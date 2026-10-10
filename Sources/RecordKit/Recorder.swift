import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import RecordCore
@preconcurrency import ScreenCaptureKit
import Synchronization

/// What to capture. Rects are in global display points, top-left origin (CoreGraphics space).
public enum CaptureSource: Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(CGDirectDisplayID, CGRect)
}

public struct Microphone: Identifiable, Hashable, Sendable {
    public var id: String, name: String
    public static func all() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Listens to a microphone before recording, so the record bar can show it's picking you up. Only start it once
/// Microphone access is allowed: opening the device would otherwise bring up macOS's prompt.
public final class MicMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "RecordStudio.micMeter")
    private let power = Mutex<Float>(-160)

    /// From 0 (silent, or no microphone) to 1.
    public var level: Double { meterLevel(dB: Double(power.withLock { $0 })) }

    /// Switches to a microphone, or stops listening (nil).
    public func use(_ id: String?) {
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let id, let device = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                if session.outputs.isEmpty, session.canAddOutput(output) {
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.addOutput(output)
                }
            }
            session.commitConfiguration()
            power.withLock { $0 = -160 }
            if session.inputs.isEmpty { if session.isRunning { session.stopRunning() } } else if !session.isRunning { session.startRunning() }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        power.withLock { $0 = db }
    }
}

/// Records with ScreenCaptureKit straight to an MP4 (video + microphone), and samples the cursor alongside.
/// Our own windows (the HUD, the setup bar) are excluded from display captures.
/// System audio, when asked for, comes from a second, audio-only stream into system.m4a: SCRecordingOutput can write
/// a broken file when it gets both the microphone and system audio, and a file of its own can be balanced separately.
/// Pausing ends the screen's file and resuming starts the next (raw-2.mp4, …); `stop` joins them into raw.mp4.
public final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    public let id: String
    public let dir: URL
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var cursor: CursorTracker?
    private var keys: KeyTracker?
    private var started: CheckedContinuation<Void, Error>?
    private var finished: CheckedContinuation<Void, Error>?
    public private(set) var startedAt: Date?
    public var onError: ((Error) -> Void)?
    private var camera: CameraRig?
    private var cameraStart: Double?   // host time of the camera file's first frame
    private var screenStart: Double?   // host time of the screen file's first frame
    private var audioStream: SCStream?
    private var systemAudio: SystemAudioWriter?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    /// Keeps the filter up to date with Finder's and Notification Center's windows while the desktop icons and widgets are left out (see `CaptureExclusion`).
    private var exclusionWatch: Task<Void, Never>?
    private var parts = 0
    /// Times the cursor, shortcuts and system audio around pauses.
    private let clock = SharedClock()
    /// From `pause` until recording has carried on again.
    public private(set) var isPaused = false

    deinit { exclusionWatch?.cancel() }

    public init(root: URL = Paths.data) {
        id = String(Int64(Date().timeIntervalSince1970 * 1000))
        dir = root.appending(path: "recordings/\(id)")
    }

    /// `keystrokes`: also note the shortcuts pressed, when Input Monitoring is allowed (see `KeyTracker`).
    /// `hideDesktopIcons`: leave the files, folders and widgets on the desktop out of display and area recordings.
    /// `clickThrough`: our windows that let clicks through (the dim around what's recorded), so presses on them still count.
    public func start(_ source: CaptureSource, microphone: String?, systemAudio: Bool = false, camera: CameraRig? = nil,
                      keystrokes: Bool = false, hideDesktopIcons: Bool = false, clickThrough: Set<CGWindowID> = []) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Camera first, so the screen recording never begins without it; the offset is stored for sync.
        if let camera, camera.isActive {
            cameraStart = try await camera.startRecording(to: dir.appending(path: "camera.mov"))
            self.camera = camera
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw StudioError.message("RecordStudio needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app.") }

        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        /// The whole display, leaving out this app's windows (the HUD, the bar) and, when asked, the desktop icons.
        func displayFilter(_ d: SCDisplay) -> SCContentFilter { Self.filter(d, content, hideDesktopIcons: hideDesktopIcons) }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let captureRect: CGRect // global points, for normalizing the cursor
        var recorded: SCDisplay? // the display, for display and area recordings

        func display(_ id: CGDirectDisplayID) throws -> SCDisplay {
            guard let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw StudioError.message("No display to record.") }
            return d
        }
        switch source {
        case .display(let id):
            let d = try display(id)
            filter = displayFilter(d)
            captureRect = d.frame
            recorded = d
        case .window(let wid):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw StudioError.message("That window has closed.") }
            filter = SCContentFilter(desktopIndependentWindow: w)
            captureRect = w.frame
        case .area(let id, let rect):
            let d = try display(id)
            filter = displayFilter(d)
            recorded = d
            config.sourceRect = rect.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY) // display-local points
            captureRect = rect
        }
        let scale = CGFloat(filter.pointPixelScale)
        let kind: String = { if case .window = source { return "window" }; if case .area = source { return "area" }; return "display" }()
        try JSONEncoder().encode(CaptureInfo(kind: kind, pointScale: Double(scale))).write(to: dir.appending(path: "capture.json"))
        config.width = Int((captureRect.width * scale).rounded(.down)) & ~1
        config.height = Int((captureRect.height * scale).rounded(.down)) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // The cursor is left out and redrawn in the editor, smoothed and resizable, when its shape can be read.
        let redraw = await MainActor.run { CursorTracker.snapshot(scale: Double(scale)) } != nil
        config.showsCursor = !redraw
        config.queueDepth = 6
        if let microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphone
        }

        self.filter = filter
        self.config = config
        cursor = CursorTracker(rect: captureRect, imageScale: redraw ? Double(scale) : nil, clock: clock,
                               isOwn: { CursorTracker.onOwnWindow($0, skipping: clickThrough) })
        keys = keystrokes && CGPreflightListenEventAccess() ? KeyTracker(clock: clock) : nil // without the permission: no keys, as usual

        if systemAudio {
            // Everything the Mac plays except this app, whatever part of the screen is recorded.
            let ac = SCStreamConfiguration()
            ac.capturesAudio = true
            ac.excludesCurrentProcessAudio = true
            ac.sampleRate = 48_000
            ac.channelCount = 2
            ac.width = 2 // the stream needs a video size; no frames are kept
            ac.height = 2
            ac.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            ac.showsCursor = false
            let writer = try SystemAudioWriter(url: dir.appending(path: "system.m4a"), clock: clock)
            let s = SCStream(filter: SCContentFilter(display: try display(CGMainDisplayID()), excludingApplications: ours, exceptingWindows: []),
                             configuration: ac, delegate: nil)
            try s.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            do { try await s.startCapture() }
            catch { throw StudioError.message("System audio couldn't be recorded: \(error.localizedDescription)") }
            audioStream = s
            self.systemAudio = writer
        }

        do {
            try await startPart()
        } catch {
            await stopSystemAudio(keep: false)
            throw error
        }
        if hideDesktopIcons, let recorded { watchExclusion(recorded.displayID) }
    }

    /// The filter for recording display `d`: this app is left out, and with `hideDesktopIcons` so are the desktop icons and widgets.
    static func filter(_ d: SCDisplay, _ content: SCShareableContent, hideDesktopIcons: Bool) -> SCContentFilter {
        let x = CaptureExclusion(content.windows.map(ScreenWindow.init), ownPID: ProcessInfo.processInfo.processIdentifier,
                                 hideDesktopIcons: hideDesktopIcons)
        return SCContentFilter(display: d, excludingApplications: content.applications.filter { x.apps.contains($0.processID) },
                               exceptingWindows: content.windows.filter { x.keep.contains($0.windowID) })
    }

    /// Finder and Notification Center are left out but for the windows they had when the filter was made, so one opened
    /// since would be missing. Every second, while recording, the filter is made again when their windows have changed.
    // ponytail: polling; a newly opened Finder window or notification banner can be missing for up to a second.
    private func watchExclusion(_ displayID: CGDirectDisplayID) {
        exclusionWatch = Task { [weak self] in
            var last: CaptureExclusion?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard !Task.isCancelled, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let d = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { continue }
                let x = CaptureExclusion(content.windows.map(ScreenWindow.init), ownPID: ProcessInfo.processInfo.processIdentifier, hideDesktopIcons: true)
                guard x != last else { continue }
                let first = last == nil
                last = x
                if first { continue } // the filter was just made from the same windows
                let filter = Self.filter(d, content, hideDesktopIcons: true)
                self.filter = filter // for the next part, after a pause
                try? await self.stream?.updateContentFilter(filter)
            }
        }
    }

    /// Starts a stream writing the screen and microphone to the next part: raw.mp4, then raw-2.mp4 after a pause, and
    /// so on. Returns once the part's first frame is written.
    private func startPart() async throws {
        guard let filter, let config else { throw StudioError.message("Not recording.") }
        parts += 1
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = dir.appending(path: Self.partName(parts))
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            started = c
            stream.startCapture { error in
                if let error { self.resumeStarted(throwing: error) }
            }
        }
        self.stream = stream
        self.output = output
    }

    /// Stops the stream and waits until its part is finalized.
    private func endPart(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            finished = c
            stream.stopCapture { error in
                if let error { self.resumeFinished(throwing: error) }
            }
        }
    }

    /// Stops writing until `resume`: the screen's part is closed, the camera pauses, and system audio, the cursor and
    /// shortcuts skip the time, so everything still lines up afterwards.
    public func pause() async throws {
        guard let stream, !isPaused else { return }
        isPaused = true
        clock.update { $0.pause(at: CACurrentMediaTime()) }
        camera?.pauseRecording()
        self.stream = nil
        output = nil
        try await endPart(stream)
    }

    /// Carries on into the same recording. The camera and the clock resume with the new part's first frame, so the
    /// time it takes the screen to start again is left out of everything.
    public func resume() async throws {
        guard isPaused, stream == nil else { return }
        try await startPart()
        isPaused = false
    }

    /// Stops, waits for the files to be finalized, joins the parts, writes cursor.json. Returns the recording folder.
    public func stop() async throws -> URL {
        guard stream != nil || isPaused else { throw StudioError.message("Not recording.") }
        exclusionWatch?.cancel()
        if let stream {
            do {
                try await endPart(stream)
            } catch {
                await stopSystemAudio(keep: true)
                throw error
            }
        }
        self.stream = nil
        await stopSystemAudio(keep: true)
        let (samples, images) = cursor?.stop() ?? ([], [])
        try JSONEncoder().encode(samples).write(to: dir.appending(path: "cursor.json"))
        if !images.isEmpty { try JSONEncoder().encode(images).write(to: dir.appending(path: "cursors.json")) }
        if let pressed = keys?.stop(), !pressed.isEmpty { try JSONEncoder().encode(pressed).write(to: dir.appending(path: "keys.json")) }
        if let camera {
            try await camera.stopRecording()
            if let c = cameraStart, let s = screenStart {
                try JSONEncoder().encode(CameraSync(offset: c - s)).write(to: dir.appending(path: "camera.json"))
            }
        }
        try await Self.joinParts(in: dir)
        return dir
    }

    static func partName(_ n: Int) -> String { n == 1 ? "raw.mp4" : "raw-\(n).mp4" }

    /// Joins the parts a paused recording was written in (raw.mp4, raw-2.mp4, …) end to end into raw.mp4, without
    /// re-encoding, and removes them. Does nothing for a recording that was never paused.
    public static func joinParts(in dir: URL) async throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let parts = names.compactMap { name -> (Int, URL)? in
            if name == "raw.mp4" { return (1, dir.appending(path: name)) }
            guard name.hasPrefix("raw-"), name.hasSuffix(".mp4"), let n = Int(name.dropFirst(4).dropLast(4)), n > 1 else { return nil }
            return (n, dir.appending(path: name))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        guard parts.count > 1 else { return }
        let joined = dir.appending(path: ".joined.mp4")
        try? FileManager.default.removeItem(at: joined)
        try await join(parts, into: joined)
        for part in parts { try FileManager.default.removeItem(at: part) }
        try FileManager.default.moveItem(at: joined, to: dir.appending(path: "raw.mp4"))
    }

    /// Writes `parts` one after another into `out`, each starting where the one before's picture ends. Every track
    /// keeps its place within its part, so a microphone that starts a moment after the picture stays in sync. Sound
    /// that runs past its part's picture is cut there: starting the next part after it would leave a gap in the video
    /// (an empty edit, with no frame to draw) and push the picture after each pause out of step with the cursor. A part
    /// that can't be read (cut short by a crash) is left out rather than losing the rest.
    static func join(_ parts: [URL], into out: URL) async throws {
        let comp = AVMutableComposition()
        var video: AVMutableCompositionTrack?, audio: [AVMutableCompositionTrack] = []
        var at = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let pictures = try? await asset.loadTracks(withMediaType: .video), let picture = pictures.first,
                  let length = try? await picture.load(.timeRange).end, length > .zero,
                  let sounds = try? await asset.loadTracks(withMediaType: .audio) else { continue }
            func place(_ track: AVAssetTrack, into t: AVMutableCompositionTrack) async throws {
                let range = try await track.load(.timeRange).intersection(CMTimeRange(start: .zero, end: length))
                guard range.duration > .zero else { return }
                try t.insertTimeRange(range, of: track, at: at + range.start)
            }
            if video == nil {
                video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                video?.preferredTransform = try await picture.load(.preferredTransform)
            }
            if let video { try await place(picture, into: video) }
            for (i, sound) in sounds.enumerated() {
                if i == audio.count, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { audio.append(t) }
                if audio.indices.contains(i) { try await place(sound, into: audio[i]) }
            }
            at = at + length
        }
        guard video != nil else { throw StudioError.message("The recording's parts couldn't be read.") }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw StudioError.message("The recording's parts couldn't be joined.")
        }
        try await session.export(to: out, as: .mp4)
    }

    /// Stops the system audio stream and closes its file, writing system.json beside it when `keep` is set.
    private func stopSystemAudio(keep: Bool) async {
        guard let audioStream, let systemAudio else { return }
        self.audioStream = nil
        self.systemAudio = nil
        try? await audioStream.stopCapture()
        // A file with nothing in it is removed, so the editor shows no system audio.
        let first = await systemAudio.finish()
        if keep, let first, let s = screenStart {
            try? JSONEncoder().encode(CameraSync(offset: first - s)).write(to: dir.appending(path: "system.json"))
        } else {
            try? FileManager.default.removeItem(at: dir.appending(path: "system.m4a"))
        }
    }

    /// Recording time so far, not counting pauses. It stands still while paused.
    public var elapsed: TimeInterval { clock.read { $0.elapsed(at: CACurrentMediaTime()) } }

    // MARK: delegates

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let now = CACurrentMediaTime()
        if screenStart == nil {
            startedAt = Date()
            screenStart = now
            clock.update { $0.begin(at: now) } // t = 0 is the first recorded frame
            cursor?.start()
            keys?.start()
        } else {
            clock.update { $0.resume(at: now) } // a part after a pause
            camera?.resumeRecording()
        }
        resumeStarted(throwing: nil)
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resumeFinished(throwing: nil)
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resumeStarted(throwing: error)
        resumeFinished(throwing: error)
        onError?(error)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        resumeStarted(throwing: error)
        resumeFinished(throwing: error)
        onError?(error)
    }

    private let lock = NSLock()
    private func resumeStarted(throwing error: Error?) {
        lock.lock(); let c = started; started = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
    private func resumeFinished(throwing error: Error?) {
        lock.lock(); let c = finished; finished = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}

/// Writes system audio sample buffers to an AAC file as they arrive.
final class SystemAudioWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "RecordStudio.systemAudio")
    private let url: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var first: Double? // host time of the first sample
    private var hostOffset = 0.0 // host time minus sample time, 0 when samples are on the host clock
    private let clock: SharedClock

    init(url: URL, clock: SharedClock) throws {
        self.url = url
        self.clock = clock
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, sample.numSamples > 0 else { return }
        if input == nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ], sourceFormatHint: sample.formatDescription)
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { return }
            writer.add(i)
            guard writer.startWriting() else { return }
            let pts = sample.presentationTimeStamp
            writer.startSession(atSourceTime: pts)
            input = i
            // Sample times are on the host clock, like CACurrentMediaTime(). If they ever aren't, use the arrival time.
            let now = CACurrentMediaTime()
            first = abs(pts.seconds - now) < 1 ? pts.seconds : now - sample.duration.seconds
            hostOffset = (first ?? pts.seconds) - pts.seconds
        }
        // Sound played while paused is left out, and what follows moves up to close the gap.
        let host = sample.presentationTimeStamp.seconds + hostOffset, timing = clock.read { $0 }
        guard !timing.isPaused(at: host) else { return }
        let gap = timing.pausedTime(before: host)
        guard let input, input.isReadyForMoreMediaData, let out = gap > 0 ? Self.shifted(sample, back: gap) : sample else { return }
        input.append(out)
    }

    /// The same sound, `seconds` earlier.
    static func shifted(_ sample: CMSampleBuffer, back seconds: Double) -> CMSampleBuffer? {
        let delta = CMTime(seconds: seconds, preferredTimescale: 48_000)
        guard var timing = try? sample.sampleTimingInfos() else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - delta
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - delta }
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timing)
    }

    /// Closes the file. Returns when its first sample was captured, or nil (and removes the file) if nothing was written.
    func finish() async -> Double? {
        let (input, first): (AVAssetWriterInput?, Double?) = queue.sync { (self.input, self.first) }
        guard let input, let first, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return first
    }
}

/// One `RecordingClock` for the recorder and the trackers and writer it feeds, which read it from their own threads.
final class SharedClock: Sendable {
    private let clock = Mutex(RecordingClock())
    func read<T: Sendable>(_ body: (RecordingClock) -> T) -> T { clock.withLock { body($0) } }
    func update(_ body: (inout RecordingClock) -> Void) { clock.withLock { body(&$0) } }
}

/// What was captured, saved next to the recording. Window recordings get their rounded corners masked.
/// A window as ScreenCaptureKit lists it, reduced to what decides whether a recording shows it.
public struct ScreenWindow: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    public var bundleID: String?
    public var layer: Int
    public init(id: CGWindowID, pid: pid_t, bundleID: String?, layer: Int) { (self.id, self.pid, self.bundleID, self.layer) = (id, pid, bundleID, layer) }
    init(_ w: SCWindow) {
        self.init(id: w.windowID, pid: w.owningApplication?.processID ?? 0, bundleID: w.owningApplication?.bundleIdentifier, layer: w.windowLayer)
    }
}

/// What a display or area recording leaves out, in the shape `SCContentFilter(display:excludingApplications:exceptingWindows:)`
/// takes: whole apps, except some of their windows. This app always (its HUD and bar, even ones opened later). With
/// `hideDesktopIcons`, Finder and Notification Center too, except their ordinary windows: Finder draws the desktop's
/// files and folders, and Notification Center each desktop widget, in windows below every other (layer < 0), so that's
/// all that's left out. The wallpaper (drawn by the Dock), notification banners and every window still show, and
/// nothing on the screen itself changes.
public struct CaptureExclusion: Equatable, Sendable {
    public var apps: Set<pid_t>
    public var keep: Set<CGWindowID>

    public init(_ windows: [ScreenWindow], ownPID: pid_t, hideDesktopIcons: Bool) {
        apps = [ownPID]
        keep = []
        guard hideDesktopIcons else { return }
        for id in ["com.apple.finder", "com.apple.notificationcenterui"] {
            let app = windows.filter { $0.bundleID == id }
            guard let desktop = app.first(where: { $0.layer < 0 }) else { continue }
            apps.insert(desktop.pid)
            keep.formUnion(app.filter { $0.layer >= 0 }.map(\.id))
        }
    }

    /// Where the record bar's switch is kept.
    public static let defaultsKey = "hideDesktopIcons"

    /// The switch as set, on when it never has been.
    public static func hidesDesktopIcons(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: defaultsKey) as? Bool ?? true }

    /// Whether the recording shows `w`.
    public func shows(_ w: ScreenWindow) -> Bool { !apps.contains(w.pid) || keep.contains(w.id) }
}

public struct CaptureInfo: Codable, Sendable {
    public var kind: String          // "display", "window" or "area"
    public var pointScale: Double    // pixels per point at capture time
    public var isWindow: Bool { kind == "window" }
}

/// Polls the cursor at 60 Hz. Needs no permission: position from CoreGraphics, buttons from NSEvent.
/// With `imageScale` it also reads the cursor's shape 10 times a second, keeping each shape once.
/// Keyboard shortcuts pressed while recording, from a listen-only event tap (it can't change or block a key). Every
/// press is checked with `shortcutPress` as it arrives, so ordinary typing is never kept, not even in memory.
final class KeyTracker: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed: [ShortcutPress] = []
    private let clock: SharedClock
    private let lock = NSLock()

    init(clock: SharedClock) { self.clock = clock }

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: { _, type, event, info in
            if type == .keyDown, let info { Unmanaged<KeyTracker>.fromOpaque(info).takeUnretainedValue().note(event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { return } // not allowed after all: record without keys
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func note(_ e: CGEvent) {
        guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return } // a held shortcut counts once
        guard let t = clock.read({ $0.time(at: CACurrentMediaTime()) }) else { return } // paused: nothing is recorded
        let f = e.flags
        var length = 0, chars = [UniChar](repeating: 0, count: 4)
        // What the key types with no modifiers held, so ⌥4 shows as 4 rather than ¢.
        let plain = e.copy()
        plain?.flags = []
        plain?.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard let k = shortcutPress(t: t, keyCode: Int(e.getIntegerValueField(.keyboardEventKeycode)),
                                    characters: String(utf16CodeUnits: chars, count: length), command: f.contains(.maskCommand),
                                    control: f.contains(.maskControl), option: f.contains(.maskAlternate), shift: f.contains(.maskShift)) else { return }
        lock.lock(); pressed.append(k); lock.unlock()
    }

    func stop() -> [ShortcutPress] {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        (tap, source) = (nil, nil)
        lock.lock(); defer { lock.unlock() }
        return pressed
    }
}

final class CursorTracker: @unchecked Sendable {
    private let rect: CGRect
    private let imageScale: Double?
    private var samples: [CursorSample] = []
    private var images: [CursorImage] = []
    private var shape: Int?, lastShape: Int?
    private var timers: [DispatchSourceTimer] = []
    private let clock: SharedClock
    private let lock = NSLock()
    /// Whether a point (global, top-left origin) is on one of this app's windows: the pill, camera bubble, teleprompter.
    private let isOwn: @Sendable (CGPoint) -> Bool
    private var wasDown = false, ownPress = false

    init(rect: CGRect, imageScale: Double?, clock: SharedClock, isOwn: @escaping @Sendable (CGPoint) -> Bool = { CursorTracker.onOwnWindow($0) }) {
        (self.rect, self.imageScale, self.clock, self.isOwn) = (rect, imageScale, clock, isOwn)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        timers = [timer]
        if let scale = imageScale {
            // AppKit, so on the main thread. Frames before the first read use the first shape.
            let shapes = DispatchSource.makeTimerSource(queue: .main)
            shapes.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            shapes.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readShape(scale) } }
            timers.append(shapes)
        }
        timers.forEach { $0.resume() }
    }

    // ponytail: re-encodes the shape on every read to compare it; cache by NSCursor identity if this ever shows in a profile.
    @MainActor private func readShape(_ scale: Double) {
        guard let img = Self.snapshot(scale: scale) else { return }
        lock.lock(); defer { lock.unlock() }
        if let i = images.firstIndex(of: img) { shape = i } else { images.append(img); shape = images.count - 1 }
    }

    private func sample() {
        // Not sampled while paused; a shape that changed meanwhile is noted with the first sample after.
        guard let t = clock.read({ $0.time(at: CACurrentMediaTime()) }), let p = CGEvent(source: nil)?.location else { return }
        add(t: t, p: p, down: NSEvent.pressedMouseButtons & 1 != 0)
    }

    func add(t: Double, p: CGPoint, down: Bool) {
        // A press on our own pill (Pause, Resume, Stop) or panels isn't in the video, so it's no click and makes no zoom.
        lock.lock(); defer { lock.unlock() }
        if down && !wasDown { ownPress = isOwn(p) }
        wasDown = down
        let changed = shape != lastShape
        lastShape = shape
        samples.append(CursorSample(t: t, x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height,
                                    down: down && !ownPress, image: changed ? shape : nil))
    }

    /// Asked only when a press starts, so the window list is read a few times per recording. Windows in `skipping` let
    /// clicks through to the app below (the window list can't tell), so a press on them isn't on us.
    static func onOwnWindow(_ p: CGPoint, skipping: Set<CGWindowID> = [], me: pid_t = ProcessInfo.processInfo.processIdentifier,
                            windows: [[String: Any]] = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []) -> Bool {
        windows.contains { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == me, let n = w[kCGWindowNumber as String] as? CGWindowID, !skipping.contains(n),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b) else { return false }
            return frame.contains(p)
        }
    }

    func stop() -> ([CursorSample], [CursorImage]) {
        timers.forEach { $0.cancel() }
        timers = []
        lock.lock(); defer { lock.unlock() }
        return (samples, images)
    }

    /// The system cursor's current shape, drawn at `scale` pixels per point, with its hotspot in those pixels.
    /// `currentSystem` is slated for deprecation, but it's the only way to read another app's cursor.
    @MainActor static func snapshot(scale: Double) -> CursorImage? {
        guard let c = NSCursor.currentSystem else { return nil }
        let w = Int((c.image.size.width * scale).rounded()), h = Int((c.image.size.height * scale).rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                       bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        c.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return CursorImage(png: png, hotX: c.hotSpot.x * scale, hotY: c.hotSpot.y * scale)
    }
}

/// Windows you can pick, front to back, in global points (top-left origin). Our own windows are left out.
public struct PickableWindow: Identifiable, Sendable {
    public var id: CGWindowID, app: String, title: String, frame: CGRect
    public var pid: pid_t
}

public enum Shareable {
    public static func windows() async throws -> [PickableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        // CGWindowList is ordered front to back; SCShareableContent isn't.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        return order.compactMap { byID[$0] }.filter { w in
            w.windowLayer == 0 && w.frame.width > 60 && w.frame.height > 60 && w.owningApplication?.processID != me && w.isOnScreen
        }.map {
            PickableWindow(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "", frame: $0.frame,
                           pid: $0.owningApplication?.processID ?? 0)
        }
    }
}
