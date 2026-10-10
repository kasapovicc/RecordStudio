import AppKit
import AVFoundation
import IOKit.hid
import RecordCore
import RecordKit
import SwiftUI

/// What macOS currently allows, asked for in context: the welcome window, Settings › Permissions, and the record bar
/// all read and request through here. macOS sends no notice when a permission changes in System Settings, so the
/// states are read again whenever the app comes back to the front.
@MainActor @Observable
final class PermissionCenter {
    static let shared = PermissionCenter()
    static let welcomeKey = "hasSeenPermissions"
    /// macOS shows the Screen Recording prompt only once, and its preflight can't tell "denied" from "never asked".
    private static let askedScreenKey = "askedScreenRecording"
    /// The same goes for Accessibility.
    private static let askedAccessibilityKey = "askedAccessibility"

    private(set) var states: [Permission: PermissionState] = [:]
    /// Some permissions take effect only after a relaunch, so a grant since launch still needs one.
    private var allowedAtLaunch: Set<Permission> = []
    /// Asked for, or their System Settings page opened, since launch: the answer may be waiting for a relaunch.
    private var askedThisSession: Set<Permission> = []

    @ObservationIgnored private var welcome: NSWindow?

    private init() {
        refresh()
        allowedAtLaunch = Set(Permission.allCases.filter { state($0) == .allowed })
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
    }

    func state(_ p: Permission) -> PermissionState { states[p] ?? .notAsked }

    func needsRelaunch(_ p: Permission) -> Bool {
        p.appliesAfterRelaunch && !allowedAtLaunch.contains(p) && askedThisSession.contains(p)
    }

    func refresh() {
        states = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, Self.read($0)) })
    }

    private static func read(_ p: Permission) -> PermissionState {
        switch p {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .allowed }
            return UserDefaults.standard.bool(forKey: askedScreenKey) ? .denied : .notAsked
        case .microphone: return state(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera: return state(AVCaptureDevice.authorizationStatus(for: .video))
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .allowed
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notAsked
            }
        case .accessibility:
            if AXIsProcessTrusted() { return .allowed }
            return UserDefaults.standard.bool(forKey: askedAccessibilityKey) ? .denied : .notAsked
        }
    }

    private static func state(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Shows macOS's prompt the first time, and the permission's page in System Settings after that.
    func request(_ p: Permission) async {
        askedThisSession.insert(p)
        switch state(p).action {
        case .ask:
            switch p {
            case .screenRecording:
                UserDefaults.standard.set(true, forKey: Self.askedScreenKey)
                CGRequestScreenCaptureAccess()
            case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .camera: _ = await CameraRig.requestAccess()
            case .inputMonitoring: CGRequestListenEventAccess()
            case .accessibility:
                UserDefaults.standard.set(true, forKey: Self.askedAccessibilityKey)
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        case .openSettings: NSWorkspace.shared.open(p.settingsURL)
        case nil: break
        }
        refresh()
    }

    func relaunch() { Installer(app: Bundle.main.bundleURL).relaunch() }

    /// Record was clicked without Screen Recording: what to do, rather than an error.
    func explainScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = "Turn on RecordStudio in System Settings › Privacy & Security › Screen & System Audio Recording. macOS applies it once RecordStudio relaunches."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            askedThisSession.insert(.screenRecording)
            NSWorkspace.shared.open(Permission.screenRecording.settingsURL)
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }

    /// Once, on first launch: what the app does, then every permission with what it's for, so none of macOS's prompts
    /// comes out of nowhere, then the first step. Help › Welcome to RecordStudio opens it again.
    func showWelcomeIfNew() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.welcomeKey)
        showWelcome()
    }

    func showWelcome() {
        NSApp.activate()
        if let welcome { welcome.makeKeyAndOrderFront(nil); return }
        // A fixed size, like the update window, so SwiftUI never resizes the window as rows change.
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: Welcome.size), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Welcome to RecordStudio" // for the Window menu and VoiceOver; hidden, the first page says it
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Welcome { [weak self] in self?.welcome?.close() }.tint(.graphite))
        host.sizingOptions = []
        w.contentView = host
        w.center()
        // Closed however it's closed, it opens again on page one.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.welcome = nil }
        }
        welcome = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Three short pages, each skippable: what RecordStudio does, the permissions, then the first recording.
private struct Welcome: View {
    static let size = CGSize(width: 600, height: 510)
    let done: () -> Void
    @State private var page = 0
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var recordShortcut: Shortcut? { ShortcutStore.shared.map[.newRecording] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: features.transition(slide)
                case 1: permissions.transition(slide)
                default: ready.transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // the window's full height, title bar included, so the footer never moves
        .ignoresSafeArea() // the hero runs up under the transparent title bar
    }

    // MARK: Pages

    private var features: some View {
        VStack(alignment: .leading, spacing: 0) {
            OutputSketch().frame(height: 200)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Welcome to RecordStudio").font(.largeTitle.weight(.semibold)).tracking(-0.4)
                Text("Record your screen. It comes out zoomed where you click and framed, before you edit anything.")
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            Grid(alignment: .topLeading, horizontalSpacing: Space.xl, verticalSpacing: Space.l) {
                GridRow {
                    feature("record.circle", "Record", recordShortcut.map { "Your screen, a window or an area. \($0.symbol) from anywhere." } ?? "Your screen, a window or an area.")
                    feature("plus.magnifyingglass", "Zooms itself", "Each click becomes a smooth zoom.")
                }
                GridRow {
                    feature("rectangle.inset.filled", "Framed", "On a wallpaper, with a redrawn cursor.")
                    feature("scissors", "Finish", "Trim, add text and captions. MP4, GIF and more.")
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.l)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Permissions").font(.largeTitle.weight(.semibold)).tracking(-0.4)
            Text("macOS asks before an app can see your screen or hear you. Allow what you'll use; you can change it any time in Settings › Permissions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PermissionRows()
                .padding(Space.l)
                .background(.quinary, in: .rect(cornerRadius: Radius.medium))
                .padding(.top, Space.m)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, 52) // off-scale: clears the transparent title bar
    }

    private var ready: some View {
        VStack(spacing: Space.l) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            VStack(spacing: Space.s) {
                Text("You're ready").font(.largeTitle.weight(.semibold)).tracking(-0.4)
                if let recordShortcut {
                    HStack(spacing: Space.xs) {
                        Text("Press")
                        Keycaps(caps: recordShortcut.caps)
                        Text("anywhere, or click New Recording.")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Click New Recording to start.").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xl)
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            PageDots(page: page, count: 3)
            HStack(spacing: Space.s) {
                switch page {
                case 0:
                    Button("Skip", action: done)
                    Button("Try the Sample Project") { done(); Studio.shared.openSample() }
                        .help("Opens a short recording with edits already made, to explore the editor")
                    Spacer()
                    Button("Set Up Recording") { go(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case 1:
                    Button("Back") { go(0) }
                    Spacer()
                    Button("Continue") { go(2) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                default:
                    Button("Back") { go(1) }
                    Spacer()
                    Button("Done", action: done)
                    Button { done(); Studio.shared.newRecording() } label: { Label("New Recording", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).tint(.record)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
    }

    /// Pages slide a short way in the direction of travel, so Back visibly goes back. A cross-fade with Reduce Motion.
    private func go(_ to: Int) {
        forward = to > page
        withAnimation(Motion.move.respecting(reduceMotion)) { page = to }
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .slide(edge: forward ? .trailing : .leading), removal: .slide(edge: forward ? .leading : .trailing))
    }
}

/// A sketch of what RecordStudio makes: a window framed on the default graphite wallpaper. Once, on opening, the
/// cursor clicks, the camera eases in on it and back out, as in a recording. Only the click shows with Reduce Motion.
private struct OutputSketch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clicked = false
    @State private var zoomed = false
    @State private var ripple = false
    private let wallpaper = BackgroundGradient.presets[0]
    private let click = UnitPoint(x: 0.66, y: 0.62) // where the cursor sits, as a fraction of the window
    private let card = CGSize(width: 280, height: 150), drop = 14.0 // off-scale: optical centre below the title bar

    var body: some View {
        GeometryReader { geo in
            // The click in the whole sketch's coordinates, so the camera zooms in on it.
            let anchor = UnitPoint(x: (geo.size.width - card.width) / 2 / geo.size.width + click.x * card.width / geo.size.width,
                                   y: ((geo.size.height - card.height) / 2 + drop + click.y * card.height) / geo.size.height)
            ZStack {
                LinearGradient(colors: [Color(cgColor: hexColor(wallpaper.from)), Color(cgColor: hexColor(wallpaper.to))],
                               startPoint: .top, endPoint: .bottom)
                window.frame(width: card.width, height: card.height).offset(y: drop)
            }
            .scaleEffect(zoomed ? 1.4 : 1, anchor: anchor)
        }
        .clipped()
        .accessibilityHidden(true)
        .task {
            guard !clicked else { return }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(Motion.demoClick) { clicked = true; ripple = true }
            withAnimation(Motion.demoRipple) { ripple = false }
            guard !reduceMotion else { return }
            withAnimation(Motion.demoZoom) { zoomed = true }
            try? await Task.sleep(for: .milliseconds(2200))
            withAnimation(Motion.demoZoom) { zoomed = false }
        }
    }

    private var window: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.medium).fill(.white)
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.xs) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.black.opacity(0.12)).frame(width: 7, height: 7) }
                    }
                    .padding(.bottom, Space.xs)
                    bar(0.55, opacity: 0.22)
                    bar(0.8)
                    bar(0.7)
                    bar(0.45)
                }
                .padding(Space.m)
                // The button the cursor clicks.
                Capsule().fill(.black.opacity(clicked ? 0.85 : 0.75))
                    .frame(width: 64, height: 18)
                    .position(x: w * click.x, y: h * click.y)
                Circle().stroke(.record, lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .scaleEffect(clicked ? 1.2 : 0.5)
                    .opacity(ripple ? 1 : 0)
                    .position(x: w * click.x, y: h * click.y)
                Image(systemName: "cursorarrow").font(.title3).foregroundStyle(.black)
                    .shadow(color: .white, radius: 1)
                    .position(x: w * click.x + 8, y: h * click.y + 10)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
    }

    private func bar(_ width: Double, opacity: Double = 0.08) -> some View {
        Capsule().fill(.black.opacity(opacity)).frame(width: (card.width - 2 * Space.m) * width, height: 7)
    }
}

/// The current page among `count`, as dots.
private struct PageDots: View {
    let page: Int, count: Int

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(count)")
    }
}

/// A shortcut such as ⌃⌥⌘R drawn as keys, one per symbol.
/// A shortcut drawn as the keys to press, one keycap each.
struct Keycaps: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, key in Text(key).foregroundStyle(.primary).keycap() }
        }
        .accessibilityElement()
        .accessibilityLabel(caps.joined())
    }
}

extension View {
    /// Text drawn as a key on a keyboard; `monospaced` off for words like "None".
    func keycap(monospaced: Bool = true) -> some View {
        font(.callout.weight(.medium)).monospaced(monospaced)
            .padding(.horizontal, Space.xs)
            .frame(minWidth: 22, minHeight: 22)
            .background(.quinary, in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.quaternary))
    }
}

/// One row per permission: what it's for, whether it's allowed, and the one button that changes it.
struct PermissionRows: View {
    private let center = PermissionCenter.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.m) {
            ForEach(Permission.allCases, id: \.self) { p in
                let state = center.state(p)
                // Asked for this session: macOS reports the answer only after a relaunch, so it's neither ✓ nor ✕ yet.
                let relaunch = center.needsRelaunch(p)
                let allowed = state == .allowed && !relaunch
                GridRow {
                    // A small mark: green when allowed, amber when it needs something, graphite when not asked yet. The
                    // text on the right says the same, so colour is never the only sign.
                    Circle().fill(allowed ? AnyShapeStyle(.green) : relaunch || state == .denied ? AnyShapeStyle(.orange) : AnyShapeStyle(.quiet))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(relaunch ? "Needs a relaunch" : allowed ? "Allowed" : state == .denied ? "Not allowed" : "Not asked yet")
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(p.title).fontWeight(.medium)
                        Text(relaunch ? "If you allowed it, relaunch to apply it." : p.purpose).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        if relaunch {
                            Button("Relaunch Now") { center.relaunch() }
                                .help("macOS applies \(p.title) once RecordStudio relaunches")
                        }
                        switch state.action {
                        case .ask: Button("Allow…") { Task { await center.request(p) } }
                        case .openSettings: Button("Open System Settings") { Task { await center.request(p) } }
                        case nil:
                            // The button turns into a checkmark that draws itself in once macOS says yes.
                            Label("Allowed", systemImage: "checkmark").foregroundStyle(.secondary)
                                .transition(.symbolEffect(.drawOn))
                        }
                    }
                    .fixedSize() // the buttons keep their labels; the description wraps instead
                    .gridColumnAlignment(.trailing)
                    .motion(Motion.enter, value: state)
                }
            }
        }
    }
}
