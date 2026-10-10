import Foundation
import Testing

/// The landing page (site/index.html) is plain HTML with no build step, so nothing else notices a renamed or missing
/// screenshot or video. This reads the page and fails on any local file it points at that isn't there.
@Suite struct Site {
    @Test func everyLocalFileThePageUsesExists() throws {
        let site = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../site")
        let html = try String(contentsOf: site.appending(path: "index.html"), encoding: .utf8)
        var paths: [String] = []
        for match in html.matches(of: #/(?:src|href|poster|srcset|imagesrcset)="([^"]+)"/#) {
            // A srcset lists "path width, path width"; the others hold one path.
            paths += match.1.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
        }
        let local = paths.filter { !$0.contains(":") && !$0.hasPrefix("#") && $0 != "./" }
        #expect(local.count > 10)
        let missing = local.filter { !FileManager.default.fileExists(atPath: site.appending(path: $0).path) }
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }
}
