import Foundation

/// A one-time tip in the editor, shown the first time what it's about is on screen.
public enum Tip: String, CaseIterable, Sendable {
    case zoom, split, captions
}

/// A step on the editor's Next steps card, ticked off the first time it's done.
public enum NextStep: String, CaseIterable, Sendable {
    case watch, trim, zooms, text, export
}

/// What the editor has taught so far: tips seen, steps done, and how many times the editor has opened. Kept in
/// UserDefaults; Help › Reset Tips starts it over.
public struct Teaching: Equatable, Sendable {
    public var seen: Set<Tip> = []
    public var done: Set<NextStep> = []
    public var tipsOff = false
    public var cardDismissed = false
    public var opens = 0

    /// The card shows for the first few recordings opened, until it's dismissed or every step is done.
    public static let cardOpens = 3

    public init() {}

    public var showsCard: Bool { !tipsOff && !cardDismissed && opens <= Self.cardOpens && done.count < NextStep.allCases.count }

    /// The first unseen tip of those relevant now, in the order given. None while `busy` (playing, cropping…): never
    /// more than one, and never in the way of work.
    public func tip(relevant: [Tip], busy: Bool) -> Tip? {
        guard !tipsOff, !busy else { return nil }
        return relevant.first { !seen.contains($0) }
    }

    /// For UserDefaults.
    public var stored: [String: Any] {
        ["seen": seen.map(\.rawValue).sorted(), "done": done.map(\.rawValue).sorted(), "tipsOff": tipsOff, "cardDismissed": cardDismissed, "opens": opens]
    }

    /// Reads what `stored` wrote; anything missing or unreadable starts fresh.
    public init(stored: [String: Any]) {
        seen = Set((stored["seen"] as? [String] ?? []).compactMap(Tip.init))
        done = Set((stored["done"] as? [String] ?? []).compactMap(NextStep.init))
        tipsOff = stored["tipsOff"] as? Bool ?? false
        cardDismissed = stored["cardDismissed"] as? Bool ?? false
        opens = stored["opens"] as? Int ?? 0
    }

    /// Help › Reset Tips: tips are back on, and every tip and the card show again.
    public mutating func reset() { self = Teaching() }
}
