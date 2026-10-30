import Foundation
import Accelerate

/// Alfabet Baudot ITA2 - wariant US (jak MMTTY / fldigi). Kody 5-bitowe, najmłodszy bit nadawany pierwszy.
enum Baudot {
    static let letters: [UInt8: Character] = [
        0b00011: "A", 0b11001: "B", 0b01110: "C", 0b01001: "D", 0b00001: "E", 0b01101: "F", 0b11010: "G",
        0b10100: "H", 0b00110: "I", 0b01011: "J", 0b01111: "K", 0b10010: "L", 0b11100: "M", 0b01100: "N",
        0b11000: "O", 0b10110: "P", 0b10111: "Q", 0b01010: "R", 0b00101: "S", 0b10000: "T", 0b00111: "U",
        0b11110: "V", 0b10011: "W", 0b11101: "X", 0b10101: "Y", 0b10001: "Z"
    ]
    static let figures: [UInt8: Character] = [
        0b00011: "-", 0b11001: "?", 0b01110: ":", 0b01001: "$", 0b00001: "3", 0b01101: "!", 0b11010: "&",
        0b10100: "#", 0b00110: "8", 0b01011: "'", 0b01111: "(", 0b10010: ")", 0b11100: ".", 0b01100: ",",
        0b11000: "9", 0b10110: "0", 0b10111: "1", 0b01010: "4", 0b10000: "5", 0b00111: "7",
        0b11110: ";", 0b10011: "2", 0b11101: "/", 0b10101: "6", 0b10001: "\""
    ]
    static let space: UInt8 = 0b00100, cr: UInt8 = 0b01000, lf: UInt8 = 0b00010
    static let figsShift: UInt8 = 0b11011, ltrsShift: UInt8 = 0b11111
    static let lettersReverse = Dictionary(uniqueKeysWithValues: letters.map { ($1, $0) })
    static let figuresReverse = Dictionary(uniqueKeysWithValues: figures.map { ($1, $0) })
}

struct RTTYSettings: Equatable {
    var shift = 170.0
    var baud = 45.45
    var reverse = false
    var usos = true
    var afc = true
}

/// Dekoder RTTY (algorytm sprawdzony prototypem: SNR 10 dB 0 %, 5 dB 2 %, odstrojenie 40 Hz 3 %,
/// zaniki bez szumu 0 %, sam szum - brak fałszywych znaków):
/// 8 kHz (filtr 3,4 kHz) → mieszanie na mark i space → filtr ~0,6 bitu → decyzja m − s → UART
/// (start, 5 bitów, stop) → Baudot z LTRS/FIGS i USOS. Bramka „czy to RTTY” (para tonów w widmie)
/// z odtworzeniem ostatnich 1,5 s; AFC: zgrubnie z widma (para - słabszy z tonów), dokładnie z fazy (FLL).
final class RTTYDecoder: @unchecked Sendable {
    enum Event: Sendable {
        case text(String)
        case status(mark: Double, space: Double, locked: Bool, signal: Double)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "ft710.rtty.decoder", qos: .userInitiated)
    private static let rate = 8000.0

    private var settings = RTTYSettings()
    private var mark = 2125.0
    private var paused = false

    // zmiana częstotliwości próbkowania
    private var inputRate = 0.0
    private var lowpass: [Float] = []
    private var lowpassHistory: [Float] = []
    private var lastFiltered: Float = 0
    private var resamplePosition = 0.0

    // widmo (bramka i zgrubne AFC)
    private var fftBuffer = [Float](repeating: 0, count: 2048)
    private var fftCount = 0
    private var spectrum: [Float] = []
    private let fftSetup = vDSP_DFT_zrop_CreateSetup(nil, 2048, .FORWARD)
    private let hann: [Float] = (0..<2048).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 2048)) }
    private var gate = false
    private var strong = 0
    private var weak = 0
    private var coarse: Double?
    private var held: [(Double, Double)] = []
    private var lastRatio = 0.0

    // mieszanie i filtr ~0,6 bitu (średnia krocząca na zespolonych)
    private var phaseMark = 0.0
    private var phaseSpace = 0.0
    private var boxMark: [(Double, Double)] = []
    private var boxSpace: [(Double, Double)] = []
    private var sumMark = (0.0, 0.0)
    private var sumSpace = (0.0, 0.0)
    private var boxIndex = 0
    private var lastMark = (0.0, 0.0)
    private var lastSpace = (0.0, 0.0)

    // FLL
    private var errorSum = 0.0
    private var weightSum = 0.0
    private var fllCount = 0
    private var noise = 1e-6

    // UART i Baudot
    private var framing = false
    private var t = 0.0
    private var accumulator: [Double] = []
    private var bits: [Int] = []
    private var previous = 1
    private var figures = false
    private var statusCount = 0

    deinit { if let fftSetup { vDSP_DFT_DestroySetup(fftSetup) } }

    // MARK: - API

    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [self] in
            guard !paused else { return }
            process(resample(samples, from: sampleRate))
        }
    }

    func configure(_ newSettings: RTTYSettings) {
        queue.async { [self] in
            let rebuild = newSettings.baud != settings.baud
            settings = newSettings
            if rebuild { boxMark = [] }
        }
    }

    /// Ręczne wskazanie tonu mark (kliknięcie w widmo).
    func setMark(_ hz: Double) {
        queue.async { [self] in
            mark = hz
            coarse = hz
            framing = false
        }
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            framing = false
        }
    }

    // MARK: - 8 kHz (filtr 3,4 kHz - tony RTTY do ~2,9 kHz)

    private func resample(_ input: [Float], from rate: Double) -> [Float] {
        if rate == Self.rate { return input }
        if rate != inputRate {
            inputRate = rate
            let n = 127
            let cutoff = 3400.0 / rate
            var taps = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let k = Double(i) - Double(n - 1) / 2
                let sinc = k == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * k) / (Double.pi * k)
                taps[i] = Float(sinc * (0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1))))
            }
            lowpass = taps.reversed()
            lowpassHistory = [Float](repeating: 0, count: n - 1)
            resamplePosition = 0
            lastFiltered = 0
        }
        guard !input.isEmpty else { return [] }
        let buffer = lowpassHistory + input
        var filtered = [Float](repeating: 0, count: input.count)
        buffer.withUnsafeBufferPointer { b in
            lowpass.withUnsafeBufferPointer { f in
                vDSP_conv(b.baseAddress!, 1, f.baseAddress!, 1, &filtered, 1, vDSP_Length(input.count), vDSP_Length(lowpass.count))
            }
        }
        lowpassHistory = Array(buffer.suffix(lowpass.count - 1))
        let step = rate / Self.rate
        var output: [Float] = []
        var position = resamplePosition
        while position < Double(filtered.count) {
            let i = Int(position)
            let frac = Float(position - Double(i))
            let a = i == 0 ? lastFiltered : filtered[i - 1]
            output.append(a + (filtered[i] - a) * frac)
            position += step
        }
        resamplePosition = position - Double(filtered.count)
        lastFiltered = filtered.last ?? lastFiltered
        return output
    }

    // MARK: - Sygnał

    private var tones: (mark: Double, space: Double) {
        settings.reverse ? (mark + settings.shift, mark) : (mark, mark + settings.shift)
    }

    private func process(_ x: [Float]) {
        guard !x.isEmpty else { return }
        fftBuffer = Array((fftBuffer + x).suffix(2048))
        fftCount += x.count
        if fftCount >= 2000 { fftCount = 0; analyseSpectrum() }

        let length = max(4, Int(Self.rate / settings.baud * 0.6))       // filtr ~0,6 bitu
        if boxMark.count != length {
            boxMark = Array(repeating: (0, 0), count: length)
            boxSpace = Array(repeating: (0, 0), count: length)
            sumMark = (0, 0); sumSpace = (0, 0); boxIndex = 0
        }
        let (fm, fs) = tones
        let stepMark = 2 * Double.pi * fm / Self.rate, stepSpace = 2 * Double.pi * fs / Self.rate
        let scale = 1 / Double(length)
        for v in x {
            let s = Double(v)
            let mre = s * cos(phaseMark), mim = -s * sin(phaseMark)
            let sre = s * cos(phaseSpace), sim = -s * sin(phaseSpace)
            phaseMark += stepMark; if phaseMark > 2 * Double.pi { phaseMark -= 2 * Double.pi }
            phaseSpace += stepSpace; if phaseSpace > 2 * Double.pi { phaseSpace -= 2 * Double.pi }
            let oldM = boxMark[boxIndex], oldS = boxSpace[boxIndex]
            boxMark[boxIndex] = (mre, mim); boxSpace[boxIndex] = (sre, sim)
            boxIndex = (boxIndex + 1) % length
            sumMark = (sumMark.0 + mre - oldM.0, sumMark.1 + mim - oldM.1)
            sumSpace = (sumSpace.0 + sre - oldS.0, sumSpace.1 + sim - oldS.1)
            sampleComplex((sumMark.0 * scale, sumMark.1 * scale), (sumSpace.0 * scale, sumSpace.1 * scale))
        }
    }

    private func analyseSpectrum() {
        guard let fftSetup else { return }
        let n = 2048, half = 1024
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(fftBuffer, 1, hann, 1, &windowed, 1, vDSP_Length(n))
        var inRe = [Float](repeating: 0, count: half), inIm = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half), outIm = [Float](repeating: 0, count: half)
        inRe.withUnsafeMutableBufferPointer { re in
            inIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        vDSP_DFT_Execute(fftSetup, inRe, inIm, &outRe, &outIm)
        var power = [Float](repeating: 0, count: half)
        for k in 1..<half { power[k] = outRe[k] * outRe[k] + outIm[k] * outIm[k] }
        if spectrum.count != half { spectrum = power }
        for k in 0..<half { spectrum[k] = 0.7 * spectrum[k] + 0.3 * power[k] }

        let binHz = Self.rate / Double(n)
        let k = Int((settings.shift / binHz).rounded())
        let lo = Int(600 / binHz), hi = min(Int((2900 - settings.shift) / binHz), half - k - 2)
        let medianBand = Array(spectrum[Int(300 / binHz)..<Int(3000 / binHz)]).sorted()
        let median = Double(max(medianBand[medianBand.count / 2], 1e-20))
        // para tonów: słabszy z dwóch - sam silny ton nie udaje pary
        var best = lo, bestScore: Float = 0
        if hi > lo {
            for i in lo...hi {
                let score = min(spectrum[i], spectrum[i + k])
                if score > bestScore { bestScore = score; best = i }
            }
        }
        let ratio = Double(bestScore) / median
        lastRatio = ratio
        strong = ratio > 6 ? strong + 1 : 0
        weak = ratio < 3 ? weak + 1 : 0
        if !gate, strong >= 2 {
            gate = true
            framing = false
            previous = 1
            let replay = held
            held = []
            for (m, s) in replay { decide(m, s) }
        }
        if gate, weak >= 6 { gate = false }

        guard settings.afc, ratio > 8, best > 0, best + 1 < spectrum.count else { return }
        // interpolacja paraboliczna wyniku pary
        func score(_ i: Int) -> Double { Double(min(spectrum[i], spectrum[min(i + k, half - 1)])) + 1e-20 }
        let a = log(score(best - 1)), b = log(score(best)), c = log(score(best + 1))
        let denominator = a - 2 * b + c
        let lower = (Double(best) + (denominator != 0 ? max(min(0.5 * (a - c) / denominator, 0.5), -0.5) : 0)) * binHz
        let target = settings.reverse ? lower + settings.shift : lower
        let confirmed = coarse.map { abs(target - $0) < 15 } ?? false
        coarse = target
        if confirmed, abs(target - mark) > 30, abs(target - mark) < 400 { mark = target }   // tylko duże odstrojenie
    }

    private func sampleComplex(_ am: (Double, Double), _ asp: (Double, Double)) {
        let m = (am.0 * am.0 + am.1 * am.1).squareRoot()
        let s = (asp.0 * asp.0 + asp.1 * asp.1).squareRoot()
        // FLL: obrót fazy na próbkę = odchyłka częstotliwości; tylko przy rozpoznanym sygnale
        if settings.afc, gate {
            if m > s, m > 2 * noise {
                errorSum += atan2(am.1 * lastMark.0 - am.0 * lastMark.1, am.0 * lastMark.0 + am.1 * lastMark.1) * Self.rate / (2 * .pi) * m
                weightSum += m
            } else if s > m, s > 2 * noise {
                errorSum += atan2(asp.1 * lastSpace.0 - asp.0 * lastSpace.1, asp.0 * lastSpace.0 + asp.1 * lastSpace.1) * Self.rate / (2 * .pi) * s
                weightSum += s
            }
            fllCount += 1
            if fllCount >= 1600, weightSum > 0 {                         // co 0,2 s, łagodnie
                let error = errorSum / weightSum
                if abs(error) < 80 {
                    mark += 0.25 * error
                    if let coarse { mark = min(max(mark, coarse - 100), coarse + 100) }
                }
                errorSum = 0; weightSum = 0; fllCount = 0
            }
        }
        lastMark = am
        lastSpace = asp
        noise += (min(m, s) < noise ? 0.02 : 0.001) * (min(m, s) - noise)
        if gate {
            decide(m, s)
        } else {
            held.append((m, s))
            if held.count > Int(1.5 * Self.rate) { held.removeFirst(held.count - Int(1.5 * Self.rate)) }
        }
        statusCount += 1
        if statusCount >= 1600 {                                          // ~5×/s
            statusCount = 0
            let (fm, fs) = tones
            onEvent?(.status(mark: fm, space: fs, locked: gate, signal: lastRatio))
        }
    }

    /// Decyzja: który ton silniejszy (m − s) - w porównaniu wygrała ze wszystkimi wariantami ATC.
    private func decide(_ m: Double, _ s: Double) {
        let d = m - s
        let bit = d > 0 ? 1 : 0
        let spb = Self.rate / settings.baud
        if !framing {
            if previous == 1, bit == 0 {                                  // zbocze bitu startu
                framing = true
                t = 0
                accumulator = []
                bits = []
            }
        } else {
            t += 1
            accumulator.append(d)
            let index = bits.count
            let centre = (Double(index) + 0.5) * spb
            if t >= centre + 0.25 * spb {
                let from = max(Int(centre - 0.25 * spb), 0), to = min(Int(centre + 0.25 * spb), accumulator.count)
                let mean = from < to ? accumulator[from..<to].reduce(0, +) / Double(to - from) : d
                bits.append(mean > 0 ? 1 : 0)
                if index == 0, bits[0] != 0 {
                    framing = false                                       // fałszywy start
                } else if bits.count == 7 {                               // start + 5 + stop
                    if bits[6] == 1 {
                        var code: UInt8 = 0
                        for i in 0..<5 where bits[1 + i] == 1 { code |= UInt8(1 << i) }
                        emit(code)
                    }
                    framing = false
                }
            }
        }
        previous = bit
    }

    private func emit(_ code: UInt8) {
        switch code {
        case Baudot.ltrsShift: figures = false
        case Baudot.figsShift: figures = true
        case Baudot.space:
            if settings.usos { figures = false }                          // Unshift On Space
            onEvent?(.text(" "))
        case Baudot.cr: break
        case Baudot.lf: onEvent?(.text("\n"))
        default:
            if let c = (figures ? Baudot.figures : Baudot.letters)[code] { onEvent?(.text(String(c))) }
        }
    }
}

/// Koder RTTY: tekst → Baudot (z LTRS/FIGS; po spacji FIGS wysyłane ponownie - odbiorcy z USOS) →
/// AFSK z ciągłą fazą: start 1 bit, 5 bitów (najmłodszy pierwszy), stop 1,5 bitu; spoczynek = mark.
enum RTTYEncoder {
    static func codes(for text: String) -> [UInt8] {
        var codes: [UInt8] = [Baudot.ltrsShift, Baudot.ltrsShift]
        var figures = false
        for ch in text.uppercased() {
            if ch == " " { codes.append(Baudot.space); figures = false; continue }
            if ch == "\n" { codes += [Baudot.cr, Baudot.lf]; continue }
            if let code = Baudot.lettersReverse[ch] {
                if figures { codes.append(Baudot.ltrsShift); figures = false }
                codes.append(code)
            } else if let code = Baudot.figuresReverse[ch] {
                if !figures { codes.append(Baudot.figsShift); figures = true }
                codes.append(code)
            }
        }
        return codes
    }

    static func duration(of text: String, baud: Double, lead: Double = 0.5, tail: Double = 0.3) -> Double {
        Double(codes(for: text).count) * 7.5 / baud + lead + tail
    }

    static func modulate(_ text: String, sampleRate: Double = 48_000, mark: Double = 2125, shift: Double = 170,
                         baud: Double = 45.45, reverse: Bool = false, amplitude: Float = 0.5,
                         lead: Double = 0.5, tail: Double = 0.3) -> [Float] {
        let fMark = reverse ? mark + shift : mark, fSpace = reverse ? mark : mark + shift
        var plan: [(Int, Double)] = [(1, lead * baud)]
        for code in codes(for: text) {
            plan.append((0, 1))
            for i in 0..<5 { plan.append((Int(code >> UInt8(i)) & 1, 1)) }
            plan.append((1, 1.5))
        }
        plan.append((1, tail * baud))
        var out: [Float] = []
        var phase = 0.0, time = 0.0
        var done = 0
        for (bit, bits) in plan {
            time += bits / baud
            let end = Int((time * sampleRate).rounded())
            let step = 2 * Double.pi * (bit == 1 ? fMark : fSpace) / sampleRate
            for _ in done..<max(end, done) {
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                out.append(amplitude * Float(sin(phase)))
            }
            done = max(end, done)
        }
        return out
    }
}
