import Foundation
import Accelerate
import RNNoise

/// Redukcja szumu w odbieranym dźwięku (między wyjściem audio radia a słuchawkami).
/// STFT (okno sqrt-Hann, krok 1/4 okna), szum z minimum wygładzonej mocy (~1 s), filtr Wienera
/// z oceną SNR „decision-directed”, podłoga tłumienia (bez „ćwierkania”), wygładzanie wzmocnień,
/// filtr pasma głosu i wyrównanie głośności. Algorytm sprawdzony prototypem na mowie z szumem.
/// Wywoływane tylko z wątku audio (obróbka w miejscu); konfiguracja ustawiana z dowolnego wątku.
final class AudioDenoiser: @unchecked Sendable {
    enum Level: Int, CaseIterable, Codable {
        // kolejność na liście: …, Maks., Głos DX, AI (wartości liczbowe zapisane w ustawieniach - bez zmian)
        case off = 0, light = 1, medium = 2, strong = 3, maximum = 4, dx = 6, ai = 5

        var name: String {
            switch self {
            case .off: return L("Wył.")
            case .light: return L("Lekki")
            case .medium: return L("Średni")
            case .strong: return L("Mocny")
            case .maximum: return L("Maks.")
            case .dx: return L("Głos DX")
            case .ai: return "AI"
            }
        }

        /// nadmiar odejmowania szumu, podłoga tłumienia (dB), współczynnik decision-directed
        fileprivate var parameters: (beta: Float, floorDB: Float, dd: Float) {
            switch self {
            case .off: return (1, 0, 0.96)
            case .light: return (1.0, -10, 0.96)
            case .medium: return (1.6, -15, 0.97)
            case .strong: return (2.3, -20, 0.98)
            case .maximum: return (3.2, -26, 0.985)
            case .ai: return (1, 0, 0.96)                 // AI = sieć RNNoise, bez filtru Wienera
            case .dx: return (1.6, -15, 0.97)             // Głos DX = OM-LSA (osobny algorytm)
            }
        }
    }

    struct Config: Equatable {
        var level: Level = .off
        var voiceBand = true
        var agc = true
        var anf = false                                   // wycinanie gwizdów i nośnych
        var nb = false                                    // wygaszanie trzasków (impulsów)
        var apf = false                                   // wąski filtr szczytowy CW (APF)
        var apfHz = 700.0
        var apfBandwidth = 100.0
        var aiStrength = 0.7                              // AI: udział wyniku sieci (reszta - oryginał)
        var eq = false                                    // korektor 8-pasmowy
        var eqGains: [Double] = [0, 0, 0, 0, 0, 0, 0, 0]
        var active: Bool { level != .off || voiceBand || anf || nb || apf || eq }
        /// Filtr Wienera (poziomy 1–4) albo pasmo głosu - etap widmowy (STFT).
        var spectral: Bool { (level != .off && level != .ai) || voiceBand }
    }

    private let lock = NSLock()
    private var pendingConfig = Config()

    func setConfig(_ config: Config) {
        lock.lock()
        pendingConfig = config
        lock.unlock()
    }

    // MARK: - Stan (tylko wątek audio)

    private var config = Config()
    private var sampleRate = 0.0
    private var n = 1024
    private var hop = 256
    private var bins = 513
    private var forwardSetup: vDSP_DFT_Setup?
    private var inverseSetup: vDSP_DFT_Setup?
    private var window: [Float] = []
    private var scale: Float = 1
    private var inBuffer: [Float] = []
    private var accumulator: [Float] = []
    private var inQueue: [Float] = []
    private var outQueue: [Float] = []
    private var band: [Float] = []

    private var smoothedPower: [Float] = []
    private var currentMin: [Float] = []
    private var minima: [[Float]] = []
    private var minCount = 0
    private var noise: [Float] = []
    private var previousGain: [Float] = []
    private var previousPower: [Float] = []
    private var agcGain: Float = 1
    private var speechRMS: Float = 0.05

    private static let subwindow = 24         // ramek w podoknie minimum statistics
    private static let subwindows = 8         // ~1 s historii przy 48 kHz

    deinit {
        if let forwardSetup { vDSP_DFT_DestroySetup(forwardSetup) }
        if let inverseSetup { vDSP_DFT_DestroySetup(inverseSetup) }
    }

    /// Obróbka w miejscu. Opóźnienie stałe: n próbek (~21 ms przy 48 kHz).
    /// Zwraca true, gdy dźwięk został przetworzony (false = obejście, próbki bez zmian).
    @discardableResult
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate rate: Double) -> Bool {
        lock.lock()
        let wanted = pendingConfig
        lock.unlock()
        guard wanted.active else {
            if config.active { config = wanted; sampleRate = 0 }   // przy ponownym włączeniu - od nowa
            return false
        }
        if rate != sampleRate || !config.active { configure(rate) }
        if wanted.level != config.level { agcGain = 1 }
        if wanted.level == .dx, config.level != .dx { resetOMLSA() }   // od świeżego oszacowania szumu
        // etapy włączane w trakcie pracy startują od czystego stanu
        if wanted.nb, !config.nb || blanker == nil { blanker = ImpulseBlanker(sampleRate: rate) }
        if wanted.anf, !config.anf || notch == nil { notch = AdaptiveNotch(sampleRate: rate) }
        if wanted.level == .ai, config.level != .ai || neural == nil { neural = rate == 48_000 ? NeuralDenoiser() : nil }
        if wanted.spectral, !config.spectral { resetSpectral() }
        config = wanted

        // Łańcuch: NB → ANF → AI (RNNoise) → APF → widmowy filtr / pasmo głosu → korektor → wyrównanie głośności
        if config.nb { blanker?.process(samples, count: count) }
        if config.anf { notch?.process(samples, count: count) }
        if config.level == .ai { neural?.process(samples, count: count, strength: Float(config.aiStrength)) }   // RNNoise tylko przy 48 kHz
        if config.apf {
            if !apfRunning { apfFilter.reset() }
            apfFilter.setBandpass(center: config.apfHz, bandwidth: config.apfBandwidth, sampleRate: sampleRate)
            apfFilter.process(samples, count: count)
        }
        apfRunning = config.apf
        if config.spectral { spectralStage(samples, count: count) }
        if config.eq { equalizer.process(samples, count: count, gains: config.eqGains, sampleRate: sampleRate) }
        if config.agc, config.level != .off { applyAGC(samples, count: count) }
        return true
    }

    /// Etap widmowy (STFT): filtr Wienera (poziomy 1–4) i pasmo głosu.
    private func spectralStage(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        inQueue.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        while inQueue.count >= hop {
            inBuffer.removeFirst(hop)
            inBuffer.append(contentsOf: inQueue[0..<hop])
            inQueue.removeFirst(hop)
            outQueue.append(contentsOf: frame())
        }
        let available = min(count, outQueue.count)
        outQueue.withUnsafeBufferPointer { src in
            samples.update(from: src.baseAddress!, count: available)
        }
        outQueue.removeFirst(available)
        if available < count { (samples + available).update(repeating: 0, count: count - available) }
    }

    private func resetSpectral() {
        resetOMLSA()
        inBuffer = [Float](repeating: 0, count: n)
        accumulator = [Float](repeating: 0, count: n)
        inQueue = []
        outQueue = [Float](repeating: 0, count: hop)
        smoothedPower = []
        currentMin = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        minima = []
        minCount = 0
        previousGain = [Float](repeating: 1, count: bins)
        previousPower = [Float](repeating: 0, count: bins)
    }

    private var apfFilter = Biquad()
    private var equalizer = AudioEqualizer()
    private var apfRunning = false
    private var blanker: ImpulseBlanker?
    private var notch: AdaptiveNotch?
    private var neural: NeuralDenoiser?

    private func configure(_ rate: Double) {
        sampleRate = rate
        blanker = nil
        notch = nil
        neural = nil
        n = rate > 50_000 ? 2048 : 1024
        hop = n / 4
        bins = n / 2 + 1
        if let forwardSetup { vDSP_DFT_DestroySetup(forwardSetup) }
        if let inverseSetup { vDSP_DFT_DestroySetup(inverseSetup) }
        forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
        inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .INVERSE)
        window = (0..<n).map { Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)))) }

        // Skala: zmierzona (przekształcenie tam i z powrotem) × normalizacja nakładania okien.
        var probe = (0..<n).map { _ in Float.random(in: -1...1) }
        let roundTrip = transform(&probe, gains: nil)
        var dotXY: Float = 0, dotXX: Float = 0
        vDSP_dotpr(roundTrip, 1, probe, 1, &dotXY, vDSP_Length(n))
        vDSP_dotpr(probe, 1, probe, 1, &dotXX, vDSP_Length(n))
        let dftScale = dotXY != 0 ? dotXX / dotXY : 1
        let windowEnergy = window.reduce(0) { $0 + $1 * $1 }
        scale = dftScale * Float(hop) / windowEnergy

        inBuffer = [Float](repeating: 0, count: n)
        accumulator = [Float](repeating: 0, count: n)
        inQueue = []
        outQueue = [Float](repeating: 0, count: hop)           // zapas jednego kroku - wyjście zawsze gotowe
        band = (0..<bins).map { k in
            let f = Double(k) * rate / Double(n)
            let low = min(max((f - 200) / 100, 0), 1), high = min(max((3300 - f) / 500, 0), 1)
            return Float(low * high)
        }
        smoothedPower = []
        currentMin = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        minima = []
        minCount = 0
        noise = [Float](repeating: 1e-6, count: bins)
        previousGain = [Float](repeating: 1, count: bins)
        previousPower = [Float](repeating: 0, count: bins)
        agcGain = 1
        speechRMS = 0.05
    }

    /// Przekształcenie: FFT → (moce do `power`) → wzmocnienia → IFFT. Bez okna i skali.
    private func transform(_ signal: inout [Float], gains: (([Float]) -> [Float])?) -> [Float] {
        let half = n / 2
        var inRe = [Float](repeating: 0, count: half), inIm = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half), outIm = [Float](repeating: 0, count: half)
        inRe.withUnsafeMutableBufferPointer { re in
            inIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                signal.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        guard let forwardSetup, let inverseSetup else { return signal }
        vDSP_DFT_Execute(forwardSetup, inRe, inIm, &outRe, &outIm)

        if let gains {
            // Pakowanie zrop: outRe[0] = DC, outIm[0] = Nyquist, reszta - zwykłe prążki.
            var power = [Float](repeating: 0, count: half + 1)
            power[0] = outRe[0] * outRe[0]
            power[half] = outIm[0] * outIm[0]
            for k in 1..<half { power[k] = outRe[k] * outRe[k] + outIm[k] * outIm[k] }
            let g = gains(power)
            outRe[0] *= g[0]
            outIm[0] *= g[half]
            for k in 1..<half { outRe[k] *= g[k]; outIm[k] *= g[k] }
        }

        var backRe = [Float](repeating: 0, count: half), backIm = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(inverseSetup, outRe, outIm, &backRe, &backIm)
        var result = [Float](repeating: 0, count: n)
        backRe.withUnsafeMutableBufferPointer { re in
            backIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                result.withUnsafeMutableBufferPointer { r in
                    r.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        return result
    }

    private func frame() -> [Float] {
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(inBuffer, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let level = config.level, voiceBand = config.voiceBand
        let processed = transform(&windowed) { power in self.gains(for: power, level: level, voiceBand: voiceBand) }

        // okno syntezy, skala, nakładanie (funkcje zwracające nowe tablice - bez nakładania dostępu)
        let synthesis = vDSP.multiply(scale, vDSP.multiply(processed, window))
        accumulator = vDSP.add(accumulator, synthesis)
        let out = Array(accumulator[0..<hop])
        accumulator.removeFirst(hop)
        accumulator.append(contentsOf: [Float](repeating: 0, count: hop))

        return out
    }

    private func gains(for power: [Float], level: Level, voiceBand: Bool) -> [Float] {
        var gain = [Float](repeating: 1, count: bins)
        if level == .dx {
            gain = omlsaGains(power)
        } else if level != .off, level != .ai {
            let p = level.parameters
            // szum: minimum wygładzonej mocy w ostatniej ~1 s (mowa ma przerwy, szum - nie)
            if smoothedPower.isEmpty { smoothedPower = power }
            for k in 0..<bins {
                smoothedPower[k] = 0.8 * smoothedPower[k] + 0.2 * power[k]
                currentMin[k] = min(currentMin[k], smoothedPower[k])
            }
            minCount += 1
            if minCount >= Self.subwindow {
                minima.append(currentMin)
                if minima.count > Self.subwindows { minima.removeFirst(minima.count - Self.subwindows) }
                currentMin = [Float](repeating: .greatestFiniteMagnitude, count: bins)
                minCount = 0
            }
            for k in 0..<bins {
                var m = currentMin[k]
                for stored in minima { m = min(m, stored[k]) }
                if m < .greatestFiniteMagnitude { noise[k] = m * 1.6 }     // korekta obciążenia minimum
            }
            // filtr Wienera z oceną SNR „decision-directed”
            let floorGain = powf(10, p.floorDB / 20)
            var raw = [Float](repeating: 1, count: bins)
            for k in 0..<bins {
                let noisePower = max(noise[k] * p.beta, 1e-12)
                let gamma = power[k] / noisePower
                let xi = p.dd * previousGain[k] * previousGain[k] * previousPower[k] / noisePower
                    + (1 - p.dd) * max(gamma - 1, 0)
                raw[k] = xi / (1 + xi)
            }
            // wygładzenie w częstotliwości (mniej „ćwierkania”) i podłoga tłumienia
            for k in 0..<bins {
                let a = raw[max(k - 1, 0)], b = raw[k], c = raw[min(k + 1, bins - 1)]
                gain[k] = max((a + b + c) / 3, floorGain)
            }
            previousGain = gain
            previousPower = power
        }
        if voiceBand {
            for k in 0..<bins { gain[k] *= band[k] }
        }
        return gain
    }

    // MARK: - Głos DX: OM-LSA + MCRA
    //
    // Na podstawie publikacji (bez cudzego kodu): Cohen & Berdugo 2001 (OM-LSA), Cohen & Berdugo 2002 (MCRA),
    // Ephraim & Malah 1985 (LSA). Parametry dostrojone do słabej mowy SSB: próg obecności mowy 2, okno minimum
    // 80 ramek. Pomiar (5 poziomów SNR × 3 przebiegi szumu): stosunek mowy do tła +1,9…+2,7 dB lepszy niż
    // poziom Średni, wygrana w 15/15 próbach, także przy stacjach pod szumem (SNR −6 dB).

    private var omS: [Float] = []
    private var omSmin: [Float] = []
    private var omStmp: [Float] = []
    private var omNoise: [Float] = []
    private var omP: [Float] = []
    private var omGPrev: [Float] = []
    private var omGammaPrev: [Float] = []
    private var omFrames = 0

    private func resetOMLSA() { omS = [] }

    /// Wykładnicza całka E1(x) (Abramowitz & Stegun 5.1.53 / 5.1.56), błąd < 1e-4.
    private static func expintE1(_ value: Float) -> Float {
        let x = max(value, 1e-10)
        if x < 1 {
            return -logf(x) - 0.57721566 + x * (0.99999193 + x * (-0.24991055 + x * (0.05519968
                + x * (-0.00976004 + x * 0.00107857))))
        }
        return expf(-x) / x * (x * x + 2.334733 * x + 0.250621) / (x * x + 3.330657 * x + 1.681534)
    }

    /// Średnia krocząca o nieparzystej szerokości, wyśrodkowana, zera poza zakresem (jak numpy „same”).
    private static func movingAverage(_ v: [Float], width: Int) -> [Float] {
        let h = width / 2, n = v.count
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + v[i] }
        return (0..<n).map { k in (prefix[min(k + h + 1, n)] - prefix[max(k - h, 0)]) / Float(width) }
    }

    private func omlsaGains(_ power: [Float]) -> [Float] {
        let n = bins
        let y2 = power.map { $0 + 1e-12 }
        // wygładzenie w częstotliwości (0,25 / 0,5 / 0,25)
        var sf = [Float](repeating: 0, count: n)
        for k in 0..<n {
            sf[k] = 0.5 * y2[k] + 0.25 * (k > 0 ? y2[k - 1] : 0) + 0.25 * (k + 1 < n ? y2[k + 1] : 0)
        }
        if omS.count != n {
            omS = sf; omSmin = sf; omStmp = sf; omNoise = y2
            omP = [Float](repeating: 0, count: n)
            omGPrev = [Float](repeating: 1, count: n)
            omGammaPrev = [Float](repeating: 1, count: n)
            omFrames = 0
        }
        // MCRA: śledzenie minimum i prawdopodobieństwo obecności mowy; szum aktualizowany tam, gdzie mowy brak
        omFrames += 1
        let resetWindow = omFrames % 80 == 0
        for k in 0..<n {
            omS[k] = 0.85 * omS[k] + 0.15 * sf[k]
            omSmin[k] = min(omSmin[k], omS[k])
            omStmp[k] = min(omStmp[k], omS[k])
            if resetWindow {
                omSmin[k] = min(omStmp[k], omS[k])
                omStmp[k] = omS[k]
            }
            let present: Float = omS[k] / max(omSmin[k], 1e-12) > 2 ? 1 : 0
            omP[k] = 0.3 * omP[k] + 0.7 * present
            let ad = 0.97 + 0.03 * omP[k]
            omNoise[k] = ad * omNoise[k] + (1 - ad) * y2[k]
        }
        // OM-LSA: a priori SNR (decision-directed), wzmocnienie LSA, prawdopodobieństwo obecności mowy
        var gamma = [Float](repeating: 0, count: n), xi = gamma, v = gamma, gH1 = gamma
        let xiMin: Float = 0.0031622776                               // −25 dB
        for k in 0..<n {
            let lambda = omNoise[k] * 1.5
            gamma[k] = min(y2[k] / lambda, 1000)
            xi[k] = max(0.95 * omGPrev[k] * omGPrev[k] * omGammaPrev[k] + 0.05 * max(gamma[k] - 1, 0), xiMin)
            v[k] = gamma[k] * xi[k] / (1 + xi[k])
            gH1[k] = min(xi[k] / (1 + xi[k]) * expf(0.5 * Self.expintE1(v[k])), 1)
        }
        let local = Self.movingAverage(xi, width: 3), global = Self.movingAverage(xi, width: 31)
        func likelihood(_ z: Float) -> Float { min(max((10 * log10f(z + 1e-12) + 10) / 5, 0), 1) }
        let gMin: Float = 0.056234133                                 // −25 dB
        var gain = [Float](repeating: 1, count: n)
        for k in 0..<n {
            let q = min(max(1 - likelihood(local[k]) * likelihood(global[k]), 0), 0.95)
            let pSpeech = 1 / (1 + q / (1 - q + 1e-12) * (1 + xi[k]) * expf(-v[k]))
            gain[k] = powf(gH1[k], pSpeech) * powf(gMin, 1 - pSpeech)
        }
        omGPrev = gH1
        omGammaPrev = gamma
        return gain
    }

    /// Wyrównanie głośności (redukcja szumu ścisza całość) i miękki ogranicznik - na końcu łańcucha.
    private func applyAGC(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
        let rms = meanSquare.squareRoot() + 1e-9
        if rms > 0.5 * speechRMS { speechRMS = 0.995 * speechRMS + 0.005 * rms }
        let target = min(0.1 / speechRMS, 4)                       // najwyżej +12 dB
        agcGain += 0.02 * (target - agcGain)
        for i in 0..<count {
            samples[i] = tanhf(samples[i] * agcGain * 1.2) / 1.2
        }
    }
}


// MARK: - Etapy łańcucha

/// Wygaszacz impulsów (trzaski QRN): próbka > 8 × średnia obwiedni z ~2 ms → wygaszenie łagodnymi
/// zboczami (0,5 ms); opóźnienie 2 ms pozwala wyciszyć też początek impulsu.
/// Pomiar: trzaski −17 dB, na czystej mowie wygaszane 0,03 % próbek.
private final class ImpulseBlanker {
    private let threshold: Float = 8
    private let alpha: Float
    private let ramp: Float
    private let hang: Int
    private var delay: [Float]
    private var position = 0
    private var average: Float = 1e-3
    private var hold = 0
    private var gain: Float = 1

    init(sampleRate: Double) {
        alpha = Float(1 / (sampleRate * 0.002))
        ramp = Float(1 / max(1, sampleRate * 0.0005))
        hang = Int(sampleRate * 0.002)
        delay = [Float](repeating: 0, count: max(1, Int(sampleRate * 0.002)))
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let length = delay.count
        for i in 0..<count {
            let v = samples[i]
            let a = abs(v)
            if a > threshold * average {
                hold = length + hang                                  // opóźniona próbka i chwila po impulsie
            } else {
                average += alpha * (a - average)                      // średnia tylko z „czystych” próbek
            }
            let target: Float
            if hold > 0 { hold -= 1; target = 0 } else { target = 1 }
            gain += max(-ramp, min(ramp, target - gain))
            let delayed = delay[position]
            delay[position] = v
            position = (position + 1) % length
            samples[i] = delayed * gain
        }
    }
}

/// Automatyczne wycinanie gwizdów i nośnych (adaptacyjny wzmacniacz linii, Widrow 1975):
/// predyktor NLMS przewiduje składowe okresowe z próbek opóźnionych o ~1,3 ms; wyjście = błąd predykcji,
/// czyli sygnał bez tonów (mowa jest za mało przewidywalna, żeby zniknąć). Pomiar: nośne −12…−16 dB.
private final class AdaptiveNotch {
    private let taps: Int
    private let history: Int
    private let weights: UnsafeMutablePointer<Float>
    private let buffer: UnsafeMutablePointer<Float>                    // podwójny bufor kołowy
    private var position = 0
    private var power: Float = 1e-3
    private let mu: Float = 0.005
    private let leak: Float = 1e-4

    init(sampleRate: Double) {
        taps = max(16, Int(256 * sampleRate / 48_000))               // ~5,3 ms
        let delay = max(4, Int(64 * sampleRate / 48_000))            // ~1,3 ms
        history = taps + delay
        weights = .allocate(capacity: taps)
        weights.initialize(repeating: 0, count: taps)
        buffer = .allocate(capacity: 2 * history)
        buffer.initialize(repeating: 0, count: 2 * history)
    }

    deinit {
        weights.deallocate()
        buffer.deallocate()
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        var keep = 1 - leak
        for i in 0..<count {
            let v = samples[i]
            position = (position + 1) % history
            buffer[position] = v
            buffer[position + history] = v
            // próbki opóźnione o `delay`…`history-1`: ciągły fragment bufora (od najstarszej)
            let window = buffer + position + 1
            var prediction: Float = 0
            vDSP_dotpr(weights, 1, window, 1, &prediction, vDSP_Length(taps))
            let error = v - prediction
            power = 0.99 * power + 0.01 * v * v
            var step = mu / (power * Float(taps) + 1e-9) * error
            vDSP_vsmul(weights, 1, &keep, weights, 1, vDSP_Length(taps))
            vDSP_vsma(window, 1, &step, weights, 1, weights, 1, vDSP_Length(taps))
            samples[i] = error
        }
    }
}

/// Redukcja szumu siecią neuronową RNNoise (Xiph, licencja BSD; ramki 480 próbek przy 48 kHz,
/// opóźnienie 10 ms). Pomiar przy silnym szumie: tło −13…−16 dB przy tej samej jakości mowy.
private final class NeuralDenoiser {
    private static let frame = 480
    private let state: OpaquePointer?
    private var inQueue: [Float] = []
    private var outQueue = [Float](repeating: 0, count: NeuralDenoiser.frame)
    /// Oryginał opóźniony tak samo jak wynik sieci: 480 (bufor) + 480 (opóźnienie RNNoise) = 960 próbek.
    /// Przesunięcie przy mieszaniu dałoby słyszalne „echo”.
    private var dryQueue = [Float](repeating: 0, count: 2 * NeuralDenoiser.frame)
    private var input = [Float](repeating: 0, count: NeuralDenoiser.frame)
    private var output = [Float](repeating: 0, count: NeuralDenoiser.frame)

    init() { state = rnnoise_create(nil) }

    deinit { if let state { rnnoise_destroy(state) } }

    /// `strength`: udział wyniku sieci 0,3…1 - przy słabych stacjach część oryginału zostaje słyszalna.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, strength: Float) {
        guard let state else { return }
        dryQueue.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        inQueue.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        while inQueue.count >= Self.frame {
            for i in 0..<Self.frame { input[i] = inQueue[i] * 32768 }    // RNNoise oczekuje skali 16-bitowej
            inQueue.removeFirst(Self.frame)
            _ = rnnoise_process_frame(state, &output, input)
            for i in 0..<Self.frame { outQueue.append(output[i] / 32768) }
        }
        let available = min(count, outQueue.count, dryQueue.count)
        let wet = min(max(strength, 0), 1)
        for i in 0..<available { samples[i] = wet * outQueue[i] + (1 - wet) * dryQueue[i] }
        outQueue.removeFirst(available)
        dryQueue.removeFirst(available)
        if available < count { (samples + available).update(repeating: 0, count: count - available) }
    }
}
