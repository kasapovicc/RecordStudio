import AVFoundation
import AppKit
import RecordCore
import RecordKit
import SwiftUI

/// Borderless, always-on-top panel on every Space, hosting SwiftUI. It can take keyboard focus (Esc, menus)
/// without activating the app, like the system screenshot bar.
final class FloatingPanel: NSPanel {
    init<V: View>(size: CGSize, level: NSWindow.Level = .floating, resizable: Bool = false, @ViewBuilder content: () -> V) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: resizable ? [.borderless, .nonactivatingPanel, .resizable] : [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // The first click works even while another app is in front (as it is while recording), rather than only
        // bringing the panel forward.
        let host = FirstMouseHostingView(rootView: content().tint(.graphite))
        host.sizingOptions = []
        contentView = host
    }
    override var canBecomeKey: Bool { true }
}

/// The full-screen picker. A borderless window can't become key unless it says so, and AppKit hands clicks on
/// fully transparent pixels (the cut-out around the highlighted window or area) to whatever is underneath.
final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Takes the first click even while the app is still activating, so a drag or click isn't spent on focus.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The screen the pointer is on, with its CoreGraphics display id and bounds (global points, top-left origin).
struct ActiveScreen {
    let screen: NSScreen
    let id: CGDirectDisplayID
    var bounds: CGRect { CGDisplayBounds(id) }

    static func current() -> ActiveScreen {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return ActiveScreen(screen: screen, id: id)
    }

    /// Bottom-centre placement inside the visible frame, `lift` points above the Dock.
    func bottomCentre(_ size: CGSize, lift: CGFloat = 96) -> CGPoint {
        let f = screen.visibleFrame
        return CGPoint(x: f.midX - size.width / 2, y: f.minY + lift)
    }
}

@MainActor
final class Panels {
    static let shared = Panels()
    private var bar: FloatingPanel?
    private var hud: FloatingPanel?
    private var picker: NSWindow?
    private var preview: FloatingPanel?
    private var previewShown: BubbleShown?
    private var countdownPanel: FloatingPanel?
    private var outline: FloatingPanel?
    /// The record bar's microphone level; listens only while the bar is open.
    let meter = MicMeter()
    /// A window the picker resized for this recording, put back to its own size once the recording ends.
    var restoreAfterRecording: WindowResize?

    func restoreWindow() {
        restoreAfterRecording.map { $0.set($0.original) }
        restoreAfterRecording = nil
    }

    var isCountingDown: Bool { countdownPanel != nil }

    /// Shows a big 3-2-1 in the middle of what `source` records and returns once it has run (true) or Esc cancelled it
    /// (false). The recording starts only after the panel has closed, so it never appears in the video.
    func countdown(_ seconds: Int, on source: CaptureSource) async -> Bool {
        guard seconds > 0 else { return true }
        let number = CountdownNumber()
        let run = Task {
            let finished = await RecordCore.countdown(seconds) { number.value = $0 }
            // Fade the backing out first, so the recording starts on a clean screen. Esc closes it at once.
            if finished { await number.fadeOut() }
            return finished
        }
        let size = CGSize(width: 220, height: 220)
        let panel = FloatingPanel(size: size, level: .screenSaver) { CountdownView(number: number) { run.cancel() } }
        panel.hasShadow = false // the window is square; a shadow would outline it around the round glass
        let f = Self.recordedFrame(source) ?? Self.screen(for: source).frame
        panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        countdownPanel = panel
        defer {
            panel.close()
            countdownPanel = nil
        }
        return await run.value
    }

    /// Live webcam bubble for framing yourself. It's one of our windows, so it never shows up in the recording.
    func showCameraPreview(session: AVCaptureSession) {
        guard preview == nil else { return }
        let screen = ActiveScreen.current()
        let size = CGSize(width: 180, height: 180)
        let shown = BubbleShown()
        let panel = FloatingPanel(size: size, level: .statusBar) { CameraBubble(session: session, shown: shown) }
        let f = screen.screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: f.maxX - size.width - 32, y: f.minY + 32))
        panel.orderFrontRegardless()
        preview = panel
        previewShown = shown
        withAnimation(Motion.enter) { shown.value = true }
    }

    /// Fades the bubble out the way it came, then closes it. A new one can open meanwhile.
    func closeCameraPreview() {
        guard let panel = preview else { return }
        preview = nil
        withAnimation(Motion.exit) { previewShown?.value = false } completion: { panel.close() }
        previewShown = nil
    }

    func showBar() {
        closeBar()
        let screen = ActiveScreen.current()
        let size = CGSize(width: 1000, height: 68)
        let panel = FloatingPanel(size: size) { RecordBar(screen: screen) }
        panel.setFrameOrigin(screen.bottomCentre(size))
        panel.makeKeyAndOrderFront(nil)
        bar = panel
    }

    /// The window's shadow follows the bar's shape once it has faded in; drawn while it was still clear, it would be missing.
    func refreshBarShadow() { bar?.invalidateShadow() }

    func closeBar() {
        bar?.close()
        bar = nil
        meter.use(nil)
        showOutline(nil)
        closePicker()
    }

    /// Outlines the display a Screen recording will capture and names it, behind the bar; nil hides it.
    func showOutline(_ screen: ActiveScreen?) {
        outline?.close()
        outline = nil
        guard let screen, let bar else { return }
        let f = screen.screen.frame
        let panel = FloatingPanel(size: f.size) { ScreenOutline(name: screen.screen.localizedName) }
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.setFrame(f, display: false)
        panel.order(NSWindow.OrderingMode.below, relativeTo: bar.windowNumber)
        outline = panel
    }

    /// Hides the bar while the full-screen picker is up; Esc brings it back.
    func pick(_ mode: PickMode, on screen: ActiveScreen, mic: String?) {
        bar?.orderOut(nil)
        let win = PickerWindow(contentRect: screen.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Over the Dock and menu bar, but under menus, so the window toolbar's Size menu opens on top.
        win.level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false // set explicitly: catch clicks on transparent pixels too
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstMouseHostingView(rootView: PickerOverlay(mode: mode, screen: screen, onDone: { [weak self] source in
            self?.closePicker()
            if let source {
                Task { await Studio.shared.start(source, microphone: mic) }
            } else {
                self?.bar?.makeKeyAndOrderFront(nil)
            }
        }))
        // Without this the hosting view sizes the window to the overlay's ideal size, which is tiny, instead of
        // the whole screen, and every click lands on the windows underneath.
        host.sizingOptions = []
        win.contentView = host
        win.setFrame(screen.screen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        picker = win
    }

    private func closePicker() {
        picker?.orderOut(nil)
        picker = nil
    }

    /// Shows the recording pill where it was last dragged, or where it covers least, with the microphone's level.
    /// Dims everything that isn't being recorded, on every display, from the countdown until the recording ends: all
    /// but the window or area, or the other displays for a whole display. It's made of our windows, so it's left out
    /// of the video.
    func showRecordedDim(_ source: CaptureSource) {
        closeRecordedDim()
        let isWindow = if case .window = source { true } else { false }
        let hole = RecordedHole()
        hole.rect = Self.recordedFrame(source)
        let recordedScreen: NSScreen? = if case .display = source { Self.screen(for: source) } else { nil }
        for screen in NSScreen.screens where screen != recordedScreen {
            let f = screen.frame
            let panel = FloatingPanel(size: f.size) { RecordedDim(hole: hole, screen: f, rounded: isWindow) }
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.setFrame(f, display: false)
            panel.orderFrontRegardless()
            dimPanels.append(panel)
        }
        guard isWindow else { return }
        // A recorded window can be moved; the clear part goes with it.
        followWindow = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if let r = Self.recordedFrame(source), r != hole.rect { hole.rect = r }
            }
        }
    }

    func closeRecordedDim() {
        followWindow?.cancel()
        followWindow = nil
        dimPanels.forEach { $0.close() }
        dimPanels = []
    }

    private var dimPanels: [FloatingPanel] = []
    /// The dim's window numbers: it lets clicks through, so a press on it is a click in what's recorded.
    var dimWindows: Set<CGWindowID> { Set(dimPanels.map { CGWindowID($0.windowNumber) }) }
    private var followWindow: Task<Void, Never>?

    func showHUD(on source: CaptureSource, microphone: String?) {
        closePill()
        let size = CGSize(width: 500, height: 60)
        let panel = FloatingPanel(size: size, level: .statusBar) {
            RecordingHUD(microphone: microphone != nil, camera: Studio.shared.camera.isActive)
        }
        panel.hasShadow = false // the pill changes size inside the panel; a window shadow would keep the old outline
        panel.setFrameOrigin(Self.savedHUDOrigin(size) ?? Self.hudOrigin(size, avoiding: source))
        panel.orderFrontRegardless()
        hudMoved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.hudOriginKey) }
        }
        meter.use(microphone)
        hud = panel
    }

    /// Closes the pill and the outline around what was recorded.
    func closeHUD() {
        closeRecordedDim()
        closePill()
    }

    private func closePill() {
        hudMoved.map(NotificationCenter.default.removeObserver)
        hudMoved = nil
        hud?.close()
        hud = nil
        meter.use(nil)
    }

    private var hudMoved: NSObjectProtocol?
    private static let hudOriginKey = "hudOrigin"

    /// Where the pill was dragged to, if that's still on a display. It may have been dragged while collapsed, so the
    /// panel is pulled fully onto the display, where the expanded pill fits too.
    private static func savedHUDOrigin(_ size: CGSize) -> CGPoint? {
        guard let s = UserDefaults.standard.string(forKey: hudOriginKey) else { return nil }
        let origin = NSPointFromString(s), centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let f = NSScreen.screens.first(where: { $0.frame.contains(centre) })?.frame else { return nil }
        return CGPoint(x: min(max(origin.x, f.minX), f.maxX - size.width), y: min(max(origin.y, f.minY), f.maxY - size.height))
    }

    /// Outside the recorded window or area, or a bottom corner for a whole display.
    private static func hudOrigin(_ size: CGSize, avoiding source: CaptureSource) -> CGPoint {
        let avoid = recordedFrame(source)
        let screen = avoid.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? ActiveScreen.current().screen
        return pillOrigin(size: size, visible: screen.visibleFrame, avoid: avoid)
    }

    /// The display `source` records, or the one with the pointer.
    private static func screen(for source: CaptureSource) -> NSScreen {
        guard case .display(let id) = source else { return ActiveScreen.current().screen }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            ?? ActiveScreen.current().screen
    }

    /// The recorded window or area in AppKit's global space (y up); nil for a whole display.
    private static func recordedFrame(_ source: CaptureSource) -> CGRect? {
        let recorded: CGRect? = switch source {
        case .display: nil
        case .area(_, let r): r
        case .window(let id):
            ((CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first?[kCGWindowBounds as String] as! CFDictionary?)
                .flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        // CoreGraphics' top-left origin to AppKit's bottom-left.
        return recorded.map { CGRect(x: $0.minX, y: NSScreen.screens[0].frame.maxY - $0.maxY, width: $0.width, height: $0.height) }
    }
}

// MARK: - Record bar

enum PickMode: String, CaseIterable, Identifiable {
    case screen, window, area
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var symbol: String { ["screen": "display", "window": "macwindow", "area": "rectangle.dashed"][rawValue]! }
}

struct RecordBar: View {
    let screen: ActiveScreen
    @AppStorage("captureMode") private var mode: PickMode = .screen
    @AppStorage("microphoneID") private var micID = ""
    @AppStorage(Studio.systemAudioKey) private var systemAudio = false
    @AppStorage(Studio.keystrokesKey) private var keystrokes = true
    @AppStorage(Studio.hideDesktopIconsKey) private var hideDesktopIcons = true
    @AppStorage("cameraID") private var cameraID = ""
    @AppStorage(Studio.countdownKey) private var countdown = 3
    @State private var notesOpen = false
    @Bindable private var prompter = Teleprompter.shared
    @State private var mics: [Microphone] = []
    @State private var cameras: [CameraDevice] = []
    @State private var starting = false
    /// False until the bar has faded in, and again while ✕ fades it out.
    @State private var shown = false
    @State private var hoveredMode: PickMode?
    @Namespace private var tiles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One height for the pickers and toggles; only the mode tiles and Record are taller.
    private static let controlHeight: CGFloat = 28

    var body: some View {
        // One gap between groups (and either side of each divider); controls inside a group sit closer.
        HStack(spacing: Space.m) {
            Button(action: leave) {
                Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                    .frame(width: Self.controlHeight, height: Self.controlHeight).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Close (Esc)")
            .accessibilityLabel("Close")

            Divider().frame(height: 30)

            // What to record. The selected fill slides to the clicked tile; with Reduce Motion it fades instead.
            HStack(spacing: Space.xxs) {
                ForEach(PickMode.allCases) { m in
                    Button { mode = m } label: {
                        VStack(spacing: Space.xxs) {
                            Image(systemName: m.symbol).font(.title2.weight(.regular)).frame(height: 20)
                            Text(m.name).font(.subheadline.weight(.medium))
                        }
                        .frame(width: 66, height: 50)
                        .foregroundStyle(mode == m ? Color.primary : Color.secondary)
                        .background {
                            if mode == m, reduceMotion {
                                RoundedRectangle(cornerRadius: Radius.medium).fill(.faint(0.12))
                            } else if mode != m, hoveredMode == m {
                                RoundedRectangle(cornerRadius: Radius.medium).fill(.faint(0.05))
                            }
                        }
                        .matchedGeometryEffect(id: m, in: tiles)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .onHover { inside in hoveredMode = inside ? m : hoveredMode == m ? nil : hoveredMode }
                }
            }
            // One fill that follows the selected tile, so it moves rather than jumping.
            .background {
                if !reduceMotion {
                    RoundedRectangle(cornerRadius: Radius.medium).fill(.faint(0.12))
                        .matchedGeometryEffect(id: mode, in: tiles, isSource: false)
                }
            }
            .motion(Motion.move, value: mode)
            .motion(Motion.hover, value: hoveredMode)

            Divider().frame(height: 30)

            // What to hear and see: one group, the microphone with its level, then the camera.
            HStack(spacing: Space.l) {
                HStack(spacing: Space.s) {
                    Picker(selection: $micID) {
                        Text("No microphone").tag("")
                        if !mics.isEmpty { Divider() }
                        ForEach(mics) { Text($0.name).tag($0.id) }
                    } label: {
                        Image(systemName: micID.isEmpty ? "mic.slash" : "mic")
                    }
                    .controlSize(.large)
                    .fixedSize() // the whole name, not "MacBook…"
                    .help("Microphone")

                    // Before recording, not after: a denied microphone otherwise records silence.
                    if !micID.isEmpty, PermissionCenter.shared.state(.microphone) == .denied {
                        Button { Task { await PermissionCenter.shared.request(.microphone) } } label: {
                            Image(systemName: "exclamationmark.triangle.fill").frame(width: 22, height: 26).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.yellow)
                        .help("Microphone access is off. Click to allow it in System Settings.")
                        .accessibilityLabel("Microphone access is off. Allow…")
                    } else if !micID.isEmpty {
                        MicLevel()
                    }
                }

                Picker(selection: $cameraID) {
                    Text("No camera").tag("")
                    if !cameras.isEmpty { Divider() }
                    ForEach(cameras) { c in Label(c.name, systemImage: c.isPhone ? "iphone" : "web.camera").tag(c.id) }
                } label: {
                    Image(systemName: cameraID.isEmpty ? "video.slash" : "video")
                }
                .controlSize(.large)
                .fixedSize()
                .help("Camera — your iPhone appears here through Continuity Camera")
                .onChange(of: cameraID) { _, id in Task { await Studio.shared.useCamera(id.isEmpty ? nil : id) } }
            }

            Spacer(minLength: 0)

            // Set-and-forget switches, each spelled out with a checkmark; Settings › General has the same ones.
            Menu("Options") {
                Toggle("Record System Audio", isOn: $systemAudio)
                Toggle("Show Keyboard Shortcuts", isOn: Binding(get: { keystrokes }, set: { on in
                    keystrokes = on
                    // Capturing keys needs Input Monitoring, asked for when it's turned on. Without it, recordings just have no keys.
                    if on, PermissionCenter.shared.state(.inputMonitoring) != .allowed {
                        Task { await PermissionCenter.shared.request(.inputMonitoring) }
                    }
                }))
                // Window recordings never include the desktop, so there it doesn't apply.
                Toggle("Hide Desktop Icons and Widgets", isOn: $hideDesktopIcons).disabled(mode == .window)
                Picker("Countdown", selection: $countdown) {
                    Text("None").tag(0)
                    Text("3 Seconds").tag(3)
                    Text("5 Seconds").tag(5)
                }
                Divider()
                Button("Speaker Notes…") { notesOpen = true }
                Toggle("Show Teleprompter", isOn: $prompter.showsWhileRecording)
                if !cameraID.isEmpty {
                    Divider()
                    Button("Video Effects…") { CameraRig.showVideoEffects() }
                }
            }
            .menuStyle(.button)
            .controlSize(.large)
            .fixedSize()
            .help("System audio, shortcuts in the video, desktop icons and widgets, countdown, speaker notes and video effects")
            .popover(isPresented: $notesOpen, arrowEdge: .top) { NotesEditor() }
            .padding(.trailing, -Space.xs) // Options and Record read as one pair

            // The bar's one prominent control: a graphite capsule, with the red dot only when it records. Window and
            // Area pick what to record first, so the button selects rather than records until then. One width for every
            // label, so the bar doesn't shift.
            Button(action: record) {
                HStack(spacing: Space.s) {
                    if mode == .screen { Circle().fill(.record).frame(width: 10, height: 10) } else { Image(systemName: mode.symbol) }
                    Text(starting ? "Starting…" : mode == .screen ? "Record" : "Select…")
                }
                .frame(width: 96, height: Self.controlHeight)
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(starting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.outer(Radius.medium, inset: 9))) // concentric with the 50-pt mode tiles in the 68-pt bar
        // Materialises where it opens, rising from its bottom edge; Esc closes it at once, ✕ fades it out.
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(Motion.enter.respecting(reduceMotion)) { shown = true } completion: { Panels.shared.refreshBarShadow() }
        }
        .onExitCommand { Studio.shared.cancelNewRecording() }
        // With more than one display, show which one a Screen recording captures.
        .onHover { inside in Panels.shared.showOutline(inside && mode == .screen && NSScreen.screens.count > 1 ? screen : nil) }
        .onChange(of: micID) { listen() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
        .task {
            PermissionCenter.shared.refresh() // the bar doesn't activate the app, so coming back from System Settings won't
            refreshDevices()
            if !cameraID.isEmpty {
                if cameras.contains(where: { $0.id == cameraID }) { await Studio.shared.useCamera(cameraID) } else { cameraID = "" }
            }
            mics = Microphone.all()
            if !micID.isEmpty, !mics.contains(where: { $0.id == micID }) { micID = mics.first?.id ?? "" }
            if micID.isEmpty, UserDefaults.standard.object(forKey: "microphoneID") == nil { micID = mics.first?.id ?? "" }
            listen()
        }
    }

    private func leave() {
        withAnimation(Motion.exit.respecting(reduceMotion)) { shown = false } completion: { Studio.shared.cancelNewRecording() }
    }

    /// Feeds the level meter from the chosen microphone, once it's allowed; asking happens at Record.
    private func listen() {
        Panels.shared.meter.use(PermissionCenter.shared.state(.microphone) == .allowed && !micID.isEmpty ? micID : nil)
    }

    private func refreshDevices() {
        mics = Microphone.all()
        cameras = CameraRig.devices()
    }

    private func record() {
        let permissions = PermissionCenter.shared
        guard permissions.state(.screenRecording) == .allowed else {
            Studio.shared.cancelNewRecording()
            // The first time, macOS's own prompt says what to do; after that, explain it and offer a relaunch.
            if permissions.state(.screenRecording) == .notAsked { Task { await permissions.request(.screenRecording) } }
            else { permissions.explainScreenRecording() }
            return
        }
        let mic = micID.isEmpty ? nil : micID
        // Asked here rather than left to ScreenCaptureKit, whose silent fallback is a recording with no sound.
        if mic != nil, permissions.state(.microphone) == .notAsked {
            Task {
                await permissions.request(.microphone)
                // Turned down: stay on the bar, where the microphone now shows its warning.
                if permissions.state(.microphone) == .allowed { record() }
            }
            return
        }
        if mode == .screen {
            starting = true
            Task { await Studio.shared.start(.display(screen.id), microphone: mic) }
        } else {
            Panels.shared.pick(mode, on: screen, mic: mic)
        }
    }
}

/// The record bar's main button, and Record in the pickers: a graphite capsule, drawn here rather than by AppKit so it
/// stays filled while the panel isn't the key window. Sinks slightly while held.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color(light: .white, dark: .black))
            .padding(.horizontal, Space.m)
            .background(.graphite, in: .capsule)
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(.capsule)
            .pressed(configuration.isPressed)
    }
}

/// Five bars that light up with the microphone's level, so a silent take is caught before it's recorded. They rise at
/// once and fall slowly, so they read as a level rather than flicker.
private struct MicLevel: View {
    @State private var shown = 0.0
    var body: some View {
        let lit = Int((shown * 5).rounded(.up))
        HStack(spacing: Space.xxs) {
            ForEach(0..<5) { i in
                Capsule().fill(i < lit ? Color.green : Color.secondary.opacity(0.3)).frame(width: 3, height: 8 + CGFloat(i) * 2)
            }
        }
        .frame(height: 18, alignment: .bottom)
        .task {
            while !Task.isCancelled {
                shown = smoothedLevel(shown: shown, heard: Panels.shared.meter.level)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .help("Microphone level")
        .accessibilityHidden(true)
    }
}

/// The display a Screen recording captures, outlined and named; shown while hovering the bar with several displays.
/// The recorded window or area, in AppKit's global space; nil when nothing on this display is recorded.
@Observable private final class RecordedHole {
    var rect: CGRect?
}

/// One display's dim, with the recorded part left clear.
private struct RecordedDim: View {
    let hole: RecordedHole
    /// The display's frame, in AppKit's global space.
    let screen: CGRect
    let rounded: Bool

    var body: some View {
        var dim = Path(CGRect(origin: .zero, size: screen.size))
        if let r = hole.rect {
            // AppKit's global space (y up) to this view's (y down).
            let local = CGRect(x: r.minX - screen.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
            dim = dim.subtracting(Path(roundedRect: local, cornerRadius: rounded ? macWindowCornerPoints : 0))
        }
        return dim.fill(Color.black.opacity(0.6))
    }
}

private struct ScreenOutline: View {
    let name: String
    @State private var shown = false
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.record, lineWidth: 4)
            .overlay(alignment: .top) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                    .background(.record, in: .capsule)
                    .padding(.top, 40) // off-scale: clear of the menu bar
            }
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.hover) { shown = true } }
    }
}

// MARK: - Camera preview bubble

@MainActor @Observable
final class BubbleShown { var value = false }

struct CameraBubble: View {
    let session: AVCaptureSession
    let shown: BubbleShown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CameraLayerView(session: session)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .padding(Space.xs)
            // From the screen corner it sits in; only the fade with Reduce Motion.
            .scaleEffect(shown.value || reduceMotion ? 1 : 0.95, anchor: .bottomTrailing)
            .opacity(shown.value ? 1 : 0)
            .help("Your camera. Drag to move. It isn't captured in the screen recording.")
    }
}

struct CameraLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Countdown

@MainActor @Observable
final class CountdownNumber {
    var value = 0
    var gone = false

    func fadeOut() async {
        await withCheckedContinuation { done in
            withAnimation(Motion.exit) { gone = true } completion: { done.resume() }
        }
    }
}

struct CountdownView: View {
    let number: CountdownNumber
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.xs) {
            // Each digit comes in from 90% and the one before leaves growing to 105%, overlapping.
            ZStack {
                Text("\(number.value)")
                    .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit()) // off-scale: the countdown digits
                    .id(number.value)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .scale(scale: 1.05).combined(with: .opacity)))
            }
            .motion(Motion.enter, value: number.value)
            Text("Esc to cancel").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid rather than glass, so the ring reads over any content (and with Reduce Transparency).
        .background(.scrim(0.75), in: .circle)
        .opacity(number.gone ? 0 : 1)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { cancel(); return .handled }
        .onAppear { focused = true }
    }
}

// MARK: - Recording HUD

struct RecordingHUD: View {
    /// What's being recorded besides the screen, shown so a silent take or a forgotten camera is caught at once.
    let microphone: Bool
    let camera: Bool
    @State private var stopping = false
    @State private var confirmRestart = false
    @State private var hovering = false
    /// A few seconds without the pointer: just the dot and the time.
    @State private var idle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let studio = Studio.shared, paused = studio.isPaused
        // Stays expanded while paused, and when the menu bar had no room for its item, so the controls stay in reach.
        let collapsed = idle && !hovering && !paused && !confirmRestart && StatusItem.shared.isShowing
        HStack(spacing: Space.m) {
            if confirmRestart {
                // The controls slide aside for the question, and back.
                HStack(spacing: Space.m) { restartConfirmation }.transition(.slide(edge: .trailing))
            } else {
                status(paused)
                if !collapsed {
                    // The capsule widens first and the controls fade in once it's opening.
                    HStack(spacing: Space.m) { controls(paused) }
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.follow.respecting(reduceMotion)), removal: .opacity))
                }
            }
        }
        .padding(.leading, Space.l)
        .padding(.trailing, collapsed ? Space.l : Space.s)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .overlay { Capsule().strokeBorder(.orange, lineWidth: 2).opacity(paused ? 1 : 0) }
        .motion(Motion.move, value: paused)
        .fixedSize()
        .onHover { inside in withAnimation(Motion.enter.respecting(reduceMotion)) { hovering = inside } }
        .task(id: hovering) {
            guard !hovering else { return idle = false }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(Motion.exit.respecting(reduceMotion)) { idle = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recording: a pulsing red dot and the time. Paused: the word, in amber, and the time standing still.
    @ViewBuilder private func status(_ paused: Bool) -> some View {
        RecordingDot(paused: paused).frame(width: 12, height: 12)
        HStack(spacing: Space.s) {
            if paused { Text("Paused ·").font(.title3.weight(.semibold)).foregroundStyle(.orange).transition(.slide(edge: .trailing)) }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(formatTime(Studio.shared.recorder?.elapsed ?? 0))
                    .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit()) // off-scale: the recording timer
                    .foregroundStyle(paused ? .secondary : .primary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(paused ? "Paused" : "Recording")
    }

    @ViewBuilder private func controls(_ paused: Bool) -> some View {
        let studio = Studio.shared
        if !paused {
            if microphone { MicLevel() }
            if camera {
                Image(systemName: "web.camera.fill").font(.callout).foregroundStyle(.secondary)
                    .help("The camera is recording").accessibilityLabel("Camera on")
            }
        }
        Spacer(minLength: Space.s)
        Button { withAnimation(Motion.move.respecting(reduceMotion)) { confirmRestart = true } } label: {
            Image(systemName: "arrow.counterclockwise").font(.title3.weight(.semibold)).frame(width: 40, height: 40)
                .background(.quaternary, in: .circle)
        }
        .buttonStyle(PillButtonStyle())
        .disabled(stopping || studio.isPausing)
        .help("Restart: discard this take and start again")
        // ▶ Resume, spelled out, while paused; never the red of Stop next to it.
        Button { studio.togglePause() } label: {
            if paused {
                Label("Resume", systemImage: "play.fill").font(.body.weight(.semibold))
                    .padding(.horizontal, Space.m).frame(height: 40).background(.quaternary, in: .capsule)
            } else {
                Image(systemName: "pause.fill").font(.title3.weight(.bold)).frame(width: 40, height: 40)
                    .background(.quaternary, in: .circle)
            }
        }
        .buttonStyle(PillButtonStyle())
        .disabled(stopping || studio.isPausing)
        .help(pauseHelp(paused))
        Button {
            stopping = true
            Task { await Studio.shared.stop() }
        } label: {
            Label("Stop", systemImage: "stop.fill").font(.body.weight(.semibold))
                .padding(.horizontal, Space.m).frame(height: 40).background(.record, in: .capsule)
        }
        .buttonStyle(PillButtonStyle())
        .foregroundStyle(.white)
        .disabled(stopping)
        .help("Stop recording (⌘.)")
    }

    /// Asked once, in the pill: the take can't be got back from the app (it goes to the Trash).
    @ViewBuilder private var restartConfirmation: some View {
        Text("Discard this take?").font(.body.weight(.semibold))
        Spacer(minLength: Space.s)
        Button("Keep Recording") { withAnimation(Motion.move.respecting(reduceMotion)) { confirmRestart = false } }
            .keyboardShortcut(.cancelAction)
        Button("Restart") {
            confirmRestart = false
            stopping = true
            Task { await Studio.shared.restart() }
        }
        .buttonStyle(.borderedProminent)
        .tint(.record)
    }

    private func pauseHelp(_ paused: Bool) -> String {
        let key = ShortcutStore.shared.map[.pauseRecording].map { " (\($0.symbol))" } ?? ""
        return (paused ? "Resume recording" : "Pause recording") + key
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.circle)
            .pressed(configuration.isPressed, scale: 0.92)
    }
}

/// The recording light, pulsing; paused, it turns into the amber pause sign. It pulses again on resuming.
private struct RecordingDot: View {
    let paused: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: paused ? "pause.fill" : "circle.fill")
            .font(paused ? .subheadline.weight(.bold) : .caption)
            .foregroundStyle(paused ? AnyShapeStyle(.orange) : AnyShapeStyle(.record))
            .contentTransition(.symbolEffect(.replace))
            .opacity(pulse ? 0.35 : 1)
            .onChange(of: paused, initial: true) {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { pulse = false }
                guard !paused, !reduceMotion else { return }
                withAnimation(Motion.pulse) { pulse = true }
            }
    }
}

// MARK: - Menu bar item

@MainActor
final class StatusItem: NSObject {
    static let shared = StatusItem()
    private var item: NSStatusItem?
    private var timer: Timer?

    /// False when macOS had no room for the item in the menu bar (beside the notch), so it can't be the backup control.
    var isShowing: Bool { item?.button?.window?.occlusionState.contains(.visible) ?? false }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        item.button?.imagePosition = .imageLeading
        self.item = item
        update()
    }

    func update() {
        guard let item else { return }
        let recording = Studio.shared.isRecording, paused = Studio.shared.isPaused
        let menu = NSMenu()
        if recording {
            let pause = action(paused ? "Resume Recording" : "Pause Recording", key: "") { Studio.shared.togglePause() }
            pause.isEnabled = !Studio.shared.isPausing
            menu.autoenablesItems = false
            menu.addItem(pause)
            menu.addItem(action("Stop Recording", key: ".") { Task { await Studio.shared.stop() } })
        } else {
            menu.addItem(action("New Recording…", key: "n") { Studio.shared.newRecording() })
        }
        menu.addItem(action("Show RecordStudio", key: "") { Studio.shared.showMain() })
        menu.addItem(.separator())
        menu.addItem(action("Quit RecordStudio", key: "q") { NSApp.terminate(nil) })
        item.menu = menu
        item.button?.image = paused ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "RecordStudio, paused") : menuBarIcon(recording: recording)

        timer?.invalidate()
        timer = nil
        item.button?.title = ""
        if recording {
            let tick = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { StatusItem.shared.item?.button?.title = " " + formatTime(Studio.shared.recorder?.elapsed ?? 0) }
            }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        }
    }

    private func action(_ title: String, key: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let mi = ClosureMenuItem(title: title, keyEquivalent: key, run: run)
        return mi
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
