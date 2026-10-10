import AVFoundation
import Foundation
import RecordCore
import SQLite3

public struct ExportRow: Equatable, Sendable {
    public var path: String, preset: String, createdAt: Int64
}

public struct Recording: Identifiable, Equatable, Sendable {
    public var id: String, title: String, createdAt: Int64, dir: String
    public var duration: Double, width: Int, height: Int, fps: Double, hasAudio: Bool
    public var edits: String?
    public var exports: [ExportRow] = []
    public var editedAt: Int64 = 0      // when the edits or title last changed, ms; the creation time until then
    public var path: String { dir + "/raw.mp4" }
    /// Whether the movie is gone, deleted in Finder or on a drive that isn't connected. Checked each time, so the
    /// recording works again when the files come back.
    public var isMissing: Bool { !FileManager.default.fileExists(atPath: path) }
    /// The newest export whose file is still there; nil when there is none.
    public var latestExport: ExportRow? { exports.first { FileManager.default.fileExists(atPath: $0.path) } }
    public var cursorPath: String { dir + "/cursor.json" }
    /// The cursor's shapes, for recordings made with it left out of the video; empty for older ones.
    public var cursorImages: [CursorImage] {
        FileManager.default.contents(atPath: dir + "/cursors.json").flatMap { try? JSONDecoder().decode([CursorImage].self, from: $0) } ?? []
    }
    /// Shortcuts pressed while recording, when they were captured; empty otherwise.
    public var keys: [ShortcutPress] {
        FileManager.default.contents(atPath: dir + "/keys.json").flatMap { try? JSONDecoder().decode([ShortcutPress].self, from: $0) } ?? []
    }
    /// The latest export as the library tile shows it, "Exported MP4 · 2 hours ago"; nil when there is none.
    public func exportSummary(now: Date = .now) -> String? {
        guard let x = latestExport else { return nil }
        let format = ExportFormat(rawValue: x.preset)?.label ?? x.preset.uppercased()
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        return "Exported \(format) · \(f.localizedString(for: Date(timeIntervalSince1970: Double(x.createdAt) / 1000), relativeTo: now))"
    }
    /// Whether the title has `query` in it, ignoring case and accents.
    public func titleMatches(_ query: String) -> Bool { title.localizedStandardContains(query) }
    /// The first caption line with `query` in it, so a search finds what's said; nil without captions or a match.
    /// ponytail: decodes the edits on every search; cache the caption text if libraries grow to hundreds.
    public func spokenMatch(_ query: String) -> String? {
        guard let edits, let e = try? JSONDecoder().decode(Edits.self, from: Data(edits.utf8)) else { return nil }
        return e.captions?.lines.first { $0.text.localizedStandardContains(query) }?.text
    }
    /// Bytes the recording's folder takes: the movie, camera, system audio and the rest.
    public var diskSize: Int64 {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).reduce(0) {
            $0 + ((try? fm.attributesOfItem(atPath: dir + "/" + $1)[.size] as? Int64) ?? 0)
        }
    }
    public var cameraPath: String { dir + "/camera.mov" }
    public var hasCamera: Bool { FileManager.default.fileExists(atPath: cameraPath) }
    public var capture: CaptureInfo? {
        FileManager.default.contents(atPath: dir + "/capture.json").flatMap { try? JSONDecoder().decode(CaptureInfo.self, from: $0) }
    }
    /// For window recordings: the window's own corner radius in source pixels.
    public var windowCornerPx: Double? { capture.flatMap { $0.isWindow ? macWindowCornerPoints * $0.pointScale : nil } }
    /// Seconds into the screen recording at which the camera file starts.
    public var cameraOffset: Double {
        FileManager.default.contents(atPath: dir + "/camera.json").flatMap { try? JSONDecoder().decode(CameraSync.self, from: $0) }?.offset ?? 0
    }
    /// Sound from other apps, recorded to its own file so it can be balanced against the microphone.
    public var systemAudioPath: String { dir + "/system.m4a" }
    public var hasSystemAudio: Bool { FileManager.default.fileExists(atPath: systemAudioPath) }
    /// Seconds into the screen recording at which the system audio file starts.
    public var systemAudioOffset: Double {
        FileManager.default.contents(atPath: dir + "/system.json").flatMap { try? JSONDecoder().decode(CameraSync.self, from: $0) }?.offset ?? 0
    }
    /// The pointer's recorded positions; empty when there are none.
    public var cursorSamples: [CursorSample] {
        FileManager.default.contents(atPath: cursorPath).flatMap { try? JSONDecoder().decode([CursorSample].self, from: $0) } ?? []
    }
    /// The edits a recording starts with before it's edited: the look chosen for new recordings, or the built-in
    /// default, where window recordings get the window's own corners.
    public func startingEdits(cursor: [CursorSample], looks: Looks = .load()) -> Edits {
        let corners = capture.flatMap { $0.isWindow ? windowCornerFraction(width: width, height: height, crop: .full, pointScale: $0.pointScale) : nil }
        let e = defaultEdits(duration: duration, cursor: cursor, hasCamera: hasCamera, cornerRadius: corners)
        return looks.forNewLook.map { e.withLook(of: $0.edits) } ?? e
    }
    /// The name a library export saves this recording under in `folder`: its title, or "title 2"… when its file (or
    /// folder, with extras) is already there and isn't this recording's own export, or is `taken` by another export's
    /// video in the same batch.
    public func exportName(folder: String, format: ExportFormat, extras: ExportExtras, taken: [String]) -> String {
        let own = Set(exports.map(\.path)), dir = URL(fileURLWithPath: folder)
        return keepBothName(exportFileName(title)) {
            let video = ExportJob.video(outDir: dir, name: $0, format: format, extras: extras).path
            let place = ExportJob.place(outDir: dir, name: $0, format: format, extras: extras).path
            return taken.contains(video) || (!own.contains(video) && FileManager.default.fileExists(atPath: place))
        }
    }
    /// The edits as the editor opens them: the saved ones, or the starting ones when there are none. Throws when the
    /// saved ones can't be read.
    public func openingEdits(cursor: [CursorSample]) throws -> Edits {
        guard let edits else { return startingEdits(cursor: cursor) }
        var e = try JSONDecoder().decode(Edits.self, from: Data(edits.utf8))
        if hasCamera, e.camera == nil { e.camera = CameraStyle() }
        e.splitAtSpeedChanges() // speed is set per piece of the clip; older edits had it on a lane of its own
        return e
    }
}

/// How the library orders recordings: newest first by date, A to Z by title, longest first by length.
public enum LibrarySort: String, CaseIterable, Sendable {
    case created = "Date Created", edited = "Date Edited", title = "Title", length = "Length"

    public func sorted(_ recs: [Recording]) -> [Recording] {
        switch self {
        case .created: recs.sorted { $0.createdAt > $1.createdAt }
        case .edited: recs.sorted { $0.editedAt > $1.editedAt }
        case .title: recs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .length: recs.sorted { $0.duration > $1.duration }
        }
    }
}

public enum StudioError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Where everything lives. `RECORD_STUDIO_DIR` overrides the default ~/Movies/RecordStudio.
public enum Paths {
    public static var data: URL {
        if let d = ProcessInfo.processInfo.environment["RECORD_STUDIO_DIR"], !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/RecordStudio")
    }
    /// Where earlier versions kept the library.
    public static var legacy: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Record Studio") }
    public static var recordings: URL { data.appending(path: "recordings") }
    public static var exports: URL { data.appending(path: "exports") }
    public static var backgrounds: URL { data.appending(path: "backgrounds") }
    public static var images: URL { data.appending(path: "images") } // pictures placed on the video as annotations

    /// Only touch files inside the data folder (or system wallpapers, read-only).
    public static func inside(_ path: String, root: URL = data) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return path.hasPrefix("/") && !path.contains("/../") && (p == root.path || p.hasPrefix(root.standardizedFileURL.path + "/"))
    }
}

/// SQLite library: same schema as the Tauri version. ponytail: one connection guarded by a lock; this is a single-user app.
public final class Library: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let root: URL

    public init(root: URL = Paths.data) throws {
        self.root = root
        let fm = FileManager.default
        let moved = root == Paths.data && ProcessInfo.processInfo.environment["RECORD_STUDIO_DIR"] == nil
            ? try Self.moveLegacyFolder(from: Paths.legacy, to: root) : false
        for d in ["recordings", "exports", "backgrounds", "images"] { try fm.createDirectory(at: root.appending(path: d), withIntermediateDirectories: true) }
        guard sqlite3_open(root.appending(path: "library.sqlite").path, &db) == SQLITE_OK else { throw StudioError.message("Couldn't open the library database.") }
        try exec("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS recordings(
              id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL, dir TEXT NOT NULL,
              duration REAL NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, fps REAL NOT NULL,
              has_audio INTEGER NOT NULL, edits TEXT);
            CREATE TABLE IF NOT EXISTS exports(
              id INTEGER PRIMARY KEY, recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
              path TEXT NOT NULL, preset TEXT NOT NULL, created_at INTEGER NOT NULL);
            """)
        // Added after the Tauri version: existing rows count as last edited when they were made.
        var hasEditedAt = false
        try run("SELECT 1 FROM pragma_table_info('recordings') WHERE name = 'edited_at'") { _ in hasEditedAt = true }
        if !hasEditedAt { try exec("ALTER TABLE recordings ADD COLUMN edited_at INTEGER; UPDATE recordings SET edited_at = created_at;") }
        if moved { try rewritePaths(from: Paths.legacy.path, to: root.path) }
    }

    /// One-time move of a library from its old folder. Only when the new folder doesn't exist yet,
    /// so nothing is ever overwritten.
    static func moveLegacyFolder(from old: URL, to new: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.appending(path: "library.sqlite").path), !fm.fileExists(atPath: new.path) else { return false }
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: new)
        return true
    }

    /// The database stores absolute paths (recording folders, exports, imported backgrounds inside edits).
    func rewritePaths(from old: String, to new: String) throws {
        let o = old.hasSuffix("/") ? old : old + "/", n = new.hasSuffix("/") ? new : new + "/"
        try run("UPDATE recordings SET dir = ?2 || substr(dir, length(?1) + 1) WHERE substr(dir, 1, length(?1)) = ?1", [o, n])
        try run("UPDATE recordings SET dir = ?2 WHERE dir = ?1", [old, new])
        try run("UPDATE exports SET path = ?2 || substr(path, length(?1) + 1) WHERE substr(path, 1, length(?1)) = ?1", [o, n])
        // Edits are JSON; paths in it are escaped the way JSONEncoder writes them ("/" as "\/").
        for (a, b) in [(o, n), (o.replacingOccurrences(of: "/", with: "\\/"), n.replacingOccurrences(of: "/", with: "\\/"))] {
            try run("UPDATE recordings SET edits = replace(edits, ?1, ?2) WHERE edits IS NOT NULL", [a, b])
        }
    }
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StudioError.message(String(cString: sqlite3_errmsg(db))) }
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Runs one statement; `bind` values are String, Int, Int64, Double, Bool or nil.
    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw StudioError.message(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(st, n, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as Bool: sqlite3_bind_int(st, n, v ? 1 : 0)
            default: sqlite3_bind_null(st, n)
            }
        }
        var rows = 0
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { rows += 1; row?(st!) } else if rc == SQLITE_DONE { break }
            else { throw StudioError.message(String(cString: sqlite3_errmsg(db))) }
        }
        return rows
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }

    public func list() throws -> [Recording] {
        var recs: [Recording] = []
        try run("SELECT id,title,created_at,dir,duration,width,height,fps,has_audio,edits,coalesce(edited_at,created_at) FROM recordings ORDER BY created_at DESC") { st in
            recs.append(Recording(
                id: self.text(st, 0) ?? "", title: self.text(st, 1) ?? "", createdAt: sqlite3_column_int64(st, 2), dir: self.text(st, 3) ?? "",
                duration: sqlite3_column_double(st, 4), width: Int(sqlite3_column_int64(st, 5)), height: Int(sqlite3_column_int64(st, 6)),
                fps: sqlite3_column_double(st, 7), hasAudio: sqlite3_column_int(st, 8) != 0, edits: self.text(st, 9), editedAt: sqlite3_column_int64(st, 10)))
        }
        for i in recs.indices {
            try run("SELECT path,preset,created_at FROM exports WHERE recording_id=?1 ORDER BY created_at DESC", [recs[i].id]) { st in
                recs[i].exports.append(ExportRow(path: self.text(st, 0) ?? "", preset: self.text(st, 1) ?? "", createdAt: sqlite3_column_int64(st, 2)))
            }
        }
        return recs
    }

    /// Probes the movie with AVFoundation and stores it.
    @discardableResult
    public func insert(id: String, title: String, dir: URL, createdAt: Int64? = nil) async throws -> Recording {
        let info = try await Probe.movie(dir.appending(path: "raw.mp4"))
        let created = createdAt ?? Int64(id) ?? Int64(Date().timeIntervalSince1970 * 1000)
        try run("INSERT OR REPLACE INTO recordings(id,title,created_at,dir,duration,width,height,fps,has_audio,edited_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?3)",
                [id, title, created, dir.path, info.duration, info.width, info.height, info.fps, info.hasAudio])
        return Recording(id: id, title: title, createdAt: created, dir: dir.path, duration: info.duration, width: info.width,
                         height: info.height, fps: info.fps, hasAudio: info.hasAudio, editedAt: created)
    }

    /// Stores the edits and title, and when they changed (saving the same again leaves the time alone). Returns the
    /// stored JSON and that time.
    @discardableResult
    public func saveEdits(id: String, title: String, edits: Edits, at now: Date = Date()) throws -> (edits: String, editedAt: Int64) {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys // the same edits always read the same, so an unchanged save is recognised
        let json = String(decoding: try enc.encode(edits), as: UTF8.self)
        try run("""
            UPDATE recordings SET edited_at = CASE WHEN edits IS ?1 AND title = ?2 THEN coalesce(edited_at, created_at) ELSE ?4 END,
              edits=?1, title=?2 WHERE id=?3
            """, [json, title, id, Int64(now.timeIntervalSince1970 * 1000)])
        var editedAt: Int64 = 0
        try run("SELECT edited_at FROM recordings WHERE id=?1", [id]) { editedAt = sqlite3_column_int64($0, 0) }
        return (json, editedAt)
    }

    /// Renames a recording from the library; a new title counts as an edit.
    public func rename(id: String, title: String, at now: Date = Date()) throws {
        try run("UPDATE recordings SET title=?2, edited_at=?3 WHERE id=?1 AND title IS NOT ?2", [id, title, Int64(now.timeIntervalSince1970 * 1000)])
    }

    public func addExport(id: String, path: String, preset: String) throws {
        try run("INSERT INTO exports(recording_id,path,preset,created_at) VALUES(?1,?2,?3,?4)", [id, path, preset, Int64(Date().timeIntervalSince1970 * 1000)])
    }

    /// Removes the recording and moves its folder and its autosaved project files to the Trash, so Finder's Put Back
    /// works. Exports are the user's shareable files, so they stay. Returns where each item went in the Trash, keyed by
    /// where it was, for `restore`.
    @discardableResult
    public func delete(id: String) throws -> [URL: URL] {
        try run("DELETE FROM recordings WHERE id=?1", [id])
        let dir = root.appending(path: "recordings/\(id)"), projects = root.appending(path: "projects")
        guard Paths.inside(dir.path, root: root) else { return [:] }
        let projectFiles = ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [])
            .filter { $0.hasSuffix("-\(id).\(Project.fileExtension)") }.map { projects.appending(path: $0) }
        var moved: [URL: URL] = [:]
        for item in [dir] + projectFiles {
            var trashed: NSURL?
            try? FileManager.default.trashItem(at: item, resultingItemURL: &trashed)
            moved[item] = trashed as URL?
        }
        return moved
    }

    /// Undoes `delete`: moves the folder and project files back from the Trash and puts the row, its edits and exports back.
    public func restore(_ rec: Recording, from trashed: [URL: URL]) throws {
        for (original, url) in trashed where !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.moveItem(at: url, to: original)
        }
        try run("INSERT INTO recordings(id,title,created_at,dir,duration,width,height,fps,has_audio,edits,edited_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                [rec.id, rec.title, rec.createdAt, rec.dir, rec.duration, rec.width, rec.height, rec.fps, rec.hasAudio, rec.edits, rec.editedAt])
        for x in rec.exports {
            try run("INSERT INTO exports(recording_id,path,preset,created_at) VALUES(?1,?2,?3,?4)", [rec.id, x.path, x.preset, x.createdAt])
        }
    }

    /// A crash mid-recording leaves a folder with a movie but no row; bring those back.
    public func recoverOrphans() async {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "recordings"), includingPropertiesForKeys: nil)) ?? []
        let known = Set(((try? list()) ?? []).map(\.id))
        for d in dirs where !known.contains(d.lastPathComponent) && FileManager.default.fileExists(atPath: d.appending(path: "raw.mp4").path) {
            try? await Recorder.joinParts(in: d) // a recording that was paused when the app quit
            _ = try? await insert(id: d.lastPathComponent, title: "Recovered recording", dir: d)
        }
    }
}

public enum Probe {
    public struct Info: Sendable { public var duration: Double, width: Int, height: Int, fps: Double, hasAudio: Bool }

    public static func movie(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.message("The recording has no video track.") }
        let (size, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return Info(duration: duration, width: Int(abs(r.width)), height: Int(abs(r.height)), fps: Double(fps), hasAudio: !audio.isEmpty)
    }
}

/// Speaker notes for the teleprompter: one script, kept in the library between recordings so it can be reused or
/// adjusted, and copied into each recording made with it.
public enum SpeakerNotes {
    public static let fileName = "notes.md"
    /// The text and Markdown files notes can be opened from.
    public static let extensions = ["txt", "md", "markdown", "text"]

    /// What the notes start as the first time: a short script about the app, which also shows how the teleprompter works.
    public static let sample = """
        # Intro

        Hi, I'm going to show you how **RecordStudio** turns a plain screen recording into something you can share. \
        First we record the screen, then we trim it, add a zoom on the important click, and export it.

        Let's start with a new recording. Press control option command R, pick the screen, and hit record.

        # The teleprompter

        These notes scroll past the reading line while you record, at the pace you pick. \
        Hover over this panel to hold it, nudge it back or forward, or make the text bigger. \
        Replace this text with your own script from the notes button in the record bar.
        """

    public static func load(root: URL = Paths.data) -> String {
        (try? String(contentsOf: root.appending(path: fileName), encoding: .utf8)) ?? ""
    }

    /// Keeps `text` for next time; empty notes remove the file.
    public static func save(_ text: String, root: URL = Paths.data) throws {
        let url = root.appending(path: fileName)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Puts a copy of `text` in a recording's folder, so it stays with the recording it was used for.
    public static func keep(_ text: String, in recording: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try text.write(to: recording.appending(path: fileName), atomically: true, encoding: .utf8)
    }
}
