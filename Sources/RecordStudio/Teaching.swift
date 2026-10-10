import Observation
import RecordCore
import RecordKit
import SwiftUI

/// What the editor has taught (see `Teaching`), kept in UserDefaults. The editor ticks steps off and marks tips seen as
/// they're done; Settings turns tips off and Help › Reset Tips starts over.
@MainActor @Observable
final class TipStore {
    static let shared = TipStore()
    private static let key = "teaching"

    var state: Teaching {
        didSet { if state != oldValue { UserDefaults.standard.set(state.stored, forKey: Self.key) } }
    }

    private init() { state = Teaching(stored: UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]) }

    /// A step done, and the tip it makes unnecessary.
    func done(_ step: NextStep, seen tip: Tip? = nil) {
        state.done.insert(step)
        if let tip { state.seen.insert(tip) }
    }

    /// Steps an edit finishes: trimming, and adding text or captions (which also retires the captions tip).
    func noteEdit(from old: Edits, to new: Edits) {
        if new.trim != old.trim { done(.trim) }
        if old.captions == nil, new.captions != nil { done(.text, seen: .captions) }
        if new.callouts.count > old.callouts.count { done(.text) }
    }
}

/// A one-time tip on the timeline, next to what it's about. ✕ dismisses it for good; doing what it says does too.
struct TipBubble: View {
    let tip: Tip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "lightbulb").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(Self.text(tip)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button("Dismiss Tip", systemImage: "xmark") { TipStore.shared.state.seen.insert(tip) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .help("Don’t show this tip again")
        }
        .padding(.leading, Space.m).padding(.trailing, Space.s).padding(.vertical, Space.xs)
        .glassEffect(in: .capsule)
    }

    static func text(_ tip: Tip) -> String {
        let keys = ShortcutStore.shared.map
        switch tip {
        case .zoom:
            return "Zooms come from your clicks. Drag one to move it, or select it to pin it to an area."
        case .split:
            let split = keys[.split].map { "Press \($0.symbol)" } ?? "Click Split"
            return "\(split) to split here, then \(keys[.delete]?.symbol ?? "Delete") to cut a piece."
        case .captions:
            return "Make Captions turns what you said into captions you can edit."
        }
    }
}

/// The first few recordings' checklist, in the preview's corner. Each step ticks itself off when it's done; ✕ hides it.
/// What to press sits at the trailing edge as keycaps, what to do on a quiet line under the step.
struct NextStepsCard: View {
    let hasAudio: Bool

    var body: some View {
        let done = TipStore.shared.state.done
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("Next steps").font(.headline)
                Text("\(done.count) of \(NextStep.allCases.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: Space.l)
                Button("Hide Next Steps", systemImage: "xmark") { TipStore.shared.state.cardDismissed = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                    .help("Hide next steps. Help › Reset Tips brings them back.")
            }
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(NextStep.allCases, id: \.self) { step in
                    let isDone = done.contains(step)
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isDone ? AnyShapeStyle(.graphite) : AnyShapeStyle(.tertiary))
                            .accessibilityLabel(isDone ? "Done" : "To do")
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(title(step)).foregroundStyle(isDone ? .secondary : .primary)
                            if let detail = detail(step) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: Space.l)
                        if let keys = keys(step) { Keycaps(caps: keys.caps) }
                    }
                }
            }
            .font(.callout)
            .motion(Motion.hover, value: done)
        }
        .padding(Space.m)
        .fixedSize()
        .glassEffect(in: .rect(cornerRadius: Radius.large))
    }

    private func title(_ s: NextStep) -> String {
        switch s {
        case .watch: "Watch it back"
        case .trim: "Trim the start"
        case .zooms: "Check the zooms"
        case .text: hasAudio ? "Add a caption or text" : "Add text"
        case .export: "Export"
        }
    }

    private func detail(_ s: NextStep) -> String? {
        switch s {
        case .trim: "Drag the clip’s edge, or set it at the playhead"
        case .zooms: "Click one on the Zooms lane"
        case .text: hasAudio ? "Make Captions, or add text at the playhead" : nil
        default: nil
        }
    }

    /// The keys for the step, as the user has set them.
    private func keys(_ s: NextStep) -> Shortcut? {
        let map = ShortcutStore.shared.map
        return switch s {
        case .watch: map[.play]
        case .trim: map[.setIn]
        case .zooms: nil
        case .text: map[.addText]
        case .export: Shortcut("cmd+e")
        }
    }
}

/// Help › Keyboard Shortcuts (⌘/): every shortcut by where it works, as the user has set them. Esc closes it.
struct ShortcutsOverlay: View {
    static let id = "shortcuts"
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let groups = ShortcutStore.shared.map.overview(tabs: InspectorTab.allCases.map(\.name))
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(group.title).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
                            ForEach(group.items, id: \.label) { item in
                                GridRow {
                                    Text(item.label).frame(maxWidth: .infinity, alignment: .leading)
                                    Keycaps(caps: item.shortcut.caps).gridColumnAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Space.xl)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("Change them in Settings › Shortcuts.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings…") {
                    UserDefaults.standard.set(SettingsTab.shortcuts.rawValue, forKey: SettingsTab.key)
                    openSettings()
                }
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
            .background(.bar)
        }
        .frame(width: 480, height: 600)
        .background { Button("Close") { dismissWindow(id: Self.id) }.keyboardShortcut(.cancelAction).hidden() }
    }
}
