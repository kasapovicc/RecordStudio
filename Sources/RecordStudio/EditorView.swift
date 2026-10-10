import AppKit
import Carbon.HIToolbox
import AVFoundation
import RecordCore
import RecordKit
import SwiftUI

struct EditorView: View {
    let rec: Recording
    @State private var model: EditorModel?

    var body: some View {
        Group {
            // The same canvas the stage opens on, for the moment before the model exists.
            if let model { EditorBody(model: model) } else { Color(nsColor: .underPageBackgroundColor) }
        }
        .task { if model == nil { model = EditorModel(rec: rec) }; Studio.shared.editor = model }
        .onDisappear { model?.close(); if Studio.shared.editor === model { Studio.shared.editor = nil } }
    }
}

private struct EditorBody: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A split view rather than .inspector, which runs its column (and its dividing line) up through the toolbar.
        HSplitView {
            VStack(spacing: 0) {
                Stage(model: model)
                Divider()
                TimelineDock(model: model).arriving(model.previewReady)
            }
            .layoutPriority(1) // spare width goes to the preview, so the inspector opens at its narrowest
            if model.showInspector, !model.inspectorFit.narrow {
                InspectorView(model: model).frame(minWidth: 320, maxWidth: 400).arriving(model.previewReady)
            }
        }
        // A fresh split view when the inspector moves between the side and floating: one that had it at the side keeps
        // the preview's old width when the window jumps narrow (tiling), so the preview and timeline spill off both edges.
        .id(model.inspectorFit.narrow)
        // Opaque: the library stays drawn under the pushed editor and would show through the split view's gaps
        // (under the inspector's tabs, above the timeline toolbar).
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            if model.showInspector, model.inspectorFit.narrow {
                // Floating over the preview: a soft shadow on its leading edge rather than a hard line.
                InspectorView(model: model).frame(width: 320).clipped()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: -2)
                    .transition(.slide(edge: .trailing))
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { model.inspectorFit.fit(width: $0, shown: &model.showInspector) }
        // The window's name (Window menu, Mission Control); the bar shows its own title, which looks renamable.
        .navigationTitle(model.title)
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        // Esc deselects; everything else follows the shortcuts set in Settings (Space, I, O, Delete and Z by default).
        .background(EditorKeys(model: model))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { TitleField(model: model) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button {
                // Slides when clicked; the View menu's shortcut shows or hides it at once, like every keyboard action.
                let showing = !model.showInspector
                withAnimation((showing ? Motion.enter : Motion.exit).respecting(reduceMotion)) { model.showInspector = showing }
            } label: {
                Label(model.showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .help(model.showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            // Every choice is in the sheet. While an export runs with the sheet closed, this shows how it's going.
            Button { model.openExport() } label: { ExportLabel(state: model.export) }
                .buttonStyle(.glassProminent)
                .help("Export (⌘E)")
        }
    }
}

/// The Export button's label. Every state is laid out at once and only the current one shows, so the button keeps
/// one width and the states cross-fade in place.
private struct ExportLabel: View {
    let state: ExportState

    private enum Phase { case idle, working, done, failed }
    private var phase: Phase {
        switch state {
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .failed: .failed
        }
    }

    var body: some View {
        ZStack {
            Text("Export…").opacity(phase == .idle ? 1 : 0)
            HStack(spacing: Space.xs) {
                if case .working(_, let p?) = state { ProgressView(value: p).progressViewStyle(.circular) } else { ProgressView() }
                Text("Exporting…")
            }
            .controlSize(.small)
            .opacity(phase == .working ? 1 : 0)
            Label("Exported", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).opacity(phase == .done ? 1 : 0)
            Label("Export Failed", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon).opacity(phase == .failed ? 1 : 0)
        }
        .motion(Motion.hover, value: phase)
    }
}

/// The recording's title, which looks like a field on hover and is one: click to rename, Return or clicking away
/// saves, Esc keeps the old name. The save state sits under it.
private struct TitleField: View {
    @Bindable var model: EditorModel
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xs) {
                // The hidden text sizes the field to its title, so the bar doesn't hold an empty stretch.
                Text(draft.isEmpty ? model.title : draft).lineLimit(1).hidden()
                    .overlay(alignment: .leading) {
                        TextField("Title", text: $draft).textFieldStyle(.plain).focused($focused)
                            .onSubmit(done)
                            .onExitCommand { draft = model.title; done() }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                Image(systemName: "pencil").foregroundStyle(.secondary).opacity(hovering && !focused ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.headline)
            Text(model.saveState).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .background(.faint(hovering || focused ? 0.06 : 0), in: .rect(cornerRadius: Radius.small))
        .motion(Motion.hover, value: hovering || focused)
        .onHover { hovering = $0 }
        .help("Click to rename")
        .onAppear { draft = model.title }
        .onChange(of: model.title) { if !focused { draft = model.title } }
        .onChange(of: focused) { if !focused { commit() } }
    }

    /// Leaves the field, so the editor's shortcuts work again.
    private func done() {
        focused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { draft = model.title } else { model.title = name } // an empty title keeps the old one
    }
}

extension View {
    /// Hidden until `ready`, then fading in just after it: the editor's timeline and inspector once the preview shows.
    func arriving(_ ready: Bool) -> some View { opacity(ready ? 1 : 0).motion(Motion.follow, value: ready) }
}

/// The editor's keyboard shortcuts, for key presses in its window that aren't typing. A window-level monitor rather than
/// SwiftUI focus, which a closing popover or a click on a control can take away, and which also hears keys typed into
/// text fields inside the editor. Popovers and sheets are windows of their own, so typing in them never reaches here.
private struct EditorKeys: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.model = model }

    final class KeyView: NSView {
        var model: EditorModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Only the plain values cross into the main actor, not the event itself.
                let from = event.window.map(ObjectIdentifier.init), escape = event.keyCode == UInt16(kVK_Escape), shortcut = Shortcut(event: event)
                let nudge = Self.nudge(event)
                let handled = MainActor.assumeIsolated { self?.handle(from: from, escape: escape, nudge: nudge, shortcut) == true }
                return handled ? nil : event
            }
        }

        /// An arrow key, with nothing held but ⇧, as a step in output pixels: 1, or 10 with ⇧.
        private static func nudge(_ event: NSEvent) -> (dx: Double, dy: Double)? {
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1
            switch Int(event.keyCode) {
            case kVK_LeftArrow: return (-step, 0)
            case kVK_RightArrow: return (step, 0)
            case kVK_UpArrow: return (0, -step)
            case kVK_DownArrow: return (0, step)
            default: return nil
            }
        }

        /// True when the key ran an editor action, so it goes no further.
        private func handle(from: ObjectIdentifier?, escape: Bool, nudge: (dx: Double, dy: Double)?, _ shortcut: Shortcut?) -> Bool {
            guard let model, let window, from == ObjectIdentifier(window) else { return false }
            model.keyPressedAt = CACurrentMediaTime() // what a key changes doesn't animate (see InspectorView)
            if let text = window.firstResponder as? NSTextView, text.isEditable { return false } // typing, e.g. a callout's text
            if escape {
                if model.cropping { model.cropping = false } else { model.deselect() }
                return true
            }
            // With a callout or annotation selected, the arrows move it rather than the playhead.
            if let nudge, model.moveSelection(dx: nudge.dx / Double(model.size.width), dy: nudge.dy / Double(model.size.height)) { return true }
            guard let shortcut, let action = ShortcutStore.shared.map.editorAction(for: shortcut) else { return false }
            model.perform(action)
            return true
        }
    }
}

// MARK: - Stage: the framed video, exactly as it will export

/// Outline and handles for the selected annotation. Shapes and images: drag the box to move it, the corner dot to resize.
/// Arrows: drag either end to aim it, the middle dot to move it. Like the bubble, it's saved once, on release.
private struct AnnotationHandles: View {
    @Bindable var model: EditorModel
    let index: Int
    @State private var draft: Annotation?

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            if let saved = model.edits.allAnnotations.indices.contains(index) ? model.edits.allAnnotations[index] : nil {
                let a = model.onCanvas(draft ?? saved)
                if a.kind == .arrow {
                    let tail = CGPoint(x: a.x * W, y: a.y * H), tip = CGPoint(x: (a.x + a.w) * W, y: (a.y + a.h) * H)
                    Path { p in p.move(to: tail); p.addLine(to: tip) }
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                    knob(at: tail, saved, W, H) { b, dx, dy in b.x += dx; b.y += dy; b.w -= dx; b.h -= dy }
                    knob(at: tip, saved, W, H) { b, dx, dy in b.w += dx; b.h += dy }
                    knob(at: CGPoint(x: (tail.x + tip.x) / 2, y: (tail.y + tip.y) / 2), saved, W, H, move: true) { b, dx, dy in b.x += dx; b.y += dy }
                } else {
                    let angle = a.rotation * .pi / 180
                    ZStack(alignment: .bottomTrailing) {
                        Rectangle().fill(Color.white.opacity(0.001))
                            .overlay(Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).shadow(color: .black.opacity(0.5), radius: 1))
                            .gesture(edit(saved, W, H) { b, dx, dy in b.x += dx; b.y += dy })
                            .help("Drag to move")
                        dot().offset(x: 6, y: 6)
                            .gesture(edit(saved, W, H) { b, dx, dy in
                                // Resize along the box's own axes, so a rotated box grows the way you pull.
                                let lx = dx * W * cos(angle) + dy * H * sin(angle), ly = -dx * W * sin(angle) + dy * H * cos(angle)
                                if let v = b.video {
                                    // A video keeps its shape: follow whichever way the pointer pulls further.
                                    let shape = Double(v.height) / Double(max(1, v.width)) // height ÷ width, in pixels
                                    let wide = max(0.02, max(b.w * W + lx, (b.h * H + ly) / shape))
                                    (b.w, b.h) = (wide / W, wide * shape / H)
                                } else {
                                    b.w = max(0.01, b.w + lx / W)
                                    b.h = max(0.01, b.h + ly / H)
                                }
                            })
                            .help("Drag to resize")
                    }
                    .frame(width: max(1, a.w * W), height: max(1, a.h * H))
                    .rotationEffect(.radians(angle))
                    .offset(x: a.x * W, y: a.y * H)
                }
            }
        }
    }

    private func dot(move: Bool = false) -> some View {
        // Over the video, so fixed colours rather than the appearance's: the move handle is the dark one.
        Circle().fill(move ? Color(white: 0.14) : .white) // off-scale: over the video, not the window
            .overlay(Circle().strokeBorder(move ? .white : .black.opacity(0.35)))
            .frame(width: 12, height: 12)
            .frame(width: 24, height: 24) // a bigger target than it looks
            .contentShape(.circle)
    }

    private func knob(at p: CGPoint, _ saved: Annotation, _ W: Double, _ H: Double, move: Bool = false,
                      _ change: @escaping (inout Annotation, Double, Double) -> Void) -> some View {
        dot(move: move)
            .position(p)
            .gesture(edit(saved, W, H, change))
            .help(move ? "Drag to move" : "Drag to aim")
    }

    /// A drag in screen points, handed to `change` as a fraction of the `W`×`H` canvas and applied to the saved
    /// annotation; committed on release.
    private func edit(_ saved: Annotation, _ W: Double, _ H: Double,
                      _ change: @escaping (inout Annotation, Double, Double) -> Void) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                var b = model.onCanvas(saved)
                change(&b, v.translation.width / max(1, W), v.translation.height / max(1, H))
                draft = model.inRecording(b, like: saved)
            }
            .onEnded { _ in
                if let draft, model.edits.allAnnotations.indices.contains(index) { model.edits.allAnnotations[index] = draft }
                draft = nil
            }
    }
}

/// An invisible handle over the webcam bubble: hover outlines it, and dragging moves an outline that drops the
/// bubble where you let go. The preview re-renders once, on drop, rather than on every step of the drag.
private struct BubbleHandle: View {
    @Bindable var model: EditorModel
    @State private var drag: CGSize?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            if let style = model.edits.camera {
                let size = model.size
                let k = geo.size.width / Double(size.width) // canvas pixels → points on screen
                let r = cameraRect(size, style, zoom: 1)
                let shape = RoundedRectangle(cornerRadius: bubbleCornerRadius(diameter: r.d, style) * k)
                shape
                    .fill(Color.white.opacity(0.001)) // invisible, but still catches the pointer
                    .overlay {
                        if hovering || drag != nil {
                            shape.strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                    }
                    .frame(width: r.d * k, height: r.d * k)
                    .offset(x: r.x * k + (drag?.width ?? 0), y: r.y * k + (drag?.height ?? 0))
                    .onHover { hovering = $0 }
                    .pointerStyle(.grabIdle)
                    // The bubble has no selection of its own: a click shows its settings.
                    .onTapGesture { model.deselect(); model.tab = .overlays }
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { v in
                                model.edits.camera?.center = cameraCenter(size, style, topLeft: r.x + v.translation.width / k,
                                                                          r.y + v.translation.height / k)
                                drag = nil
                            }
                    )
                    .help("Drag to move the webcam anywhere")
            }
        }
    }
}

/// What's drawn on the preview at the playhead, to click and drag: annotations, callouts and the caption, in the order
/// they're drawn so the topmost wins. Hovering outlines one, a click selects it, and dragging moves an outline that
/// snaps to the frame's edges and centre lines, dropping the item (and selecting it) on release. A click anywhere else
/// selects nothing.
private struct PreviewTargets: View {
    @Bindable var model: EditorModel
    @State private var hovered: Target?
    @State private var drag: (target: Target, offset: CGSize, guideX: Double?, guideY: Double?)?

    enum Target: Hashable { case annotation(Int), callout(Int), caption(Int) }

    /// A target's box on the canvas (normalized, top-left origin, before `rotation` in degrees about its centre).
    struct Item { let target: Target; let box: CGRect; var rotation = 0.0 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect).onTapGesture { model.deselect() }
                ForEach(items(), id: \.target) { item in
                    let moving = drag?.target == item.target, off = moving ? drag!.offset : .zero
                    let movable = if case .caption = item.target { false } else { true }
                    let selected = isSelected(item.target)
                    // A selected annotation has its own handles; anything else selected gets a steady outline.
                    let outline = moving || (selected && !isAnnotation(item.target)) ? 0.9 : hovered == item.target ? 0.5 : 0
                    Rectangle().fill(Color.white.opacity(0.001)) // invisible, but still catches the pointer
                        .overlay {
                            if outline > 0 {
                                Rectangle().strokeBorder(.white.opacity(outline), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .shadow(color: .black.opacity(0.5), radius: 1)
                            }
                        }
                        .frame(width: max(8, item.box.width * W), height: max(8, item.box.height * H))
                        .rotationEffect(.degrees(item.rotation))
                        .offset(x: item.box.minX * W + off.width, y: item.box.minY * H + off.height)
                        .onHover { inside in if inside { hovered = item.target } else if hovered == item.target { hovered = nil } }
                        .pointerStyle(movable ? .grabIdle : nil)
                        .onTapGesture { select(item.target) }
                        .gesture(move(item, W, H), including: movable ? .all : .subviews)
                }
                // Alignment guides while a snapped drag holds.
                if let x = drag?.guideX { guide().frame(width: 1, height: H).offset(x: x * W) }
                if let y = drag?.guideY { guide().frame(width: W, height: 1).offset(y: y * H) }
            }
        }
    }

    private func guide() -> some View { Rectangle().fill(.graphite).allowsHitTesting(false) }

    private func move(_ item: Item, _ W: Double, _ H: Double) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in
                let b = item.box
                // Snap within 6 points.
                let s = snapBox(x: b.minX + v.translation.width / W, y: b.minY + v.translation.height / H, w: b.width, h: b.height,
                                within: (6 / W, 6 / H))
                drag = (item.target, CGSize(width: (s.x - b.minX) * W, height: (s.y - b.minY) * H), s.guideX, s.guideY)
            }
            .onEnded { _ in
                if let d = drag {
                    select(item.target)
                    // A callout held inside the canvas is drawn left of or above its own x, y: move it from where it's drawn.
                    var (dx, dy) = (d.offset.width / W, d.offset.height / H)
                    if case .callout(let i) = item.target, model.edits.callouts.indices.contains(i) { (dx, dy) = (dx + item.box.minX - model.edits.callouts[i].x, dy + item.box.minY - model.edits.callouts[i].y) }
                    model.moveSelection(dx: dx, dy: dy)
                }
                drag = nil
                hovered = nil // it moved out from under the hover tracking, which won't notice the pointer leaving
            }
    }

    private func items() -> [Item] {
        let e = model.edits, t = model.time, size = model.size
        var out: [Item] = []
        for (i, a) in e.allAnnotations.enumerated() where annotationOpacity(a, at: t) > 0 {
            let b = model.onCanvas(a)
            // An arrow's box runs from its tail to its head, so it can be flipped.
            out.append(Item(target: .annotation(i), box: CGRect(x: min(b.x, b.x + b.w), y: min(b.y, b.y + b.h), width: abs(b.w), height: abs(b.h)),
                            rotation: a.kind == .arrow ? 0 : a.rotation))
        }
        for (i, k) in e.callouts.enumerated() where t >= k.start && t <= k.end {
            // ponytail: draws the callout's text to measure it on every redraw; cache by text if playback stutters.
            guard let img = FrameRenderer.calloutImage(k.text, canvasWidth: Double(size.width), canvasHeight: Double(size.height)) else { continue }
            let w = img.extent.width / Double(size.width), h = img.extent.height / Double(size.height), o = calloutOrigin(k, w: w, h: h)
            out.append(Item(target: .callout(i), box: CGRect(x: o.x, y: o.y, width: w, height: h)))
        }
        if let box = model.captionBox(at: t), let i = e.captions?.lines.lastIndex(where: { t >= $0.start && t < $0.end }) {
            out.append(Item(target: .caption(i), box: box))
        }
        return out
    }

    private func isAnnotation(_ t: Target) -> Bool { if case .annotation = t { true } else { false } }

    private func isSelected(_ t: Target) -> Bool {
        switch t {
        case .annotation(let i): model.selectedAnnotation == i
        case .callout(let i): model.selectedCallout == i
        case .caption(let i): model.selectedCaption == i
        }
    }

    private func select(_ t: Target) {
        switch t {
        case .annotation(let i): model.selectedAnnotation = i
        case .callout(let i): model.selectedCallout = i
        case .caption(let i): model.selectedCaption = i
        }
    }
}

/// The selected zoom's area, over the whole frame (the preview leaves the zoom out while it's selected). Drag the box
/// to pin the zoom there, or its corner to change how far it zooms in; saved on release.
private struct ZoomFrame: View {
    @Bindable var model: EditorModel
    let index: Int
    @State private var draft: Zoom?

    var body: some View {
        GeometryReader { geo in
            if model.edits.zooms.indices.contains(index) {
                let saved = model.edits.zooms[index], z = draft ?? saved
                let size = model.size
                // The cropped recording's area on screen, in points.
                let content = CGRect(x: Double(size.x) / Double(size.width) * geo.size.width, y: Double(size.y) / Double(size.height) * geo.size.height,
                                     width: Double(size.contentW) / Double(size.width) * geo.size.width,
                                     height: Double(size.contentH) / Double(size.height) * geo.size.height)
                let c = centre(z)
                let box = CGRect(x: content.minX + (c.x - 0.5 / z.scale) * content.width, y: content.minY + (c.y - 0.5 / z.scale) * content.height,
                                 width: content.width / z.scale, height: content.height / z.scale)
                ZStack(alignment: .topLeading) {
                    Path { p in p.addRect(content); p.addRect(box) }
                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: Radius.small)
                            .fill(Color.white.opacity(0.001))
                            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                                .stroke(z.focus == nil ? Color.white.opacity(0.8) : Color.zoomClip,
                                        style: StrokeStyle(lineWidth: 2, dash: z.focus == nil ? [5, 3] : [])))
                            .pointerStyle(.grabIdle)
                            .gesture(edit(saved, content) { z, dx, dy in
                                let half = 0.5 / z.scale, c = centre(z)
                                z.focus = Point(x: round3(min(1 - half, max(half, c.x + dx))), y: round3(min(1 - half, max(half, c.y + dy))))
                            })
                            .help(z.focus == nil ? "Drag to pin the zoom to this area" : "Drag to choose what the zoom shows")
                        Circle().fill(.white).overlay(Circle().strokeBorder(.black.opacity(0.35))) // off-scale: over the video
                            .frame(width: 12, height: 12).frame(width: 24, height: 24).contentShape(.circle)
                            .offset(x: 6, y: 6)
                            .pointerStyle(.frameResize(position: .bottomTrailing))
                            .gesture(edit(saved, content) { z, dx, _ in
                                // The box keeps its centre and the frame's shape; wider zooms out.
                                let c = centre(z)
                                z.scale = min(4, max(1.2, (1 / max(0.01, 1 / z.scale + 2 * dx) * 10).rounded() / 10))
                                if z.focus != nil {
                                    let half = 0.5 / z.scale
                                    z.focus = Point(x: round3(min(1 - half, max(half, c.x))), y: round3(min(1 - half, max(half, c.y))))
                                }
                            })
                            .help("Drag to zoom in or out")
                    }
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                }
            }
        }
    }

    /// Where the zoom looks, in the cropped recording (normalized): its pinned focus, or where the cursor-following
    /// camera is halfway through it, kept inside the frame.
    private func centre(_ z: Zoom) -> Point {
        let half = 0.5 / z.scale
        let c = z.focus ?? {
            let full = model.edits // the camera with every zoom, as the export has it
            let a = cameraAt(cameraPath(model.cursor, full, duration: model.rec.duration), (z.start + z.end) / 2)
            return Point(x: a.x, y: a.y)
        }()
        return Point(x: min(1 - half, max(half, c.x)), y: min(1 - half, max(half, c.y)))
    }

    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// A drag, handed to `change` as a fraction of the recording's area on screen and applied to the saved zoom;
    /// committed on release.
    private func edit(_ saved: Zoom, _ content: CGRect, _ change: @escaping (inout Zoom, Double, Double) -> Void) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                var z = saved
                change(&z, v.translation.width / max(1, content.width), v.translation.height / max(1, content.height))
                draft = z
            }
            .onEnded { _ in
                if let draft, model.edits.zooms.indices.contains(index) { model.edits.zooms[index] = draft }
                draft = nil
            }
    }
}

private struct Stage: View {
    @Bindable var model: EditorModel
    /// The crop's shape while cropping (width ÷ height in pixels); nil = free.
    @State private var cropAspect: Double?
    @State private var hovering = false

    var body: some View {
        let aspect = model.cropping ? Double(model.rec.width) / Double(model.rec.height) : Double(model.size.width) / Double(model.size.height)
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            PlayerLayerView(player: model.player) { model.previewReady = true }
                .aspectRatio(aspect, contentMode: .fit)
                // Until the first frame is drawn, the library's frame of the recording, blurred, cross-fading to it.
                .overlay { if !model.previewReady { OpeningPoster(rec: model.rec).transition(.opacity) } }
                .motion(Motion.enter, value: model.previewReady)
                .overlay {
                    if model.cropping {
                        CropOverlay(crop: $model.edits.crop, aspect: cropAspect, source: (Double(model.rec.width), Double(model.rec.height)))
                    }
                }
                .overlay { if !model.cropping { PreviewTargets(model: model) } }
                .overlay { if !model.cropping, model.edits.camera?.visible == true { BubbleHandle(model: model) } }
                .overlay {
                    if !model.cropping, let i = model.selectedAnnotation, model.edits.allAnnotations.indices.contains(i),
                       annotationOpacity(model.edits.allAnnotations[i], at: model.time) > 0 {
                        AnnotationHandles(model: model, index: i)
                    }
                }
                .overlay { if !model.cropping, let i = model.selectedZoom, model.edits.zooms.indices.contains(i) { ZoomFrame(model: model, index: i) } }
                .clipShape(.rect(cornerRadius: model.cropping ? Radius.small : Radius.medium))
                // A hairline, so the frame's own background never blurs into the canvas around it.
                .overlay {
                    RoundedRectangle(cornerRadius: model.cropping ? Radius.small : Radius.medium)
                        .strokeBorder(.faint(0.12), lineWidth: 1).allowsHitTesting(false)
                }
                // A video dropped on the preview plays over the recording from the playhead.
                .dropDestination(for: URL.self) { urls, _ in
                    guard !model.cropping, let url = urls.first(where: { Importer.extensions.contains($0.pathExtension.lowercased()) }) else { return false }
                    model.addVideoOverlay(from: url)
                    return true
                }
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .padding(Space.xl)
        }
        // The frame's size and shape, on hover, in the canvas's bottom corner: there when you look for it.
        .overlay(alignment: .bottomTrailing) {
            if hovering, !model.cropping {
                Text(frameLabel(model.size)).font(.caption).monospacedDigit().foregroundStyle(.quiet)
                    .padding(.trailing, Space.xl).padding(.bottom, Space.xs)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        // The first recordings' checklist, out of the way while cropping. It fades, and nothing else about it moves.
        .overlay(alignment: .topLeading) {
            let shows = TipStore.shared.state.showsCard && model.previewReady && !model.cropping
            ZStack {
                if shows { NextStepsCard(hasAudio: model.rec.hasAudio).padding(Space.l).transition(.opacity) }
            }
            .motion(Motion.hover, value: shows)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: Space.s) {
                if let progress = model.progress { ProgressCapsule(text: progress).transition(.message(at: .bottom)) }
                if let toast = model.toast { ToastView(toast: toast) { model.toast = nil }.transition(.message(at: .bottom)) }
                if model.cropping { cropBar }
            }
            .padding(Space.s)
        }
        // A toast goes away by itself after a few seconds; a newer one starts the wait again.
        .task(id: model.toast?.text) {
            guard model.toast != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { model.toast = nil }
        }
    }

    /// The crop's size in pixels, its shape, Reset and Done, under the frame being cropped.
    private var cropBar: some View {
        let c = model.edits.crop, source = (w: Double(model.rec.width), h: Double(model.rec.height))
        return HStack(spacing: Space.m) {
            Text(verbatim: "\(Int((c.w * source.w).rounded())) × \(Int((c.h * source.h).rounded()))")
                .monospacedDigit().foregroundStyle(.secondary)
            Picker("Shape", selection: Binding(get: { cropAspect }, set: { a in
                cropAspect = a
                if let a { model.edits.crop = cropFitting(aspect: a, around: model.edits.crop, source: source) }
            })) {
                Text("Free").tag(Double?.none)
                ForEach(Self.shapes, id: \.label) { Text($0.label).tag(Double?.some($0.aspect)) }
            }
            .labelsHidden().fixedSize()
            Button("Reset") { model.edits.crop = .full; cropAspect = nil }.disabled(c == .full)
            Button("Done") { model.cropping = false }.buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .glassEffect(.regular, in: .capsule)
    }

    /// Crop shapes, to match a target format.
    private static let shapes: [(label: String, aspect: Double)] = [
        ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1 Square", 1), ("4:5 Portrait", 4.0 / 5), ("9:16 Vertical", 9.0 / 16),
    ]
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Called once the layer has a frame to show.
    var onReady: () -> Void = {}
    func makeNSView(context: Context) -> PlayerNSView { let v = PlayerNSView(); update(v); return v }
    func updateNSView(_ v: PlayerNSView, context: Context) { update(v) }
    private func update(_ v: PlayerNSView) { v.playerLayer.player = player; v.onReady = onReady }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        var onReady: () -> Void = {}
        private var ready: NSKeyValueObservation?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            ready = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in self?.onReady() }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// The recording's frame from the library, blurred, with a small spinner: what the stage shows while the player opens.
private struct OpeningPoster: View {
    let rec: Recording
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            // The library tile's frame, so it's usually already cached.
            if let poster { Image(nsImage: poster).resizable().scaledToFill().blur(radius: 16).opacity(0.8) }
            ProgressView().controlSize(.small)
        }
        .clipped()
        .task(id: rec.path) { poster = await Thumbnails.image(rec.path, at: min(0.5, rec.duration / 2), maxSize: 600) }
    }
}

/// Drag across the raw frame to choose what stays visible, keeping `aspect` when one is chosen.
private struct CropOverlay: View {
    @Binding var crop: NRect
    let aspect: Double?
    let source: (w: Double, h: Double)
    @State private var draft: NRect?

    var body: some View {
        GeometryReader { geo in
            let r = draft ?? crop
            let rect = CGRect(x: r.x * geo.size.width, y: r.y * geo.size.height, width: r.w * geo.size.width, height: r.h * geo.size.height)
            ZStack(alignment: .topLeading) {
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(rect) }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                func n(_ p: CGPoint) -> Point { Point(x: min(1, max(0, p.x / geo.size.width)), y: min(1, max(0, p.y / geo.size.height))) }
                draft = cropRect(from: n(v.startLocation), to: n(v.location), aspect: aspect, source: source)
            }.onEnded { _ in
                if let d = draft, d.w >= 0.05, d.h >= 0.05 { crop = d } // ignore stray clicks
                draft = nil
            })
        }
        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
}

/// Work under way, with a spinner; it stays until the work is done.
struct ProgressCapsule: View {
    let text: String
    var cancel: (() -> Void)?
    var body: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(text).lineLimit(1).truncationMode(.middle)
            if let cancel { Button("Cancel", action: cancel).controlSize(.small) }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .glassEffect(in: .capsule)
    }
}

/// Something finished, with its one action and a close button.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: Space.m) {
            Text(toast.text).font(.callout)
            if let action = toast.action { Button(action.label) { action.run(); dismiss() }.controlSize(.small) }
            Button("Close", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.leading, Space.l).padding(.trailing, Space.s).padding(.vertical, Space.s)
        .glassEffect(in: .capsule)
        .transition(.opacity)
    }
}
