import Foundation
import CoreGraphics

/// How fast the teleprompter scrolls, in spoken words per minute.
public enum PrompterPace: String, CaseIterable, Codable, Sendable {
    case slower, standard, faster

    public var wordsPerMinute: Double {
        switch self { case .slower: 110; case .standard: 140; case .faster: 170 }
    }

    public var label: String {
        switch self { case .slower: "Slower"; case .standard: "Default"; case .faster: "Faster" }
    }
}

/// Where the teleprompter is in the notes, in words read, over time (any clock in seconds, like `CACurrentMediaTime`).
/// It stands still until `start` (when the countdown ends and recording begins), and while it's held from the panel
/// or the recording is paused. Changing the pace or nudging it carries on from where it is.
public struct PrompterClock: Equatable, Sendable {
    public private(set) var pace: PrompterPace
    /// The notes' length in words; the position never goes past it.
    public var length: Double
    /// Held from the panel or a shortcut.
    public private(set) var held = false
    public private(set) var recordingPaused = false
    private var words = 0.0      // the position at `since`
    private var since: Double?   // when the position was last worked out while started; nil before `start`

    public init(pace: PrompterPace = .standard, length: Double = .infinity) {
        self.pace = pace
        self.length = length
    }

    public var started: Bool { since != nil }
    public var isRunning: Bool { since != nil && !held && !recordingPaused }

    /// Words read at time t.
    public func position(at t: Double) -> Double {
        guard isRunning, let since else { return min(words, length) }
        return min(length, words + max(0, t - since) * pace.wordsPerMinute / 60)
    }

    /// Settles the position at t, so what changes next counts from there.
    private mutating func settle(_ t: Double) {
        words = position(at: t)
        if since != nil { since = t }
    }

    public mutating func start(at t: Double) {
        guard since == nil else { return }
        since = t
    }

    public mutating func hold(_ on: Bool, at t: Double) {
        settle(t)
        held = on
    }

    public mutating func pauseForRecording(_ on: Bool, at t: Double) {
        settle(t)
        recordingPaused = on
    }

    public mutating func setPace(_ p: PrompterPace, at t: Double) {
        settle(t)
        pace = p
    }

    /// Moves `by` words back (negative) or forward, within the notes.
    public mutating func nudge(by: Double, at t: Double) {
        settle(t)
        words = min(length, max(0, words + by))
    }
}

/// Notes as the teleprompter shows them: Markdown headings without their #s. Bold and italics are kept for display.
public func prompterText(_ notes: String) -> String { notes.replacing(#/(?m)^[ \t]*\#{1,6}[ \t]+/#, with: "") }

/// The words in some notes, as the teleprompter's pace counts them (heading marks aren't words).
public func wordCount(_ text: String) -> Int { prompterText(text).split(whereSeparator: \.isWhitespace).count }

/// Where to put the teleprompter: its saved frame, kept inside the visible frame of the screen it's mostly on (clear of
/// the menu bar and the Dock), or `fallback` when there's none saved or its screen is gone.
public func prompterFrame(saved: CGRect?, screens: [CGRect], fallback: CGRect) -> CGRect {
    guard let saved, let screen = screens.max(by: { area($0.intersection(saved)) < area($1.intersection(saved)) }),
          area(screen.intersection(saved)) > 0 else { return fallback }
    let w = min(saved.width, screen.width), h = min(saved.height, screen.height)
    return CGRect(x: min(max(saved.minX, screen.minX), screen.maxX - w), y: min(max(saved.minY, screen.minY), screen.maxY - h), width: w, height: h)
}

/// The teleprompter's home: centred at the top of a screen's visible frame, just under the menu bar and the camera.
public func prompterHome(size: CGSize, screen: CGRect) -> CGRect {
    CGRect(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - size.height - 12, width: size.width, height: size.height)
}

/// Where a teleprompter let go at `frame` settles: home, when it's within `reach` points of it and not there already.
public func prompterSnap(_ frame: CGRect, screen: CGRect, reach: Double = 48) -> CGRect? {
    let home = prompterHome(size: frame.size, screen: screen)
    let dx = abs(frame.minX - home.minX), dy = abs(frame.minY - home.minY)
    return dx <= reach && dy <= reach && dx + dy > 0 ? home : nil
}

private func area(_ r: CGRect) -> Double { r.isNull ? 0 : r.width * r.height }
