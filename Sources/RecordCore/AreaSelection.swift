import Foundation

/// A grab handle on the area picker's selection: which way it moves the horizontal and vertical edges (-1 the
/// min edge, 1 the max edge, 0 neither).
public struct AreaHandle: Hashable, Sendable {
    public let x, y: Int
    public static let all = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)].map { AreaHandle(x: $0.0, y: $0.1) }
}

/// Smallest area worth recording, in points; a smaller drag is almost always a slip.
public let minimumArea = 40.0

/// `r` with `handle` dragged by `d`, kept inside `bounds` and at least `minimumArea` each way. With `aspect`
/// (width / height) the shape is kept: corners keep the opposite corner still, edges keep the opposite edge and
/// stay centred the other way.
public func resizing(_ r: CGRect, _ handle: AreaHandle, by d: CGSize, aspect: Double?, in bounds: CGRect) -> CGRect {
    let sx = Double(handle.x), sy = Double(handle.y)
    // The point that stays still, and how much room there is from it to the bounds.
    let ax = handle.x < 0 ? r.maxX : handle.x > 0 ? r.minX : r.midX
    let ay = handle.y < 0 ? r.maxY : handle.y > 0 ? r.minY : r.midY
    func room(_ s: Int, _ a: Double, _ lo: Double, _ hi: Double) -> Double { s < 0 ? a - lo : s > 0 ? hi - a : 2 * min(a - lo, hi - a) }
    let maxW = room(handle.x, ax, bounds.minX, bounds.maxX), maxH = room(handle.y, ay, bounds.minY, bounds.maxY)
    var w = max(r.width + sx * d.width, 1), h = max(r.height + sy * d.height, 1)
    if let aspect {
        if handle.x != 0 { h = w / aspect } else { w = h * aspect }
        let up = max(1, minimumArea / w, minimumArea / h), down = min(1, maxW / (w * up), maxH / (h * up))
        (w, h) = (w * up * down, h * up * down)
    } else {
        w = min(max(w, minimumArea), maxW)
        h = min(max(h, minimumArea), maxH)
    }
    let x = handle.x < 0 ? ax - w : handle.x > 0 ? ax : ax - w / 2
    let y = handle.y < 0 ? ay - h : handle.y > 0 ? ay : ay - h / 2
    return CGRect(x: x, y: y, width: w, height: h)
}

/// `r` moved by `d`, stopping at the edges of `bounds`.
public func moving(_ r: CGRect, by d: CGSize, in bounds: CGRect) -> CGRect {
    CGRect(x: min(max(r.minX + d.width, bounds.minX), bounds.maxX - r.width),
           y: min(max(r.minY + d.height, bounds.minY), bounds.maxY - r.height), width: r.width, height: r.height)
}

/// A rectangle of `size` centred on `centre` as far as `bounds` allows, or nil if it doesn't fit at all.
public func placing(_ size: CGSize, around centre: CGPoint, in bounds: CGRect) -> CGRect? {
    guard size.width <= bounds.width, size.height <= bounds.height else { return nil }
    let r = CGRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(), width: size.width, height: size.height)
    return moving(r, by: .zero, in: bounds)
}
