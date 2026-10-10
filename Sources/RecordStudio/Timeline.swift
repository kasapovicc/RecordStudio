import RecordCore
import RecordKit
import SwiftUI

extension Color {
    static let zoomClip = Color(red: 0.62, green: 0.55, blue: 1.0)
    static let textClip = Color(red: 0.95, green: 0.71, blue: 0.29)
    static let noteClip = Color(red: 0.98, green: 0.5, blue: 0.62)
    static let audioClip = Color(red: 0.4, green: 0.82, blue: 0.62)
    static let cameraClip = Color(red: 0.45, green: 0.7, blue: 1.0)
    static let micClip = Color(red: 0.55, green: 0.85, blue: 0.95)
    static let systemClip = Color(red: 0.95, green: 0.6, blue: 0.85)
    static let speedClip = Color(red: 0.98, green: 0.85, blue: 0.35)
    static let chapterMark = Color(red: 1.0, green: 0.58, blue: 0.3)
    static let captionClip = Color(light: NSColor(srgbRed: 0.78, green: 0.78, blue: 0.81, alpha: 1), dark: NSColor(srgbRed: 0.9, green: 0.9, blue: 0.93, alpha: 1))
    static let insertedClip = Color(red: 0.36, green: 0.42, blue: 0.62)
    // The recording's own clip: a neutral block, light in light mode so it doesn't sit as a charcoal slab in a light
    // window. Its title and trim handles follow, so both stay readable.
    static let clipTop = Color(light: NSColor(white: 0.84, alpha: 1), dark: NSColor(white: 0.36, alpha: 1))
    static let clipBottom = Color(light: NSColor(white: 0.78, alpha: 1), dark: NSColor(white: 0.3, alpha: 1))
    static let clipHandle = Color(light: NSColor(white: 0.3, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
    static let clipGrip = Color(light: NSColor(white: 1, alpha: 0.6), dark: NSColor(white: 0, alpha: 0.35))
}

struct TimelineDock: View {
    @Bindable var model: EditorModel
    /// How far the row is folded (see `controls`): the roomiest that fits, measured off-screen so the change cross-fades.
    @State private var fold = 0

    var body: some View {
        VStack(spacing: Space.s) {
            // The roomiest layout that fits: first the add buttons fold into one Add menu, then the clip buttons lose
            // their names, so nothing is ever clipped or wrapped. Names stay as tooltips.
            ZStack {
                ViewThatFits(in: .horizontal) {
                    ForEach(0..<3) { i in controls(compact: i, measuring: true).onAppear { fold = i } }
                }
                .hidden()
                .accessibilityHidden(true)
                controls(compact: fold).id(fold).transition(.opacity)
            }
            .motion(Motion.hover, value: fold)
            .controlSize(.regular)

            Tracks(model: model)
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .padding(.bottom, Space.m)
        .background(.bar)
    }

    /// The row above the timeline in three groups: the transport, buttons that change the clip, and buttons that add on
    /// top of it, then the timeline's zoom. `compact` 0 shows everything; 1 folds the add buttons into one Add menu; 2
    /// also shows the clip buttons as icons only. `measuring` is the hidden copy that picks the fold, so it opens nothing.
    private func controls(compact: Int, measuring: Bool = false) -> some View {
        let map = model.edits.timeMap
        let clipStyle = LaneLabel(iconOnly: compact >= 2)
        return HStack(spacing: Space.s) {
            HStack(spacing: Space.m) {
                PlayButton(model: model)
                Text("\(timecode(sourceToOutput(map, model.time))) \(Text("/ \(timecode(outputDuration(map)))").foregroundStyle(.quiet))")
                    .font(.title3.weight(.medium).monospacedDigit())
                    .lineLimit(1).fixedSize()
            }

            Spacer(minLength: Space.m)
            Button { model.split() } label: { Label("Split", systemImage: "scissors") }
                .labelStyle(clipStyle)
                .help("Split the clip at the playhead (S), then select a part and press ⌫ to cut it")
            Menu {
                SpeedPicker(model: model, piece: nil).pickerStyle(.inline)
            } label: {
                Label("Speed", systemImage: "gauge.with.dots.needle.67percent").labelStyle(LaneLabel(iconOnly: compact >= 2, menu: true))
            }
            .fixedSize()
            .modifier(MenuBezel())
            .accessibilityLabel("Speed")
            .help("Play the selected piece of the clip, or the one under the playhead, faster or slower. Split (S) to change the speed of just part of it.")
            if model.rec.hasAudio { PausesButton(model: model, presents: !measuring).labelStyle(clipStyle) }
            Button { model.cropping = true } label: { Label("Crop", systemImage: "crop") }
                .labelStyle(clipStyle)
                .disabled(model.cropping)
                .help("Choose what part of the recording stays visible")
            Button { model.chooseClip() } label: { Label("Insert Clip…", systemImage: "film.stack") }
                .labelStyle(clipStyle)
                .disabled(model.insertingClip)
                .help("Insert a video at the playhead, or at the split it's on: an intro, an outro, a shot from your phone. You can also drop one on the timeline.")

            divider

            if compact == 0 {
                // Icons only, each in the colour of the lane it adds to: the one place the row has colour.
                HStack(spacing: Space.xs) {
                    Button { model.addZoom() } label: { Label("Add Zoom", systemImage: "plus.magnifyingglass") }
                        .labelStyle(LaneLabel(iconOnly: true, tint: .zoomClip))
                        .help("Add a zoom at the playhead (Z)")
                    Button { model.addMarker() } label: { Label("Add Chapter", systemImage: "bookmark") }
                        .labelStyle(LaneLabel(iconOnly: true, tint: .chapterMark))
                        .help("Add a chapter at the playhead (M). Exported videos get a chapter starting at each.")
                    Button { model.addCallout() } label: { Label("Add Text", systemImage: "textformat") }
                        .labelStyle(LaneLabel(iconOnly: true, tint: .textClip))
                        .help("Add a text callout at the playhead")
                    Menu { annotationItems } label: {
                        Label("Add Annotation", systemImage: "scribble").labelStyle(LaneLabel(iconOnly: true, menu: true, tint: .noteClip))
                    }
                    .fixedSize()
                    .modifier(MenuBezel())
                    .accessibilityLabel("Add Annotation")
                    .help("Add an arrow, box, circle or picture at the playhead, a video over the recording, or blur or pixelate part of it")
                }
            } else {
                Menu {
                    Button { model.addZoom() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                    Button { model.addMarker() } label: { Label("Chapter", systemImage: "bookmark") }
                    Button { model.addCallout() } label: { Label("Text", systemImage: "textformat") }
                    Divider()
                    annotationItems
                } label: {
                    Label("Add", systemImage: "plus").labelStyle(LaneLabel(menu: true))
                }
                .fixedSize()
                .modifier(MenuBezel())
                .accessibilityLabel("Add")
                .help("Add a zoom (Z), chapter (M), text or annotation at the playhead")
            }

            if model.maxTimelineZoom > 1 {
                divider
                // log2, so each step of the slider zooms by the same factor.
                HStack(spacing: Space.xs) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log2(model.timelineZoom) }, set: { model.timelineZoom = pow(2, $0) }),
                           in: 0...log2(model.maxTimelineZoom))
                        .frame(width: 88)
                        .controlSize(.mini)
                        .accessibilityLabel("Timeline zoom")
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .help("Zoom the timeline: ⌘+ / ⌘− or pinch, ⌘0 to fit")
            }
        }
        .buttonStyle(ToolButtonStyle())
    }

    private var divider: some View { Divider().frame(height: 18).padding(.horizontal, Space.xs) }

    /// The kinds of annotation, each added at the playhead.
    @ViewBuilder private var annotationItems: some View {
        ForEach([Annotation.Kind.arrow, .rectangle, .ellipse], id: \.self) { k in
            Button { model.addAnnotation(k) } label: { Label(k.name, systemImage: k.symbol) }
        }
        Button { model.chooseImage() } label: { Label("Image…", systemImage: Annotation.Kind.image.symbol) }
        Button { model.chooseOverlay() } label: { Label("Video Overlay…", systemImage: Annotation.Kind.video.symbol) }
            .disabled(model.insertingClip)
        Divider()
        Button { model.addAnnotation(.blur) } label: { Label("Blur", systemImage: Annotation.Kind.blur.symbol) }
        Button { model.addAnnotation(.blur, pixelate: true) } label: { Label("Pixelate", systemImage: "squareshape.split.3x3") }
    }
}

extension AnyTransition {
    /// A zoom, callout or annotation added or deleted with a click: it fades in from a touch smaller where it's placed,
    /// and fades out. From the keyboard there's no animation, so it appears or goes at once (see `Tracks.laneMotion`).
    static let laneItem = AnyTransition.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity)
}

/// A pull-down menu drawn by SwiftUI from its label (see `LaneLabel.menu`). AppKit's own menu bezel is lighter than
/// the buttons beside it, and no button style changes it.
private struct MenuBezel: ViewModifier {
    func body(content: Content) -> some View { content.menuStyle(.button).buttonStyle(.plain) }
}

/// Play or pause. The symbol swaps with a short replace when clicked; Space (a menu command) swaps it at once.
private struct PlayButton: View {
    let model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { withAnimation(Motion.press.respecting(reduceMotion)) { model.togglePlay() } } label: {
            Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .help(model.playing ? "Pause (Space)" : "Play (Space)")
    }
}

/// The tool row's buttons: the same bezel as its pull-down menus (`LaneLabel.menu`), sinking slightly while pressed.
private struct ToolButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Space.m)
            .frame(height: LaneLabel.height)
            .background(LaneLabel.bezel, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.4)
            .pressed(configuration.isPressed)
    }
}

/// Icon and title, the icon a step quieter than the title, or in `tint` for the add buttons (the lane colour they add
/// to). Folded to the icon, the name is still read out by VoiceOver and shown as a tooltip. `menu` adds a chevron and
/// the bezel the row's buttons have (`ToolButtonStyle`).
private struct LaneLabel: LabelStyle {
    var iconOnly = false
    var menu = false
    var tint: Color?
    static let bezel = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))
    static let height = 24.0 // off-scale: a regular control's height

    func makeBody(configuration: Configuration) -> some View {
        let icon = configuration.icon.foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        let label = Label { configuration.title } icon: { icon }
        let styled = Group { if iconOnly { label.labelStyle(.iconOnly) } else { label.labelStyle(.titleAndIcon) } }
        if menu {
            HStack(spacing: Space.xs) {
                styled
                Image(systemName: "chevron.down").imageScale(.small).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.m)
            .frame(height: Self.height)
            .background(Self.bezel, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        } else {
            styled
        }
    }
}

private enum Lane {
    static let ruler: CGFloat = 20, flags: CGFloat = 18, clip: CGFloat = 40, source: CGFloat = 24, zoom: CGFloat = 28, text: CGFloat = 28, note: CGFloat = 28, audio: CGFloat = 28, caption: CGFloat = 24
    static let gap: CGFloat = 5
    /// The column of lane names at the left.
    static let header: CGFloat = 92
}

extension Color {
    /// The lane colour, darkened in light mode, where the pale lane colours wash out on a pale lane.
    var ink: Color {
        let c = NSColor(self)
        return Color(light: c.blended(withFraction: 0.45, of: .black) ?? c, dark: c)
    }
}

/// One look for every item on a lane: a faint fill of the lane's colour with a solid bar at its start, a border under
/// the pointer, and a graphite ring outside it when selected. It clips its own content, so a short one's grips and label
/// don't spill over its neighbours.
private struct LaneItem: ViewModifier {
    let tint: Color
    let selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(tint.opacity(0.3))
            .overlay(alignment: .leading) { Rectangle().fill(tint.ink).frame(width: 2) }
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(tint.ink, lineWidth: 1)
                    .opacity(hovering && !selected ? 0.8 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.outer(Radius.small, inset: 2)).strokeBorder(.graphite, lineWidth: 1.5)
                    .padding(-Space.xxs)
                    .opacity(selected ? 1 : 0)
            }
            .onHover { hovering = $0 }
            .motion(Motion.hover, value: hovering)
    }
}

/// An item's icon and name. The name truncates first; on an item too short for it, only the icon shows.
private struct ItemLabel: View {
    let text: String, symbol: String
    init(_ text: String, symbol: String) { self.text = text; self.symbol = symbol }

    var body: some View {
        let icon = Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.xs) {
                icon
                Text(text).font(.caption.weight(.medium)).lineLimit(1)
            }
            // Measured at 44 points, so a long name truncates rather than dropping to the icon; below that it'd show a
            // letter or two.
            .frame(minWidth: 44, idealWidth: 44, maxWidth: .infinity, alignment: .leading) // off-scale: see above
            icon
        }
    }
}

/// Where recording times sit across the timeline: laid out in played time (see `Edits.timeMap`), so trimmed and cut
/// time takes no room on any lane and sped-up parts are as long as they play. Drags measure against the scale of the edits they began with, so the
/// layout doesn't shift under the pointer while the drag changes it.
struct TimelineScale {
    let map: [Trim], total: Double, width: CGFloat
    init(_ e: Edits, width: CGFloat) {
        map = e.timeMap
        total = max(0.01, outputDuration(map))
        self.width = max(1, width)
    }
    func x(_ t: Double) -> CGFloat { CGFloat(sourceToOutput(map, t) / total) * width }
    /// The recording time at x; at a cut, where the video carries on. Past either end it carries on at the same
    /// scale, so a trim handle dragged out of the timeline brings back trimmed time.
    func t(_ x: CGFloat) -> Double {
        if x < 0, let first = map.first { return first.start + Double(x / width) * total }
        if x > width, let last = map.last { return last.end + Double((x - width) / width) * total }
        return outputToSource(map, Double(x / width) * total)
    }
    func width(_ a: Double, _ b: Double) -> CGFloat { x(b) - x(a) }
    /// Recording time t moved by dx points along the timeline.
    func moved(_ t: Double, by dx: CGFloat) -> Double { self.t(x(t) + dx) }
}

/// Where each lane sits. Under the clip come the recording's own sources (camera, microphone, system audio), only those
/// it has, and the captions made from the microphone, then zooms, text, annotations and the extra audio. Speed isn't a
/// lane: it belongs to pieces of the clip.
private struct LaneLayout {
    let camera, mic, system: Bool
    /// A row under the ruler's times for chapter flags, when there are any.
    let flags: Bool
    var captions: Bool { mic }

    var clipY: CGFloat { Lane.ruler + (flags ? Lane.flags : 0) + Lane.gap }
    var cameraY: CGFloat { clipY + Lane.clip + Lane.gap }
    var micY: CGFloat { cameraY + (camera ? Lane.source + Lane.gap : 0) }
    var systemY: CGFloat { micY + (mic ? Lane.source + Lane.gap : 0) }
    var captionY: CGFloat { systemY + (system ? Lane.source + Lane.gap : 0) }
    var zoomY: CGFloat { captionY + (captions ? Lane.caption + Lane.gap : 0) }
    var textY: CGFloat { zoomY + Lane.zoom + Lane.gap }
    var noteY: CGFloat { textY + Lane.text + Lane.gap }
    var audioY: CGFloat { noteY + Lane.note + Lane.gap }
    var height: CGFloat { audioY + Lane.audio }
}

private struct Tracks: View {
    @Bindable var model: EditorModel
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0 // how far the zoomed-in timeline is scrolled
    @State private var pinchFrom: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Zooms, callouts and annotations added or deleted with a click fade in and out (see `AnyTransition.laneItem`);
    /// from the keyboard (Z, ⌫, ⌘Z…) they appear and go at once, as in the inspector.
    private var laneMotion: Animation? { CACurrentMediaTime() - model.keyPressedAt < 0.3 ? nil : Motion.enter.respecting(reduceMotion) }

    /// ponytail: the lanes (and the waveforms' Canvas) are drawn at full width, so the zoomed timeline is capped at this
    /// many points; drawing only the part in view would let it zoom further.
    static let widest: CGFloat = 20_000

    var body: some View {
        let L = LaneLayout(camera: model.rec.hasCamera && model.edits.camera != nil, mic: model.rec.hasAudio, system: model.rec.hasSystemAudio,
                            flags: !model.edits.allMarkers.isEmpty)
        let micOn = (model.edits.micVolume ?? 1) > 0, systemOn = (model.edits.systemVolume ?? 1) > 0
        let keys = ShortcutStore.shared.map
        let cameraOn = model.edits.camera?.visible == true
        HStack(alignment: .top, spacing: Space.s) {
            VStack(spacing: 0) {
                Color.clear.frame(height: L.clipY)
                header("Clip", Lane.clip) { label("film") }
                Color.clear.frame(height: Lane.gap)
                if L.camera {
                    header("Camera", Lane.source) {
                        toggle(cameraOn ? "video" : "video.slash", cameraOn ? "Camera: click to hide it" : "Camera hidden: click to show it") {
                            model.edits.camera?.visible.toggle()
                        }
                    }
                    Color.clear.frame(height: Lane.gap)
                }
                if L.mic {
                    header("Microphone", Lane.source) {
                        toggle(micOn ? "mic" : "mic.slash", micOn ? "Microphone: click to mute it" : "Microphone muted: click to turn it back on") {
                            model.edits.micVolume = micOn ? 0 : nil
                        }
                    }
                    Color.clear.frame(height: Lane.gap)
                }
                if L.system {
                    header("System", Lane.source) {
                        toggle(systemOn ? "speaker.wave.2" : "speaker.slash", systemOn ? "System audio: click to mute it" : "System audio muted: click to turn it back on") {
                            model.edits.systemVolume = systemOn ? 0 : nil
                        }
                    }
                    Color.clear.frame(height: Lane.gap)
                }
                if L.captions {
                    let on = model.showCaptions
                    header("Captions", Lane.caption) {
                        toggle("captions.bubble", slashed: !on, model.edits.captions == nil ? "Captions: click to make them from what’s said"
                               : on ? "Captions: click to hide them" : "Captions hidden: click to show them") {
                            model.showCaptions.toggle()
                        }
                        .disabled(model.transcribing)
                    }
                    Color.clear.frame(height: Lane.gap)
                }
                header("Zooms", Lane.zoom) { label("plus.magnifyingglass") }
                Color.clear.frame(height: Lane.gap)
                header("Text", Lane.text) { label("textformat") }
                Color.clear.frame(height: Lane.gap)
                header("Annotations", Lane.note) { label("scribble") }
                Color.clear.frame(height: Lane.gap)
                header("Audio", Lane.audio) { label("music.note") }
            }
            .frame(width: Lane.header)

            GeometryReader { geo in
                let view = geo.size.width
                let w = view * min(model.timelineZoom, model.maxTimelineZoom)
                let d = model.duration
                let scale = TimelineScale(model.edits, width: w)
                let x = scale.x
                let segments = model.edits.keptSegments
                let tip = tipPlace(L, scale)
                ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Ruler(scale: scale)
                    // Lanes and clips. Each item draws only its own shape, so one that crosses a split it wasn't split at
                    // shows as one piece.
                    ZStack(alignment: .topLeading) {
                        lane(y: L.clipY, h: Lane.clip)
                        if L.captions { lane(y: L.captionY, h: Lane.caption) }
                        lane(y: L.zoomY, h: Lane.zoom)
                        lane(y: L.textY, h: Lane.text)
                        lane(y: L.noteY, h: Lane.note)
                        lane(y: L.audioY, h: Lane.audio)
                        // Empty lanes say how to fill them, at the left of what's in view.
                        if model.edits.zooms.isEmpty {
                            hint("\(keys[.addZoom]?.symbol ?? "Add Zoom") adds a zoom at the playhead", y: L.zoomY, h: Lane.zoom)
                        }
                        if model.edits.callouts.isEmpty {
                            hint("\(keys[.addText]?.symbol ?? "Add Text") adds text at the playhead", y: L.textY, h: Lane.text)
                        }

                        TrimmedClip(model: model, width: w)
                            .frame(width: max(24, scale.width(model.edits.trim.start, model.edits.trim.end)), height: Lane.clip)
                            .offset(x: x(model.edits.trim.start), y: L.clipY)

                        // The recording's own sources, where each has footage or sound, with a gap wherever an inserted clip
                        // plays. Clicks pass through to seek; the buttons beside the lanes turn each one off, and the Audio and
                        // Webcam tabs have the rest.
                        let r = model.rec.duration
                        if L.camera {
                            let start = max(0, model.rec.cameraOffset), end = min(r, model.rec.cameraOffset + (model.cameraDuration ?? r))
                            ForEach(Array(blocks(pieces(start, end), in: segments).enumerated()), id: \.offset) { _, b in let p = b.piece
                                SourceClip(name: "Camera", color: .cameraClip, on: cameraOn, levels: nil, volume: 1) { _ in nil }
                                    .frame(width: max(8, scale.width(p.start, p.end) - (b.gap ? 2 : 0)), height: Lane.source)
                                    .offset(x: x(p.start), y: L.cameraY)
                            }
                        }
                        if L.mic {
                            ForEach(Array(blocks(pieces(0, r), in: segments).enumerated()), id: \.offset) { _, b in let p = b.piece
                                SourceClip(name: "Microphone", color: .micClip, on: micOn, levels: model.micLevels,
                                           volume: model.edits.micVolume ?? 1) { model.edits.recordingTime(scale.t(x(p.start) + $0)) }
                                    .frame(width: max(8, scale.width(p.start, p.end) - (b.gap ? 2 : 0)), height: Lane.source)
                                    .offset(x: x(p.start), y: L.micY)
                            }
                        }
                        if L.system {
                            let offset = model.rec.systemAudioOffset
                            let start = max(0, offset)
                            let end = model.systemLevels.isEmpty ? r : min(r, offset + Double(model.systemLevels.count) * VoiceActivity.window)
                            ForEach(Array(blocks(pieces(start, end), in: segments).enumerated()), id: \.offset) { _, b in let p = b.piece
                                SourceClip(name: "System audio", color: .systemClip, on: systemOn, levels: model.systemLevels,
                                           volume: model.edits.systemVolume ?? 1) { model.edits.recordingTime(scale.t(x(p.start) + $0)).map { $0 - offset } }
                                    .frame(width: max(8, scale.width(p.start, p.end) - (b.gap ? 2 : 0)), height: Lane.source)
                                    .offset(x: x(p.start), y: L.systemY)
                            }
                        }

                        if L.captions {
                            CaptionLane(model: model, scale: scale, width: w, showsTip: tip?.tip == .captions).offset(y: L.captionY)
                        }

                        ForEach(visible(model.edits.zooms, scale), id: \.element.id.uuid) { i, z in
                            ZoomClip(model: model, index: i, zoom: z, width: w)
                                .frame(width: itemWidth(model.edits.zooms, i, scale), height: Lane.zoom)
                                .offset(x: x(z.start), y: L.zoomY)
                                .transition(.laneItem)
                        }
                        .animation(laneMotion, value: model.edits.zooms.map(\.id.uuid))
                        ForEach(visible(model.edits.callouts, scale), id: \.element.id.uuid) { i, k in
                            let selected = model.selectedCallout == i
                            ItemLabel(k.text, symbol: "textformat")
                                .padding(.horizontal, Space.s)
                                .frame(width: itemWidth(model.edits.callouts, i, scale), height: Lane.text, alignment: .leading)
                                .modifier(LaneItem(tint: .textClip, selected: selected))
                                .modifier(TimelineDrag(model: model, width: w, edges: [k.start, k.end], lifts: true, tap: { _ in model.selectedCallout = i; model.seek(k.start) }) { o, move in
                                    guard o.callouts.indices.contains(i) else { return }
                                    let k0 = o.callouts[i], len = k0.end - k0.start
                                    let s = round2(min(max(0, move(k0.start)), d - len))
                                    model.edits.callouts[i].start = s
                                    model.edits.callouts[i].end = round2(s + len)
                                })
                                .overlay {
                                    HStack(spacing: 0) {
                                        TrimGrip(model: model, width: w, height: Lane.text, edge: k.start, shown: selected) { o, move in
                                            guard o.callouts.indices.contains(i) else { return }
                                            model.edits.callouts[i].start = round2(min(max(0, move(o.callouts[i].start)), o.callouts[i].end - 0.5))
                                        }
                                        Spacer(minLength: 0)
                                        TrimGrip(model: model, width: w, height: Lane.text, edge: k.end, shown: selected) { o, move in
                                            guard o.callouts.indices.contains(i) else { return }
                                            model.edits.callouts[i].end = round2(min(max(o.callouts[i].start + 0.5, move(o.callouts[i].end)), d))
                                        }
                                    }
                                }
                                .offset(x: x(k.start), y: L.textY)
                                .help("Drag to move, drag the edges to resize")
                                .transition(.laneItem)
                        }
                        .animation(laneMotion, value: model.edits.callouts.map(\.id.uuid))

                        ForEach(visible(model.edits.allAnnotations, scale), id: \.element.id.uuid) { i, a in
                            AnnotationClip(model: model, index: i, annotation: a, width: w)
                                .frame(width: itemWidth(model.edits.allAnnotations, i, scale), height: Lane.note)
                                .offset(x: x(a.start), y: L.noteY)
                                .transition(.laneItem)
                        }
                        .animation(laneMotion, value: model.edits.allAnnotations.map(\.id.uuid))

                        if let m = model.edits.audio {
                            AudioClip(model: model, track: m, width: w)
                                .frame(width: max(24, scale.width(m.at, m.end)), height: Lane.audio)
                                .offset(x: x(m.at), y: L.audioY)
                        }

                        // Silenced sound, dimmed. Once split, a click on the microphone or system audio selects the piece
                        // under it (the music's own clip handles its clicks): ⌫ silences it, ⌫ again brings it back.
                        ForEach(soundLanes(L), id: \.source) { lane in
                            ForEach(Array(blocks(model.edits.silencedRanges(lane.source), in: segments).enumerated()), id: \.offset) { _, b in
                                let r = b.piece
                                RoundedRectangle(cornerRadius: Radius.small).fill(.black.opacity(0.55))
                                    .overlay(Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(.white.opacity(0.7)))
                                    .frame(width: max(2, scale.width(r.start, r.end) - (b.gap ? 2 : 0)), height: lane.h)
                                    .offset(x: x(r.start), y: lane.y)
                                    .allowsHitTesting(false)
                            }
                            if segments.count > 1, lane.source != .music {
                                ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                                    Color.clear.frame(width: scale.width(seg.start, seg.end), height: Lane.source)
                                        .contentShape(.rect)
                                        .onTapGesture { p in
                                            let t = scale.t(x(seg.start) + p.x)
                                            model.selectPart(.sound(lane.source), at: t)
                                            model.seek(t)
                                        }
                                        .help("Click to select, ⌫ to silence this part of the \(lane.name) (⌫ again brings it back)")
                                        .offset(x: x(seg.start), y: lane.y)
                                }
                            }
                        }
                    }

                    // What the pauses panel would take out, through the clip and down to the microphone's waveform.
                    if let o = model.pausePanel {
                        PausePreview(pauses: model.pauses(o), speedUp: o.speedUp, x: x,
                                     height: (L.mic ? L.micY + Lane.source : L.clipY + Lane.clip) - L.clipY)
                            .offset(y: L.clipY)
                            .transition(.opacity)
                    }

                    if let p = model.selectedPart, let f = partFrame(p, L) {
                        RoundedRectangle(cornerRadius: Radius.small).fill(.white.opacity(0.08)).strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                            .frame(width: max(4, scale.width(f.start, f.end)), height: f.h)
                            .offset(x: x(f.start), y: f.y)
                            .allowsHitTesting(false)
                    }

                    // Chapter markers under the ruler's times, each with a faint line down through the lanes. Hidden
                    // while in a cut.
                    let markers = model.edits.allMarkers.enumerated().filter { m in segments.contains { m.element.t >= $0.start && m.element.t < $0.end } }
                    let flags = flagLayout(markers.map { Double(x($0.element.t)) }, width: Double(w), icon: Double(MarkerFlag.icon))
                    ForEach(Array(zip(markers, flags)), id: \.0.offset) { m, f in
                        MarkerFlag(model: model, index: m.offset, marker: m.element, width: w, shift: CGFloat(f.x) - x(m.element.t),
                                   room: CGFloat(f.room), height: L.height - Lane.ruler)
                            .offset(x: x(m.element.t), y: Lane.ruler)
                    }

                    if let g = model.snapGuide {
                        Rectangle().fill(.graphite).frame(width: 1, height: L.height - Lane.ruler)
                            .offset(x: x(g), y: Lane.ruler)
                            .allowsHitTesting(false)
                    }

                    Playhead(height: L.height).offset(x: x(model.time) - 5, y: 10)
                        .allowsHitTesting(false)

                    // The one tip on screen, beside what it's about, on whichever side has room. Fades in and out.
                    ZStack(alignment: .topLeading) {
                        if let tip, tip.tip != .captions {
                            let leading = tip.x < w / 2
                            TipBubble(tip: tip.tip)
                                .frame(maxWidth: max(160, leading ? w - tip.x : tip.x) - Space.s, alignment: .leading)
                                .padding(leading ? .leading : .trailing, leading ? tip.x : w - tip.x)
                                .frame(width: w, alignment: leading ? .leading : .trailing)
                                .offset(y: tip.y)
                                .transition(.opacity)
                        }
                    }
                    .motion(Motion.hover, value: tip?.tip)
                }
                .frame(width: w, height: L.height, alignment: .topLeading)
                .motion(Motion.enter, value: model.pausePanel == nil)
                .contentShape(.rect)
                .coordinateSpace(name: "timeline") // lane items report clicks in it, as timeline time
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in model.selectedPart = nil; model.seek(scale.t(v.location.x)) })
                // A video dropped on the timeline is inserted there, at the nearest split or clip edge when one is close.
                .dropDestination(for: URL.self) { urls, p in
                    guard let url = urls.first(where: { Importer.extensions.contains($0.pathExtension.lowercased()) }) else { return false }
                    model.insertClip(from: url, at: scale.t(p.x), snap: Double(12 / w) * scale.total)
                    return true
                }
                }
                .scrollPosition($scroll)
                .scrollIndicators(w > view ? .visible : .never)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { offset = $1 }
                // At most 2 seconds across the window, and no wider than the lanes can be drawn.
                .onChange(of: [Double(view), scale.total], initial: true) { model.maxTimelineZoom = max(1, min(scale.total / 2, Double(Self.widest / max(1, view)))) }
                // Zooming keeps the playhead where it is on screen; one off screen comes to the middle.
                .onChange(of: model.timelineZoom) { old, new in
                    let px = Double(x(model.time)), was = px * old / new - offset
                    scroll.scrollTo(x: clamp(px - (was >= 0 && was <= view ? was : view / 2), 0, max(0, w - view)))
                }
                // Playing, stepping or jumping out of view scrolls the playhead back in.
                .onChange(of: model.time) {
                    let px = x(model.time)
                    if w > view, px < offset || px > offset + view { scroll.scrollTo(x: clamp(px - view * 0.1, 0, max(0, w - view))) }
                }
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if pinchFrom == nil { pinchFrom = model.timelineZoom }
                        model.timelineZoom = clamp((pinchFrom ?? 1) * v.magnification, 1, model.maxTimelineZoom)
                    }
                    .onEnded { _ in pinchFrom = nil })
            }
            .frame(height: L.height + 4)
        }
    }

    /// Recording time a…b on the timeline: a piece per stretch between inserted clips.
    private func pieces(_ a: Double, _ b: Double) -> [Trim] {
        model.edits.recordingRuns(duration: b).compactMap { run in
            let s = max(a, run.start), e = min(b, run.end)
            return e > s ? Trim(start: s + run.shift, end: e + run.shift) : nil
        }
    }

    /// Items with their indices, leaving out any that are wholly inside a cut and so take no room.
    private func visible<T: Timed>(_ items: [T], _ scale: TimelineScale) -> [(offset: Int, element: T)] {
        items.enumerated().filter { scale.width($0.element.start, $0.element.end) > 0.5 }.map { ($0.offset, $0.element) }
    }

    /// An item's width on its lane: 2 pt short of an item that starts where it ends, like the clip's pieces.
    private func itemWidth<T: Timed>(_ items: [T], _ i: Int, _ scale: TimelineScale) -> CGFloat {
        max(16, scale.width(items[i].start, items[i].end) - (touchesNext(items, i) ? 2 : 0))
    }

    /// The sound lanes this recording has: microphone, system audio, and the extra music when there is one.
    private func soundLanes(_ L: LaneLayout) -> [(source: SoundSource, y: CGFloat, h: CGFloat, name: String)] {
        (L.mic ? [(SoundSource.mic, L.micY, Lane.source, "microphone")] : [])
            + (L.system ? [(SoundSource.system, L.systemY, Lane.source, "system audio")] : [])
            + (model.edits.audio != nil ? [(SoundSource.music, L.audioY, Lane.audio, "music")] : [])
    }

    /// Where the selected piece is drawn: its segment across every lane for the clip, otherwise its segment within that
    /// lane's item. Nil when the item has nothing in that segment.
    private func partFrame(_ p: TimelinePart, _ L: LaneLayout) -> (start: Double, end: Double, y: CGFloat, h: CGFloat)? {
        let segments = model.edits.keptSegments
        guard segments.indices.contains(p.segment) else { return nil }
        let seg = segments[p.segment]
        func within(_ a: Double, _ b: Double, _ y: CGFloat, _ h: CGFloat) -> (Double, Double, CGFloat, CGFloat)? {
            let s = max(a, seg.start), e = min(b, seg.end)
            return e > s ? (s, e, y, h) : nil
        }
        switch p.lane {
        case .clip: return (seg.start, seg.end, L.clipY, L.height - L.clipY)
        case .sound(let src):
            guard let lane = soundLanes(L).first(where: { $0.source == src }) else { return nil }
            let m = model.edits.audio
            return src == .music ? m.flatMap { within($0.at, $0.end, lane.y, lane.h) } : within(seg.start, seg.end, lane.y, lane.h)
        }
    }

    /// A lane's header: its icon (or on/off button) and its name, so lanes read without their colour.
    private func header<Icon: View>(_ name: String, _ h: CGFloat, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: Space.xxs) {
            icon()
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: h, alignment: .leading)
        .frame(height: h)
    }

    private func label(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.callout).foregroundStyle(.quiet).frame(width: 22)
    }

    /// A lane's on/off button: shown as a button when the pointer is over it, so it doesn't look like the plain lane
    /// labels. Off is a slash through the icon, drawn for symbols that have no slashed version.
    private func toggle(_ symbol: String, slashed: Bool = false, _ help: String, _ action: @escaping () -> Void) -> some View {
        LaneToggle(symbol: symbol, slashed: slashed, action: action).help(help)
    }

    /// The tip to show and where: the first unseen one of those that apply now, never while playing or cropping.
    /// Zooms: under the first zoom, once there is one. Split: at the playhead, stopped inside a clip not yet split.
    /// Captions: beside Make Captions (drawn by `CaptionLane`).
    private func tipPlace(_ L: LaneLayout, _ scale: TimelineScale) -> (tip: Tip, x: CGFloat, y: CGFloat)? {
        let e = model.edits, w = scale.width
        func beside(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b < w / 2 ? b + Space.s : a - Space.s }
        var places: [Tip: (x: CGFloat, y: CGFloat)] = [:]
        // Under the zooms rather than on their lane, so the zooms it's about stay in view and clickable.
        if let z = e.zooms.first { places[.zoom] = (scale.x(z.start) < w / 2 ? scale.x(z.start) : scale.x(z.end), L.textY) }
        if e.keptSegments.count == 1, model.time > e.trim.start + 0.5, model.time < e.trim.end - 0.5 {
            places[.split] = (beside(scale.x(model.time), scale.x(model.time)), L.clipY + Space.s)
        }
        if L.captions, e.captions == nil, !model.transcribing { places[.captions] = (0, L.captionY) }
        let busy = model.playing || model.cropping || !model.previewReady || Studio.shared.isRecording
        guard let tip = TipStore.shared.state.tip(relevant: Tip.allCases.filter { places[$0] != nil }, busy: busy), let p = places[tip] else { return nil }
        return (tip, p.x, p.y)
    }

    /// An empty lane's line saying how to add to it, kept at the left of the part in view.
    private func hint(_ text: String, y: CGFloat, h: CGFloat) -> some View {
        Text(text).font(.caption).foregroundStyle(.quiet).lineLimit(1)
            .padding(.leading, Space.s)
            .frame(height: h)
            .offset(x: offset, y: y)
            .allowsHitTesting(false)
    }

    private func lane(y: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.small).fill(.faint(0.04)).frame(height: h).offset(y: y)
    }
}

private struct LaneToggle: View {
    let symbol: String
    let slashed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout)
                .overlay { if slashed { Capsule().frame(width: 1.5, height: 17).rotationEffect(.degrees(-45)) } }
                .frame(width: 22, height: 22)
                .background(.primary.opacity(hovering ? 0.12 : 0), in: .rect(cornerRadius: Radius.small))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
    }
}

/// The mark at an item's end that trims it: drag it to move that end.
private struct TrimGrip: View {
    let model: EditorModel
    let width: CGFloat
    let height: CGFloat
    var edge: Double // the time it trims, which snaps
    var shown = true // its mark, drawn on a selected item; it can be dragged either way
    let apply: (Edits, (Double) -> Double) -> Void

    var body: some View {
        Capsule().fill(.primary.opacity(shown ? 0.45 : 0)).frame(width: 2, height: min(12, height - 10))
            .frame(width: 9, height: height)
            .contentShape(.rect)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .modifier(TimelineDrag(model: model, width: width, edges: [edge], apply: apply))
    }
}

/// A horizontal drag, applied to the edits as they were when it began, with a function that moves a recording time by
/// the drag along the timeline as it was then. A press without movement is a tap. The dragged `edges` snap to the
/// playhead and the timeline's edit points (see `Edits.editPoints`) within a few points; ⌘ turns that off.
private struct TimelineDrag: ViewModifier {
    let model: EditorModel
    let width: CGFloat
    var edges: [Double] = []
    /// Picked up while dragged (a little larger, with a shadow), and set down with `Motion.settle` when let go.
    var lifts = false
    var tap: ((Double) -> Void)? // gets the recording time clicked
    let apply: (Edits, (Double) -> Double) -> Void
    @State private var moved = false
    @State private var own: [Double] = [] // `edges` when the drag began
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let up = lifts && moved
        return content
            .animation((up ? Motion.press : Motion.settle).respecting(reduceMotion)) {
                $0.scaleEffect(up && !reduceMotion ? 1.02 : 1)
                    .shadow(color: .black.opacity(up ? 0.3 : 0), radius: 4, y: 2)
                    .opacity(up ? 0.9 : 1)
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if model.dragOrigin == nil { model.dragOrigin = model.edits; own = edges }
                if abs(v.translation.width) > 3 { moved = true }
                if moved, let o = model.dragOrigin {
                    let scale = TimelineScale(o, width: width)
                    var dx = Double(v.translation.width)
                    model.snapGuide = nil
                    if !NSEvent.modifierFlags.contains(.command) {
                        let targets = (o.editPoints + [model.time]).filter { t in !own.contains { abs($0 - t) < 0.005 } }
                        if let s = snapOffset(own.map { Double(scale.x($0)) + dx }, to: targets.map { Double(scale.x($0)) }, within: 6) {
                            dx += s.offset
                            model.snapGuide = scale.t(CGFloat(s.target))
                        }
                    }
                    apply(o) { scale.moved($0, by: CGFloat(dx)) }
                }
            }
            .onEnded { v in
                if !moved { tap?(TimelineScale(model.edits, width: width).t(v.location.x)) }
                moved = false
                model.dragOrigin = nil
                model.snapGuide = nil
            })
    }
}

private struct TrimmedClip: View {
    @Bindable var model: EditorModel
    let width: CGFloat

    var body: some View {
        let trim = model.edits.trim, segments = model.edits.keptSegments
        let scale = TimelineScale(model.edits, width: width), x = scale.x
        ZStack(alignment: .topLeading) {
            // Each kept segment is a block; what's cut from the middle shows as a gap. With more than one, a click selects
            // a segment (⌫ cuts it); otherwise clicks fall through to seek.
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                let speed = model.edits.speed(ofSegment: i), pieceWidth = max(4, scale.width(s.start, s.end) - (i < segments.count - 1 ? 2 : 0))
                let clip = model.edits.clipIndex(at: (s.start + s.end) / 2)
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(clip == nil ? LinearGradient(colors: [Color.clipTop, Color.clipBottom], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color.insertedClip, Color.insertedClip.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        if let clip, model.edits.allClips.indices.contains(clip) {
                            InsertedClipLabel(clip: model.edits.allClips[clip], from: s.start - model.edits.allClips[clip].at, width: pieceWidth)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(clip == nil ? AnyShapeStyle(.faint(0.12)) : AnyShapeStyle(.white.opacity(0.3))))
                    .overlay(alignment: .bottomLeading) {
                        // A sped-up or slowed piece carries its speed, where there's room for it.
                        if speed != 1, pieceWidth > 34 {
                            Text(speedLabel(speed))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, Space.xs).frame(height: 15)
                                .background(Color.speedClip, in: .capsule)
                                .foregroundStyle(.black.opacity(0.8))
                                .padding(.leading, Space.m).padding(.bottom, Space.xs) // clear of the trim handle, under the title
                        }
                    }
                    .frame(width: pieceWidth)
                    .clipShape(.rect(cornerRadius: Radius.small))
                    .contentShape(.rect)
                    .contextMenu {
                        SpeedPicker(model: model, piece: i).pickerStyle(.inline)
                        if let clip { InsertedClipMenu(model: model, clip: clip, piece: s) }
                        if segments.count > 1 {
                            Divider()
                            Button("Cut This Part") { model.removePart(TimelinePart(lane: .clip, segment: i)) }
                        }
                    }
                    .gesture(moveGesture(clip ?? -1, scale: scale), including: clip == nil ? .subviews : .all)
                    .onTapGesture { p in let t = scale.t(x(s.start) + p.x); model.selectPart(.clip, at: t); model.seek(t) }
                    .help(clip != nil ? "Drag to another split to move this clip, click to select, right-click for its sound and more"
                          : segments.count > 1 ? "Click to select, ⌫ to cut this part, right-click to change its speed"
                          : "Right-click to change the speed; split (S) to change just part of it")
                    .offset(x: x(s.start) - x(trim.start))
            }
            // Where a dragged clip would go.
            if let drop = model.clipDrop {
                Capsule().fill(.white).frame(width: 3, height: Lane.clip + 6)
                    .shadow(radius: 2)
                    .offset(x: x(drop.at) - x(trim.start) - 1.5, y: -3)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                handle(.start)
                Text(model.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                    .padding(.horizontal, Space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                handle(.end)
            }
        }
    }

    enum Side { case start, end }

    /// Dragging an inserted clip shows where it would go (the split or clip edge nearest the pointer) and moves it there
    /// when let go. A press without a drag falls through to the tap that selects.
    private func moveGesture(_ clip: Int, scale: TimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("timeline"))
            .onChanged { v in
                guard clip >= 0 else { return }
                model.clipDrop = (clip, model.edits.insertionPoint(near: scale.t(v.location.x), snap: .infinity))
            }
            .onEnded { _ in
                if let d = model.clipDrop { model.moveClip(d.clip, to: d.at) }
                model.clipDrop = nil
            }
    }

    private func handle(_ side: Side) -> some View {
        UnevenRoundedRectangle(cornerRadii: side == .start ? .init(topLeading: Radius.small, bottomLeading: Radius.small) : .init(bottomTrailing: Radius.small, topTrailing: Radius.small))
            .fill(Color.clipHandle)
            .overlay(Capsule().fill(Color.clipGrip).frame(width: 2, height: 14))
            .frame(width: 10)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .help(side == .start ? "Drag to trim the start (I)" : "Drag to trim the end (O)")
            .modifier(TimelineDrag(model: model, width: width, edges: [side == .start ? model.edits.trim.start : model.edits.trim.end]) { o, move in
                let d = model.duration
                let v: Double
                if side == .start { v = round2(min(max(0, move(o.trim.start)), o.trim.end - 0.5)); model.edits.trim.start = v }
                else { v = round2(min(max(o.trim.start + 0.5, move(o.trim.end)), d)); model.edits.trim.end = v }
                model.seek(v) // show the frame being cut at
            })
    }
}

private struct ZoomClip: View {
    @Bindable var model: EditorModel
    let index: Int
    let zoom: Zoom
    let width: CGFloat

    var body: some View {
        let selected = model.selectedZoom == index
        HStack(spacing: Space.xs) {
            grip(.start, shown: selected)
            ItemLabel(String(format: "%.1f×", zoom.scale), symbol: zoom.focus != nil ? "scope" : "plus.magnifyingglass")
            Spacer(minLength: 0)
            grip(.end, shown: selected)
        }
        .modifier(LaneItem(tint: .zoomClip, selected: selected))
        .modifier(TimelineDrag(model: model, width: width, edges: [zoom.start, zoom.end], lifts: true, tap: { _ in model.selectZoom(index) }) { o, move in
            guard o.zooms.indices.contains(index) else { return }
            model.selectedZoom = index
            model.tab = .cursorZoom
            let z0 = o.zooms[index], len = z0.end - z0.start
            let s = round2(min(max(0, move(z0.start)), model.duration - len))
            model.edits.zooms[index].start = s
            model.edits.zooms[index].end = round2(s + len)
        })
        .help("Drag to move, drag the edges to resize")
    }

    private func grip(_ side: TrimmedClip.Side, shown: Bool) -> some View {
        Capsule().fill(.primary.opacity(shown ? 0.45 : 0)).frame(width: 2, height: 12)
            .frame(width: 9, height: Lane.zoom)
            .contentShape(.rect)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .modifier(TimelineDrag(model: model, width: width, edges: [side == .start ? zoom.start : zoom.end]) { o, move in
                guard o.zooms.indices.contains(index) else { return }
                model.selectedZoom = index
                let z0 = o.zooms[index]
                if side == .start { model.edits.zooms[index].start = round2(min(max(0, move(z0.start)), z0.end - 0.5)) }
                else { model.edits.zooms[index].end = round2(min(max(z0.start + 0.5, move(z0.end)), model.duration)) }
            })
    }
}

/// A chapter marker: a flag under the ruler with its name (as much as fits before the next one) and a line through the
/// lanes. Click to select it and jump there, click again to rename it, drag to move it; right-click for the rest.
private struct MarkerFlag: View {
    /// The width of a flag showing only its icon.
    static let icon: CGFloat = 18

    @Bindable var model: EditorModel
    let index: Int
    let marker: Marker
    let width: CGFloat
    let shift: CGFloat  // how far the flag sits right of its line, to clear the flag before it
    let room: CGFloat   // points to the next flag or the end
    let height: CGFloat

    var body: some View {
        let selected = model.selectedMarker == index
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.chapterMark.opacity(selected ? 0.9 : 0.45)).frame(width: 1, height: height)
                .allowsHitTesting(false)
            HStack(spacing: Space.xxs) {
                Image(systemName: "bookmark.fill").font(.caption2.weight(.bold))
                if room > 40 { Text(marker.name).font(.caption.weight(.semibold)).lineLimit(1) }
            }
            .padding(.horizontal, Space.xs)
            .frame(height: 16)
            .background(Color.chapterMark, in: UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: Radius.small, topTrailing: Radius.small)))
            .overlay(UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: Radius.small, topTrailing: Radius.small)).strokeBorder(.white, lineWidth: selected ? 1.5 : 0))
            .foregroundStyle(.black.opacity(0.8))
            .contentShape(.rect)
            .modifier(TimelineDrag(model: model, width: width, edges: [marker.t], tap: { _ in
                if selected { model.renamingMarker = index } else { model.selectedMarker = index }
                model.seek(marker.t)
            }) { o, move in
                guard o.allMarkers.indices.contains(index) else { return }
                var list = o.allMarkers
                list[index].t = round2(clamp(move(list[index].t), o.trim.start, o.trim.end - 0.05))
                model.edits.allMarkers = list
                model.selectedMarker = model.edits.allMarkers.firstIndex(of: list[index])
            })
            .contextMenu {
                Button("Rename…") { model.selectedMarker = index; model.renamingMarker = index }
                Button("Delete Chapter", role: .destructive) { model.removeMarker(index) }
            }
            .popover(isPresented: Binding(get: { model.renamingMarker == index }, set: { if !$0, model.renamingMarker == index { model.renamingMarker = nil } }),
                     arrowEdge: .bottom) {
                MarkerName(model: model, index: index, name: marker.name)
            }
            .help("\(marker.name): click again to rename, drag to move, ⌫ to delete")
            .frame(maxWidth: max(Self.icon - 2, min(180, room - 2)), alignment: .leading) // the name truncates before the next flag
            .offset(x: shift)
        }
    }
}

/// The name field in a marker's popover. Return or clicking away keeps the name; Esc puts the old one back.
private struct MarkerName: View {
    let model: EditorModel
    let index: Int
    @State var name: String
    @State private var cancelled = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Chapter name").font(.headline)
            TextField("Chapter name", text: $name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($focused)
                .onSubmit { model.renamingMarker = nil }
                .onExitCommand { cancelled = true; model.renamingMarker = nil }
            Text("Shown in players and listed in the summary.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.m)
        .frame(width: 240)
        .onAppear { focused = true }
        .onDisappear {
            let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Marker.maxName))
            guard !cancelled, !n.isEmpty, model.edits.allMarkers.indices.contains(index), model.edits.allMarkers[index].name != n else { return }
            model.edits.allMarkers[index].name = n
        }
    }
}

/// The speed presets for a piece of the clip, the current one checked. `piece` nil means the selected piece, or the one
/// under the playhead.
struct SpeedPicker: View {
    let model: EditorModel
    let piece: Int?

    var body: some View {
        let current = model.speedPiece(piece).map { model.edits.speed(ofSegment: $0) } ?? 1
        Picker("Speed", selection: Binding(get: { current }, set: { model.setSpeed($0, piece: piece) })) {
            ForEach([0.5, 1] + SpeedRegion.speeds.filter { $0 > 1 }, id: \.self) { v in
                Text(v == 1 ? "Normal (1×)" : speedLabel(v)).tag(v)
            }
        }
    }
}

extension Edits {
    /// True when the whole of `piece` of `source` is silenced.
    func isSilenced(_ source: SoundSource, _ piece: Trim) -> Bool {
        silencedRanges(source).contains { $0.start <= piece.start + 1e-6 && $0.end >= piece.end - 1e-6 }
    }
}

func speedLabel(_ v: Double) -> String { v == 0.5 ? "0.5×" : String(format: v == v.rounded() ? "%.0f×" : "%.1f×", v) }

/// The extra audio file: drag it to move it in time, drag its ends to trim which part of the file plays.
private struct AudioClip: View {
    @Bindable var model: EditorModel
    let track: AudioTrack
    let width: CGFloat

    var body: some View {
        HStack(spacing: Space.xs) {
            grip(.start, shown: model.selectedMusic)
            ItemLabel(URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent, symbol: "music.note")
            if track.duck { Image(systemName: "person.wave.2").font(.caption2).help("Lowered while you speak") }
            Spacer(minLength: 0)
            grip(.end, shown: model.selectedMusic)
        }
        .modifier(LaneItem(tint: .audioClip, selected: model.selectedMusic))
        .modifier(TimelineDrag(model: model, width: width, edges: [track.at, track.end], lifts: true, tap: { t in model.tab = .sound; model.selectMusic(at: t) }) { o, move in
            guard let m0 = o.audio else { return }
            model.edits.audio?.at = round2(min(max(0, move(m0.at)), max(0, model.duration - 0.1)))
        })
        .help("Drag to move, drag the edges to trim")
    }

    private func grip(_ side: TrimmedClip.Side, shown: Bool) -> some View {
        Capsule().fill(.primary.opacity(shown ? 0.45 : 0)).frame(width: 2, height: 12)
            .frame(width: 9, height: Lane.audio)
            .contentShape(.rect)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .modifier(TimelineDrag(model: model, width: width, edges: [side == .start ? track.at : track.end]) { o, move in
                guard let m0 = o.audio else { return }
                if side == .start {
                    // Trimming the start keeps the rest of the file where it was: later in the file, later on the timeline.
                    let d = min(max(move(m0.at) - m0.at, -m0.from, -m0.at), m0.length - 0.5)
                    model.edits.audio?.at = round2(m0.at + d)
                    model.edits.audio?.from = round2(m0.from + d)
                    model.edits.audio?.length = round2(m0.length - d)
                } else {
                    model.edits.audio?.length = round2(min(max(0.5, move(m0.end) - m0.at), m0.fileDuration - m0.from))
                }
            })
    }
}

/// An annotation on its lane: drag to move it, drag an edge to trim it. A video overlay's edges stop at its video's ends,
/// and trimming its start shows later in the video rather than moving it.
private struct AnnotationClip: View {
    @Bindable var model: EditorModel
    let index: Int
    let annotation: Annotation
    let width: CGFloat

    var body: some View {
        let selected = model.selectedAnnotation == index
        HStack(spacing: Space.xs) {
            grip(.start, shown: selected)
            ItemLabel(annotation.video?.name ?? annotation.name, symbol: annotation.symbol)
            Spacer(minLength: 0)
            grip(.end, shown: selected)
        }
        .modifier(LaneItem(tint: .noteClip, selected: selected))
        .modifier(TimelineDrag(model: model, width: width, edges: [annotation.start, annotation.end], lifts: true, tap: { _ in model.selectAnnotation(index) }) { o, move in
            guard o.allAnnotations.indices.contains(index) else { return }
            let a0 = o.allAnnotations[index], len = a0.end - a0.start
            var a = a0
            a.shift(by: round2(min(max(0, move(a0.start)), model.duration - len)) - a0.start)
            model.edits.allAnnotations[index] = a
        })
        .help("Drag to move, drag the edges to trim")
    }

    private func grip(_ side: TrimmedClip.Side, shown: Bool) -> some View {
        Capsule().fill(.primary.opacity(shown ? 0.45 : 0)).frame(width: 2, height: 10)
            .frame(width: 9, height: Lane.note)
            .contentShape(.rect)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .modifier(TimelineDrag(model: model, width: width, edges: [side == .start ? annotation.start : annotation.end]) { o, move in
                guard o.allAnnotations.indices.contains(index) else { return }
                let a0 = o.allAnnotations[index]
                if side == .start {
                    model.edits.allAnnotations[index].start = round2(min(max(move(a0.start), a0.video?.at ?? 0, 0), a0.end - 0.2))
                } else {
                    model.edits.allAnnotations[index].end = round2(max(min(move(a0.end), a0.video?.end ?? .infinity, model.duration), a0.start + 0.2))
                }
            })
    }
}

/// An inserted clip's name and a frame from it, inside its piece of the clip lane.
private struct InsertedClipLabel: View {
    let clip: InsertedClip
    let from: Double   // seconds into the clip where this piece starts
    let width: CGFloat
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: Space.xs) {
            if width > 70, let thumb {
                Image(nsImage: thumb).resizable().scaledToFill()
                    .frame(width: 44, height: Lane.clip - 2 * Space.xs).clipShape(.rect(cornerRadius: Radius.inner(Radius.small, inset: Space.xs)))
            }
            if width > 40 {
                Label(clip.name, systemImage: "film").font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m) // clear of the trim handles
        .allowsHitTesting(false)
        .task(id: "\(clip.path)|\(from)") { thumb = await Thumbnails.image(clip.path, at: max(0, from) + min(0.5, clip.length / 2), maxSize: 120) }
    }
}

/// An inserted clip's own commands: its sound, and where it plays.
private struct InsertedClipMenu: View {
    @Bindable var model: EditorModel
    let clip: Int
    let piece: Trim

    var body: some View {
        let c = model.edits.allClips.indices.contains(clip) ? model.edits.allClips[clip] : nil
        Divider()
        Menu("Clip Volume") {
            ForEach([1.0, 0.75, 0.5, 0.25, 0], id: \.self) { v in
                Toggle(v == 0 ? "Muted" : "\(Int(v * 100))%", isOn: Binding(get: { (c?.volume ?? 1) == v }, set: { _ in model.setClipVolume(clip, v) }))
            }
        }
        Button(model.edits.isSilenced(.clip, piece) ? "Bring Back This Part’s Sound" : "Silence This Part") { model.edits.toggleSilence(.clip, piece) }
        Button("Move to the Start") { model.moveClip(clip, to: model.edits.trim.start) }
            .disabled(c.map { $0.at <= model.edits.trim.start + 1e-6 } ?? true)
        Button("Move to the End") { model.moveClip(clip, to: model.edits.trim.end) }
            .disabled(c.map { $0.end >= model.edits.trim.end - 1e-6 } ?? true)
        if model.clipIsOnePiece(clip) { Button("Delete Clip", role: .destructive) { model.removeClip(clip) } }
    }
}

/// Ticks in the edited video's time.
private struct Ruler: View {
    let scale: TimelineScale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Labels at least 70 points apart, however far the timeline is zoomed.
        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].first { CGFloat($0 / scale.total) * scale.width >= 70 } ?? 7200
        let ticks = Array(stride(from: 0.0, through: scale.total, by: step))
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                let x = CGFloat(t / scale.total) * scale.width
                // Too close to the right edge to fit after its tick, a label ends at the tick instead.
                let end = x > scale.width - 56
                VStack(alignment: end ? .trailing : .leading, spacing: Space.xxs) {
                    // A step stronger in light mode, where tertiary grey on the pale bar is hard to read.
                    Text(formatTime(t)).font(.caption.monospacedDigit()).foregroundStyle(scheme == .light ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quiet)).fixedSize()
                        .padding(.leading, end ? 0 : 6) // clear of the playhead's knob, which sits on the tick
                    Rectangle().fill(.quiet).frame(width: 1, height: 4)
                }
                .frame(width: 56, alignment: end ? .trailing : .leading)
                .offset(x: end ? x - 55 : x)
            }
        }
        .frame(height: Lane.ruler, alignment: .topLeading)
    }
}

/// The caption lines, under the sound they were made from. Before there are any, the lane offers to make them. Click a
/// line to select it (⌫ deletes it), drag it to move it between its neighbours; right-click to split or delete.
private struct CaptionLane: View {
    @Bindable var model: EditorModel
    let scale: TimelineScale
    let width: CGFloat
    let showsTip: Bool

    var body: some View {
        if let c = model.edits.captions {
            ZStack(alignment: .topLeading) {
                ForEach(Array(c.lines.enumerated()).filter { scale.width($0.element.start, $0.element.end) > 0.5 }, id: \.offset) { i, line in
                    self.line(i, line, on: c.visible)
                }
            }
        } else {
            // A real button, so it reads as an action in an otherwise empty lane.
            HStack(spacing: Space.s) {
                // Drawn here rather than .bordered: AppKit's bezel all but disappears against the lane, more so when the
                // window isn't in front.
                Button { model.showCaptions = true } label: {
                    Label { Text("Make Captions") } icon: { Image(systemName: "captions.bubble").foregroundStyle(.secondary) }
                        .font(.subheadline)
                        .padding(.horizontal, Space.s).frame(height: 20) // off-scale: a small control's height
                        .background(.faint(0.08), in: .rect(cornerRadius: Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.faint(0.15)))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.transcribing)
                .opacity(model.transcribing ? 0.5 : 1)
                if model.transcribing {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing on this Mac…").font(.subheadline).foregroundStyle(.secondary)
                }
                if showsTip { TipBubble(tip: .captions).transition(.opacity) }
            }
            .motion(Motion.hover, value: showsTip)
            .padding(.horizontal, Space.s)
            .frame(height: Lane.caption)
            .help("Transcribes the microphone on this Mac and shows it as subtitles. Nothing is uploaded.")
        }
    }

    private func line(_ i: Int, _ line: CaptionLine, on: Bool) -> some View {
        let selected = model.selectedCaption == i
        return Text(line.text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, Space.s)
            .frame(width: max(4, scale.width(line.start, line.end) - 1), height: Lane.caption, alignment: .leading)
            .background(Color.captionClip.opacity(on ? 0.85 : 0.3), in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.white, lineWidth: selected ? 2 : 0))
            .foregroundStyle(.black.opacity(on ? 0.8 : 0.5))
            .clipped()
            .modifier(TimelineDrag(model: model, width: width, edges: [line.start, line.end], tap: { _ in model.selectCaption(i) }) { o, move in
                guard let l = o.captions?.lines, l.indices.contains(i) else { return }
                model.edits.captions?.move(i, to: move(l[i].start))
            })
            .overlay {
                HStack(spacing: 0) {
                    ForEach([true, false], id: \.self) { start in
                        if !start { Spacer(minLength: 0) }
                        TrimGrip(model: model, width: width, height: Lane.caption, edge: start ? line.start : line.end) { o, move in
                            guard let l = o.captions?.lines, l.indices.contains(i) else { return }
                            model.edits.captions?.trim(i, start: start, to: move(start ? l[i].start : l[i].end))
                        }
                    }
                }
            }
            .contextMenu {
                Button("Split at Playhead") { model.selectedCaption = i; model.splitCaption() }
                    .disabled(!(model.time > line.start + 0.05 && model.time < line.end - 0.05 && line.text.contains(" ")))
                Button("Delete Line", role: .destructive) { model.selectedCaption = i; model.perform(.delete) }
            }
            .help(line.text)
            .offset(x: scale.x(line.start))
    }
}

/// A source of the recording on its own lane: a waveform for sound, a plain bar for the camera. Dimmed when off.
private struct SourceClip: View {
    let name: String
    let color: Color
    let on: Bool
    /// Loudness every `VoiceActivity.window` seconds from the source's start; nil for the camera.
    let levels: [Double]?
    let volume: Double
    /// Seconds into `levels` at x points from the clip's left edge, following the timeline's cuts and speeds; nil where
    /// the source isn't playing (an inserted clip).
    let at: (CGFloat) -> Double?


    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.small).fill(color.opacity(on ? 0.28 : 0.1))
            if let levels, !levels.isEmpty {
                Canvas { ctx, size in
                    // One bar per two points, the loudest moment in it; square-rooted so quiet speech still shows.
                    let step: CGFloat = 2, mid = size.height / 2
                    var path = Path()
                    var px: CGFloat = 0
                    while px < size.width {
                        if let a = at(px), let b = at(px + step) ?? at(px) {
                            let i0 = max(0, Int(a / VoiceActivity.window)), i1 = min(levels.count, Int(b / VoiceActivity.window) + 1)
                            if i0 < i1 {
                                let peak = levels[i0..<i1].max() ?? 0
                                let h = max(1, CGFloat(min(1, (peak * volume / 0.25).squareRoot())) * (size.height - 6))
                                path.addRect(CGRect(x: px, y: mid - h / 2, width: 1.2, height: h))
                            }
                        }
                        px += step
                    }
                    ctx.fill(path, with: .color(color.ink.opacity(on ? 0.95 : 0.35)))
                }
                .allowsHitTesting(false)
            }
            Text(on ? name : "\(name) (off)").font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                .background(.background.opacity(0.75), in: .capsule) // the window's background: dark or light with the appearance
                .foregroundStyle(.primary.opacity(on ? 0.9 : 0.5))
                .padding(.leading, Space.xs)
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: Radius.small))
        .allowsHitTesting(false)
    }
}

private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 2, bottomLeading: 5, bottomTrailing: 5, topTrailing: 2)) // off-scale: the knob is a glyph, not a panel
                .fill(.graphite).frame(width: 10, height: 9)
            Rectangle().fill(.graphite).frame(width: 2.5, height: height - 7)
        }
        .shadow(color: .black.opacity(0.25), radius: 1)
    }
}
