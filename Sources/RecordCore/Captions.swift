import Foundation

/// One recognised word, at recording times.
public struct CaptionWord: Equatable, Sendable {
    public var text: String
    public var start, end: Double
    public init(_ text: String, start: Double, end: Double) { (self.text, self.start, self.end) = (text, start, end) }
}

/// One line of captions, shown from `start` to `end` in recording time, so it follows cuts and speed changes.
public struct CaptionLine: Codable, Equatable, Sendable, Timed {
    public var text: String
    public var start, end: Double
    public init(_ text: String, start: Double, end: Double) { (self.text, self.start, self.end) = (text, start, end) }
}

/// Subtitles burned into the video, made from the recording's speech. Hiding them keeps the lines for later.
public struct Captions: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable { case bottom, top }
    public enum Style: String, Codable, CaseIterable, Sendable { case box, outline }
    public static let sizes = 0.5...2.0
    /// A line's length in characters, as subtitle guidelines have it.
    public static let maxChars = 42
    /// A pause this long (seconds) starts a new line, and a line is shown for at least `minDuration`.
    public static let maxGap = 0.8, minDuration = 1.0
    /// Font size as a fraction of the frame's shorter side, at size 1.
    public static let font = 0.05

    public var visible = true
    public var position = Position.bottom
    public var size = 1.0
    public var style = Style.box
    public var srt = true // also save the lines as a subtitles file next to the export
    public var lines: [CaptionLine]
    public init(lines: [CaptionLine]) { self.lines = lines }

    /// The line showing at recording time t, if any.
    public func line(at t: Double) -> CaptionLine? { lines.last { t >= $0.start && t < $0.end } }

    /// Splits line i at recording time t, sharing its words by time. False when t isn't well inside it or it's one word.
    @discardableResult
    public mutating func split(_ i: Int, at t: Double) -> Bool {
        guard lines.indices.contains(i) else { return false }
        let l = lines[i], words = l.text.split(separator: " ")
        guard words.count > 1, t > l.start + 0.05, t < l.end - 0.05 else { return false }
        let k = min(words.count - 1, max(1, Int((Double(words.count) * (t - l.start) / (l.end - l.start)).rounded())))
        lines[i] = CaptionLine(words[..<k].joined(separator: " "), start: l.start, end: t)
        lines.insert(CaptionLine(words[k...].joined(separator: " "), start: t, end: l.end), at: i + 1)
        return true
    }

    /// Moves line i to start at `start`, keeping its length and staying between its neighbours.
    public mutating func move(_ i: Int, to start: Double) {
        guard lines.indices.contains(i) else { return }
        let len = lines[i].end - lines[i].start
        let lo = i > 0 ? lines[i - 1].end : 0, hi = i + 1 < lines.count ? lines[i + 1].start - len : .infinity
        let s = (min(max(lo, start), max(lo, hi)) * 100).rounded() / 100
        (lines[i].start, lines[i].end) = (s, s + len)
    }

    /// Moves one edge of line i to t, staying between its neighbours and at least 0.2 s long.
    public mutating func trim(_ i: Int, start: Bool, to t: Double) {
        guard lines.indices.contains(i) else { return }
        let l = lines[i], r = { (v: Double) in (v * 100).rounded() / 100 }
        if start { lines[i].start = r(min(max(i > 0 ? lines[i - 1].end : 0, t), l.end - 0.2)) }
        else { lines[i].end = r(max(min(i + 1 < lines.count ? lines[i + 1].start : .infinity, t), l.start + 0.2)) }
    }
}

/// Words grouped into caption lines: a new line after a sentence ends, at a pause of `maxGap`, or before the line
/// would pass `maxChars`. Each line stays up until the next one when they're close, so captions don't blink off
/// between phrases, and for at least `Captions.minDuration`.
public func captionLines(_ words: [CaptionWord], maxChars: Int = Captions.maxChars, maxGap: Double = Captions.maxGap) -> [CaptionLine] {
    var lines: [CaptionLine] = [], current: [CaptionWord] = []
    func flush() {
        if let a = current.first, let b = current.last { lines.append(CaptionLine(current.map(\.text).joined(separator: " "), start: a.start, end: b.end)) }
        current = []
    }
    for var w in words {
        w.text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.text.isEmpty else { continue }
        if let last = current.last {
            let length = current.reduce(0) { $0 + $1.text.count + 1 } + w.text.count
            if w.start - last.end >= maxGap || length > maxChars || ".?!".contains(last.text.last!) { flush() }
        }
        current.append(w)
    }
    flush()
    for i in lines.indices {
        let next = i + 1 < lines.count ? lines[i + 1].start : .infinity
        if next - lines[i].end < maxGap { lines[i].end = next }
        lines[i].end = max(lines[i].end, min(next, lines[i].start + Captions.minDuration))
    }
    return lines
}

/// The lines as an SRT subtitles file for the exported video: at output times, leaving out lines that are wholly cut.
public func srt(_ lines: [CaptionLine], _ map: [Trim]) -> String {
    func stamp(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    let timed = lines.map { (a: sourceToOutput(map, $0.start), b: sourceToOutput(map, $0.end), text: $0.text) }
        .filter { $0.b - $0.a >= 0.05 && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    return timed.enumerated().map { i, l in "\(i + 1)\n\(stamp(l.a)) --> \(stamp(l.b))\n\(l.text)\n" }.joined(separator: "\n")
}
