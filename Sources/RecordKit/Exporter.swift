import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import RecordCore
import Synchronization
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case mp4, hevc, webm, gif
    public var label: String { ["mp4": "MP4", "hevc": "HEVC", "webm": "WebM", "gif": "GIF"][rawValue]! }
    public var detail: String {
        switch self {
        case .mp4: "H.264. Plays everywhere. Best for sharing and uploading."
        case .hevc: "H.265. Half the size, plays on Apple devices and modern browsers."
        case .webm: "VP9, for web pages."
        case .gif: "A looping animation for READMEs and chats. No sound, up to \(Int(GIFOptions.maxSeconds)) seconds."
        }
    }
    public var fileExtension: String {
        switch self {
        case .webm: "webm"
        case .gif: "gif"
        case .mp4, .hevc: "mp4"
        }
    }
}

/// The files written next to the video, besides it.
public struct ExportExtras: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let subtitles = ExportExtras(rawValue: 1), transcript = ExportExtras(rawValue: 2)
    public static let poster = ExportExtras(rawValue: 4), summary = ExportExtras(rawValue: 8)
    public static let all: ExportExtras = [.subtitles, .transcript, .poster, .summary]
}

public struct ExportResult: Sendable {
    public var video: String
    /// What Show in Finder selects: the export's folder when it has extras, otherwise the video.
    public var place: String
    /// Nil when not asked for (see `ExportExtras`).
    public var poster, transcript, summary: String?
    public var transcriptError: String?
}

public struct ExportJob: Sendable {
    public var source: URL, width: Int, height: Int, duration: Double, fps: Double
    public var title: String, createdAt: Date, edits: Edits, cursor: [CursorSample]
    /// The video is `outDir/name.<extension>`; with any extras, it and they go in a folder `outDir/name/` instead,
    /// all with the same name (see `place`). An existing file or folder is replaced.
    public var format: ExportFormat, outDir: URL, name: String
    public var extras: ExportExtras
    public var camera: URL?, cameraOffset: Double
    public var systemAudio: URL?, systemAudioOffset: Double
    public var windowCornerPx: Double?
    public var cursorImages: [CursorImage]
    public var keys: [ShortcutPress]
    public var gif: GIFOptions
    public var resolution: ExportResolution, quality: ExportQuality
    public init(source: URL, width: Int, height: Int, duration: Double, fps: Double, title: String, createdAt: Date,
                edits: Edits, cursor: [CursorSample], format: ExportFormat, outDir: URL, name: String, extras: ExportExtras = .all,
                camera: URL? = nil, cameraOffset: Double = 0, windowCornerPx: Double? = nil, gif: GIFOptions = GIFOptions(),
                resolution: ExportResolution = .p1080, quality: ExportQuality = .high, systemAudio: URL? = nil, systemAudioOffset: Double = 0,
                cursorImages: [CursorImage] = [], keys: [ShortcutPress] = []) {
        self.cursorImages = cursorImages; self.keys = keys
        self.systemAudio = systemAudio; self.systemAudioOffset = systemAudioOffset
        self.camera = camera; self.cameraOffset = cameraOffset; self.windowCornerPx = windowCornerPx; self.gif = gif
        self.resolution = resolution; self.quality = quality
        self.source = source; self.width = width; self.height = height; self.duration = duration; self.fps = fps
        self.title = title; self.createdAt = createdAt; self.edits = edits; self.cursor = cursor
        self.format = format; self.outDir = outDir; self.name = name; self.extras = extras
    }
}

extension ExportJob {
    /// Where an export named `name` goes in `outDir`: with any extras, a folder named after it holding the video and
    /// its extras; otherwise the video alone.
    public static func place(outDir: URL, name: String, format: ExportFormat, extras: ExportExtras) -> URL {
        let base = exportFileName(name)
        return extras.isEmpty ? outDir.appending(path: "\(base).\(format.fileExtension)") : outDir.appending(path: base)
    }
    /// The video's path in `place(…)`.
    public static func video(outDir: URL, name: String, format: ExportFormat, extras: ExportExtras) -> URL {
        let place = place(outDir: outDir, name: name, format: format, extras: extras)
        return extras.isEmpty ? place : place.appending(path: "\(place.lastPathComponent).\(format.fileExtension)")
    }
    public var place: URL { Self.place(outDir: outDir, name: name, format: format, extras: extras) }
}

public enum Exporter {
    public typealias Transcribe = @Sendable (URL) async throws -> String

    /// Renders the video, then writes the extras asked for beside it: poster, transcript, Markdown summary and, when
    /// captions are on, subtitles. `progress` reports a stage name and, while encoding, a 0...1 fraction. Cancelling the
    /// task stops it and removes the unfinished video. The video is written beside its place and moved there once it's
    /// finished, so an existing file it replaces is kept if the export stops or fails. With extras, they all go in a
    /// folder, written beside its place and swapped in whole once everything is written.
    public static func run(_ job: ExportJob, transcribe: Transcribe?, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> ExportResult {
        let problems = validateEdits(job.edits, duration: job.duration)
        if !problems.isEmpty { throw StudioError.message(problems.joined(separator: "\n")) }
        let length = outputDuration(job.edits.timeMap)
        if job.format == .gif {
            guard GIFOptions.frameRates.contains(job.gif.fps), GIFOptions.widths.contains(job.gif.width) else {
                throw StudioError.message("Pick one of the GIF frame rates and widths.")
            }
            guard length <= GIFOptions.maxSeconds + 0.01 else {
                throw StudioError.message("GIFs can be up to \(Int(GIFOptions.maxSeconds)) seconds. Trim the clip, or export a video.")
            }
        }
        try FileManager.default.createDirectory(at: job.outDir, withIntermediateDirectories: true)
        let base = exportFileName(job.name), place = job.place, fm = FileManager.default
        let folder = !job.extras.isEmpty
        // A folder is written whole as `.name.partial/`; a lone video as `.name.partial.<extension>` beside its place.
        let partial = job.outDir.appending(path: folder ? ".\(base).partial" : ".\(base).partial.\(job.format.fileExtension)")
        do {
            if folder {
                try? fm.removeItem(at: partial)
                try fm.createDirectory(at: partial, withIntermediateDirectories: true)
                let video = partial.appending(path: "\(base).\(job.format.fileExtension)")
                var res = try await write(job, dir: partial, base: base, video: video, partial: video, length: length, transcribe: transcribe, progress: progress)
                // Finished: only now does the folder take the place of one with the same name.
                try Task.checkCancellation()
                if fm.fileExists(atPath: place.path) { try fm.removeItem(at: place) }
                try fm.moveItem(at: partial, to: place)
                func moved(_ path: String) -> String { place.appending(path: URL(fileURLWithPath: path).lastPathComponent).path }
                res.video = moved(res.video); res.poster = res.poster.map(moved)
                res.transcript = res.transcript.map(moved); res.summary = res.summary.map(moved)
                res.place = place.path
                return res
            }
            return try await write(job, dir: job.outDir, base: base, video: place, partial: partial, length: length, transcribe: transcribe, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Task.isCancelled ? CancellationError() : error // stopped readers fail with their own errors
        }
    }

    /// Writes the video to `partial`, moves it to `video` (when they differ) and writes the extras beside it in `dir`.
    private static func write(_ job: ExportJob, dir: URL, base: String, video: URL, partial: URL, length: Double, transcribe: Transcribe?,
                              progress: @escaping @Sendable (String, Double?) -> Void) async throws -> ExportResult {
        let poster = dir.appending(path: "\(base).jpg")
        let transcriptURL = dir.appending(path: "\(base).transcript.txt")
        let summaryURL = dir.appending(path: "\(base).md")

        // The cleaned microphone is made once per setting and kept beside the recording; usually it's there already.
        var mic: CleanMic?
        if let cleanup = job.edits.micCleanup, cleanup.isOn {
            progress("Cleaning up the microphone", nil)
            mic = try await MicCleaner.file(for: job.source, in: job.source.deletingLastPathComponent(), cleanup)
        }
        progress("Rendering", 0)
        let sources = try await Sources.load(screen: job.source, camera: job.camera, offset: job.cameraOffset, music: job.edits.audio,
                                             system: job.systemAudio, systemOffset: job.systemAudioOffset, mic: mic,
                                             clips: job.edits.allClips, overlays: job.edits.videoOverlays, segments: job.edits.timeMap)
        let voice = job.edits.audio?.duck == true ? try await VoiceActivity.ranges(of: job.source) : []
        let audioMix = AudioMixer.make(sources, music: job.edits.audio, voice: voice, mic: job.edits.micVolume ?? 1, system: job.edits.systemVolume ?? 1,
                                       silenced: job.edits.silenced ?? [], clips: job.edits.allClips, overlays: job.edits.videoOverlays)
        // GIFs are scaled down from the preview size; videos render at the chosen resolution.
        let renderer = FrameRenderer(edits: job.edits, cursor: job.cursor, sourceWidth: job.width, sourceHeight: job.height, duration: job.duration,
                                     windowCornerPx: job.windowCornerPx,
                                     maxLongSide: (job.format == .gif ? ExportResolution.preview : job.resolution).longSide,
                                     cursorImages: job.cursorImages, keys: job.keys)
        let composition = try await Composition.make(sources, renderer: renderer, fps: job.fps)
        if job.format == .gif {
            try await writeGIF(sources, composition: composition, canvas: renderer.size, job: job, to: partial, progress: progress)
        } else {
            try await encode(sources, composition: composition, audioMix: audioMix, size: renderer.size, job: job,
                             to: job.format == .webm ? dir.appending(path: ".\(base).tmp.mp4") : partial, progress: progress)
        }

        try Task.checkCancellation()
        if job.format == .webm {
            progress("Converting to WebM", nil)
            let encoded = dir.appending(path: ".\(base).tmp.mp4")
            defer { try? FileManager.default.removeItem(at: encoded) }
            try await Tools.run(Tools.ffmpeg(), ["-y", "-hide_banner", "-loglevel", "error", "-i", encoded.path,
                "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                "-c:a", "libopus", "-b:a", "96k", partial.path])
        }

        // Finished: only now does it take the place of a file with the same name.
        try Task.checkCancellation()
        if partial != video {
            if FileManager.default.fileExists(atPath: video.path) { try FileManager.default.removeItem(at: video) }
            try FileManager.default.moveItem(at: partial, to: video)
        }

        try Task.checkCancellation()
        let extras = job.extras
        if extras.contains(.poster) {
            progress("Poster", nil)
            if job.format == .gif {
                try writePoster(ofGIF: video, frame: gifFrameCount(seconds: min(1, length / 3), job.gif), to: poster)
            } else {
                try await writePoster(of: video, at: min(1, length / 3), to: poster)
            }
        }

        // The summary quotes the transcript, so it's made for either.
        var transcript = ""
        var transcriptError: String?
        if !extras.isDisjoint(with: [.transcript, .summary]) {
            progress("Transcript", nil)
            if job.format == .gif {
                transcriptError = "GIFs have no sound."
            } else if let transcribe {
                do { transcript = try await transcribe(video) } catch { transcriptError = error.localizedDescription }
            } else {
                transcriptError = "Transcription is off."
            }
            try Task.checkCancellation()
        }
        if extras.contains(.transcript) {
            try (transcript.isEmpty ? "(No transcript\(transcriptError.map { ": \($0)" } ?? "."))\n" : transcript + "\n")
                .write(to: transcriptURL, atomically: true, encoding: .utf8)
        }

        if extras.contains(.summary) {
            progress("Summary", nil)
            try summaryMarkdown(title: job.title, createdAt: job.createdAt, edits: job.edits, video: video.lastPathComponent,
                                poster: extras.contains(.poster) ? poster.lastPathComponent : nil, transcript: transcript)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        if extras.contains(.subtitles), let c = job.edits.captions, c.srt, job.format != .gif {
            try srt(c.lines, job.edits.timeMap).write(to: dir.appending(path: "\(base).srt"), atomically: true, encoding: .utf8)
        }

        return ExportResult(video: video.path, place: video.path, poster: extras.contains(.poster) ? poster.path : nil,
                            transcript: extras.contains(.transcript) ? transcriptURL.path : nil,
                            summary: extras.contains(.summary) ? summaryURL.path : nil,
                            transcriptError: extras.contains(.transcript) ? transcriptError : nil)
    }

    /// MP4, HEVC, or the MP4 that WebM is converted from: the rendered frames and the mixed audio, re-encoded at the
    /// job's bitrate. AVAssetWriter rather than an export session, because only the writer takes a bitrate.
    static func encode(_ sources: Sources, composition: AVVideoComposition, audioMix: AVAudioMix?, size: OutputSize, job: ExportJob, to url: URL,
                       progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        // The sources hold only the kept segments, back to back, so the video is 0…its edited length. Placing them rounds
        // each to the composition's clock, so it can come out a tick short; reading past its end fails (-11841).
        let asset = sources.asset, length = max(0.01, min(outputDuration(job.edits.timeMap), try await asset.load(.duration).seconds))
        let range = CMTimeRange(start: .zero, end: CMTime(seconds: length, preferredTimescale: 600))
        // One reader per track. A shared reader can stall: it may hold back video until audio is read, while the writer
        // holds back audio until video catches up, and neither moves again. Separate readers leave only the writer's
        // interleaving between them, which always makes progress.
        let videoReader = try AVAssetReader(asset: asset)
        videoReader.timeRange = range
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await asset.loadTracks(withMediaType: .video),
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOut) else { throw StudioError.message("Couldn't read the rendered frames.") }
        videoReader.add(videoOut)

        // Audio is decoded to 48 kHz stereo PCM (mono microphones are spread to both sides), then encoded as AAC.
        var stereo = AudioChannelLayout()
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layout = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        var audioReader: AVAssetReader?
        if !audioTracks.isEmpty {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = range
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVChannelLayoutKey: layout,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            out.alwaysCopiesSampleData = false
            out.audioMix = audioMix // microphone and system levels; the extra track's volume, fades and ducking
            out.audioTimePitchAlgorithm = .spectral // sped-up or slowed parts keep their pitch
            if r.canAdd(out) { r.add(out); audioOut = out; audioReader = r }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let hevc = job.format == .hevc
        let fps = min(60, max(1, job.fps))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: exportBitrate(width: size.width, height: size.height, fps: fps, job.quality, hevc: hevc),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            // The compositor renders sRGB; tag it as standard HD video so players show the same colours.
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw StudioError.message("This Mac can't encode that format at this size.") }
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVChannelLayoutKey: layout,
                AVEncoderBitRateKey: 160_000])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        // Chapters: a timed-text track the video names as its chapter list, as QuickTime, YouTube and VLC read them.
        let chapters = Chapters(job.edits.chapters(title: job.title))
        if let input = chapters.input, writer.canAdd(input), videoIn.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue) {
            writer.add(input)
            videoIn.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        } else {
            chapters.input = nil
        }

        // Only start the audio reader if the writer took the audio input too.
        var tracks = [WriteTrack(reader: videoReader, output: videoOut, input: videoIn, label: "video")]
        if let audioReader, let audioOut, let audioIn { tracks.append(WriteTrack(reader: audioReader, output: audioOut, input: audioIn, label: "audio")) }
        let session = WriteSession(readers: tracks.map(\.reader), writer: writer)

        guard writer.startWriting() else { throw writer.error ?? StudioError.message("Couldn't start writing the video.") }
        for t in tracks where !t.reader.startReading() {
            session.readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            throw t.reader.error ?? StudioError.message("Couldn't read the rendered frames.")
        }
        writer.startSession(atSourceTime: range.start)

        // Cancelling raises a flag that each track sees on its own queue, where it stops its reader and finishes early;
        // the check after this then throws. A reader cancelled from another thread while it's reading a frame crashes
        // inside CoreMedia (#258).
        try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            // Feeds one reader output into one writer input whenever the writer wants more.
            for track in tracks {
                group.enter()
                track.input.requestMediaDataWhenReady(on: DispatchQueue(label: "RecordStudio.export.\(track.label)")) {
                    let reader = track.reader, output = track.output, input = track.input
                    while input.isReadyForMoreMediaData {
                        if session.cancelled.withLock({ $0 }) { reader.cancelReading() }
                        guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        if track.label == "video" {
                            progress("Rendering", min(1, max(0, sample.presentationTimeStamp.seconds / length)))
                        }
                        if !input.append(sample) {
                            session.cancelled.withLock { $0 = true } // the writer failed; stop the other track too
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            // The chapters are a handful of samples, handed over as the writer asks for them alongside the video.
            if let first = chapters.input {
                group.enter()
                first.requestMediaDataWhenReady(on: DispatchQueue(label: "RecordStudio.export.chapters")) {
                    // Reached through `chapters`, which may cross queues, like the tracks above through `track`.
                    guard let input = chapters.input else { group.leave(); return }
                    while input.isReadyForMoreMediaData {
                        guard let sample = chapters.next(), input.append(sample) else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) {
                let writer = session.writer
                let failed = session.readers.first { $0.status == .failed }
                if writer.status == .failed || failed != nil {
                    let error = writer.error ?? failed?.error ?? StudioError.message("The video couldn't be encoded.")
                    writer.cancelWriting()
                    done.resume(throwing: error)
                    return
                }
                writer.finishWriting {
                    let writer = session.writer
                    if writer.status == .completed { done.resume() }
                    else { done.resume(throwing: writer.error ?? StudioError.message("The video couldn't be finished.")) }
                }
            }
        } } onCancel: { session.cancelled.withLock { $0 = true } }
        try Task.checkCancellation()
    }

    /// An export's chapters as 3GPP timed text (`tx3g`), the text format MP4 carries, one sample per chapter.
    final class Chapters: @unchecked Sendable {
        var input: AVAssetWriterInput?
        private var samples: [CMSampleBuffer]

        init(_ list: [Chapter]) {
            var format: CMFormatDescription?
            let white: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                          kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
            // The sample description tx3g requires. Chapter text is never drawn, so the values are just valid ones.
            let ext: [CFString: Any] = [
                kCMTextFormatDescriptionExtension_DisplayFlags: 0,
                kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
                kCMTextFormatDescriptionExtension_VerticalJustification: 0,
                kCMTextFormatDescriptionExtension_BackgroundColor: [kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                                                                    kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255],
                kCMTextFormatDescriptionExtension_DefaultTextBox: [kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                                                                   kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0],
                kCMTextFormatDescriptionExtension_DefaultStyle: [kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                                                                 kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                                                                 kCMTextFormatDescriptionStyle_ForegroundColor: white, kCMTextFormatDescriptionStyle_FontSize: 12],
                kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
            ]
            CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
                                      extensions: ext as CFDictionary, formatDescriptionOut: &format)
            samples = format.map { f in list.compactMap { Self.sample($0, format: f) } } ?? []
            guard let format, !samples.isEmpty else { return }
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.marksOutputTrackAsEnabled = false // a chapter list, not subtitles to show
            input.expectsMediaDataInRealTime = false
            self.input = input
        }

        func next() -> CMSampleBuffer? { samples.isEmpty ? nil : samples.removeFirst() }

        /// tx3g text: a 16-bit big-endian byte count, then the UTF-8.
        private static func sample(_ c: Chapter, format: CMFormatDescription) -> CMSampleBuffer? {
            let utf8 = Array(c.name.utf8.prefix(Int(UInt16.max)))
            var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                     blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
            else { return nil }
            var timing = CMSampleTimingInfo(duration: CMTime(seconds: c.end - c.start, preferredTimescale: 600),
                                            presentationTimeStamp: CMTime(seconds: c.start, preferredTimescale: 600), decodeTimeStamp: .invalid)
            var size = bytes.count
            var out: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                 sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                 sampleSizeArray: &size, sampleBufferOut: &out)
            return out
        }
    }

    /// Reads the rendered frames in order, keeps one every 1/fps of the trimmed clip, scales them down and writes
    /// them as GIF frames. Each kept frame is added as soon as it's read, so nothing waits for the whole clip.
    static func writeGIF(_ sources: Sources, composition: AVVideoComposition, canvas: OutputSize, job: ExportJob, to url: URL,
                         progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let o = job.gif, length = min(outputDuration(job.edits.timeMap), try await sources.asset.load(.duration).seconds) // see `encode`
        let reader = try AVAssetReader(asset: sources.asset)
        reader.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await sources.asset.loadTracks(withMediaType: .video),
                                                         videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.message("Couldn't read the rendered frames.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Couldn't read the rendered frames.") }
        defer { reader.cancelReading() }

        let size = gifSize(canvas, o), total = gifFrameCount(seconds: length, o), delay = 1 / Double(o.fps)
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw StudioError.message("Couldn't create the GIF.")
        }
        // Loop count 0 repeats forever; without the key, the GIF plays once.
        let loop: [CFString: Any] = o.loops ? [kCGImagePropertyGIFLoopCount: 0] : [:]
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: loop] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary

        let ctx = CIContext(options: [.cacheIntermediates: false])
        let sy = Double(size.height) / Double(canvas.height), sx = Double(size.width) / Double(canvas.width)
        func scaled(_ buffer: CVPixelBuffer) -> CGImage? {
            let f = CIFilter.lanczosScaleTransform() // sharper than plain resampling, so small UI text stays readable
            f.inputImage = CIImage(cvPixelBuffer: buffer)
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            guard let img = f.outputImage else { return nil }
            return ctx.createCGImage(img, from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        var written = 0
        var last: CGImage?
        while written < total, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Frame k of the GIF shows the clip at k/fps: take the first rendered frame at or after that time.
            let t = sample.presentationTimeStamp.seconds
            guard Double(written) * delay <= t + 1e-3, let buffer = sample.imageBuffer, let image = scaled(buffer) else { continue }
            while written < total, Double(written) * delay <= t + 1e-3 {
                CGImageDestinationAddImage(dest, image, frameProps)
                written += 1
            }
            last = image
            progress("Rendering", Double(written) / Double(total))
        }
        if reader.status == .failed { throw reader.error ?? StudioError.message("Couldn't read the rendered frames.") }
        // The clip can end a hair before the last frame's time; hold the final image for it.
        while written < total, let last {
            CGImageDestinationAddImage(dest, last, frameProps)
            written += 1
        }
        guard written == total, CGImageDestinationFinalize(dest) else { throw StudioError.message("Couldn't write the GIF.") }
    }

    static func writePoster(ofGIF gif: URL, frame: Int, to out: URL) throws {
        guard let src = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, min(frame, CGImageSourceGetCount(src) - 1), nil) else {
            throw StudioError.message("Couldn't read the GIF back for its poster.")
        }
        try writeJPEG(image, to: out)
    }

    static func writePoster(of video: URL, at seconds: Double, to out: URL) async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let (image, _) = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try writeJPEG(image, to: out)
    }

    static func writeJPEG(_ image: CGImage, to out: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StudioError.message("Couldn't write the poster image.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw StudioError.message("Couldn't write the poster image.") }
    }
}

// AVFoundation's readers and writers aren't Sendable. `encode` uses them safely: each track's reader, output and input
// are only touched on that track's queue (cancelling included, through `cancelled`), and the writer is finished only
// after every track is done. These wrappers say so.
private final class WriteSession: @unchecked Sendable {
    let readers: [AVAssetReader], writer: AVAssetWriter
    let cancelled = Mutex(false)
    init(readers: [AVAssetReader], writer: AVAssetWriter) { self.readers = readers; self.writer = writer }
}
private struct WriteTrack: @unchecked Sendable {
    let reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String
}

/// Optional command-line helpers (ffmpeg for WebM, whisper-cli for transcripts). Nothing else needs them.
public enum Tools {
    static func find(_ env: String, _ name: String) -> String? {
        if let p = ProcessInfo.processInfo.environment[env], !p.isEmpty { return p }
        return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static var hasFFmpeg: Bool { find("FFMPEG_PATH", "ffmpeg") != nil }

    static func ffmpeg() throws -> String {
        guard let p = find("FFMPEG_PATH", "ffmpeg") else { throw StudioError.message("WebM needs ffmpeg. Install it with `brew install ffmpeg`, or export MP4/HEVC.") }
        return p
    }

    /// Runs a tool to completion; throws with the tail of its stderr on failure.
    @discardableResult
    public static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else { cont.resume(throwing: StudioError.message("\((exe as NSString).lastPathComponent) failed: \(e.suffix(600))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
