import AppKit
import RecordCore
import RecordKit
import SwiftUI

/// Every export choice, made at the moment of exporting: format, size, file name and folder, extra files, beside the
/// export's poster frame with its length and size. Once it starts, the settings make way and the poster grows to the
/// middle, showing the progress and then the result, in a sheet that keeps its size. Closing it while exporting leaves
/// the export running; the toolbar button shows it.
struct ExportSheet: View {
    @Bindable var model: EditorModel
    @State private var replacing = false
    @State private var poster: CGImage?
    @Namespace private var posterSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private enum Phase { case choosing, working, done, failed }
    private var phase: Phase {
        switch model.export {
        case .idle: .choosing
        case .working: .working
        case .done: .done
        case .failed: .failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Export “\(model.title)”").font(.headline).lineLimit(1).opacity(phase == .choosing ? 1 : 0)
            ZStack {
                // Still laid out once the export starts, so the sheet keeps its size while the progress takes its place.
                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        // When the export starts, the poster grows from here to the middle.
                        if phase == .choosing {
                            posterFrame(width: 240, height: 200).matchedGeometryEffect(id: "poster", in: posterSpace)
                        } else {
                            Color.clear.frame(width: posterWidth(240, 200), height: posterWidth(240, 200) / shape)
                        }
                        Text(model.exportEstimate).foregroundStyle(.secondary).monospacedDigit()
                            .contentTransition(.numericText())
                            .motion(Motion.hover, value: model.exportEstimate)
                    }
                    .frame(width: 240)
                    choices.disabled(phase != .choosing).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .opacity(phase == .choosing ? 1 : 0)
                .accessibilityHidden(phase != .choosing)
                if phase != .choosing { progress }
            }
            if phase == .choosing { problems }
            buttons
        }
        .padding(Space.l)
        .frame(width: 760)
        .motion(Motion.enter, value: phase)
        .task { poster = await model.exportPoster(maxSize: 480) }
        .confirmationDialog("“\(model.exportURL.lastPathComponent)” already exists in \(folderName(model.exportURL.deletingLastPathComponent())).",
                            isPresented: $replacing) {
            Button("Replace", role: .destructive) { model.runExport() }
            Button("Keep Both") {
                model.exportName = keepBothName(exportFileName(model.exportName)) {
                    FileManager.default.fileExists(atPath: model.exportPlace(named: $0).path)
                }
                model.runExport()
            }
        }
    }

    // MARK: The poster and what's under it

    /// The exported frame's shape, with the poster in it: dimmed with a bar along its bottom while exporting, and a
    /// checkmark drawn in once it's done.
    private func posterFrame(width maxWidth: Double, height maxHeight: Double) -> some View {
        // A fixed size from the output's shape, so the text under it never squeezes it.
        let width = posterWidth(maxWidth, maxHeight)
        return ZStack {
            Rectangle().fill(.faint(0.06))
            if let poster { Image(decorative: poster, scale: 1).resizable().scaledToFit() }
            if phase == .working { Rectangle().fill(.scrim(0.5)) }
        }
        .frame(width: width, height: width / shape)
        .overlay(alignment: .bottom) { if phase == .working { progressBar } }
        .clipShape(.rect(cornerRadius: Radius.small))
        .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.faint(0.12), lineWidth: 1) }
    }

    /// The output's width ÷ height.
    private var shape: Double { Double(model.size.width) / Double(max(1, model.size.height)) }
    /// The poster's width in a `maxWidth` × `maxHeight` box, at the output's shape.
    private func posterWidth(_ maxWidth: Double, _ maxHeight: Double) -> Double { min(maxWidth, maxHeight * shape) }

    /// The export's progress, along the poster's bottom edge.
    private var progressBar: some View {
        let p: Double? = if case .working(_, let p) = model.export { p } else { nil }
        return GeometryReader { geo in
            Rectangle().fill(.white).frame(width: geo.size.width * (p ?? 0))
        }
        .frame(height: Space.xs)
        .background(.scrim(0.4))
    }

    /// The export once it's started, in the middle: the poster, dimmed with a bar along its bottom while it renders,
    /// then bright again with a checkmark drawn in; under it how it's going, what was saved where, or why it failed.
    private var progress: some View {
        VStack(spacing: Space.m) {
            // The poster grows here from the settings' side; with Reduce Motion it just fades in.
            posterFrame(width: 400, height: 220)
                .matchedGeometryEffect(id: reduceMotion ? "centre" : "poster", in: posterSpace)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .overlay(alignment: .bottomTrailing) { if phase == .done { doneBadge.offset(x: Space.s, y: Space.s) } }
            VStack(spacing: Space.xs) { caption }
                .multilineTextAlignment(.center)
                .id(phase) // each step's words cross-fade
                .transition(.opacity.animation(Motion.follow)) // just after the poster
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var caption: some View {
        switch model.export {
        case .idle: EmptyView()
        case .working(let stage, let p):
            Text("Exporting").font(.title2.weight(.semibold))
            Text(p.map { "\(stage)… \(Int(($0 * 100).rounded()))%" } ?? "\(stage)…").foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
            Text("You can close this; the export carries on.").font(.callout).foregroundStyle(.quiet)
        case .done(let video, _, let transcriptError):
            let url = URL(fileURLWithPath: video)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            let facts = [formatTime(outputDuration(model.edits.timeMap)), bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                         "in \(folderName(url.deletingLastPathComponent()))"].compactMap { $0 }
            Text("Exported").font(.title2.weight(.semibold))
            Text(url.lastPathComponent).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Text(facts.joined(separator: " · ")).foregroundStyle(.secondary).monospacedDigit()
            if let transcriptError { Text("No transcript: \(transcriptError)").font(.callout).foregroundStyle(.secondary) }
        case .failed(let message):
            Text("Export failed").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The checkmark that draws itself in on the result's corner, in graphite rather than a new colour.
    private var doneBadge: some View {
        Image(systemName: "checkmark").font(.title2.weight(.semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .transition(.symbolEffect(.drawOn))
            .frame(width: 44, height: 44)
            .background(.graphite, in: .circle)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .accessibilityLabel("Exported")
    }

    // MARK: Choosing

    private let textWidth = 360.0

    private var choices: some View {
        let o = $model.exportSettings, format = model.exportSettings.format
        return Form {
            Picker("Format", selection: o.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            // The form takes its widest row's width, and a text grows with its words, so the description and the name
            // get a set width; otherwise a long one pushes the sheet's content past its edges.
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(format.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let blocker = model.formatBlocker { Label(blocker, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .font(.callout)
            .frame(width: textWidth, alignment: .leading)

            // Popups left over from the other appearance come up blank, so they're made anew when it changes.
            Group {
                if format == .gif {
                    Picker("Width", selection: o.gif.width) {
                        ForEach(GIFOptions.widths, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Frame rate", selection: o.gif.fps) {
                        ForEach(GIFOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Toggle("Loop", isOn: o.gif.loops)
                } else {
                    Picker("Size", selection: o.resolution) {
                        ForEach(ExportResolution.allCases, id: \.self) { r in
                            let s = model.exportSize(r)
                            Text("\(r.label) — \(Readout.size(s.width, s.height))").tag(r)
                        }
                    }
                    .help("The video is never made larger than the recording.")
                    Picker("Quality", selection: o.quality) {
                        ForEach(ExportQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            .id(colorScheme)

            LabeledContent("Name") {
                HStack(spacing: Space.xs) {
                    TextField("Name", text: $model.exportName, prompt: Text(model.title)).labelsHidden()
                    Text(".\(format.fileExtension)").foregroundStyle(.secondary)
                }
                .frame(width: textWidth)
            }
            LabeledContent("Where") { FolderMenu(folder: o.folder) }

            LabeledContent("Also save") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    extra("Subtitles (.srt)", .subtitles, help: "Needs captions, with subtitles turned on in the Captions tab.")
                    extra("Transcript (.txt)", .transcript, help: "GIFs have no sound.")
                    extra("Poster image (.jpg)", .poster)
                    extra("Summary (.md)", .summary, help: "A Markdown page with the length, moments, chapters and transcript.")
                }
            }
        }
        .formStyle(.columns)
    }

    @ViewBuilder private var problems: some View {
        if !model.problems.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(model.problems, id: \.self) { problem in
                    HStack(alignment: .firstTextBaseline) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Show") { model.reveal(problem) }.controlSize(.small)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func extra(_ label: String, _ kind: ExportExtras, help: String? = nil) -> some View {
        let off = !model.availableExtras.contains(kind)
        return Toggle(label, isOn: Binding(get: { !off && model.exportSettings.extras.contains(kind) },
                                    set: { if $0 { model.exportSettings.extras.insert(kind) } else { model.exportSettings.extras.remove(kind) } }))
            .disabled(off)
            .help(help ?? "")
    }

    private func export() {
        if model.exportName.trimmingCharacters(in: .whitespaces).isEmpty { model.exportName = model.title }
        if FileManager.default.fileExists(atPath: model.exportURL.path) { replacing = true } else { model.runExport() }
    }

    // MARK: Buttons

    /// The sheet's buttons for each step. The trailing pair keeps its place: the main action is always where Export was.
    @ViewBuilder private var buttons: some View {
        HStack {
            switch model.export {
            case .idle:
                Spacer()
                Button("Cancel") { model.showExport = false }.keyboardShortcut(.cancelAction)
                // Return only exports when it can, so a blocked Export isn't drawn as the sheet's main button.
                let blocked = !model.problems.isEmpty || model.formatBlocker != nil
                Button("Export") { export() }
                    .keyboardShortcut(blocked ? nil : .defaultAction)
                    .disabled(blocked)
            case .working:
                Spacer()
                Button("Stop Export") { model.cancelExport() }
                Button("Close") { model.showExport = false }.keyboardShortcut(.cancelAction)
            case .done(let video, let place, _):
                let url = URL(fileURLWithPath: video)
                Button("Copy") { copyFile(url) }.help("Copy the video to paste into Slack, Mail, Finder…")
                ShareLink("Share…", item: url)
                Spacer()
                Button("Done") { model.export = .idle; model.showExport = false }.keyboardShortcut(.cancelAction)
                Button("Show in Finder") { Studio.shared.reveal(place) }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Change Settings") { model.export = .idle }
                Spacer()
                Button("Close") { model.export = .idle; model.showExport = false }.keyboardShortcut(.cancelAction)
                Button("Try Again") { model.export = .idle; export() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The export folder: the library's Exports folder, Desktop, Downloads, the one last used, or any other.
private struct FolderMenu: View {
    @Binding var folder: String

    var body: some View {
        let current = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        let places = [Paths.exports] + [.desktopDirectory, .downloadsDirectory].compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        Menu {
            // Compared by path: the same folder can come as URLs that aren't equal (a trailing slash, say).
            ForEach(([current] + places).reduce(into: [URL]()) { list, url in
                if !list.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { list.append(url) }
            }, id: \.self) { url in
                Button(folderName(url)) { folder = url.path }
            }
            Divider()
            Button("Other…") { choose() }
        } label: {
            Label(folderName(current), systemImage: "folder")
        }
        .fixedSize()
        .help(folder)
    }


    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

/// A folder as the sheet names it: the library's export folder is "Exports", others as Finder shows them.
private func folderName(_ url: URL) -> String {
    url.standardizedFileURL == Paths.exports.standardizedFileURL ? "Exports" : FileManager.default.displayName(atPath: url.path)
}
