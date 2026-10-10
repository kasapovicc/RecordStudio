import AVFoundation
import Foundation
import ImageIO
import RecordCore

/// Brings a video made elsewhere into the library, so it can be edited like a recording.
public enum Importer {
    public static let extensions = ["mov", "mp4", "m4v"]

    /// Copies `source` into `dir` as raw.mp4: rewrapped when its video and sound already fit in an MP4, re-encoded to
    /// H.264 otherwise. A video meant to be shown turned (from a phone) is re-encoded upright, since the renderer
    /// works on the frames as stored. Its sound becomes the microphone track. Returns when the file says it was made.
    @discardableResult
    public static func importVideo(_ source: URL, into dir: URL) async throws -> Date? {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset: AVURLAsset
        do {
            asset = try await convert(source, to: dir.appending(path: "raw.mp4"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        // The date it was shot, from its metadata, or else when the file was made.
        if let item = try await asset.load(.creationDate), let date = try await item.load(.dateValue) { return date }
        return try? source.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Copies a picture into `dir` (the library's images folder) so an image annotation keeps working if the original
    /// moves. Returns the copy's path and its width ÷ height (1 when the file doesn't say).
    public static func image(_ source: URL, into dir: URL = Paths.images) throws -> (path: String, aspect: Double) {
        let ext = source.pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { throw StudioError.message("Choose a HEIC, JPEG, PNG, TIFF or WebP image.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        var aspect = 1.0
        if let src = CGImageSourceCreateWithURL(dest as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, h > 0 {
            aspect = w / h
        }
        return (dest.path, aspect)
    }

    /// Copies `source` into a recording's `folder` (as clip-<id>.mp4, converted like an import) to be inserted into its
    /// timeline. Not yet placed: `at` is 0.
    public static func clip(_ source: URL, into folder: URL) async throws -> InsertedClip {
        let out = folder.appending(path: "clip-\(UUID().uuidString.prefix(8).lowercased()).mp4")
        _ = try await convert(source, to: out)
        do {
            let info = try await Probe.movie(out)
            guard info.duration.isFinite, info.duration >= 0.1 else { throw StudioError.message("“\(source.lastPathComponent)” is too short to insert.") }
            return InsertedClip(path: out.path, name: source.deletingPathExtension().lastPathComponent, length: info.duration,
                                width: info.width, height: info.height)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Writes `source` to `out` as an MP4: rewrapped when its video and sound already fit, re-encoded to H.264
    /// otherwise, and upright. Returns the source asset.
    static func convert(_ source: URL, to out: URL) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video: AVAssetTrack?, turned: Bool
        do {
            video = try await asset.loadTracks(withMediaType: .video).first
            turned = try await video?.load(.preferredTransform) ?? .identity != .identity
        } catch {
            throw StudioError.message("“\(source.lastPathComponent)” couldn’t be read. It may be damaged, or in a format this Mac can’t play.")
        }
        guard video != nil else { throw StudioError.message("“\(source.lastPathComponent)” has no video in it.") }
        let fits = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .mp4)
        let rewrap = fits && !turned
        guard let session = AVAssetExportSession(asset: asset, presetName: rewrap ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality) else {
            throw StudioError.message("“\(source.lastPathComponent)” can’t be converted.")
        }
        if turned { session.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset) }
        try? FileManager.default.removeItem(at: out)
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw StudioError.message("“\(source.lastPathComponent)” couldn’t be imported: \(error.localizedDescription)")
        }
        return asset
    }
}
