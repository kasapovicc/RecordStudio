import Foundation
import Testing

/// The app's views take spacing, corner radii, type, colour and motion from one scale (Sources/RecordStudio/Scale.swift). This reads
/// their source and fails on a literal that bypasses it. A deliberate exception carries an `off-scale:` comment.
@Suite struct UIScale {
    static let literals = [
        #"\.padding\((\.\w+, *)?-?\d"#,       // .padding(12), .padding(.horizontal, 6)
        #"\bspacing: *[1-9]"#,               // HStack(spacing: 6); 0 is allowed
        #"cornerRadius: *\d"#,               // .rect(cornerRadius: 7)
        #"cornerRadii: [^)]*\b\d"#,         // UnevenRoundedRectangle(cornerRadii: .init(topLeading: 7…))
        #"\.system\(size: *\d"#,             // .font(.system(size: 11)); use a text style
        #"accentColor"#,                     // system blue; use .graphite
        #"\.tint\(\.red\)|systemRed"#,        // recording uses the brand red, .record
        #"\bColor\(white:"#,                // one grey in both appearances; use Color(light:dark:)
        #"duration: *[0-9.]"#,              // .easeOut(duration: 0.2), .spring(duration: 0.35); use a Motion token
        #"\.(snappy|bouncy|smooth)\b"#,      // the system springs; use a Motion token
    ]

    @Test func viewsUseTheScale() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/RecordStudio")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Scale.swift" }
        #expect(files.count > 5)
        let patterns = try Self.literals.map { try Regex($0) }
        var offenders: [String] = []
        for file in files {
            for (i, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.contains("off-scale:") && patterns.contains(where: { line.contains($0) }) {
                offenders.append("\(file.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}
