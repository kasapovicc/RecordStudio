// Pure edit -> render logic. Foundation only, so it is fast to test and shared by preview and export.
// JSON shapes match the Tauri version, so libraries recorded with it open unchanged.
import Foundation

/// Normalized rectangle (0...1), top-left origin, relative to the recorded frame.
public struct NRect: Codable, Equatable, Sendable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }
    public static let full = NRect(x: 0, y: 0, w: 1, h: 1)
}

/// Cursor position normalized to the recorded frame; `t` is seconds of video time.
/// `image` indexes the recording's cursor images, set only on samples where the cursor's shape changes.
public struct CursorSample: Codable, Equatable, Sendable {
    public var t, x, y: Double
    public var down: Bool
    public var image: Int?
    public init(t: Double, x: Double, y: Double, down: Bool, image: Int? = nil) {
        (self.t, self.x, self.y, self.down, self.image) = (t, x, y, down, image)
    }
}

/// One cursor shape (arrow, I-beam, hand…) as captured, in source pixels; the hotspot is from the top-left.
public struct CursorImage: Codable, Equatable, Sendable {
    public var png: Data
    public var hotX, hotY: Double
    public init(png: Data, hotX: Double, hotY: Double) { (self.png, self.hotX, self.hotY) = (png, hotX, hotY) }
}

/// What happens at each click: an expanding ring that fades, or the drawn cursor briefly shrinking and back.
public enum ClickEffect: String, Codable, CaseIterable, Sendable {
    case ripple, bounce
    public static let duration = 0.3
    /// Size of the drawn cursor `k` (0…1) into a bounce: dips to 75% halfway and comes back.
    public static func bounceScale(_ k: Double) -> Double { 1 - 0.25 * sin(.pi * k) }
}

/// How the redrawn cursor looks. Only used for recordings that have cursor images.
public struct CursorStyle: Codable, Equatable, Sendable {
    public var visible = true
    public var size = 1.0       // times the cursor's own size
    public var smoothing = 0.5  // 0 = follows the mouse exactly, 1 = most smoothing
    public var motionBlur: Double? // blur along fast moves, 0–1; nil = off
    public init() {}
    /// Below this speed, in output pixels per frame, the cursor stays sharp.
    public static let blurThreshold = 3.0
    /// Motion blur radius in output pixels for a cursor moving `speed` output pixels per frame; 0 = sharp.
    /// At full strength the blur spans about half a frame's travel, like a 180° shutter.
    public static func blurRadius(speed: Double, strength: Double) -> Double {
        speed < blurThreshold ? 0 : min(60, speed * strength / 4)
    }
    public static let sizes = 0.5...3.0
    /// Per-stage time constant (s) of the smoothing filter.
    public var follow: Double { smoothing * 0.15 }
}

public struct Point: Codable, Equatable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { (self.x, self.y) = (x, y) }
}

/// `focus` pins the camera to a point (crop-normalized centre); without it the camera follows the cursor.
/// Which zoom, callout or annotation this is, so the timeline can follow it while the list is sorted, added to and
/// deleted from. It's not saved (each opening gives fresh ones) and it isn't part of what an item is: two items with the
/// same settings are equal whatever their ids, so it never counts as an edit.
public struct ItemID: Codable, Equatable, Sendable {
    public let uuid: UUID
    public init() { uuid = UUID() }
    public init(from decoder: Decoder) throws { uuid = UUID() }
    public func encode(to encoder: Encoder) throws {}
    public static func == (_: ItemID, _: ItemID) -> Bool { true }
}

extension KeyedDecodingContainer {
    /// Edits are saved without ids, so every item gets a new one when they're read.
    public func decode(_: ItemID.Type, forKey _: Key) throws -> ItemID { ItemID() }
}

extension KeyedEncodingContainer {
    /// Leaves the id out of saved edits.
    public mutating func encode(_: ItemID, forKey _: Key) throws {}
}

public struct Zoom: Codable, Equatable, Sendable {
    public var start, end, scale: Double
    public var focus: Point?
    public var id = ItemID()
    public init(start: Double, end: Double, scale: Double, focus: Point? = nil) {
        (self.start, self.end, self.scale, self.focus) = (start, end, scale, focus)
    }
}

/// Text callout; x/y is the top-left corner, normalized to the output canvas.
public struct Callout: Codable, Equatable, Sendable {
    /// The longest text a callout takes; typing stops there.
    public static let maxText = 120
    /// Text as typed, cut at `maxText`.
    public static func limited(_ text: String) -> String { String(text.prefix(maxText)) }
    public var text: String
    public var start, end, x, y: Double
    public var id = ItemID()
    public init(text: String, start: Double, end: Double, x: Double, y: Double) {
        (self.text, self.start, self.end, self.x, self.y) = (text, start, end, x, y)
    }
}

public struct Trim: Codable, Equatable, Sendable {
    public var start, end: Double
    public var speed: Double?           // playback speed, in a `timeMap` piece; nil = 1×
    public init(start: Double, end: Double, speed: Double? = nil) { (self.start, self.end, self.speed) = (start, end, speed) }
}

/// A stretch of recording time played faster or slower.
public struct SpeedRegion: Codable, Equatable, Sendable {
    public static let speeds = [0.5, 1.5, 2, 4, 8]
    /// Above this the sound is muted rather than stretched.
    public static let maxAudible = 2.0
    public var start, end, speed: Double
    public init(start: Double, end: Double, speed: Double) { (self.start, self.end, self.speed) = (start, end, speed) }
}

public struct Edits: Codable, Equatable, Sendable {
    public var trim: Trim               // the outer bounds; see `keptSegments` for what's cut from the middle
    public var segments: [Trim]?        // the kept parts in order, when there's more than one; nil = the whole trim
    public var crop: NRect
    public var zooms: [Zoom]
    public var padding: Double          // fraction of content width added on every side
    public var background: String       // #rrggbb, also shown while an image loads
    public var backgroundImage: String? // image path behind the video, scaled to cover
    public var annotations: [Annotation]? // arrows, shapes and images over the video; nil = none (see `allAnnotations`)
    public var audio: AudioTrack?       // background music or a voice-over, mixed with the recording's sound
    public var gradient: BackgroundGradient? // used instead of the colour when there's no image
    public var backgroundBlur: Double?  // blurs the image, 0–1; nil = sharp
    public var cursorHighlight: Bool
    public var cursorStyle: CursorStyle? // the redrawn cursor; nil = defaults
    public var cursorIdleHide: Double?
    public var clickEffect: ClickEffect? // nil = none  // fade the cursor out after this many seconds without movement; nil = always shown
    public var callouts: [Callout]
    public var aspect: String?          // output frame "w:h" (see `aspectRatios`); nil = match the recording
    public var camera: CameraStyle?     // webcam bubble; nil when the recording has no camera
    public var cornerRadius: Double?    // framed video's corner radius, as a fraction of its shorter side; nil = automatic
    public var shadow: Double?          // framed video's shadow strength, 0–1; nil = `DropShadow.defaultStrength`
    public var shadowSoftness: Double?  // how far it spreads, 0–1; nil = `DropShadow.defaultSoftness`
    public var micVolume: Double?       // the recording's microphone, 0–1; nil = full
    public var systemVolume: Double?    // the recording's system audio (system.m4a), 0–1; nil = full
    public var silenced: [SilencedRange]? // parts of the microphone or system audio muted on their own; nil = none
    public var speeds: [SpeedRegion]?   // parts played faster or slower; nil = none
    public var keystrokes: KeystrokeStyle? // shortcuts pressed while recording, when there are any; nil = shown, defaults
    public var markers: [Marker]?       // named points that become chapters; nil = none (see `allMarkers`)
    public var captions: Captions?      // lines from the transcript and how they look; nil = never turned on
    public var micCleanup: MicCleanup?  // noise reduction and loudness for the microphone; nil = off
    public var clips: [InsertedClip]?   // videos played between parts of the recording; nil = none (see `allClips`)

    public init(trim: Trim, crop: NRect = .full, zooms: [Zoom] = [], padding: Double = 0.06, background: String = "#1e1b4b",
                backgroundImage: String? = nil, cursorHighlight: Bool = true, callouts: [Callout] = [], aspect: String? = nil,
                camera: CameraStyle? = nil, cornerRadius: Double? = nil, shadow: Double? = nil, shadowSoftness: Double? = nil,
                gradient: BackgroundGradient? = nil, backgroundBlur: Double? = nil) {
        self.trim = trim; self.crop = crop; self.zooms = zooms; self.padding = padding; self.background = background
        self.backgroundImage = backgroundImage; self.cursorHighlight = cursorHighlight; self.callouts = callouts; self.aspect = aspect
        self.camera = camera; self.cornerRadius = cornerRadius; self.shadow = shadow; self.shadowSoftness = shadowSoftness
        self.gradient = gradient; self.backgroundBlur = backgroundBlur
    }
}

/// A named point on the timeline, at recording time `t`. The exported video gets a chapter starting at each.
public struct Marker: Codable, Equatable, Sendable {
    public var t: Double
    public var name: String
    public init(t: Double, name: String) { (self.t, self.name) = (t, name) }
    public static let maxName = 80
}

/// Where chapter flags go along the timeline, for markers at `xs` (left to right): each at its marker, or just after the
/// flag before it when that one is in the way, so close markers sit side by side as icons rather than one hiding the
/// other. `room` is how far a flag reaches before the next one (or `width`), for as much of its name as fits.
public func flagLayout(_ xs: [Double], width: Double, icon: Double) -> [(x: Double, room: Double)] {
    var at: [Double] = []
    for x in xs { at.append(max(x, (at.last ?? -.infinity) + icon)) }
    return at.indices.map { (at[$0], (at.indices.contains($0 + 1) ? at[$0 + 1] : width) - at[$0]) }
}

/// One chapter of the exported video, in output time.
public struct Chapter: Equatable, Sendable {
    public var start, end: Double
    public var name: String
    public init(start: Double, end: Double, name: String) { (self.start, self.end, self.name) = (start, end, name) }
}

extension Edits {
    /// The markers as a plain list, in time order, for editing. Stored as nil when empty.
    public var allMarkers: [Marker] {
        get { markers ?? [] }
        set { markers = newValue.isEmpty ? nil : newValue.sorted { $0.t < $1.t } }
    }

    /// Moves marker i to recording time t, kept inside the trim, and returns its index in the re-sorted list.
    @discardableResult
    public mutating func moveMarker(_ i: Int, to t: Double) -> Int? {
        guard allMarkers.indices.contains(i) else { return nil }
        var list = allMarkers
        list[i].t = (clamp(t, trim.start, trim.end - 0.05) * 100).rounded() / 100
        let m = list[i]
        allMarkers = list
        return allMarkers.firstIndex(of: m)
    }

    /// The exported video's chapters: one from each marker that plays, at its output time, following cuts and speeds.
    /// Markers in a cut or outside the trim are dropped. Players and YouTube want the first chapter at 0:00, so when the
    /// first marker comes later, the video's opening is a chapter named `title`.
    public func chapters(title: String) -> [Chapter] {
        let map = timeMap, length = outputDuration(map)
        let starts = allMarkers
            .filter { m in map.contains { m.t >= $0.start && m.t < $0.end } }
            .map { (t: sourceToOutput(map, $0.t), name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !starts.isEmpty else { return [] }
        var list = (starts.first!.t > 0.5 ? [(t: 0.0, name: title)] : []) + starts
        list[0].t = 0
        // Two markers at the same moment would make an empty chapter: the later one wins.
        list = list.enumerated().filter { i, c in i == list.count - 1 || list[i + 1].t - c.t > 0.01 }.map(\.element)
        return list.indices.map { i in Chapter(start: list[i].t, end: i + 1 < list.count ? list[i + 1].t : length, name: list[i].name) }
    }
}

/// "0:00", "12:34" or "1:02:03", the way YouTube reads chapter times.
public func chapterTime(_ s: Double) -> String {
    let s = Int(max(0, s))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// The recording's own sound sources, which can be silenced in parts.
public enum SoundSource: String, Codable, Sendable { case mic, system, music, clip }

/// A stretch of recording time where one sound source is muted while everything else plays.
public struct SilencedRange: Codable, Equatable, Sendable {
    public var source: SoundSource
    public var start, end: Double
    public init(source: SoundSource, start: Double, end: Double) { (self.source, self.start, self.end) = (source, start, end) }
}

/// Where `source` is muted, merged and in order.
public func silencedRanges(_ all: [SilencedRange], _ source: SoundSource) -> [Trim] {
    mergedRanges(all.filter { $0.source == source }.map { Trim(start: $0.start, end: $0.end) })
}

/// Anything shown between two recording times: zooms, callouts, annotations.
public protocol Timed {
    var start: Double { get set }
    var end: Double { get set }
    /// Moves it `d` seconds later (or earlier) with whatever is timed along with it. Changing `start` or `end` on their
    /// own trims it instead.
    mutating func shift(by d: Double)
    /// Makes it a new item with the same settings, for a copy or a split-off piece.
    mutating func renewID()
}

extension Timed {
    public mutating func shift(by d: Double) { start += d; end += d }
    public mutating func renewID() {}
}
extension Zoom: Timed { public mutating func renewID() { id = ItemID() } }
extension Callout: Timed { public mutating func renewID() { id = ItemID() } }
extension Annotation: Timed { public mutating func renewID() { id = ItemID() } }
extension SpeedRegion: Timed {}

/// `items` with every one that spans t split into two touching pieces with the same settings.
public func splitting<T: Timed>(_ items: [T], at t: Double) -> [T] {
    items.flatMap { it -> [T] in
        guard t > it.start + 0.05, t < it.end - 0.05 else { return [it] }
        var a = it, b = it
        a.end = t; b.start = t
        b.renewID()
        return [a, b]
    }
}

/// Pieces that touch and are otherwise identical, joined back into one, so a split on its own doesn't change the
/// video (a split zoom would otherwise ease out and back in at the split).
public func joiningTouching<T: Timed & Equatable>(_ items: [T]) -> [T] {
    func same(_ a: T, _ b: T) -> Bool { var a = a, b = b; (a.start, a.end, b.start, b.end) = (0, 0, 0, 0); return a == b }
    var out: [T] = []
    for it in items.sorted(by: { $0.start < $1.start }) {
        if let last = out.last, abs(last.end - it.start) < 1e-6, same(last, it) { out[out.count - 1].end = it.end } else { out.append(it) }
    }
    return out
}

/// Ranges cut into the kept segments they cross: what a lane draws as separate blocks, like the clip's pieces.
/// `gap` is true for a block that ends at a split, so it's drawn a little short of the next one.
public func blocks(_ ranges: [Trim], in segments: [Trim]) -> [(piece: Trim, gap: Bool)] {
    ranges.flatMap { r in
        segments.indices.compactMap { i in
            let s = max(r.start, segments[i].start), e = min(r.end, segments[i].end)
            return e > s ? (Trim(start: s, end: e), i < segments.count - 1 && e >= segments[i].end) : nil
        }
    }
}

/// Whether item i ends where another starts, as both pieces of a split item do, so it's drawn a little short of it.
public func touchesNext<T: Timed>(_ items: [T], _ i: Int) -> Bool {
    items.contains { abs($0.start - items[i].end) < 1e-6 }
}

/// Volume points with `muted` silenced, fading over `fade` into and out of each range. Times are recording times.
public func silencing(_ points: [(t: Double, gain: Double)], _ muted: [Trim], fade: Double = 0.01) -> [(t: Double, gain: Double)] {
    guard !muted.isEmpty, let first = points.first, let last = points.last else { return points }
    func gain(_ t: Double) -> Double {
        if t <= first.t { return first.gain }
        if t >= last.t { return last.gain }
        let j = points.firstIndex { $0.t > t }!, a = points[j - 1], b = points[j]
        return a.gain + (b.gain - a.gain) * (t - a.t) / max(1e-9, b.t - a.t)
    }
    func mask(_ t: Double) -> Double {
        muted.map { r in t < r.start - fade || t > r.end + fade ? 1 : t < r.start ? (r.start - t) / fade : t > r.end ? (t - r.end) / fade : 0 }.min() ?? 1
    }
    let ts = Set(points.map(\.t) + muted.flatMap { [$0.start - fade, $0.start, $0.end, $0.end + fade] }.filter { $0 >= 0 }).sorted()
    return ts.map { (t: $0, gain: gain($0) * mask($0)) }
}

/// Sorted, with overlapping or touching ranges joined.
public func mergedRanges(_ ranges: [Trim]) -> [Trim] {
    var out: [Trim] = []
    for r in ranges.sorted(by: { $0.start < $1.start }) where r.end > r.start {
        if let last = out.last, r.start <= last.end + 1e-6 { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
    }
    return out
}

extension Edits {
    /// Where `source` is muted, merged and in order.
    public func silencedRanges(_ source: SoundSource) -> [Trim] { RecordCore.silencedRanges(silenced ?? [], source) }

    /// Mutes `source` over `range`, or, when it's already muted all the way through, brings it back.
    public mutating func toggleSilence(_ source: SoundSource, _ range: Trim) {
        var mine = silencedRanges(source)
        if mine.contains(where: { $0.start <= range.start + 1e-6 && $0.end >= range.end - 1e-6 }) {
            mine = mine.flatMap { r in
                [Trim(start: r.start, end: min(r.end, range.start)), Trim(start: max(r.start, range.end), end: r.end)].filter { $0.end - $0.start > 1e-6 }
            }
        } else {
            mine = mergedRanges(mine + [range])
        }
        let others = (silenced ?? []).filter { $0.source != source }
        let all = others + mine.map { SilencedRange(source: source, start: $0.start, end: $0.end) }
        silenced = all.isEmpty ? nil : all
    }

    /// The parts of the recording that play, in order, within the trim. The first starts at the trim's start and the
    /// last ends at its end, so dragging the trim handles moves them. Setting it moves the trim to the outer bounds.
    public var keptSegments: [Trim] {
        get {
            var s = (segments ?? []).sorted { $0.start < $1.start }
                .map { Trim(start: max($0.start, trim.start), end: min($0.end, trim.end)) }
                .filter { $0.end - $0.start > 0.01 }
            guard !s.isEmpty else { return [trim] }
            s[0].start = trim.start
            s[s.count - 1].end = trim.end
            return s
        }
        set {
            guard let first = newValue.first, let last = newValue.last else { return }
            segments = newValue.count > 1 ? newValue : nil
            trim = Trim(start: first.start, end: last.end)
        }
    }

    /// Splits everything at recording time `t`: the kept segment under it, and every zoom, callout and annotation that
    /// spans it, so each lane has a separate piece either side. False when t isn't inside a segment, or too near an edge.
    @discardableResult
    public mutating func split(at t: Double) -> Bool {
        var s = keptSegments
        guard let i = s.firstIndex(where: { t > $0.start + 0.1 && t < $0.end - 0.1 }) else { return false }
        s.insert(Trim(start: t, end: s[i].end), at: i + 1)
        s[i].end = t
        keptSegments = s
        zooms = splitting(zooms, at: t)
        callouts = splitting(callouts, at: t)
        allAnnotations = splitting(allAnnotations, at: t)
        speeds = speeds.map { splitting($0, at: t) }
        return true
    }

    /// The kept segments split where the speed changes, each piece with its speed: what plays, in order. Map output
    /// time with `outputToSource`, `sourceToOutput` and `outputDuration`.
    public var timeMap: [Trim] { RecordCore.timeMap(keptSegments, speeds ?? []) }

    /// Cuts a kept segment out. The last one left can't be removed.
    public mutating func removeSegment(_ i: Int) {
        var s = keptSegments
        guard s.count > 1, s.indices.contains(i) else { return }
        s.remove(at: i)
        keptSegments = s
    }

    /// The speed regions as a plain list, in order, for editing. Stored as nil when empty.
    public var allSpeeds: [SpeedRegion] {
        get { speeds ?? [] }
        set { speeds = newValue.isEmpty ? nil : newValue.sorted { $0.start < $1.start } }
    }

    /// Plays recording time a…b at `speed` (1 = normal), replacing whatever speed was there. The clip is split at a and
    /// b, so speed only ever changes between pieces of the clip.
    public mutating func setSpeed(_ speed: Double, from a: Double, to b: Double) {
        splitSegments(at: a)
        splitSegments(at: b)
        let others = subtracting(allSpeeds.map { Trim(start: $0.start, end: $0.end, speed: $0.speed) }, [Trim(start: a, end: b)])
        allSpeeds = others.map { SpeedRegion(start: $0.start, end: $0.end, speed: $0.speed ?? 1) }
            + (speed == 1 ? [] : [SpeedRegion(start: a, end: b, speed: speed)])
    }

    /// The speed piece `i` of the clip plays at.
    public func speed(ofSegment i: Int) -> Double {
        let s = keptSegments
        return s.indices.contains(i) ? speedAt(allSpeeds, (s[i].start + s[i].end) / 2) : 1
    }

    /// Splits the clip wherever the speed changes inside a piece, so each piece plays at one speed. For edits made when
    /// speed had a lane of its own.
    public mutating func splitAtSpeedChanges() {
        for r in allSpeeds { splitSegments(at: r.start); splitSegments(at: r.end) }
    }

    /// Splits only the clip at t, when t is inside a piece rather than at its edge.
    private mutating func splitSegments(at t: Double) {
        var s = keptSegments
        guard let i = s.firstIndex(where: { t > $0.start + 0.01 && t < $0.end - 0.01 }) else { return }
        s.insert(Trim(start: t, end: s[i].end), at: i + 1)
        s[i].end = t
        keptSegments = s
    }

    /// The annotations as a plain list, for editing. Stored as nil when empty, so edits without any stay unchanged.
    public var allAnnotations: [Annotation] {
        get { annotations ?? [] }
        set { annotations = newValue.isEmpty ? nil : newValue }
    }
}

/// An arrow, rectangle, ellipse, image or video shown over the video between `start` and `end` (recording seconds), or a box
/// that blurs or pixelates what's under it. Positions are normalized to the output canvas with a top-left origin, like
/// callouts, except a blur's: it's normalized to the recorded frame, so it stays over the same content when cropped,
/// zoomed or panned.
public struct Annotation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case arrow, rectangle, ellipse, image, blur, video }
    public var kind: Kind
    public var start, end: Double
    /// Shapes and images: the box's top-left corner and size, before rotation. Arrows: the tail is (x, y) and the head
    /// is (x + w, y + h), so w and h can be negative.
    public var x, y, w, h: Double
    public var rotation: Double         // degrees clockwise about the box's centre; arrows ignore it
    public var color: String            // #rrggbb, for arrows and shapes
    public var stroke: Double           // line width as a fraction of the canvas's short side
    public var image: String?           // image file, for `.image`
    public var fade: Double?            // seconds to fade in and out; nil = appear and disappear at once
    public var pixelate: Bool?          // `.blur`: square blocks instead of a blur; nil = blur
    public var strength: Double?        // `.blur`: 0–1; nil = `defaultStrength`
    public var video: OverlayVideo?     // `.video`: what plays in the box
    public var id = ItemID()

    public init(kind: Kind, start: Double, end: Double, x: Double, y: Double, w: Double, h: Double, rotation: Double = 0,
                color: String = "#ff3b30", stroke: Double = 0.008, image: String? = nil, fade: Double? = nil) {
        self.kind = kind; self.start = start; self.end = end; self.x = x; self.y = y; self.w = w; self.h = h
        self.rotation = rotation; self.color = color; self.stroke = stroke; self.image = image; self.fade = fade
    }

    public static let strokes = 0.002...0.03
    public static let fades = 0.0...2.0
    public static let defaultStrength = 0.5

    /// A blur's radius, or a pixelated block's side, in source pixels for a recording whose shorter side is `short`.
    /// In source pixels, so it grows with the zoom like what it hides.
    public func blurAmount(short: Double) -> Double {
        let k = strength ?? Self.defaultStrength
        return short * (pixelate == true ? 0.01 + 0.04 * k : 0.004 + 0.026 * k)
    }
}

extension Annotation {
    /// Moving a video overlay moves what plays in it too; trimming it doesn't, so a trimmed end shows less of the video.
    public mutating func shift(by d: Double) {
        start += d
        end += d
        video?.at += d
    }
}

/// A video played in an annotation's box, over the recording: a product shot in the corner, a phone recording beside
/// the screen. Its file is a copy in the recording's folder. It plays at its own pace from timeline time `at`, which
/// may be before the box starts (trimmed off the front); the box's start and end pick what part of it shows.
public struct OverlayVideo: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var at: Double
    public var length: Double           // the whole file
    public var width: Int, height: Int  // its frame, upright
    public var volume: Double?          // its sound, 0–1; nil = off
    public var roundness: Double?       // corner radius as a fraction of half the shorter side, 0–1; nil = `defaultRoundness`
    public var shadow: Double?          // 0–1; nil = `DropShadow.defaultStrength`

    public init(path: String, name: String, at: Double, length: Double, width: Int, height: Int) {
        (self.path, self.name, self.at, self.length, self.width, self.height) = (path, name, at, length, width, height)
    }

    public static let defaultRoundness = 0.15
    public var end: Double { at + length }
}

extension Edits {
    /// The video overlays as they're drawn: touching pieces of one joined back up (see `joiningTouching`), in the
    /// order the renderer meets them. Each gets its own tracks in the player and the export, by index in this list.
    public var videoOverlays: [Annotation] { joiningTouching(allAnnotations).filter { $0.kind == .video && $0.video != nil } }
}

/// Where a point normalized to the recorded frame shows on the canvas (normalized, top-left origin), through the crop
/// and the camera at `cam`. `sourcePoint` goes back.
public func canvasPoint(_ p: Point, _ e: Edits, _ size: OutputSize, camera cam: CameraPoint) -> Point {
    let c = e.crop
    let u = ((p.x - c.x) / c.w - cam.x) * cam.z + 0.5, v = ((p.y - c.y) / c.h - cam.y) * cam.z + 0.5
    return Point(x: (Double(size.x) + u * Double(size.contentW)) / Double(size.width),
                 y: (Double(size.y) + v * Double(size.contentH)) / Double(size.height))
}

/// The point of the recorded frame (normalized) shown at canvas point q; see `canvasPoint`.
public func sourcePoint(_ q: Point, _ e: Edits, _ size: OutputSize, camera cam: CameraPoint) -> Point {
    let c = e.crop
    let u = (q.x * Double(size.width) - Double(size.x)) / Double(size.contentW), v = (q.y * Double(size.height) - Double(size.y)) / Double(size.contentH)
    return Point(x: c.x + c.w * ((u - 0.5) / cam.z + cam.x), y: c.y + c.h * ((v - 0.5) / cam.z + cam.y))
}

/// An audio file played along with the recording: `from`…`from + length` of the file, starting at recording time `at`.
public struct AudioTrack: Codable, Equatable, Sendable {
    public var path: String
    public var fileDuration: Double     // the whole file, so trimming can't run past its end
    public var at, from, length: Double
    public var volume: Double           // 0–1
    public var fadeIn, fadeOut: Double  // seconds
    public var duck: Bool               // lower it while you're speaking into the microphone

    public init(path: String, fileDuration: Double, at: Double, from: Double = 0, length: Double, volume: Double = 0.6,
                fadeIn: Double = 0.5, fadeOut: Double = 1.5, duck: Bool = false) {
        self.path = path; self.fileDuration = fileDuration; self.at = at; self.from = from; self.length = length
        self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.duck = duck
    }

    public var end: Double { at + length }
    public static let extensions = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]
    public static let fades = 0.0...10.0
    /// While ducking, the music drops to this fraction of its volume, over `duckRamp` seconds either side of your voice.
    public static let duckLevel = 0.25, duckRamp = 0.3

    /// The fields that decide which part of the file plays where. Changing them rebuilds the player; the rest only
    /// changes volumes.
    public var placement: [Double] { [at, from, length] }
}

/// The extra track's volume at recording time `t`: 0 outside it, ramping over the fades, and dipped while any of the
/// `voice` ranges is active (if it ducks).
public func musicGain(_ m: AudioTrack, at t: Double, voice: [ClosedRange<Double>] = []) -> Double {
    guard t >= m.at, t <= m.end, m.length > 0 else { return 0 }
    var g = max(0, min(1, m.volume))
    if m.fadeIn > 0 { g *= min(1, (t - m.at) / m.fadeIn) }
    if m.fadeOut > 0 { g *= min(1, (m.end - t) / m.fadeOut) }
    if m.duck {
        // How far into a dip: 1 inside a voice range, ramping down to 0 over `duckRamp` either side.
        let r = AudioTrack.duckRamp
        let dip = voice.map { v -> Double in
            if v.contains(t) { return 1 }
            let gap = t < v.lowerBound ? v.lowerBound - t : t - v.upperBound
            return max(0, 1 - gap / r)
        }.max() ?? 0
        g *= 1 - (1 - AudioTrack.duckLevel) * dip
    }
    return g
}

/// Times where the volume curve bends, with the volume there. Straight ramps between them follow `musicGain`.
public func musicVolumePoints(_ m: AudioTrack, voice: [ClosedRange<Double>] = []) -> [(t: Double, gain: Double)] {
    var ts: Set<Double> = [m.at, m.end, min(m.end, m.at + m.fadeIn), max(m.at, m.end - m.fadeOut)]
    if m.duck {
        for v in voice where v.upperBound > m.at - AudioTrack.duckRamp && v.lowerBound < m.end + AudioTrack.duckRamp {
            for t in [v.lowerBound - AudioTrack.duckRamp, v.lowerBound, v.upperBound, v.upperBound + AudioTrack.duckRamp] { ts.insert(t) }
        }
    }
    return ts.filter { $0 >= m.at && $0 <= m.end }.sorted().map { ($0, musicGain(m, at: $0, voice: voice)) }
}

/// When you're speaking, from microphone loudness measured every `window` seconds (RMS, 0–1). Short gaps are bridged
/// and blips ignored, so the music doesn't pump between words.
public func voiceRanges(levels: [Double], window: Double, threshold: Double = 0.02, bridge: Double = 0.6, minimum: Double = 0.25) -> [ClosedRange<Double>] {
    var out: [ClosedRange<Double>] = []
    var start: Double?
    for (i, v) in levels.enumerated() {
        let t = Double(i) * window
        if v >= threshold { if start == nil { start = t } }
        else if let s = start { out.append(s...t); start = nil }
    }
    if let s = start { out.append(s...Double(levels.count) * window) }
    var merged: [ClosedRange<Double>] = []
    for r in out {
        if let last = merged.last, r.lowerBound - last.upperBound <= bridge { merged[merged.count - 1] = last.lowerBound...r.upperBound }
        else { merged.append(r) }
    }
    return merged.filter { $0.upperBound - $0.lowerBound >= minimum }
}

/// How long pauses are found and what happens to them.
public struct PauseOptions: Equatable, Sendable {
    public var minimum: Double   // seconds of silence before it counts as a pause
    public var padding: Double   // seconds kept before and after speech, so words aren't clipped
    public var speedUp: Bool     // play them at `speed` instead of cutting them
    public static let speed = 4.0
    public static let minimums = 0.5...5.0, paddings = 0.0...1.0
    public init(minimum: Double = 1.5, padding: Double = 0.25, speedUp: Bool = false) {
        (self.minimum, self.padding, self.speedUp) = (minimum, padding, speedUp)
    }
}

/// The silences within `segments` that are at least `o.minimum` long: between `voice` ranges, and before the first or
/// after the last. Each keeps `o.padding` next to speech (not at a segment's edge, where there's no speech to protect).
/// Empty when there's no speech at all, since then there's nothing to tighten around.
public func longPauses(voice: [ClosedRange<Double>], in segments: [Trim], _ o: PauseOptions) -> [Trim] {
    guard !voice.isEmpty else { return [] }
    return segments.flatMap { s -> [Trim] in
        var gaps: [Trim] = [], t = s.start
        for v in voice.sorted(by: { $0.lowerBound < $1.lowerBound }) where v.upperBound > s.start && v.lowerBound < s.end {
            if v.lowerBound > t { gaps.append(Trim(start: t, end: v.lowerBound)) }
            t = max(t, v.upperBound)
        }
        if t < s.end { gaps.append(Trim(start: t, end: s.end)) }
        return gaps.filter { $0.end - $0.start >= o.minimum }.compactMap { g in
            let a = g.start == s.start ? g.start : g.start + o.padding, b = g.end == s.end ? g.end : g.end - o.padding
            return b - a >= 0.1 ? Trim(start: a, end: b) : nil
        }
    }
}

/// `ranges` with every part inside `holes` taken out.
public func subtracting(_ ranges: [Trim], _ holes: [Trim]) -> [Trim] {
    let holes = mergedRanges(holes)
    return ranges.flatMap { r -> [Trim] in
        var out: [Trim] = [], t = r.start
        for h in holes where h.end > t && h.start < r.end {
            if h.start > t { out.append(Trim(start: t, end: h.start, speed: r.speed)) }
            t = max(t, h.end)
        }
        if t < r.end { out.append(Trim(start: t, end: r.end, speed: r.speed)) }
        return out.filter { $0.end - $0.start > 0.01 }
    }
}

extension Edits {
    /// What `removePauses` takes out: the long pauses in what plays, less, when speeding up, any time that already has
    /// a speed of its own. `voice` is in timeline time (see `timelineRanges`).
    public func pauses(voice: [ClosedRange<Double>], _ o: PauseOptions) -> [Trim] {
        // An inserted clip has no microphone, but its quiet isn't a pause in what you said.
        let p = subtracting(longPauses(voice: voice, in: keptSegments, o), allClips.map { Trim(start: $0.at, end: $0.end) })
            .filter { $0.end - $0.start >= 0.1 }
        guard o.speedUp else { return p }
        return subtracting(p, allSpeeds.map { Trim(start: $0.start, end: $0.end) }).filter { $0.end - $0.start >= 0.3 }
    }

    /// Takes the long pauses out in one edit: cut from the kept segments, or played at `PauseOptions.speed`.
    /// Nothing changes when cutting would leave nothing.
    public mutating func removePauses(voice: [ClosedRange<Double>], _ o: PauseOptions) {
        let p = pauses(voice: voice, o)
        if o.speedUp {
            for q in p { setSpeed(PauseOptions.speed, from: q.start, to: q.end) }
        } else {
            let kept = subtracting(keptSegments, p)
            if !kept.isEmpty { keptSegments = kept }
        }
    }
}

/// How visible an annotation is at `t`: 0 outside its time range, ramping over `fade` seconds at each end.
public func annotationOpacity(_ a: Annotation, at t: Double) -> Double {
    guard t >= a.start, t <= a.end else { return 0 }
    guard let f = a.fade, f > 0 else { return 1 }
    let ramp = min(f, (a.end - a.start) / 2)
    return min(1, (t - a.start) / ramp, (a.end - t) / ramp)
}

/// Where a callout's box `w`×`h` is drawn (normalized, top-left origin): at its own `x`, `y`, moved left or up just
/// enough to stay inside the canvas.
public func calloutOrigin(_ k: Callout, w: Double, h: Double) -> (x: Double, y: Double) {
    (max(0, min(k.x, 1 - w)), max(0, min(k.y, 1 - h)))
}

/// Snaps a box being dragged on the canvas (normalized, top-left origin): along each axis, its nearest edge or centre
/// moves onto the canvas's nearest edge or centre line when that's within `within` (per axis, normalized). Returns the
/// new origin and the line it snapped to on each axis, for drawing a guide.
public func snapBox(x: Double, y: Double, w: Double, h: Double, within: (x: Double, y: Double)) -> (x: Double, y: Double, guideX: Double?, guideY: Double?) {
    func snap(_ p: Double, _ len: Double, _ within: Double) -> (Double, Double?) {
        var best: (d: Double, line: Double)?
        for line in [0, 0.5, 1.0] {
            for edge in [p, p + len / 2, p + len] where abs(line - edge) <= within && abs(line - edge) < (best.map { abs($0.d) } ?? .infinity) {
                best = (line - edge, line)
            }
        }
        return best.map { (p + $0.d, $0.line) } ?? (p, nil)
    }
    let (sx, gx) = snap(x, w, within.x), (sy, gy) = snap(y, h, within.y)
    return (sx, sy, gx, gy)
}

/// RecordStudio's one colour, #E5484D in sRGB 0–1. It means recording: the record buttons and dot, and the click ripple.
public enum Brand {
    public static let red = (r: 0.898, g: 0.282, b: 0.302)
}

/// A two-colour linear gradient. `angle` is in degrees like CSS: the direction it runs, clockwise from upward.
/// 90 runs left→right, 180 top→bottom, 135 from the top-left corner to the bottom-right one.
public struct BackgroundGradient: Codable, Hashable, Sendable {
    public var from, to: String         // #rrggbb
    public var angle: Double
    public init(from: String, to: String, angle: Double) { (self.from, self.to, self.angle) = (from, to, angle) }

    public static let presets: [BackgroundGradient] = [
        .init(from: "#2b2d31", to: "#4a4d55", angle: 180), // graphite: RecordStudio's own, the default for new recordings
        .init(from: "#4f46e5", to: "#db2777", angle: 135), // indigo → pink
        .init(from: "#0ea5e9", to: "#10b981", angle: 135), // sky → emerald
        .init(from: "#f97316", to: "#facc15", angle: 135), // orange → amber
        .init(from: "#1e1b4b", to: "#7c3aed", angle: 180), // midnight → violet
        .init(from: "#fce7f3", to: "#dbeafe", angle: 135), // pastel pink → blue
    ]
}

/// Where a gradient starts and ends on a `width`×`height` canvas, in pixels with a top-left origin. The line runs
/// through the centre and is just long enough that the end colours land exactly on the canvas's far corners or edges.
public func gradientEnds(_ g: BackgroundGradient, width: Double, height: Double) -> (start: (x: Double, y: Double), end: (x: Double, y: Double)) {
    let a = g.angle * .pi / 180, dx = sin(a), dy = -cos(a) // y grows downward
    let half = (abs(width * dx) + abs(height * dy)) / 2
    let cx = width / 2, cy = height / 2
    return ((cx - dx * half, cy - dy * half), (cx + dx * half, cy + dy * half))
}

/// Blur radius in output pixels for `Edits.backgroundBlur` on a canvas whose shorter side is `short` pixels.
public func backgroundBlurRadius(_ e: Edits, short: Double) -> Double { (e.backgroundBlur ?? 0) * 0.05 * short }

/// A drop shadow in output pixels: black at `alpha`, blurred by `radius`, moved down by `offset`.
public struct DropShadow: Equatable, Sendable {
    public var alpha, radius, offset: Double
    /// Strength and softness are 0–1. The defaults reproduce the shadows from before they were adjustable.
    public static let defaultStrength = 0.5, defaultSoftness = 0.5
    public static let range = 0.0...1.0
}

/// The framed video's shadow, or nil when there's none to draw (no padding to show it on, or strength 0).
public func frameShadow(_ s: OutputSize, _ e: Edits) -> DropShadow? {
    let strength = e.shadow ?? DropShadow.defaultStrength
    guard s.x > 0 || s.y > 0, strength > 0 else { return nil }
    let h = Double(s.contentH), soft = e.shadowSoftness ?? DropShadow.defaultSoftness
    return DropShadow(alpha: 0.9 * strength, radius: h * (0.004 + 0.042 * soft), offset: h * (0.004 + 0.016 * soft))
}

/// The webcam bubble's shadow for a bubble `d` pixels across, or nil at strength 0.
public func bubbleShadow(diameter d: Double, _ c: CameraStyle) -> DropShadow? { boxShadow(size: d, strength: c.shadow) }

/// The shadow under a floating box (the webcam bubble, a video overlay) whose shorter side is `d` pixels, or nil at
/// strength 0. Strength nil is `DropShadow.defaultStrength`.
public func boxShadow(size d: Double, strength: Double?) -> DropShadow? {
    let strength = strength ?? DropShadow.defaultStrength
    guard strength > 0 else { return nil }
    return DropShadow(alpha: strength, radius: d * 0.05, offset: d * 0.03)
}

/// macOS 26 window corners (continuous curve), measured on a standard window.
public let macWindowCornerPoints = 26.0
public let cornerRadii = 0.0...0.15

/// Corner radius of the framed video in output pixels. Automatic: gently rounded when padded, square otherwise.
public func cornerRadiusPx(_ s: OutputSize, _ e: Edits) -> Double {
    let short = Double(min(s.contentW, s.contentH))
    if let r = e.cornerRadius { return r * short }
    return s.x > 0 || s.y > 0 ? 0.018 * Double(s.contentH) : 0
}

/// The radius (as `Edits.cornerRadius`) that lines the frame up with a recorded window's own corners.
public func windowCornerFraction(width: Int, height: Int, crop: NRect, pointScale: Double) -> Double {
    min(cornerRadii.upperBound, macWindowCornerPoints * pointScale / min(Double(width) * crop.w, Double(height) * crop.h))
}

/// The webcam bubble drawn over the canvas.
public struct CameraStyle: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, rounded }
    public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public var visible = true
    public var shape = Shape.circle
    public var size = 0.24              // diameter as a fraction of the canvas's short side
    public var corner = Corner.bottomRight
    public var mirror = true            // match what you saw in the preview
    public var shrinkWhenZoomed = true  // get out of the way while the screen is zoomed in
    public var shadow: Double?          // shadow strength, 0–1; nil = `DropShadow.defaultStrength`
    public var center: Point?           // dragged position: the bubble's centre, normalized to the canvas; nil = `corner`
    public var margin: Double?          // gap from the canvas edge for corner placement, fraction of the short side; nil = 4%
    public var roundness: Double?       // 0 = square, 1 = circle; nil = from `shape` (older edits)
    public init() {}
    public static let sizes = 0.1...0.5
    public static let margins = 0.0...0.15
    public static let defaultMargin = 0.04

    /// Square-to-circle, falling back to the old circle/rounded choice. "Rounded" was a corner radius of 20% of the size.
    public var effectiveRoundness: Double { roundness ?? (shape == .circle ? 1 : 0.4) }
}

/// The bubble's corner radius for a bubble `d` pixels across: 0 for a square, d/2 for a circle.
public func bubbleCornerRadius(diameter d: Double, _ c: CameraStyle) -> Double { min(1, max(0, c.effectiveRoundness)) * d / 2 }

/// Where the bubble sits at a given zoom level: top-left corner and diameter, in canvas pixels.
/// A dragged bubble shrinks around its centre while zoomed, and always stays fully on the canvas.
public func cameraRect(_ s: OutputSize, _ c: CameraStyle, zoom: Double) -> (x: Double, y: Double, d: Double) {
    let w = Double(s.width), h = Double(s.height), short = min(w, h)
    var d = c.size * short
    if c.shrinkWhenZoomed { d *= 1 - 0.35 * min(1, max(0, (zoom - 1) / 0.8)) }
    if let p = c.center {
        return (min(max(0, p.x * w - d / 2), w - d), min(max(0, p.y * h - d / 2), h - d), d)
    }
    let m = (c.margin ?? CameraStyle.defaultMargin) * short
    let right = c.corner == .topRight || c.corner == .bottomRight
    let bottom = c.corner == .bottomLeft || c.corner == .bottomRight
    return (right ? w - m - d : m, bottom ? h - m - d : m, d)
}

/// The normalized centre that puts the bubble's top-left corner at (`x`, `y`) canvas pixels, kept on the canvas.
/// The editor uses it when you drop a dragged bubble.
public func cameraCenter(_ s: OutputSize, _ c: CameraStyle, topLeft x: Double, _ y: Double) -> Point {
    let w = Double(s.width), h = Double(s.height), d = c.size * min(w, h)
    return Point(x: (min(max(0, x), w - d) + d / 2) / w, y: (min(max(0, y), h - d) + d / 2) / h)
}

/// Settings for a GIF export. The frames come from the same renderer as the video, scaled down to `width`.
public struct GIFOptions: Equatable, Codable, Sendable {
    public var fps: Int
    public var width: Int
    public var loops: Bool
    public init(fps: Int = 15, width: Int = 640, loops: Bool = true) { (self.fps, self.width, self.loops) = (fps, width, loops) }

    public static let frameRates = [10, 15, 20]
    public static let widths = [480, 640, 800, 1080]
    /// Every frame is a full image, so long GIFs get huge and slow to encode.
    public static let maxSeconds = 60.0
}

/// GIF frame size: the canvas scaled to the chosen width (never up), keeping its shape.
public func gifSize(_ canvas: OutputSize, _ o: GIFOptions) -> (width: Int, height: Int) {
    let w = min(o.width, canvas.width)
    return (w, max(1, Int((Double(canvas.height) * Double(w) / Double(max(1, canvas.width))).rounded())))
}

/// Frames in a GIF of `seconds`: one every 1/fps, starting at 0.
public func gifFrameCount(seconds: Double, _ o: GIFOptions) -> Int {
    max(1, Int((seconds * Double(o.fps) - 1e-6).rounded(.up)))
}

/// A rough size for the export button. Screen recordings with flat UI compress far better than this; busy
/// wallpapers and lots of zooming come close.
public func gifEstimatedBytes(_ canvas: OutputSize, seconds: Double, _ o: GIFOptions) -> Int {
    let s = gifSize(canvas, o)
    return Int(Double(s.width * s.height * gifFrameCount(seconds: seconds, o)) * 0.3)
}

/// Output frames offered for export, as (value, label). The recording is fitted inside; the background fills the rest.
public let aspectRatios: [(value: String, label: String)] = [
    ("16:9", "16:9 Widescreen"), ("9:16", "9:16 Vertical"), ("1:1", "1:1 Square"), ("4:3", "4:3 Standard"), ("4:5", "4:5 Portrait"),
]

func parseAspect(_ s: String?) -> Double? {
    guard let s, aspectRatios.contains(where: { $0.value == s }) else { return nil }
    let p = s.split(separator: ":").compactMap { Double($0) }
    return p.count == 2 && p[1] > 0 ? p[0] / p[1] : nil
}

/// The crop dragged from `p` to `q` (normalized to the recorded frame, which is `source` pixels), kept inside it.
/// With an `aspect` (width ÷ height, in pixels) the box keeps that shape: as wide as the drag allows, from `p`.
public func cropRect(from p: Point, to q: Point, aspect: Double?, source: (w: Double, h: Double)) -> NRect {
    let cx = { (v: Double) in min(1, max(0, v)) }
    let qx = cx(q.x), qy = cx(q.y)
    guard let aspect, aspect > 0 else {
        return NRect(x: min(p.x, qx), y: min(p.y, qy), w: abs(p.x - qx), h: abs(p.y - qy))
    }
    // Room in the drag's direction, from p to the frame's edge.
    let dx = qx >= p.x ? 1.0 : -1, dy = qy >= p.y ? 1.0 : -1
    let roomW = dx > 0 ? 1 - p.x : p.x, roomH = dy > 0 ? 1 - p.y : p.y
    let k = source.w / (source.h * aspect) // normalized height per normalized width
    var w = max(abs(qx - p.x), abs(qy - p.y) / k)
    w = min(w, roomW, roomH / k)
    let h = w * k
    return NRect(x: dx > 0 ? p.x : p.x - w, y: dy > 0 ? p.y : p.y - h, w: w, h: h)
}

/// The largest crop of `aspect` (width ÷ height, in pixels) in a `source`-pixel frame, centred on `around`'s centre
/// as far as the frame allows.
public func cropFitting(aspect: Double, around c: NRect, source: (w: Double, h: Double)) -> NRect {
    let k = source.w / (source.h * aspect)
    let w = min(1, 1 / k), h = w * k
    let x = min(1 - w, max(0, c.x + c.w / 2 - w / 2)), y = min(1 - h, max(0, c.y + c.h / 2 - h / 2))
    return NRect(x: x, y: y, w: w, h: h)
}

public struct CameraPoint: Equatable, Sendable {
    public var t, z, x, y: Double
}

/// Canvas `width`×`height`; the recording occupies `contentW`×`contentH` with its top-left at (`x`, `y`).
public struct OutputSize: Equatable, Sendable {
    public var contentW, contentH, x, y, width, height: Int
    public init(contentW: Int, contentH: Int, x: Int, y: Int, width: Int, height: Int) {
        (self.contentW, self.contentH, self.x, self.y, self.width, self.height) = (contentW, contentH, x, y, width, height)
    }
}

/// The output's size and, when it's close to a common one, its shape: "1920 × 1080 · 16:9". For the preview's readout.
public func frameLabel(_ s: OutputSize) -> String {
    let size = "\(s.width) × \(s.height)"
    guard s.height > 0 else { return size }
    let ratio = Double(s.width) / Double(s.height)
    let shapes = ["16:9", "16:10", "3:2", "4:3", "1:1", "4:5", "9:16", "21:9"]
    guard let shape = shapes.first(where: { name in
        let p = name.split(separator: ":").compactMap { Double($0) }
        return abs(p[0] / p[1] / ratio - 1) < 0.01
    }) else { return size }
    return "\(size) · \(shape)"
}

public enum Tuning {
    public static let ramp = 1.1         // seconds to ease in/out of a zoom
    public static let follow = 0.28      // per-stage time constant (s) of the two-stage camera follow
    public static let cameraFPS = 30.0
    public static let cursorFPS = 60.0
}

@inline(__always) public func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
/// Rounds down to an even number of pixels (video encoders need even sizes), ignoring floating-point dust so that
/// 3840 × (1280 / 3840) stays 1280.
private func evenDown(_ v: Double) -> Int { max(2, Int((v + 1e-6) / 2) * 2) }

public func safeFilename(_ name: String, fallback: String = "recording") -> String {
    var s = name.precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: #"[^\p{L}\p{N}._-]+"#, with: "-", options: .regularExpression)
        .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        .replacingOccurrences(of: #"^[.-]+|[.-]+$"#, with: "", options: .regularExpression)
    s = String(s.prefix(80)).replacingOccurrences(of: #"[.-]+$"#, with: "", options: .regularExpression)
    return s.isEmpty ? fallback : s
}

/// Counts down `seconds` (3, 2, 1), showing each number for a second. False when cancelled, so recording starts
/// only once the whole countdown has run and nothing of the overlay is captured.
public func countdown(_ seconds: Int, tick: @MainActor (Int) -> Void,
                      sleep: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async -> Bool {
    for n in stride(from: seconds, to: 0, by: -1) {
        await tick(n)
        do { try await sleep() } catch { return false }
    }
    return !Task.isCancelled
}

/// A microphone's average power (dBFS) as a meter fill from 0 to 1: -50 dB and quieter is empty, 0 dB is full.
public func meterLevel(dB: Double) -> Double { clamp((dB + 50) / 50, 0, 1) }

/// The meter's next shown level: it jumps up to a louder sound at once and falls back a quarter of the way each tick,
/// so it reads as a level rather than flicker.
public func smoothedLevel(shown: Double, heard: Double) -> Double { heard >= shown ? heard : shown + (heard - shown) * 0.25 }

/// A rectangle in screen points -> capture rect normalized to the screen, clipped to it.
public func normalizeBounds(_ b: NRect, screen: (w: Double, h: Double)) -> NRect? {
    let x0 = clamp(b.x / screen.w, 0, 1), y0 = clamp(b.y / screen.h, 0, 1)
    let x1 = clamp((b.x + b.w) / screen.w, 0, 1), y1 = clamp((b.y + b.h) / screen.h, 0, 1)
    return x1 - x0 >= 0.05 && y1 - y0 >= 0.05 ? NRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : nil
}

public func clickTimes(_ cursor: [CursorSample]) -> [Double] {
    cursor.indices.filter { cursor[$0].down && ($0 == 0 || !cursor[$0 - 1].down) }.map { cursor[$0].t }
}

/// `segments` split where `speeds` start and end, each piece carrying its region's speed (where they overlap, the one starting first wins).
public func timeMap(_ segments: [Trim], _ speeds: [SpeedRegion]) -> [Trim] {
    let regions = speeds.sorted { $0.start < $1.start }
    return segments.flatMap { s -> [Trim] in
        var out: [Trim] = [], t = s.start
        for r in regions where r.end > t && r.start < s.end {
            if r.start > t { out.append(Trim(start: t, end: r.start)) }
            let e = min(r.end, s.end)
            out.append(Trim(start: max(t, r.start), end: e, speed: r.speed == 1 ? nil : r.speed))
            t = e
        }
        if t < s.end { out.append(Trim(start: t, end: s.end)) }
        return out.filter { $0.end - $0.start > 1e-6 }
    }
}

extension Trim {
    /// How long this piece plays for.
    public var outputLength: Double { (end - start) / (speed ?? 1) }
}

/// Length of the edited video: the pieces of a `timeMap` (or plain kept segments) back to back, at their speeds.
public func outputDuration(_ segments: [Trim]) -> Double { segments.reduce(0) { $0 + $1.outputLength } }

/// Recording time shown at output time t.
public func outputToSource(_ segments: [Trim], _ t: Double) -> Double {
    var left = max(0, t)
    for s in segments {
        if left < s.outputLength { return s.start + left * (s.speed ?? 1) }
        left -= s.outputLength
    }
    return segments.last?.end ?? t
}

/// Output time at which recording time t plays. Inside a cut it's where the video carries on, before the trim 0.
public func sourceToOutput(_ segments: [Trim], _ t: Double) -> Double {
    var out = 0.0
    for s in segments {
        if t < s.start { return out }
        if t <= s.end { return out + (t - s.start) / (s.speed ?? 1) }
        out += s.outputLength
    }
    return out
}

/// Playback speed at recording time t.
public func speedAt(_ speeds: [SpeedRegion], _ t: Double) -> Double {
    speeds.sorted { $0.start < $1.start }.first { t >= $0.start && t < $0.end }?.speed ?? 1
}

/// The latest click at or before t that's still animating, with its eased-out progress 0…1.
// ponytail: linear scan over click times, which are few.
public func clickAnimation(_ clicks: [Double], _ t: Double, duration: Double = ClickEffect.duration) -> (t: Double, k: Double)? {
    guard let c = clicks.last(where: { $0 <= t }), t - c < duration else { return nil }
    let k = (t - c) / duration
    return (c, 1 - pow(1 - k, 3))
}

/// One zoom per burst of clicks: leads in so it's settled by the click, lingers after, merges clicks closer than `gap`.
public func autoZooms(_ cursor: [CursorSample], duration: Double, scale: Double = 1.8, gap: Double = 1.2) -> [Zoom] {
    var zooms: [Zoom] = []
    for t in clickTimes(cursor) {
        let start = clamp(t - 0.9, 0, duration), end = clamp(t + 2.6, 0, duration)
        if let last = zooms.last, start - last.end < gap { zooms[zooms.count - 1].end = end }
        else { zooms.append(Zoom(start: start, end: end, scale: scale)) }
    }
    return zooms.filter { $0.end - $0.start > 0.3 }
}

/// 0...1 eased weight of one zoom at time t (0 outside, 1 on the plateau).
public func weight(_ s: Zoom, _ t: Double) -> Double {
    guard t > s.start, t < s.end else { return 0 }
    let k = min(t - s.start, s.end - t) / min(Tuning.ramp, (s.end - s.start) / 2.5)
    // smootherstep: zero velocity and acceleration at both ends, so a zoom never kicks off or lands abruptly.
    return k >= 1 ? 1 : k * k * k * (k * (6 * k - 15) + 10)
}

/// The strongest zoom at time t, with its eased weight.
public func activeZoom(_ zooms: [Zoom], _ t: Double) -> (zoom: Zoom, w: Double)? {
    var best: (zoom: Zoom, w: Double)?
    for z in zooms {
        let w = weight(z, t)
        if w > 0, best == nil || 1 + (z.scale - 1) * w > 1 + (best!.zoom.scale - 1) * best!.w { best = (z, w) }
    }
    return best
}

public func zoomAt(_ zooms: [Zoom], _ t: Double) -> Double {
    guard let a = activeZoom(zooms, t) else { return 1 }
    return 1 + (a.zoom.scale - 1) * a.w
}

public func cursorAt(_ cursor: [CursorSample], _ t: Double) -> Point {
    guard let first = cursor.first, let last = cursor.last else { return Point(x: 0.5, y: 0.5) }
    if t <= first.t { return Point(x: first.x, y: first.y) }
    if t >= last.t { return Point(x: last.x, y: last.y) }
    var lo = 0, hi = cursor.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if cursor[mid].t <= t { lo = mid } else { hi = mid }
    }
    let a = cursor[lo], b = cursor[hi]
    let k = (t - a.t) / (b.t - a.t == 0 ? 1 : b.t - a.t)
    return Point(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
}

/// Times the cursor moved or a button changed: the moments it stops being idle.
public func cursorActivity(_ cursor: [CursorSample]) -> [Double] {
    cursor.indices.filter { i in
        i == 0 || cursor[i].x != cursor[i - 1].x || cursor[i].y != cursor[i - 1].y || cursor[i].down != cursor[i - 1].down
    }.map { cursor[$0].t }
}

/// Cursor opacity at t: fades out over `fade` once it's been idle for `delay`, and back in just before it next moves.
// ponytail: linear scans over the activity times, a binary search if long recordings make preview stutter.
public func cursorOpacity(_ activity: [Double], _ t: Double, delay: Double, fade: Double = 0.2) -> Double {
    let since = activity.last { $0 <= t }.map { t - $0 } ?? .infinity
    let until = activity.first { $0 > t }.map { $0 - t } ?? .infinity
    return max(clamp(1 - (since - delay) / fade, 0, 1), clamp(1 - until / fade, 0, 1))
}

public func toCrop(_ p: Point, _ c: NRect) -> Point { Point(x: (p.x - c.x) / c.w, y: (p.y - c.y) / c.h) }

/// The cursor sampled every 1/fps s through two cascaded low-pass stages with time constant `follow` each.
/// That's ≈ a critically damped spring: it accelerates into a move instead of jumping to full speed the way a
/// single exponential filter does. Look points up with `pathAt`. Smoothing runs in output time, so it follows as
/// closely in a part played at `speeds` as at 1×.
public func smoothPath(_ cursor: [CursorSample], duration: Double, fps: Double, follow: Double, speeds: [SpeedRegion] = []) -> [Point] {
    let n = max(1, Int((duration * fps).rounded(.up)))
    var out: [Point] = []
    out.reserveCapacity(n + 1)
    var ax = Double.nan, ay = 0.0, fx = 0.0, fy = 0.0
    for i in 0...n {
        let t = min(duration, Double(i) / fps)
        let alpha = follow > 0 ? 1 - exp(-1 / fps / speedAt(speeds, t) / follow) : 1
        let c = cursorAt(cursor, t)
        if ax.isNaN { (ax, ay, fx, fy) = (c.x, c.y, c.x, c.y) }
        ax += (c.x - ax) * alpha; ay += (c.y - ay) * alpha
        fx += (ax - fx) * alpha; fy += (ay - fy) * alpha
        out.append(Point(x: fx, y: fy))
    }
    return out
}

/// Linear interpolation into a path from `smoothPath` (O(1)).
public func pathAt(_ path: [Point], fps: Double, _ t: Double) -> Point {
    guard let last = path.last else { return Point(x: 0.5, y: 0.5) }
    let f = max(0, t * fps), i = Int(f)
    if i >= path.count - 1 { return last }
    let a = path[i], b = path[i + 1], k = f - Double(i)
    return Point(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
}

/// The cursor image shown at t: the last one set at or before it. `changes` are the samples that set an image.
// ponytail: linear scan, fine while shape changes number in the hundreds.
public func cursorImageAt(_ changes: [CursorSample], _ t: Double) -> Int? {
    (changes.last { $0.t <= t } ?? changes.first)?.image
}

/// Camera over the whole recording: zoom level plus a smoothed focus point in crop-normalized coords.
/// `cursor` and `duration` are the recording's; the path runs in timeline time, past any inserted clips (see `InsertedClip`).
public func cameraPath(_ cursor: [CursorSample], _ edits: Edits, duration: Double) -> [CameraPoint] {
    let cursor = edits.timelineCursor(cursor), duration = edits.timelineDuration(duration)
    // Zooms ease in output time, so one in a fast part still takes its time to land. Cuts are left out of the map:
    // there the camera carries on as if the part were still there.
    let speeds = edits.speeds ?? [], warp = timeMap([Trim(start: 0, end: max(duration, edits.trim.end))], speeds)
    let zooms = joiningTouching(edits.zooms).map { z in
        var z = z; (z.start, z.end) = (sourceToOutput(warp, z.start), sourceToOutput(warp, z.end)); return z
    }
    let fps = Tuning.cameraFPS
    let smooth = smoothPath(cursor, duration: duration, fps: fps, follow: Tuning.follow, speeds: speeds)
    var out: [CameraPoint] = []
    out.reserveCapacity(smooth.count)
    for (i, p) in smooth.enumerated() {
        let t = min(duration, Double(i) / fps)
        let c = toCrop(p, edits.crop), fx = c.x, fy = c.y
        let a = activeZoom(zooms, sourceToOutput(warp, t))
        let z = a.map { 1 + ($0.zoom.scale - 1) * $0.w } ?? 1
        // A pinned zoom eases from the cursor-following camera onto its focus, in step with the zoom itself.
        var x = fx, y = fy
        if let a, let f = a.zoom.focus { x = fx + (f.x - fx) * a.w; y = fy + (f.y - fy) * a.w }
        let half = 0.5 / z
        out.append(CameraPoint(t: t, z: z, x: clamp(x, half, 1 - half), y: clamp(y, half, 1 - half)))
    }
    return out
}

/// Linear interpolation into a uniformly sampled camera path (O(1)).
public func cameraAt(_ path: [CameraPoint], _ t: Double) -> CameraPoint {
    guard let first = path.first else { return CameraPoint(t: t, z: 1, x: 0.5, y: 0.5) }
    let f = max(0, t * Tuning.cameraFPS)
    let i = Int(f)
    if i >= path.count - 1 { return path[path.count - 1] }
    if t <= first.t { return first }
    let a = path[i], b = path[i + 1], k = f - Double(i)
    return CameraPoint(t: t, z: a.z + (b.z - a.z) * k, x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
}

/// Export sizes, by the long side of the output frame. The output is never larger than the recording at zoom 1.
public enum ExportResolution: String, CaseIterable, Codable, Sendable {
    case p720, p1080, p1440, p2160
    public var longSide: Double {
        switch self { case .p720: 1280; case .p1080: 1920; case .p1440: 2560; case .p2160: 3840 }
    }
    public var label: String {
        switch self { case .p720: "720p"; case .p1080: "1080p"; case .p1440: "1440p"; case .p2160: "4K" }
    }
    /// The editor's preview and GIFs render at this size.
    public static let preview = ExportResolution.p1080
}

/// Video quality as a target bitrate.
public enum ExportQuality: String, CaseIterable, Codable, Sendable {
    case standard, high, maximum
    public var label: String { rawValue.capitalized }
    /// Bits per pixel per frame for H.264. Screen recordings are mostly flat UI, so these are generous.
    var bitsPerPixel: Double {
        switch self { case .standard: 0.08; case .high: 0.14; case .maximum: 0.25 }
    }
}

/// Target video bitrate in bits per second. HEVC gets the same quality from about 60% of the bits.
public func exportBitrate(width: Int, height: Int, fps: Double, _ q: ExportQuality, hevc: Bool) -> Int {
    Int(Double(width * height) * min(60, max(1, fps)) * q.bitsPerPixel * (hevc ? 0.6 : 1))
}

/// A rough size for a video export: its target bitrate plus 160 kbps of audio, over `seconds`.
public func videoEstimatedBytes(width: Int, height: Int, fps: Double, seconds: Double, _ q: ExportQuality, hevc: Bool) -> Int {
    Int(Double(exportBitrate(width: width, height: height, fps: fps, q, hevc: hevc) + 160_000) * max(0, seconds) / 8)
}

/// A name typed for an exported file, made safe to save: no slashes or colons, no leading dot, trimmed.
public func exportFileName(_ name: String, fallback: String = "Recording") -> String {
    let s = name.replacingOccurrences(of: #"[/:\x00-\x1F]"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"^\.+"#, with: "", options: .regularExpression)
    return s.isEmpty ? fallback : String(s.prefix(200))
}

/// "Keep Both": the first of `name`, "name 2", "name 3"… that `exists` says is free.
public func keepBothName(_ name: String, exists: (String) -> Bool) -> String {
    var n = 2, candidate = name
    while exists(candidate) { candidate = "\(name) \(n)"; n += 1 }
    return candidate
}

/// The output frame for a recording. `maxLongSide` caps the frame's longer side (see `ExportResolution`).
public func outputSize(width: Int, height: Int, _ edits: Edits, maxLongSide: Double = ExportResolution.preview.longSide) -> OutputSize {
    let cw = Double(width) * edits.crop.w, ch = Double(height) * edits.crop.h
    guard let ratio = parseAspect(edits.aspect) else {
        // Match the recording: padding is a fraction of the content width on every side.
        // The padded frame is cw·(1+2p) wide and ch + 2·cw·p tall; scale so its longer side fits.
        let side = cw * edits.padding
        let k = min(1, maxLongSide / max(cw + 2 * side, ch + 2 * side))
        let contentW = evenDown(cw * k), contentH = evenDown(ch * k)
        let pad = Int((Double(contentW) * edits.padding).rounded())
        return OutputSize(contentW: contentW, contentH: contentH, x: pad, y: pad, width: contentW + 2 * pad, height: contentH + 2 * pad)
    }
    // Fixed frame: long side as large as the padded recording needs (capped), recording fitted and centred inside.
    let long = min(maxLongSide, max(cw, ch) * (1 + 2 * edits.padding))
    let W = evenDown(ratio >= 1 ? long : long * ratio), H = evenDown(ratio >= 1 ? long / ratio : long)
    let pad = Double(min(W, H)) * edits.padding
    let k = min((Double(W) - 2 * pad) / cw, (Double(H) - 2 * pad) / ch)
    let contentW = evenDown(cw * k), contentH = evenDown(ch * k)
    return OutputSize(contentW: contentW, contentH: contentH, x: (W - contentW) / 2, y: (H - contentH) / 2, width: W, height: H)
}

public func defaultEdits(duration: Double, cursor: [CursorSample], hasCamera: Bool = false, cornerRadius: Double? = nil) -> Edits {
    var e = Edits(trim: Trim(start: 0, end: duration), zooms: autoZooms(cursor, duration: duration), cursorHighlight: false,
                  camera: hasCamera ? CameraStyle() : nil, cornerRadius: cornerRadius, gradient: BackgroundGradient.presets[0])
    e.cursorIdleHide = 2
    e.clickEffect = .ripple
    return e
}

/// A group of settings in the inspector, which its Reset puts back together.
public enum SettingsGroup: String, CaseIterable, Sendable { case look, cursor, webcam, captions, shortcuts, sound }

extension Edits {
    /// These edits with `group`'s settings as in `d`, the edits the recording starts with. What was made stays: zooms,
    /// caption lines (and whether they show), the music file and where it plays.
    public func resetting(_ group: SettingsGroup, to d: Edits) -> Edits {
        var e = self
        switch group {
        case .look:
            (e.aspect, e.padding, e.cornerRadius, e.shadow, e.shadowSoftness) = (d.aspect, d.padding, d.cornerRadius, d.shadow, d.shadowSoftness)
            (e.background, e.backgroundImage, e.gradient, e.backgroundBlur) = (d.background, d.backgroundImage, d.gradient, d.backgroundBlur)
        case .cursor:
            (e.cursorStyle, e.cursorHighlight, e.clickEffect, e.cursorIdleHide) = (d.cursorStyle, d.cursorHighlight, d.clickEffect, d.cursorIdleHide)
        case .webcam:
            if e.camera != nil { e.camera = d.camera ?? CameraStyle() }
        case .captions:
            if let c = e.captions {
                var fresh = Captions(lines: c.lines)
                fresh.visible = c.visible
                e.captions = fresh
            }
        case .shortcuts:
            e.keystrokes = d.keystrokes
        case .sound:
            (e.micVolume, e.systemVolume, e.micCleanup) = (d.micVolume, d.systemVolume, d.micCleanup)
            if let a = e.audio {
                let fresh = AudioTrack(path: a.path, fileDuration: a.fileDuration, at: a.at, from: a.from, length: a.length)
                (e.audio!.volume, e.audio!.fadeIn, e.audio!.fadeOut, e.audio!.duck) = (fresh.volume, fresh.fadeIn, fresh.fadeOut, fresh.duck)
            }
        }
        return e
    }
}

extension Edits {
    /// The edits a saved Look starts from: nothing of a recording, only the appearance settings `withLook` copies.
    /// It has a webcam and captions, so their style is kept even when the look is saved from a recording without them.
    public static var lookTemplate: Edits {
        var e = Edits(trim: Trim(start: 0, end: 0), camera: CameraStyle())
        e.captions = Captions(lines: [])
        return e
    }

    /// These edits with the appearance of `l` (a Look): the Look tab's settings, the cursor's, the webcam bubble's
    /// style and place, the caption and shortcut style, and the microphone clean-up. What belongs to this recording
    /// stays: trim, crop, zooms, text, annotations, music, and whether the webcam and captions show. A webcam or caption
    /// style only applies where the recording has one.
    public func withLook(of l: Edits) -> Edits {
        var e = self
        for g in [SettingsGroup.look, .cursor, .shortcuts] { e = e.resetting(g, to: l) }
        if let mine = e.camera, var c = l.camera {
            c.visible = mine.visible
            e.camera = c
        }
        if let c = l.captions, e.captions != nil {
            (e.captions!.position, e.captions!.size, e.captions!.style, e.captions!.srt) = (c.position, c.size, c.style, c.srt)
        }
        e.micCleanup = l.micCleanup
        return e
    }
}

public let imageExtensions = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"]

/// Human-readable problems; empty means renderable.
/// `duration`: the recording's own length; inserted clips add theirs.
public func validateEdits(_ e: Edits, duration: Double) -> [String] {
    var errs: [String] = []
    let ok = { (v: Double) in v.isFinite }
    let t = e.trim, c = e.crop
    let clips = e.allClips
    for (i, k) in clips.enumerated() {
        if ![k.at, k.length].allSatisfy(ok) || k.at < 0 || k.length < 0.1 || k.width < 1 || k.height < 1 { errs.append("Clip \(i + 1): its time or size is out of range.") }
        else if i > 0, k.at < clips[i - 1].end - 0.001 { errs.append("Clip \(i + 1): it overlaps the clip before it.") }
        if let v = k.volume, !(v.isFinite && (0...1).contains(v)) { errs.append("Clip \(i + 1): volume must be between 0% and 100%.") }
    }
    if !ok(t.start) || !ok(t.end) || t.start < 0 || t.end > e.timelineDuration(duration) + 0.05 { errs.append("Trim must stay within the recording.") }
    else if outputDuration(e.timeMap) < 0.5 { errs.append("Trimmed clip must be at least 0.5 s long.") }
    if ![c.x, c.y, c.w, c.h].allSatisfy(ok) || c.x < 0 || c.y < 0 || c.w < 0.05 || c.h < 0.05 || c.x + c.w > 1.0001 || c.y + c.h > 1.0001 {
        errs.append("Crop must be inside the frame and at least 5% wide and tall.")
    }
    for (i, z) in e.zooms.enumerated() {
        if !ok(z.start) || !ok(z.end) || z.end <= z.start { errs.append("Zoom \(i + 1): end must be after start.") }
        if !ok(z.scale) || z.scale < 1 || z.scale > 4 { errs.append("Zoom \(i + 1): scale must be between 1× and 4×.") }
        if let f = z.focus, !(0...1).contains(f.x) || !(0...1).contains(f.y) { errs.append("Zoom \(i + 1): focus point is outside the frame.") }
    }
    if let c = e.captions {
        if !(c.size.isFinite && Captions.sizes.contains(c.size)) { errs.append("Caption size must be between 50% and 200%.") }
        if c.lines.contains(where: { !$0.start.isFinite || !$0.end.isFinite || $0.end <= $0.start }) { errs.append("Every caption line must end after it starts.") }
    }
    if let k = e.keystrokes, !(k.size.isFinite && KeystrokeStyle.sizes.contains(k.size)) { errs.append("Shortcut size must be between 50% and 200%.") }
    for (i, r) in (e.speeds ?? []).enumerated() {
        if !ok(r.start) || !ok(r.end) || r.end <= r.start { errs.append("Speed \(i + 1): end must be after start.") }
        if !SpeedRegion.speeds.contains(r.speed) { errs.append("Speed \(i + 1): pick one of the listed speeds.") }
    }
    if !ok(e.padding) || e.padding < 0 || e.padding > 0.25 { errs.append("Padding must be between 0% and 25%.") }
    if let r = e.cornerRadius, !(r.isFinite && cornerRadii.contains(r)) { errs.append("Corner radius must be between 0% and 15%.") }
    if let c = e.camera, !(c.size.isFinite && CameraStyle.sizes.contains(c.size)) { errs.append("Webcam size must be between 10% and 50%.") }
    if let v = e.shadow, !(v.isFinite && DropShadow.range.contains(v)) { errs.append("Shadow must be between 0% and 100%.") }
    if let v = e.shadowSoftness, !(v.isFinite && DropShadow.range.contains(v)) { errs.append("Shadow softness must be between 0% and 100%.") }
    if let v = e.camera?.shadow, !(v.isFinite && DropShadow.range.contains(v)) { errs.append("Webcam shadow must be between 0% and 100%.") }
    if let v = e.camera?.margin, !(v.isFinite && CameraStyle.margins.contains(v)) { errs.append("Webcam margin must be between 0% and 15%.") }
    if let v = e.camera?.roundness, !(v.isFinite && (0...1).contains(v)) { errs.append("Webcam roundness must be between 0% and 100%.") }
    if let p = e.camera?.center, !((0...1).contains(p.x) && (0...1).contains(p.y)) { errs.append("Webcam position is off-canvas.") }
    if let g = e.gradient {
        if ![g.from, g.to].allSatisfy(isHexColour) { errs.append("Gradient colours must be #rrggbb.") }
        if !(g.angle.isFinite && (0...360).contains(g.angle)) { errs.append("Gradient angle must be between 0° and 360°.") }
    }
    if let v = e.backgroundBlur, !(v.isFinite && (0...1).contains(v)) { errs.append("Background blur must be between 0% and 100%.") }
    if let a = e.aspect, parseAspect(a) == nil { errs.append("Aspect ratio must be one of \(aspectRatios.map(\.value).joined(separator: ", ")).") }
    if !isHexColour(e.background) { errs.append("Background must be a #rrggbb colour.") }
    if let img = e.backgroundImage, !imageExtensions.contains((img as NSString).pathExtension.lowercased()) {
        errs.append("Background image must be HEIC, JPEG, PNG, TIFF or WebP.")
    }
    if let v = e.micVolume, !(v.isFinite && (0...1).contains(v)) { errs.append("Microphone volume must be between 0% and 100%.") }
    if let v = e.systemVolume, !(v.isFinite && (0...1).contains(v)) { errs.append("System audio volume must be between 0% and 100%.") }
    if let m = e.audio {
        if !AudioTrack.extensions.contains((m.path as NSString).pathExtension.lowercased()) { errs.append("Audio must be M4A, MP3, WAV, AIFF, CAF or AAC.") }
        if ![m.at, m.from, m.length, m.fileDuration].allSatisfy(ok) || m.at < 0 || m.from < 0 || m.length < 0.1 || m.from + m.length > m.fileDuration + 0.05 {
            errs.append("Audio: its start and length must stay within the file.")
        }
        if !(m.volume.isFinite && (0...1).contains(m.volume)) { errs.append("Audio volume must be between 0% and 100%.") }
        if !(m.fadeIn.isFinite && AudioTrack.fades.contains(m.fadeIn)) || !(m.fadeOut.isFinite && AudioTrack.fades.contains(m.fadeOut)) {
            errs.append("Audio fades must be between 0 and 10 seconds.")
        }
    }
    for (i, a) in e.allAnnotations.enumerated() {
        let n = "Annotation \(i + 1)"
        if !ok(a.start) || !ok(a.end) || a.end <= a.start { errs.append("\(n): end must be after start.") }
        if ![a.x, a.y, a.w, a.h, a.rotation].allSatisfy(ok) || a.x < -0.5 || a.x > 1.5 || a.y < -0.5 || a.y > 1.5 || abs(a.w) > 2 || abs(a.h) > 2 {
            errs.append("\(n): position is off-canvas.")
        } else if a.kind == .arrow ? (abs(a.w) < 0.005 && abs(a.h) < 0.005) : (a.w < 0.005 || a.h < 0.005) {
            errs.append("\(n): it's too small to see.")
        }
        if a.kind == .blur, let k = a.strength, !(k.isFinite && (0...1).contains(k)) { errs.append("\(n): strength must be between 0% and 100%.") }
        if a.kind != .image, !isHexColour(a.color) { errs.append("\(n): colour must be #rrggbb.") }
        if a.kind != .image, !(a.stroke.isFinite && Annotation.strokes.contains(a.stroke)) { errs.append("\(n): line width is out of range.") }
        if let f = a.fade, !(f.isFinite && Annotation.fades.contains(f)) { errs.append("\(n): fade must be between 0 and 2 seconds.") }
        if a.kind == .video {
            if let v = a.video {
                if ![v.at, v.length].allSatisfy(ok) || v.length < 0.1 || v.width < 1 || v.height < 1 { errs.append("\(n): the video's length or size is out of range.") }
                else if a.start < v.at - 0.01 || a.end > v.end + 0.01 { errs.append("\(n): it plays past the ends of its video.") }
                if [v.volume, v.roundness, v.shadow].contains(where: { $0.map { !($0.isFinite && (0...1).contains($0)) } ?? false }) {
                    errs.append("\(n): sound, corners and shadow must be between 0% and 100%.")
                }
            } else { errs.append("\(n): it has no video.") }
        }
        if a.kind == .image, !(a.image.map { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) } ?? false) {
            errs.append("\(n): pick a HEIC, JPEG, PNG, TIFF or WebP image.")
        }
    }
    for (i, m) in e.allMarkers.enumerated() {
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > Marker.maxName { errs.append("Chapter \(i + 1): its name must be 1–\(Marker.maxName) characters.") }
        if !(m.t.isFinite && m.t >= 0) { errs.append("Chapter \(i + 1): its time is out of range.") }
    }
    for (i, k) in e.callouts.enumerated() {
        let text = k.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > Callout.maxText { errs.append("Callout \(i + 1): text must be 1–\(Callout.maxText) characters.") }
        if !ok(k.start) || !ok(k.end) || k.end <= k.start { errs.append("Callout \(i + 1): end must be after start.") }
        if !(0...1).contains(k.x) || !(0...1).contains(k.y) { errs.append("Callout \(i + 1): position is off-canvas.") }
    }
    return errs
}

func isHexColour(_ s: String) -> Bool { s.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil }

/// How the inspector writes slider values, one way per kind, so a column of readouts reads alike.
public enum Readout {
    public static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    /// For small fractions such as line widths, where whole percents would all read 0% or 1%.
    public static func finePercent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    public static func scale(_ v: Double) -> String { String(format: "%.1f×", v) }
    public static func seconds(_ v: Double) -> String { String(format: "%g s", (v * 100).rounded() / 100) }
    public static func degrees(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    /// Pixel sizes, without the locale's thousands separator: "2880×1800", never "2.880×1.800".
    public static func size(_ w: Int, _ h: Int) -> String { "\(w)×\(h)" }
}

/// "m:ss", or "h:mm:ss" from an hour up.
public func formatTime(_ s: Double) -> String {
    let s = Int(max(0, s))
    return s >= 3600 ? "\(s / 3600):" + String(format: "%02d:%02d", s / 60 % 60, s % 60) : "\(s / 60):" + String(format: "%02d", s % 60)
}

extension Edits {
    /// Every time the timeline has an edge at, sorted: the trim, splits, the edges of zooms, callouts, annotations and
    /// the extra audio, and chapters. ↑ / ↓ jump between them, and drags snap to them.
    public var editPoints: [Double] {
        var t = keptSegments.flatMap { [$0.start, $0.end] }
        for i in zooms as [any Timed] + callouts + allAnnotations { t += [i.start, i.end] }
        if let a = audio { t += [a.at, a.end] }
        t += allMarkers.map(\.t)
        return Array(Set(t.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }
}

/// How far to move the edges at `xs` so the nearest one lands on a target within `within`, or nil when none is that close.
public func snapOffset(_ xs: [Double], to targets: [Double], within: Double) -> (offset: Double, target: Double)? {
    var best: (offset: Double, target: Double)?
    for x in xs {
        for t in targets where abs(t - x) <= within && abs(t - x) < abs(best?.offset ?? .infinity) { best = (t - x, t) }
    }
    return best
}

/// Markdown written next to each export.
public func summaryMarkdown(title: String, createdAt: Date, edits: Edits, video: String, poster: String?, transcript: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = [
        "# \(title)", "",
        "- Recorded: \(f.string(from: createdAt))",
        "- Length: \(formatTime(outputDuration(edits.timeMap)))",
        "- Video: [\(video)](\(video.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? video))",
        "",
    ]
    if let poster { lines += ["![Poster](\(poster.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? poster))", ""] }
    let marks = (edits.zooms.map { (t: $0.start, label: "Zoom \(String(format: "%.1f", $0.scale))×") }
        + edits.callouts.map { (t: $0.start, label: "Callout: \($0.text)") })
        .filter { m in edits.keptSegments.contains { m.t >= $0.start && m.t <= $0.end } }
        .sorted { $0.t < $1.t }
    if !marks.isEmpty {
        lines += ["## Moments", ""] + marks.map { "- \(formatTime(sourceToOutput(edits.timeMap, $0.t))) — \($0.label)" } + [""]
    }
    let chapters = edits.chapters(title: title)
    if !chapters.isEmpty { lines += ["## Chapters", ""] + chapters.map { "\(chapterTime($0.start)) \($0.name)" } + [""] }
    lines += ["## Transcript", "", transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No transcript._" : transcript, ""]
    return lines.joined(separator: "\n")
}

/// Undo and redo for `Edits`. Each step stores the edits from before it. Changes close together (a slider drag, typing)
/// or made during the same timeline drag join one step.
public struct EditHistory: Sendable {
    public static let mergeWindow = 0.6 // seconds
    public static let limit = 500       // steps kept
    public private(set) var undoStack: [Edits] = []
    public private(set) var redoStack: [Edits] = []
    private var last: (time: Double, drag: Edits?)?

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Notes a change at `time` (seconds, any clock) from `before`. `drag` is the edits where the current timeline drag
    /// began, if one is under way: every change in that drag is one step.
    public mutating func record(_ before: Edits, at time: Double, drag: Edits? = nil) {
        let joins = last.map { l in drag != nil ? l.drag == drag : l.drag == nil && time - l.time < Self.mergeWindow } ?? false
        if !joins {
            undoStack.append(before)
            if undoStack.count > Self.limit { undoStack.removeFirst() }
        }
        last = (time, drag)
        redoStack.removeAll()
    }

    /// The edits to go back to from `current`, or nil when there's nothing to undo.
    public mutating func undo(_ current: Edits) -> Edits? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append(current)
        last = nil
        return e
    }

    public mutating func redo(_ current: Edits) -> Edits? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append(current)
        last = nil
        return e
    }
}

/// The library gallery's sections, in the order shown.
public enum GallerySection: String, CaseIterable, Sendable {
    case recent = "Recently edited", today = "Today", yesterday = "Yesterday", week = "This week", older = "Older"
}

/// Sorts recordings into the gallery's sections as of `now`: the `recent` most recently edited first, then the rest by
/// when they were recorded. "This week" starts on `calendar`'s first weekday. Empty sections are left out.
public func gallerySections<T>(_ items: [T], created: (T) -> Date, edited: (T) -> Date, now: Date,
                               calendar: Calendar = .current, recent: Int = 5) -> [(section: GallerySection, items: [T])] {
    let byEdit = items.indices.sorted { edited(items[$0]) > edited(items[$1]) }
    let top = Set(byEdit.prefix(recent))
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let week = calendar.dateInterval(of: .weekOfYear, for: now)
    func section(_ d: Date) -> GallerySection {
        if calendar.isDate(d, inSameDayAs: now) || d > now { return .today }
        if calendar.isDate(d, inSameDayAs: yesterday) { return .yesterday }
        return week?.contains(d) == true ? .week : .older
    }
    let rest = items.indices.filter { !top.contains($0) }.sorted { created(items[$0]) > created(items[$1]) }
    let groups = [(GallerySection.recent, byEdit.prefix(recent).map { items[$0] })]
        + [GallerySection.today, .yesterday, .week, .older].map { s in (s, rest.filter { section(created(items[$0])) == s }.map { items[$0] }) }
    return groups.filter { !$0.1.isEmpty }.map { (section: $0.0, items: $0.1) }
}

/// Where an arrow key moves the selection in the library: sections of `counts` tiles, each starting on a new row of
/// `columns`, with tiles numbered across all sections. Left and right step through the order; up and down keep the column,
/// or take the last tile of a shorter row. Stays put at the edges.
public func gridMove(_ index: Int, dx: Int, dy: Int, counts: [Int], columns: Int) -> Int {
    let columns = max(1, columns)
    var rows: [(start: Int, count: Int)] = []
    var start = 0
    for n in counts {
        for r in stride(from: 0, to: n, by: columns) { rows.append((start + r, min(columns, n - r))) }
        start += n
    }
    guard let row = rows.firstIndex(where: { index >= $0.start && index < $0.start + $0.count }) else { return index }
    if dx != 0 { return min(max(index + dx, 0), start - 1) }
    let to = row + dy
    guard rows.indices.contains(to) else { return index }
    return rows[to].start + min(index - rows[row].start, rows[to].count - 1)
}

/// A keyboard shortcut pressed while recording, `t` seconds in. Only shortcuts are ever kept (see `shortcutPress`).
public struct ShortcutPress: Codable, Equatable, Sendable {
    public var t: Double
    public var modifiers: [String] // in macOS menu order: ⌃ ⌥ ⇧ ⌘
    public var key: String
    public init(t: Double, modifiers: [String], key: String) { (self.t, self.modifiers, self.key) = (t, modifiers, key) }
    /// One keycap each, e.g. ["⌘", "⇧", "4"] drawn as ⌘ ⇧ 4.
    public var caps: [String] { modifiers + [key] }
}

/// The press as a shortcut, or nil for ordinary typing: it has to hold ⌘, ⌃ or ⌥ (⇧ alone is typing), or be Esc.
/// `keyCode` is the virtual key code; `characters` what the key types without modifiers.
public func shortcutPress(t: Double, keyCode: Int, characters: String, command: Bool, control: Bool, option: Bool, shift: Bool) -> ShortcutPress? {
    let key = keyName(keyCode: keyCode, characters: characters)
    guard command || control || option || key == "esc", !key.isEmpty else { return nil }
    let mods = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")].filter(\.0).map(\.1)
    return ShortcutPress(t: t, modifiers: mods, key: key)
}

/// How a key is shown on its keycap: a symbol for the special keys, otherwise the character it types, upper-cased.
public func keyName(keyCode: Int, characters: String) -> String {
    let special: [Int: String] = [
        51: "⌫", 117: "⌦", 53: "esc", 48: "⇥", 36: "↩", 76: "⌤", 49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    if let s = special[keyCode] { return s }
    return characters.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).uppercased()
}

/// The shortcuts overlay on the video.
public struct KeystrokeStyle: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable { case bottomCenter, bottomLeft, bottomRight }
    public static let duration = 1.2, fade = 0.15
    public static let sizes = 0.5...2.0
    public var visible = true
    public var position = Position.bottomCenter
    public var size = 1.0
    public init() {}
}

/// The shortcut showing at t and its opacity: each shows for `duration` with short fades, until the next replaces it.
public func keystrokeAt(_ keys: [ShortcutPress], _ t: Double) -> (press: ShortcutPress, alpha: Double)? {
    guard let i = keys.lastIndex(where: { $0.t <= t }) else { return nil }
    let k = keys[i], age = t - k.t, d = KeystrokeStyle.duration, f = KeystrokeStyle.fade
    guard age < d else { return nil }
    let replaced = i + 1 < keys.count && keys[i + 1].t < k.t + d // the next one cuts it short, so no fade out
    return (k, min(1, age / f, replaced ? 1 : (d - age) / f))
}

/// Where the keycaps go on a `canvasW`×`canvasH` frame: their top-left corner, top-left origin.
public func keystrokeOrigin(canvasW: Double, canvasH: Double, w: Double, h: Double, _ position: KeystrokeStyle.Position) -> (x: Double, y: Double) {
    let y = canvasH * 0.94 - h, margin = canvasW * 0.04
    switch position {
    case .bottomCenter: return ((canvasW - w) / 2, y)
    case .bottomLeft: return (margin, y)
    case .bottomRight: return (canvasW - margin - w, y)
    }
}

/// Where an item `length` seconds long goes when pasted at `t`: starting there, moved back to fit before `duration`.
public func pasteRange(length: Double, at t: Double, duration: Double) -> (start: Double, end: Double) {
    let length = min(length, duration), start = max(0, min(t, duration - length))
    return (start, start + length)
}

/// The editor's inspector folds away when the window narrows past the point where it fits beside the preview, as when
/// tiled to half a 13" screen, and comes back when the window widens again if it was folded rather than hidden by hand.
/// In between, ⌥⌘I still shows it, floating over the preview, since the two don't fit side by side.
public struct InspectorFit: Equatable, Sendable {
    /// Below this window width the inspector would squeeze the preview and the timeline's buttons.
    public static let roomyWidth = 900.0

    public private(set) var narrow = false
    private var folded = false
    public init() {}

    /// Updates `shown` for a window `width` points wide. Only crossing the breakpoint changes it.
    public mutating func fit(width: Double, shown: inout Bool) {
        let narrow = width < Self.roomyWidth
        guard narrow != self.narrow else { return }
        self.narrow = narrow
        if narrow {
            folded = shown
            shown = false
        } else {
            if folded { shown = true }
            folded = false
        }
    }
}
