import AppKit
import Observation
import QuartzCore
import RecordCore
import RecordKit
import SwiftUI
import UniformTypeIdentifiers

/// Speaker notes and the teleprompter that scrolls them while recording. The panel shows from when the record bar
/// opens (so it can be placed near the camera) until the recording stops. It's one of this app's windows, so it never
/// shows in a recording.
@MainActor @Observable
final class Teleprompter {
    static let shared = Teleprompter()
    private static let seededKey = "notesSeeded", onKey = "teleprompter", paceKey = "prompterPace", sizeKey = "prompterTextSize", frameName = "Teleprompter"
    static let textSizes = 18.0...56.0

    var notes: String {
        didSet {
            guard notes != oldValue else { return }
            try? SpeakerNotes.save(notes)
            clock.length = Double(wordCount(notes))
            update()
        }
    }
    var showsWhileRecording: Bool {
        didSet { UserDefaults.standard.set(showsWhileRecording, forKey: Self.onKey); update() }
    }
    var textSize: Double {
        didSet { UserDefaults.standard.set(textSize, forKey: Self.sizeKey) }
    }
    var pace: PrompterPace {
        get { clock.pace }
        set { clock.setPace(newValue, at: CACurrentMediaTime()); UserDefaults.standard.set(newValue.rawValue, forKey: Self.paceKey) }
    }
    private(set) var clock: PrompterClock
    /// Words in a line at the panel's current width and text size, as the panel measures them, for nudging by lines.
    @ObservationIgnored var wordsPerLine = 8.0
    /// From the record bar opening until the recording ends.
    @ObservationIgnored private var active = false
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var moved: (any NSObjectProtocol)?
    /// Waiting for the pointer to let go of a dragged panel, to see where it lands.
    @ObservationIgnored private var settling: Task<Void, Never>?

    var isShowing: Bool { panel != nil }

    private init() {
        let d = UserDefaults.standard
        var saved = SpeakerNotes.load()
        // The first time, a sample script to try the teleprompter with; once cleared it stays cleared.
        if !d.bool(forKey: Self.seededKey) {
            d.set(true, forKey: Self.seededKey)
            if saved.isEmpty {
                saved = SpeakerNotes.sample
                try? SpeakerNotes.save(saved)
            }
        }
        notes = saved
        showsWhileRecording = d.object(forKey: Self.onKey) as? Bool ?? true
        textSize = d.object(forKey: Self.sizeKey) as? Double ?? 30
        clock = PrompterClock(pace: d.string(forKey: Self.paceKey).flatMap(PrompterPace.init) ?? .standard)
        clock.length = Double(wordCount(notes))
    }

    // MARK: Recording flow (see `Studio`)

    /// The record bar opened: show the notes from the top, standing still.
    func begin() {
        active = true
        clock = PrompterClock(pace: clock.pace, length: Double(wordCount(notes)))
        update()
    }

    func recordingStarted() { clock.start(at: CACurrentMediaTime()) }
    func recordingPaused(_ paused: Bool) { clock.pauseForRecording(paused, at: CACurrentMediaTime()) }

    /// The bar was closed or the recording ended.
    func end() {
        active = false
        update()
    }

    // MARK: Controls

    func toggleHold() {
        guard clock.started else { return }
        clock.hold(!clock.held, at: CACurrentMediaTime())
    }

    /// Moves back (negative) or forward by lines of the notes as they're shown.
    func nudge(lines: Double) { clock.nudge(by: (lines * wordsPerLine).rounded(), at: CACurrentMediaTime()) }

    func openFile() {
        let open = NSOpenPanel()
        open.allowedContentTypes = SpeakerNotes.extensions.compactMap { UTType(filenameExtension: $0) }
        open.message = "Choose a text or Markdown file to use as your notes."
        guard open.runModal() == .OK, let url = open.url else { return }
        do { notes = try String(contentsOf: url, encoding: .utf8) } catch { Studio.shared.error = Problem("Couldn’t read “\(url.lastPathComponent)”", error.localizedDescription) }
    }

    // MARK: Panel

    private func update() {
        let wanted = active && showsWhileRecording && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wanted, panel == nil {
            let p = FloatingPanel(size: CGSize(width: 560, height: 210), level: .statusBar, resizable: true) { TeleprompterView() }
            p.contentMinSize = CGSize(width: 320, height: 130)
            // Where it was last left, kept on a connected screen; otherwise at the top of the screen with the menu
            // bar, under the camera. Named first, since naming it restores the saved frame as-is.
            p.setFrameAutosaveName(Self.frameName)
            let saved = p.setFrameUsingName(Self.frameName) ? p.frame : nil
            let fallback = prompterHome(size: p.frame.size, screen: NSScreen.screens.first?.visibleFrame ?? .zero)
            p.setFrame(prompterFrame(saved: saved, screens: NSScreen.screens.map(\.visibleFrame), fallback: fallback), display: false)
            p.orderFrontRegardless()
            moved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelMoved() }
            }
            panel = p
        } else if !wanted, let p = panel {
            moved.map(NotificationCenter.default.removeObserver)
            settling?.cancel()
            p.close()
            panel = nil
        }
    }

    /// Dragging stays 1:1 with the pointer. Let go near the top centre of its screen, under the camera, it settles there.
    private func panelMoved() {
        guard settling == nil else { return }
        settling = Task {
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(50)) }
            defer { settling = nil }
            guard !Task.isCancelled, let p = panel, let screen = p.screen?.visibleFrame,
                  let home = prompterSnap(p.frame, screen: screen) else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                p.setFrame(home, display: true)
            } else {
                NSAnimationContext.animate(Motion.settle) { p.setFrame(home, display: true) }
            }
        }
    }
}

/// The notes scrolling past a reading line. Drag it anywhere, resize it from its edges; the controls float over its
/// bottom edge on hover and before recording starts.
private struct TeleprompterView: View {
    private let model = Teleprompter.shared
    @State private var textHeight = 1.0
    @State private var hovering = false

    var body: some View {
        scroller
            .overlay(alignment: .bottom) {
                PrompterControls(model: model).padding(.bottom, Space.s)
                    .opacity(hovering || !model.clock.started ? 1 : 0)
                    .motion(Motion.hover, value: hovering)
            }
            // Translucent, but blurred enough that what's behind never competes with the notes. Solid with Reduce Transparency.
            .background(.scrim(0.6), in: .rect(cornerRadius: Radius.large))
            .background(.ultraThickMaterial, in: .rect(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(.white.opacity(0.12)))
            .onHover { hovering = $0 }
            .environment(\.colorScheme, .dark)
    }

    private var scroller: some View {
        GeometryReader { geo in
            let lineHeight = model.textSize * 1.4, readingY = (geo.size.height * 0.32).rounded()
            // A comfortable measure: about 60 characters at most, centred.
            let column = min(geo.size.width - 2 * Space.xl, model.textSize * 30)
            // Display-synced and linear: constant motion at the chosen pace, standing still when it isn't running.
            TimelineView(.animation(paused: !model.clock.isRunning)) { _ in
                let words = model.clock.position(at: CACurrentMediaTime())
                let perWord = textHeight / max(1, model.clock.length)
                notes(width: column, lineHeight: lineHeight)
                    .offset(x: ((geo.size.width - column) / 2).rounded(), y: readingY - lineHeight / 2 - words * perWord)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .mask(ReadingMask(height: geo.size.height, readingY: readingY, lineHeight: lineHeight))
        }
    }

    private func notes(width: Double, lineHeight: Double) -> some View {
        let text = prompterText(model.notes)
        let markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(markdown ?? AttributedString(text))
            .font(.system(size: model.textSize, weight: .semibold))
            .lineSpacing(lineHeight - model.textSize * 1.2)
            .foregroundStyle(.white)
            .frame(width: max(40, width), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { h in
                textHeight = max(1, h)
                model.wordsPerLine = max(1, model.clock.length / max(1, h / lineHeight))
            }
    }
}

/// The line being read at full strength, the lines before and after it dimmed, and both edges fading out rather than
/// cut off. It marks the reading line by brightness alone, with no bar over the text.
private struct ReadingMask: View {
    let height: Double, readingY: Double, lineHeight: Double
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dim = Color.black.opacity(contrast == .increased ? 0.75 : 0.55), faint = Color.black.opacity(0.15)
        // The bottom fade is deeper, so the text has gone quiet by the time it passes behind the controls.
        let top = min(Space.xl, height * 0.12), bottom = min(lineHeight * 2, height * 0.35), half = lineHeight / 2, soft = lineHeight * 0.6
        // In order down the panel; clamped so they never run backwards when the panel is short.
        let ys = [0, top, readingY - half - soft, readingY - half, readingY + half, readingY + half + soft, height - bottom, height - bottom / 2, height - Space.s, height]
        let colors = [Color.clear, dim, dim, .black, .black, dim, dim, faint, .clear, .clear]
        var last = 0.0
        let stops = zip(colors, ys).map { c, y in
            last = max(last, min(height, y))
            return Gradient.Stop(color: c, location: last / max(1, height))
        }
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// Hold, back and forward, pace and text size, in a small capsule over the panel's bottom edge.
private struct PrompterControls: View {
    @Bindable var model: Teleprompter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xxs) {
            button("chevron.up", help: "Back a few lines", key: .prompterBack) { model.nudge(lines: -2) }
            // Clicked, the symbol swaps with a short replace; from the keyboard shortcut it changes at once.
            button(model.clock.held ? "play.fill" : "pause.fill", help: model.clock.started ? (model.clock.held ? "Carry on scrolling" : "Hold here") : "Starts scrolling when recording starts",
                   key: .prompterHold) { withAnimation(Motion.press.respecting(reduceMotion)) { model.toggleHold() } }
                .disabled(!model.clock.started)
            button("chevron.down", help: "Forward a few lines", key: .prompterForward) { model.nudge(lines: 2) }
            Divider().frame(height: 16).padding(.horizontal, Space.xs)
            Picker("Pace", selection: $model.pace) {
                ForEach(PrompterPace.allCases, id: \.self) { Text("\($0.label) · \(Int($0.wordsPerMinute)) wpm").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Scrolling pace")
            Divider().frame(height: 16).padding(.horizontal, Space.xs)
            button("textformat.size.smaller", help: "Smaller text") { model.textSize = max(Teleprompter.textSizes.lowerBound, model.textSize - 4) }
                .disabled(model.textSize <= Teleprompter.textSizes.lowerBound)
            button("textformat.size.larger", help: "Larger text") { model.textSize = min(Teleprompter.textSizes.upperBound, model.textSize + 4) }
                .disabled(model.textSize >= Teleprompter.textSizes.upperBound)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ symbol: String, help: String, key: ShortcutAction? = nil, _ action: @escaping () -> Void) -> some View {
        let shortcut = key.flatMap { ShortcutStore.shared.map[$0] }.map { " (\($0.symbol))" } ?? ""
        return Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 26).contentShape(.rect)
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white.opacity(0.9))
        .help(help + shortcut)
    }
}

/// Writing the notes, from the record bar: type or paste, or open a text or Markdown file. Kept between recordings.
struct NotesEditor: View {
    @Bindable var model = Teleprompter.shared
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let words = wordCount(model.notes)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Speaker Notes").font(.headline)
                TextEditor(text: $model.notes)
                    .font(.body)
                    .lineSpacing(Space.xs)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: Radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.faint(0.1)))
                    .overlay(alignment: .topLeading) {
                        if model.notes.isEmpty {
                            Text("Type or paste what you want to say. It scrolls past a reading line while you record.")
                                .foregroundStyle(.tertiary).padding(.horizontal, Space.m + Space.xxs).padding(.vertical, Space.s).allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 260)
                Picker("Pace", selection: $model.pace) {
                    ForEach(PrompterPace.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Show the teleprompter while recording", isOn: $model.showsWhileRecording)
            }
            .padding(Space.l)
            Divider()
            HStack(spacing: Space.s) {
                Button("Open…") { model.openFile() }
                    .help("Use a text or Markdown file as your notes")
                // Clearing deletes the notes file, so a script longer than a few lines is only cleared once confirmed.
                Button("Clear") { if words > 25 { confirmClear = true } else { model.notes = "" } }
                    .disabled(model.notes.isEmpty)
                Spacer()
                if words > 0 {
                    let minutes = Double(words) / model.pace.wordsPerMinute
                    Text("\(words) words · about \(minutes < 1 ? "\(Int((minutes * 60).rounded())) s" : "\(Int(minutes.rounded())) min")")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .help("At the \(model.pace.label.lowercased()) pace, \(Int(model.pace.wordsPerMinute)) words a minute")
                }
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
        .frame(width: 460)
        .confirmationDialog("Clear your speaker notes?", isPresented: $confirmClear) {
            Button("Clear Notes", role: .destructive) { model.notes = "" }
        } message: {
            Text("All \(words) words are deleted. This can’t be undone.")
        }
    }
}
