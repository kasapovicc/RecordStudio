import Foundation
import Testing
@testable import RecordCore
@testable import RecordKit

@Suite struct LooksTests {
    /// A look carries the appearance from one recording to another and leaves the other's own edits alone.
    @Test func appliesAppearanceOnly() {
        var mine = defaultEdits(duration: 20, cursor: [], hasCamera: true)
        mine.padding = 0.15; mine.backgroundImage = "/tmp/wall.heic"; mine.clickEffect = nil
        mine.camera?.size = 0.4; mine.camera?.corner = .topLeft
        mine.micCleanup = MicCleanup(); mine.micCleanup?.normalize = true
        var captions = Captions(lines: []); captions.style = .outline
        mine.captions = captions
        let look = Look(name: "Channel", from: mine)

        var other = defaultEdits(duration: 8, cursor: [], hasCamera: true)
        other.zooms = [Zoom(start: 1, end: 2, scale: 2)]
        other.camera?.visible = false
        other.captions = Captions(lines: [CaptionLine("hi", start: 0, end: 1)])
        let applied = other.withLook(of: look.edits)
        #expect(applied.padding == 0.15 && applied.backgroundImage == "/tmp/wall.heic" && applied.clickEffect == nil)
        #expect(applied.camera?.size == 0.4 && applied.camera?.corner == .topLeft && applied.camera?.visible == false)
        #expect(applied.captions?.style == .outline && applied.captions?.lines.count == 1)
        #expect(applied.micCleanup?.normalize == true)
        #expect(applied.trim == other.trim && applied.zooms == other.zooms)

        // A recording without a webcam doesn't get one.
        #expect(defaultEdits(duration: 8, cursor: []).withLook(of: look.edits).camera == nil)

        var looks = Looks()
        looks.save("Channel", from: mine)
        #expect(looks.current(applied)?.name == "Channel" && looks.current(other) == nil)
    }

    @Test func savesAndStartsNewRecordingsWithTheChosenLook() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-looks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Looks.load(root: root) == Looks()) // no file yet

        var e = Edits(trim: Trim(start: 0, end: 1))
        e.padding = 0.2
        var looks = Looks()
        looks.save("Wide", from: e)
        looks.forNew = "Wide"
        try looks.save(root: root)
        let back = Looks.load(root: root)
        #expect(back == looks)

        let rec = Recording(id: "1", title: "Take", createdAt: 0, dir: root.path, duration: 4, width: 640, height: 400, fps: 30, hasAudio: true)
        #expect(rec.startingEdits(cursor: [], looks: back).padding == 0.2)
        #expect(rec.startingEdits(cursor: [], looks: Looks()).padding == 0.06)

        // Deleting the look new recordings use goes back to the built-in default.
        looks.delete("Wide")
        #expect(looks.all.isEmpty && looks.forNew == nil)
    }
}
