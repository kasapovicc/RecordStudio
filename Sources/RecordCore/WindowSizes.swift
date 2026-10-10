import Foundation

/// A size to resize a window to before recording it, in pixels: the size the video comes out at.
public struct SizePreset: Hashable, Sendable {
    public var width, height: Int
    public var name: String
    public init(_ width: Int, _ height: Int, _ name: String) { (self.width, self.height, self.name) = (width, height, name) }

    public static let all = [
        SizePreset(1280, 720, "720p, 16:9"), SizePreset(1920, 1080, "1080p, 16:9"), SizePreset(2560, 1440, "1440p, 16:9"),
        SizePreset(1440, 900, "16:10"), SizePreset(1080, 1080, "Square"), SizePreset(1080, 1920, "Vertical, 9:16"),
    ]

    public var size: String { "\(width) × \(height)" }

    /// How it's remembered per app ("1920x1080"); a size that isn't in the list reads back as Custom.
    public var key: String { "\(width)x\(height)" }
    public init?(key: String) {
        let parts = key.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
        self = Self.all.first { $0.width == parts[0] && $0.height == parts[1] } ?? SizePreset(parts[0], parts[1], "Custom")
    }

    /// The window's size in points on a display with `scale` pixels per point.
    public func points(scale: Double) -> CGSize { CGSize(width: Double(width) / scale, height: Double(height) / scale) }

    /// The window's frame at this size, centred in `area` (the display's visible frame), or nil if it doesn't fit.
    public func centred(in area: CGRect, scale: Double) -> CGRect? {
        let s = points(scale: scale)
        guard s.width <= area.width, s.height <= area.height else { return nil }
        return CGRect(x: (area.midX - s.width / 2).rounded(), y: (area.midY - s.height / 2).rounded(), width: s.width, height: s.height)
    }
}

/// What to say when a window didn't take the size asked for (a minimum size, a fixed-size panel); nil when it did.
/// Sizes are in pixels.
public func resizeShortfall(app: String, asked: SizePreset, got: (width: Int, height: Int)) -> String? {
    let dw = got.width - asked.width, dh = got.height - asked.height
    guard abs(dw) > 1 || abs(dh) > 1 else { return nil }
    let size = "\(got.width) × \(got.height)"
    if dw >= -1 && dh >= -1 { return "\(app) won't go smaller than \(size)." }
    if dw <= 1 && dh <= 1 { return "\(app) won't go bigger than \(size)." }
    return "\(app) kept the window at \(size)."
}
