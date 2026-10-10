import Foundation
import Testing

/// Failures are reported as a `Problem` whose title names what failed (see Studio.swift); this reads the app's source and
/// fails on a bare error string or the old "Something went wrong" alert creeping back.
@Suite struct Messages {
    static let patterns = [
        #"Something went wrong"#,
        #"\berror = (\"|error\.localizedDescription)"#, // Studio.error = "…" or = error.localizedDescription
        #"\bnotice = "#,                               // the old editor banner; use progress, toast or a Problem
    ]

    @Test func failuresNameWhatFailed() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/RecordStudio")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 5)
        let regexes = try Self.patterns.map { try Regex($0) }
        var offenders: [String] = []
        for file in files {
            for (i, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where regexes.contains(where: { line.contains($0) }) {
                offenders.append("\(file.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}
