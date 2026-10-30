import Foundation
import Accelerate

/// Alfabet Morse'a (wspólny dla dekodera i nadajnika).
enum Morse {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..", "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.", "/": "-..-.", "?": "..--..",
        "=": "-...-", ".": ".-.-.-", ",": "--..--", "+": ".-.-."
    ]
    static let decode: [String: Character] = Dictionary(uniqueKeysWithValues: table.map { ($1, $0) })
}

/// Model językowy krótkofalarskiego CW: trigram znakowy (początek słowa ^^, koniec $),
/// interpolowany z bigramem i unigramem. Korpus: typowe frazy QSO + znaki z dziennika użytkownika.
final class CWLanguageModel: @unchecked Sendable {
    private var tri: [String: [Character: Double]] = [:]
    private var bi: [Character: [Character: Double]] = [:]
    private var uni: [Character: Double] = [:]
    private var triTotal: [String: Double] = [:]
    private var biTotal: [Character: Double] = [:]
    private var uniTotal = 0.0
    private let k = 0.1
    private let vocabulary = Double(Morse.table.count + 1)

    init(extraWords: [String]) {
        var rng = SplitMix64(seed: 11)
        var words: [String] = []
        for _ in 0..<400 { words += Self.qso(&rng).split(separator: " ").map(String.init) }
        // znaki z dziennika i własny - częściej, żeby model je „znał”
        for word in extraWords { words += Array(repeating: word.uppercased(), count: 3) }
        for word in words {
            let w = Array("^^" + word.filter { Morse.table[$0] != nil } + "$")
            guard w.count > 3 else { continue }
            for i in 2..<w.count {
                let ctx = String(w[(i - 2)..<i]), c = w[i]
                tri[ctx, default: [:]][c, default: 0] += 1
                triTotal[ctx, default: 0] += 1
                bi[w[i - 1], default: [:]][c, default: 0] += 1
                biTotal[w[i - 1], default: 0] += 1
                uni[c, default: 0] += 1
                uniTotal += 1
            }
        }
    }

    /// log P(c | dwa poprzednie znaki)
    func logp(_ context: [Character], _ c: Character) -> Double {
        let a = context.count >= 2 ? String(context.suffix(2)) : String(repeating: "^", count: 2 - context.count) + String(context)
        let b = context.last ?? "^"
        let pt = ((tri[a]?[c] ?? 0) + k) / ((triTotal[a] ?? 0) + k * vocabulary)
        let pb = ((bi[b]?[c] ?? 0) + k) / ((biTotal[b] ?? 0) + k * vocabulary)
        let pu = ((uni[c] ?? 0) + k) / (uniTotal + k * vocabulary)
        return log(0.6 * pt + 0.3 * pb + 0.1 * pu)
    }

    // Typowe frazy QSO (jak w korpusie prototypu)
    private static func qso(_ rng: inout SplitMix64) -> String {
        let prefixes = ["SP", "SQ", "SO", "DL", "DK", "G", "M", "F", "I", "EA", "OK", "OM", "HA", "YO", "UR", "LY",
                        "K", "W", "N", "VE", "JA", "VK", "PY", "LU", "OH", "SM", "LA", "OZ", "PA", "ON"]
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        func call() -> String {
            var s = prefixes[rng.next(prefixes.count)] + String(rng.next(10))
            for _ in 0..<(1 + rng.next(3)) { s.append(letters[rng.next(letters.count)]) }
            return s
        }
        let names = ["TOM", "JAN", "PIOTR", "ANDY", "JOHN", "HANS", "PAUL", "MARK", "ADAM", "BOB", "KARL", "JOE", "ALEX", "ED"]
        let cities = ["WARSAW", "KRAKOW", "BERLIN", "LONDON", "PARIS", "ROMA", "PRAHA", "WIEN", "OSLO", "MADRID", "LODZ"]
        let rsts = ["599", "5NN", "579", "559", "449", "569"]
        let me = call(), dx = call(), rst = rsts[rng.next(rsts.count)]
        let lines = [
            "CQ CQ CQ DE \(me) \(me) K",
            "\(me) DE \(dx) \(dx) K",
            "\(dx) DE \(me) GM TNX FER CALL UR RST \(rst) \(rst) NAME \(names[rng.next(names.count)]) QTH \(cities[rng.next(cities.count)]) HW? \(dx) DE \(me) K",
            "\(me) DE \(dx) R TNX UR \(rst) NAME \(names[rng.next(names.count)]) RIG FT710 PWR 100W ANT DIPOLE WX SUNNY 73 \(me) DE \(dx) SK",
            "TU 73 GL \(dx) DE \(me) EE",
            "QRZ? DE \(me) K",
            "5NN TU"
        ]
        return (0..<3).map { _ in lines[rng.next(lines.count)] }.joined(separator: " ")
    }
}

/// Prosty, powtarzalny generator liczb losowych (korpus jest zawsze taki sam).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ upper: Int) -> Int { Int(nextRaw() % UInt64(upper)) }
}

/// Dekoder CW (algorytm sprawdzony prototypem na łącznościach z szumem, zanikami i nierówną ręką):
/// 8 kHz → automatyczne dostrajanie tonu (FFT + interpolacja) → obwiednia (mieszanie, dwa filtry
/// jednobiegunowe ~15% kropki) → próg z histerezą (szczyt z opadaniem, szum) i eliminacja zakłóceń
/// → tempo z globalnego dopasowania (kropki 1×, kreski 3×) → miękkie decyzje → przeszukiwanie
/// wiązkowe słowa z modelem językowym.
final class CWDecoder: @unchecked Sendable {
    enum Event: Sendable {
        case provisional(String)          // bieżące słowo (twarde decyzje)
        case word(String)                 // słowo zakończone (po modelu językowym)
        case status(pitch: Double, wpm: Double, snrDB: Double, locked: Bool)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "ft710.cw.decoder", qos: .userInitiated)
    private static let rate = 8000.0
    private static let tick = 16                                     // 2 ms
    private static let dotGrid: [Double] = (0..<120).map { 25 * pow(300.0 / 25, Double($0) / 119) }

    // ustawienia (z dowolnego wątku przez kolejkę)
    private var useModel = true
    private var useAPF = false
    private var apfFilter = Biquad()
    private var model: CWLanguageModel?
    private var lockedPitch: Double?
    private var paused = false

    // zmiana częstotliwości próbkowania na 8 kHz (jak w dekoderze SSTV)
    private var inputRate = 0.0
    private var lowpass: [Float] = []
    private var lowpassHistory: [Float] = []
    private var lastFiltered: Float = 0
    private var resamplePosition = 0.0

    // ton
    private var fftBuffer = [Float](repeating: 0, count: 1024)
    private var fftCount = 0
    private var spectrum: [Float] = []
    /// Widmo uśrednione ~1 s - do testu „czy to wąski ton CW” (harmoniczne mowy się rozmywają, ton CW nie).
    private var slowSpectrum: [Float] = []
    private var toneOK = false
    private var strongFrames = 0
    private var weakFrames = 0
    private var heldTicks: [Double] = []                             // obwiednia czekająca na decyzję „to CW”
    private var pitch = 700.0
    private var ready = false
    private let fftSetup = vDSP_DFT_zrop_CreateSetup(nil, 1024, .FORWARD)
    private let hann: [Float] = (0..<1024).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 1024)) }

    // obwiednia
    private var mixPhase = 0.0
    private var stage1 = (re: 0.0, im: 0.0)
    private var stage2 = (re: 0.0, im: 0.0)
    private var tickSum = 0.0
    private var tickCount = 0

    // próg i stany
    private var noise: Double?
    private var peak = 0.0
    private var down = false
    private var count = 0
    private var candidate = 0
    private var dot = 50.0                                           // ms (24 WPM)
    private var marks: [Double] = []
    private var sinceMark = 0.0
    private var statusCounter = 0

    // słowo
    private enum Element { case mark(Double), gap(Double) }          // p(kreska) / p(granica znaku)
    private var word: [Element] = []
    private var pendingGap: Double?

    deinit { if let fftSetup { vDSP_DFT_DestroySetup(fftSetup) } }

    // MARK: - API

    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [self] in
            guard !paused else { return }
            process(resample(samples, from: sampleRate))
        }
    }

    func configure(useModel: Bool, extraWords: [String]) {
        queue.async { [self] in
            self.useModel = useModel
            if useModel, model == nil { model = CWLanguageModel(extraWords: extraWords) }
        }
    }

    /// Ręczne ustawienie tonu (np. kliknięcie w widmo); nil = automatyczne dostrajanie.
    func lockPitch(_ hz: Double?) {
        queue.async { [self] in
            lockedPitch = hz
            if let hz { pitch = hz; ready = true; resetWord() }
        }
    }

    /// APF dekodera: filtr 100 Hz na tonie tylko na torze odczytu znaków (wyszukiwanie tonu widzi całe
    /// pasmo). Pomiar: przy SNR 0 dB błędy 22,5 → 18,4 %, przy silnym sygnale bez zmian, na szumie - cisza.
    func setAPF(_ on: Bool) {
        queue.async { [self] in
            if on != useAPF { apfFilter.reset() }
            useAPF = on
        }
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            if value { finishWord(); down = false; count = 0; candidate = 0 }
        }
    }

    // MARK: - Próbkowanie 8 kHz

    private func resample(_ input: [Float], from rate: Double) -> [Float] {
        if rate == Self.rate { return input }
        if rate != inputRate {
            inputRate = rate
            let n = 63
            let cutoff = 1500.0 / rate
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
        let buffer = lowpassHistory + input
        var filtered = [Float](repeating: 0, count: input.count)
        guard !input.isEmpty else { return [] }
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

    private func process(_ x: [Float]) {
        guard !x.isEmpty else { return }
        fftBuffer = Array((fftBuffer + x).suffix(1024))
        fftCount += x.count
        if fftCount >= 400 { fftCount = 0; updatePitch() }

        // mieszanie do pasma podstawowego i dwa filtry jednobiegunowe (stała ~15% kropki, 2…8 ms)
        let tau = min(max(dot * 0.15, 2), 8) / 1000
        let alpha = 1 - exp(-1 / (Self.rate * tau))
        let step = 2 * Double.pi * pitch / Self.rate
        if useAPF { apfFilter.setBandpass(center: pitch, bandwidth: 100, sampleRate: Self.rate) }
        for raw in x {
            let v = useAPF ? apfFilter.process(raw) : raw            // FFT tonu dostał sygnał bez filtra
            let s = Double(v)
            let re = s * cos(mixPhase), im = -s * sin(mixPhase)
            mixPhase += step
            if mixPhase > 2 * Double.pi { mixPhase -= 2 * Double.pi }
            stage1.re += alpha * (re - stage1.re); stage1.im += alpha * (im - stage1.im)
            stage2.re += alpha * (stage1.re - stage2.re); stage2.im += alpha * (stage1.im - stage2.im)
            tickSum += (stage2.re * stage2.re + stage2.im * stage2.im).squareRoot()
            tickCount += 1
            if tickCount == Self.tick {
                tick(tickSum / Double(Self.tick))
                tickSum = 0
                tickCount = 0
            }
        }
    }

    private func updatePitch() {
        guard let fftSetup else { return }
        let half = 512
        var windowed = [Float](repeating: 0, count: 1024)
        vDSP_vmul(fftBuffer, 1, hann, 1, &windowed, 1, 1024)
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
        if spectrum.count != half { spectrum = power; slowSpectrum = power }
        for k in 0..<half {
            spectrum[k] = 0.8 * spectrum[k] + 0.2 * power[k]
            slowSpectrum[k] = 0.95 * slowSpectrum[k] + 0.05 * power[k]
        }
        defer { updateToneCheck() }
        guard lockedPitch == nil else { return }

        let lo = Int(300.0 * 1024 / Self.rate), hi = Int(1200.0 * 1024 / Self.rate)
        var bandValues = Array(spectrum[lo...hi])
        guard let maxValue = bandValues.max(), let maxIndex = bandValues.firstIndex(of: maxValue) else { return }
        bandValues.sort()
        let median = bandValues[bandValues.count / 2]
        guard maxValue > 6 * median else { return }
        if maxValue > 10 * median { ready = true }                   // wyraźny ton - można dekodować
        let idx = lo + maxIndex
        // interpolacja paraboliczna między prążkami (dokładność ~1 Hz)
        let l = log(Double(spectrum[idx - 1]) + 1e-20), c = log(Double(spectrum[idx]) + 1e-20)
        let r = log(Double(spectrum[idx + 1]) + 1e-20)
        let denominator = l - 2 * c + r
        let offset = denominator != 0 ? min(max(0.5 * (l - r) / denominator, -0.5), 0.5) : 0
        let estimate = (Double(idx) + offset) * Self.rate / 1024
        let current = Int((pitch * 1024 / Self.rate).rounded())
        if abs(idx - current) <= 3 {
            pitch += 0.3 * (estimate - pitch)                        // płynne dostrajanie
        } else if current > 0, current < half, maxValue > 2 * spectrum[current] {
            pitch = estimate                                         // inna, silniejsza stacja
            resetWord()
            marks = []
        }
    }

    /// Czy na tonie jest wąski sygnał CW: moc ±1 prążek wokół tonu / średnia z otoczenia (±6…25 prążków,
    /// ok. ±50…200 Hz). Pomiar na nagraniach: CW ≥ ~12 nawet przy SNR 0 dB, fonia SSB zwykle < 12, szum ~2.
    /// Dekodowanie rusza po 0,5 s powyżej 14 i milknie po 1,5 s poniżej 5 - przy fonii nie powstają śmieci.
    /// Obwiednia z ostatnich 3 s jest pamiętana i po otwarciu odtwarzana (pomiar: przy fonii SSB dekoder milczy,
    /// CW czysty ~0 % błędów, SNR 3 dB 3 %).
    private func updateToneCheck() {
        let k = Int((pitch * 1024 / Self.rate).rounded())
        guard k - 26 >= 0, k + 26 < slowSpectrum.count else { return }
        let tone = max(slowSpectrum[k - 1], slowSpectrum[k], slowSpectrum[k + 1])
        var side: Float = 0
        for i in (k - 25)..<(k - 5) { side += slowSpectrum[i] }
        for i in (k + 6)..<(k + 26) { side += slowSpectrum[i] }
        let ratio = tone / max(side / 40, 1e-20)
        strongFrames = ratio > 14 ? strongFrames + 1 : 0
        weakFrames = ratio < 5 ? weakFrames + 1 : 0
        if !toneOK, strongFrames >= 10 {
            toneOK = true
            down = false; count = 0; candidate = 0                   // od czystego stanu klucza
            // odtwórz zapamiętaną obwiednię - początek transmisji (CQ, znak) nie ginie
            let replay = heldTicks
            heldTicks = []
            for v in replay { decodeTick(v) }
        }
        if toneOK, weakFrames >= 30 {                                // 1,5 s bez tonu CW
            toneOK = false
            finishWord()                                             // koniec CW - zamknij bieżące słowo
        }
    }

    // MARK: - Takty 2 ms

    private func tick(_ v: Double) {
        if noise == nil { noise = v; peak = v }
        guard var noiseLevel = noise else { return }
        peak = max(v, peak * 0.997)                                   // szczyt z opadaniem (QSB)
        noiseLevel += (v < noiseLevel ? 0.05 : 0.002) * (v - noiseLevel)
        noise = noiseLevel
        statusCounter += 1
        if statusCounter >= 100 {                                     // ~5×/s
            statusCounter = 0
            let snr = 20 * log10(max(peak, 1e-12) / max(noiseLevel, 1e-12))
            onEvent?(.status(pitch: pitch, wpm: 1200 / dot, snrDB: snr, locked: ready && toneOK))
        }
        guard ready, toneOK else {                                    // bez wąskiego tonu CW - nie dekodujemy,
            heldTicks.append(v)                                       // ale pamiętamy ostatnie 3 s obwiedni
            if heldTicks.count > 1500 { heldTicks.removeFirst(heldTicks.count - 1500) }
            return
        }
        decodeTick(v)
    }

    /// Część decyzyjna taktu: próg z histerezą, eliminacja zakłóceń, długości elementów.
    private func decodeTick(_ v: Double) {
        guard let noiseLevel = noise else { return }
        let span = max(peak - noiseLevel, 1e-12)
        let squelch = peak < 3 * noiseLevel
        let raw = down ? v > noiseLevel + 0.3 * span : (v > noiseLevel + 0.5 * span && !squelch)
        let minTicks = max(2, Int(0.3 * dot / 2))                     // zmiana stanu musi trwać ≥30% kropki
        candidate = raw != down ? candidate + 1 : 0
        count += 1
        if candidate >= minTicks {
            let length = Double(count - candidate) * 2
            if down { onMark(length) } else { onSpace(length) }
            down.toggle()
            count = candidate
            candidate = 0
        }
        if !down {
            sinceMark += 2
            if !word.isEmpty, sinceMark > 5 * dot { finishWord() }
        }
    }

    private static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-min(max(x, -40), 40))) }

    private func onMark(_ ms: Double) {
        let pDash = Self.sigmoid((log(ms) - log(2 * dot)) / 0.25)
        marks.append(ms)
        if marks.count > 30 { marks.removeFirst(marks.count - 30) }
        updateSpeed()
        if let gap = pendingGap, !word.isEmpty { word.append(.gap(gap)) }
        pendingGap = nil
        word.append(.mark(pDash))
        sinceMark = 0
        onEvent?(.provisional(hardDecode()))
    }

    private func onSpace(_ ms: Double) {
        guard !word.isEmpty else { return }
        let r = log(max(ms, 1) / dot)
        if r > log(5.0) { finishWord(); return }
        pendingGap = Self.sigmoid((r - log(2.0)) / 0.25)
    }

    /// Tempo: która kropka (25…300 ms) najlepiej tłumaczy ostatnie znaki jako kropki (1×) i kreski (3×).
    private func updateSpeed() {
        guard let last = marks.last else { return }
        if marks.count < 8 {
            dot += 0.3 * ((last < 2 * dot ? last : last / 3) - dot)
            return
        }
        let logs = marks.map { log($0) }
        let log3 = log(3.0)
        var best = dot, bestCost = Double.infinity
        for candidateDot in Self.dotGrid {
            let d = log(candidateDot)
            var cost = 0.0
            for x in logs { cost += min(min(abs(x - d), abs(x - d - log3)), 0.7) }
            if cost < bestCost { bestCost = cost; best = candidateDot }
        }
        dot += 0.3 * (best - dot)
    }

    // MARK: - Słowa

    private func hardDecode() -> String {
        var text = "", code = ""
        for element in word {
            switch element {
            case .mark(let p): code += p > 0.5 ? "-" : "."
            case .gap(let p):
                if p > 0.5 { text.append(Morse.decode[code] ?? "*"); code = "" }
            }
        }
        if !code.isEmpty { text.append(Morse.decode[code] ?? "*") }
        return text
    }

    private func finishWord() {
        guard !word.isEmpty else { return }
        let text = (useModel ? model.map { beamDecode($0) } : nil) ?? hardDecode()
        resetWord()
        onEvent?(.word(text))
    }

    private func resetWord() {
        word = []
        pendingGap = nil
        onEvent?(.provisional(""))
    }

    /// Przeszukiwanie wiązkowe: niepewne elementy (kropka/kreska) i przerwy (w znaku / między znakami)
    /// rozważane razem, wynik oceniany modelem językowym (waga 0,25 - rozstrzyga tylko przypadki niejasne).
    private func beamDecode(_ lm: CWLanguageModel) -> String {
        let weight = 0.25
        struct Hypothesis { var text: [Character]; var code: String; var score: Double }
        var hyps = [Hypothesis(text: [], code: "", score: 0)]
        for element in word {
            var next: [Hypothesis] = []
            switch element {
            case .mark(let raw):
                let p = min(max(raw, 1e-4), 1 - 1e-4)
                for h in hyps {
                    next.append(Hypothesis(text: h.text, code: h.code + "-", score: h.score + log(p)))
                    next.append(Hypothesis(text: h.text, code: h.code + ".", score: h.score + log(1 - p)))
                }
            case .gap(let raw):
                let p = min(max(raw, 1e-4), 1 - 1e-4)
                for h in hyps {
                    if h.code.count < 6 {
                        next.append(Hypothesis(text: h.text, code: h.code, score: h.score + log(1 - p)))
                    }
                    if let c = Morse.decode[h.code] {
                        next.append(Hypothesis(text: h.text + [c], code: "",
                                               score: h.score + log(p) + weight * lm.logp(h.text, c)))
                    }
                }
            }
            next.sort { $0.score > $1.score }
            hyps = Array(next.prefix(32))
        }
        var best: (String, Double)?
        for h in hyps {
            guard let c = Morse.decode[h.code] else { continue }
            let score = h.score + weight * (lm.logp(h.text, c) + lm.logp(h.text + [c], "$"))
            if best == nil || score > best!.1 { best = (String(h.text + [c]), score) }
        }
        return best?.0 ?? hardDecode()
    }
}
