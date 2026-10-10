import AVFoundation
import Foundation
import Testing
@testable import RecordCore
@testable import RecordKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct PausedRecordingFiles {
    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The colour in the top-right corner of the frame at `t`, away from the test movie's moving square.
    func corner(_ url: URL, at t: Double) async throws -> (r: Int, g: Int, b: Int) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let image = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let pixel = try #require(image.cropping(to: CGRect(x: image.width - 20, y: 20, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    @Test func pressesOnOurOwnPillAreNoClicks() {
        // The pill sits at x < 100; a press there (Pause, Stop) stays unpressed, the press in the recording counts.
        let tracker = CursorTracker(rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), imageScale: nil, clock: SharedClock(), isOwn: { $0.x < 100 })
        for (t, x, down) in [(0.0, 500.0, false), (0.1, 500, true), (0.2, 500, false), (0.3, 50, true), (0.4, 600, true), (0.5, 50, false)] {
            tracker.add(t: t, p: CGPoint(x: x, y: 500), down: down)
        }
        #expect(clickTimes(tracker.stop().0) == [0.1])
    }

    @Test func pressesThroughTheClickThroughDimAreClicks() {
        // Our full-screen dim (window 7) lets clicks through; the pill (window 8) doesn't. Another app's window is never ours.
        func window(_ n: Int, pid: pid_t, _ frame: CGRect) -> [String: Any] {
            // NSNumbers, as in the real window list.
            [kCGWindowNumber as String: NSNumber(value: n), kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let windows = [window(8, pid: 1, CGRect(x: 0, y: 0, width: 100, height: 40)),
                       window(7, pid: 1, CGRect(x: 0, y: 0, width: 1000, height: 1000)),
                       window(9, pid: 2, CGRect(x: 0, y: 0, width: 1000, height: 1000))]
        #expect(!CursorTracker.onOwnWindow(CGPoint(x: 500, y: 500), skipping: [7], me: 1, windows: windows))
        #expect(CursorTracker.onOwnWindow(CGPoint(x: 50, y: 20), skipping: [7], me: 1, windows: windows))
        #expect(CursorTracker.onOwnWindow(CGPoint(x: 500, y: 500), skipping: [], me: 1, windows: windows))
    }

    @Test func joinsThePartsOfAPausedRecordingIntoOneFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Recorded for 2 seconds, paused, then 1 more second: written as two parts, red and then blue.
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 2, solid: (1, 0, 0))
        try await synthesizeMovie(dir.appending(path: "raw-2.mp4"), seconds: 1, solid: (0, 0, 1))
        try await Recorder.joinParts(in: dir)

        let raw = dir.appending(path: "raw.mp4")
        let info = try await Probe.movie(raw)
        #expect(abs(info.duration - 3) < 0.1 && info.hasAudio)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["raw.mp4"])
        // The second part follows straight on from the first, with no gap.
        let before = try await corner(raw, at: 1.5), after = try await corner(raw, at: 2.5)
        #expect(before.r > 200 && before.b < 60)
        #expect(after.b > 200 && after.r < 60)
        // The sound runs the whole length, like the picture.
        let sound = try #require(try await AVURLAsset(url: raw).loadTracks(withMediaType: .audio).first)
        let heard = try await sound.load(.timeRange).duration.seconds
        #expect(abs(heard - 3) < 0.1)
    }

    @Test func startsTheNextPartWhereThePictureEndsWhenTheSoundRunsOn() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Like ScreenCaptureKit's parts: the sound runs 0.1 s past the last frame of 2 s of picture.
        let red = dir.appending(path: "red.mp4"), tone = dir.appending(path: "tone.mp4")
        try await synthesizeMovie(red, seconds: 2, solid: (1, 0, 0))
        try await synthesizeMovie(tone, seconds: 3)
        let (picture, sound) = (AVURLAsset(url: red), AVURLAsset(url: tone)) // kept: a track doesn't keep its asset alive
        let comp = AVMutableComposition()
        let v = try #require(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let a = try #require(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let seconds = { (s: Double) in CMTime(seconds: s, preferredTimescale: 600) }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: seconds(2)), of: try #require(try await picture.loadTracks(withMediaType: .video).first), at: .zero)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: seconds(2.1)), of: try #require(try await sound.loadTracks(withMediaType: .audio).first), at: .zero)
        let session = try #require(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: dir.appending(path: "raw.mp4"), as: .mp4)
        withExtendedLifetime((picture, sound)) {}
        for f in [red, tone] { try FileManager.default.removeItem(at: f) }
        try await synthesizeMovie(dir.appending(path: "raw-2.mp4"), seconds: 1, solid: (0, 0, 1))
        try await Recorder.joinParts(in: dir)

        let raw = dir.appending(path: "raw.mp4")
        let track = try #require(try await AVURLAsset(url: raw).loadTracks(withMediaType: .video).first)
        // No empty stretch in the picture, and the second part starts right at 2 s.
        #expect(try await track.load(.segments).allSatisfy { !$0.isEmpty })
        let before = try await corner(raw, at: 1.98), after = try await corner(raw, at: 2.02)
        #expect(before.r > 200 && before.b < 60)
        #expect(after.b > 200 && after.r < 60)
        #expect(abs(try await Probe.movie(raw).duration - 3) < 0.05)
    }

    @Test func leavesARecordingThatWasNeverPausedAsItIs() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appending(path: "raw.mp4")
        try await synthesizeMovie(raw, seconds: 1)
        let written = try FileManager.default.attributesOfItem(atPath: raw.path)[.modificationDate] as? Date
        try await Recorder.joinParts(in: dir)
        #expect(try FileManager.default.attributesOfItem(atPath: raw.path)[.modificationDate] as? Date == written)
    }

    @Test func namesThePartsInOrder() {
        #expect((1...3).map(Recorder.partName) == ["raw.mp4", "raw-2.mp4", "raw-3.mp4"])
    }
}

@Suite struct DesktopIcons {
    // Finder's desktop icons, a Finder window, the Dock's wallpaper, another app's window, this app's HUD, and
    // Notification Center's desktop widget and a banner.
    let windows = [ScreenWindow(id: 1, pid: 10, bundleID: "com.apple.finder", layer: Int(CGWindowLevelForKey(.desktopIconWindow))),
                   ScreenWindow(id: 2, pid: 10, bundleID: "com.apple.finder", layer: 0),
                   ScreenWindow(id: 3, pid: 20, bundleID: "com.apple.dock", layer: Int(CGWindowLevelForKey(.desktopWindow))),
                   ScreenWindow(id: 4, pid: 30, bundleID: "com.apple.Safari", layer: 0),
                   ScreenWindow(id: 5, pid: 99, bundleID: "com.kasapovic.RecordStudio", layer: 25),
                   ScreenWindow(id: 6, pid: 40, bundleID: "com.apple.notificationcenterui", layer: -2147483601),
                   ScreenWindow(id: 7, pid: 40, bundleID: "com.apple.notificationcenterui", layer: 23)]

    func shown(_ hide: Bool) -> [CGWindowID] {
        let x = CaptureExclusion(windows, ownPID: 99, hideDesktopIcons: hide)
        return windows.filter(x.shows).map(\.id)
    }

    @Test func leavesOutOnlyTheDesktopIconsAndWidgetsWhenOnAndOnByDefault() throws {
        #expect(shown(true) == [2, 3, 4, 7])
        #expect(shown(false) == [1, 2, 3, 4, 6, 7])
        let defaults = try #require(UserDefaults(suiteName: "DesktopIcons-\(UUID().uuidString)"))
        #expect(CaptureExclusion.hidesDesktopIcons(defaults)) // never set
        defaults.set(false, forKey: CaptureExclusion.defaultsKey)
        #expect(!CaptureExclusion.hidesDesktopIcons(defaults))
        // With nothing on the desktop Finder has no icon window, and nothing of Finder's is left out.
        let x = CaptureExclusion(Array(windows.dropFirst().filter { $0.id != 6 }), ownPID: 99, hideDesktopIcons: true)
        #expect(x.apps == [99] && x.keep.isEmpty)
        // Widgets but no icons: only Notification Center's widget is left out.
        let widgets = CaptureExclusion(Array(windows.dropFirst()), ownPID: 99, hideDesktopIcons: true)
        #expect(widgets.apps == [99, 40] && widgets.keep == [7])
    }
}

@Suite struct Notes {
    @Test func savesReloadsAndKeepsTheNotesWithTheRecording() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SpeakerNotes.load(root: root) == "")
        try SpeakerNotes.save("# Intro\nHi, I'm **Halid**.", root: root)
        #expect(SpeakerNotes.load(root: root) == "# Intro\nHi, I'm **Halid**.") // kept for the next recording
        let recording = root.appending(path: "recordings/1")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try SpeakerNotes.keep(SpeakerNotes.load(root: root), in: recording)
        #expect(try String(contentsOf: recording.appending(path: SpeakerNotes.fileName), encoding: .utf8).hasPrefix("# Intro"))
        try SpeakerNotes.save("  \n", root: root)
        #expect(SpeakerNotes.load(root: root) == "")
        #expect(FileManager.default.fileExists(atPath: recording.appending(path: SpeakerNotes.fileName).path)) // the recording keeps its copy
    }
}
