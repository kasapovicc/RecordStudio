import Foundation
import ImageIO
import Testing

/// `make dmg` draws the install window's background with Resources/DiskImage/dmg-window. Finder writes the icon labels
/// over it in black in light mode and white in dark mode, so the picture under them has to read with both.
@Suite struct DiskImage {
    @Test func backgroundHasBothScalesAndLabelsReadInLightAndDark() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let folder = FileManager.default.temporaryDirectory.appending(path: "dmg-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["swift", root.appending(path: "Resources/DiskImage/dmg-window").path, "--render", folder.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let source = try #require(CGImageSourceCreateWithURL(folder.appending(path: ".background/background.tiff") as CFURL, nil))
        let images = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        #expect(images.map { [$0.width, $0.height] } == [[640, 400], [1280, 800]])

        // Read the 1× picture back as sRGB bytes and check the label line under each icon (icons centred at y 224, 128pt).
        let image = try #require(images.first)
        var pixels = [UInt8](repeating: 0, count: 640 * 400 * 4)
        let ctx = try #require(CGContext(data: &pixels, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 400))
        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = (y * 640 + x) * 4
            let c = (0..<3).map { v -> Double in
                let s = Double(pixels[i + v]) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        for x in [140, 176, 212, 428, 464, 500] {
            for y in [292, 300, 308] {
                let l = luminance(x, y)
                #expect((l + 0.05) / 0.05 >= 4.5, "black label at \(x), \(y)")
                #expect(1.05 / (l + 0.05) >= 4.5, "white label at \(x), \(y)")
            }
        }
    }
}
