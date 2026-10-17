import AVFoundation
import CoreImage
import RecordCore

/// One instruction spanning the whole recording; it carries the renderer for the current edits.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    /// Each inserted clip's video, by its index in `Edits.allClips`.
    let clipTrackIDs: [Int: CMPersistentTrackID]
    /// Each video overlay's video, by its index in `Edits.videoOverlays`.
    let overlayTrackIDs: [Int: CMPersistentTrackID]
    let renderer: FrameRenderer
    let segments: [Trim]?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, clipTrackIDs: [Int: CMPersistentTrackID],
         overlayTrackIDs: [Int: CMPersistentTrackID], renderer: FrameRenderer, segments: [Trim]?) {
        self.timeRange = timeRange
        self.segments = segments
        self.trackID = trackID
        self.cameraTrackID = cameraTrackID
        self.clipTrackIDs = clipTrackIDs
        self.overlayTrackIDs = overlayTrackIDs
        self.requiredSourceTrackIDs = ([trackID] + (cameraTrackID.map { [$0] } ?? []) + clipTrackIDs.values.sorted() + overlayTrackIDs.values.sorted())
            .map { NSNumber(value: $0) }
        self.renderer = renderer
    }
}

/// AVFoundation calls this for every frame, in the player and in the exporter.
final class StudioCompositor: NSObject, AVVideoCompositing {
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "RecordStudio"])
    private static let format: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    /// The last screen frame drawn, for a gap in the screen track (requests can come from several threads).
    private let lock = NSLock()
    private var lastScreen: CVPixelBuffer?

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.format }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.format }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let inst = request.videoCompositionInstruction as? StudioInstruction, let dst = request.renderContext.newPixelBuffer() else {
            request.finish(with: StudioError.message("A video frame couldn't be rendered."))
            return
        }
        let t = request.compositionTime.seconds, at = inst.segments.map { outputToSource($0, t) } ?? t
        // Overlay tracks are empty outside their time, so only the ones showing have a frame.
        let overlays = inst.overlayTrackIDs.compactMapValues { request.sourceFrame(byTrackID: $0).map { CIImage(cvPixelBuffer: $0) } }
        let img: CIImage
        if let i = inst.renderer.edits.clipIndex(at: at) {
            // An inserted clip plays here, in place of the recording. A clip whose file has gone shows as black.
            let frame = inst.clipTrackIDs[i].flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            img = inst.renderer.render(clip: frame, overlays: overlays, at: at)
        } else {
            // A recording's screen track can have short empty edits (one of 13 ms, mid-recording): the frame before
            // carries on through them, or just the background when there's none yet, as after a seek into one.
            let src = lock.withLock {
                if let f = request.sourceFrame(byTrackID: inst.trackID) { lastScreen = f }
                return lastScreen
            }
            // The camera track has gaps where the camera wasn't recording; the bubble is simply absent there.
            let cam = inst.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            img = inst.renderer.render(src.map { CIImage(cvPixelBuffer: $0) } ?? .empty(), camera: cam, overlays: overlays, at: at)
        }
        let size = inst.renderer.size
        Self.context.render(img, to: dst, bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: dst)
    }
}

/// The recording as one asset: screen video + microphone, plus the camera video and system audio placed at their sync offsets,
/// and any inserted clips (see `InsertedClip`) between them. Composition time is timeline time, or with `segments` (for
/// export, an `Edits.timeMap`) output time: only the kept parts, back to back, each at its speed.
public struct Sources: @unchecked Sendable {
    public let asset: AVAsset
    public let segments: [Trim]?
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?
    /// The extra audio file's track, if one was placed (see `AudioMixer`).
    let musicTrack: AVAssetTrack?
    /// The recording's own sound: the microphone (in the screen file) and system audio (system.m4a).
    let micTracks: [AVAssetTrack]
    let systemTrack: AVAssetTrack?
    /// The inserted clips this was built with, and each one's video and sound, by index in `clips`.
    public let clips: [InsertedClip]
    let clipVideo: [Int: CMPersistentTrackID]
    let clipSound: [(track: AVAssetTrack, clip: Int)]
    /// The video overlays this was built with (`Edits.videoOverlays`), and each one's video and sound, by index in `overlays`.
    public let overlays: [Annotation]
    let overlayVideo: [Int: CMPersistentTrackID]
    let overlaySound: [(track: AVAssetTrack, overlay: Int)]

    /// `music`: an extra audio file, placed at its time in the recording. Its volume comes from `AudioMixer`.
    /// `system`: the system audio file, which starts `systemOffset` seconds into the screen recording.
    /// `mic`: a cleaned copy of the microphone (see `MicCleaner`), played instead of the screen file's own sound.
    /// `clips`: `Edits.allClips`, played between parts of the recording; the recording's own media moves later past each.
    /// `overlays`: `Edits.videoOverlays`, each placed for its time on the timeline.
    public static func load(screen: URL, camera: URL?, offset: Double, music: AudioTrack? = nil,
                            system: URL? = nil, systemOffset: Double = 0, mic: CleanMic? = nil, clips: [InsertedClip] = [],
                            overlays: [Annotation] = [], segments: [Trim]? = nil) async throws -> Sources {
        var runs: [(start: Double, end: Double, shift: Double)] = []
        /// Inserts `track`'s media for timeline time `start`…`start + length`, where file time is timeline time + `fileOffset`.
        func placeOnTimeline(_ track: AVAssetTrack, start: Double, length: Double, fileOffset: Double, into t: AVMutableCompositionTrack, timescale: CMTimeScale = 600) throws {
            let time = { (s: Double) in CMTime(seconds: s, preferredTimescale: timescale) }
            guard let segments else {
                return try t.insertTimeRange(CMTimeRange(start: time(start + fileOffset), duration: time(length)), of: track, at: time(start))
            }
            var out = 0.0
            for s in segments {
                let a = max(s.start, start), b = min(s.end, start + length), speed = s.speed ?? 1
                if b - a > 0.001 {
                    let at = time(out + (a - s.start) / speed)
                    try t.insertTimeRange(CMTimeRange(start: time(a + fileOffset), duration: time(b - a)), of: track, at: at)
                    if speed != 1 { t.scaleTimeRange(CMTimeRange(start: at, duration: time(b - a)), toDuration: time((b - a) / speed)) }
                }
                out += s.outputLength
            }
        }

        /// Inserts `track`'s media for recording time `start`…`start + length`, where file time is recording time +
        /// `fileOffset`: on the timeline, in one piece per stretch between inserted clips.
        func place(_ track: AVAssetTrack, start: Double, length: Double, fileOffset: Double, into t: AVMutableCompositionTrack, timescale: CMTimeScale = 600) throws {
            for run in runs {
                let a = max(start, run.start), b = min(start + length, run.end)
                if b - a > 0.001 { try placeOnTimeline(track, start: a + run.shift, length: b - a, fileOffset: fileOffset - run.shift, into: t, timescale: timescale) }
            }
        }
        let s = AVURLAsset(url: screen)
        let duration = try await s.load(.duration)
        runs = recordingRuns(clips, duration: duration.seconds)
        let timeline = duration.seconds + clips.reduce(0) { $0 + $1.length }
        guard let video = try await s.loadTracks(withMediaType: .video).first else { throw StudioError.message("The recording has no video track.") }
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.message("Couldn't prepare the video.") }
        try place(video, start: 0, length: duration.seconds, fileOffset: 0, into: v)
        var micTracks: [AVAssetTrack] = []
        let cleanAsset = mic.flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? AVURLAsset(url: $0.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) : nil }
        if let mic, let cleanAsset, let a = try await cleanAsset.loadTracks(withMediaType: .audio).first {
            // Placed like the system audio: file time τ is screen time τ + offset.
            let span = try await a.load(.timeRange)
            let skip = max(span.start.seconds, -mic.offset), at = skip + mic.offset
            let len = min(span.end.seconds - skip, duration.seconds - at)
            if len > 0.05, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try place(a, start: at, length: len, fileOffset: skip - at, into: t, timescale: 48_000)
                } catch { throw StudioError.message("Couldn't add the cleaned microphone: \(error.localizedDescription)") }
                micTracks.append(t)
            }
        }
        withExtendedLifetime(cleanAsset) {}
        let usesCleanMic = !micTracks.isEmpty
        for a in try await s.loadTracks(withMediaType: .audio) where !usesCleanMic {
            // The track's own span, not the video's: audio can end a few milliseconds before the video, and asking
            // for time a track doesn't have fails (AVFoundation -11800 / -12780).
            let span = try await a.load(.timeRange).intersection(range)
            guard span.duration.seconds > 0.01, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            do { try place(a, start: span.start.seconds, length: span.duration.seconds, fileOffset: 0, into: t) }
            catch { throw StudioError.message("Couldn't add the recording's sound: \(error.localizedDescription)") }
            micTracks.append(t)
        }
        var camID: CMPersistentTrackID?
        if let camera, FileManager.default.fileExists(atPath: camera.path) {
            let c = AVURLAsset(url: camera)
            if let cv = try await c.loadTracks(withMediaType: .video).first {
                // Camera time τ is screen time τ + offset. Skip any camera footage from before the screen started.
                let cdur = try await c.load(.duration).seconds
                let skip = max(0, -offset), at = max(0, offset)
                let len = min(cdur - skip, duration.seconds - at)
                if len > 0.05, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try place(cv, start: at, length: len, fileOffset: skip - at, into: t)
                    camID = t.trackID
                }
            }
        }
        var musicTrack: AVAssetTrack?
        // Keep the asset in a variable: a track doesn't keep its asset alive, and inserting from a track whose asset
        // has gone fails with AVFoundation -11800 / -12780.
        let musicAsset = music.map { AVURLAsset(url: URL(fileURLWithPath: $0.path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        if let music, let musicAsset, FileManager.default.fileExists(atPath: music.path),
           let a = try await musicAsset.loadTracks(withMediaType: .audio).first {
            // Never past the end of the recording, so the timeline keeps the video's length, nor past the end of the
            // file as it actually reads (a damaged or replaced file may be shorter than when it was added).
            let available = try await a.load(.timeRange).end.seconds - music.from
            let len = min(music.length, timeline - music.at, available)
            if len > 0.05, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try placeOnTimeline(a, start: music.at, length: len, fileOffset: music.from - music.at, into: t)
                } catch { throw StudioError.message("Couldn't add the audio file: \(error.localizedDescription)") }
                musicTrack = t
            }
        }
        withExtendedLifetime(musicAsset) {}
        var systemTrack: AVAssetTrack?
        let systemAsset = system.map { AVURLAsset(url: $0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        if let system, let systemAsset, FileManager.default.fileExists(atPath: system.path),
           let a = try await systemAsset.loadTracks(withMediaType: .audio).first {
            // Like the camera: file time τ is screen time τ + offset. Skip anything from before the screen started.
            let span = try await a.load(.timeRange)
            let skip = max(span.start.seconds, -systemOffset), at = skip + systemOffset
            let len = min(span.end.seconds - skip, duration.seconds - at)
            if len > 0.05, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try place(a, start: at, length: len, fileOffset: skip - at, into: t, timescale: 48_000)
                } catch { throw StudioError.message("Couldn't add the system audio: \(error.localizedDescription)") }
                systemTrack = t
            }
        }
        withExtendedLifetime(systemAsset) {}
        // Each clip on tracks of its own, so its frames are told apart from the recording's and its sound has its own volume.
        var clipVideo: [Int: CMPersistentTrackID] = [:], clipSound: [(track: AVAssetTrack, clip: Int)] = []
        var clipAssets: [AVURLAsset] = []
        for (i, clip) in clips.enumerated() where FileManager.default.fileExists(atPath: clip.path) {
            let asset = AVURLAsset(url: URL(fileURLWithPath: clip.path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            clipAssets.append(asset)
            do {
                if let cv = try await asset.loadTracks(withMediaType: .video).first {
                    let span = try await cv.load(.timeRange)
                    let len = min(clip.length, span.end.seconds) - span.start.seconds
                    if len > 0.05, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try placeOnTimeline(cv, start: clip.at + span.start.seconds, length: len, fileOffset: -clip.at, into: t)
                        clipVideo[i] = t.trackID
                    }
                }
                if let ca = try await asset.loadTracks(withMediaType: .audio).first {
                    let span = try await ca.load(.timeRange)
                    let len = min(clip.length, span.end.seconds) - span.start.seconds
                    if len > 0.05, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try placeOnTimeline(ca, start: clip.at + span.start.seconds, length: len, fileOffset: -clip.at, into: t, timescale: 48_000)
                        clipSound.append((track: t as AVAssetTrack, clip: i))
                    }
                }
            } catch {
                throw StudioError.message("The clip “\(clip.name)” couldn’t be added: \(error.localizedDescription)")
            }
        }
        withExtendedLifetime(clipAssets) {}
        // Each overlay on tracks of its own too, holding just the part that shows: file time is timeline time - `at`.
        var overlayVideo: [Int: CMPersistentTrackID] = [:], overlaySound: [(track: AVAssetTrack, overlay: Int)] = []
        var overlayAssets: [AVURLAsset] = []
        for (i, a) in overlays.enumerated() {
            guard let o = a.video, FileManager.default.fileExists(atPath: o.path) else { continue }
            let asset = AVURLAsset(url: URL(fileURLWithPath: o.path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            overlayAssets.append(asset)
            do {
                for type in [AVMediaType.video, .audio] {
                    guard let track = try await asset.loadTracks(withMediaType: type).first else { continue }
                    let span = try await track.load(.timeRange)
                    let start = max(a.start, o.at + span.start.seconds), end = min(a.end, o.at + min(o.length, span.end.seconds), timeline)
                    guard end - start > 0.05, let t = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try placeOnTimeline(track, start: start, length: end - start, fileOffset: -o.at, into: t, timescale: type == .audio ? 48_000 : 600)
                    if type == .video { overlayVideo[i] = t.trackID } else { overlaySound.append((track: t as AVAssetTrack, overlay: i)) }
                }
            } catch {
                throw StudioError.message("The video overlay “\(o.name)” couldn’t be added: \(error.localizedDescription)")
            }
        }
        withExtendedLifetime(overlayAssets) {}
        return Sources(asset: comp, segments: segments, screenTrack: v.trackID, cameraTrack: camID, musicTrack: musicTrack, micTracks: micTracks,
                       systemTrack: systemTrack, clips: clips, clipVideo: clipVideo, clipSound: clipSound,
                       overlays: overlays, overlayVideo: overlayVideo, overlaySound: overlaySound)
    }
}

public enum Composition {
    /// A video composition that renders `edits` over the sources. Times seen by the renderer are recording times.
    /// `fps` is the recording's measured rate; the composition runs at `outputFrameRate(fps)`.
    public static func make(_ src: Sources, renderer: FrameRenderer, fps: Double) async throws -> AVVideoComposition {
        let duration = try await src.asset.load(.duration)
        var config = AVVideoComposition.Configuration()
        config.customVideoCompositorClass = StudioCompositor.self
        config.renderSize = CGSize(width: renderer.size.width, height: renderer.size.height)
        config.frameDuration = CMTime(value: 1, timescale: CMTimeScale(outputFrameRate(fps)))
        config.instructions = [StudioInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackID: src.screenTrack,
                                                 cameraTrackID: src.cameraTrack, clipTrackIDs: src.clipVideo, overlayTrackIDs: src.overlayVideo,
                                                 renderer: renderer, segments: src.segments)]
        return AVVideoComposition(configuration: config)
    }
}

/// Volumes as an audio mix for the player and the exporter alike: the extra track over time, and the microphone and
/// system audio at their set levels. Nil when everything plays at full volume.
public enum AudioMixer {
    /// `silenced`: parts of the microphone, system audio, music or clips muted on their own, in timeline time.
    /// `voice`: when you're speaking, in recording time. `clips`: the inserted clips as edited now, for their volumes
    /// (the sources are built without them, so a volume change doesn't rebuild the player). `overlays`: the video
    /// overlays as edited now, likewise; their sound is off unless turned up, and fades with the picture.
    public static func make(_ src: Sources, music: AudioTrack?, voice: [ClosedRange<Double>], mic: Double = 1, system: Double = 1,
                            silenced: [SilencedRange] = [], clips: [InsertedClip]? = nil, overlays: [Annotation]? = nil) -> AVAudioMix? {
        let voice = timelineRanges(src.clips, voice)
        var params: [AVAudioMixInputParameters] = []
        // Parts played faster than `SpeedRegion.maxAudible` are silent: stretched that far, speech is just chatter.
        let fast = (src.segments ?? []).filter { ($0.speed ?? 1) > SpeedRegion.maxAudible }
        let muted = { (s: SoundSource) in mergedRanges(silencedRanges(silenced, s) + fast) }
        for t in src.micTracks where mic < 1 || !muted(.mic).isEmpty {
            params.append(volume(t, [(0, max(0, mic))], muted: muted(.mic), segments: src.segments))
        }
        if let t = src.systemTrack, system < 1 || !muted(.system).isEmpty {
            params.append(volume(t, [(0, max(0, system))], muted: muted(.system), segments: src.segments))
        }
        if let music, let t = src.musicTrack {
            params.append(volume(t, musicVolumePoints(music, voice: voice), muted: muted(.music), segments: src.segments))
        }
        for (t, i) in src.clipSound {
            let edited = clips ?? src.clips
            let v = edited.indices.contains(i) ? edited[i].volume ?? 1 : 1
            if v < 1 || !muted(.clip).isEmpty { params.append(volume(t, [(0, max(0, v))], muted: muted(.clip), segments: src.segments)) }
        }
        for (t, i) in src.overlaySound {
            let edited = overlays ?? src.overlays
            guard edited.indices.contains(i) else { params.append(volume(t, [(0, 0)], muted: [], segments: src.segments)); continue }
            let a = edited[i], v = max(0, a.video?.volume ?? 0), ramp = min(a.fade ?? 0, (a.end - a.start) / 2)
            let points: [(t: Double, gain: Double)] = ramp > 0.01 ? [(0, 0), (a.start, 0), (a.start + ramp, v), (a.end - ramp, v), (a.end, 0)] : [(0, v)]
            params.append(volume(t, points, muted: fast, segments: src.segments))
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    /// A track's volume from points in recording time, silenced over `muted` (10 ms fades), moved to output time when
    /// the sources are cut. The mix interpolates between points, so they're laid out as ramps.
    // ponytail: a fade inside a cut is squeezed to nothing rather than re-planned around it.
    private static func volume(_ track: AVAssetTrack, _ points: [(t: Double, gain: Double)], muted: [Trim], segments: [Trim]?) -> AVAudioMixInputParameters {
        let p = AVMutableAudioMixInputParameters(track: track)
        var points = silencing(points, muted)
        if let segments { points = points.map { (t: sourceToOutput(segments, $0.t), gain: $0.gain) } }
        // AVFoundation rejects the mix (error -12780) if volume changes overlap or a ramp is empty, so: the starting
        // volume at time zero, then back-to-back ramps that are non-empty after rounding.
        let time = { (t: Double) in CMTime(seconds: t, preferredTimescale: 48_000) }
        if let first = points.first { p.setVolume(Float(first.gain), at: .zero) }
        for (a, b) in zip(points, points.dropFirst()) {
            let range = CMTimeRange(start: time(a.t), end: time(b.t))
            guard range.duration > .zero else { continue }
            p.setVolumeRamp(fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain), timeRange: range)
        }
        return p
    }
}

/// Loudness over time, for waveforms on the timeline and for finding speech.
public enum AudioLevels {
    /// RMS loudness (0–1) of a file's sound, every audio track mixed to mono, every `window` seconds from its start.
    public static func read(_ url: URL, window: Double = 0.1) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8_000.0
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Couldn't read the sound.") }
        let per = max(1, Int(rate * window))
        var levels: [Double] = [], sum = 0.0, count = 0
        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var pcm = [Int16](repeating: 0, count: bytes / 2)
            pcm.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            for v in pcm {
                let x = Double(v) / 32768
                sum += x * x
                count += 1
                if count == per { levels.append((sum / Double(per)).squareRoot()); sum = 0; count = 0 }
            }
        }
        if reader.status == .failed { throw reader.error ?? StudioError.message("Couldn't read the sound.") }
        return levels
    }
}

/// When you're speaking in a recording, so music can duck under your voice.
public enum VoiceActivity {
    public static let window = 0.1

    /// From the recording's own audio (the microphone, not system audio or any extra track).
    public static func ranges(of recording: URL) async throws -> [ClosedRange<Double>] {
        ranges(levels: try await AudioLevels.read(recording, window: window))
    }

    /// From microphone levels already read with `AudioLevels.read(_:window:)` at `window`.
    public static func ranges(levels: [Double]) -> [ClosedRange<Double>] { voiceRanges(levels: levels, window: window) }
}
