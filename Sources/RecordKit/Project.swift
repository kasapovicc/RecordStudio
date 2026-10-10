import Foundation
import RecordCore

/// A recording with its edits as one `.recordstudio` file (a zip) that another copy of RecordStudio can open:
///
///     project.json   format version, title, recording date, edits
///     recording/     raw.mp4, cursor.json and the other files the recording was made with
///     assets/        files the edits use from elsewhere (music, background and annotation images, inserted clips)
///
/// In project.json the edits point at `assets/<name>`, or at a built-in wallpaper as `wallpaper:<name>`.
public enum Project {
    public static let fileExtension = "recordstudio"
    public static let version = 1
    /// The recording's own files that travel with it; nothing else from the folder is read or written.
    static let recordingFiles = ["raw.mp4", "cursor.json", "cursors.json", "capture.json", "camera.mov", "camera.json", "system.m4a", "system.json", "keys.json"]
    static let wallpaperPrefix = "wallpaper:"

    struct Manifest: Codable {
        var version: Int
        var title: String
        var createdAt: Int64
        var edits: Edits
    }

    /// Where a recording's own project file is kept up to date: `<title>-<id>.recordstudio` in the library's projects folder.
    public static func autosaveURL(id: String, title: String, root: URL = Paths.data) -> URL {
        root.appending(path: "projects/\(safeFilename(title))-\(id).\(fileExtension)")
    }

    /// Rewrites the recording's own project file, removing the one under its old title after a rename.
    public static func autosave(_ rec: Recording, title: String, edits: Edits, root: URL = Paths.data) async throws {
        let url = autosaveURL(id: rec.id, title: title, root: root), dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await save(rec, title: title, edits: edits, to: url)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where f.hasSuffix("-\(rec.id).\(fileExtension)") && f != url.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appending(path: f))
        }
    }

    /// Writes `rec` with `edits` to `url`, replacing what's there.
    public static func save(_ rec: Recording, title: String, edits: Edits, to url: URL) async throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appending(path: "rs-project-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        let recording = stage.appending(path: "recording"), assets = stage.appending(path: "assets")
        try fm.createDirectory(at: recording, withIntermediateDirectories: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        for f in recordingFiles where fm.fileExists(atPath: rec.dir + "/" + f) {
            try fm.copyItem(at: URL(fileURLWithPath: rec.dir + "/" + f), to: recording.appending(path: f))
        }
        var copied: [String: String] = [:] // original path -> path in the project
        func pack(_ path: String) throws -> String? {
            if let done = copied[path] { return done }
            if path.hasPrefix(Wallpapers.root + "/") { return wallpaperPrefix + (URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) }
            guard fm.fileExists(atPath: path) else { return nil } // already missing here: dropped rather than shipped broken
            let name = "\(copied.count + 1)-\(URL(fileURLWithPath: path).lastPathComponent)"
            try fm.copyItem(at: URL(fileURLWithPath: path), to: assets.appending(path: name))
            copied[path] = "assets/" + name
            return "assets/" + name
        }
        var e = edits
        e.backgroundImage = try e.backgroundImage.flatMap(pack)
        if let a = e.audio { e.audio = try pack(a.path).map { var a = a; a.path = $0; return a } }
        e.allAnnotations = try e.allAnnotations.compactMap { a in
            if let v = a.video { return try pack(v.path).map { var a = a; a.video?.path = $0; return a } }
            guard let img = a.image else { return a }
            return try pack(img).map { var a = a; a.image = $0; return a }
        }
        // A clip holds its place on the timeline even when its file has gone (it shows as black), so it's always kept.
        e.allClips = try e.allClips.map { c in var c = c; c.path = try pack(c.path) ?? "assets/missing-clip.mp4"; return c }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Manifest(version: version, title: title, createdAt: rec.createdAt, edits: e)).write(to: stage.appending(path: "project.json"))
        let tmp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        try await Tools.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--zlibCompressionLevel", "0", stage.path, tmp.path])
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }

    /// Imports a project file as a new recording in `library` (a copy each time) and returns it.
    @discardableResult
    public static func open(_ url: URL, into library: Library) async throws -> Recording {
        let fm = FileManager.default
        // The file comes from someone else: check every entry's path before anything is written.
        let entries = try await Tools.run("/usr/bin/zipinfo", ["-1", url.path]).split(separator: "\n").map(String.init)
        for e in entries where e.hasPrefix("/") || e.split(separator: "/").contains("..") || e.contains("\\") {
            throw StudioError.message("This project file isn’t valid: it has a file outside the project (\(e)).")
        }
        let stage = fm.temporaryDirectory.appending(path: "rs-open-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try await Tools.run("/usr/bin/ditto", ["-x", "-k", url.path, stage.path])
        // Links could point anywhere on this Mac; a project never has any.
        let files = (fm.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey])?.allObjects as? [URL]) ?? []
        if files.contains(where: { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }) {
            throw StudioError.message("This project file isn’t valid: it contains a link.")
        }
        guard let data = fm.contents(atPath: stage.appending(path: "project.json").path) else {
            throw StudioError.message("This isn’t a RecordStudio project.")
        }
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw StudioError.message("This isn’t a RecordStudio project.") }
        guard header.version <= version else {
            throw StudioError.message("This project was saved by a newer version of RecordStudio. Update RecordStudio to open it.")
        }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else { throw StudioError.message("This project’s edits couldn’t be read.") }
        guard fm.fileExists(atPath: stage.appending(path: "recording/raw.mp4").path) else { throw StudioError.message("This project has no recording in it.") }

        // A new id (ids are creation times in ms, unique per folder), so opening it twice makes two copies.
        var id = Int64(Date().timeIntervalSince1970 * 1000)
        let recordings = library.root.appending(path: "recordings")
        while fm.fileExists(atPath: recordings.appending(path: "\(id)").path) { id += 1 }
        let dir = recordings.appending(path: "\(id)")
        let assets = dir.appending(path: "assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        do {
            for f in recordingFiles where fm.fileExists(atPath: stage.appending(path: "recording/\(f)").path) {
                try fm.copyItem(at: stage.appending(path: "recording/\(f)"), to: dir.appending(path: f))
            }
            let wallpapers = Wallpapers.list()
            func unpack(_ path: String) throws -> String? {
                if path.hasPrefix(wallpaperPrefix) {
                    let name = String(path.dropFirst(wallpaperPrefix.count))
                    return wallpapers.first { $0.name == name }?.path // not on this Mac: the background colour shows instead
                }
                let name = String(path.dropFirst("assets/".count))
                guard path.hasPrefix("assets/"), !name.isEmpty, !name.contains("/"), name != "..", name != "." else {
                    throw StudioError.message("This project file isn’t valid: it points at a file outside the project (\(path)).")
                }
                let src = stage.appending(path: path), dest = assets.appending(path: name)
                guard fm.fileExists(atPath: src.path) else { return nil }
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
                guard Paths.inside(dest.path, root: dir) else { throw StudioError.message("This project file isn’t valid.") }
                return dest.path
            }
            var e = m.edits
            e.backgroundImage = try e.backgroundImage.flatMap(unpack)
            if let a = e.audio { e.audio = try unpack(a.path).map { var a = a; a.path = $0; return a } }
            e.allAnnotations = try e.allAnnotations.compactMap { a in
                if let v = a.video { return try unpack(v.path).map { var a = a; a.video?.path = $0; return a } }
                guard let img = a.image else { return a }
                return try unpack(img).map { var a = a; a.image = $0; return a }
            }
            e.allClips = try e.allClips.map { c in var c = c; c.path = try unpack(c.path) ?? assets.appending(path: "missing-clip").path; return c }
            var rec = try await library.insert(id: "\(id)", title: m.title, dir: dir, createdAt: m.createdAt)
            let saved = try library.saveEdits(id: rec.id, title: m.title, edits: e)
            (rec.edits, rec.editedAt) = (saved.edits, saved.editedAt)
            return rec
        } catch {
            try? fm.removeItem(at: dir) // a half-made import is removed, not put in the Trash
            _ = try? library.delete(id: "\(id)")
            throw error
        }
    }
}
