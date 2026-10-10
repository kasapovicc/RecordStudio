import Foundation
import RecordCore

/// A named set of appearance settings, applied to a recording in one go (see `Edits.withLook`).
public struct Look: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    /// `Edits.lookTemplate` with the look's settings.
    public var edits: Edits
    public var id: String { name }
    public init(name: String, from e: Edits) { (self.name, self.edits) = (name, Edits.lookTemplate.withLook(of: e)) }
}

/// The saved looks, kept in looks.json in the library folder, and which one new recordings start with.
public struct Looks: Codable, Equatable, Sendable {
    static let fileName = "looks.json"
    public var all: [Look] = []
    /// The name of the look new recordings start with; nil = the built-in default.
    public var forNew: String?
    public init() {}

    public var forNewLook: Look? { all.first { $0.name == forNew } }

    /// The look `e` has exactly, if any.
    public func current(_ e: Edits) -> Look? { all.first { e.withLook(of: $0.edits) == e } }

    /// Saves `e`'s appearance as `name`, replacing a look of that name.
    public mutating func save(_ name: String, from e: Edits) {
        let look = Look(name: name, from: e)
        if let i = all.firstIndex(where: { $0.name == name }) { all[i] = look } else { all.append(look) }
    }

    public mutating func delete(_ name: String) {
        all.removeAll { $0.name == name }
        if forNew == name { forNew = nil }
    }

    /// The saved looks; none when there's no file or it can't be read.
    public static func load(root: URL = Paths.data) -> Looks {
        FileManager.default.contents(atPath: root.appending(path: fileName).path).flatMap { try? JSONDecoder().decode(Looks.self, from: $0) } ?? Looks()
    }

    public func save(root: URL = Paths.data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: root.appending(path: Self.fileName), options: .atomic)
    }
}
