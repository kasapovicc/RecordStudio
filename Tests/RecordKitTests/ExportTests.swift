import SQLite3
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers
import Testing
@testable import RecordCore
@testable import RecordKit

/// Writes a 640×400, 30 fps movie with colour bars, a moving square and a 440 Hz tone (or silence, with `tone: false`).
/// It waits for the writer by suspending, never by blocking a thread: tests run in parallel on Swift's small shared
/// thread pool, and a few of them blocked at once (with a semaphore or a sleep loop) could stall every other test.
func synthesizeMovie(_ url: URL, seconds: Int = 4, solid: (CGFloat, CGFloat, CGFloat)? = nil, size: (Int, Int) = (640, 400),
                     windowCorner: CGFloat? = nil, tone: Bool = true, fileType: AVFileType = .mp4, pcm: Bool = false,
                     transform: CGAffineTransform = .identity) async throws {
    try? FileManager.default.removeItem(at: url)
    let (w, h) = size
    let fps = 30, rate = 44_100
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    // `pcm` keeps the sound uncompressed, as cameras and screen tools often write it to a MOV; an MP4 can't hold that.
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm ? nil : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
    video.transform = transform // how players should turn it, like a phone video shot upright
    video.expectsMediaDataInRealTime = false
    audio.expectsMediaDataInRealTime = false
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)

    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)

    let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
    let perFrame = rate / fps
    func picture(_ i: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for (j, c) in (solid.map { [$0] } ?? colours).enumerated() {
            let n = solid == nil ? 4 : 1
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: j * w / n, y: 0, width: w / n, height: h))
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 20 + i * 4, y: 180, width: 40, height: 40))
        if let r = windowCorner { // what window capture produces: black outside the window's rounded corners
            ctx.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fillPath(using: .evenOdd)
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }
    func sound(_ i: Int) -> CMSampleBuffer {
        var pcm = [Int16](repeating: 0, count: perFrame)
        if tone { for k in 0..<perFrame { pcm[k] = Int16(sin(Double(i * perFrame + k) * 2 * .pi * 440 / Double(rate)) * 8000) } }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: perFrame * 2, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: perFrame * 2, flags: 0, blockBufferOut: &block)
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: perFrame * 2) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: perFrame,
                                                             presentationTimeStamp: CMTime(value: Int64(i * perFrame), timescale: Int32(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }
    // Each track is fed whenever the writer is ready for it, never one strictly after the other: to interleave them in the
    // file the writer may hold one back until the other catches up, and waiting on that one alone would wait forever.
    let frames = seconds * fps
    var nextPicture = 0, nextSound = 0
    while nextPicture < frames || nextSound < frames {
        var fed = false
        if nextPicture < frames, video.isReadyForMoreMediaData {
            adaptor.append(picture(nextPicture), withPresentationTime: CMTime(value: Int64(nextPicture), timescale: Int32(fps)))
            nextPicture += 1
            if nextPicture == frames { video.markAsFinished() }
            fed = true
        }
        if nextSound < frames, audio.isReadyForMoreMediaData {
            audio.append(sound(nextSound))
            nextSound += 1
            if nextSound == frames { audio.markAsFinished() }
            fed = true
        }
        if writer.status == .failed { throw writer.error! }
        if !fed { try await Task.sleep(for: .milliseconds(1)) }
    }
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? StudioError.message("writer failed") }
}

private let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: ".out")

private func pixel(_ jpeg: String, x: Int, yFromTop y: Int) throws -> (r: Int, g: Int, b: Int) {
    let img = CIImage(contentsOf: URL(fileURLWithPath: jpeg))!
    var px = [UInt8](repeating: 0, count: 4)
    let ciY = Int(img.extent.height) - 1 - y
    CIContext().render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: ciY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

/// One pixel of a rendered image, `y` counted from the top of `canvas`.
private func pixel(_ img: CIImage, x: Int, yFromTop y: Int, canvas: CGRect) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    CIContext().render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: Int(canvas.height) - 1 - y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

@Suite struct Backgrounds {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test func switchesBackgroundFillAndBringsTheLastOneBack() {
        let wall = Wallpapers.root + "/Sonoma.heic", mine = "/tmp/import-1.png", g = BackgroundGradient.presets[1]
        var e = Edits(trim: Trim(start: 0, end: 1), zooms: [], backgroundImage: wall, gradient: g)
        var memory = BackgroundMemory()
        #expect(e.fill == .wallpaper)
        #expect(!e.setFill(.image, memory: &memory, wallpaper: nil) && e.backgroundImage == wall) // no image chosen yet
        #expect(e.setFill(.colour, memory: &memory, wallpaper: nil) && e.fill == .colour && e.backgroundImage == nil && e.gradient == nil)
        #expect(e.setFill(.gradient, memory: &memory, wallpaper: nil) && e.gradient == g)        // the same gradient comes back
        #expect(e.setFill(.wallpaper, memory: &memory, wallpaper: nil) && e.backgroundImage == wall)
        e.backgroundImage = mine
        #expect(e.fill == .image)
        #expect(e.setFill(.wallpaper, memory: &memory, wallpaper: nil) && e.backgroundImage == wall)
        #expect(e.setFill(.image, memory: &memory, wallpaper: nil) && e.backgroundImage == mine)
        var fresh = Edits(trim: Trim(start: 0, end: 1), zooms: []), none = BackgroundMemory()
        #expect(fresh.setFill(.gradient, memory: &none, wallpaper: nil) && fresh.gradient == BackgroundGradient.presets[0])
        #expect(fresh.setFill(.wallpaper, memory: &none, wallpaper: wall) && fresh.fill == .wallpaper)
    }
    @Test func drawsAGradientFromOneEndToTheOther() {
        var e = Edits(trim: Trim(start: 0, end: 1))
        e.gradient = BackgroundGradient(from: "#ff0000", to: "#0000ff", angle: 90) // left → right
        let bg = FrameRenderer.background(e, canvas: canvas)
        let left = pixel(bg, x: 1, yFromTop: 100, canvas: canvas), right = pixel(bg, x: 398, yFromTop: 100, canvas: canvas)
        #expect(left.r > 240 && left.b < 15)
        #expect(right.b > 240 && right.r < 15)
        let top = pixel(bg, x: 200, yFromTop: 2, canvas: canvas), bottom = pixel(bg, x: 200, yFromTop: 197, canvas: canvas)
        #expect(abs(top.r - bottom.r) < 3 && abs(top.b - bottom.b) < 3) // horizontal: no change top to bottom

        e.gradient?.angle = 180 // top → bottom
        let v = FrameRenderer.background(e, canvas: canvas)
        #expect(pixel(v, x: 200, yFromTop: 1, canvas: canvas).r > 240 && pixel(v, x: 200, yFromTop: 198, canvas: canvas).b > 240)
    }

    @Test func blursTheImageWithoutDarkeningItsEdges() throws {
        // Left half black, right half white.
        let url = out.appending(path: "halves.png")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let halves = CIImage(color: .white).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
            .composited(over: CIImage(color: .black).cropped(to: canvas))
        try CIContext().writePNGRepresentation(of: halves, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var e = Edits(trim: Trim(start: 0, end: 1), background: "#ff0000")
        e.backgroundImage = url.path

        let sharp = FrameRenderer.background(e, canvas: canvas)
        #expect(pixel(sharp, x: 197, yFromTop: 100, canvas: canvas).g < 10 && pixel(sharp, x: 203, yFromTop: 100, canvas: canvas).g > 245)

        e.backgroundBlur = 1 // 10 px radius on this 200 px tall canvas
        let soft = FrameRenderer.background(e, canvas: canvas)
        let edge = pixel(soft, x: 197, yFromTop: 100, canvas: canvas)
        #expect(edge.g > 40 && edge.g < 215) // grey where black meets white
        // The border stays the image's own colour, not the red underneath or transparent black pulled in by the blur.
        let corner = pixel(soft, x: 399, yFromTop: 0, canvas: canvas)
        #expect(corner.r > 245 && corner.g > 245 && corner.b > 245)
    }
}

@Suite struct DrawnCursor {
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
    // An 8×8 red square with its hotspot at the top-left, moving left to right across the middle over 10 s.
    let square = CursorImage(png: CIContext().pngRepresentation(of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
                                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!, hotX: 0, hotY: 0)
    let track = stride(from: 0.0, through: 10.0, by: 1 / 60).map { t in CursorSample(t: t, x: 0.2 + 0.06 * t, y: 0.5, down: false, image: t == 0 ? 0 : nil) }

    func render(at t: Double, _ style: (inout CursorStyle) -> Void = { _ in }) -> (CIImage, CGRect) {
        var e = Edits(trim: Trim(start: 0, end: 10), padding: 0, cursorHighlight: false)
        var s = CursorStyle(); s.smoothing = 0; style(&s); e.cursorStyle = s
        let r = FrameRenderer(edits: e, cursor: track, sourceWidth: 640, sourceHeight: 400, duration: 10, cursorImages: [square])
        return (r.render(source, at: t), CGRect(x: 0, y: 0, width: r.size.width, height: r.size.height))
    }
    func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 220 && p.g < 40 }

    @Test func drawsTheCursorWhereItIsAtThatTime() {
        let (img, canvas) = render(at: 5) // x = 0.5 → 320 px, y = 200 px
        #expect(isRed(pixel(img, x: 323, yFromTop: 203, canvas: canvas)))  // inside the square, below-right of the hotspot
        #expect(!isRed(pixel(img, x: 316, yFromTop: 203, canvas: canvas))) // left of the hotspot
        #expect(!isRed(pixel(img, x: 323, yFromTop: 196, canvas: canvas))) // above it
        let (early, _) = render(at: 1) // x = 0.26 → 166 px
        #expect(isRed(pixel(early, x: 169, yFromTop: 203, canvas: canvas)) && !isRed(pixel(early, x: 323, yFromTop: 203, canvas: canvas)))
    }
    @Test func scalesWithTheSizeAndCanBeHidden() {
        let (big, canvas) = render(at: 5) { $0.size = 2 }
        #expect(isRed(pixel(big, x: 333, yFromTop: 213, canvas: canvas)))   // 16 px square now
        let (hidden, _) = render(at: 5) { $0.visible = false }
        #expect(!isRed(pixel(hidden, x: 323, yFromTop: 203, canvas: canvas)))
    }
}

@Suite struct CursorMotionBlur {
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
    let square = DrawnCursor().square

    /// How many pixels across the row through the cursor are tinted red, with the cursor at `x(t)` and blur on.
    func footprint(_ x: @escaping (Double) -> Double, at t: Double) -> Int {
        let track = stride(from: 0.0, through: 4.0, by: 1 / 60).map { t in CursorSample(t: t, x: x(t), y: 0.5, down: false, image: t == 0 ? 0 : nil) }
        var e = Edits(trim: Trim(start: 0, end: 4), padding: 0, cursorHighlight: false)
        var style = CursorStyle(); style.smoothing = 0; style.motionBlur = 1; e.cursorStyle = style
        let r = FrameRenderer(edits: e, cursor: track, sourceWidth: 640, sourceHeight: 400, duration: 4, cursorImages: [square])
        var row = [UInt8](repeating: 0, count: 640 * 4)
        CIContext().render(r.render(source, at: t), toBitmap: &row, rowBytes: 640 * 4, bounds: CGRect(x: 0, y: 400 - 1 - 203, width: 640, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0..<640).filter { Int(row[$0 * 4]) - Int(row[$0 * 4 + 1]) > 20 }.count
    }

    @Test func staysSharpWhenStillAndSmearsWhenFast() {
        let still = footprint({ _ in 0.5 }, at: 2)
        #expect(still == 8) // just the 8 px square
        let fast = footprint({ 0.1 + 0.2 * $0 }, at: 2) // 0.2 of 640 px per second → about 2 px per frame: under the threshold
        #expect(fast == 8)
        let faster = footprint({ 0.5 + 4 * ($0 - 2) }, at: 2) // 4 widths per second → about 43 px per frame, crossing the middle at 2 s
        #expect(faster > 16)
    }
}

@Suite struct Ripple {
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
    // The cursor sits in the middle and clicks at 2 s.
    let track = stride(from: 0.0, through: 4.0, by: 1 / 60).map { t in CursorSample(t: t, x: 0.5, y: 0.5, down: t >= 2 && t < 2.1) }

    /// Whether any pixel on the row through the click, from its centre outwards, is tinted brand red by the ring.
    func ringShows(at t: Double) -> Bool {
        var e = Edits(trim: Trim(start: 0, end: 4), padding: 0, cursorHighlight: false)
        e.clickEffect = .ripple
        let r = FrameRenderer(edits: e, cursor: track, sourceWidth: 640, sourceHeight: 400, duration: 4)
        let img = r.render(source, at: t), canvas = CGRect(x: 0, y: 0, width: r.size.width, height: r.size.height)
        return (320...345).contains { x in let p = pixel(img, x: x, yFromTop: 200, canvas: canvas); return p.r - p.g > 30 && p.r - p.b > 30 }
    }

    @Test func showsJustAfterAClickAndIsGoneHalfASecondLater() {
        #expect(!ringShows(at: 1.9))
        #expect(ringShows(at: 2.1))
        #expect(!ringShows(at: 2.6))
    }
}

@Suite struct Keycaps {
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))

    /// keys.json as the recorder writes it: ⌘⇧4 at 2 s.
    func keys() throws -> [ShortcutPress] {
        try JSONDecoder().decode([ShortcutPress].self, from: Data(#"[{"t":2,"modifiers":["⇧","⌘"],"key":"4"}]"#.utf8))
    }

    /// Whether the keycaps cover the point, x from the left and y from the top of the 640×400 frame.
    func plate(at t: Double, x: Int, y: Int, _ position: KeystrokeStyle.Position = .bottomCenter) throws -> Bool {
        var e = Edits(trim: Trim(start: 0, end: 4), padding: 0, cursorHighlight: false)
        e.keystrokes = KeystrokeStyle()
        e.keystrokes?.position = position
        let r = FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 4, keys: try keys())
        let p = pixel(r.render(source, at: t), x: x, yFromTop: y, canvas: CGRect(x: 0, y: 0, width: 640, height: 400))
        return abs(p.r - 127) > 20 // the plate, a keycap or its glyph: anything but the grey recording
    }

    @Test func showsTheShortcutAtTheBottomForAMomentThenFades() throws {
        // The plate sits just above 94% of the height, centred.
        #expect(try !plate(at: 1.9, x: 320, y: 360))
        #expect(try plate(at: 2.5, x: 320, y: 360))
        #expect(try !plate(at: 2.5, x: 320, y: 300) && !plate(at: 2.5, x: 30, y: 360))
        #expect(try !plate(at: 3.3, x: 320, y: 360))                          // gone after 1.2 s
        #expect(try plate(at: 2.5, x: 30, y: 360, .bottomLeft) && !plate(at: 2.5, x: 320, y: 360, .bottomLeft))
        #expect(try plate(at: 2.5, x: 610, y: 360, .bottomRight))
    }
}

@Suite struct Annotations {
    // A plain grey "recording"; with no cursor there are no zooms, so the canvas is static.
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))

    func render(_ list: [Annotation], at t: Double) -> (img: CIImage, canvas: CGRect, size: OutputSize) {
        var e = Edits(trim: Trim(start: 0, end: 10), padding: 0, cursorHighlight: false)
        e.allAnnotations = list
        let r = FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 10)
        return (r.render(source, at: t), CGRect(x: 0, y: 0, width: r.size.width, height: r.size.height), r.size)
    }

    @Test func drawsAnArrowOnlyInsideItsTimeAndAtItsPosition() {
        // A thick red arrow across the middle, from 20% to 80% of the width, shown from 2 s to 4 s.
        let arrow = Annotation(kind: .arrow, start: 2, end: 4, x: 0.2, y: 0.5, w: 0.6, h: 0, color: "#ff0000", stroke: 0.02)
        let on = render([arrow], at: 3)
        let mid = pixel(on.img, x: on.size.width / 2, yFromTop: on.size.height / 2, canvas: on.canvas)
        #expect(mid.r > 220 && mid.g < 40 && mid.b < 40)                                          // on the shaft
        let tip = pixel(on.img, x: Int(0.78 * Double(on.size.width)), yFromTop: on.size.height / 2, canvas: on.canvas)
        #expect(tip.r > 220 && tip.g < 40)                                                         // in the head
        let above = pixel(on.img, x: on.size.width / 2, yFromTop: on.size.height / 4, canvas: on.canvas)
        #expect(abs(above.r - above.g) < 10)                                                      // grey away from it
        let before = render([arrow], at: 1.5), after = render([arrow], at: 4.5)
        for f in [before, after] {
            let p = pixel(f.img, x: f.size.width / 2, yFromTop: f.size.height / 2, canvas: f.canvas)
            #expect(abs(p.r - p.g) < 10)                                                          // not drawn outside 2–4 s
        }
    }

    @Test func drawsRotatedShapesAndImages() throws {
        // A green square outline rotated 45°: its corner now points straight up, above where the unrotated top edge was.
        let box = Annotation(kind: .rectangle, start: 0, end: 10, x: 0.4, y: 0.3, w: 0.15, h: 0.15 * 640 / 400, rotation: 45,
                             color: "#00ff00", stroke: 0.01)
        let f = render([box], at: 1)
        let cx = Double(f.size.width) * (0.4 + 0.075), cy = Double(f.size.height) * (0.3 + 0.075 * 640 / 400)
        let half = Double(f.size.width) * 0.075
        let topCorner = pixel(f.img, x: Int(cx), yFromTop: Int(cy - half * 2.0.squareRoot() + 3), canvas: f.canvas)
        #expect(topCorner.g > 200 && topCorner.r < 60)
        let centre = pixel(f.img, x: Int(cx), yFromTop: Int(cy), canvas: f.canvas)
        #expect(abs(centre.r - centre.g) < 10)                                                    // an outline, not filled

        // A solid blue image fills its box.
        let url = out.appending(path: "note-blue.png")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try CIContext().writePNGRepresentation(of: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40)),
                                               to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let pic = Annotation(kind: .image, start: 0, end: 10, x: 0.1, y: 0.1, w: 0.2, h: 0.2, image: url.path)
        let g = render([pic], at: 1)
        let inside = pixel(g.img, x: Int(0.2 * Double(g.size.width)), yFromTop: Int(0.2 * Double(g.size.height)), canvas: g.canvas)
        #expect(inside.b > 220 && inside.r < 30)
        let outside = pixel(g.img, x: Int(0.35 * Double(g.size.width)), yFromTop: Int(0.2 * Double(g.size.height)), canvas: g.canvas)
        #expect(abs(outside.r - outside.b) < 10)
    }
}

/// A mono sine wave as a 16-bit WAV file.
func writeTone(_ url: URL, seconds: Double, hz: Double = 1000) throws {
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    let n = AVAudioFrameCount(seconds * 44_100)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
    buffer.frameLength = n
    for i in 0..<Int(n) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * hz * Double(i) / 44_100) * 0.5) }
    try file.write(from: buffer)
    file.close() // writes the header now; left to deinit it can happen too late, and the file reads as empty
}

/// RMS loudness (0–1) of a movie's mixed sound between two times.
func loudness(_ url: URL, from a: Double, to b: Double) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(out)
    #expect(reader.startReading())
    var sum = 0.0, count = 0
    while let sample = out.copyNextSampleBuffer() {
        guard let block = sample.dataBuffer else { continue }
        let bytes = CMBlockBufferGetDataLength(block)
        var pcm = [Int16](repeating: 0, count: bytes / 2)
        pcm.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        for v in pcm { let x = Double(v) / 32768; sum += x * x; count += 1 }
    }
    return count == 0 ? 0 : (sum / Double(count)).squareRoot()
}

@Suite(.serialized) struct Import {
    let dir = out.appending(path: "import")

    /// Imports a synthetic video made elsewhere, lists it in a fresh library, opens it with default edits and exports it.
    func importAndExport(_ source: URL) async throws -> (rec: Recording, exported: Probe.Info) {
        let root = dir.appending(path: "library-\(source.lastPathComponent)")
        try? FileManager.default.removeItem(at: root)
        let library = try Library(root: root)
        let folder = root.appending(path: "recordings/1")
        let shot = try await Importer.importVideo(source, into: folder)
        try await library.insert(id: "1", title: "Clip", dir: folder, createdAt: shot.map { Int64($0.timeIntervalSince1970 * 1000) })
        let rec = try #require(try library.list().first)
        let edits = defaultEdits(duration: rec.duration, cursor: [])
        #expect(edits.zooms.isEmpty) // no cursor, so no automatic zooms
        let job = ExportJob(source: URL(fileURLWithPath: rec.path), width: rec.width, height: rec.height, duration: rec.duration, fps: rec.fps,
                            title: "Clip", createdAt: Date(), edits: edits, cursor: [], format: .mp4, outDir: root, name: "Clip-1")
        let res = try await Exporter.run(job, transcribe: nil) { _, _ in }
        return (rec, try await Probe.movie(URL(fileURLWithPath: res.video)))
    }

    @Test func convertsAMOVWithUncompressedSound() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mov = dir.appending(path: "camera.mov")
        try await synthesizeMovie(mov, seconds: 2, fileType: .mov, pcm: true)
        let (rec, exported) = try await importAndExport(mov)
        #expect(rec.width == 640 && rec.height == 400 && rec.hasAudio && abs(rec.duration - 2) < 0.1)
        #expect(abs(exported.duration - 2) < 0.15 && exported.hasAudio)
        // When it was made: the file's own date, since it has no shooting date in its metadata.
        let made = try mov.resourceValues(forKeys: [.creationDateKey]).creationDate!
        #expect(abs(Double(rec.createdAt) / 1000 - made.timeIntervalSince1970) < 2)
    }

    @Test func turnsAPhoneVideoUpright() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let phone = dir.appending(path: "phone.mov")
        // Stored 640×400, meant to be shown turned a quarter: 400×640.
        try await synthesizeMovie(phone, seconds: 1, fileType: .mov, transform: CGAffineTransform(rotationAngle: .pi / 2))
        let (rec, _) = try await importAndExport(phone)
        #expect(rec.width == 400 && rec.height == 640)
        let stored = try #require(try await AVURLAsset(url: URL(fileURLWithPath: rec.path)).loadTracks(withMediaType: .video).first)
        let (size, transform) = try await stored.load(.naturalSize, .preferredTransform)
        #expect(size.width == 400 && size.height == 640 && transform == .identity) // upright in the frames themselves
    }

    @Test func rewrapsAnMP4WithoutConverting() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mp4 = dir.appending(path: "ready.mp4")
        try await synthesizeMovie(mp4, seconds: 1)
        let (rec, _) = try await importAndExport(mp4)
        #expect(rec.width == 640 && rec.height == 400 && rec.hasAudio)
        await #expect(throws: StudioError.self) { try await Importer.importVideo(dir.appending(path: "missing.mov"), into: dir.appending(path: "nowhere")) }
    }
}

/// The stage names an export reports, from whichever thread it reports them on.
final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

@Suite(.serialized) struct EndToEnd {
    let raw = out.appending(path: "raw.mp4")

    init() async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: raw.path) { try await synthesizeMovie(raw) }
    }

    func job(_ format: ExportFormat, _ edit: (inout Edits) -> Void = { _ in }) -> ExportJob {
        let cursor = (0...120).map { i in CursorSample(t: Double(i) / 30, x: 0.1 + 0.8 * Double(i) / 120, y: 0.3 + 0.4 * Double(i) / 120, down: (30..<33).contains(i)) }
        var edits = defaultEdits(duration: 4, cursor: cursor)
        edits.trim = Trim(start: 0.5, end: 3.5)
        (edits.background, edits.gradient) = ("#204060", nil)
        edits.callouts = [Callout(text: "Step 1: it's here", start: 1, end: 2.5, x: 0.05, y: 0.05)]
        edit(&edits)
        return ExportJob(source: raw, width: 640, height: 400, duration: 4, fps: 30, title: "My demo: take 1", createdAt: Date(),
                         edits: edits, cursor: cursor, format: format, outDir: out, name: "My-demo-take-1-20260101-1200-\(format.rawValue)")
    }

    @Test func exportsMP4WithPosterTranscriptAndSummary() async throws {
        let stages = Stages()
        let res = try await Exporter.run(job(.mp4), transcribe: nil) { stage, _ in stages.append(stage) }

        let info = try await Probe.movie(URL(fileURLWithPath: res.video))
        #expect(info.width == 716 && info.height == 476) // 640×400 + 6% padding each side
        #expect(abs(info.duration - 3) < 0.15)
        #expect(info.hasAudio)
        #expect(res.video.hasSuffix("My-demo-take-1-20260101-1200-mp4.mp4"))

        // The padding shows the background colour, so the compositor really ran.
        let corner = try pixel(res.poster!, x: 4, yFromTop: 4)
        #expect(abs(corner.r - 0x20) < 12 && abs(corner.g - 0x40) < 12 && abs(corner.b - 0x60) < 12)

        #expect(try String(contentsOfFile: res.transcript!, encoding: .utf8).contains("No transcript"))
        let md = try String(contentsOfFile: res.summary!, encoding: .utf8)
        #expect(md.contains("# My demo: take 1") && md.contains("Callout: Step 1"))
        #expect(Set(stages.all).isSuperset(of: ["Rendering", "Poster", "Transcript", "Summary"]))
    }

    @Test func exportsARecordingWhoseScreenTrackHasAGap() async throws {
        // Like a real recording's raw.mp4: an empty edit of 8/600 s in the video track, here at 2 s.
        let comp = AVMutableComposition()
        let v = try #require(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let asset = AVURLAsset(url: raw) // kept: a track doesn't keep its asset alive
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let t = { (s: Int64) in CMTime(value: s, timescale: 600) }
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: t(1200)), of: track, at: .zero)
        v.insertEmptyTimeRange(CMTimeRange(start: t(1200), duration: t(8)))
        try v.insertTimeRange(CMTimeRange(start: t(1200), duration: t(1200)), of: track, at: t(1208))
        let gappy = out.appending(path: "gappy.mov")
        try? FileManager.default.removeItem(at: gappy)
        let session = try #require(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: gappy, as: .mov)
        withExtendedLifetime(asset) {}

        var j = job(.mp4) { $0.trim = Trim(start: 1.5, end: 2.5) }
        j.source = gappy
        j.name = "gap"
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(abs(try await Probe.movie(URL(fileURLWithPath: res.video)).duration - 1) < 0.15)
    }

    @Test func cutsMiddleSectionsOut() async throws {
        // The trim is 0.5–3.5 s; cutting 1.5–2.5 s out leaves 2 s, and the summary's moments move up to match.
        let j = job(.mp4) { e in
            e.split(at: 1.5); e.split(at: 2.5); e.removeSegment(1)
            e.callouts = [Callout(text: "After the cut", start: 3, end: 3.4, x: 0.05, y: 0.05)]
        }
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        let info = try await Probe.movie(URL(fileURLWithPath: res.video))
        #expect(abs(info.duration - outputDuration(j.edits.keptSegments)) < 0.15 && abs(info.duration - 2) < 0.15)
        #expect(info.hasAudio)
        let md = try String(contentsOfFile: res.summary!, encoding: .utf8)
        #expect(md.contains("- Length: 0:02") && md.contains("- 0:01 — Callout: After the cut"))
    }

    @Test func writesOnlyTheExtrasAskedFor() async throws {
        var j = job(.mp4) { $0.captions = Captions(lines: [CaptionLine("Hi", start: 1, end: 2)]) }
        j.name = "Only the video"
        j.extras = [.subtitles]
        // Loose files from runs before exports with extras got their own folder would still be beside it.
        for name in try FileManager.default.contentsOfDirectory(atPath: out.path) where name.hasPrefix("Only the video") {
            try FileManager.default.removeItem(at: out.appending(path: name))
        }
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        // With an extra, the video and its subtitles go in one folder named after the export.
        let folder = out.appending(path: "Only the video")
        #expect(res.video == folder.appending(path: "Only the video.mp4").path && res.place == folder.path)
        #expect(res.poster == nil && res.transcript == nil && res.summary == nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["Only the video.mp4", "Only the video.srt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.contains("Only the video") } == ["Only the video"])

        // Without extras, the video stays a single file.
        j.name = "Just the video"
        j.extras = []
        let alone = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(alone.video == out.appending(path: "Just the video.mp4").path && alone.place == alone.video)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.contains("Just the video") } == ["Just the video.mp4"])
    }

    @Test func replacesAFolderOnlyOnceTheNewOneIsFinished() async throws {
        var j = job(.mp4)
        j.name = "Replaced folder"
        let folder = out.appending(path: "Replaced folder"), partial = out.appending(path: ".Replaced folder.partial")
        try? FileManager.default.removeItem(at: folder) // left by an earlier run
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appending(path: "old.txt"))
        // Stopped: the folder it would replace is untouched, and nothing is left half-written.
        let task = Task { try await Exporter.run(j, transcribe: nil) { _, _ in } }
        task.cancel()
        _ = try? await task.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["old.txt"])
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        // Finished: the new folder takes the old one's place whole.
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
                == ["Replaced folder.mp4", "Replaced folder.jpg", "Replaced folder.transcript.txt", "Replaced folder.md"])
        #expect(try await Probe.movie(URL(fileURLWithPath: res.video)).duration > 2.5)
        #expect([res.poster, res.transcript, res.summary].allSatisfy { $0.map { FileManager.default.fileExists(atPath: $0) } == true })
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func replacesAFileOnlyOnceTheNewOneIsFinished() async throws {
        var j = job(.mp4)
        j.name = "Replaced"
        j.extras = []
        let target = out.appending(path: "Replaced.mp4"), partial = out.appending(path: ".Replaced.partial.mp4")
        try Data("old".utf8).write(to: target)
        // Stopped: the file it would replace is still there, and nothing is left half-written.
        let task = Task { try await Exporter.run(j, transcribe: nil) { _, _ in } }
        task.cancel()
        _ = try? await task.value
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        // Finished: the new video takes its place.
        _ = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(try await Probe.movie(target).duration > 2.5)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func cancellingRemovesTheUnfinishedVideo() async throws {
        var j = job(.mp4)
        j.name = "Cancelled"
        let task = Task { try await Exporter.run(j, transcribe: nil) { _, _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "Cancelled.mp4").path))
    }

    @Test func cancellingWhileRenderingStopsCleanly() async throws {
        // Cancelling while a frame was being read used to crash inside CoreMedia (#258). It's a race, so try a few times.
        for attempt in 1...40 {
            var j = job(.mp4)
            j.name = "Cancelled while rendering \(attempt)"
            let (rendering, started) = AsyncStream<Void>.makeStream()
            let task = Task { try await Exporter.run(j, transcribe: nil) { stage, _ in if stage == "Rendering" { started.yield() } } }
            for await _ in rendering { break }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 0...60)))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: out.appending(path: "\(j.name).mp4").path))
        }
    }

    @Test func exportsWhenPlacingTheSplitPiecesComesOutATickShort() async throws {
        // Pieces 0.5–1.13 s and 1.13–3.3467 s: placed on the composition's 1/600 s clock they total a tick less than
        // the edited length, and reading to the edited length used to fail with AVFoundation error -11841.
        var j = job(.mp4) { e in
            e.trim.end = 3.3466666666666667
            e.split(at: 1.13)
        }
        j.name = "My-demo-take-1-20260101-1200-tick"
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(abs(try await Probe.movie(URL(fileURLWithPath: res.video)).duration - 2.85) < 0.1)
    }

    @Test func writesChaptersAtTheirOutputTimes() async throws {
        // Trim 0.5–3.5 s with 1.5–2.0 s cut: markers at 1.2 s and 2.5 s play at 0.7 s and 1.5 s; one in the cut is dropped.
        let j = job(.mp4) { e in
            e.split(at: 1.5); e.split(at: 2.0); e.removeSegment(1)
            e.allMarkers = [Marker(t: 1.2, name: "Setup"), Marker(t: 1.7, name: "Gone"), Marker(t: 2.5, name: "Démo ✨")]
        }
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        let asset = AVURLAsset(url: URL(fileURLWithPath: res.video))
        let locale = try await asset.load(.availableChapterLocales).first ?? Locale(identifier: "und")
        var found: [(Double, String)] = []
        for g in try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []) {
            let title = try await g.items.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue) ?? ""
            found.append((g.timeRange.start.seconds, title))
        }
        #expect(found.map(\.1) == ["My demo: take 1", "Setup", "Démo ✨"])
        #expect(zip(found.map(\.0), [0, 0.7, 1.5]).allSatisfy { abs($0 - $1) < 0.02 })
        #expect(try String(contentsOfFile: res.summary!, encoding: .utf8).contains("0:00 My demo: take 1\n0:00 Setup\n0:01 Démo ✨"))
    }

    @Test func writesSubtitlesAtTheirOutputTimes() async throws {
        // Trim 0.5–3.5 s with 1.5–2.0 s cut: a line at 2.2–2.8 s plays at 1.2–1.8 s; one in the cut is left out.
        var j = job(.mp4) { e in
            e.split(at: 1.5); e.split(at: 2.0); e.removeSegment(1)
            var c = Captions(lines: [CaptionLine("Gone", start: 1.6, end: 1.9), CaptionLine("Still here", start: 2.2, end: 2.8)])
            c.visible = false // hidden from the video, still saved as subtitles
            e.captions = c
        }
        j.name = "My-demo-take-1-20260101-1200-captions"
        let video = try await Exporter.run(j, transcribe: nil) { _, _ in }.video
        let srt = try String(contentsOfFile: (video as NSString).deletingPathExtension + ".srt", encoding: .utf8)
        #expect(srt == "1\n00:00:01,200 --> 00:00:01,800\nStill here\n")
    }

    @Test func silencesTheMicrophoneOnlyWhereAsked() async throws {
        // Trim 0.5–3.5 s, 2.5–3.0 s cut out, the microphone silenced over 1.5–2.0 s: in the export that's 1.0–1.5 s.
        var j = job(.mp4) { e in
            e.callouts = []
            e.split(at: 2.5); e.split(at: 3); e.removeSegment(1)
            e.toggleSilence(.mic, Trim(start: 1.5, end: 2))
        }
        j.name = "My-demo-take-1-20260101-1200-silenced"
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(try await loudness(video, from: 0.2, to: 0.8) > 0.05)   // the tone before
        #expect(try await loudness(video, from: 1.1, to: 1.4) < 0.01)   // silenced
        #expect(try await loudness(video, from: 1.6, to: 1.9) > 0.05)   // back on
        #expect(try await loudness(video, from: 2.1, to: 2.4) > 0.05)   // after the cut
    }

    @Test func playsASpeedRegionFaster() async throws {
        // Trim 0.5–3.5 s with 1–2 s at 2×: 2.5 s long. The square moves 120 px/s from x = 20, so its position in a frame
        // gives the recording time that frame came from.
        var j = job(.mp4) { e in
            (e.callouts, e.zooms, e.padding, e.cursorHighlight, e.clickEffect) = ([], [], 0, false, nil)
            e.allSpeeds = [SpeedRegion(start: 1, end: 2, speed: 2)]
        }
        j.name = "My-demo-take-1-20260101-1200-speed"
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(abs(try await Probe.movie(video).duration - 2.5) < 0.15)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter) = (.zero, .zero)
        for (output, source) in [(0.75, 1.5), (1.5, 2.5)] {
            let frame = try await gen.image(at: CMTime(seconds: output, preferredTimescale: 600)).image
            var row = [UInt8](repeating: 0, count: frame.width * 4)
            CIContext().render(CIImage(cgImage: frame), toBitmap: &row, rowBytes: frame.width * 4, bounds: CGRect(x: 0, y: frame.height / 2, width: frame.width, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let left = (0..<frame.width).first { x in row[x * 4] > 220 && row[x * 4 + 1] > 220 && row[x * 4 + 2] > 220 }
            #expect(left.map { abs(Double($0) - (20 + 120 * source)) < 10 } == true, "output \(output) s: square at \(String(describing: left))")
        }
    }

    @Test func insertsAClipFittedInTheFrameAndShiftsWhatFollows() async throws {
        // A 2 s magenta clip, 16:9 so it's letterboxed in the 16:10 frame, inserted 1.5 s into the trim 0.5–3.5 s.
        let file = out.appending(path: "insert.mp4")
        try await synthesizeMovie(file, seconds: 2, solid: (0.9, 0.1, 0.8), size: (480, 270))
        var j = job(.mp4) { e in
            (e.callouts, e.zooms, e.padding, e.cursorHighlight, e.clickEffect) = ([], [], 0, false, nil)
            e.allMarkers = [Marker(t: 2.5, name: "Later")]
            e.insertClip(InsertedClip(path: file.path, name: "Phone shot", length: 2, width: 480, height: 270), at: 1.5)
        }
        j.name = "My-demo-take-1-20260101-1200-insert"
        #expect(j.edits.allClips.first?.at == 1.5)
        #expect(j.edits.allMarkers.first?.t == 4.5) // the recording's edits after it moved with it
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        let info = try await Probe.movie(video)
        #expect(abs(info.duration - 5) < 0.15) // 3 s of recording and the 2 s clip
        #expect(info.hasAudio)

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter) = (.zero, .zero)
        func frame(_ t: Double) async throws -> CGImage { try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image }
        func colour(_ img: CGImage, x: Int, yFromTop y: Int) -> (r: Int, g: Int, b: Int) {
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: img), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: img.height - 1 - y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        /// Where the test movie's white square is: it moves 120 px/s from x = 20, so it tells the recording time.
        func square(_ img: CGImage) -> Int? {
            var row = [UInt8](repeating: 0, count: img.width * 4)
            CIContext().render(CIImage(cgImage: img), toBitmap: &row, rowBytes: img.width * 4, bounds: CGRect(x: 0, y: img.height / 2, width: img.width, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (0..<img.width).first { x in row[x * 4] > 220 && row[x * 4 + 1] > 220 && row[x * 4 + 2] > 220 }
        }
        // Before the clip: recording time 1 s.
        let before = try await frame(0.5)
        #expect(square(before).map { abs($0 - 140) < 10 } == true)
        // During it (output 1–3 s): the clip fills the frame's width, centred, with black above and below.
        let during = try await frame(2)
        let w = during.width, h = during.height, fit = clipFit(width: 480, height: 270, inside: Double(w), Double(h))
        let mid = colour(during, x: w / 2, yFromTop: h / 2)
        #expect(mid.r > 180 && mid.b > 150 && mid.g < 80)
        let bar = colour(during, x: w / 2, yFromTop: Int(fit.y / 2))
        #expect(fit.y > 4 && bar.r < 30 && bar.g < 30 && bar.b < 30)
        // After it, the recording carries on where it left off: output 3.5 s is recording time 2 s.
        let after = try await frame(3.5)
        #expect(square(after).map { abs($0 - 260) < 10 } == true)
    }

    @Test func drawsAVideoOverlayInItsBoxOnlyInItsTimeAndMixesItsSoundOnlyWhenTurnedUp() async throws {
        // A silent recording, and a 2 s magenta overlay with a tone, 16:10 like its box: a quarter of the 640×400 frame
        // from (320, 200). It plays from timeline 1.0 s, shown 1.5–2.5 s (export 1.0–2.0 s, as the trim starts at 0.5 s).
        let quiet = out.appending(path: "quiet-overlay.mp4"), file = out.appending(path: "overlay.mp4")
        try await synthesizeMovie(quiet, seconds: 4, tone: false)
        try await synthesizeMovie(file, seconds: 2, solid: (0.9, 0.1, 0.8), size: (320, 200))
        func export(volume: Double?, _ tag: String) async throws -> URL {
            var j = job(.mp4) { e in
                (e.callouts, e.zooms, e.padding, e.cursorHighlight, e.clickEffect) = ([], [], 0, false, nil)
                var a = Annotation(kind: .video, start: 1.5, end: 2.5, x: 0.5, y: 0.5, w: 0.25, h: 0.25)
                a.video = OverlayVideo(path: file.path, name: "Product shot", at: 1, length: 2, width: 320, height: 200)
                a.video?.volume = volume
                a.video?.roundness = 0
                a.video?.shadow = 0
                e.allAnnotations = [a]
            }
            j.source = quiet
            j.name = "My-demo-take-1-20260101-1200-overlay-\(tag)"
            return URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        }
        let video = try await export(volume: nil, "silent")
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter) = (.zero, .zero)
        func magenta(_ t: Double, x: Int, yFromTop y: Int) async throws -> Bool {
            let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: img), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: img.height - 1 - y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px[0] > 180 && px[1] < 80 && px[2] > 150
        }
        // In its time: inside the box, near each corner and in the middle, but not just outside it.
        for (x, y) in [(400, 250), (326, 206), (474, 294)] { #expect(try await magenta(1.5, x: x, yFromTop: y), "(\(x), \(y)) inside the box") }
        for (x, y) in [(312, 250), (488, 250), (400, 192), (400, 308)] { #expect(try await !magenta(1.5, x: x, yFromTop: y), "(\(x), \(y)) outside the box") }
        // Before and after its time, nothing.
        #expect(try await !magenta(0.7, x: 400, yFromTop: 250))
        #expect(try await !magenta(2.3, x: 400, yFromTop: 250))
        // Its sound is off by default; turned up, it plays in its time and nowhere else.
        #expect(try await loudness(video, from: 1.1, to: 1.9) < 0.01)
        let loud = try await export(volume: 1, "sound")
        #expect(try await loudness(loud, from: 1.1, to: 1.9) > 0.05)
        #expect(try await loudness(loud, from: 0.1, to: 0.8) < 0.01)
        #expect(try await loudness(loud, from: 2.2, to: 2.9) < 0.01)
    }

    @Test func mutesPartsPlayedFasterThan2x() async throws {
        var j = job(.mp4) { e in (e.callouts, e.allSpeeds) = ([], [SpeedRegion(start: 1.5, end: 2.5, speed: 4)]) }
        j.name = "My-demo-take-1-20260101-1200-speed4"
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        // 0.5–1.5 s plays for 1 s, 1.5–2.5 s for 0.25 s, then 2.5–3.5 s.
        #expect(try await loudness(video, from: 0.2, to: 0.8) > 0.05)
        #expect(try await loudness(video, from: 1.05, to: 1.2) < 0.01)
        #expect(try await loudness(video, from: 1.5, to: 2.0) > 0.05)
    }

    @Test func exportsHEVCOverAnImageBackground() async throws {
        let wall = out.appending(path: "wallpaper.png")
        let grad = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 800, y: 0),
            "inputColor0": CIColor(red: 1, green: 0.5, blue: 0), "inputColor1": CIColor(red: 0.5, green: 0, blue: 1)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 500))
        try CIContext().writePNGRepresentation(of: grad, to: wall, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let res = try await Exporter.run(job(.hevc) { $0.backgroundImage = wall.path; $0.aspect = "1:1" }, transcribe: nil) { _, _ in }
        let info = try await Probe.movie(URL(fileURLWithPath: res.video))
        #expect(info.width == info.height) // square frame, recording letterboxed on the wallpaper
        let asset = AVURLAsset(url: URL(fileURLWithPath: res.video))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let codec = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_HEVC)
        // Top band of the square frame is wallpaper (orange→purple gradient, cover-cropped), not the video's red bar.
        let corner = try pixel(res.poster!, x: 4, yFromTop: 4)
        #expect(corner.r > 120 && corner.b > 60)
    }

    @Test func drawsTheWebcamBubbleFromASeparateCameraFile() async throws {
        let cam = out.appending(path: "camera.mov")
        try await synthesizeMovie(cam, seconds: 4, solid: (0.9, 0.1, 0.8), size: (480, 270)) // magenta: a colour the screen video never has
        var j = job(.mp4) { e in
            var style = CameraStyle()
            style.shrinkWhenZoomed = false
            e.camera = style
            e.callouts = []
        }
        j.camera = cam
        j.cameraOffset = 0.2
        j.name = "My-demo-take-1-20260101-1200-webcam"
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        let size = outputSize(width: 640, height: 400, j.edits)
        let r = cameraRect(size, j.edits.camera!, zoom: 1)
        let centre = try pixel(res.poster!, x: Int(r.x + r.d / 2), yFromTop: Int(r.y + r.d / 2))
        #expect(centre.r > 180 && centre.b > 150 && centre.g < 80) // the camera, not the screen or background
        let corner = try pixel(res.poster!, x: Int(r.x + 1), yFromTop: Int(r.y + 1)) // outside the circle: background
        #expect(!(corner.r > 180 && corner.b > 150 && corner.g < 80))

        // Hidden bubble: same spot shows the background instead.
        j.edits.camera?.visible = false
        j.name = "My-demo-take-1-20260101-1200-webcam-hidden"
        let hidden = try await Exporter.run(j, transcribe: nil) { _, _ in }
        let spot = try pixel(hidden.poster!, x: Int(r.x + r.d / 2), yFromTop: Int(r.y + r.d / 2))
        #expect(!(spot.r > 180 && spot.b > 150 && spot.g < 80))
    }

    @Test func drawsASquareBubbleWhereItWasDragged() async throws {
        let cam = out.appending(path: "camera-square.mov")
        try await synthesizeMovie(cam, seconds: 4, solid: (0.9, 0.1, 0.8), size: (480, 270)) // magenta
        func export(roundness: Double, _ tag: String) async throws -> (corner: (r: Int, g: Int, b: Int), rect: (x: Double, y: Double, d: Double)) {
            var j = job(.mp4) { e in
                var style = CameraStyle()
                style.shrinkWhenZoomed = false
                style.center = Point(x: 0.3, y: 0.4)
                style.roundness = roundness
                style.shadow = 0
                e.camera = style
                e.callouts = []
            }
            j.camera = cam
            j.name = "My-demo-take-1-20260101-1200-\(tag)"
            let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
            let r = cameraRect(outputSize(width: 640, height: 400, j.edits), j.edits.camera!, zoom: 1)
            // Just inside the bubble's top-left corner: covered by a square, outside a circle.
            return (try pixel(res.poster!, x: Int(r.x + 4), yFromTop: Int(r.y + 4)), r)
        }
        let square = try await export(roundness: 0, "bubble-square")
        let size = outputSize(width: 640, height: 400, job(.mp4).edits)
        #expect(abs(square.rect.x + square.rect.d / 2 - 0.3 * Double(size.width)) < 1) // centred where it was dropped
        #expect(square.corner.r > 180 && square.corner.b > 150 && square.corner.g < 80) // the camera
        let circle = try await export(roundness: 1, "bubble-circle")
        #expect(!(circle.corner.r > 180 && circle.corner.b > 150 && circle.corner.g < 80))
    }

    @Test func hidesAWindowRecordingsBlackCornersEvenWhenZoomed() async throws {
        let win = out.appending(path: "window.mp4")
        try await synthesizeMovie(win, seconds: 4, solid: (0.9, 0.9, 0.9), windowCorner: 52)
        func export(_ cornerPx: Double?, _ tag: String) async throws -> (r: Int, g: Int, b: Int) {
            var j = job(.mp4) { e in
                e.callouts = []
                e.cursorHighlight = false
                e.zooms = [Zoom(start: 0, end: 4, scale: 2, focus: Point(x: 0, y: 0))] // parked on the top-left corner
                e.cornerRadius = 0 // square frame: only the window mask can hide the corner
            }
            j.source = win
            j.windowCornerPx = cornerPx
            j.name = "My-demo-take-1-20260101-1200-\(tag)"
            let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
            let size = outputSize(width: 640, height: 400, j.edits)
            // 10 px in from the content's corner: inside the window's corner curve, which is doubled by the 2× zoom.
            return try pixel(res.poster!, x: size.x + 10, yFromTop: size.y + 10)
        }
        let masked = try await export(52, "window-masked")
        #expect(abs(masked.r - 0x20) < 14 && abs(masked.g - 0x40) < 14 && abs(masked.b - 0x60) < 14) // background shows through
        let unmasked = try await export(nil, "window-unmasked")
        #expect(unmasked.r < 30 && unmasked.g < 30 && unmasked.b < 30) // without it, the capture's black corner shows
    }

    @Test func drawsTheFrameShadowOnlyWhenItsOn() async throws {
        func export(_ shadow: Double, _ tag: String) async throws -> (r: Int, g: Int, b: Int) {
            var j = job(.mp4) { e in
                e.callouts = []
                e.cursorHighlight = false
                e.zooms = []
                e.shadow = shadow
                e.shadowSoftness = 1 // spread it far enough to reach past the video's compression fringe
            }
            j.name = "My-demo-take-1-20260101-1200-\(tag)"
            let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
            let size = outputSize(width: 640, height: 400, j.edits)
            // On the background below the middle of the frame's bottom edge, where the shadow falls. 14 px down
            // clears the 16 px block holding the edge, so the video's colour bars don't smear into the sample.
            return try pixel(res.poster!, x: size.x + size.contentW / 2, yFromTop: size.y + size.contentH + 14)
        }
        let on = try await export(1, "shadow-on"), off = try await export(0, "shadow-off")
        #expect(abs(off.r - 0x20) < 14 && abs(off.g - 0x40) < 14 && abs(off.b - 0x60) < 14) // plain background
        #expect(on.r + on.g + on.b < off.r + off.g + off.b - 30)                              // clearly darker
    }

    @Test func exportsALoopingGIFWithTheChosenFramesAndWidth() async throws {
        func export(_ o: GIFOptions, _ tag: String) async throws -> (res: ExportResult, count: Int, width: Int, height: Int, loop: Int?, delay: Double?) {
            var j = job(.gif)
            j.gif = o
            j.name = "My-demo-take-1-20260101-1200-\(tag)"
            let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
            let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: res.video) as CFURL, nil))
            let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
            let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
            let frame = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double
            let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            return (res, CGImageSourceGetCount(src), image.width, image.height, loop, delay)
        }
        let canvas = outputSize(width: 640, height: 400, job(.gif).edits) // 716×476 with the default padding

        let a = try await export(GIFOptions(fps: 10, width: 480, loops: true), "gif-10")
        #expect(a.res.video.hasSuffix(".gif"))
        #expect(a.count == 30) // the 3 s trim at 10 fps
        #expect(a.width == 480 && a.height == gifSize(canvas, GIFOptions(width: 480)).height)
        #expect(a.loop == 0)   // forever
        #expect(abs((a.delay ?? 0) - 0.1) < 0.011)
        #expect(FileManager.default.fileExists(atPath: a.res.poster!))
        #expect(try String(contentsOfFile: a.res.transcript!, encoding: .utf8).contains("no sound"))

        let b = try await export(GIFOptions(fps: 15, width: 1080, loops: false), "gif-15")
        #expect(b.count == 45)
        #expect(b.width == canvas.width) // 1080 is wider than the canvas, so it isn't scaled up
        #expect(b.loop != 0)             // plays once

        // The padding shows the background colour in the GIF too, so it came from the same renderer as the video.
        let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: b.res.video) as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: first), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 4, y: first.height - 5, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(abs(Int(px[0]) - 0x20) < 16 && abs(Int(px[1]) - 0x40) < 16 && abs(Int(px[2]) - 0x60) < 16)
    }

    @Test func exportsAtTheChosenResolutionAndBitrate() async throws {
        let big = out.appending(path: "big.mp4")
        try await synthesizeMovie(big, seconds: 4, size: (1600, 1000))
        var j = job(.mp4) { $0.callouts = [] }
        j.source = big
        j.width = 1600
        j.height = 1000
        j.resolution = .p720
        j.quality = .standard
        j.name = "My-demo-take-1-20260101-1200-720p"
        let res = try await Exporter.run(j, transcribe: nil) { _, _ in }
        let info = try await Probe.movie(URL(fileURLWithPath: res.video))
        let want = outputSize(width: 1600, height: 1000, j.edits, maxLongSide: 1280)
        #expect(want.width == 1280)                                // the padded frame's long side is the preset
        #expect(info.width == want.width && info.height == want.height)
        #expect(info.hasAudio)
        #expect(abs(info.duration - 3) < 0.15)
        // The writer was given a bitrate; the encoder may undershoot on this simple picture, but shouldn't blow past it.
        let track = try #require(try await AVURLAsset(url: URL(fileURLWithPath: res.video)).loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.estimatedDataRate)
        #expect(Double(rate) < Double(exportBitrate(width: want.width, height: want.height, fps: 30, .standard, hevc: false)) * 2)
    }

    @Test func mixesTheExtraAudioOnlyWhereItIsPlaced() async throws {
        let quiet = out.appending(path: "quiet.mp4")
        do { try await synthesizeMovie(quiet, seconds: 4, tone: false) } // a silent microphone, so only the extra track makes sound
        catch { Issue.record("step 1, making the silent recording: \(error)"); return }
        let music = out.appending(path: "music.wav")
        try writeTone(music, seconds: 3)
        let toneLength = try await AVURLAsset(url: music).load(.duration).seconds
        try #require(abs(toneLength - 3) < 0.05, "the tone file reads as \(toneLength) s")
        let track = AudioTrack(path: music.path, fileDuration: 3, at: 1.0, from: 0.5, length: 1.5, volume: 1, fadeIn: 0, fadeOut: 0)

        // The pieces the exporter uses, one at a time, so a failure says which one.
        let src: Sources
        do { src = try await Sources.load(screen: quiet, camera: nil, offset: 0, music: track) }
        catch { Issue.record("step 2, adding the music to the composition: \(error)"); return }
        #expect(src.musicTrack != nil, "step 2: the music track wasn't added")
        let tracks = try await src.asset.loadTracks(withMediaType: .audio)
        let steps: [(String, AVAudioMix?)] = [("step 3, reading the mixed sound", nil),
                                              ("step 4, reading it with the volume curve", AudioMixer.make(src, music: track, voice: []))]
        for (step, mix) in steps {
            let reader = try AVAssetReader(asset: src.asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 3.5, preferredTimescale: 600))
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            output.audioMix = mix
            reader.add(output)
            guard reader.startReading() else { Issue.record("\(step) (\(tracks.count) tracks): \(String(describing: reader.error))"); return }
            var samples = 0
            while output.copyNextSampleBuffer() != nil { samples += 1 }
            if reader.status == .failed { Issue.record("\(step), partway: \(String(describing: reader.error))"); return }
            #expect(samples > 0, "\(step): no sound came out")
        }

        var j = job(.mp4) { e in
            e.callouts = []
            // 1.5 s of the file from 1.0 s in the recording: 0.5–2.0 s in the export, whose trim starts at 0.5 s.
            e.audio = AudioTrack(path: music.path, fileDuration: 3, at: 1.0, from: 0.5, length: 1.5, volume: 1, fadeIn: 0, fadeOut: 0)
        }
        j.source = quiet
        j.name = "My-demo-take-1-20260101-1200-music"
        let res: ExportResult
        do { res = try await Exporter.run(j, transcribe: nil) { _, _ in } }
        catch { Issue.record("step 5, the full export: \(error)"); return }
        let video = URL(fileURLWithPath: res.video)
        let before = try await loudness(video, from: 0.05, to: 0.35)
        let during = try await loudness(video, from: 0.8, to: 1.7)
        let after = try await loudness(video, from: 2.3, to: 2.9)
        #expect(during > 0.1)                    // the tone
        #expect(before < 0.01 && after < 0.01)   // silence either side of it

        // Silencing a stretch of it (recording 1.4–1.8 s, export 0.9–1.3 s) quiets just that stretch.
        j.edits.toggleSilence(.music, Trim(start: 1.4, end: 1.8))
        j.name = "My-demo-take-1-20260101-1200-music-silenced"
        let part = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(try await loudness(part, from: 0.95, to: 1.25) < 0.01)
        #expect(try await loudness(part, from: 1.4, to: 1.7) > 0.1)
        j.edits.silenced = nil

        // Volume 0 mutes it entirely: the mix is applied, not just the track.
        j.edits.audio?.volume = 0
        j.name = "My-demo-take-1-20260101-1200-music-muted"
        let muted = try await Exporter.run(j, transcribe: nil) { _, _ in }
        #expect(try await loudness(URL(fileURLWithPath: muted.video), from: 0.8, to: 1.7) < 0.01)
    }

    @Test func mixesSystemAudioAtItsOffsetAndBalancesItAgainstTheMicrophone() async throws {
        let quiet = out.appending(path: "quiet-system.mp4")
        try await synthesizeMovie(quiet, seconds: 4, tone: false)
        let system = out.appending(path: "system.wav")
        try writeTone(system, seconds: 3)

        // A file that started before the screen loses its head: half a second early means it plays from 0.5 s in, at 0.
        let early = try await Sources.load(screen: quiet, camera: nil, offset: 0, system: system, systemOffset: -0.5)
        let span = try #require(try await early.systemTrack?.load(.timeRange))
        #expect(abs(span.start.seconds) < 0.01 && abs(span.duration.seconds - 2.5) < 0.05)

        // System audio from 1 s in the recording: from 0.5 s in the export, whose trim starts at 0.5 s.
        var j = job(.mp4) { $0.callouts = [] }
        j.source = quiet
        j.systemAudio = system
        j.systemAudioOffset = 1
        j.name = "My-demo-take-1-20260101-1200-system"
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(try await loudness(video, from: 0.05, to: 0.35) < 0.01)
        #expect(try await loudness(video, from: 1.0, to: 2.0) > 0.1)

        j.edits.systemVolume = 0
        j.name = "My-demo-take-1-20260101-1200-system-muted"
        let muted = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(try await loudness(muted, from: 1.0, to: 2.0) < 0.01)

        // A muted microphone (the 440 Hz tone in `raw`) leaves only the system audio, from 2 s in: 1.5 s in the export.
        j.source = raw
        j.edits.systemVolume = nil
        j.edits.micVolume = 0
        j.systemAudioOffset = 2
        j.name = "My-demo-take-1-20260101-1200-mic-muted"
        let micMuted = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        #expect(try await loudness(micMuted, from: 0.1, to: 0.9) < 0.01)
        #expect(try await loudness(micMuted, from: 2.0, to: 2.8) > 0.1)
    }

    @Test func cleansUpTheMicrophoneIntoACopyAndExportsIt() async throws {
        let folder = out.appending(path: "mic-cleanup")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = folder.appending(path: "raw.mp4")
        try FileManager.default.copyItem(at: raw, to: screen)
        let original = try Data(contentsOf: screen)

        let cleanup = MicCleanup(noise: .light, normalize: true)
        let mic = try #require(try await MicCleaner.file(for: screen, in: folder, cleanup))
        #expect(mic.url.lastPathComponent == "mic-light-normalized.m4a")
        #expect(abs(mic.offset) < 0.05)
        let copy = try #require(try await MicCleaner.read(mic.url))
        #expect(abs(Double(copy.channels[0].count) / 48_000 - 4) < 0.1) // as long as the recording
        #expect(abs(try #require(integratedLoudness(copy.channels, rate: 48_000)) - MicCleanup.target) < 1)
        #expect(try Data(contentsOf: screen) == original) // the recording itself is untouched

        // The same settings reuse the copy; new ones replace it, and turning everything off needs none.
        let made = try FileManager.default.attributesOfItem(atPath: mic.url.path)[.modificationDate] as? Date
        #expect(try await MicCleaner.file(for: screen, in: folder, cleanup) == mic)
        #expect(try FileManager.default.attributesOfItem(atPath: mic.url.path)[.modificationDate] as? Date == made)
        let normalized = try #require(try await MicCleaner.file(for: screen, in: folder, MicCleanup(normalize: true)))
        #expect(normalized.url.lastPathComponent == "mic-off-normalized.m4a")
        #expect(!FileManager.default.fileExists(atPath: mic.url.path))
        #expect(try await MicCleaner.file(for: screen, in: folder, MicCleanup()) == nil)

        // The 440 Hz tone in `raw` plays at about -12 LUFS; exported with loudness normalized, at the target.
        let before = try #require(try await MicCleaner.read(screen))
        #expect(try #require(integratedLoudness(before.channels, rate: 48_000)) > MicCleanup.target + 2)
        var j = job(.mp4) { $0.callouts = []; $0.trim = Trim(start: 0, end: 4); $0.micCleanup = MicCleanup(normalize: true) }
        j.source = screen
        j.outDir = folder
        j.name = "My-demo-take-1-20260101-1200-mic-cleanup"
        let video = URL(fileURLWithPath: try await Exporter.run(j, transcribe: nil) { _, _ in }.video)
        let exported = try #require(try await MicCleaner.read(video))
        #expect(abs(try #require(integratedLoudness(exported.channels, rate: 48_000)) - MicCleanup.target) < 1)
        #expect(try Data(contentsOf: screen) == original)
    }

    @Test func readsLoudnessForTheTimelineWaveforms() async throws {
        let tone = out.appending(path: "levels.wav")
        try writeTone(tone, seconds: 2)
        let levels = try await AudioLevels.read(tone, window: 0.1)
        #expect(abs(levels.count - 20) <= 1)
        #expect(levels.allSatisfy { abs($0 - 0.35) < 0.05 }) // a 0.5 sine is 0.35 RMS
        let quiet = out.appending(path: "quiet-levels.mp4")
        try await synthesizeMovie(quiet, seconds: 2, tone: false)
        #expect(try await AudioLevels.read(quiet).allSatisfy { $0 < 0.01 })
    }

    @Test func rejectsInvalidEditsBeforeRendering() async {
        await #expect(throws: StudioError.self) {
            try await Exporter.run(job(.mp4) { $0.trim = Trim(start: 3, end: 3.1) }, transcribe: nil) { _, _ in }
        }
    }
}

@Suite struct LibraryStore {
    /// A recording whose folder is deleted outside the app is listed as missing, works again when the folder comes
    /// back, and Remove from Library takes its row away.
    @Test func reportsRecordingsWhoseFilesAreGone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library(root: root)
        let dir = root.appending(path: "recordings/1700000000000"), away = root.appending(path: "away")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)
        try await lib.insert(id: "1700000000000", title: "First", dir: dir)
        #expect(try lib.list().map(\.isMissing) == [false])

        try FileManager.default.moveItem(at: dir, to: away)
        #expect(try lib.list().map(\.isMissing) == [true])
        try FileManager.default.moveItem(at: away, to: dir)
        #expect(try lib.list().map(\.isMissing) == [false])

        try FileManager.default.removeItem(at: dir)
        let rec = try #require(try lib.list().first)
        #expect(rec.isMissing)
        #expect(try lib.delete(id: rec.id).isEmpty) // nothing left to move to the Trash
        #expect(try lib.list().isEmpty)
    }

    @Test func storesListsUpdatesAndDeletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library(root: root)
        let dir = root.appending(path: "recordings/1700000000000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)

        try await lib.insert(id: "1700000000000", title: "First", dir: dir)
        var e = Edits(trim: Trim(start: 0, end: 1))
        e.padding = 0.1
        try lib.saveEdits(id: "1700000000000", title: "Renamed", edits: e)
        try lib.addExport(id: "1700000000000", path: "/x/a.mp4", preset: "mp4")
        let rec = try #require(try lib.list().first)
        #expect(rec.title == "Renamed" && rec.width == 640 && rec.hasAudio && rec.exports.count == 1)
        // Saving changed edits moves the edit time; saving the same again doesn't.
        #expect(rec.editedAt > rec.createdAt)
        let later = Date(timeIntervalSinceNow: 3600)
        #expect(try lib.saveEdits(id: rec.id, title: "Renamed", edits: e, at: later).editedAt == rec.editedAt)
        e.padding = 0.12
        #expect(try lib.saveEdits(id: rec.id, title: "Renamed", edits: e, at: later).editedAt == Int64(later.timeIntervalSince1970 * 1000))
        #expect(try JSONDecoder().decode(Edits.self, from: Data(rec.edits!.utf8)).padding == 0.1)

        // Deleting moves the folder and the autosaved project files to the Trash; undoing brings back the folder,
        // the project files, the row, its edits and exports.
        let projects = lib.root.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let project = projects.appending(path: "Renamed-\(rec.id).recordstudio"), other = projects.appending(path: "Other-1.recordstudio")
        try Data("p".utf8).write(to: project)
        try Data("o".utf8).write(to: other)
        let trashed = try lib.delete(id: rec.id)
        #expect(try lib.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path) && !FileManager.default.fileExists(atPath: project.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: try #require(trashed[dir]).appending(path: "raw.mp4").path))
        #expect(FileManager.default.fileExists(atPath: try #require(trashed[project]).path))
        try lib.restore(rec, from: trashed)
        #expect(try lib.list() == [rec])
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "raw.mp4").path) && FileManager.default.fileExists(atPath: project.path))
        #expect(trashed.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for url in try lib.delete(id: rec.id).values { try FileManager.default.removeItem(at: url) } // don't leave test files in the Trash
        #expect(try lib.list().isEmpty)

        // A folder left behind by a crash comes back on the next launch.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)
        await lib.recoverOrphans()
        #expect(try lib.list().first?.title == "Recovered recording")
    }

    @Test func opensEditsAndNamesExportsWithoutAnEditor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rec = Recording(id: "1", title: "Demo: take", createdAt: 0, dir: root.path, duration: 4, width: 640, height: 400, fps: 30, hasAudio: true)
        // Not edited yet: the starting edits. Saved edits are read back; unreadable ones throw rather than being replaced.
        #expect(try rec.openingEdits(cursor: []) == rec.startingEdits(cursor: []))
        var e = Edits(trim: Trim(start: 1, end: 3))
        e.padding = 0.2
        rec.edits = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(try rec.openingEdits(cursor: []).padding == 0.2)
        rec.edits = "{"
        #expect(throws: (any Error).self) { try rec.openingEdits(cursor: []) }

        // Named after the title; another recording's file and one taken earlier in the batch are kept, the recording's
        // own earlier export is replaced.
        let folder = root.path
        #expect(rec.exportName(folder: folder, format: .mp4, extras: [], taken: []) == "Demo- take")
        try Data().write(to: root.appending(path: "Demo- take.mp4"))
        #expect(rec.exportName(folder: folder, format: .mp4, extras: [], taken: []) == "Demo- take 2")
        #expect(rec.exportName(folder: folder, format: .webm, extras: [], taken: []) == "Demo- take")
        rec.exports = [ExportRow(path: root.appending(path: "Demo- take.mp4").path, preset: "mp4", createdAt: 0)]
        #expect(rec.exportName(folder: folder, format: .mp4, extras: [], taken: []) == "Demo- take")
        #expect(rec.exportName(folder: folder, format: .mp4, extras: [], taken: [root.appending(path: "Demo- take.mp4").path]) == "Demo- take 2")

        // With extras, the export is a folder: another export's folder is kept, the recording's own is replaced.
        #expect(rec.exportName(folder: folder, format: .mp4, extras: .transcript, taken: []) == "Demo- take")
        let own = root.appending(path: "Demo- take/Demo- take.mp4")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(rec.exportName(folder: folder, format: .mp4, extras: .transcript, taken: []) == "Demo- take 2")
        rec.exports = [ExportRow(path: own.path, preset: "mp4", createdAt: 0)]
        #expect(rec.exportName(folder: folder, format: .mp4, extras: .transcript, taken: []) == "Demo- take")
        #expect(rec.exportName(folder: folder, format: .mp4, extras: .transcript, taken: [own.path]) == "Demo- take 2")
    }

    @Test func searchesSortsAndRenames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try Library(root: root)
        let dir = root.appending(path: "recordings/1700000000000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)
        try await lib.insert(id: "1700000000000", title: "Café demo", dir: dir)
        var e = Edits(trim: Trim(start: 0, end: 1))
        e.captions = Captions(lines: [CaptionLine("Hello there", start: 0, end: 0.5), CaptionLine("Now open Settings", start: 0.5, end: 1)])
        try lib.saveEdits(id: "1700000000000", title: "Café demo", edits: e)
        let rec = try #require(try lib.list().first)

        // The title matches ignoring case and accents; what's said matches by its caption line.
        #expect(rec.titleMatches("cafe") && !rec.titleMatches("settings"))
        #expect(rec.spokenMatch("settings") == "Now open Settings" && rec.spokenMatch("goodbye") == nil)
        #expect(rec.diskSize > 0)

        // Renaming counts as an edit; renaming to the same title doesn't.
        try lib.rename(id: rec.id, title: "Tour", at: Date(timeIntervalSince1970: 1800000000))
        #expect(try lib.list().first?.title == "Tour" && lib.list().first?.editedAt == 1800000000000)
        try lib.rename(id: rec.id, title: "Tour", at: Date(timeIntervalSince1970: 1900000000))
        #expect(try lib.list().first?.editedAt == 1800000000000)

        func r(_ title: String, created: Int64, edited: Int64, length: Double) -> Recording {
            Recording(id: title, title: title, createdAt: created, dir: "", duration: length, width: 1, height: 1, fps: 30, hasAudio: true, editedAt: edited)
        }
        let recs = [r("b", created: 1, edited: 3, length: 5), r("A", created: 2, edited: 1, length: 9), r("c", created: 3, edited: 2, length: 1)]
        #expect(LibrarySort.created.sorted(recs).map(\.title) == ["c", "A", "b"])
        #expect(LibrarySort.edited.sorted(recs).map(\.title) == ["b", "c", "A"])
        #expect(LibrarySort.title.sorted(recs).map(\.title) == ["A", "b", "c"])
        #expect(LibrarySort.length.sorted(recs).map(\.title) == ["A", "b", "c"])
    }

    @Test func addsTheEditTimeToAnOlderLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rs-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(root.appending(path: "library.sqlite").path, &db)
        sqlite3_exec(db, """
            CREATE TABLE recordings(id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL, dir TEXT NOT NULL,
              duration REAL NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, fps REAL NOT NULL, has_audio INTEGER NOT NULL, edits TEXT);
            INSERT INTO recordings VALUES('1', 'Old', 1700000000000, '/x', 1, 640, 400, 30, 1, NULL);
            """, nil, nil, nil)
        sqlite3_close(db)
        #expect(try Library(root: root).list().first?.editedAt == 1700000000000)
        #expect(try Library(root: root).list().count == 1) // opening it again doesn't add the column twice
    }

    @Test func movesALegacyLibraryAndRewritesItsPaths() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "rs-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appending(path: "Record Studio"), new = base.appending(path: "RecordStudio")
        let lib = try Library(root: old)
        let dir = old.appending(path: "recordings/1700000000001")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)
        try await lib.insert(id: "1700000000001", title: "Old", dir: dir)
        var e = Edits(trim: Trim(start: 0, end: 1))
        e.backgroundImage = old.appending(path: "backgrounds/import-1.png").path
        try lib.saveEdits(id: "1700000000001", title: "Old", edits: e)
        try lib.addExport(id: "1700000000001", path: old.appending(path: "exports/a.mp4").path, preset: "mp4")

        #expect(try Library.moveLegacyFolder(from: old, to: new))
        let moved = try Library(root: new)
        try moved.rewritePaths(from: old.path, to: new.path)
        let rec = try #require(try moved.list().first)
        #expect(rec.dir == new.appending(path: "recordings/1700000000001").path)
        #expect(FileManager.default.fileExists(atPath: rec.path))
        #expect(rec.exports.first?.path == new.appending(path: "exports/a.mp4").path)
        let edits = try JSONDecoder().decode(Edits.self, from: Data(rec.edits!.utf8))
        #expect(edits.backgroundImage == new.appending(path: "backgrounds/import-1.png").path)
        #expect(try !Library.moveLegacyFolder(from: old, to: new)) // never runs twice or overwrites
    }

    @Test func confinesPathsToTheDataFolder() {
        let root = URL(fileURLWithPath: "/data")
        #expect(Paths.inside("/data/recordings/1/raw.mp4", root: root))
        #expect(!Paths.inside("/data/../etc/passwd", root: root))
        #expect(!Paths.inside("/database/x", root: root))
        #expect(!Paths.inside("relative/x", root: root))
    }

    @Test func copiesAnImageForAnAnnotation() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rs-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appending(path: "Pic.PNG")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: src)

        let images = dir.appending(path: "images")
        let copy = try Importer.image(src, into: images)
        #expect(copy.aspect == 2)
        #expect(copy.path.hasPrefix(images.path) && copy.path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(throws: StudioError.self) { try Importer.image(dir.appending(path: "notes.txt"), into: images) }
    }
}

@Suite struct ProjectFiles {
    let base = FileManager.default.temporaryDirectory.appending(path: "rs-project-test-\(UUID().uuidString)")

    /// A library with one recording whose edits use music, a background image and an annotation image from outside it.
    func source() async throws -> (Library, Recording, Edits) {
        let lib = try Library(root: base.appending(path: "a"))
        let dir = lib.root.appending(path: "recordings/1700000000000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await synthesizeMovie(dir.appending(path: "raw.mp4"), seconds: 1)
        try Data("[]".utf8).write(to: dir.appending(path: "cursor.json"))
        let elsewhere = base.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for f in ["song.m4a", "wall.png", "logo.png"] { try Data(f.utf8).write(to: elsewhere.appending(path: f)) }
        let rec = try await lib.insert(id: "1700000000000", title: "Demo", dir: dir)
        var e = Edits(trim: Trim(start: 0, end: 1))
        e.backgroundImage = elsewhere.appending(path: "wall.png").path
        e.audio = AudioTrack(path: elsewhere.appending(path: "song.m4a").path, fileDuration: 1, at: 0, length: 1)
        e.allAnnotations = [Annotation(kind: .image, start: 0, end: 1, x: 0, y: 0, w: 0.2, h: 0.2, image: elsewhere.appending(path: "logo.png").path),
                            Annotation(kind: .arrow, start: 0, end: 1, x: 0, y: 0, w: 0.1, h: 0.1)]
        try lib.saveEdits(id: rec.id, title: "Demo", edits: e)
        return (lib, rec, e)
    }

    /// The sample project the app ships (Help › Open Sample Project) opens, renders, and shows each feature once.
    @Test func sampleProjectOpensWithAnEditOfEachKind() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let file = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Sample.recordstudio")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size < 10_000_000) // it ships inside the app
        let lib = try Library(root: base.appending(path: "sample"))
        let rec = try await Project.open(file, into: lib)
        #expect(rec.title == "Sample — Getting started" && rec.hasAudio && rec.duration > 30)
        let e = try JSONDecoder().decode(Edits.self, from: Data(try #require(rec.edits).utf8))
        #expect(validateEdits(e, duration: rec.duration).isEmpty)
        #expect(e.zooms.count == 2 && e.zooms.contains { $0.focus != nil } && e.zooms.contains { $0.focus == nil })
        #expect(e.callouts.count == 1 && e.speeds?.count == 1 && (e.markers?.count ?? 0) > 1 && (e.captions?.lines.count ?? 0) > 5)
        #expect(clickTimes(rec.cursorSamples).count == 5) // the zooms and ripples come from real clicks
    }

    @Test func savesAndOpensInAnotherLibrary() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (_, rec, e) = try await source()
        let file = base.appending(path: "Demo.recordstudio")
        try await Project.save(rec, title: "Demo", edits: e, to: file)

        let other = try Library(root: base.appending(path: "b"))
        let opened = try await Project.open(file, into: other)
        let again = try await Project.open(file, into: other)
        #expect(try opened.id != again.id && other.list().count == 2) // twice: two copies
        #expect(opened.title == "Demo" && opened.createdAt == rec.createdAt && opened.dir != rec.dir)
        let got = try JSONDecoder().decode(Edits.self, from: Data(try #require(opened.edits).utf8))
        // Every file the edits use is inside the new recording's folder, with the same content.
        let paths = [got.backgroundImage, got.audio?.path, got.allAnnotations[0].image].compactMap { $0 }
        #expect(paths.count == 3)
        for p in paths { #expect(Paths.inside(p, root: URL(fileURLWithPath: opened.dir)) && FileManager.default.fileExists(atPath: p)) }
        #expect(String(decoding: FileManager.default.contents(atPath: got.audio!.path)!, as: UTF8.self) == "song.m4a")
        #expect(FileManager.default.fileExists(atPath: opened.cursorPath))
        // Apart from where the files are, the edits are the same.
        var same = got
        same.backgroundImage = e.backgroundImage; same.audio?.path = e.audio!.path; same.allAnnotations[0].image = e.allAnnotations[0].image
        #expect(same == e)
    }

    @Test func keepsOneProjectFilePerRecording() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let (lib, rec, e) = try await source()
        try await Project.autosave(rec, title: "Demo", edits: e, root: lib.root)
        try await Project.autosave(rec, title: "Demo: renamed", edits: e, root: lib.root) // a rename replaces the old file
        let files = try FileManager.default.contentsOfDirectory(atPath: lib.root.appending(path: "projects").path)
        #expect(files == ["Demo-renamed-1700000000000.recordstudio"])
        let opened = try await Project.open(Project.autosaveURL(id: rec.id, title: "Demo: renamed", root: lib.root), into: lib)
        #expect(opened.title == "Demo: renamed")
    }

    /// A project file whose manifest has been changed by `edit`.
    func tampered(_ name: String, _ edit: (inout [String: Any]) -> Void) async throws -> URL {
        let (_, rec, e) = try await source()
        let file = base.appending(path: "ok.recordstudio")
        try await Project.save(rec, title: "Demo", edits: e, to: file)
        let dir = base.appending(path: "unpacked-\(name)")
        try await Tools.run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path])
        let manifest = dir.appending(path: "project.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let out = base.appending(path: "\(name).recordstudio")
        try await Tools.run("/usr/bin/ditto", ["-c", "-k", dir.path, out.path])
        return out
    }

    @Test func refusesPathsOutsideTheProjectAndNewerVersions() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let escape = try await tampered("escape") { json in
            var edits = json["edits"] as! [String: Any]
            edits["backgroundImage"] = "assets/../../../../etc/hosts"
            json["edits"] = edits
        }
        let lib = try Library(root: base.appending(path: "c"))
        await #expect(throws: StudioError.self) { try await Project.open(escape, into: lib) }
        let absolute = try await tampered("absolute") { json in
            var edits = json["edits"] as! [String: Any]
            edits["backgroundImage"] = "/etc/hosts"
            json["edits"] = edits
        }
        await #expect(throws: StudioError.self) { try await Project.open(absolute, into: lib) }
        let newer = try await tampered("newer") { $0["version"] = 99 }
        do { try await Project.open(newer, into: lib); Issue.record("opened a newer project") }
        catch { #expect(error.localizedDescription.contains("newer version")) }
        #expect(try lib.list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.root.appending(path: "recordings").path).isEmpty) // nothing left behind
    }
}

@Suite struct CopyExport {
    @Test func putsTheFileOnTheClipboardAndAGIFAsAnImage() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("demo.mp4"), gif = dir.appendingPathComponent("demo.gif")
        try Data("mp4".utf8).write(to: video)
        try Data("GIF89a".utf8).write(to: gif)

        copyFile(video, to: pb)
        #expect(pb.readObjects(forClasses: [NSURL.self]) as? [URL] == [video])
        #expect(pb.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == nil)

        copyFile(gif, to: pb)
        #expect(pb.readObjects(forClasses: [NSURL.self]) as? [URL] == [gif])
        #expect(pb.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == Data("GIF89a".utf8))
    }
}

@Suite struct BlurBoxes {
    // A sharp black-and-white checkerboard "recording": high local contrast everywhere until something blurs it.
    let source: CIImage = {
        let f = CIFilter.checkerboardGenerator()
        f.color0 = .black
        f.color1 = .white
        f.width = 6
        f.center = .zero
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
    }()

    /// How much the brightness varies in a 24-pixel square around canvas point (x, y), top-left origin: 0 for flat.
    func contrast(_ img: CIImage, size: OutputSize, x: Double, y: Double) -> Double {
        let side = 24
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let cx = Int(x * Double(size.width)) - side / 2, cy = size.height - Int(y * Double(size.height)) - side / 2
        CIContext().render(img, toBitmap: &px, rowBytes: side * 4, bounds: CGRect(x: cx, y: cy, width: side, height: side),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let v = stride(from: 0, to: px.count, by: 4).map { Double(px[$0]) }
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    func renderer(_ box: Annotation, zoom: Zoom? = nil) -> FrameRenderer {
        var e = Edits(trim: Trim(start: 0, end: 10), padding: 0, cursorHighlight: false)
        e.allAnnotations = [box]
        if let zoom { e.zooms = [zoom] }
        return FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 10)
    }

    @Test(arguments: [false, true]) func hidesOnlyInsideTheBoxAndOnlyInItsTime(pixelate: Bool) {
        // The middle fifth of the recording, from 2 s to 4 s, with no fade.
        var box = Annotation(kind: .blur, start: 2, end: 4, x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        box.pixelate = pixelate ? true : nil
        let r = renderer(box)
        let on = r.render(source, at: 3)
        #expect(contrast(on, size: r.size, x: 0.5, y: 0.5) < 40)   // blurred or blocky: hardly any detail
        #expect(contrast(on, size: r.size, x: 0.15, y: 0.5) > 100) // outside: as sharp as the recording
        let off = r.render(source, at: 5)
        #expect(contrast(off, size: r.size, x: 0.5, y: 0.5) > 100) // after its time it's gone
    }

    @Test func staysOverTheSameContentWhenZoomedIn() {
        // A 2× zoom pinned on the recording's top-left quarter; the box covers part of that quarter.
        let box = Annotation(kind: .blur, start: 0, end: 10, x: 0.2, y: 0.2, w: 0.1, h: 0.1)
        let r = renderer(box, zoom: Zoom(start: 0, end: 10, scale: 2, focus: Point(x: 0.25, y: 0.25)))
        let img = r.render(source, at: 5)
        let e = r.edits, cam = r.camera(at: 5)
        #expect(cam.z > 1.9)
        let mid = canvasPoint(Point(x: 0.25, y: 0.25), e, r.size, camera: cam)
        #expect(abs(mid.x - 0.5) < 0.02 && abs(mid.y - 0.5) < 0.02) // the box's centre is in the middle of the zoomed frame
        #expect(contrast(img, size: r.size, x: mid.x, y: mid.y) < 40)
        let beside = canvasPoint(Point(x: 0.4, y: 0.25), e, r.size, camera: cam)
        #expect(contrast(img, size: r.size, x: beside.x, y: beside.y) > 100)
        // And back: canvas → recording → canvas lands where it started.
        let back = canvasPoint(sourcePoint(Point(x: 0.3, y: 0.7), e, r.size, camera: cam), e, r.size, camera: cam)
        #expect(abs(back.x - 0.3) < 1e-9 && abs(back.y - 0.7) < 1e-9)
    }
}

@Suite struct BurnedInCaptions {
    let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))

    /// How much the brightness varies across a band of the frame, top-left origin: 0 where it's flat.
    func detail(_ img: CIImage, size: OutputSize, top: Double, bottom: Double) -> Double {
        let y0 = Int(Double(size.height) * (1 - bottom)), h = Int(Double(size.height) * (bottom - top))
        var px = [UInt8](repeating: 0, count: size.width * h * 4)
        CIContext().render(img, toBitmap: &px, rowBytes: size.width * 4, bounds: CGRect(x: 0, y: y0, width: size.width, height: h),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let v = stride(from: 0, to: px.count, by: 4).map { Double(px[$0]) }
        let mean = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    func renderer(_ change: (inout Captions) -> Void = { _ in }) -> FrameRenderer {
        var e = Edits(trim: Trim(start: 0, end: 10), padding: 0, cursorHighlight: false)
        var c = Captions(lines: [CaptionLine("Hello from the captions", start: 2, end: 4)])
        change(&c)
        e.captions = c
        return FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 10)
    }

    @Test(arguments: [Captions.Style.box, .outline]) func showsTheLineOnlyInItsTime(style: Captions.Style) {
        let r = renderer { $0.style = style }
        let on = r.render(source, at: 3)
        #expect(detail(on, size: r.size, top: 0.7, bottom: 1) > 10)   // text along the bottom
        #expect(detail(on, size: r.size, top: 0, bottom: 0.3) < 1)    // nothing at the top
        #expect(detail(r.render(source, at: 5), size: r.size, top: 0.7, bottom: 1) < 1) // after its time it's gone
    }

    @Test func goesToTheTopWhenAsked() {
        let r = renderer { $0.position = .top }
        let on = r.render(source, at: 3)
        #expect(detail(on, size: r.size, top: 0, bottom: 0.3) > 10)
        #expect(detail(on, size: r.size, top: 0.7, bottom: 1) < 1)
    }

    @Test func drawsNothingWhenTurnedOff() {
        let r = renderer { $0.visible = false }
        #expect(detail(r.render(source, at: 3), size: r.size, top: 0, bottom: 1) < 1)
    }
}

@Test func libraryTileShowsExportOnlyWhenThereIsOne() throws {
    var rec = Recording(id: "1", title: "T", createdAt: 0, dir: "/tmp", duration: 1, width: 640, height: 400, fps: 30, hasAudio: true)
    #expect(rec.exportSummary() == nil)
    let now = Date(timeIntervalSince1970: 10_000)
    let file = FileManager.default.temporaryDirectory.appending(path: "rs-export-\(UUID().uuidString).gif")
    try Data("g".utf8).write(to: file)
    rec.exports = [ExportRow(path: file.path, preset: "gif", createdAt: 10_000_000 - 7_200_000)]
    let line = rec.exportSummary(now: now)
    #expect(line?.hasPrefix("Exported GIF · ") == true)
    #expect(line == "Exported GIF · \(RelativeDateTimeFormatter().localizedString(fromTimeInterval: -7200))")
    // An export whose file was deleted isn't shown.
    try FileManager.default.removeItem(at: file)
    #expect(rec.exportSummary(now: now) == nil && rec.latestExport == nil)
}

@Suite struct CaptionBox {
    /// The box the preview clicks covers the caption the renderer draws: centred, near the bottom, and only while it shows.
    @Test func matchesTheDrawnCaption() throws {
        var e = Edits(trim: Trim(start: 0, end: 4), padding: 0, cursorHighlight: false)
        e.captions = Captions(lines: [CaptionLine("Hello there", start: 1, end: 2)])
        let r = FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 4)
        #expect(r.captionBox(at: 0.5) == nil)
        let box = try #require(r.captionBox(at: 1.5))
        #expect(abs(box.midX - 0.5) < 0.01)
        #expect(box.maxY > 0.8 && box.maxY < 1)
        e.captions?.position = .top
        let top = try #require(FrameRenderer(edits: e, cursor: [], sourceWidth: 640, sourceHeight: 400, duration: 4).captionBox(at: 1.5))
        #expect(top.minY > 0 && top.minY < 0.1)
    }
}

/// The sample project's callout at x 0.55 used to run off the right edge at 1080p; a long one ran off any frame.
@Test func calloutsStayInsideTheFrame() throws {
    let (W, H) = (1920.0, 1080.0)
    let short = try #require(FrameRenderer.calloutImage("Callouts like this one are in the Insert menu.", canvasWidth: W, canvasHeight: H))
    let one = Callout(text: "", start: 0, end: 1, x: 0.55, y: 0.95)
    let o = calloutOrigin(one, w: short.extent.width / W, h: short.extent.height / H)
    #expect(o.x < 0.55 && abs(o.x * W + short.extent.width - W) < 1) // moved left until its right edge meets the frame's
    #expect(abs(o.y * H + short.extent.height - H) < 1)                  // and up off the bottom
    #expect(calloutOrigin(Callout(text: "", start: 0, end: 1, x: 0.1, y: 0.1), w: 0.2, h: 0.1) == (0.1, 0.1)) // fits: stays put

    let long = try #require(FrameRenderer.calloutImage(String(repeating: "Wrap this callout text please. ", count: 4), canvasWidth: W, canvasHeight: H))
    #expect(long.extent.width <= W * 0.9 && long.extent.height > short.extent.height * 1.4) // wrapped onto more lines
}
