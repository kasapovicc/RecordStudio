import Foundation

/// Clean-up for the recording's microphone: background noise reduced, loudness evened out. Applied to a copy of the
/// microphone sound (see `MicCleaner` in RecordKit); the recording itself is never changed.
public struct MicCleanup: Codable, Equatable, Hashable, Sendable {
    public enum Noise: String, Codable, CaseIterable, Sendable {
        case off, light, strong

        public var label: String {
            switch self {
            case .off: "Off"
            case .light: "Light"
            case .strong: "Strong"
            }
        }

        /// How far above the noise a sound must rise to pass untouched, and how far the noise itself is turned down.
        var overSubtraction: Double { self == .strong ? 3 : 2 }
        var floor: Double { self == .strong ? 0.1 : 0.3 } // -20 dB or about -10 dB
    }

    /// Integrated loudness to aim for, in LUFS: the usual level for video on the web.
    public static let target = -16.0
    /// The limiter keeps peaks below this (-1 dBFS), so raising a quiet recording doesn't clip.
    public static let ceiling: Float = 0.891
    /// Never raise by more than this (dB): a nearly silent recording would only get louder hiss.
    public static let maxGain = 30.0

    public var noise = Noise.off
    public var normalize = false

    public init(noise: Noise = .off, normalize: Bool = false) { (self.noise, self.normalize) = (noise, normalize) }

    public var isOn: Bool { noise != .off || normalize }
}

/// Runs `cleanup` over the microphone's channels (all the same length) at `rate` Hz. `playedAs`: how many output
/// channels they fill, when that's more than there are (see `integratedLoudness`). A stereo pair that's really one
/// channel twice (a mono microphone, spread to both sides) is processed once.
public func cleanMicrophone(_ channels: [[Float]], rate: Double, _ cleanup: MicCleanup, playedAs outputs: Int? = nil) -> [[Float]] {
    guard cleanup.isOn, let first = channels.first else { return channels }
    if channels.count > 1, channels.dropFirst().allSatisfy({ $0 == first }) {
        let one = cleanMicrophone([first], rate: rate, cleanup, playedAs: max(outputs ?? 0, channels.count))[0]
        return Array(repeating: one, count: channels.count)
    }
    var out = cleanup.noise == .off ? channels : channels.map { reduceNoise($0, cleanup.noise) }
    if cleanup.normalize { normalizeLoudness(&out, rate: rate, playedAs: outputs ?? channels.count) }
    return out
}

// MARK: Noise reduction

/// Spectral gating. The noise's spectrum is learned from the quietest tenth of the recording (the gaps between words),
/// then every moment keeps the parts of its spectrum that rise well above it and turns the rest down. Steady noise
/// like fans and hum goes; speech stays.
public func reduceNoise(_ x: [Float], _ strength: MicCleanup.Noise) -> [Float] {
    let n = 1024, hop = n / 2, bins = n / 2 + 1
    guard strength != .off, x.count >= n else { return x }
    // The square root of a periodic Hann window, used on the way in and out: at 50% overlap the two add back to 1.
    let window = (0..<n).map { sin(Double.pi * Double($0) / Double(n)) }
    let starts = Array(stride(from: -hop, to: x.count, by: hop))
    let fft = FFT(n)
    var re = [Double](repeating: 0, count: n), im = re

    func load(_ start: Int) {
        for i in 0..<n {
            let j = start + i
            re[i] = j >= 0 && j < x.count ? Double(x[j]) * window[i] : 0
            im[i] = 0
        }
    }

    // The quietest tenth of frames that aren't digital silence (which would teach it there's no noise at all).
    let energy = starts.map { s in
        (0..<n).reduce(0.0) { sum, i in
            let j = s + i
            guard j >= 0, j < x.count else { return sum }
            let v = Double(x[j]) * window[i]
            return sum + v * v
        }
    }
    let audible = starts.indices.filter { energy[$0] > 1e-10 }
    guard !audible.isEmpty else { return x }
    let quiet = audible.sorted { energy[$0] < energy[$1] }.prefix(max(1, audible.count / 10))
    var noise = [Double](repeating: 0, count: bins)
    for f in quiet {
        load(starts[f])
        fft.transform(&re, &im, inverse: false)
        for k in 0..<bins { noise[k] += (re[k] * re[k] + im[k] * im[k]).squareRoot() }
    }
    noise = noise.map { $0 / Double(quiet.count) }

    var out = [Float](repeating: 0, count: x.count)
    var gain = [Double](repeating: 1, count: bins), held = gain
    let release = 0.7 // per frame: a gain that opened closes over a few frames, so word endings aren't chopped
    for s in starts {
        load(s)
        fft.transform(&re, &im, inverse: false)
        for k in 0..<bins {
            let magnitude = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            gain[k] = max(strength.floor, 1 - strength.overSubtraction * noise[k] / max(magnitude, 1e-12))
        }
        // Smoothed across neighbouring bins and held over time, which keeps the leftover noise from warbling.
        for k in 0..<bins {
            let smooth = (gain[max(0, k - 1)] + gain[k] + gain[min(bins - 1, k + 1)]) / 3
            held[k] = max(smooth, held[k] * release)
        }
        for k in 0..<bins {
            re[k] *= held[k]; im[k] *= held[k]
            if k > 0, k < n / 2 { re[n - k] *= held[k]; im[n - k] *= held[k] }
        }
        fft.transform(&re, &im, inverse: true)
        for i in 0..<n {
            let j = s + i
            if j >= 0, j < x.count { out[j] += Float(re[i] * window[i]) }
        }
    }
    return out
}

/// An in-place radix-2 FFT of a fixed power-of-two size.
struct FFT {
    let n: Int
    private let cosines: [Double], sines: [Double], reversed: [Int]

    init(_ n: Int) {
        precondition(n > 1 && n & (n - 1) == 0, "FFT size must be a power of two")
        self.n = n
        cosines = (0..<n / 2).map { cos(2 * Double.pi * Double($0) / Double(n)) }
        sines = (0..<n / 2).map { sin(2 * Double.pi * Double($0) / Double(n)) }
        let bits = n.trailingZeroBitCount
        reversed = (0..<n).map { i in (0..<bits).reduce(0) { r, b in r | ((i >> b) & 1) << (bits - 1 - b) } }
    }

    /// Forward, or inverse (scaled by 1/n, so a round trip gives back the input).
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        for i in 0..<n where i < reversed[i] {
            re.swapAt(i, reversed[i])
            im.swapAt(i, reversed[i])
        }
        var length = 2
        while length <= n {
            let half = length / 2, step = n / length
            for start in stride(from: 0, to: n, by: length) {
                for j in 0..<half {
                    let wr = cosines[j * step], wi = inverse ? sines[j * step] : -sines[j * step]
                    let a = start + j, b = a + half
                    let xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                }
            }
            length *= 2
        }
        if inverse {
            let scale = 1 / Double(n)
            for i in 0..<n { re[i] *= scale; im[i] *= scale }
        }
    }
}

// MARK: Loudness

/// Integrated loudness in LUFS (ITU-R BS.1770: K-weighted, 400 ms blocks every 100 ms, gated at -70 LUFS and then
/// 10 LU below the ungated level). `playedAs`: how many output channels the sound fills, so a mono microphone that
/// the export spreads to both sides is measured as it will play. Nil when there's nothing above the gate.
public func integratedLoudness(_ channels: [[Float]], rate: Double, playedAs outputs: Int? = nil) -> Double? {
    guard let length = channels.first?.count else { return nil }
    let block = Int(0.4 * rate), step = Int(0.1 * rate)
    guard length >= block else { return nil }
    // Running sums of the K-weighted squares, so each block's mean is one subtraction.
    let sums = channels.map { c -> [Double] in
        var total = 0.0
        return [0] + kWeighted(c, rate: rate).map { v -> Double in total += v * v; return total }
    }
    // Each output channel counts once: a mono source spread to two counts twice.
    let copies = Double(max(1, (outputs ?? channels.count) / channels.count))
    let power = stride(from: 0, through: length - block, by: step).map { start in
        sums.reduce(0.0) { $0 + ($1[start + block] - $1[start]) / Double(block) } * copies
    }
    func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(p) }
    let loud = power.filter { $0 > 0 && lufs($0) > -70 }
    guard !loud.isEmpty else { return nil }
    let relative = lufs(loud.reduce(0, +) / Double(loud.count)) - 10
    let gated = loud.filter { lufs($0) > relative }
    return lufs(gated.reduce(0, +) / Double(gated.count))
}

/// Brings the sound to `MicCleanup.target`, then limits peaks to `MicCleanup.ceiling` so raising it never clips.
/// Returns the gain applied, in dB (0 when the sound is too short or quiet to measure).
@discardableResult
public func normalizeLoudness(_ channels: inout [[Float]], rate: Double, playedAs outputs: Int? = nil,
                              target: Double = MicCleanup.target) -> Double {
    guard let measured = integratedLoudness(channels, rate: rate, playedAs: outputs) else { return 0 }
    let db = min(MicCleanup.maxGain, target - measured)
    let gain = Float(pow(10, db / 20))
    // An instant-attack limiter: the envelope jumps to each peak and falls back over about 50 ms.
    let fall = Float(exp(-1 / (0.05 * rate)))
    var envelope: Float = 0
    for i in 0..<(channels.first?.count ?? 0) {
        var peak: Float = 0
        for c in channels.indices { peak = max(peak, abs(channels[c][i] * gain)) }
        envelope = max(peak, envelope * fall)
        let g = envelope > MicCleanup.ceiling ? gain * MicCleanup.ceiling / envelope : gain
        for c in channels.indices { channels[c][i] *= g }
    }
    return db
}

/// The K-weighting filter: a high shelf (+4 dB above about 1.5 kHz, roughly how the head shapes sound) and then a
/// high-pass at about 38 Hz. Coefficients follow BS.1770 at 48 kHz, recalculated for other rates.
func kWeighted(_ x: [Float], rate: Double) -> [Double] {
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func callAsFunction(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
    var shelf: Biquad = {
        let gain = 3.999843853973347, f0 = 1681.974450955533, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / rate), vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }()
    var highPass: Biquad = {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / rate), a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }()
    return x.map { highPass(shelf(Double($0))) }
}
