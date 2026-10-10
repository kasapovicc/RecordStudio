import Foundation

/// A release version like "1.2.0" or "1.0.0-beta.1", ordered the semantic-versioning way: numbers part by part, and
/// a version with a label (a pre-release) comes before the same version without one, so 1.0.0-beta.1 < 1.0.0.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Major, minor and patch. Missing parts are 0, so "1.2" equals "1.2.0".
    public var numbers: [Int]
    /// The label's dot-separated parts, e.g. ["beta", "1"]. Empty for a full release.
    public var label: [String]

    /// Parses "1.0.0", "v1.0.0-beta.1" or "1.0.0-beta.1+build.5" (build metadata is ignored). Nil for anything else.
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        let core: Substring, label: [String]
        if let dash = s.firstIndex(of: "-") {
            core = s[..<dash]
            label = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !label.contains(where: \.isEmpty) else { return nil }
        } else {
            core = s
            label = []
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        self.label = label
    }

    public var isBeta: Bool { !label.isEmpty }

    public var description: String { numbers.map(String.init).joined(separator: ".") + (label.isEmpty ? "" : "-" + label.joined(separator: ".")) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        switch (a.label.isEmpty, b.label.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.label, b.label) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true   // numbers sort before words
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.label.count < b.label.count
    }
}

/// One release from the GitHub releases API (`GET /repos/{owner}/{repo}/releases`), with only the fields the updater reads.
public struct Release: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        /// The download link a browser uses. It only works without signing in when the repository is public.
        public var url: URL
        /// The same file through the API, which takes a token, so it works for a private repository.
        public var api: URL?
        public var size: Int
        /// "sha256:<hex>", which GitHub computes when the file is uploaded.
        public var digest: String?

        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", api = "url", size, digest }

        public init(name: String, url: URL, api: URL? = nil, size: Int, digest: String? = nil) {
            (self.name, self.url, self.api, self.size, self.digest) = (name, url, api, size, digest)
        }

        /// With a token, the file is fetched through the API (as raw bytes) and signed in; without one, from the browser link.
        public func downloadRequest(token: String?) -> URLRequest {
            guard let token, let api, api.scheme == "https", api.host() == "api.github.com" else { return URLRequest(url: url) }
            var request = URLRequest(url: api)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        /// The SHA-256 to check the download against, as lowercase hex, when GitHub gave a well-formed one.
        public var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hex = digest.dropFirst("sha256:".count).lowercased()
            return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
        }
    }

    public var tag: String
    public var name: String?
    public var notes: String?
    public var page: URL?
    public var draft: Bool
    /// GitHub's own pre-release tick. A version label also makes a release a beta, whether or not this is set.
    public var prerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, notes = "body", page = "html_url", draft, prerelease, assets
    }

    public init(tag: String, name: String? = nil, notes: String? = nil, page: URL? = nil, draft: Bool = false,
                prerelease: Bool = false, assets: [Asset] = []) {
        (self.tag, self.name, self.notes, self.page, self.draft, self.prerelease, self.assets) = (tag, name, notes, page, draft, prerelease, assets)
    }

    public var version: AppVersion? { AppVersion(tag) }
    public var isBeta: Bool { prerelease || version?.isBeta == true }

    /// The disk image to install: the one named after this version (as `make dmg` names it), else the only other
    /// RecordStudio disk image. Only https downloads from github.com are accepted.
    public var installer: Asset? {
        let images = assets.filter {
            $0.name.lowercased().hasPrefix("recordstudio") && $0.name.lowercased().hasSuffix(".dmg")
                && $0.url.scheme == "https" && $0.url.host() == "github.com"
        }
        if let v = version, let exact = images.first(where: { $0.name == "RecordStudio-\(v).dmg" }) { return exact }
        return images.count == 1 ? images[0] : nil
    }
}

/// The request for a repository's releases, signed in when there's a token (needed while the repository is private).
public func releasesRequest(repository: String, token: String?) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
}

/// Why a check found no releases. Only a build that carries an update token (a test build) mentions the token:
/// someone with a public build has never heard of it and can't do anything about it.
public func noReleasesMessage(repository: String, signedIn: Bool) -> String {
    let found = "GitHub has no releases for \(repository) that this copy can see."
    return signedIn ? found + " While the repository is private, the app needs to be built with an update token." : found
}

/// A redirect keeps the token only while it stays on the same host. GitHub sends asset downloads on to a signed
/// storage link, which must not get the token (it's not theirs to see, and the storage rejects a second credential).
public func redirect(_ next: URLRequest, from previous: URL?) -> URLRequest {
    guard next.url?.host() != previous?.host() else { return next }
    var stripped = next
    stripped.setValue(nil, forHTTPHeaderField: "Authorization")
    return stripped
}

/// What the updater should offer: the newest published release that's newer than the running version and has a
/// disk image to install. Betas are offered only when `includeBetas` is on.
public func availableUpdate(_ releases: [Release], current: AppVersion, includeBetas: Bool) -> Release? {
    releases
        .filter { !$0.draft && (includeBetas || !$0.isBeta) && $0.installer != nil }
        .compactMap { r -> (Release, AppVersion)? in r.version.map { (r, $0) } }
        .filter { $0.1 > current }
        .max { $0.1 < $1.1 }?.0
}

/// Whether to check on launch: only with automatic checks on, and at most once a day. A clock that moved
/// backwards counts as due, so a wrong date can't stop checks for good.
public func isUpdateCheckDue(automatic: Bool, lastCheck: Date?, now: Date, interval: TimeInterval = 24 * 60 * 60) -> Bool {
    guard automatic else { return false }
    guard let lastCheck else { return true }
    let elapsed = now.timeIntervalSince(lastCheck)
    return elapsed >= interval || elapsed < 0
}

/// Release notes rewritten so inline-only Markdown reads like the GitHub release page: SwiftUI's `Text` draws
/// bold, italics and links, but not headings or lists. Headings become bold lines, list items bullets, and bare
/// links short ones: "#123" for a pull request or issue, the range for a compare link, else the host.
public func releaseNotesMarkdown(_ notes: String) -> String {
    notes.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
        var line = String(raw)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(indent.count)
        if let heading = body.firstMatch(of: #/^#{1,6}\s+(.*?)\s*#*\s*$/#) {
            line = indent + "**\(heading.1)**"
        } else if let item = body.firstMatch(of: #/^[*+-]\s+(.*)$/#) {
            line = indent + "• " + item.1
        }
        return line.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard word.hasPrefix("https://") || word.hasPrefix("http://"),
                  let url = URL(string: String(word)), let host = url.host() else { return String(word) }
            let parts = url.pathComponents
            let label = if parts.count >= 5, ["pull", "issues"].contains(parts[3]), Int(parts[4]) != nil { "#\(parts[4])" }
                else if parts.count >= 5, parts[3] == "compare" { parts[4] }
                else { host }
            return "[\(label)](\(word))"
        }.joined(separator: " ")
    }.joined(separator: "\n")
}
