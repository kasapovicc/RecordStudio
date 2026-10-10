import RecordCore
import SwiftUI

/// Finds long pauses in the microphone and cuts them or speeds them up in one step. While it's open the timeline marks
/// what it would take out, and every change to the settings shows there at once.
struct PausesButton: View {
    @Bindable var model: EditorModel
    /// False for a copy that's only measured, so two buttons never open the same panel.
    var presents = true

    var body: some View {
        Button { model.showPauses.toggle() } label: { Label("Remove Pauses…", systemImage: "waveform.badge.minus") }
            .help("Find long pauses in your speech and cut or speed them up")
            .popover(isPresented: presents ? $model.showPauses : .constant(false), arrowEdge: .top) { PausesPanel(model: model) { model.showPauses = false } }
    }
}

private struct PausesPanel: View {
    let model: EditorModel
    let done: () -> Void
    @AppStorage("pauseMinimum") private var minimum = 1.5
    @AppStorage("pausePadding") private var padding = 0.25
    @AppStorage("pauseSpeedUp") private var speedUp = false

    private var options: PauseOptions { PauseOptions(minimum: minimum, padding: padding, speedUp: speedUp) }

    var body: some View {
        let pauses = model.pauses(options)
        let total = pauses.reduce(0) { $0 + $1.end - $1.start }
        let saved = speedUp ? total * (1 - 1 / PauseOptions.speed) : total
        let before = outputDuration(model.edits.timeMap)

        VStack(alignment: .leading, spacing: Space.l) {
            summary(count: pauses.count, before: before, after: before - saved)

            if !pauses.isEmpty { list(pauses) }

            // No speech to tighten around: no setting would find a pause, so only the explanation shows.
            if model.voice?.isEmpty != true { settings(pauses.count) }
        }
        .padding(Space.l)
        .frame(width: 340)
        .onChange(of: options, initial: true) { model.pausePanel = options }
        .onDisappear { model.pausePanel = nil }
    }

    @ViewBuilder private func settings(_ count: Int) -> some View {
        Picker("", selection: $speedUp) {
            Text("Cut").tag(false)
            Text("Speed up \(speedLabel(PauseOptions.speed))").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.m) {
            row("Longer than", value: $minimum, in: PauseOptions.minimums, step: 0.25)
            row("Keep near speech", value: $padding, in: PauseOptions.paddings, step: 0.05)
        }

        HStack {
            Text("Undo puts them all back.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle(count)) {
                model.removePauses(options)
                done()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(count == 0)
        }
    }

    /// The headline: how many pauses, and the video's length before and after, so the effect reads before it's applied.
    @ViewBuilder private func summary(count: Int, before: Double, after: Double) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if model.voice == nil {
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Listening for pauses…").font(.headline)
                }
                Text("Measuring when you’re speaking.").font(.callout).foregroundStyle(.secondary)
            } else if count == 0 {
                Text("No long pauses").font(.headline)
                Text(model.voice?.isEmpty == true ? "There’s no speech in the microphone to tighten around."
                     : "Nothing quiet for longer than \(seconds(minimum)). Try a shorter length, or keep less near speech.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("^[\(count) pause](inflect: true)")
                    .font(.headline)
                    .contentTransition(.numericText(value: Double(count)))
                Text("\(timecode(before)) → \(Text(timecode(after)).foregroundStyle(.primary))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: after))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading) // the same height in every state, so the panel doesn't jump
        .motion(Motion.hover, value: count) // short: the numbers follow a slider
        .motion(Motion.hover, value: after)
    }

    /// Where each pause is in the video and how long it lasts, in two columns; scrolls past a few.
    private func list(_ pauses: [Trim]) -> some View {
        let map = model.edits.timeMap
        return ScrollView {
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
                GridRow {
                    Text("At")
                    Text("Length").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(pauses.enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(timecode(sourceToOutput(map, p.start)))
                        Text(seconds(p.end - p.start))
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 96) // off-scale: about five rows
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step).controlSize(.small)
            Text(seconds(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func actionTitle(_ n: Int) -> LocalizedStringKey {
        if n == 0 { return speedUp ? "Speed Up Pauses" : "Cut Pauses" }
        return speedUp ? "Speed Up ^[\(n) Pause](inflect: true)" : "Cut ^[\(n) Pause](inflect: true)"
    }

    private func seconds(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) + " s" }
}

/// On the timeline while the pauses panel is open: each pause it would take out, over the clip and the sources under it.
struct PausePreview: View {
    let pauses: [Trim]
    let speedUp: Bool
    let x: (Double) -> CGFloat
    let height: CGFloat

    var body: some View {
        let tint = speedUp ? Color.speedClip : Color(red: 1, green: 0.42, blue: 0.4)
        ZStack(alignment: .topLeading) {
            ForEach(Array(pauses.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(tint.opacity(0.28))
                    .strokeBorder(tint.opacity(0.9), lineWidth: 1)
                    .overlay {
                        Image(systemName: speedUp ? "forward.fill" : "scissors")
                            .font(.caption2.weight(.bold)).foregroundStyle(tint)
                            .opacity(x(p.end) - x(p.start) > 18 ? 1 : 0) // only where it fits
                    }
                    .frame(width: max(2, x(p.end) - x(p.start)), height: height)
                    .offset(x: x(p.start))
            }
        }
        .allowsHitTesting(false)
    }
}
