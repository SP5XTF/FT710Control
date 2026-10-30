import Foundation

/// Filtr drugiego rzędu (biquad, postać transponowana II). Pasmowy wg RBJ Audio EQ Cookbook:
/// wzmocnienie 1 w środku pasma. Zmiana częstotliwości zachowuje stan - bez trzasków przy przestrajaniu.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0
    private(set) var center = 0.0
    private(set) var bandwidth = 0.0

    mutating func setBandpass(center newCenter: Double, bandwidth newBandwidth: Double, sampleRate: Double) {
        guard abs(newCenter - center) > 0.5 || abs(newBandwidth - bandwidth) > 0.5 else { return }
        center = newCenter
        bandwidth = newBandwidth
        let w0 = 2 * Double.pi * min(max(newCenter, 50), sampleRate * 0.45) / sampleRate
        let q = max(newCenter / max(newBandwidth, 10), 0.3)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = Float(alpha / a0)
        b1 = 0
        b2 = Float(-alpha / a0)
        a1 = Float(-2 * cos(w0) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { samples[i] = process(samples[i]) }
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func set(_ c: BiquadCoefficients) {
        b0 = Float(c.b0); b1 = Float(c.b1); b2 = Float(c.b2); a1 = Float(c.a1); a2 = Float(c.a2)
    }
}

/// Współczynniki filtrów korektora (RBJ Audio EQ Cookbook), znormalizowane (a0 = 1).
struct BiquadCoefficients: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    enum Kind { case peaking, lowShelf, highShelf }

    static func make(_ kind: Kind, center: Double, gainDB: Double, q: Double = 2.0, sampleRate: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * center / sampleRate
        let c = cos(w0), s = sin(w0)
        var b = [1.0, 0, 0], d = [1.0, 0, 0]
        switch kind {
        case .peaking:
            let alpha = s / (2 * q)
            b = [1 + alpha * a, -2 * c, 1 - alpha * a]
            d = [1 + alpha / a, -2 * c, 1 - alpha / a]
        case .lowShelf, .highShelf:
            let sq = 2 * sqrt(a) * (s / 2 * sqrt(2.0))           // nachylenie półki S = 1
            if kind == .lowShelf {
                b = [a * ((a + 1) - (a - 1) * c + sq), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - sq)]
                d = [(a + 1) + (a - 1) * c + sq, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - sq]
            } else {
                b = [a * ((a + 1) + (a - 1) * c + sq), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - sq)]
                d = [(a + 1) - (a - 1) * c + sq, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - sq]
            }
        }
        return BiquadCoefficients(b0: b[0] / d[0], b1: b[1] / d[0], b2: b[2] / d[0], a1: d[1] / d[0], a2: d[2] / d[0])
    }

    /// Wzmocnienie (dB) na częstotliwości f.
    func magnitudeDB(at f: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
    }
}

/// Gotowe ustawienia korektora. Wartości suwaków wyliczone tak, by rzeczywista charakterystyka
/// (z nakładaniem się pasm) trafiała w zamierzony kształt - dokładność ~0,2–2 dB.
enum EQPreset: String, CaseIterable, Identifiable, Codable {
    case flat, dxVoice, contest, warm, lessHiss, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .flat: return L("Płasko")
        case .dxVoice: return L("DX – mowa")
        case .contest: return L("Wyraźność (zawody)")
        case .warm: return L("Ciepło (rozmowa)")
        case .lessHiss: return L("Mniej szumu")
        case .custom: return L("Własne")
        }
    }

    var gains: [Double]? {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0]
        case .dxVoice: return [-10.5, -3, -1, 0.5, 1.5, 3.5, 5, -10.5]
        case .contest: return [-12, -6.5, -2.5, 0.5, 2, 4.5, 5, -12]
        case .warm: return [3.5, 1.5, 1, 0, -0.5, -1, -0.5, -8.5]
        case .lessHiss: return [-0, -0, 0, -0, 0.5, -0, -2, -12]
        case .custom: return nil
        }
    }
}

/// Korektor 8-pasmowy dla odsłuchu SSB: półka 200 Hz, szczyty 350…2400 Hz co pół oktawy, półka 3200 Hz.
/// Całość ściszana o rzeczywisty szczyt charakterystyki - korektor nie przesterowuje.
struct AudioEqualizer {
    static let bands: [(hz: Double, kind: BiquadCoefficients.Kind)] = [
        (200, .lowShelf), (350, .peaking), (600, .peaking), (900, .peaking),
        (1300, .peaking), (1800, .peaking), (2400, .peaking), (3200, .highShelf)
    ]

    private var filters = [Biquad](repeating: Biquad(), count: AudioEqualizer.bands.count)
    private var gains: [Double] = []
    private var sampleRate = 0.0
    private var preGain: Float = 1

    static func coefficients(_ gains: [Double], sampleRate: Double) -> [BiquadCoefficients] {
        zip(bands, gains).map { BiquadCoefficients.make($0.0.kind, center: $0.0.hz, gainDB: $0.1, sampleRate: sampleRate) }
    }

    /// Charakterystyka całego korektora (do wykresu i do wyliczenia zapasu).
    static func response(_ gains: [Double], at freqs: [Double], sampleRate: Double = 48_000) -> [Double] {
        let coeffs = coefficients(gains, sampleRate: sampleRate)
        return freqs.map { f in coeffs.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) } }
    }

    static let responseGrid: [Double] = (0..<60).map { 80 * pow(5000.0 / 80, Double($0) / 59) }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gains newGains: [Double], sampleRate rate: Double) {
        if newGains != gains || rate != sampleRate {
            gains = newGains
            sampleRate = rate
            for (i, c) in Self.coefficients(newGains, sampleRate: rate).enumerated() { filters[i].set(c) }
            let peak = Self.response(newGains, at: Self.responseGrid, sampleRate: rate).max() ?? 0
            preGain = Float(pow(10, -max(peak, 0) / 20))
        }
        for i in 0..<count {
            var v = samples[i] * preGain
            for k in 0..<filters.count { v = filters[k].process(v) }
            samples[i] = v
        }
    }
}

/// Korektor nadawania (12 pasm, zakres mowy SSB) - mikrofon Maca i mikrofon panelu zdalnego → radio (USB).
/// Jak korektor odsłuchu: całość ściszana o największe podbicie - zmienia barwę, nie przesterowuje toru.
struct TXEqualizer {
    static let bands: [(hz: Double, kind: BiquadCoefficients.Kind)] = [
        (60, .lowShelf), (100, .peaking), (160, .peaking), (250, .peaking), (400, .peaking), (630, .peaking),
        (1000, .peaking), (1400, .peaking), (1800, .peaking), (2300, .peaking), (2800, .peaking), (3300, .highShelf)
    ]
    static let flat = [Double](repeating: 0, count: bands.count)

    private var filters = [Biquad](repeating: Biquad(), count: TXEqualizer.bands.count)
    private var gains: [Double] = []
    private var sampleRate = 0.0
    private var preGain: Float = 1

    static func coefficients(_ gains: [Double], sampleRate: Double) -> [BiquadCoefficients] {
        zip(bands, gains).map { BiquadCoefficients.make($0.0.kind, center: $0.0.hz, gainDB: $0.1, q: 1.8, sampleRate: sampleRate) }
    }

    static func response(_ gains: [Double], at freqs: [Double], sampleRate: Double = 48_000) -> [Double] {
        let coeffs = coefficients(gains, sampleRate: sampleRate)
        return freqs.map { f in coeffs.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) } }
    }

    static let responseGrid: [Double] = (0..<60).map { 40 * pow(4500.0 / 40, Double($0) / 59) }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gains newGains: [Double], sampleRate rate: Double) {
        guard newGains.count == Self.bands.count, rate > 0 else { return }
        if newGains != gains || rate != sampleRate {
            gains = newGains
            sampleRate = rate
            for (i, c) in Self.coefficients(newGains, sampleRate: rate).enumerated() { filters[i].set(c) }
            let peak = Self.response(newGains, at: Self.responseGrid, sampleRate: rate).max() ?? 0
            preGain = Float(pow(10, -max(peak, 0) / 20))
        }
        for i in 0..<count {
            var v = samples[i] * preGain
            for k in 0..<filters.count { v = filters[k].process(v) }
            samples[i] = v
        }
    }
}

/// Ustawienia korektora nadawania - wspólne dla toru mikrofonu Maca i panelu zdalnego (czytane z wątków audio).
final class TXEqualizerConfig: @unchecked Sendable {
    static let shared = TXEqualizerConfig()
    private let lock = NSLock()
    private var enabledValue = false
    private var gainsValue = TXEqualizer.flat

    func set(enabled: Bool, gains: [Double]) {
        lock.lock(); enabledValue = enabled; gainsValue = gains; lock.unlock()
    }

    /// nil - korektor wyłączony (albo płaski: bez obróbki).
    var activeGains: [Double]? {
        lock.lock(); defer { lock.unlock() }
        guard enabledValue, gainsValue.contains(where: { $0 != 0 }) else { return nil }
        return gainsValue
    }
}
