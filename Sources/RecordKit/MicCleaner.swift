import AVFoundation
import RecordCore

/// A cleaned copy of a recording's microphone, which plays in place of the original sound (see `Sources.load`).
public struct CleanMic: Equatable, Sendable {
    public var url: URL
    /// Seconds into the screen recording at which the copy starts, like the system audio's offset.
    public var offset: Double
}

/// Writes the microphone with `MicCleanup` applied into the recording's folder, one file per setting (like
/// `mic-light-normalized.m4a`) next to a JSON file with its offset. The same settings reuse the file; making one for
/// new settings removes the others. `raw.mp4` is only read.
public enum MicCleaner {
    static let rate = 48_000.0
    /// Bumped when the processing changes, so older copies are made again.
    static let version = 1

    struct Info: Codable, Equatable {
        var cleanup: MicCleanup
        var offset: Double
        var version: Int
    }

    /// The cleaned copy for `cleanup`, made now if there isn't one yet. Nil when clean-up is off or there's no sound.
    public static func file(for screen: URL, in folder: URL, _ cleanup: MicCleanup) async throws -> CleanMic? {
        guard cleanup.isOn else { return nil }
        let audio = folder.appending(path: name(cleanup) + ".m4a"), sidecar = folder.appending(path: name(cleanup) + ".json")
        if let data = FileManager.default.contents(atPath: sidecar.path), let info = try? JSONDecoder().decode(Info.self, from: data),
           info.cleanup == cleanup, info.version == version, FileManager.default.fileExists(atPath: audio.path) {
            return CleanMic(url: audio, offset: info.offset)
        }
        let made = try await render(screen, cleanup, to: audio, sidecar: sidecar)
        // Copies for other settings are of no more use. One a player still has open stays readable until it lets go.
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where f.hasPrefix("mic-") && (f.hasSuffix(".m4a") || f.hasSuffix(".json")) && !f.hasPrefix(name(cleanup) + ".") {
            try? FileManager.default.removeItem(at: folder.appending(path: f))
        }
        return made
    }

    /// Distinct per setting, so making one never overwrites a file the preview may be playing.
    static func name(_ c: MicCleanup) -> String { "mic-\(c.noise.rawValue)" + (c.normalize ? "-normalized" : "") }

    @concurrent private static func render(_ screen: URL, _ cleanup: MicCleanup, to audio: URL, sidecar: URL) async throws -> CleanMic? {
        guard let sound = try await read(screen) else { return nil }
        try Task.checkCancellation()
        let cleaned = cleanMicrophone(sound.channels, rate: rate, cleanup)
        try Task.checkCancellation()
        // Written beside the final name and then moved, so a half-written file is never taken for a finished one.
        let temp = audio.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(8))-\(audio.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(cleaned, to: temp)
        try? FileManager.default.removeItem(at: sidecar)
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        try FileManager.default.moveItem(at: temp, to: audio)
        try JSONEncoder().encode(Info(cleanup: cleanup, offset: sound.offset, version: version)).write(to: sidecar)
        return CleanMic(url: audio, offset: sound.offset)
    }

    /// Every audio track of the screen file mixed to 48 kHz stereo, as the exporter hears it (a mono microphone is
    /// spread to both sides), and the time it starts at. Nil when there's no sound.
    static func read(_ screen: URL) async throws -> (channels: [[Float]], offset: Double)? {
        let asset = AVURLAsset(url: screen)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Couldn't read the microphone.") }
        var left: [Float] = [], right: [Float] = [], start: Double?
        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { continue }
            if start == nil { start = sample.presentationTimeStamp.seconds }
            let bytes = CMBlockBufferGetDataLength(block)
            var pcm = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            pcm.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            for i in stride(from: 0, to: pcm.count - 1, by: 2) {
                left.append(pcm[i])
                right.append(pcm[i + 1])
            }
        }
        if reader.status == .failed { throw reader.error ?? StudioError.message("Couldn't read the microphone.") }
        guard !left.isEmpty else { return nil }
        return ([left, right], start ?? 0)
    }

    /// AAC at 192 kbps: well above what a voice needs, so the copy sounds like the processing, not the encoding.
    static func write(_ channels: [[Float]], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count, AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 48_000, length = channels.first?.count ?? 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let data = buffer.floatChannelData else { throw StudioError.message("Couldn't write the cleaned microphone.") }
        for start in stride(from: 0, to: length, by: chunk) {
            let count = min(chunk, length - start)
            for (c, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { src in
                    data[c].update(from: src.baseAddress! + start, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
        file.close() // writes the header now; left to deinit it can happen too late, and the file reads as empty
    }
}
