import AVFoundation
import AppKit
import Foundation
import RecordCore
import Speech
import UniformTypeIdentifiers

/// Puts an exported file on the clipboard to paste into Slack, Mail, Finder and so on. A GIF also goes on as image
/// data, so apps that take images (but not files) paste the animation.
public func copyFile(_ url: URL, to pasteboard: NSPasteboard = .general) {
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    if url.pathExtension.lowercased() == "gif", let data = try? Data(contentsOf: url) {
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

/// The menu bar icon: the app icon's focus brackets around the record dot, 18 pt. Idle, it's a template image so it
/// follows the menu bar's colour. Recording, the menu bar would ignore a tint on a template, so the dot is drawn in the
/// brand red and the brackets in the label colour, which the drawing handler resolves for a light or dark menu bar.
public func menuBarIcon(recording: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let brackets = NSBezierPath()
        let (lo, hi, arm) = (2.5, 15.5, 4.5)
        for (x, y, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1, 1), (lo, hi, 1, -1), (hi, hi, -1, -1)] {
            brackets.move(to: NSPoint(x: x, y: y + dy * arm))
            brackets.line(to: NSPoint(x: x, y: y))
            brackets.line(to: NSPoint(x: x + dx * arm, y: y))
        }
        brackets.lineWidth = 1.6
        brackets.lineCapStyle = .round
        brackets.lineJoinStyle = .round
        (recording ? NSColor.labelColor : .black).set()
        brackets.stroke()
        if recording { NSColor(srgbRed: Brand.red.r, green: Brand.red.g, blue: Brand.red.b, alpha: 1).set() }
        NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
        return true
    }
    image.isTemplate = !recording
    image.accessibilityDescription = "RecordStudio"
    return image
}

/// The app's own interface follows the system, or stays Light or Dark (Settings › General). Exports don't change.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark
    public static let key = "appearance"

    public var label: String { rawValue.capitalized }
    /// For `NSApp.appearance`, which reaches AppKit-hosted windows, sheets and popovers as well as SwiftUI. Nil follows the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The saved choice, System when there's none.
    public static func saved(_ defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: key).flatMap(AppAppearance.init) ?? .system
    }

    /// Applies the saved choice; called at launch and when it changes.
    @MainActor public static func apply() { NSApp.appearance = saved().nsAppearance }
}

/// macOS wallpapers installed on this Mac. Core Image reads HEIC directly, so no conversion step is needed.
public struct Wallpaper: Identifiable, Hashable, Sendable {
    public var name: String, path: String, thumb: String
    public var id: String { path }
}

public enum Wallpapers {
    public static let root = "/System/Library/Desktop Pictures"

    public static func list() -> [Wallpaper] {
        let fm = FileManager.default
        let dirs = [root] + ((try? fm.contentsOfDirectory(atPath: root + "/.wallpapers")) ?? []).map { "\(root)/.wallpapers/\($0)" }
        var out: [Wallpaper] = []
        for dir in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let ext = (f as NSString).pathExtension.lowercased()
                guard ["heic", "jpg", "jpeg", "png"].contains(ext) else { continue }
                let path = "\(dir)/\(f)"
                // Placeholders for downloadable wallpapers are tiny; only offer the real thing.
                guard let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int, size > 1_000_000 else { continue }
                let name = (f as NSString).deletingPathExtension
                let thumb = ["\(root)/.thumbnails/\(name).heic", "\(dir)/\(name) Thumbnail@2x.png"].first { fm.fileExists(atPath: $0) } ?? path
                out.append(Wallpaper(name: name, path: path, thumb: thumb))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The wallpaper to switch to when there was none before: Sonoma if present, else the first one.
    public static func preferred() -> String? {
        let all = list()
        return (all.first { $0.name.localizedCaseInsensitiveContains("sonoma") } ?? all.first)?.path
    }
}

/// The one kind of fill behind the video. The renderer prefers an image to a gradient and a gradient to a colour, so
/// the kind is whichever of those is set first.
public enum BackgroundFill: String, CaseIterable, Sendable {
    case wallpaper, image, gradient, colour
    public var name: String { ["wallpaper": "Wallpaper", "image": "Image", "gradient": "Gradient", "colour": "Colour"][rawValue]! }
}

/// The last wallpaper, image and gradient replaced by another kind of fill, so switching back brings them back.
public struct BackgroundMemory: Sendable {
    public var wallpaper, image: String?
    public var gradient: BackgroundGradient?
    public init() {}
}

extension Edits {
    public var fill: BackgroundFill {
        if let img = backgroundImage { return img.hasPrefix(Wallpapers.root) ? .wallpaper : .image }
        return gradient != nil ? .gradient : .colour
    }

    /// Uses `kind` of fill, with its last settings from `memory` (a wallpaper falls back to `wallpaper`, a gradient to
    /// the first preset), and remembers what it replaces. False, changing nothing, when an image or wallpaper is
    /// needed and there's none to use. The colour is always kept, since nothing else is stored there.
    public mutating func setFill(_ kind: BackgroundFill, memory: inout BackgroundMemory, wallpaper: String?) -> Bool {
        guard kind != fill else { return true }
        let image: String?
        switch kind {
        case .wallpaper: image = memory.wallpaper ?? wallpaper
        case .image: image = memory.image
        case .gradient, .colour: image = nil
        }
        if kind == .wallpaper || kind == .image, image == nil { return false }
        if let img = backgroundImage { if fill == .wallpaper { memory.wallpaper = img } else { memory.image = img } }
        if let g = gradient { memory.gradient = g }
        backgroundImage = image
        // An image covers the gradient, so it can stay; a colour can't show through one.
        if kind == .gradient { gradient = memory.gradient ?? BackgroundGradient.presets[0] }
        if kind == .colour { gradient = nil }
        return true
    }
}

/// On-device speech recognition with `SpeechAnalyzer`, which follows long recordings to the end (the older
/// `SFSpeechRecognizer` only kept what was said last). Nothing leaves the Mac; the first use may download the
/// language's speech model.
public enum Transcriber {
    /// The text of an exported video.
    public static func transcribe(_ video: URL) async throws -> String {
        try await recognize(video).text
    }

    /// Each word said in a video, with when it was said (seconds into the file), for captions.
    public static func words(_ video: URL) async throws -> [CaptionWord] {
        try await recognize(video).words
    }

    private static func recognize(_ video: URL) async throws -> (text: String, words: [CaptionWord]) {
        let audio = try await AVURLAsset(url: video).loadTracks(withMediaType: .audio)
        if audio.isEmpty { throw TranscriptError("This recording has no audio.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptError("On-device speech recognition isn't available for your language.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: video)
        async let collected: (String, [CaptionWord]) = {
            var text: [String] = [], words: [CaptionWord] = []
            for try await result in transcriber.results {
                text.append(String(result.text.characters).trimmingCharacters(in: .whitespaces))
                for run in result.text.runs {
                    guard let r = run.audioTimeRange else { continue }
                    words.append(CaptionWord(String(result.text[run.range].characters), start: r.start.seconds, end: r.end.seconds))
                }
            }
            return (text.joined(separator: " "), words)
        }()
        if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
        else { await analyzer.cancelAndFinishNow() }
        return try await collected
    }

    struct TranscriptError: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
