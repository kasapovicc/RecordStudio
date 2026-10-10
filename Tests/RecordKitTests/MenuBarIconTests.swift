import AppKit
import Testing
import RecordCore
@testable import RecordKit

@Suite struct MenuBarIcon {
    /// Whether the icon is drawn at (x, y) in points, top-left origin.
    func inked(_ image: NSImage, _ x: Int, _ y: Int) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!)
        return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
    }

    @Test func isAnEighteenPointTemplateOfBracketsAroundTheDot() {
        let icon = menuBarIcon()
        #expect(icon.isTemplate) // so it follows the menu bar's colour
        #expect(icon.size == NSSize(width: 18, height: 18))
        #expect(inked(icon, 9, 9))                       // the record dot
        #expect(inked(icon, 2, 2) && inked(icon, 15, 15)) // bracket corners
        #expect(!inked(icon, 9, 2) && !inked(icon, 4, 9)) // gaps between the brackets and around the dot
    }

    @Test func recordingDrawsTheDotInBrandRed() throws {
        let icon = menuBarIcon(recording: true)
        #expect(!icon.isTemplate) // the menu bar ignores a tint on a template image
        let rep = NSBitmapImageRep(cgImage: icon.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!)
        let dot = try #require(rep.colorAt(x: 9, y: 9)?.usingColorSpace(.sRGB))
        // Loose bounds, since NSImage's cache shifts the exact sRGB values a little; it still fails for black or white.
        #expect(dot.redComponent > 0.8 && dot.greenComponent < 0.5 && dot.blueComponent < 0.5)
    }
}

@Suite struct Appearance {
    @Test func systemFollowsMacOSAndTheOthersAreFixed() {
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func readsTheSavedChoiceAndDefaultsToSystem() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppearanceTests.\(UUID())"))
        #expect(AppAppearance.saved(defaults) == .system)
        defaults.set("dark", forKey: AppAppearance.key)
        #expect(AppAppearance.saved(defaults) == .dark)
        defaults.set("sepia", forKey: AppAppearance.key)
        #expect(AppAppearance.saved(defaults) == .system)
    }
}
