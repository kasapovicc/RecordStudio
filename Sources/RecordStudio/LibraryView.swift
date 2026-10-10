import AVFoundation
import RecordCore
import RecordKit
import SwiftUI

struct LibraryView: View {
    @Environment(Studio.self) private var studio
    @State private var confirmDelete: [Recording] = []
    @State private var dropping = false
    @State private var query = ""
    @AppStorage("librarySort") private var sort = LibrarySort.created
    @AppStorage("libraryAsList") private var asList = false
    /// The selected recordings, and the one the keyboard is on (where ⇧-click and the arrows start from).
    @State private var selection: Set<String> = []
    @State private var selected: String?
    @State private var renaming: String?
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool

    var body: some View {
        Group {
            if studio.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No recordings yet", systemImage: "record.circle")
                } description: {
                    Text("Record your screen, a window or an area, or drop a video here to edit it.")
                } actions: {
                    // On macOS the actions sit in one row; stack them so the primary button comes first and the caption goes below.
                    VStack(spacing: Space.m) {
                        VStack(spacing: Space.s) {
                            Button { studio.newRecording() } label: { NewRecordingLabel().frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                            Button { studio.chooseVideos() } label: { Text("Import a Video…").frame(maxWidth: .infinity) }
                            Button { studio.openSample() } label: { Text("Try the Sample Project").frame(maxWidth: .infinity) }
                                .help("Opens a short recording with edits already made, to explore the editor")
                        }
                        .controlSize(.large).fixedSize() // both buttons as wide as the wider one
                        Text("Files stay on this Mac in \(Paths.data.path)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if asList {
                list
            } else {
                // Re-reads the clock every minute, so Today rolls over at midnight.
                TimelineView(.everyMinute) { ctx in grid(now: ctx.date) }
            }
        }
        // Several recordings whose files are gone: one place to remove them all.
        .safeAreaInset(edge: .top, spacing: 0) {
            let missing = studio.recordings.filter(\.isMissing)
            if missing.count > 1 {
                HStack {
                    Label("The files of \(missing.count) recordings are gone", systemImage: "questionmark.folder")
                    Spacer()
                    Button("Remove \(missing.count) Missing Recordings") { studio.delete(missing) }
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
                .background(.bar)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let projects = urls.filter { $0.pathExtension.lowercased() == Project.fileExtension }
            let videos = urls.filter { Importer.extensions.contains($0.pathExtension.lowercased()) }
            Task {
                for url in projects { await studio.openProject(url) }
                if !videos.isEmpty { await studio.importVideos(videos) }
            }
            return !projects.isEmpty || !videos.isEmpty
        } isTargeted: { dropping = $0 }
        // While something is dragged over the library: a quiet outline saying what dropping does.
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.graphite, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.graphite.opacity(0.06), in: .rect(cornerRadius: Radius.large))
                    .overlay { Label("Drop a video to edit it, or a project to open it", systemImage: "square.and.arrow.down").font(.headline) }
                    .padding(Space.m)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .motion(Motion.hover, value: dropping)
        // Importing and exporting can take a while; say what's happening, out of the way.
        .overlay(alignment: .bottom) {
            VStack(spacing: Space.s) {
                if let name = studio.importing { ProgressCapsule(text: "Importing “\(name)”…").transition(.slide(edge: .bottom)) }
                if let exporting = studio.exporting {
                    ProgressCapsule(text: exporting) { studio.cancelExport() }.transition(.slide(edge: .bottom))
                }
                if let toast = studio.libraryToast { ToastView(toast: toast) { studio.libraryToast = nil } }
            }
            .padding(Space.l)
        }
        .motion(Motion.enter, value: studio.importing == nil)
        .motion(Motion.enter, value: studio.exporting == nil)
        .motion(Motion.enter, value: studio.libraryToast?.text)
        // A toast goes away by itself after a few seconds; a newer one starts the wait again.
        .task(id: studio.libraryToast?.text) {
            guard studio.libraryToast != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { studio.libraryToast = nil }
        }
        .onChange(of: selection, initial: true) { studio.librarySelection = selection }
        .navigationTitle("Recordings")
        .searchable(text: $query, placement: .toolbar, prompt: "Titles and what’s said")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Picker("View", selection: $asList) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(false)
                        Label("List", systemImage: "list.bullet").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort and View", systemImage: asList ? "list.bullet" : "square.grid.2x2") }
                    .help("Sort the recordings, and show them as a grid or a list")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { studio.chooseVideos() } label: { Label("Import Video", systemImage: "video.badge.plus") }
                    .labelStyle(.titleAndIcon)
                    .help("Import a video made elsewhere to edit it (⇧⌘O)")
                    .disabled(studio.importing != nil)
            }
            // Its own group: importing isn't recording.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                // The one prominent button: graphite like Export in the editor, with the red dot as its only colour.
                Button { studio.newRecording() } label: { NewRecordingLabel() }
                    .buttonStyle(.glassProminent)
                    .help("New Recording (⌘N)")
                    .disabled(studio.isRecording)
            }
        }
        .confirmationDialog(confirmDelete.count == 1 ? "Move “\(confirmDelete[0].title)” to the Trash?" : "Move \(confirmDelete.count) recordings to the Trash?",
                            isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { studio.delete(confirmDelete) }
        } message: {
            Text("The raw recordings and their edits go to the Trash; Undo (⌘Z) brings them back. Exported videos stay where they are.")
        }
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The recordings the search finds, in the chosen order.
    private var shown: [Recording] {
        let q = trimmedQuery
        return sort.sorted(q.isEmpty ? studio.recordings : studio.recordings.filter { $0.titleMatches(q) || $0.spokenMatch(q) != nil })
    }

    /// What a menu or key acts on: the selection when `rec` is part of it, otherwise just `rec` (like Finder).
    private func targets(_ rec: Recording) -> [Recording] {
        selection.contains(rec.id) ? shown.filter { selection.contains($0.id) } : [rec]
    }

    private var selectedRecordings: [Recording] { shown.filter { selection.contains($0.id) } }

    private func grid(now: Date) -> some View {
        // Date sections only for the default order; a search or another order is one list.
        let sections: [(title: String?, items: [Recording])] = sort == .created && trimmedQuery.isEmpty
            ? gallerySections(shown, created: { Self.date($0.createdAt) }, edited: { Self.date($0.editedAt) }, now: now, recent: min(5, columns))
                .map { ($0.section.rawValue, $0.items) }
            : [(nil, shown)]
        let order = sections.flatMap(\.items)
        return ScrollViewReader { proxy in
            ScrollView {
                // A grid per section, so the header sits close to its own tiles rather than a whole row gap above them.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections, id: \.title) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Space.l, alignment: .top)], spacing: Space.xl) {
                                ForEach(group.items) { rec in
                                    Tile(rec: rec, selected: selection.contains(rec.id), query: trimmedQuery, renaming: renamingBinding(rec),
                                         open: { open(rec) }, select: { click(rec, order: order) })
                                        .id(rec.id)
                                        .contextMenu { menu(targets(rec)) }
                                        .transition(.asymmetric(insertion: .enterFromTrigger(anchor: .center), removal: .opacity))
                                }
                            }
                            // The gap under the header is the grid's, not the header's, so the header's background stops
                            // short of the tiles: a selected tile's ring (4 pt out, more while lifted on hover) stays whole.
                            .padding(.top, Space.s)
                            .padding(.bottom, Space.xl)
                        } header: {
                            if let title = group.title {
                                // A quiet label, so the tile titles stay the strongest text in the grid. Date sections
                                // say how many they hold.
                                HStack {
                                    Text(title).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if title != GallerySection.recent.rawValue {
                                        Text("^[\(group.items.count) recording](inflect: true)").font(.subheadline).monospacedDigit()
                                    }
                                }
                                .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, Space.m)
                                    .background(.background)
                            } else {
                                Color.clear.frame(height: Space.m)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.xl).padding(.bottom, Space.xl)
                // Imported recordings fade in and deleted ones close their gap; typing a search doesn't animate.
                .motion(Motion.move, value: studio.recordings.map(\.id))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            // The grid takes keyboard focus as a whole: arrows move the selection, ⌘↓ opens it, Return renames it and
            // ⌫ or ⌘⌫ trashes it, as in Finder.
            .focusable().focusEffectDisabled().focused($gridFocused)
            .onAppear { gridFocused = true }
            .onMoveCommand { dir in
                move(dir, order: order, counts: sections.map(\.items.count))
                proxy.scrollTo(selected)
            }
            .modifier(SelectionKeys(selection: selectedRecordings, open: open, rename: { renaming = $0.id }, delete: { confirmDelete = $0 }))
        }
    }

    /// The same recordings as a table, with columns for length, size and when they were exported.
    private var list: some View {
        Table(shown, selection: $selection) {
            TableColumn("Title") { rec in
                TitleField(rec: rec, query: trimmedQuery, renaming: renamingBinding(rec)).lineLimit(1)
            }
            TableColumn("Created") { rec in Text(Self.date(rec.createdAt).formatted(date: .abbreviated, time: .shortened)) }
            TableColumn("Length") { rec in Text(formatTime(rec.duration)).monospacedDigit() }.width(70)
            TableColumn("Size") { rec in Text(rec.diskSize.formatted(.byteCount(style: .file))).monospacedDigit() }.width(80)
            TableColumn("Exported") { rec in
                Text(rec.latestExport.map { Self.date($0.createdAt).formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(rec.latestExport == nil ? .tertiary : .primary)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(shown.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let rec = shown.first(where: { ids.contains($0.id) }) { open(rec) }
        }
        .modifier(SelectionKeys(selection: selectedRecordings, open: open, rename: { renaming = $0.id }, delete: { confirmDelete = $0 }))
    }

    private func renamingBinding(_ rec: Recording) -> Binding<Bool> {
        Binding(get: { renaming == rec.id }, set: { renaming = $0 ? rec.id : nil; if !$0 { gridFocused = true } })
    }

    /// Click selects one; ⌘-click adds or removes one; ⇧-click selects everything from the last one clicked.
    private func click(_ rec: Recording, order: [Recording]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            selection.formSymmetricDifference([rec.id])
        } else if mods.contains(.shift), let a = order.firstIndex(where: { $0.id == selected }), let b = order.firstIndex(of: rec) {
            selection.formUnion(order[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [rec.id]
        }
        if !mods.contains(.shift) { selected = rec.id }
        gridFocused = true
    }

    /// As many columns as the adaptive grid fits: 250 pt tiles, 16 pt apart, 24 pt padding each side.
    private var columns: Int { max(1, Int((gridWidth - 48 + 16) / (250 + 16))) }

    private func move(_ dir: MoveCommandDirection, order: [Recording], counts: [Int]) {
        guard let i = order.firstIndex(where: { $0.id == selected }) else { selected = order.first?.id; selection = Set(selected.map { [$0] } ?? []); return }
        let (dx, dy) = switch dir {
        case .left: (-1, 0)
        case .right: (1, 0)
        case .up: (0, -1)
        case .down: (0, 1)
        @unknown default: (0, 0)
        }
        selected = order[gridMove(i, dx: dx, dy: dy, counts: counts, columns: columns)].id
        selection = [selected!]
    }

    private func open(_ rec: Recording) {
        guard !rec.isMissing else { return }
        selected = rec.id
        selection = [rec.id]
        studio.path = [rec.id]
    }

    @ViewBuilder private func menu(_ recs: [Recording]) -> some View {
        if let rec = recs.first, recs.count == 1 {
            Button("Edit") { open(rec) }.disabled(rec.isMissing)
            Button("Rename") { renaming = rec.id }
            if let latest = rec.latestExport {
                Divider()
                Button("Copy Export") { copyFile(URL(fileURLWithPath: latest.path)) }
                ShareLink("Share Export…", item: URL(fileURLWithPath: latest.path))
                Button("Show Export in Finder") { studio.reveal(latest.path) }
                Button("Copy Export Path") { studio.copyPath(latest.path) }
            }
            Divider()
            Button("Export") { studio.export([rec]) }.disabled(studio.exporting != nil || rec.isMissing)
            Button("Show Original in Finder") { studio.reveal(rec.path) }.disabled(rec.isMissing)
            Button("Show Project in Finder") { studio.revealProject(rec) }
            Divider()
            // Its files are already gone, so there's nothing to move to the Trash.
            if rec.isMissing {
                Button("Remove from Library", role: .destructive) { studio.delete([rec]) }
            } else {
                Button("Move to Trash…", role: .destructive) { confirmDelete = [rec] }
            }
        } else if !recs.isEmpty {
            let found = recs.filter { !$0.isMissing }, missing = recs.filter(\.isMissing)
            Button("Export \(found.count) Recordings") { studio.export(found) }.disabled(studio.exporting != nil || found.isEmpty)
            Button("Show Originals in Finder") { studio.reveal(all: found.map(\.path)) }.disabled(found.isEmpty)
            Divider()
            if !missing.isEmpty {
                Button(missing.count == 1 ? "Remove 1 Missing Recording" : "Remove \(missing.count) Missing Recordings", role: .destructive) { studio.delete(missing) }
            }
            if !found.isEmpty {
                Button("Move \(found.count) Recordings to Trash…", role: .destructive) { confirmDelete = found }
            }
        }
    }
}

/// The library's keys for the selection, in the grid and the list: ⌘↓ opens, Return renames, ⌫ or ⌘⌫ trashes.
private struct SelectionKeys: ViewModifier {
    let selection: [Recording]
    let open: (Recording) -> Void, rename: (Recording) -> Void, delete: ([Recording]) -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.return) {
                guard selection.count == 1 else { return .ignored }
                rename(selection[0])
                return .handled
            }
            .onKeyPress(keys: [.downArrow]) { press in
                guard press.modifiers.contains(.command), let rec = selection.first else { return .ignored }
                open(rec)
                return .handled
            }
            // The delete key sends DEL (or BS), with or without ⌘.
            .onKeyPress(characters: CharacterSet(charactersIn: "\u{7F}\u{8}")) { _ in
                guard !selection.isEmpty else { return .ignored }
                delete(selection)
                return .handled
            }
    }
}

/// A recording's title, with what the search matched highlighted; a field while it's being renamed.
private struct TitleField: View {
    @Environment(Studio.self) private var studio
    let rec: Recording
    let query: String
    @Binding var renaming: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if renaming {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { draft = rec.title; focused = true }
                .onSubmit { studio.rename(rec, to: draft); renaming = false }
                .onExitCommand { renaming = false }
                .onChange(of: focused) { if !focused, renaming { studio.rename(rec, to: draft); renaming = false } }
        } else {
            Text(highlighted(rec.title, query))
        }
    }
}

/// `text` with every place `query` appears marked, as Find does.
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var out = AttributedString(text)
    guard !query.isEmpty else { return out }
    var from = text.startIndex
    while let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
        if let ar = Range(NSRange(r, in: text), in: out) { out[ar].backgroundColor = .yellow.opacity(0.45) }
        from = r.upperBound
    }
    return out
}

private struct Tile: View {
    @Environment(Studio.self) private var studio
    let rec: Recording
    let selected: Bool
    let query: String
    @Binding var renaming: Bool
    let open: () -> Void
    let select: () -> Void
    @State private var thumb: NSImage?
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Click selects, double-click opens, as in Finder; double-clicking the title renames.
        content
            .onTapGesture(count: 2, perform: open)
            .simultaneousGesture(TapGesture().onEnded(select))
            // Sinks from the moment it's pressed, before the click that selects it. Outside the taps, so it doesn't
            // stop a double-click opening it.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([rec.title, Duration.seconds(rec.duration).formatted(.units(width: .wide)),
                                 created.formatted(date: .abbreviated, time: .shortened), rec.isMissing ? "Its files are gone" : nil, rec.exportSummary()].compactMap(\.self).joined(separator: ", "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
            .accessibilityAction(named: "Rename") { renaming = true }
            // A second in, past the black first frame many recordings start with.
            .task(id: "\(rec.path) \(missing)") {
                thumb = missing ? nil : await Thumbnails.image(rec.path, at: min(1, rec.duration / 2), maxSize: 600)
            }
    }

    private var missing: Bool { rec.isMissing }

    private var created: Date { Date(timeIntervalSince1970: Double(rec.createdAt) / 1000) }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            // Fixed 16:10 frame; the thumbnail fills it without changing the tile's size.
            // Files gone: a quiet placeholder rather than a black frame that looks like a recording.
            Rectangle().fill(missing ? AnyShapeStyle(.quinary) : AnyShapeStyle(.black))
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if missing {
                        Image(systemName: "questionmark.folder").font(.largeTitle).foregroundStyle(.secondary)
                    } else if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                }
                .clipShape(.rect(cornerRadius: Radius.medium))
                .overlay(alignment: .bottomTrailing) {
                    Text(formatTime(rec.duration))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                        .background(.scrim(0.8), in: .rect(cornerRadius: Radius.inner(Radius.medium, inset: Space.s)))
                        .foregroundStyle(.white)
                        .padding(Space.s)
                }
            // A thin inner border, so a black frame still reads as a tile.
            .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.faint(hovering ? 0.3 : 0.12), lineWidth: 1))
            // Selected: a graphite ring outside the thumbnail, so it isn't lost against a dark frame.
            // Before the lift, so it grows with the thumbnail instead of being covered by it.
            .overlay {
                RoundedRectangle(cornerRadius: Radius.outer(Radius.medium, inset: Space.xs)).strokeBorder(Color.graphite, lineWidth: 2.5)
                    .padding(-Space.xs)
                    .opacity(selected ? 1 : 0)
            }
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 8, y: 3)
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
            .motion(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            .pressed(pressed)
            .padding(.bottom, Space.xs)

            // Two lines, so takes that start alike still differ; the full title is in the tooltip.
            TitleField(rec: rec, query: query, renaming: $renaming)
                .font(.headline).lineLimit(2).help(rec.title)
                .onTapGesture(count: 2) { renaming = true }
            // A search that found the words in what's said rather than the title shows where.
            if !query.isEmpty, !rec.titleMatches(query), let line = rec.spokenMatch(query) {
                Text(highlighted("“\(line)”", query)).font(.callout).lineLimit(2)
            }
            HStack(spacing: Space.s) {
                // Relative, so a default title ("Recording 6 Oct at 19:59") isn't repeated; the exact time is in the tooltip.
                Text(created.formatted(.relative(presentation: .named)))
                    .help(created.formatted(date: .abbreviated, time: .shortened))
                if !rec.hasAudio, !rec.hasSystemAudio { Text("No audio") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if missing { Text("Its files are gone").font(.subheadline).foregroundStyle(.secondary) }
            if let exported = rec.exportSummary() {
                Text(exported).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}

/// "New Recording" with the red dot: the dot is the only colour, as on the record bar's Record button.
private struct NewRecordingLabel: View {
    var body: some View {
        Label {
            Text("New Recording")
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(.record).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Frame grabs for tiles and the zoom focus map, cached in memory.
enum Thumbnails {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ path: String, at seconds: Double, maxSize: CGFloat) async -> NSImage? {
        let key = "\(path)@\(Int(seconds * 10))@\(Int(maxSize))"
        if let hit = cache[key] { return hit }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        cache[key] = img
        return img
    }
}
