import Foundation
import Accelerate
import Combine

/// Filtry odsłuchu (tylko to, co słychać - dekodery dostają dźwięk sprzed filtrów):
/// • pasmowy FIR o liniowej fazie, 1535 współczynników, okno Kaisera β = 8. Prototyp (48 kHz, 300–2700 Hz):
///   zbocze −1→−60 dB 105 Hz, tłumienie poza pasmem > 95 dB, bez falowania, opóźnienie 16 ms; przy wąskich
///   pasmach CW przeregulowanie 0,3 % - liniowa faza praktycznie nie „dzwoni” (osobny filtr Gaussa niepotrzebny);
/// • wycięcia ręczne: filtry notch (IIR, RBJ), szerokość ok. 40 Hz, do 6 naraz.
/// Wywoływane z wątku audio (obróbka w miejscu).
final class ListeningFilters {
    static let tapCount = 1535
    static let notchWidth = 40.0
    static let maxNotches = 6

    private var taps: [Float] = []
    private var history: [Float] = []
    private var work: [Float] = []
    private var design: (low: Double, high: Double, rate: Double)?

    private struct Notch {
        let hz: Double
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
    }
    private var notches: [Notch] = []
    private var notchRate = 0.0

    /// Pasmo włączone ponownie - bez resztek starego sygnału.
    func resetBand() {
        history = []
        design = nil
    }

    // MARK: - Filtr pasmowy

    func processBand(_ samples: UnsafeMutablePointer<Float>, count: Int, low: Double, high: Double, rate: Double) {
        guard count > 0, rate > 0, high > low else { return }
        if design == nil || design!.low != low || design!.high != high || design!.rate != rate {
            taps = Self.bandpass(low: low, high: high, rate: rate, count: Self.tapCount)
            design = (low, high, rate)
        }
        if history.count != Self.tapCount - 1 { history = [Float](repeating: 0, count: Self.tapCount - 1) }
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: history)
        work.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        // współczynniki symetryczne (liniowa faza) - korelacja vDSP_conv równa się splotowi
        vDSP_conv(work, 1, taps, 1, samples, 1, vDSP_Length(count), vDSP_Length(Self.tapCount))
        history.removeAll(keepingCapacity: true)
        history.append(contentsOf: work.suffix(Self.tapCount - 1))
    }

    /// Współczynniki filtra pasmowego: różnica dwóch dolnoprzepustowych (sinc) z oknem Kaisera.
    static func bandpass(low: Double, high: Double, rate: Double, count: Int, beta: Double = 8) -> [Float] {
        let middle = Double(count - 1) / 2
        let normalization = besselI0(beta)
        func lowpass(_ cutoff: Double, _ n: Double) -> Double {
            let x = 2 * cutoff / rate
            return n == 0 ? x : x * sin(Double.pi * x * n) / (Double.pi * x * n)
        }
        return (0..<count).map { index in
            let n = Double(index) - middle
            let ratio = n / middle
            let window = besselI0(beta * (max(0, 1 - ratio * ratio)).squareRoot()) / normalization
            return Float((lowpass(high, n) - lowpass(low, n)) * window)
        }
    }

    /// Funkcja Bessela I0 (szereg) - okno Kaisera.
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        for k in 1..<40 {
            term *= (half / Double(k)) * (half / Double(k))
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }

    // MARK: - Wycięcia

    func processNotches(_ samples: UnsafeMutablePointer<Float>, count: Int, frequencies: [Double], rate: Double) {
        guard rate > 0 else { return }
        let wanted = Array(frequencies.prefix(Self.maxNotches))
        if rate != notchRate || notches.map(\.hz) != wanted {
            // zachowaj stan wycięć, które zostały (bez trzasku przy dodaniu kolejnego)
            let previous = rate == notchRate ? notches : []
            notches = wanted.map { hz in
                if let kept = previous.first(where: { $0.hz == hz }) { return kept }
                return Self.notch(hz: hz, rate: rate)
            }
            notchRate = rate
        }
        guard !notches.isEmpty else { return }
        for i in 0..<count {
            var x = Double(samples[i])
            for k in notches.indices {
                let y = notches[k].b0 * x + notches[k].z1                     // postać transponowana II
                notches[k].z1 = notches[k].b1 * x - notches[k].a1 * y + notches[k].z2
                notches[k].z2 = notches[k].b2 * x - notches[k].a2 * y
                x = y
            }
            samples[i] = Float(x)
        }
    }

    /// Filtr notch (RBJ): zero na częstotliwości, szerokość ok. 40 Hz.
    private static func notch(hz: Double, rate: Double) -> Notch {
        let w0 = 2 * Double.pi * hz / rate
        let q = max(hz / notchWidth, 0.5)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Notch(hz: hz, b0: 1 / a0, b1: -2 * cos(w0) / a0, b2: 1 / a0,
                     a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    /// Odpowiedź (dB) na częstotliwości - do testów i podglądu.
    static func responseDB(taps: [Float], hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, h) in taps.enumerated() {
            let phase = -2 * Double.pi * hz / rate * Double(n)
            re += Double(h) * cos(phase); im += Double(h) * sin(phase)
        }
        return 20 * log10(max((re * re + im * im).squareRoot(), 1e-12))
    }
}


/// Stan filtra odsłuchu (zapamiętywany): pasmo, wycięcia. Zmiana wywołuje onChange (konfiguracja toru dźwięku).
@MainActor
final class ListeningFilterState: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "audio.filter.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "audio.filter.enabled"); onChange?() }
    }
    @Published private(set) var low = UserDefaults.standard.object(forKey: "audio.filter.low") as? Double ?? 300
    @Published private(set) var high = UserDefaults.standard.object(forKey: "audio.filter.high") as? Double ?? 2700
    @Published private(set) var notches: [Double] = UserDefaults.standard.array(forKey: "audio.filter.notches") as? [Double] ?? []
    var onChange: (() -> Void)?

    enum Preset: String, CaseIterable, Identifiable {
        case ssb, ssbNarrow, cw500, cw200, cw100, data
        var id: String { rawValue }
        var name: String {
            switch self {
            case .ssb: return L("SSB 300–2700 Hz")
            case .ssbNarrow: return L("SSB wąskie 400–2400 Hz")
            case .cw500: return "CW 500 Hz"
            case .cw200: return "CW 200 Hz"
            case .cw100: return "CW 100 Hz"
            case .data: return L("Dane 200–3000 Hz")
            }
        }
    }

    func apply(_ preset: Preset, pitch: Double) {
        switch preset {
        case .ssb: set(low: 300, high: 2700)
        case .ssbNarrow: set(low: 400, high: 2400)
        case .cw500: set(low: pitch - 250, high: pitch + 250)
        case .cw200: set(low: pitch - 100, high: pitch + 100)
        case .cw100: set(low: pitch - 50, high: pitch + 50)
        case .data: set(low: 200, high: 3000)
        }
        enabled = true
    }

    /// Krawędzie pasma (Hz): 50–3950, szerokość co najmniej 50 Hz.
    func set(low newLow: Double, high newHigh: Double) {
        let lo = min(max(newLow.rounded(), 50), 3900)
        let hi = min(max(newHigh.rounded(), lo + 50), 3950)
        guard lo != low || hi != high else { return }
        low = lo
        high = hi
        UserDefaults.standard.set(lo, forKey: "audio.filter.low")
        UserDefaults.standard.set(hi, forKey: "audio.filter.high")
        if enabled { onChange?() }
    }

    /// Dwuklik na widmie: dodaje wycięcie albo usuwa istniejące w pobliżu (± tolerancja Hz).
    func toggleNotch(at hz: Double, tolerance: Double) {
        if let index = notches.firstIndex(where: { abs($0 - hz) <= tolerance }) {
            notches.remove(at: index)
        } else if notches.count < ListeningFilters.maxNotches, hz >= 100, hz <= 3950 {
            notches.append(hz.rounded())
        } else {
            return
        }
        UserDefaults.standard.set(notches, forKey: "audio.filter.notches")
        onChange?()
    }

    func clearNotches() {
        notches = []
        UserDefaults.standard.set(notches, forKey: "audio.filter.notches")
        onChange?()
    }

    /// Ton audio → częstotliwość w eterze (Hz) dla trybu radia. USB/DATA-U: VFO + ton; LSB/DATA-L: VFO − ton;
    /// CW-U/CW-L: radio pokazuje nośną brzmiącą tonem CW (pitch), więc VFO ± (ton − pitch).
    /// nil - AM, FM, RTTY (bez jednoznacznego przeliczenia).
    nonisolated static func rfHz(audioHz: Double, vfoHz: Int, mode: String, cwPitch: Double) -> Int? {
        switch mode {
        case "USB", "DATA-U": return vfoHz + Int(audioHz.rounded())
        case "LSB", "DATA-L": return vfoHz - Int(audioHz.rounded())
        case "CW-U": return vfoHz + Int((audioHz - cwPitch).rounded())
        case "CW-L": return vfoHz - Int((audioHz - cwPitch).rounded())
        default: return nil
        }
    }
}
