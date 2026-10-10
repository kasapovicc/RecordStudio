import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import RecordCore
import SwiftUI
import Synchronization

/// Draws one output frame from one source frame. Shared by the live preview and export, so they match exactly.
/// Core Image samples with sub-pixel precision on the GPU, so slow zooms and pans don't step.
public final class FrameRenderer: @unchecked Sendable {
    public let edits: Edits
    public let size: OutputSize
    private let cursor: [CursorSample]
    private let activity: [Double]
    private let shapes: [(image: CIImage, hotX: Double, hotY: Double)]
    private let shapeChanges: [CursorSample]
    private let pointer: [Point] // smoothed cursor, when it's redrawn
    private let clicks: [Double]
    private let path: [CameraPoint]
    private let srcW: Double, srcH: Double
    private var background: CIImage
    private let callouts: [(Callout, CIImage)]
    /// Drawn in order. Shapes and images are drawn once, here; a video overlay has its index in `Edits.videoOverlays`
    /// instead, for its frame at render time.
    private let annotations: [(a: Annotation, image: CIImage?, overlay: Int?)]
    private let blurs: [Annotation]
    private let keys: [ShortcutPress]
    private let keycaps: [String: CIImage] // drawn once per distinct shortcut
    private let captions: Captions?
    private let captionImage = Mutex<(line: CaptionLine, image: CIImage?)?>(nil) // the line showing, drawn once
    private var shadow: CIImage?
    private var contentOrigin = CGPoint.zero
    private let mask: CIImage?
    private let sourceMask: CIImage?

    /// `windowCornerPx`: for window recordings, the window's own corner radius in source pixels. The area outside
    /// those corners is black in the capture, so it's masked away before anything else (it stays hidden when zoomed).
    /// `maxLongSide` caps the output frame (export resolution); the preview uses the default.
    /// `cursorImages`: recordings made without the system cursor have it redrawn from these; older ones have none.
    /// `cursor`, `duration` and `keys` are the recording's; times given to `render` are timeline times (see `InsertedClip`).
    public init(edits: Edits, cursor recorded: [CursorSample], sourceWidth: Int, sourceHeight: Int, duration: Double, windowCornerPx: Double? = nil,
                maxLongSide: Double = ExportResolution.preview.longSide, cursorImages: [CursorImage] = [], keys: [ShortcutPress] = []) {
        self.edits = edits
        let cursor = edits.timelineCursor(recorded)
        self.cursor = cursor
        self.srcW = Double(sourceWidth)
        self.srcH = Double(sourceHeight)
        let size = outputSize(width: sourceWidth, height: sourceHeight, edits, maxLongSide: maxLongSide)
        self.size = size
        path = cameraPath(recorded, edits, duration: duration)
        activity = cursorActivity(cursor)
        shapes = cursorImages.map { (CIImage(data: $0.png) ?? .empty(), $0.hotX, $0.hotY) }
        shapeChanges = cursor.filter { $0.image != nil }
        clicks = clickTimes(cursor)
        pointer = shapes.isEmpty ? [] : smoothPath(cursor, duration: edits.timelineDuration(duration), fps: Tuning.cursorFPS,
                                                   follow: (edits.cursorStyle ?? CursorStyle()).follow, speeds: edits.speeds ?? [])
        let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        background = Self.background(edits, canvas: canvas)
        callouts = joiningTouching(edits.callouts).compactMap { k in Self.calloutImage(k.text, canvasWidth: Double(size.width), canvasHeight: Double(size.height)).map { (k, $0) } }
        let marks = joiningTouching(edits.allAnnotations)
        var overlays = 0
        annotations = marks.filter { $0.kind != .blur }.compactMap { a in
            if a.kind == .video {
                guard a.video != nil else { return nil }
                overlays += 1
                return (a, nil, overlays - 1)
            }
            return Self.annotationImage(a, canvas: size).map { (a, $0, nil) }
        }
        blurs = marks.filter { $0.kind == .blur }
        let keyStyle = edits.keystrokes ?? KeystrokeStyle()
        self.keys = keyStyle.visible ? edits.timelineKeys(keys) : []
        var caps: [String: CIImage] = [:]
        for k in self.keys where caps[k.caps.joined()] == nil {
            caps[k.caps.joined()] = Self.keycapImage(k.caps, canvasHeight: Double(size.height) * keyStyle.size)
        }
        keycaps = caps
        captions = edits.captions.flatMap { $0.visible ? $0 : nil }

        // Core Image is bottom-left origin, so flip the content's top-left y.
        let content = CGRect(x: size.x, y: size.height - size.y - size.contentH, width: size.contentW, height: size.contentH)
        contentOrigin = content.origin
        let radius = cornerRadiusPx(size, edits)
        mask = radius > 0.5 ? Self.continuousMask(content, radius: radius) : nil
        sourceMask = windowCornerPx.flatMap { $0 > 0.5 ? Self.continuousMask(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight), radius: $0) : nil }
        // With padding the video floats on the background with a soft shadow, like a window.
        if let sh = frameShadow(size, edits) {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: sh.alpha)).cropped(to: content)
                .transformed(by: .init(translationX: 0, y: -sh.offset))
            blur.radius = Float(sh.radius)
            shadow = blur.outputImage?.cropped(to: canvas)
        } else {
            shadow = nil
        }
        // Background (+ shadow) never changes during playback: flatten it into one bitmap now rather than
        // decoding and scaling a 6K wallpaper on every frame.
        let still = shadow.map { $0.composited(over: background) } ?? background
        if let cg = Self.flattener.createCGImage(still, from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            background = CIImage(cgImage: cg)
        }
        shadow = nil
    }
    private static let flattener = CIContext(options: [.cacheIntermediates: false])

    public func camera(at t: Double) -> CameraPoint { cameraAt(path, t) }

    /// `source` is the raw recorded frame (origin at 0,0); `t` is timeline time. `overlays`: the video overlays' frames
    /// at t, by index in `Edits.videoOverlays`.
    public func render(_ source: CIImage, camera webcam: CIImage? = nil, overlays: [Int: CIImage] = [:], at t: Double) -> CIImage {
        let c = edits.crop
        let cw = srcW * c.w, ch = srcH * c.h
        // Core Image is bottom-left origin; edits are top-left.
        let cropRect = CGRect(x: srcW * c.x, y: srcH * (1 - c.y - c.h), width: cw, height: ch)
        var src = source
        if let sourceMask {
            let m = CIFilter.blendWithAlphaMask()
            m.inputImage = source
            m.backgroundImage = CIImage.empty()
            m.maskImage = sourceMask
            src = m.outputImage ?? source
        }
        var img = src.cropped(to: cropRect)
            .transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))
        // Blurred boxes go on the recording itself, before the cursor and the camera, so they stay over what they hide.
        for b in blurs { img = blur(b, over: img, at: t, crop: cropRect) }

        let cursorAlpha = edits.cursorIdleHide.map { cursorOpacity(activity, t, delay: $0) } ?? 1
        func cursorPoint(_ t: Double) -> Point { toCrop(pointer.isEmpty ? cursorAt(cursor, t) : pathAt(pointer, fps: Tuning.cursorFPS, t), c) }
        let p = cursorPoint(t)
        let click = edits.clickEffect == nil ? nil : clickAnimation(clicks, t)
        if edits.cursorHighlight, !cursor.isEmpty, cursorAlpha > 0 {
            let r = ch * 0.035
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: p.x * cw, y: (1 - p.y) * ch)
            g.radius0 = Float(r - 1.5)
            g.radius1 = Float(r)
            g.color0 = CIColor(red: Brand.red.r, green: Brand.red.g, blue: Brand.red.b, alpha: 0.35 * cursorAlpha)
            g.color1 = .clear
            if let halo = g.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch)) { img = halo.composited(over: img) }
        }
        // A ring that grows from where the click happened and fades as it goes.
        if edits.clickEffect == .ripple, let click {
            let q = cursorPoint(click.t), center = CGPoint(x: q.x * cw, y: (1 - q.y) * ch)
            let r = ch * (0.012 + 0.04 * click.k), width = ch * 0.005
            let color = CIColor(red: Brand.red.r, green: Brand.red.g, blue: Brand.red.b, alpha: 0.9 * (1 - click.k))
            func disc(_ radius: Double) -> CIImage? {
                let g = CIFilter.radialGradient()
                g.center = center
                g.radius0 = Float(radius - 1)
                g.radius1 = Float(radius)
                g.color0 = color
                g.color1 = .clear
                return g.outputImage
            }
            let ring = CIFilter.sourceOutCompositing()
            ring.inputImage = disc(r)
            ring.backgroundImage = disc(r - width)
            if let out = ring.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch)) { img = out.composited(over: img) }
        }
        // Drawn in source pixels before the camera, so it scales with the zoom like the recording does.
        let style = edits.cursorStyle ?? CursorStyle()
        if style.visible, cursorAlpha > 0, let i = cursorImageAt(shapeChanges, t), shapes.indices.contains(i) {
            let s = shapes[i]
            let k = style.size * (edits.clickEffect == .bounce ? click.map { ClickEffect.bounceScale($0.k) } ?? 1 : 1)
            var drawn = s.image.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(.init(
                translationX: p.x * cw - s.hotX * k, y: (1 - p.y) * ch - (s.image.extent.height - s.hotY) * k)))
            // Motion blur from the speed over the last frame, measured in output pixels so zooming in blurs more.
            if let strength = style.motionBlur, strength > 0 {
                let a = cursorPoint(t - 1 / Tuning.cursorFPS)
                let dx = (p.x - a.x) * cw, dy = (p.y - a.y) * ch
                let outScale = Double(size.contentW) / cw * camera(at: t).z
                let radius = CursorStyle.blurRadius(speed: hypot(dx, dy) * outScale, strength: strength) / outScale
                if radius > 0 {
                    let f = CIFilter.motionBlur()
                    f.inputImage = drawn
                    f.radius = Float(radius)
                    f.angle = Float(atan2(-dy, dx)) // Core Image's y points up
                    drawn = f.outputImage ?? drawn
                }
            }
            if cursorAlpha < 1 {
                let f = CIFilter.colorMatrix()
                f.inputImage = drawn
                f.aVector = CIVector(x: 0, y: 0, z: 0, w: cursorAlpha)
                drawn = f.outputImage ?? drawn
            }
            img = drawn.composited(over: img).cropped(to: CGRect(x: 0, y: 0, width: cw, height: ch))
        }
        return framed(img, cw: cw, ch: ch, camera: webcam, overlays: overlays, at: t)
    }

    /// A frame of an inserted clip at timeline time t, in place of the recording: fitted inside the cropped recording's
    /// shape without stretching (black around it), then framed, zoomed and drawn over like the recording, without the
    /// cursor. Nil (its file has gone) is black.
    public func render(clip frame: CIImage?, overlays: [Int: CIImage] = [:], at t: Double) -> CIImage {
        let c = edits.crop
        let cw = srcW * c.w, ch = srcH * c.h, box = CGRect(x: 0, y: 0, width: cw, height: ch)
        var img = CIImage(color: .black).cropped(to: box)
        if let frame, frame.extent.width > 0, frame.extent.height > 0 {
            let e = frame.extent, r = clipFit(width: Double(e.width), height: Double(e.height), inside: cw, ch)
            let k = r.width / Double(e.width)
            img = frame.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(.init(scaleX: k, y: k))
                .concatenating(.init(translationX: r.x, y: ch - r.y - r.height))) // top-left to Core Image's bottom-left
                .cropped(to: box).composited(over: img)
        }
        let cropRect = CGRect(x: srcW * c.x, y: srcH * (1 - c.y - c.h), width: cw, height: ch)
        for b in blurs { img = blur(b, over: img, at: t, crop: cropRect) }
        return framed(img, cw: cw, ch: ch, camera: nil, overlays: overlays, at: t)
    }

    /// The cropped picture (`img`, cw × ch) zoomed by the camera, framed on the background and drawn over.
    private func framed(_ img: CIImage, cw: Double, ch: Double, camera webcam: CIImage?, overlays: [Int: CIImage], at t: Double) -> CIImage {
        var img = img
        // Camera: the visible window is 1/z of the crop, centred on the camera point, scaled to the content size.
        let cam = camera(at: t)
        let ww = cw / cam.z, wh = ch / cam.z
        let wx = cam.x * cw - ww / 2, wy = (1 - cam.y) * ch - wh / 2
        let sx = Double(size.contentW) / ww, sy = Double(size.contentH) / wh
        img = img.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -wx, y: -wy).concatenating(.init(scaleX: sx, y: sy)))
            .cropped(to: CGRect(x: 0, y: 0, width: size.contentW, height: size.contentH))
            .transformed(by: .init(translationX: contentOrigin.x, y: contentOrigin.y))

        var out = background
        if let mask {
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = img
            blend.backgroundImage = out
            blend.maskImage = mask
            out = blend.outputImage ?? img.composited(over: out)
        } else {
            out = img.composited(over: out)
        }

        if let style = edits.camera, style.visible, let webcam {
            out = drawBubble(webcam, style: style, zoom: cam.z, over: out)
        }

        for (a, png, overlay) in annotations {
            let alpha = annotationOpacity(a, at: t)
            guard alpha > 0 else { continue }
            if let overlay {
                if let frame = overlays[overlay], let v = a.video { out = drawOverlay(frame, a, v, alpha: alpha, over: out) }
                continue
            }
            guard let png else { continue }
            var img = png
            if alpha < 1 { // fading: scale the alpha channel
                let f = CIFilter.colorMatrix()
                f.inputImage = png
                f.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
                img = f.outputImage ?? png
            }
            out = img.composited(over: out)
        }

        for (k, png) in callouts where t >= k.start && t <= k.end {
            let W = Double(size.width), H = Double(size.height)
            let o = calloutOrigin(k, w: png.extent.width / W, h: png.extent.height / H)
            let x = o.x * W, y = H * (1 - o.y) - png.extent.height
            out = png.transformed(by: .init(translationX: x.rounded(), y: y.rounded())).composited(over: out)
        }
        // Over everything, like a caption: not zoomed or cropped with the recording.
        if let (img, alpha, o) = keycap(at: t) {
            var cap = img
            if alpha < 1 {
                let f = CIFilter.colorMatrix()
                f.inputImage = img
                f.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
                cap = f.outputImage ?? img
            }
            out = cap.transformed(by: .init(translationX: o.x, y: o.y)).composited(over: out)
        }
        if let (img, o) = captionPlacement(at: t) {
            out = img.transformed(by: .init(translationX: o.x, y: o.y)).composited(over: out)
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// The keycaps showing at t, their opacity and their bottom-left corner on the canvas (bottom-left origin).
    private func keycap(at t: Double) -> (CIImage, alpha: Double, CGPoint)? {
        guard let (k, alpha) = keystrokeAt(keys, t), let img = keycaps[k.caps.joined()] else { return nil }
        let o = keystrokeOrigin(canvasW: Double(size.width), canvasH: Double(size.height), w: img.extent.width, h: img.extent.height,
                                (edits.keystrokes ?? KeystrokeStyle()).position)
        return (img, alpha, CGPoint(x: o.x.rounded(), y: (Double(size.height) - o.y - img.extent.height).rounded()))
    }

    /// The caption line showing at t and its bottom-left corner on the canvas (bottom-left origin): centred, a little in
    /// from the top or bottom edge, and at the bottom above any keycaps.
    private func captionPlacement(at t: Double) -> (CIImage, CGPoint)? {
        guard let c = captions, let line = c.line(at: t), let img = caption(line, c) else { return nil }
        let W = Double(size.width), H = Double(size.height), margin = H * 0.06
        let keycapTop = keycap(at: t).map { $0.0.extent.height + $0.2.y }
        let y = c.position == .top ? H - margin - img.extent.height : max(margin, keycapTop.map { $0 + margin / 3 } ?? 0)
        return (img, CGPoint(x: ((W - img.extent.width) / 2).rounded(), y: y.rounded()))
    }

    /// Where the caption showing at t sits, normalized to the canvas with a top-left origin, so the preview can click it.
    public func captionBox(at t: Double) -> CGRect? {
        guard let (img, o) = captionPlacement(at: t) else { return nil }
        let W = Double(size.width), H = Double(size.height)
        return CGRect(x: o.x / W, y: 1 - (o.y + img.extent.height) / H, width: img.extent.width / W, height: img.extent.height / H)
    }

    /// The image for a caption line, drawn when it first shows and kept while it does.
    private func caption(_ line: CaptionLine, _ c: Captions) -> CIImage? {
        captionImage.withLock { cached in
            if let cached, cached.line == line { return cached.image }
            let img = Self.captionImage(line.text, c, canvasW: Double(size.width), canvasH: Double(size.height))
            cached = (line, img)
            return img
        }
    }

    /// `img` (the cropped recording) with blur box `b` blurred or pixelated, faded in and out.
    private func blur(_ b: Annotation, over img: CIImage, at t: Double, crop: CGRect) -> CIImage {
        let alpha = annotationOpacity(b, at: t)
        // The box in cropped-recording pixels, bottom-left origin, kept to what's there.
        let box = CGRect(x: b.x * srcW - crop.minX, y: srcH * (1 - b.y - b.h) - crop.minY, width: b.w * srcW, height: b.h * srcH)
            .intersection(img.extent).integral
        guard alpha > 0, box.width >= 1, box.height >= 1 else { return img }
        let amount = b.blurAmount(short: min(srcW, srcH))
        // Only what's inside the box is sampled, its edges extended, so nothing from outside bleeds in.
        let inside = img.cropped(to: box).clampedToExtent()
        var hidden: CIImage?
        if b.pixelate == true {
            let f = CIFilter.pixellate()
            f.inputImage = inside
            f.scale = Float(max(2, amount))
            f.center = box.origin
            hidden = f.outputImage
        } else {
            let f = CIFilter.gaussianBlur()
            f.inputImage = inside
            f.radius = Float(amount)
            hidden = f.outputImage
        }
        guard var out = hidden?.cropped(to: box) else { return img }
        if alpha < 1 {
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
            out = f.outputImage ?? out
        }
        return out.composited(over: img)
    }

    /// The webcam as a circle, rounded square or square (see `bubbleCornerRadius`) with a soft shadow, square-cropped
    /// from the centre of the frame.
    private func drawBubble(_ camera: CIImage, style: CameraStyle, zoom: Double, over out: CIImage) -> CIImage {
        let r = cameraRect(size, style, zoom: zoom)
        guard r.d > 4 else { return out }
        let e = camera.extent, side = min(e.width, e.height)
        var img = camera.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: .init(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
        if style.mirror { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0)) }
        let k = r.d / side
        let rect = CGRect(x: r.x, y: Double(size.height) - r.y - r.d, width: r.d, height: r.d) // flip to bottom-left origin
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(.init(translationX: rect.minX, y: rect.minY)))
        return floating(img, in: rect, corner: bubbleCornerRadius(diameter: r.d, style), shadow: bubbleShadow(diameter: r.d, style), over: out)
    }

    /// A video overlay's frame filling its box (cropped to keep its shape, never stretched), with rounded corners and a
    /// shadow like the webcam bubble, at `alpha`.
    private func drawOverlay(_ frame: CIImage, _ a: Annotation, _ v: OverlayVideo, alpha: Double, over out: CIImage) -> CIImage {
        let W = Double(size.width), H = Double(size.height)
        let rect = CGRect(x: a.x * W, y: H - (a.y + a.h) * H, width: a.w * W, height: a.h * H) // flip to bottom-left origin
        let e = frame.extent
        guard rect.width >= 2, rect.height >= 2, e.width > 0, e.height > 0 else { return out }
        let k = max(rect.width / e.width, rect.height / e.height)
        let img = frame.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(.init(scaleX: k, y: k))
            .concatenating(.init(translationX: rect.midX, y: rect.midY))).cropped(to: rect)
        let short = min(rect.width, rect.height)
        return floating(img, in: rect, corner: min(1, max(0, v.roundness ?? OverlayVideo.defaultRoundness)) * short / 2,
                        shadow: boxShadow(size: short, strength: v.shadow), alpha: alpha, over: out)
    }

    /// `img`, already placed over `rect`, cut to a rounded rectangle with a soft shadow under it, at `alpha`.
    private func floating(_ img: CIImage, in rect: CGRect, corner: Double, shadow: DropShadow?, alpha: Double = 1, over out: CIImage) -> CIImage {
        let mask: CIImage?
        if abs(rect.width - rect.height) < 0.5, corner >= rect.width / 2 - 0.01 {
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: rect.midX, y: rect.midY)
            g.radius0 = Float(rect.width / 2 - 1)
            g.radius1 = Float(rect.width / 2)
            g.color0 = .white
            g.color1 = .clear
            mask = g.outputImage?.cropped(to: rect)
        } else {
            let rr = CIFilter.roundedRectangleGenerator()
            rr.extent = rect
            rr.radius = Float(corner)
            rr.color = .white
            mask = rr.outputImage
        }
        guard let mask else { return out }

        // Shadow: the box's shape in black, blurred and nudged down.
        var base = out
        if let sh = shadow {
            let shade = CIFilter.blendWithAlphaMask()
            shade.inputImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: sh.alpha * alpha)).cropped(to: rect)
            shade.backgroundImage = CIImage.empty()
            shade.maskImage = mask
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = shade.outputImage?.transformed(by: .init(translationX: 0, y: -sh.offset))
            blur.radius = Float(sh.radius)
            if let shadow = blur.outputImage { base = shadow.composited(over: base) }
        }

        let cut = CIFilter.blendWithAlphaMask()
        cut.inputImage = img
        cut.backgroundImage = CIImage.empty()
        cut.maskImage = mask
        guard var shaped = cut.outputImage else { return base }
        if alpha < 1 { // fading: scale the alpha channel, after the cut so it fades rather than darkens
            let f = CIFilter.colorMatrix()
            f.inputImage = shaped
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
            shaped = f.outputImage ?? shaped
        }
        return shaped.composited(over: base)
    }

    // MARK: - Pieces built once per edit

    /// White continuous-corner ("squircle") rounded rectangle, the shape macOS uses for windows.
    static func continuousMask(_ rect: CGRect, radius: Double) -> CIImage? {
        let w = Int(rect.width.rounded(.up)), h = Int(rect.height.rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.addPath(shape.cgPath)
        ctx.setFillColor(.white)
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: .init(translationX: rect.minX, y: rect.minY))
    }

    /// The image if there is one (cover-fitted, optionally blurred), else the gradient, else the flat colour.
    static func background(_ e: Edits, canvas: CGRect) -> CIImage {
        var base = CIImage(color: CIColor(cgColor: hexColor(e.background))).cropped(to: canvas)
        if let g = e.gradient {
            // Gradient ends are top-left origin; Core Image is bottom-left.
            let ends = gradientEnds(g, width: canvas.width, height: canvas.height)
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: ends.start.x, y: canvas.height - ends.start.y)
            f.point1 = CGPoint(x: ends.end.x, y: canvas.height - ends.end.y)
            f.color0 = CIColor(cgColor: hexColor(g.from))
            f.color1 = CIColor(cgColor: hexColor(g.to))
            if let img = f.outputImage { base = img.cropped(to: canvas) }
        }
        guard let path = e.backgroundImage, let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
            return base
        }
        // Cover-fit: scale until both sides fill, then centre-crop.
        let s = max(canvas.width / img.extent.width, canvas.height / img.extent.height)
        let scaled = img.transformed(by: .init(scaleX: s, y: s))
        let dx = (canvas.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (canvas.height - scaled.extent.height) / 2 - scaled.extent.minY
        var cover = scaled.transformed(by: .init(translationX: dx, y: dy))
        let radius = backgroundBlurRadius(e, short: min(canvas.width, canvas.height))
        if radius > 0.5 {
            // Extend the edge pixels first, so the blur doesn't pull in transparent black around the border.
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = cover.clampedToExtent()
            blur.radius = Float(radius)
            cover = blur.outputImage ?? cover
        }
        return cover.cropped(to: canvas).composited(over: base)
    }

    /// An annotation drawn once into a bitmap just big enough for it, already placed on the canvas (Core Image coordinates).
    static func annotationImage(_ a: Annotation, canvas: OutputSize) -> CIImage? {
        let W = Double(canvas.width), H = Double(canvas.height)
        let lw = max(1, a.stroke * min(W, H))
        let box = CGRect(x: a.x * W, y: a.y * H, width: a.w * W, height: a.h * H) // top-left origin; arrows may be negative
        var picture: CGImage?
        if a.kind == .image {
            guard let path = a.image, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            picture = img
        }

        // What's drawn, and how far it reaches, in canvas pixels.
        let bounds: CGRect
        let head = lw * 4 // arrowhead length
        let tail = CGPoint(x: box.minX, y: box.minY), tip = CGPoint(x: box.minX + box.width, y: box.minY + box.height)
        let centre = CGPoint(x: box.midX, y: box.midY), angle = a.rotation * .pi / 180
        if a.kind == .arrow {
            bounds = CGRect(x: min(tail.x, tip.x), y: min(tail.y, tip.y), width: abs(tip.x - tail.x), height: abs(tip.y - tail.y))
                .insetBy(dx: -(head + lw), dy: -(head + lw))
        } else {
            let turn = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: angle).translatedBy(x: -centre.x, y: -centre.y)
            bounds = box.standardized.applying(turn).insetBy(dx: -lw, dy: -lw)
        }
        let area = bounds.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard area.width >= 1, area.height >= 1,
              let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Draw in canvas coordinates with a top-left origin.
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(hexColor(a.color))
        ctx.setFillColor(hexColor(a.color))
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .blur, .video:
            return nil // drawn on the recording (see `blur(_:over:at:crop:)`), or a frame at a time (see `drawOverlay`)
        case .arrow:
            let len = hypot(tip.x - tail.x, tip.y - tail.y)
            guard len > 0.5 else { return nil }
            let ux = (tip.x - tail.x) / len, uy = (tip.y - tail.y) / len
            let h = min(head, len * 0.6), wing = h * 0.55
            let base = CGPoint(x: tip.x - ux * h, y: tip.y - uy * h)
            ctx.move(to: tail)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: base.x - uy * wing, y: base.y + ux * wing))
            ctx.addLine(to: CGPoint(x: base.x + uy * wing, y: base.y - ux * wing))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle, .ellipse, .image:
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: angle)
            let local = CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
            if a.kind == .rectangle { ctx.stroke(local.insetBy(dx: lw / 2, dy: lw / 2)) }
            else if a.kind == .ellipse { ctx.strokeEllipse(in: local.insetBy(dx: lw / 2, dy: lw / 2)) }
            else if let picture {
                // CGContext.draw puts images bottom-up; flip locally so they land the right way up in this top-left space.
                ctx.translateBy(x: 0, y: local.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(picture, in: CGRect(x: local.minX, y: 0, width: local.width, height: local.height))
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: .init(translationX: area.minX, y: H - area.maxY))
    }

    /// Callout look: font size is a fraction of canvas height so it reads the same at any export size.
    public static let calloutFont = 0.045

    /// A shortcut as a row of keycaps on a dark plate, e.g. ⌘ ⇧ 4.
    static func keycapImage(_ caps: [String], canvasHeight: Double) -> CIImage? {
        let fs = max(12, (canvasHeight * 0.034).rounded())
        let font = NSFont.systemFont(ofSize: fs, weight: .semibold)
        let texts = caps.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white]) }
        let capH = fs * 1.7, gap = fs * 0.3, pad = fs * 0.35
        let widths = texts.map { max(capH, $0.size().width + fs * 0.9) }
        let w = Int((widths.reduce(0, +) + gap * Double(caps.count - 1) + pad * 2).rounded(.up)), h = Int((capH + pad * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor(white: 0.067, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: fs * 0.55, yRadius: fs * 0.55).fill()
        var x = pad
        for (text, cw) in zip(texts, widths) {
            let cap = CGRect(x: x, y: pad, width: cw, height: capH)
            NSColor(white: 1, alpha: 0.16).setFill()
            NSBezierPath(roundedRect: cap, xRadius: fs * 0.35, yRadius: fs * 0.35).fill()
            let ts = text.size()
            text.draw(at: CGPoint(x: cap.midX - ts.width / 2, y: cap.midY - ts.height / 2))
            x += cw + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// A caption line: white text on a dark box, or outlined, wrapped to stay inside the frame.
    static func captionImage(_ text: String, _ c: Captions, canvasW: Double, canvasH: Double) -> CIImage? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fs = max(12, (min(canvasW, canvasH) * Captions.font * c.size).rounded())
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs, weight: .semibold), .foregroundColor: NSColor.white,
                                                    .paragraphStyle: para]
        if c.style == .outline {
            attrs[.strokeColor] = NSColor.black
            attrs[.strokeWidth] = -7.0 // percent of the font size; negative fills as well as strokes
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
            shadow.shadowBlurRadius = fs * 0.15
            attrs[.shadow] = shadow
        }
        let attr = NSAttributedString(string: text, attributes: attrs)
        let box = attr.boundingRect(with: CGSize(width: canvasW * 0.86, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = fs * (c.style == .box ? 0.6 : 0.3), padY = fs * 0.3
        let tw = box.width.rounded(.up) + 1, th = box.height.rounded(.up)
        let w = Int(tw + padX * 2), h = Int(th + padY * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        if c.style == .box {
            NSColor(white: 0.05, alpha: 0.75).setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: fs * 0.35, yRadius: fs * 0.35).fill()
        }
        attr.draw(with: CGRect(x: padX, y: padY, width: tw, height: th), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// A callout's box, wrapping its text so the box is at most 90% of the canvas wide.
    public static func calloutImage(_ text: String, canvasWidth: Double, canvasHeight: Double) -> CIImage? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fs = max(14, (canvasHeight * calloutFont).rounded())
        let font = NSFont.systemFont(ofSize: fs, weight: .semibold)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let padX = fs * 0.9, padY = fs * 0.6
        let ts = attr.boundingRect(with: CGSize(width: max(fs, canvasWidth * 0.9 - padX * 2), height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let w = Int((ts.width + padX * 2).rounded(.up)), h = Int((ts.height + padY * 2).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSColor(white: 0.067, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: fs * 0.45, yRadius: fs * 0.45).fill()
        attr.draw(with: CGRect(x: padX, y: padY - font.descender * 0.25, width: ts.width.rounded(.up) + 1, height: ts.height.rounded(.up)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

public func hexColor(_ hex: String) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return CGColor(srgbRed: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, alpha: 1)
}
