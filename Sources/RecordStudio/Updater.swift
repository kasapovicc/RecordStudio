import AppKit
import CryptoKit
import os
import RecordCore
import Security
import SwiftUI

/// Checks GitHub releases for a newer version and installs it. The only requests are the release list and, when
/// the user says so, the disk image. Nothing about the user or the Mac is sent.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// Where releases are read from, set at build time: the public repository for public builds, the private one for test builds.
    static let repository = (Bundle.main.object(forInfoDictionaryKey: "RecordStudioUpdateRepository") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "kasapovicc/RecordStudio"
    static let automaticKey = "checkUpdatesAutomatically", betasKey = "includeBetaUpdates"
    private static let lastCheckKey = "lastUpdateCheck", skippedKey = "skippedUpdate"

    enum State: Equatable {
        case idle, checking
        /// Nothing to install. `beta` is a newer beta that isn't offered because betas are turned off.
        case upToDate(beta: Release?)
        case available(Release)
        case downloading(Release), installing(Release)
        case failed(String, page: URL?)
    }

    private(set) var state = State.idle {
        didSet { window?.setContentSize(UpdateView.size(for: state)) }
    }
    let current: AppVersion?
    /// Only a Developer ID build can verify and replace itself. `make run` builds point to the download instead.
    let canInstall: Bool

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "RecordStudio", category: "updates")
    // Ephemeral: no cookies or cache, so the requests carry nothing from earlier ones.
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        current = (info["RecordStudioVersion"] as? String ?? info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        canInstall = Installer.isDeveloperIDSigned(Bundle.main.bundleURL)
        UserDefaults.standard.register(defaults: [Self.automaticKey: true, Self.betasKey: false])
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    /// On launch and then hourly: checks when automatic checks are on and the last one was a day or more ago.
    func start() {
        checkIfDue()
        let tick = Timer(timeInterval: 60 * 60, repeats: true) { _ in MainActor.assumeIsolated { Updater.shared.checkIfDue() } }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func checkIfDue() {
        let d = UserDefaults.standard
        // Not mid-recording: a window popping up would land in the capture. The next tick tries again.
        guard !Studio.shared.isRecording, !isBusy,
              isUpdateCheckDue(automatic: d.bool(forKey: Self.automaticKey), lastCheck: lastCheck, now: .now) else { return }
        check(userInitiated: false)
    }

    /// Checking, downloading or installing.
    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// RecordStudio → Check for Updates… always shows its result. An automatic check stays quiet unless there's
    /// an update the user hasn't skipped.
    func check(userInitiated: Bool) {
        if userInitiated { show() }
        guard !isBusy else { return }
        state = .checking
        work = Task {
            do {
                let releases = try await fetchReleases()
                UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
                let d = UserDefaults.standard
                let betas = d.bool(forKey: Self.betasKey)
                guard let current, let update = availableUpdate(releases, current: current, includeBetas: betas) else {
                    let beta = betas ? nil : current.flatMap { availableUpdate(releases, current: $0, includeBetas: true) }
                    state = .upToDate(beta: beta)
                    return
                }
                state = .available(update)
                if userInitiated || d.string(forKey: Self.skippedKey) != update.tag { show() }
            } catch is CancellationError {
                state = .idle
            } catch {
                log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Couldn't check for updates. \(error.localizedDescription)", page: Self.releasesPage)
            }
        }
    }

    private func fetchReleases() async throws -> [Release] {
        let (data, response) = try await session.data(for: releasesRequest(repository: Self.repository, token: Self.token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        // GitHub answers 404, not 401, for a private repository when the request isn't signed in.
        case 404: throw UpdateError.notFound(Self.repository, signedIn: Self.token != nil)
        case 401: throw UpdateError.tokenRefused
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.server(status)
        }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.tag, forKey: Self.skippedKey)
        close()
    }

    func close() {
        window?.close()
        if !isBusy { state = .idle }
    }

    /// From the up-to-date window: turns on beta versions and checks again.
    func includeBetas() {
        UserDefaults.standard.set(true, forKey: Self.betasKey)
        state = .idle
        check(userInitiated: true)
    }

    func cancel() {
        work?.cancel()
    }

    /// Downloads the disk image, checks it, swaps it in for this copy of the app and relaunches.
    func install(_ release: Release) {
        guard let asset = release.installer else { return }
        guard canInstall else {
            NSWorkspace.shared.open(asset.url)
            return
        }
        work?.cancel()
        state = .downloading(release)
        work = Task {
            do {
                let installer = Installer(app: Bundle.main.bundleURL)
                let dmg = try await installer.download(asset, token: Self.token, with: session)
                try Task.checkCancellation()
                state = .installing(release)
                let staged = try await installer.prepare(dmg: dmg, bundleID: Bundle.main.bundleIdentifier ?? "")
                // Quitting would stop a recording that started during the download.
                guard !Studio.shared.isRecording else { throw UpdateError.recording }
                try installer.replace(with: staged)
                installer.relaunch()
            } catch where Task.isCancelled {
                // Cancel: URLSession reports it as its own error, not CancellationError.
                state = .available(release)
            } catch {
                log.error("Update to \(release.tag, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription, page: release.page)
            }
        }
    }

    /// A read-only token for the private repository, added to test builds from UPDATE_TOKEN in .env (see README).
    /// Nil in public builds, which read the public repository without signing in.
    static let token: String? = (Bundle.main.object(forInfoDictionaryKey: "RecordStudioUpdateToken") as? String).flatMap { $0.isEmpty ? nil : $0 }

    private static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    private func show() {
        if window == nil {
            // A fixed size, like the app's other hosted windows: letting SwiftUI resize the window as the content
            // changes (checking → result) can throw AppKit into a layout loop that ends in a crash. `state` sets it instead.
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: UpdateView.size(for: state)), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: UpdateView().tint(.graphite))
            host.sizingOptions = []
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum UpdateError: LocalizedError {
    case server(Int), notFound(String, signedIn: Bool), tokenRefused, rateLimited, size, checksum, notNotarized(String), noApp, signature, readOnly(String), recording, tool(String, String)

    var errorDescription: String? {
        switch self {
        case .server(let status): "GitHub answered with HTTP \(status). Try again later."
        case .notFound(let repo, let signedIn): noReleasesMessage(repository: repo, signedIn: signedIn)
        case .tokenRefused: "GitHub refused this copy's update token. It may have expired: download the newest version from GitHub by hand."
        case .rateLimited: "GitHub is limiting requests from this network for now. Try again in an hour."
        case .size, .checksum: "The download doesn't match the release on GitHub, so it wasn't installed."
        case .notNotarized(let why): "The disk image isn't signed and notarized by the RecordStudio developer, so it wasn't installed. \(why)"
        case .noApp: "The disk image doesn't contain RecordStudio."
        case .signature: "The app in the disk image isn't signed by the RecordStudio developer, so it wasn't installed."
        case .readOnly(let folder): "RecordStudio can't replace itself in \(folder). Download the new version and drag it to Applications instead."
        case .recording: "Stop the recording, then install the update."
        case .tool(let tool, let output): "\(tool) failed. \(output)"
        }
    }
}

/// The steps that touch the disk. Each one blocks on a subprocess or on file I/O, so they run off the main actor.
struct Installer {
    /// The running app, which the new one replaces.
    let app: URL

    /// Developer ID Application certificates carry this extension (Apple's OID for them), development ones don't.
    private static let developerID = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func isDeveloperIDSigned(_ url: URL) -> Bool {
        teamID(url) != nil && satisfies(url, developerID)
    }

    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String
    }

    /// Checks the whole bundle's signature (every architecture, nested code, strictly) against a code requirement.
    static func satisfies(_ url: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// Downloads into a folder on the app's volume, and checks the size and SHA-256 GitHub lists for the file.
    @concurrent func download(_ asset: Release.Asset, token: String?, with session: URLSession) async throws -> URL {
        let (temp, response) = try await session.download(for: asset.downloadRequest(token: token), delegate: RedirectGuard())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        let dmg = try workFolder().appending(path: "update.dmg")
        try FileManager.default.moveItem(at: temp, to: dmg)
        let size = try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int
        guard size == asset.size else { throw UpdateError.size }
        if let expected = asset.sha256, try Self.sha256(dmg) != expected { throw UpdateError.checksum }
        return dmg
    }

    /// Checks the disk image is notarized, copies the app out of it and checks the copy is signed by the same
    /// developer (same Team ID) with the same bundle id as this one. Returns the copy, ready to swap in.
    @concurrent func prepare(dmg: URL, bundleID: String) async throws -> URL {
        // Gatekeeper's verdict on the image: Developer ID signed and carrying a notarization ticket (`make dmg` staples it).
        do {
            _ = try Self.run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "-v", dmg.path])
        } catch UpdateError.tool(_, let output) {
            throw UpdateError.notNotarized(output)
        }
        guard let team = Self.teamID(app) else { throw UpdateError.signature }
        let plist = try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        let entities = (try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])?["system-entities"] as? [[String: Any]]
        guard let mount = entities?.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateError.noApp }
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let source = URL(filePath: mount).appending(path: app.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.noApp }
        let staged = try workFolder().appending(path: app.lastPathComponent)
        _ = try Self.run("/usr/bin/ditto", [source.path, staged.path])
        let requirement = "\(Self.developerID) and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard Self.satisfies(staged, requirement) else { throw UpdateError.signature }
        return staged
    }

    /// Swaps the new app in. The running copy keeps working until it quits, since its files stay open.
    func replace(with staged: URL) throws {
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path), FileManager.default.isWritableFile(atPath: app.path) else {
            throw UpdateError.readOnly(folder.path)
        }
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
    }

    /// Quits, and reopens the app once this process has gone.
    @MainActor func relaunch() {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// A fresh folder on the same volume as the app, so the final swap is a rename rather than a copy.
    private func workFolder() throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
    }

    private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool and returns what it printed. Its errors go to the same pipe, so a failure can say why.
    private static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        p.standardOutput = out
        // hdiutil's progress messages would get into its plist.
        if tool.hasSuffix("hdiutil") { p.standardError = FileHandle.nullDevice } else { p.standardError = out }
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.tool(URL(filePath: tool).lastPathComponent, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}

/// Keeps the token from following GitHub's redirect to the storage link.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        redirect(request, from: response.url)
    }
}

// MARK: Window

private struct UpdateView: View {
    /// Tall enough for release notes, a little taller for an error, and short for a line or two of status.
    static func size(for state: Updater.State) -> CGSize {
        switch state {
        case .available, .downloading, .installing: CGSize(width: 520, height: 400)
        case .failed: CGSize(width: 520, height: 220)
        default: CGSize(width: 520, height: 170)
        }
    }
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            switch updater.state {
            case .idle, .checking:
                status("Checking for updates…", busy: true)
            case .upToDate(let beta):
                Text("You're up to date").font(.headline)
                Text("RecordStudio \(updater.current?.description ?? "") is the newest version\(UserDefaults.standard.bool(forKey: Updater.betasKey) ? ", including betas" : "").")
                    .foregroundStyle(.secondary)
                if let beta {
                    Text("A beta, \(beta.version?.description ?? beta.tag), is available. Betas are off in Settings › Updates.")
                        .foregroundStyle(.secondary)
                }
                buttons {
                    if beta != nil { Button("Include Beta Versions") { updater.includeBetas() } }
                    Button("OK") { updater.close() }.keyboardShortcut(.defaultAction)
                }
            case .available(let r), .downloading(let r), .installing(let r):
                available(r)
            case .failed(let message, let page):
                Label("Update failed", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading) } // a tool's output can run long
                buttons {
                    if let page { Button("Open Release Page") { NSWorkspace.shared.open(page); updater.close() } }
                    Button("OK") { updater.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Space.l)
        .frame(width: Self.size(for: updater.state).width, height: Self.size(for: updater.state).height, alignment: .topLeading)
    }

    @ViewBuilder private func available(_ r: Release) -> some View {
        let version = r.version?.description ?? r.tag
        Text("RecordStudio \(version) is available").font(.headline)
        Text("You have \(updater.current?.description ?? "an older version").\(r.isBeta ? " This is a beta." : "")")
            .foregroundStyle(.secondary)
        ScrollView {
            Text(notes(r))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s)
        }
        .frame(maxHeight: .infinity)
        .background(.quinary, in: .rect(cornerRadius: Radius.medium))
        if Studio.shared.isRecording {
            Text("Stop the recording to install the update.").font(.caption).foregroundStyle(.secondary)
        }
        // While it downloads and installs, progress takes the buttons' place.
        HStack {
            switch updater.state {
            case .downloading:
                status("Downloading…", busy: true)
                Spacer()
                Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction)
            case .installing:
                status("Checking and installing…", busy: true)
                Spacer()
            default:
                Button("Skip This Version") { updater.skip(r) }
                Spacer()
                Button("Later") { updater.close() }.keyboardShortcut(.cancelAction)
                Button(updater.canInstall ? "Install and Relaunch" : "Download") { updater.install(r) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.canInstall && Studio.shared.isRecording)
                    .help(updater.canInstall ? "Download, verify and install, then reopen RecordStudio" : "This build can't update itself; download the disk image instead")
            }
        }
        .frame(minHeight: 28) // off-scale: one height for the buttons and the progress line, so the notes don't jump
    }

    private func notes(_ r: Release) -> AttributedString {
        let text = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return AttributedString("No release notes.") }
        return (try? AttributedString(markdown: releaseNotesMarkdown(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func status(_ text: String, busy: Bool) -> some View {
        HStack(spacing: Space.s) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
        }
    }

    /// The window's buttons, kept at the bottom of its fixed height.
    @ViewBuilder private func buttons<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Spacer(minLength: 0)
        HStack { Spacer(); content() }
    }
}

/// Settings → Updates: the version, when it last looked, and the two switches, on one card.
struct UpdateSettings: View {
    @AppStorage(Updater.automaticKey) private var automatic = true
    @AppStorage(Updater.betasKey) private var betas = false

    var body: some View {
        Section {
            LabeledContent {
                Button("Check Now") { Updater.shared.check(userInitiated: true) }
            } label: {
                Text("RecordStudio \(Updater.shared.current?.description ?? "")")
                Text(lastChecked)
            }
            Toggle("Check for updates automatically", isOn: $automatic)
            Toggle("Include beta versions", isOn: $betas)
        } header: {
            SectionHeader("Updates", "Only the list of releases is fetched from GitHub.")
        }
    }

    private var lastChecked: String {
        guard let d = Updater.shared.lastCheck else { return "Not checked yet." }
        return "Last checked \(d.formatted(.relative(presentation: .named)))."
    }
}
