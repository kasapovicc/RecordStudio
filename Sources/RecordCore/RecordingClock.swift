import Foundation

/// Recording time for a recording that can be paused: seconds since it started on the host clock
/// (`CACurrentMediaTime`), less the time spent paused. The cursor, the shortcuts and system audio are all timed by it,
/// so they line up with the screen, whose paused parts are never written.
public struct RecordingClock: Equatable, Sendable {
    public struct Pause: Equatable, Sendable {
        public var start: Double
        /// When recording carried on. Nil while still paused.
        public var end: Double?
    }

    /// Host time of the first recorded frame. Nil until then.
    public private(set) var start: Double?
    public private(set) var pauses: [Pause] = []

    public init() {}

    public var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    public mutating func begin(at t: Double) { start = t }

    /// Ignored while already paused.
    public mutating func pause(at t: Double) {
        guard !isPaused else { return }
        pauses.append(Pause(start: t))
    }

    /// Ignored unless paused. A resume time before the pause counts as an instant pause.
    public mutating func resume(at t: Double) {
        guard isPaused else { return }
        pauses[pauses.count - 1].end = max(t, pauses[pauses.count - 1].start)
    }

    /// Whether host time `t` falls in a pause, when nothing is recorded.
    public func isPaused(at t: Double) -> Bool {
        pauses.contains { t >= $0.start && t < ($0.end ?? .infinity) }
    }

    /// Seconds spent paused before host time `t`.
    public func pausedTime(before t: Double) -> Double {
        pauses.reduce(0) { sum, p in sum + max(0, min(t, p.end ?? t) - p.start) }
    }

    /// The recording time at host time `t`, or nil before the start and while paused (nothing recorded then).
    public func time(at t: Double) -> Double? {
        guard let start, t >= start, !isPaused(at: t) else { return nil }
        return t - start - pausedTime(before: t)
    }

    /// What the HUD shows: recording time at `t`, standing still while paused. 0 before the start.
    public func elapsed(at t: Double) -> Double {
        guard let start, t >= start else { return 0 }
        return max(0, t - start - pausedTime(before: t))
    }
}

/// Where the recording pill goes until it's dragged somewhere: under the recorded area (`avoid`), else above it, else
/// in a bottom corner of the display clear of it. Without an area to avoid (a whole-display recording), the bottom-left
/// corner, away from the camera bubble on the right. Rects share AppKit's space, with y going up.
public func pillOrigin(size: CGSize, visible: CGRect, avoid: CGRect?, margin: Double = 16) -> CGPoint {
    let left = visible.minX + margin, right = visible.maxX - size.width - margin, bottom = visible.minY + margin
    let corners = [CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
    guard let r = avoid else { return corners[0] }
    let x = min(max(r.midX - size.width / 2, left), right)
    if r.minY - margin - size.height >= bottom { return CGPoint(x: x, y: r.minY - margin - size.height) }
    if r.maxY + margin + size.height <= visible.maxY - margin { return CGPoint(x: x, y: r.maxY + margin) }
    return corners.first { !CGRect(origin: $0, size: size).intersects(r) } ?? corners[0]
}
