import AppKit
import ImageIO
import RecordCore
import RecordKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The selected item's properties, in place of the tabs; back (or Esc) returns to them.
        let item = Selected(model)
        // Clicking an item slides its settings in from the trailing edge and back slides them out the same way, faster.
        // Anything from the keyboard (Esc, ⌫, adding with Z…) swaps them at once.
        let keyboard = CACurrentMediaTime() - model.keyPressedAt < 0.3
        // A ZStack rather than a Group: a Group hands its modifiers to each branch, so the animation would leave with them.
        ZStack {
            if let item {
                VStack(spacing: 0) {
                    SelectionHeader(model: model, item: item, title: item.title(model.edits), fact: item.fact(model.edits))
                    Form {
                        switch item {
                        case .zoom(let i): ZoomDetail(model: model, index: i)
                        case .callout(let i): CalloutDetail(model: model, index: i)
                        case .annotation(let i): AnnotationDetail(model: model, index: i)
                        case .caption(let i): CaptionDetail(model: model, index: i)
                        case .chapter(let i): ChapterDetail(model: model, index: i)
                        case .music(let piece): MusicDetail(model: model, piece: piece)
                        case .piece(let i): PieceDetail(model: model, piece: i)
                        case .insertedClip(let c, let i): InsertedClipDetail(model: model, clip: c, piece: i)
                        }
                    }
                    .formStyle(.grouped)
                }
                .transition(.slide(edge: .trailing))
            } else {
                VStack(spacing: 0) {
                    InspectorTabs(model: model, animated: !keyboard)
                        .padding(.horizontal, Space.l)
                        .padding(.vertical, Space.s)
                    // A clicked tab cross-fades its settings in; ⌘1–⌘4 swap them at once.
                    let shown = model.tabs.contains(model.tab) ? model.tab : .look
                    ZStack {
                    Form {
                        // Only what applies to this recording: no webcam section without a camera, no captions without
                        // microphone sound, no shortcut keycaps without shortcuts.
                        switch shown {
                        case .look:
                            BackgroundPane(model: model)
                            CropPane(model: model)
                        case .cursorZoom:
                            ZoomPane(model: model)
                            CursorPane(model: model)
                        case .overlays:
                            if model.edits.camera != nil { WebcamPane(model: model) }
                            if model.rec.hasAudio { CaptionsPane(model: model) }
                            if !model.keys.isEmpty { ShortcutsPane(model: model) }
                        case .sound: AudioPane(model: model)
                        }
                    }
                    .formStyle(.grouped)
                    .id(shown)
                    .transition(.opacity)
                    }
                    .animation(keyboard ? nil : Motion.hover, value: shown)
                }
                // The tabs make way quickly, so they don't sit under the settings sliding in.
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit)))
            }
        }
        .clipped() // the sliding settings stay inside the inspector's column
        .animation(keyboard ? nil : (item == nil ? Motion.exit : Motion.enter).respecting(reduceMotion), value: item == nil)
    }
}

/// A group's section title, with Reset to put its settings back as a new recording starts them.
private struct GroupHeader: View {
    let title: String
    let model: EditorModel
    let group: SettingsGroup

    var body: some View {
        let reset = model.edits.resetting(group, to: model.defaults)
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("Reset") { model.edits = reset }
                .buttonStyle(.borderless)
                .disabled(reset == model.edits)
                .help("Put the \(title.lowercased()) settings back to how new recordings start (⌘Z undoes it)")
        }
    }
}

/// The fine-tuning of a group, out of the way until asked for. Open or closed as it was last left, per group.
/// Its settings are ordinary rows of the section, the same height and with the same dividers as the essentials above,
/// so opening it only adds rows. They arrive with `Motion.enter` and leave faster; the chevron turns with them.
private struct MoreOptions<Content: View>: View {
    @AppStorage private var open: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ key: String, @ViewBuilder content: () -> Content) {
        _open = AppStorage(wrappedValue: false, "moreOptions." + key)
        self.content = content()
    }

    var body: some View {
        // The whole row is the button, and quieter than the settings, since it's a way in rather than a setting.
        Button {
            withAnimation((open ? Motion.exit : Motion.enter).respecting(reduceMotion)) { open.toggle() }
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                Text("More options")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Open" : "Closed")
        if open { content }
    }
}

/// The inspector's four tabs. The selection is a graphite pill that slides to a clicked tab; from the keyboard
/// (⌘1–⌘4) it's there at once, and with Reduce Motion it doesn't travel.
private struct InspectorTabs: View {
    @Bindable var model: EditorModel
    let animated: Bool
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = model.tabs.contains(model.tab) ? model.tab : .look
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                let selected = tab == shown
                Button { model.tab = tab } label: {
                    Text(tab.name).lineLimit(1).fixedSize()
                        .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Radius.small).fill(.graphite)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Space.xxs)
        .background(.faint(0.06), in: .rect(cornerRadius: Radius.outer(Radius.small, inset: Space.xxs)))
        .animation(animated && !reduceMotion ? Motion.move : nil, value: shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector sections")
    }
}

// MARK: - Selection

/// The item whose properties the inspector shows: the one selected on the timeline or the preview, if it still exists.
private enum Selected: Equatable {
    case zoom(Int), callout(Int), annotation(Int), caption(Int), chapter(Int)
    /// The music, and the piece of it that was clicked once the clip is split.
    case music(piece: Int?)
    /// A piece of the clip between splits: of the recording, or of an inserted clip.
    case piece(Int), insertedClip(Int, piece: Int)

    @MainActor init?(_ m: EditorModel) {
        if let i = m.selectedZoom, m.edits.zooms.indices.contains(i) { self = .zoom(i) }
        else if let i = m.selectedCallout, m.edits.callouts.indices.contains(i) { self = .callout(i) }
        else if let i = m.selectedAnnotation, m.edits.allAnnotations.indices.contains(i) { self = .annotation(i) }
        else if let i = m.selectedCaption, m.edits.captions?.lines.indices.contains(i) == true { self = .caption(i) }
        else if let i = m.selectedMarker, m.edits.allMarkers.indices.contains(i) { self = .chapter(i) }
        else if m.selectedMusic, m.edits.audio != nil { self = .music(piece: m.selectedPart?.segment) }
        else if let p = m.selectedPart, p.lane == .clip, m.edits.keptSegments.indices.contains(p.segment) {
            let s = m.edits.keptSegments[p.segment]
            if let c = m.edits.clipIndex(at: (s.start + s.end) / 2) { self = .insertedClip(c, piece: p.segment) } else { self = .piece(p.segment) }
        }
        else { return nil }
    }

    func title(_ e: Edits) -> (name: String, symbol: String, start: Double, end: Double) {
        switch self {
        case .zoom(let i): ("Zoom", e.zooms[i].focus == nil ? "plus.magnifyingglass" : "scope", e.zooms[i].start, e.zooms[i].end) // as on the timeline
        case .callout(let i): ("Text", "textformat", e.callouts[i].start, e.callouts[i].end)
        case .annotation(let i):
            (e.allAnnotations[i].video?.name ?? e.allAnnotations[i].name, e.allAnnotations[i].symbol, e.allAnnotations[i].start, e.allAnnotations[i].end)
        case .caption(let i): ("Caption", "captions.bubble", e.captions!.lines[i].start, e.captions!.lines[i].end)
        case .chapter(let i): (e.allMarkers[i].name, "bookmark", e.allMarkers[i].t, e.allMarkers[i].t)
        case .music: (URL(fileURLWithPath: e.audio!.path).deletingPathExtension().lastPathComponent, "music.note", e.audio!.at, e.audio!.end)
        case .piece(let i): (e.keptSegments.count == 1 ? "Clip" : "Part \(i + 1)", "rectangle.split.3x1", e.keptSegments[i].start, e.keptSegments[i].end)
        case .insertedClip(let c, let i): (e.allClips[c].name, "film", e.keptSegments[i].start, e.keptSegments[i].end)
        }
    }

    /// The colour of the item's lane on the timeline.
    var tint: Color {
        switch self {
        case .zoom: .zoomClip
        case .callout: .textClip
        case .annotation: .noteClip
        case .caption: .captionClip
        case .chapter: .chapterMark
        case .music: .audioClip
        case .piece: .clipHandle
        case .insertedClip: .insertedClip
        }
    }

    /// One thing worth knowing at a glance, shown after the time.
    func fact(_ e: Edits) -> String? {
        switch self {
        case .zoom(let i): String(format: "%.1f×", e.zooms[i].scale) + (e.zooms[i].focus == nil ? "" : " · Pinned")
        case .callout(let i): e.callouts[i].text.isEmpty ? nil : e.callouts[i].text
        case .caption(let i): e.captions!.lines[i].text
        case .chapter: "Chapter"
        case .piece(let i): e.keptSegments[i].speed.flatMap { $0 == 1 ? nil : speedLabel($0) }
        case .insertedClip: "Inserted clip"
        case .annotation, .music: nil
        }
    }
}

/// What's selected: its lane's icon and colour, its name, and on a second line when it plays and one key fact, with a
/// way back to the tabs and a delete button (⌫ does the same).
/// The title and fact are worked out by the inspector while the item exists: after a click deletes it, this header
/// stays on screen while the tabs slide back, and reading the item from the edits then would be out of range.
private struct SelectionHeader: View {
    let model: EditorModel
    let item: Selected
    let title: (name: String, symbol: String, start: Double, end: Double)
    let fact: String?

    var body: some View {
        let t = title, map = model.edits.timeMap
        HStack(spacing: Space.s) {
            Button { model.deselect() } label: { Image(systemName: "chevron.left").frame(width: 20, height: 28).contentShape(.rect) }
                .buttonStyle(.borderless)
                .help("Back to \(model.tab.name) (Esc)")
            Image(systemName: t.symbol).font(.body.weight(.medium)).foregroundStyle(item.tint.ink).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(t.name).font(.headline).lineLimit(1)
                let from = sourceToOutput(map, t.start), to = sourceToOutput(map, t.end)
                // A chapter is a moment, not a span.
                let when = t.start == t.end ? timecode(from) : to - from < 0.05 ? "Cut from the video" : "\(timecode(from)) – \(timecode(to))"
                Text([when, fact].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // With a piece of the music clicked, ⌫ silences just that piece: nothing removes all of it from a piece.
            let musicPiece = if case .music(piece: .some) = item { true } else { false }
            Button(musicPiece ? "Silence This Part" : "Delete", systemImage: musicPiece ? "speaker.slash" : "trash", role: musicPiece ? nil : .destructive) {
                model.perform(.delete)
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(musicPiece ? "Silence or bring back the part you clicked (⌫)" : "Delete \(t.name) (⌫)")
                .disabled(item == .piece(0) && model.edits.keptSegments.count == 1) // the whole recording can't be cut
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.l)
        .frame(height: 38) // the tabs' height, so the form doesn't jump
    }
}

// MARK: - Captions

private struct CaptionsPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section {
            Toggle("Show captions", isOn: $model.showCaptions)
                .toggleStyle(.switch)
                .disabled(model.transcribing)
            if model.transcribing {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on this Mac…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Captions")
        } footer: {
            if model.edits.captions == nil { Text("Subtitles made from what’s said in the recording, transcribed on this Mac. Nothing is uploaded.") }
            else { Text("Click a line on the timeline to edit its words.") }
        }

        if let c = Binding($model.edits.captions) {
            Section {
                Group {
                    Picker("Style", selection: c.style) {
                        Text("Dark box").tag(Captions.Style.box)
                        Text("Outline").tag(Captions.Style.outline)
                    }
                    Picker("Position", selection: c.position) {
                        Text("Bottom").tag(Captions.Position.bottom)
                        Text("Top").tag(Captions.Position.top)
                    }
                }
                .disabled(!c.wrappedValue.visible)
                MoreOptions(SettingsGroup.captions.rawValue) {
                    SliderRow(label: "Size", value: c.size, range: Captions.sizes)
                        .disabled(!c.wrappedValue.visible)
                    // Not disabled with the captions hidden: the file is saved either way.
                    Toggle("Save subtitles file (.srt)", isOn: c.srt)
                        .help("Saved next to the exported video, even with captions hidden, for players and sites that show their own subtitles")
                }
            } header: {
                GroupHeader(title: "Caption style", model: model, group: .captions)
            }

            Section {
                Button("Transcribe Again") { model.makeCaptions() }
                    .disabled(model.transcribing)
            } footer: {
                Text("Replaces every line with a fresh transcript. Undo (⌘Z) brings your edited lines back.")
            }
        }
    }
}

/// A selected caption line: its words, splitting it at the playhead, and when it shows.
private struct CaptionDetail: View {
    @Bindable var model: EditorModel
    let index: Int

    var body: some View {
        if let lines = model.edits.captions?.lines, lines.indices.contains(index) {
            let line = lines[index]
            Section {
                TextField("Line", text: Binding(get: { line.text }, set: { t in
                    if model.edits.captions?.lines.indices.contains(index) == true { model.edits.captions?.lines[index].text = t }
                }), axis: .vertical)
                .labelsHidden()
                Button("Split at Playhead", systemImage: "scissors") { model.splitCaption() }
                    .disabled(model.splittableCaption != index)
                    .help("Split this line in two at the playhead, sharing its words. Move the playhead into the line first.")
            } footer: {
                Text("Drag the line on the timeline to move it, or its edges to change when it shows.")
            }
        }
    }
}

// MARK: - Background

private struct BackgroundPane: View {
    @Bindable var model: EditorModel
    @State private var walls: [Wallpaper] = []
    @State private var importing = false
    @State private var showWalls = false

    var body: some View {
        LookSection(model: model)
        Section {
            Picker("Aspect ratio", selection: $model.edits.aspect) {
                Text("Match recording").tag(String?.none)
                Divider()
                ForEach(aspectRatios, id: \.value) { Text($0.label).tag(Optional($0.value)) }
            }
            SliderRow(label: "Padding", value: $model.edits.padding, range: 0...0.25)
            SliderRow(label: "Corners",
                      value: Binding(get: { model.edits.cornerRadius ?? cornerRadiusPx(model.size, model.edits) / Double(max(1, min(model.size.contentW, model.size.contentH))) },
                                     set: { model.edits.cornerRadius = $0 }),
                      range: cornerRadii)
            MoreOptions(SettingsGroup.look.rawValue) {
                Group {
                    PercentSlider(label: "Shadow", value: $model.edits.shadow, fallback: DropShadow.defaultStrength)
                    PercentSlider(label: "Softness", value: $model.edits.shadowSoftness, fallback: DropShadow.defaultSoftness)
                        .disabled((model.edits.shadow ?? DropShadow.defaultStrength) == 0)
                }
                .disabled(model.size.x == 0 && model.size.y == 0)
                .help("The shadow shows on the background around the video, so it needs padding or a different aspect ratio")
                if let cap = model.rec.capture, cap.isWindow {
                    Button("Match Window Corners") {
                        model.edits.cornerRadius = windowCornerFraction(width: model.rec.width, height: model.rec.height, crop: model.edits.crop, pointScale: cap.pointScale)
                    }
                    .help("Round the frame like the recorded window, so its corners line up exactly")
                }
            }
        } header: {
            GroupHeader(title: "Canvas", model: model, group: .look)
        }

        // One kind of fill at a time, so every control shown changes what you see.
        Section("Background") {
            Picker("Fill", selection: Binding(get: { model.edits.fill }, set: { kind in
                var e = model.edits, memory = model.backgroundMemory
                if e.setFill(kind, memory: &memory, wallpaper: Wallpapers.preferred()) { (model.edits, model.backgroundMemory) = (e, memory) }
                else if kind == .image { importing = true } // nothing chosen yet
            })) {
                ForEach(BackgroundFill.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.edits.fill {
            case .wallpaper:
                // The current one first, then the next few; the rest are under More….
                let current = walls.first { $0.path == model.edits.backgroundImage }
                HStack(spacing: Space.s) {
                    ForEach(Array(([current].compactMap { $0 } + walls.filter { $0 != current }).prefix(3))) { wallButton($0) }
                    Button("More…") { showWalls = true }
                        .popover(isPresented: $showWalls, arrowEdge: .leading) {
                            ScrollView {
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: Space.s), count: 3), spacing: Space.s) {
                                    ForEach(walls) { wallButton($0) }
                                }
                                .padding(Space.m)
                            }
                            .frame(height: 360)
                        }
                }
                if walls.isEmpty { Text("No macOS wallpapers were found. You can still use your own image.").foregroundStyle(.secondary) }
                PercentSlider(label: "Blur", value: $model.edits.backgroundBlur, fallback: 0)
            case .image:
                HStack(spacing: Space.m) {
                    if let img = model.edits.backgroundImage { Swatch(selected: false) { Thumb(path: img) }.frame(width: 96) }
                    Button("Choose Image…") { importing = true }
                }
                PercentSlider(label: "Blur", value: $model.edits.backgroundBlur, fallback: 0)
            case .gradient:
                HStack(spacing: Space.s) {
                    ForEach(BackgroundGradient.presets, id: \.self) { g in
                        Button { model.edits.gradient = g } label: {
                            Circle().fill(linear(g))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                                .padding(Space.xxs)
                                .overlay(Circle().strokeBorder(.graphite, lineWidth: model.edits.gradient == g ? 2 : 0))
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.9))
                        .accessibilityLabel("Gradient \(g.from) to \(g.to)")
                    }
                }
                // Not `Binding($model.edits.gradient)`: that crashes when switching to Colour clears the gradient
                // while these controls are still on screen.
                let g = Binding(get: { model.edits.gradient ?? BackgroundGradient.presets[0] }, set: { model.edits.gradient = $0 })
                ColorPicker("From", selection: hexBinding(g.from), supportsOpacity: false)
                ColorPicker("To", selection: hexBinding(g.to), supportsOpacity: false)
                SliderRow(label: "Angle", value: g.angle, range: 0...360, step: 15, readout: Readout.degrees)
            case .colour:
                HStack(spacing: Space.s) {
                    ForEach(["#1e1b4b", "#0f3d3e", "#3b1f2b", "#2b2f36", "#e8e4dc", "#f5d0a9"], id: \.self) { hex in
                        Button { model.edits.background = hex } label: {
                            Circle().fill(Color(cgColor: hexColor(hex)))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                                .padding(Space.xxs)
                                .overlay(Circle().strokeBorder(.graphite, lineWidth: model.edits.background == hex ? 2 : 0))
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.9))
                        .accessibilityLabel("Colour \(hex)")
                    }
                }
                ColorPicker("Colour", selection: hexBinding($model.edits.background), supportsOpacity: false)
            }
        }
        .task { walls = await Task.detached { Wallpapers.list() }.value }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let src = try result.get()
                guard src.startAccessingSecurityScopedResource() || true else { return }
                defer { src.stopAccessingSecurityScopedResource() }
                guard imageExtensions.contains(src.pathExtension.lowercased()) else { throw StudioError.message("Choose a HEIC, JPEG, PNG, TIFF or WebP image.") }
                // Copy it into the library so the edit keeps working if the original moves.
                let dest = Paths.backgrounds.appending(path: "import-\(Int(Date().timeIntervalSince1970)).\(src.pathExtension.lowercased())")
                try FileManager.default.createDirectory(at: Paths.backgrounds, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: dest)
                if model.edits.fill == .wallpaper { model.backgroundMemory.wallpaper = model.edits.backgroundImage }
                model.edits.backgroundImage = dest.path
            } catch {
                Studio.shared.error = Problem("Couldn’t use that image", error.localizedDescription,
                                              action: MessageAction(label: "Choose Another…") { importing = true })
            }
        }
    }

    private func wallButton(_ w: Wallpaper) -> some View {
        Button { model.edits.backgroundImage = w.path; showWalls = false } label: {
            Swatch(selected: model.edits.backgroundImage == w.path) { Thumb(path: w.thumb) }
        }
        .buttonStyle(PressableButtonStyle())
        .help(w.name)
        .accessibilityLabel(w.name)
    }
}

/// The same gradient the renderer draws, for a swatch.
/// Saved looks: applying one, saving the current appearance as one, and which one new recordings start with.
private struct LookSection: View {
    @Bindable var model: EditorModel
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        @Bindable var studio = Studio.shared
        let current = studio.looks.current(model.edits)
        // The look this one was made from, while it's still saved.
        let base = current?.name ?? model.appliedLook.flatMap { n in studio.looks.all.contains { $0.name == n } ? n : nil }
        Section {
            LabeledContent("Look") {
                Menu(current?.name ?? base.map { "\($0) (edited)" } ?? "Custom") {
                    ForEach(studio.looks.all) { look in
                        Toggle(look.name, isOn: Binding(get: { current == look }, set: { _ in apply(look.name, look.edits) }))
                    }
                    Button("Built-in Default") { apply(nil, model.rec.startingEdits(cursor: [], looks: Looks())) }
                    Divider()
                    Button("Save Current as Look…") { name = base ?? ""; naming = true }
                    if let base {
                        Button("Update “\(base)”") { studio.looks.save(base, from: model.edits) }
                            .disabled(current != nil)
                        Toggle("Use “\(base)” for New Recordings", isOn: Binding(get: { studio.looks.forNew == base },
                                                                               set: { studio.looks.forNew = $0 ? base : nil }))
                        Button("Delete “\(base)”", role: .destructive) { studio.looks.delete(base); model.appliedLook = nil }
                    }
                }
                // Plain text and a chevron like the pickers around it. The default style draws its title in white for a
                // graphite fill that light mode never shows.
                .menuStyle(.button).buttonStyle(.borderless).tint(.primary)
                .fixedSize()
            }
        } footer: {
            Text(studio.looks.all.isEmpty
                 ? "Save this recording’s look (background, frame, cursor, webcam, caption style and microphone clean-up) to use it on others in one click."
                 : "A look sets the background, frame, cursor, webcam, caption style and microphone clean-up, and leaves your edits alone.")
        }
        .alert("Save Look", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                studio.looks.save(n, from: model.edits)
                model.appliedLook = n
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A look with the same name is replaced.")
        }
    }

    private func apply(_ name: String?, _ look: Edits) {
        model.edits = model.edits.withLook(of: look)
        model.appliedLook = name
    }
}

private func linear(_ g: BackgroundGradient) -> LinearGradient {
    let e = gradientEnds(g, width: 1, height: 1)
    return LinearGradient(colors: [Color(cgColor: hexColor(g.from)), Color(cgColor: hexColor(g.to))],
                          startPoint: UnitPoint(x: e.start.x, y: e.start.y), endPoint: UnitPoint(x: e.end.x, y: e.end.y))
}

private struct Swatch<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content
    var body: some View {
        // Fixed 16:10 frame; portrait thumbnails fill it instead of stretching the grid row.
        Rectangle().fill(.quaternary)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay { content }
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.outer(Radius.small, inset: Space.xxs)).strokeBorder(.graphite, lineWidth: selected ? 2 : 0).padding(-Space.xxs))
            .contentShape(.rect)
    }
}

private struct Thumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .task(id: path) {
            image = await Task.detached { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 320,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

// MARK: - Zoom

private struct ZoomPane: View {
    @Bindable var model: EditorModel
    @State private var confirmRedetect = false

    private func redetect() {
        model.selectedZoom = nil
        model.edits.zooms = autoZooms(model.edits.timelineCursor(model.cursor), duration: model.duration)
    }

    var body: some View {
        Section {
            if model.cursor.isEmpty { Text("No click data for this recording, so add zooms by hand.").foregroundStyle(.secondary) }
            else if model.edits.zooms.isEmpty { Text("No clicks were detected. Add a zoom at the playhead.").foregroundStyle(.secondary) }
            Button("Add Zoom at Playhead") { model.addZoom() }
            if !model.cursor.isEmpty {
                // Replaces every zoom, so it asks first.
                Button("Redetect from Clicks…") {
                    if model.edits.zooms.isEmpty { redetect() } else { confirmRedetect = true }
                }
                .confirmationDialog("Replace \(model.edits.zooms.count == 1 ? "the zoom" : "all \(model.edits.zooms.count) zooms") with zooms detected from clicks?",
                                    isPresented: $confirmRedetect) {
                    Button("Replace Zooms") { redetect() }
                } message: {
                    Text("You can undo this.")
                }
            }
        } header: {
            Text("Zooms")
        } footer: {
            if !model.edits.zooms.isEmpty { Text("Click a zoom on the timeline to change its size or what it shows.") }
        }
    }
}

/// Zoom size and follow vs pinned; the area itself is dragged on the preview (see `ZoomFrame`).
private struct ZoomDetail: View {
    @Bindable var model: EditorModel
    let index: Int
    /// SwiftUI can redraw this once more after the zoom is deleted, before the parent drops it, so a stale index reads
    /// a placeholder instead of crashing.
    private var zoom: Binding<Zoom> {
        Binding(get: { model.edits.zooms.indices.contains(index) ? model.edits.zooms[index] : Zoom(start: 0, end: 1, scale: 1.2) },
                set: { if model.edits.zooms.indices.contains(index) { model.edits.zooms[index] = $0 } })
    }

    var body: some View {
        let z = zoom.wrappedValue
        let mid = (z.start + z.end) / 2
        Section {
            SliderRow(label: "Size", value: zoom.scale, range: 1.2...4, step: 0.1, readout: Readout.scale)

            Picker("Camera", selection: Binding(get: { z.focus != nil }, set: { pin in
                if pin {
                    let auto = cameraAt(cameraPath(model.cursor, model.edits, duration: model.rec.duration), mid)
                    zoom.wrappedValue.focus = Point(x: auto.x, y: auto.y)
                } else {
                    zoom.wrappedValue.focus = nil
                }
            })) {
                Text("Follow cursor").tag(false)
                Text("Pin to area").tag(true)
            }
            .pickerStyle(.segmented)

            Text(z.focus == nil ? "The camera follows the cursor. Drag the box on the preview to pin it instead."
                                : "Drag the box on the preview to choose what the zoom shows, or its corner to resize it.")
                .font(.callout).foregroundStyle(.secondary)

            LabeledContent("Start") { SecondsField(value: zoom.start) }
            LabeledContent("End") { SecondsField(value: zoom.end) }
        }
    }
}

struct SecondsField: View {
    @Binding var value: Double
    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            .overlay(alignment: .trailing) { Text("s").foregroundStyle(.tertiary).offset(x: 12) }
            .padding(.trailing, Space.m)
    }
}

// MARK: - Cursor

private struct CursorPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        if model.cursor.isEmpty {
            Section("Cursor") {
                Text("This video was made outside RecordStudio, so there’s no cursor to redraw, highlight or follow. Each zoom stays on the point you pin.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let style = Binding(get: { model.edits.cursorStyle ?? CursorStyle() }, set: { model.edits.cursorStyle = $0 })
            let drawn = !model.cursorImages.isEmpty
            Section {
                if drawn {
                    Toggle("Show cursor", isOn: style.visible)
                        .toggleStyle(.switch)
                    SliderRow(label: "Size", value: style.size, range: CursorStyle.sizes, readout: Readout.scale)
                    .disabled(!style.wrappedValue.visible)
                }
                Picker("Click effect", selection: $model.edits.clickEffect) {
                    Text("None").tag(ClickEffect?.none)
                    Text("Ripple").tag(Optional(ClickEffect.ripple))
                    // Bounce animates the drawn cursor, so older recordings with the cursor in the video can't have it.
                    if drawn { Text("Bounce").tag(Optional(ClickEffect.bounce)) }
                }
                MoreOptions(SettingsGroup.cursor.rawValue) {
                    if drawn {
                        SliderRow(label: "Smoothing", value: style.smoothing, range: 0...1)
                        .disabled(!style.wrappedValue.visible)
                        Toggle("Motion blur", isOn: Binding(get: { style.wrappedValue.motionBlur != nil },
                                                            set: { style.wrappedValue.motionBlur = $0 ? 0.5 : nil }))
                            .toggleStyle(.switch)
                            .disabled(!style.wrappedValue.visible)
                        if let blur = style.wrappedValue.motionBlur {
                            SliderRow(label: "Blur strength", value: Binding(get: { blur }, set: { style.wrappedValue.motionBlur = $0 }), range: 0.1...1)
                            .disabled(!style.wrappedValue.visible)
                        }
                    }
                    Toggle("Highlight cursor", isOn: $model.edits.cursorHighlight)
                        .toggleStyle(.switch)
                    Toggle("Hide when idle", isOn: Binding(get: { model.edits.cursorIdleHide != nil },
                                                           set: { model.edits.cursorIdleHide = $0 ? 2 : nil }))
                        .toggleStyle(.switch)
                    if let delay = model.edits.cursorIdleHide {
                        SliderRow(label: "Idle after", value: Binding(get: { delay }, set: { model.edits.cursorIdleHide = $0 }),
                                  range: 1...5, step: 0.5, readout: Readout.seconds)
                    }
                }
            } header: {
                GroupHeader(title: "Cursor", model: model, group: .cursor)
            }
        }
    }
}

/// Keycaps for the shortcuts pressed while recording. Only shown when the recording captured some (Show shortcuts was on
/// while recording, with the permission).
private struct ShortcutsPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        let style = Binding(get: { model.edits.keystrokes ?? KeystrokeStyle() }, set: { model.edits.keystrokes = $0 })
        Section {
            Toggle("Show shortcuts", isOn: style.visible)
                .toggleStyle(.switch)
                .help("Keycaps for the \(model.keys.count) shortcuts pressed while recording, e.g. ⌘ ⇧ 4")
            MoreOptions(SettingsGroup.shortcuts.rawValue) {
                Picker("Position", selection: style.position) {
                    Text("Bottom centre").tag(KeystrokeStyle.Position.bottomCenter)
                    Text("Bottom left").tag(KeystrokeStyle.Position.bottomLeft)
                    Text("Bottom right").tag(KeystrokeStyle.Position.bottomRight)
                }
                SliderRow(label: "Size", value: style.size, range: KeystrokeStyle.sizes)
            }
            .disabled(!style.wrappedValue.visible)
        } header: {
            GroupHeader(title: "Shortcuts", model: model, group: .shortcuts)
        }
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @Bindable var model: EditorModel
    @State private var importing = false

    var body: some View {
        Section {
            if model.rec.hasAudio { PercentSlider(label: "Microphone", value: $model.edits.micVolume, fallback: 1) }
            if model.rec.hasSystemAudio { PercentSlider(label: "System audio", value: $model.edits.systemVolume, fallback: 1) }
            if !model.rec.hasAudio, !model.rec.hasSystemAudio { Text("This recording has no sound of its own.").foregroundStyle(.secondary) }
            if model.rec.hasAudio { MoreOptions(SettingsGroup.sound.rawValue) { MicCleanup(model: model) } }
        } header: {
            GroupHeader(title: "Recording", model: model, group: .sound)
        } footer: {
            if model.rec.hasSystemAudio { Text("System audio is the sound other apps played while recording, kept apart so you can balance it against your voice.") }
        }

        Section {
            Button(model.edits.audio == nil ? "Add Music or Voice-over…" : "Replace Audio File…") { importing = true }
        } footer: {
            Text("The file is copied into this recording and starts at the playhead. Drag it on the timeline to move it, or drag its ends to trim it.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            Task {
                do {
                    let src = try result.get()
                    let scoped = src.startAccessingSecurityScopedResource()
                    defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                    try await model.setAudio(from: src)
                } catch {
                    Studio.shared.error = Problem("Couldn’t add that audio file", error.localizedDescription,
                                                  action: MessageAction(label: "Choose Another…") { importing = true })
                }
            }
        }

        if let m = Binding($model.edits.audio) {
            Section(URL(fileURLWithPath: m.wrappedValue.path).lastPathComponent) {
                MusicControls(music: m)
                Button("Delete Audio", role: .destructive) { model.edits.audio = nil }.foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// The music's start, volume, fades and ducking: in the Audio tab, and when the music is selected.
private struct MusicControls: View {
    @Binding var music: AudioTrack

    var body: some View {
        LabeledContent("Starts at") { SecondsField(value: $music.at) }
        LabeledContent("Plays for") { Text(formatTime(music.length)).monospacedDigit() }
        SliderRow(label: "Volume", value: $music.volume, range: 0...1)
        MoreOptions("music") {
            seconds("Fade in", $music.fadeIn)
            seconds("Fade out", $music.fadeOut)
            Toggle("Lower it while I'm speaking", isOn: $music.duck)
                .help("Dips the music to a quarter of its volume wherever the microphone picks up your voice")
        }
    }

    private func seconds(_ label: String, _ v: Binding<Double>) -> some View {
        SliderRow(label: label, value: v, range: 0...5, step: 0.25, readout: Readout.seconds)
    }
}

/// The selected music, and once the clip is split, silencing the piece of it that was clicked.
private struct MusicDetail: View {
    @Bindable var model: EditorModel
    let piece: Int?

    var body: some View {
        if let audio = model.edits.audio {
            // Not `Binding($model.edits.audio)`: the header's delete clears it while these controls are still on screen.
            Section {
                MusicControls(music: Binding(get: { model.edits.audio ?? audio }, set: { if model.edits.audio != nil { model.edits.audio = $0 } }))
            } footer: {
                Text("Drag the music on the timeline to move it, or drag its ends to trim it.")
            }
            if let piece, model.edits.keptSegments.indices.contains(piece) {
                SilenceSection(model: model, source: .music, piece: model.edits.keptSegments[piece])
            }
        }
    }
}

/// Mutes one piece of a sound between splits, or brings it back.
private struct SilenceSection: View {
    let model: EditorModel
    let source: SoundSource
    let piece: Trim

    var body: some View {
        Section {
            Toggle("Silence this part", isOn: Binding(get: { model.edits.isSilenced(source, piece) }, set: { _ in model.edits.toggleSilence(source, piece) }))
        } footer: {
            Text("Only between the splits around where you clicked. ⌫ does the same.")
        }
    }
}

// MARK: - Clip pieces and chapters

/// A piece of the recording between splits: its speed, or cutting it.
private struct PieceDetail: View {
    let model: EditorModel
    let piece: Int

    var body: some View {
        let parts = model.edits.keptSegments
        Section {
            // The clip's own start and end, exactly: the trim handles on the timeline (and I and O) do the same.
            if piece == 0 {
                LabeledContent("Start") {
                    SecondsField(value: Binding(get: { model.edits.trim.start }, set: { t in
                        model.edits.trim.start = round2(min(max(0, t), parts[piece].end - 0.1))
                    }))
                }
            }
            if piece == parts.count - 1 {
                LabeledContent("End") {
                    SecondsField(value: Binding(get: { model.edits.trim.end }, set: { t in
                        model.edits.trim.end = round2(max(min(model.duration, t), parts[piece].start + 0.1))
                    }))
                }
            }
            SpeedPicker(model: model, piece: piece)
            if parts.count > 1 { Button("Cut This Part", role: .destructive) { model.removePart(TimelinePart(lane: .clip, segment: piece)) } }
        } footer: {
            Text("Everything over this part plays at its speed. Split (S) at the playhead to make more parts.")
        }
    }
}

/// An inserted clip, from the piece of it that was clicked: its sound, speed and where it plays.
private struct InsertedClipDetail: View {
    let model: EditorModel
    let clip: Int
    let piece: Int

    var body: some View {
        let clips = model.edits.allClips, segments = model.edits.keptSegments
        if clips.indices.contains(clip), segments.indices.contains(piece) {
            Section {
                PercentSlider(label: "Sound", value: Binding(get: { clips[clip].volume }, set: { model.setClipVolume(clip, $0 ?? 1) }), fallback: 1)
                SpeedPicker(model: model, piece: piece)
            }
            SilenceSection(model: model, source: .clip, piece: segments[piece])
            Section {
                HStack {
                    // Then select it again where it went, so its properties stay open.
                    Button("Move to the Start") { model.moveClip(clip, to: model.edits.trim.start); model.selectPart(.clip, at: model.edits.trim.start) }
                        .disabled(clips[clip].at <= model.edits.trim.start + 1e-6)
                    Button("Move to the End") { model.moveClip(clip, to: model.edits.trim.end); model.selectPart(.clip, at: model.edits.trim.end) }
                        .disabled(clips[clip].end >= model.edits.trim.end - 1e-6)
                }
                if model.clipIsOnePiece(clip) { Button("Delete Clip", role: .destructive) { model.removeClip(clip) } }
            } footer: {
                Text("Or drag it on the timeline to another split.")
            }
        }
    }
}

/// A chapter's name and time.
private struct ChapterDetail: View {
    @Bindable var model: EditorModel
    let index: Int

    var body: some View {
        if model.edits.allMarkers.indices.contains(index) {
            let m = model.edits.allMarkers[index]
            Section {
                TextField("Name", text: Binding(get: { model.edits.allMarkers.indices.contains(index) ? model.edits.allMarkers[index].name : m.name }, set: { n in
                    if model.edits.allMarkers.indices.contains(index) { model.edits.allMarkers[index].name = String(n.prefix(Marker.maxName)) }
                }), prompt: Text("Chapter name"))
                LabeledContent("At") {
                    // Found by value, not index: a new time re-sorts the list, and the field, still holding that time,
                    // must not then move whichever chapter took this one's place.
                    SecondsField(value: Binding(get: { m.t }, set: { t in
                        if let i = model.edits.allMarkers.firstIndex(of: m), t != m.t { model.selectedMarker = model.edits.moveMarker(i, to: t) }
                    }))
                }
                Button("Delete Chapter", role: .destructive) { model.removeMarker(index) }
            } footer: {
                Text("Shown in players and listed in the summary. Drag its flag on the timeline to move it.")
            }
        }
    }
}

// MARK: - Annotations

extension Annotation.Kind {
    var name: String { ["arrow": "Arrow", "rectangle": "Rectangle", "ellipse": "Ellipse", "image": "Image", "blur": "Blur", "video": "Video"][rawValue]! }
    var symbol: String {
        ["arrow": "arrow.up.right", "rectangle": "rectangle", "ellipse": "circle", "image": "photo", "blur": "eye.slash", "video": "play.rectangle"][rawValue]!
    }
}

extension Annotation {
    /// What it's called on the timeline and in the list: a pixelated blur box says so.
    var name: String { kind == .blur && pixelate == true ? "Pixelate" : kind.name }
    var symbol: String { kind == .blur && pixelate == true ? "squareshape.split.3x3" : kind.symbol }
}

/// A selected annotation's timing and look.
private struct AnnotationDetail: View {
    @Bindable var model: EditorModel
    let index: Int

    var body: some View {
        if model.edits.allAnnotations.indices.contains(index) { section($model.edits.allAnnotations[index]) }
    }

    private func section(_ a: Binding<Annotation>) -> some View {
        let kind = a.wrappedValue.kind
        return Section {
            LabeledContent("From") { SecondsField(value: a.start) }
            LabeledContent("To") { SecondsField(value: a.end) }
            if kind == .blur {
                Picker("Style", selection: Binding(get: { a.wrappedValue.pixelate == true }, set: { a.wrappedValue.pixelate = $0 ? true : nil })) {
                    Text("Blur").tag(false)
                    Text("Pixelate").tag(true)
                }
                .pickerStyle(.segmented)
                PercentSlider(label: "Strength", value: a.strength, fallback: Annotation.defaultStrength)
            }
            if kind == .video {
                let video = { (k: WritableKeyPath<OverlayVideo, Double?>) in
                    Binding<Double?>(get: { a.wrappedValue.video?[keyPath: k] }, set: { a.wrappedValue.video?[keyPath: k] = $0 })
                }
                PercentSlider(label: "Sound", value: video(\.volume), fallback: 0)
                PercentSlider(label: "Corners", value: video(\.roundness), fallback: OverlayVideo.defaultRoundness)
                PercentSlider(label: "Shadow", value: video(\.shadow), fallback: DropShadow.defaultStrength)
            }
            if kind != .image, kind != .blur, kind != .video {
                ColorPicker("Colour", selection: hexBinding(a.color), supportsOpacity: false)
                SliderRow(label: "Line", value: a.stroke, range: Annotation.strokes, readout: Readout.finePercent)
                    .help("Line width, as a share of the video's shorter side")
            }
            if kind != .arrow, kind != .blur, kind != .video {
                SliderRow(label: "Rotation", value: a.rotation, range: -180...180, step: 5, readout: Readout.degrees)
            }
            SliderRow(label: "Fade", value: Binding(get: { a.wrappedValue.fade ?? 0 }, set: { a.wrappedValue.fade = $0 < 0.05 ? nil : $0 }),
                      range: 0...1, step: 0.1, readout: Readout.seconds)
        }
    }
}

/// A colour well for a #rrggbb string.
private func hexBinding(_ value: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(cgColor: hexColor(value.wrappedValue)) }, set: { c in
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        value.wrappedValue = String(format: "#%02x%02x%02x", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    })
}

/// Noise reduction and loudness for the microphone. Both work on a copy, made once per setting.
private struct MicCleanup: View {
    @Bindable var model: EditorModel

    var body: some View {
        Picker("Reduce noise", selection: setting(\.noise)) {
            ForEach(RecordCore.MicCleanup.Noise.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Learns the steady background noise, like a fan or hum, from the quiet moments between words and turns it down. The original recording isn't changed.")
        Toggle("Normalize loudness", isOn: setting(\.normalize))
            .help("Evens the microphone out to -16 LUFS, the usual level for the web")
        if model.cleaningMic {
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Cleaning up the microphone…").foregroundStyle(.secondary)
            }
        }
    }

    /// One setting of the clean-up, which is stored only while something is turned on.
    private func setting<V>(_ key: WritableKeyPath<RecordCore.MicCleanup, V>) -> Binding<V> {
        Binding(get: { (model.edits.micCleanup ?? RecordCore.MicCleanup())[keyPath: key] }, set: {
            var c = model.edits.micCleanup ?? RecordCore.MicCleanup()
            c[keyPath: key] = $0
            model.edits.micCleanup = c.isOn ? c : nil
        })
    }
}

/// A percentage slider for an optional setting, where nil means `fallback`.
private struct PercentSlider: View {
    let label: String
    @Binding var value: Double?
    let fallback: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        SliderRow(label: label, value: Binding(get: { value ?? fallback }, set: { value = $0 }), range: range)
    }
}

/// Label, track and value. The label sits in one column of the same width on every slider in the inspector, and the
/// value in a fixed column wide enough for the widest readout ("-180°", "0.25 s"), so every track starts and ends at
/// the same x on every tab, and takes all the room between them.
private struct SliderRow: View {
    static let labelWidth = 92.0 // "Blur strength", the longest slider label, at the default text size

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var readout: (Double) -> String = Readout.percent

    var body: some View {
        HStack(spacing: Space.s) {
            Text(label).lineLimit(1).frame(width: Self.labelWidth, alignment: .leading)
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .labelsHidden() // in a form a slider keeps room for its own label, drawing the track in what's left
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label)
            Text(readout(value)).monospacedDigit().lineLimit(1).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Webcam

private struct WebcamPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let style = Binding($model.edits.camera) {
            Section {
                Toggle("Show webcam", isOn: style.visible).toggleStyle(.switch)
                Group {
                    SliderRow(label: "Size", value: style.size, range: CameraStyle.sizes)
                    LabeledContent("Position") { CornerPicker(style: style) }
                    MoreOptions(SettingsGroup.webcam.rawValue) {
                        PercentSlider(label: "Roundness", value: style.roundness, fallback: style.wrappedValue.effectiveRoundness)
                            .help("0% is a square, 100% a circle")
                        PercentSlider(label: "Margin", value: style.margin, fallback: CameraStyle.defaultMargin, range: CameraStyle.margins)
                            .disabled(style.wrappedValue.center != nil)
                            .help("Gap between the bubble and the edge of the frame, for the corner positions")
                        PercentSlider(label: "Shadow", value: style.shadow, fallback: DropShadow.defaultStrength)
                        Toggle("Mirror", isOn: style.mirror)
                        Toggle("Shrink while zoomed in", isOn: style.shrinkWhenZoomed)
                    }
                }
                .disabled(!style.wrappedValue.visible)
            } header: {
                GroupHeader(title: "Webcam", model: model, group: .webcam)
            } footer: {
                Text("Recorded separately from the screen, so you can restyle or hide it at any time.")
            }
            Section {
                Text(style.wrappedValue.center == nil
                     ? "Drag the bubble on the preview to place it anywhere."
                     : "Placed by dragging. Pick a corner to snap it back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Four corner buttons laid out like the frame. None is highlighted while the bubble has been dragged somewhere else.
private struct CornerPicker: View {
    @Binding var style: CameraStyle
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow { cell(.topLeft, "arrow.up.left"); cell(.topRight, "arrow.up.right") }
            GridRow { cell(.bottomLeft, "arrow.down.left"); cell(.bottomRight, "arrow.down.right") }
        }
    }
    private func cell(_ c: CameraStyle.Corner, _ symbol: String) -> some View {
        Button { style.corner = c; style.center = nil } label: {
            Image(systemName: symbol).frame(width: 28, height: 20)
        }
        .buttonStyle(.bordered)
        .tint(style.center == nil && style.corner == c ? .graphite : nil)
        .accessibilityLabel(c.rawValue)
    }
}

// MARK: - Crop

private struct CropPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section {
            HStack {
                Button(model.cropping ? "Cropping…" : "Crop…") { model.cropping = true }.disabled(model.cropping)
                if model.edits.crop != .full { Button("Reset Crop") { model.edits.crop = .full } }
            }
        } header: {
            Text("Crop")
        } footer: {
            Text(model.cropping ? "Drag across the frame to choose what stays visible. Done or Esc finishes."
                                : "Or use Crop above the timeline, or Clip › Crop… in the menu bar.")
        }
    }
}

// MARK: - Text callouts

/// A selected callout's text, timing and place.
private struct CalloutDetail: View {
    @Bindable var model: EditorModel
    let index: Int

    var body: some View {
        if model.edits.callouts.indices.contains(index) { section(index) }
    }

    private func section(_ i: Int) -> some View {
        Section {
            // Typing stops at the limit, and the count shows as it gets close. Cut in onChange rather than in the
            // binding: a field being edited only shows the cut text when it's set as a change of its own.
            // Wraps onto more lines as it grows, left-aligned like the caption line, so a long callout reads in full.
            TextField("Text", text: $model.edits.callouts[i].text, prompt: Text("Callout text"), axis: .vertical)
                .lineLimit(1...4)
                .labelsHidden()
                .onChange(of: model.edits.callouts[i].text) { _, text in
                    if text.count > Callout.maxText, model.edits.callouts.indices.contains(i) { model.edits.callouts[i].text = Callout.limited(text) }
                }
            let text = model.edits.callouts[i].text, count = text.count
            // Empty text blocks the export too, so say so here rather than only there.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add text, or delete this callout.").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if count > Callout.maxText - 20 {
                Text("\(count) of \(Callout.maxText) characters").font(.caption).monospacedDigit()
                    .foregroundStyle(count >= Callout.maxText ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            LabeledContent("From") { SecondsField(value: $model.edits.callouts[i].start) }
            LabeledContent("To") { SecondsField(value: $model.edits.callouts[i].end) }
        } footer: {
            Text("Drag it on the preview to move it, or nudge it with the arrow keys.")
        }
    }

}
