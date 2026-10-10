import Foundation

/// A video made elsewhere played between parts of the recording: an intro, an outro, a phone shot in the middle. Its
/// file is a copy in the recording's folder.
///
/// Everything in the edits is timed on the *timeline*: the recording with its inserted clips spliced in. A clip takes
/// `length` seconds of timeline from `at`, so what comes after it plays later. The recording's own sources (screen,
/// cursor, camera, microphone, system audio, shortcuts) keep recording time, and `recordingTime` / `timelineTime`
/// convert. With no clips the two are the same, so edits made before clips existed mean what they always did.
public struct InsertedClip: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var at: Double
    /// The whole file. What plays of it is decided by the kept segments over it, like any piece of the recording.
    public var length: Double
    /// Its frame, upright, for fitting it inside the recording's frame.
    public var width: Int, height: Int
    public var volume: Double?          // its own sound, 0–1; nil = full

    public init(path: String, name: String, at: Double = 0, length: Double, width: Int, height: Int, volume: Double? = nil) {
        (self.path, self.name, self.at, self.length, self.width, self.height, self.volume) = (path, name, at, length, width, height, volume)
    }

    public var end: Double { at + length }
}

extension Trim: Timed {}
extension SilencedRange: Timed {}

extension Edits {
    /// The inserted clips in timeline order, for editing. Stored as nil when there are none.
    public var allClips: [InsertedClip] {
        get { (clips ?? []).sorted { $0.at < $1.at } }
        set { clips = newValue.isEmpty ? nil : newValue.sorted { $0.at < $1.at } }
    }

    /// The clip playing at timeline time t, if any.
    public func clipIndex(at t: Double) -> Int? { allClips.firstIndex { t >= $0.at && t < $0.end } }

    /// Recording time at timeline time t; nil inside an inserted clip, where the recording isn't playing.
    public func recordingTime(_ t: Double) -> Double? {
        var shift = 0.0
        for c in allClips {
            if t < c.at { break }
            if t < c.end { return nil }
            shift += c.length
        }
        return t - shift
    }

    /// Timeline time at which recording time r plays. Where a clip was inserted, that's after the clip.
    public func timelineTime(_ r: Double) -> Double {
        var t = r
        for c in allClips where c.at <= t + 1e-9 { t += c.length }
        return t
    }

    /// The timeline's length for a recording `recording` seconds long.
    public func timelineDuration(_ recording: Double) -> Double { recording + allClips.reduce(0) { $0 + $1.length } }

    /// See `recordingRuns(_:duration:)`.
    public func recordingRuns(duration: Double) -> [(start: Double, end: Double, shift: Double)] { RecordCore.recordingRuns(allClips, duration: duration) }

    /// Ranges in recording time (like when you're speaking) moved onto the timeline.
    public func timelineRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] { RecordCore.timelineRanges(allClips, ranges) }

    /// Cursor samples moved onto the timeline. Over an inserted clip the cursor stays where it was, so nothing that
    /// follows it (the camera, zooms) drifts while the clip plays.
    public func timelineCursor(_ cursor: [CursorSample]) -> [CursorSample] {
        guard clips != nil else { return cursor }
        var out = cursor.map { s -> CursorSample in var s = s; s.t = timelineTime(s.t); return s }
        for c in allClips {
            guard let last = out.last(where: { $0.t <= c.at }) else { continue }
            var hold = last
            (hold.t, hold.image) = (c.end, nil)
            out.append(hold)
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Shortcut presses moved onto the timeline.
    public func timelineKeys(_ keys: [ShortcutPress]) -> [ShortcutPress] {
        guard clips != nil else { return keys }
        return keys.map { var k = $0; k.t = timelineTime(k.t); return k }
    }

    /// Where a clip dropped at timeline time t goes in: within the trim, never inside another clip (it goes before or
    /// after, whichever is nearer), and onto a split or clip edge within `snap` seconds.
    public func insertionPoint(near t: Double, snap: Double = 0) -> Double {
        var p = min(max(t, trim.start), trim.end)
        if let c = allClips.first(where: { p > $0.at && p < $0.end }) { p = p - c.at < c.end - p ? c.at : c.end }
        let edges = keptSegments.flatMap { [$0.start, $0.end] } + allClips.flatMap { [$0.at, $0.end] }
        if let near = edges.min(by: { abs($0 - p) < abs($1 - p) }), abs(near - p) <= snap { p = near }
        return p
    }

    /// Puts `clip` into the timeline at t (see `insertionPoint`): everything from t on moves later by its length, and
    /// whatever spans t is split there. It plays whole, at normal speed.
    public mutating func insertClip(_ clip: InsertedClip, at t: Double) {
        var c = clip
        c.at = 0
        insert(Span(length: clip.length, segments: [Trim(start: 0, end: clip.length)], clips: [c]), at: insertionPoint(near: t))
    }

    /// Takes clip i out of the timeline with everything inside it; what came after moves back. The last thing that
    /// plays can't be removed.
    public mutating func removeClip(_ i: Int) {
        let all = allClips
        guard all.indices.contains(i) else { return }
        let c = all[i]
        guard keptSegments.contains(where: { $0.end <= c.at + 1e-6 || $0.start >= c.end - 1e-6 }) else { return }
        _ = cut(c.at, c.end)
    }

    /// Moves clip i, with its pieces, speeds and everything over it, to timeline time t as the timeline is now (see
    /// `insertionPoint`). Moving it onto itself changes nothing.
    public mutating func moveClip(_ i: Int, to t: Double) {
        let all = allClips
        guard all.indices.contains(i) else { return }
        let c = all[i]
        let p = insertionPoint(near: t)
        guard p < c.at - 1e-6 || p > c.end + 1e-6 else { return }
        let span = cut(c.at, c.end)
        insert(span, at: p > c.end ? p - c.length : p)
    }

    // MARK: Spans

    /// A stretch of timeline lifted out, with everything inside it timed from its start.
    struct Span {
        var length: Double
        var segments: [Trim] = []
        var zooms: [Zoom] = [], callouts: [Callout] = [], annotations: [Annotation] = [], speeds: [SpeedRegion] = []
        var silenced: [SilencedRange] = [], lines: [CaptionLine] = [], markers: [Marker] = [], clips: [InsertedClip] = []
    }

    /// Opens a gap at t for `span` and puts it there: everything from t on moves later by its length, and whatever
    /// spans t is split there.
    mutating func insert(_ s: Span, at t: Double) {
        let l = s.length
        func widen<T: Timed>(_ items: [T], _ carried: [T], split: (T, Double) -> (T, T)) -> [T] {
            items.flatMap { it -> [T] in
                if it.end <= t { return [it] }
                if it.start >= t { return [moved(it, l)] }
                let (a, b) = split(it, t)
                return [a, moved(b, l)]
            } + carried.map { moved($0, t) }
        }
        keptSegments = widen(keptSegments, s.segments, split: splitAt).filter { $0.end - $0.start > 1e-6 }.sorted { $0.start < $1.start }
        zooms = widen(zooms, s.zooms, split: splitAt).sorted { $0.start < $1.start }
        callouts = widen(callouts, s.callouts, split: splitAt)
        allAnnotations = widen(allAnnotations, s.annotations, split: splitAt)
        allSpeeds = widen(allSpeeds, s.speeds, split: splitAt)
        let silenced = widen(self.silenced ?? [], s.silenced, split: splitAt)
        self.silenced = silenced.isEmpty ? nil : silenced
        if let lines = captions?.lines { captions?.lines = widen(lines, s.lines, split: splitLine).filter { !$0.text.isEmpty }.sorted { $0.start < $1.start } }
        allMarkers = allMarkers.map { var m = $0; if m.t >= t { m.t += l }; return m } + s.markers.map { var m = $0; m.t += t; return m }
        if let a = audio, a.at >= t { audio?.at = a.at + l }
        allClips = allClips.map { var c = $0; if c.at >= t - 1e-9 { c.at += l }; return c } + s.clips.map { var c = $0; c.at += t; return c }
    }

    /// Lifts timeline a..<b out of everything and closes the gap: what's inside is returned, timed from a, and what's
    /// after moves back. Something that spans the whole stretch stays as one piece, shorter by its length.
    mutating func cut(_ a: Double, _ b: Double) -> Span {
        let l = b - a
        var s = Span(length: l)
        func lift<T: Timed>(_ items: [T], _ carried: inout [T]) -> [T] {
            var out: [T] = []
            for it in items {
                if it.end <= a + 1e-9 { out.append(it); continue }
                if it.start >= b - 1e-9 { out.append(moved(it, -l)); continue }
                if it.start < a, it.end > b { var x = it; x.end -= l; out.append(x) } else {
                    if it.start < a { var x = it; x.end = a; out.append(x) }
                    if it.end > b { var x = it; x.start = b; out.append(moved(x, -l)) }
                }
                var inside = it
                inside.shift(by: -a)
                (inside.start, inside.end) = (max(it.start, a) - a, min(it.end, b) - a)
                if inside.end - inside.start > 0.01 { carried.append(inside) }
            }
            return out.filter { $0.end - $0.start > 0.01 }
        }
        let kept = lift(keptSegments, &s.segments)
        if !kept.isEmpty { keptSegments = kept }
        zooms = lift(zooms, &s.zooms)
        callouts = lift(callouts, &s.callouts)
        allAnnotations = lift(allAnnotations, &s.annotations)
        allSpeeds = lift(allSpeeds, &s.speeds)
        let silenced = lift(self.silenced ?? [], &s.silenced)
        self.silenced = silenced.isEmpty ? nil : silenced
        if let lines = captions?.lines { captions?.lines = lift(lines, &s.lines) }
        var markers: [Marker] = []
        for m in allMarkers {
            if m.t < a { markers.append(m) } else if m.t >= b { var m = m; m.t -= l; markers.append(m) } else { var m = m; m.t -= a; s.markers.append(m) }
        }
        allMarkers = markers
        if let at = audio?.at, at >= a { audio?.at = at >= b ? at - l : a }
        var clips: [InsertedClip] = []
        for c in allClips {
            if c.end <= a + 1e-9 { clips.append(c) } else if c.at >= b - 1e-9 { var c = c; c.at -= l; clips.append(c) } else { var c = c; c.at -= a; s.clips.append(c) }
        }
        allClips = clips
        return s
    }
}

/// Where a clip's w × h frame sits inside the cropped recording's W × H (top-left origin): as large as fits without
/// stretching, centred.
public func clipFit(width w: Double, height h: Double, inside W: Double, _ H: Double) -> (x: Double, y: Double, width: Double, height: Double) {
    guard w > 0, h > 0 else { return (0, 0, W, H) }
    let k = min(W / w, H / h)
    return ((W - w * k) / 2, (H - h * k) / 2, w * k, h * k)
}

/// The recording's stretches between `clips` (in timeline order): recording time `start..<end` plays from timeline time
/// `start + shift`.
public func recordingRuns(_ clips: [InsertedClip], duration: Double) -> [(start: Double, end: Double, shift: Double)] {
    var runs: [(start: Double, end: Double, shift: Double)] = [], r = 0.0, shift = 0.0
    for c in clips {
        let cut = min(duration, c.at - shift) // recording time where this clip goes in
        if cut > r { runs.append((r, cut, shift)) }
        r = max(r, cut)
        shift += c.length
    }
    if duration > r { runs.append((r, duration, shift)) }
    return runs
}

/// Ranges in recording time moved onto the timeline: each split where a clip goes in.
public func timelineRanges(_ clips: [InsertedClip], _ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
    guard !clips.isEmpty else { return ranges }
    let runs = recordingRuns(clips, duration: .infinity)
    return ranges.flatMap { r in
        runs.compactMap { run -> ClosedRange<Double>? in
            let s = max(r.lowerBound, run.start), e = min(r.upperBound, run.end)
            return e > s ? (s + run.shift)...(e + run.shift) : nil
        }
    }
}

private func moved<T: Timed>(_ it: T, _ d: Double) -> T { var x = it; x.shift(by: d); return x }

private func splitAt<T: Timed>(_ it: T, _ t: Double) -> (T, T) {
    var a = it, b = it
    (a.end, b.start) = (t, t)
    return (a, b)
}

/// A caption line split at t shares its words by time, like `Captions.split`; a single word stays on the longer side.
private func splitLine(_ l: CaptionLine, _ t: Double) -> (CaptionLine, CaptionLine) {
    let words = l.text.split(separator: " ")
    let k = min(words.count, max(0, Int((Double(words.count) * (t - l.start) / max(1e-9, l.end - l.start)).rounded())))
    return (CaptionLine(words[..<k].joined(separator: " "), start: l.start, end: t), CaptionLine(words[k...].joined(separator: " "), start: t, end: l.end))
}
