import AppKit
import RecordCore
import RecordKit
import SwiftUI

/// Full-screen overlay for choosing what to record. Area mode draws a selection to move, resize (by hand or to a video
/// size) and nudge, starting from last time's. Window mode selects the clicked window first, with a toolbar to resize
/// it to a video size. Both record on Record or Return.
/// Local coordinates are display points with a top-left origin, matching CoreGraphics global space.
struct PickerOverlay: View {
    let mode: PickMode
    let screen: ActiveScreen
    let onDone: (CaptureSource?) -> Void

    @State private var windows: [PickableWindow] = []
    @State private var hovered: PickableWindow?
    /// The clicked window, waiting for Record; its frame follows any resize.
    @State private var chosen: PickableWindow?
    @State private var resize: WindowResize?
    @State private var preset: SizePreset? // nil: the size it had
    @State private var note: String?
    @State private var customOpen = false
    @State private var customWidth = 1920
    @State private var customHeight = 1080
    @State private var area: CGRect?
    /// The area's size preset, whose shape handles keep; nil: free.
    @State private var areaPreset: SizePreset?
    /// The area when the current drag began, and whether it's being drawn rather than moved.
    @State private var dragStart: CGRect?
    @State private var drawing = false
    @State private var loadError: String?
    /// A handle is being dragged, so the rule-of-thirds guides show.
    @State private var resizingArea = false
    /// The chosen window's frame, pressed for a moment when it's clicked.
    @State private var settling = false
    /// The width of the window bar's top row, which the lines under it wrap within.
    @State private var confirmRowWidth: CGFloat?
    @AppStorage("restoreWindowSize") private var restoreAfter = true
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The last size picked for each app, by app name.
    private static let presetsKey = "windowSizeByApp"
    /// The last area recorded, in global points.
    private static let areaKey = "lastArea"
    private static var lastArea: CGRect? { UserDefaults.standard.string(forKey: areaKey).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }

    private var origin: CGPoint { screen.bounds.origin }
    private var scale: Double { screen.screen.backingScaleFactor }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }
    private var target: PickableWindow? { mode == .window ? chosen ?? hovered : nil }
    private var selection: CGRect? { mode == .area ? area : target.map { local($0.frame) } }

    /// Windows in front of the target, which cover part of it, so neither the highlight nor its outline crosses them.
    private var covering: [CGRect] {
        guard let target else { return [] }
        return windows.prefix(while: { $0.id != target.id }).map { local($0.frame) }
    }

    var body: some View {
        ZStack {
            // The clicks and drags go to this layer only, so the toolbar's buttons aren't also read as a pick.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Nearly invisible, but not fully transparent, so the window server sends clicks inside the
                    // selection cut-out to us instead of the window underneath.
                    Color.black.opacity(0.01)
                    if let s = selection {
                        let shown = Highlight(rect: s, rounded: mode == .window, covering: covering)
                        Group {
                            // Dim everything except the selection.
                            Highlight(rect: s, rounded: mode == .window, covering: covering, inverted: true).fill(Color.black.opacity(0.42))
                            // Drawn twice as wide and clipped, so the whole outline sits inside the selection.
                            shown.stroke(Color.graphite, lineWidth: 6).clipShape(shown)
                                .scaleEffect(settling && !reduceMotion ? 0.99 : 1, anchor: UnitPoint(x: s.midX / geo.size.width, y: s.midY / geo.size.height))
                            if mode == .area, dragStart != nil, drawing || resizingArea { thirds(s) }
                            if mode == .window || dragStart != nil {
                                // The window's name at its top-left; the area's size at its bottom-right, where the drag is.
                                label(s)
                                    .padding(Space.s)
                                    .frame(width: max(s.width, 0), height: max(s.height, 0), alignment: mode == .window ? .topLeading : .bottomTrailing)
                                    .offset(x: s.minX, y: s.minY)
                            }
                        }
                        // In Window mode the highlight glides to the window under the pointer; drawing an area follows
                        // the pointer exactly. With Reduce Motion it jumps.
                        .animation(mode == .window && !reduceMotion ? Motion.move : nil, value: s)
                        if mode == .area, s.width >= minimumArea, s.height >= minimumArea {
                            handles(s)
                        }
                    } else {
                        Rectangle().fill(Color.black.opacity(0.42))
                    }
                }
                .contentShape(.rect)
                .onContinuousHover { phase in
                    guard mode == .window, case .active(let p) = phase else { return }
                    hovered = window(at: p)
                }
                .gesture(mode == .area ? areaDrag : nil)
                .gesture(mode == .window ? windowTap : nil)
            }
            .ignoresSafeArea()

            toolbar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 64) // off-scale: clear of the Dock
            // Outside the drag layer, so dragging on the bar doesn't draw or move the selection.
            if mode == .area, let s = area, s.width >= minimumArea, s.height >= minimumArea {
                areaBar.position(barCentre(s, in: screen.bounds.size))
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { back(); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { k in
            guard let a = area else { return .ignored }
            let step = k.modifiers.contains(.shift) ? 10.0 : 1
            let d = switch k.key {
            case .leftArrow: CGSize(width: -step, height: 0)
            case .rightArrow: CGSize(width: step, height: 0)
            case .upArrow: CGSize(width: 0, height: -step)
            default: CGSize(width: 0, height: step)
            }
            area = moving(a, by: d, in: localBounds)
            return .handled
        }
        .task {
            focused = true
            if mode == .area, let last = Self.lastArea, screen.bounds.contains(last) { area = local(last) }
            guard mode == .window else { return }
            PermissionCenter.shared.refresh() // coming back from System Settings doesn't always activate the app
            await loadWindows()
        }
    }

    private func loadWindows() async {
        do { windows = try await Shareable.windows() } catch { loadError = error.localizedDescription }
    }

    private func window(at p: CGPoint) -> PickableWindow? { windows.first { local($0.frame).contains(p) } }

    private func name(_ w: PickableWindow) -> String { w.title.isEmpty ? w.app : "\(w.app) — \(w.title)" }

    private func pixels(_ s: CGSize) -> String { "\(Int((s.width * scale).rounded())) × \(Int((s.height * scale).rounded()))" }

    private func icon(_ w: PickableWindow) -> some View {
        Image(nsImage: NSRunningApplication(processIdentifier: w.pid)?.icon ?? NSWorkspace.shared.icon(for: .application))
            .resizable()
            .frame(width: 18, height: 18)
    }

    /// Area: the size being dragged. Window: a card with the app's icon, the window's name, and the app and the size the
    /// video will be, kept inside the highlighted frame.
    @ViewBuilder private func label(_ s: CGRect) -> some View {
        if let target {
            HStack(spacing: Space.s) {
                icon(target).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(target.title.isEmpty ? target.app : target.title).font(.headline).lineLimit(1)
                    Text("\(target.app) · \(pixels(s.size))").font(.subheadline).monospacedDigit().opacity(0.7).lineLimit(1)
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .frame(maxWidth: min(420, max(s.width - 2 * Space.s, 0)), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.scrim(0.8), in: .rect(cornerRadius: Radius.medium))
            .foregroundStyle(.white)
        } else {
            Text(pixels(s.size)).monospacedDigit()
                .font(.callout.weight(.medium))
                .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                .background(.scrim(0.75), in: .rect(cornerRadius: Radius.small))
                .foregroundStyle(.white)
        }
    }

    /// Rule-of-thirds lines across the area, while it's drawn or resized.
    private func thirds(_ s: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = s.minX + s.width * Double(i) / 3, y = s.minY + s.height * Double(i) / 3
                p.move(to: CGPoint(x: x, y: s.minY)); p.addLine(to: CGPoint(x: x, y: s.maxY))
                p.move(to: CGPoint(x: s.minX, y: y)); p.addLine(to: CGPoint(x: s.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var toolbar: some View {
        if let chosen { confirmBar(chosen).transition(.message(at: .bottom)) } else if mode == .area, let a = area, a.width >= minimumArea, a.height >= minimumArea {
            EmptyView() // the area's own bar, beside it
        } else {
            HStack(spacing: Space.m) {
                Text(hint).font(.body.weight(.medium))
                Button("Cancel") { back() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.vertical, Space.s).padding(.leading, Space.l).padding(.trailing, Space.s)
            .glassEffect(.regular, in: .capsule)
            .transition(.message(at: .bottom))
        }
    }

    private var hint: String {
        if let loadError { return loadError }
        return mode == .window ? "Click the window to record" : "Drag over the area to record"
    }

    private var canResize: Bool { PermissionCenter.shared.state(.accessibility) == .allowed }

    /// Record in the pickers, the same graphite capsule with the red dot as on the record bar.
    private var recordLabel: some View {
        HStack(spacing: Space.s) {
            Circle().fill(.record).frame(width: 10, height: 10)
            Text("Record")
        }
        .frame(minWidth: 72, minHeight: 28)
    }

    /// The selected window: its size, whether to put it back afterwards, then Cancel and Record at the end. As wide as
    /// its top row, on any display; the lines under it wrap within that width.
    private func confirmBar(_ w: PickableWindow) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                icon(w)
                Text(name(w)).font(.body.weight(.medium)).lineLimit(1).frame(maxWidth: 320, alignment: .leading).fixedSize()
                sizeMenu(w)
                Toggle("Put the window back afterwards", isOn: $restoreAfter)
                    .toggleStyle(.switch)
                    .disabled(preset == nil)
                Button("Cancel") { back(animated: true) }
                    .help("Choose another window (Esc)")
                    .padding(.leading, Space.m) // a wider gap before the actions
                Button { record(w) } label: { recordLabel }
                    .buttonStyle(RecordButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { confirmRowWidth = $0 }
            if note != nil || !canResize {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if !canResize {
                        // Resizing another app's window goes through Accessibility; without it, only the current size works.
                        HStack(spacing: Space.s) {
                            Text("Sizes resize the window for you, which needs Accessibility permission.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(PermissionCenter.shared.state(.accessibility) == .denied ? "Open System Settings" : "Allow…") {
                                // Leave the picker, which covers the screen, so macOS's prompt and System Settings show.
                                onDone(nil)
                                Task { await PermissionCenter.shared.request(.accessibility) }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                }
                // Within the top row's width, so a long line wraps rather than widening the bar.
                .frame(width: confirmRowWidth, alignment: .leading)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Space.s).padding(.horizontal, Space.l)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.large))
    }

    private func sizeMenu(_ w: PickableWindow) -> some View {
        let area = visibleArea
        return Menu {
            Button("Keep current size (\(pixels((resize?.original ?? w.frame).size)))") { apply(nil) }
            Divider()
            ForEach(SizePreset.all, id: \.self) { p in
                let fits = p.centred(in: area, scale: scale) != nil
                Button {
                    apply(p)
                } label: {
                    Text("\(p.size)  (\(p.name))")
                    if !fits { Text("Doesn't fit this display") }
                }
                .disabled(!fits || !canResize)
            }
            Divider()
            Button("Custom…") { customOpen = true }.disabled(!canResize)
        } label: {
            Text("Size: " + (preset.map { "\($0.size) (\($0.name))" } ?? "Current size"))
        }
        .fixedSize()
        .popover(isPresented: $customOpen, arrowEdge: .top) { customSize }
    }

    private var customSize: some View {
        let p = SizePreset(customWidth, customHeight, "Custom")
        let fits = p.centred(in: visibleArea, scale: scale) != nil
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                TextField("Width", value: $customWidth, format: .number.grouping(.never)).frame(width: 64)
                Text("×")
                TextField("Height", value: $customHeight, format: .number.grouping(.never)).frame(width: 64)
                Text("pixels").foregroundStyle(.secondary)
            }
            if !fits { Text("Doesn't fit this display").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Resize") {
                    customOpen = false
                    apply(p)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!fits || customWidth < 100 || customHeight < 100)
            }
        }
        .padding(Space.l)
    }

    /// The display's visible frame (inside the menu bar and Dock) in global points with a top-left origin.
    private var visibleArea: CGRect {
        let v = screen.screen.visibleFrame, top = NSScreen.screens[0].frame.maxY
        return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }

    private func choose(_ w: PickableWindow) {
        chosen = w
        // The frame sinks for a moment, answering the click.
        withAnimation(Motion.press) { settling = true } completion: { withAnimation(Motion.press) { settling = false } }
        if canResize, let key = (UserDefaults.standard.dictionary(forKey: Self.presetsKey) as? [String: String])?[w.app],
           let p = SizePreset(key: key), p.centred(in: visibleArea, scale: scale) != nil {
            apply(p)
        }
    }

    /// Resizes the window and centres it on the display, or puts it back to its own size (nil), and remembers the
    /// choice for the app.
    private func apply(_ p: SizePreset?) {
        guard let w = chosen else { return }
        preset = p
        note = nil
        var sizes = UserDefaults.standard.dictionary(forKey: Self.presetsKey) as? [String: String] ?? [:]
        sizes[w.app] = p?.key
        UserDefaults.standard.set(sizes, forKey: Self.presetsKey)

        guard let r = resize ?? WindowResize(w) else {
            if p != nil { note = "\(w.app) doesn't let RecordStudio resize this window." }
            return
        }
        resize = r
        r.set(p.flatMap { $0.centred(in: visibleArea, scale: scale) } ?? r.original)
        if let p, let f = r.frame {
            note = resizeShortfall(app: w.app, asked: p, got: (Int((f.width * scale).rounded()), Int((f.height * scale).rounded())))
        }
        // The window moved and came to the front: read the order and frames again, for the highlight.
        Task {
            await loadWindows()
            if let moved = windows.first(where: { $0.id == w.id }), chosen?.id == w.id { chosen = moved }
        }
    }

    /// One step back: from a selected window to picking again (putting it back as it was), or out of the picker. Only
    /// Cancel animates the toolbar away; Esc, from the keyboard, doesn't.
    private func back(animated: Bool = false) {
        guard chosen != nil else { return onDone(nil) }
        var t = Transaction()
        t.disablesAnimations = !animated
        withTransaction(t) { stepBack() }
    }

    private func stepBack() {
        if let resize, preset != nil { resize.set(resize.original) }
        resize = nil
        preset = nil
        note = nil
        chosen = nil
        Task { await loadWindows() }
    }

    private func record(_ w: PickableWindow) {
        if restoreAfter, preset != nil, let resize { Panels.shared.restoreAfterRecording = resize }
        onDone(.window(w.id))
    }

    private var localBounds: CGRect { CGRect(origin: .zero, size: screen.bounds.size) }

    /// Inside the selection it moves; outside, it draws a new one (free again).
    private var areaDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = area ?? .zero
                    drawing = !(area?.contains(v.startLocation) ?? false)
                    if drawing { areaPreset = nil }
                }
                if drawing {
                    let a = v.startLocation, b = CGPoint(x: min(max(v.location.x, 0), localBounds.maxX), y: min(max(v.location.y, 0), localBounds.maxY))
                    area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                } else if let start = dragStart {
                    area = moving(start, by: v.translation, in: localBounds)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Corner and edge handles to resize the selection, keeping a preset's shape.
    private func handles(_ s: CGRect) -> some View {
        ForEach(AreaHandle.all, id: \.self) { h in
            Circle()
                .fill(.white)
                .stroke(Color.graphite, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .frame(width: 24, height: 24) // a bigger target than the dot
                .contentShape(.rect)
                .position(x: s.midX + Double(h.x) * s.width / 2, y: s.midY + Double(h.y) * s.height / 2)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { v in
                        if dragStart == nil { dragStart = s; resizingArea = true }
                        guard let start = dragStart else { return }
                        let aspect = areaPreset.map { Double($0.width) / Double($0.height) }
                        area = resizing(start, h, by: v.translation, aspect: aspect, in: localBounds)
                    }
                    .onEnded { _ in dragStart = nil; resizingArea = false })
        }
    }

    /// The area's size menu, Cancel and Record, under the selection, or inside it at the bottom of the screen.
    private var areaBar: some View {
        HStack(spacing: Space.m) {
            areaSizeMenu
            Button("Cancel") { back() }.keyboardShortcut(.cancelAction)
            Button { recordArea() } label: { recordLabel }
                .buttonStyle(RecordButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.vertical, Space.s).padding(.horizontal, Space.m)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }

    private func barCentre(_ s: CGRect, in size: CGSize) -> CGPoint {
        // ponytail: the bar's size is estimated, not measured; it only decides the placement.
        let w = 380.0, h = 52.0, gap = 12.0
        let below = s.maxY + gap + h <= size.height - 72 // off-scale: clear of the Dock
        return CGPoint(x: min(max(s.midX, w / 2 + gap), size.width - w / 2 - gap),
                       y: below ? s.maxY + gap + h / 2 : s.maxY - gap - h / 2)
    }

    private var areaSizeMenu: some View {
        let size = area?.size ?? .zero
        return Menu {
            Toggle("Free", isOn: Binding(get: { areaPreset == nil }, set: { if $0 { areaPreset = nil } }))
            Divider()
            ForEach(SizePreset.all, id: \.self) { p in
                let fits = placed(p.points(scale: scale)) != nil
                Toggle(isOn: Binding(get: { areaPreset == p }, set: { _ in
                    areaPreset = p
                    area = placed(p.points(scale: scale))
                })) {
                    Text("\(p.size)  (\(p.name))")
                    if !fits { Text("Doesn't fit this display") }
                }
                .disabled(!fits)
            }
            if let last = Self.lastArea, screen.bounds.contains(last) {
                Divider()
                Button("Same as last time (\(pixels(last.size)))") {
                    areaPreset = nil
                    area = local(last)
                }
            }
        } label: {
            Text(pixels(size)).monospacedDigit()
        }
        .fixedSize()
        .help("Choose a video size, or drag the handles")
    }

    /// A selection of `size` points around the current one's centre.
    private func placed(_ size: CGSize) -> CGRect? {
        let a = area ?? localBounds
        return placing(size, around: CGPoint(x: a.midX, y: a.midY), in: localBounds)
    }

    private func recordArea() {
        guard let a = area, a.width >= minimumArea, a.height >= minimumArea else { return }
        let global = a.offsetBy(dx: origin.x, dy: origin.y).intersection(screen.bounds).integral
        UserDefaults.standard.set(NSStringFromRect(global), forKey: Self.areaKey)
        onDone(.area(screen.id, global))
    }

    private var windowTap: some Gesture {
        SpatialTapGesture(count: 1).onEnded { v in
            guard let hit = window(at: v.location), hit.id != chosen?.id else { return }
            if chosen != nil { back() }
            choose(hit)
        }
    }
}

/// Another app's window, moved and resized through Accessibility. Frames are global points with a top-left origin,
/// as in CoreGraphics.
@MainActor
final class WindowResize {
    private let element: AXUIElement
    /// Where the window was before it was first resized, to put it back.
    let original: CGRect

    init?(_ w: PickableWindow) {
        guard AXIsProcessTrusted() else { return nil }
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &list) == .success,
              let all = list as? [AXUIElement] else { return nil }
        // Accessibility doesn't share CoreGraphics' window ids, so match the frame, then the title if two match.
        let same = all.filter { e in
            guard let f = Self.frame(of: e) else { return false }
            return abs(f.minX - w.frame.minX) + abs(f.minY - w.frame.minY) + abs(f.width - w.frame.width) + abs(f.height - w.frame.height) < 4
        }
        guard let element = same.first(where: { Self.string($0, kAXTitleAttribute) == w.title }) ?? same.first else { return nil }
        self.element = element
        original = Self.frame(of: element) ?? w.frame
    }

    var frame: CGRect? { Self.frame(of: element) }

    /// Moves, resizes and raises the window. The size is set again after the move, since an app may limit its size
    /// by the space left on the display.
    func set(_ f: CGRect) {
        var size = f.size, origin = f.origin
        guard let s = AXValueCreate(.cgSize, &size), let o = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, o)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let o = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
              AXValueGetValue(o, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func value(_ e: AXUIElement, _ attribute: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

/// The selection, or with `inverted` everything around it, minus the windows covering it. Its frame animates, so the
/// window highlight can glide from one window to the next.
private struct Highlight: Shape {
    var rect: CGRect
    var rounded: Bool
    var covering: [CGRect] = []
    var inverted = false

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(rect.minX, rect.minY), AnimatablePair(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in bounds: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: rounded ? Radius.medium : 0)
        for c in covering where c.intersects(rect) { p = p.subtracting(Path(c)) }
        return inverted ? Path(bounds).subtracting(p) : p
    }
}
