import Foundation
import Accelerate
import CoreGraphics

/// Strumieniowy dekoder SSTV (wszystko na własnej kolejce):
/// 1. zmiana częstotliwości próbkowania na 24 kHz,
/// 2. zespolony filtr pasmowy 850–2650 Hz → sygnał analityczny → częstotliwość chwilowa,
/// 3. wykrycie nagłówka VIS (bloki 10 ms, progi względem zmierzonego tonu - toleruje rozstrojenie),
/// 4. odczyt linii z wyszukiwaniem synchronizacji i dopasowaniem prostej (korekcja pochylenia).
final class SSTVDecoder: @unchecked Sendable {
    enum Event: Sendable {
        case started(SSTVMode)
        case progress(CGImage, Double)
        case finished(CGImage, SSTVMode, complete: Bool)
        case tone(Float)                       // bieżący ton (do wskaźnika strojenia)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    static let rate = 24_000.0
    private let ms = 24.0                      // próbek na milisekundę
    private let queue = DispatchQueue(label: "ft710.sstv.decoder", qos: .userInitiated)

    // Zmiana częstotliwości próbkowania
    private var inputRate = 0.0
    private var lowpass: [Float] = []          // odwrócone wagi dla vDSP_conv
    private var lowpassHistory: [Float] = []
    private var lastFiltered: Float = 0
    private var resamplePosition = 0.0

    // Filtr analityczny
    private let bandI: [Float]
    private let bandQ: [Float]
    private var bandHistory: [Float]
    private var previousI: Float = 0
    private var previousQ: Float = 0

    // Strumień częstotliwości: freq[k] to próbka o numerze bezwzględnym base + k
    private var freq: [Float] = []
    private var base = 0
    private var total: Int { base + freq.count }

    // Stan
    private enum State { case idle, vis, receiving }
    private var state = State.idle
    private var paused = false
    private var blocks: [Float] = []           // mediany bloków 10 ms
    private var blockBase = 0                  // numer bezwzględny pierwszego bloku
    private var nextBlock = 0
    private var visStart = 0                   // próbka początku bitu startu
    private var offset: Float = 0              // korekta rozstrojenia: 1900 - zmierzony leader
    private var toneCounter = 0

    // Odbiór obrazu
    private var mode: SSTVMode?
    private var lineStart = 0.0
    private var linePeriod = 0.0
    private var renderedPeriod = 0.0
    private var renderedStart = 0.0
    private var nextLine = 0
    private var syncs: [(line: Int, start: Double)] = []
    private var missedSyncs = 0
    private var pixels: [UInt8] = []           // RGBA
    private var chromaRows: [[Double]] = []    // Robot 36: chroma każdej linii
    private var lumaRows: [[Double]] = []

    init() {
        // Zespolony FIR: dolnoprzepustowy (połowa pasma) przesunięty na środek pasma SSTV.
        let n = 97
        let fc = 1750.0, half = 900.0
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let k = Double(i) - Double(n - 1) / 2
            let x = 2 * half / Self.rate * k
            let sinc = k == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let blackman = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            let lp = 2 * half / Self.rate * sinc * blackman
            re[i] = Float(lp * cos(2 * Double.pi * fc * k / Self.rate))
            im[i] = Float(lp * sin(2 * Double.pi * fc * k / Self.rate))
        }
        // vDSP_conv liczy korelację - odwrócone wagi dają zwykły splot.
        bandI = re.reversed()
        bandQ = im.reversed()
        bandHistory = [Float](repeating: 0, count: n - 1)
    }

    // MARK: - API (dowolny wątek)

    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [self] in
            guard !paused else { return }
            process(resample(samples, from: sampleRate))
        }
    }

    /// Wstrzymanie (np. podczas własnego nadawania) i wznowienie od czystego stanu.
    func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            if value { abortReception(emit: false) }
        }
    }

    /// Zakończ bieżący odbiór (zachowując odebraną część obrazu).
    func stopReception() {
        queue.async { [self] in abortReception(emit: true) }
    }

    // MARK: - Zmiana częstotliwości próbkowania na 24 kHz

    private func resample(_ input: [Float], from rate: Double) -> [Float] {
        if rate == Self.rate { return input }
        if rate != inputRate {
            inputRate = rate
            // dolnoprzepustowy 4 kHz (SSTV kończy się na 2,3 kHz)
            let n = 65
            let cutoff = 4000.0 / rate
            var taps = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let k = Double(i) - Double(n - 1) / 2
                let sinc = k == 0 ? 1.0 : sin(2 * Double.pi * cutoff * k) / (Double.pi * k)
                let hamming = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1))
                taps[i] = Float((k == 0 ? 2 * cutoff : sinc) * hamming)
            }
            lowpass = taps.reversed()
            lowpassHistory = [Float](repeating: 0, count: n - 1)
            resamplePosition = 0
            lastFiltered = 0
        }
        let filtered = convolve(input, lowpass, history: &lowpassHistory)
        // interpolacja liniowa; indeks 0 = ostatnia próbka poprzedniej porcji
        let step = rate / Self.rate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(filtered.count) / step) + 2)
        var position = resamplePosition
        let count = filtered.count
        while position < Double(count) {
            let i = Int(position)
            let frac = Float(position - Double(i))
            let a = i == 0 ? lastFiltered : filtered[i - 1]
            let b = filtered[i]
            output.append(a + (b - a) * frac)
            position += step
        }
        resamplePosition = position - Double(count)
        lastFiltered = filtered.last ?? lastFiltered
        return output
    }

    /// Splot z zachowaniem historii między porcjami (wynik ma tyle próbek co wejście).
    private func convolve(_ input: [Float], _ reversedTaps: [Float], history: inout [Float]) -> [Float] {
        let n = reversedTaps.count
        let buffer = history + input
        var out = [Float](repeating: 0, count: input.count)
        guard !input.isEmpty else { return out }
        buffer.withUnsafeBufferPointer { b in
            reversedTaps.withUnsafeBufferPointer { f in
                vDSP_conv(b.baseAddress!, 1, f.baseAddress!, 1, &out, 1, vDSP_Length(input.count), vDSP_Length(n))
            }
        }
        history = Array(buffer.suffix(n - 1))
        return out
    }

    // MARK: - Demodulacja

    private func process(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var bandHistoryI = bandHistory
        let i = convolve(samples, bandI, history: &bandHistoryI)
        var bandHistoryQ = bandHistory
        let q = convolve(samples, bandQ, history: &bandHistoryQ)
        bandHistory = bandHistoryI
        let scale = Float(Self.rate / (2 * Double.pi))
        for k in 0..<samples.count {
            let re = i[k], im = q[k]
            let num = im * previousI - re * previousQ
            let den = re * previousI + im * previousQ
            freq.append(atan2f(num, den) * scale)
            previousI = re
            previousQ = im
        }
        run()
    }

    private func run() {
        if state == .idle { scanForVIS() }
        if state == .vis { readVIS() }
        if state == .receiving { readLines() }
        if state == .idle { trimIdleBuffer() }
    }

    private func value(at index: Int) -> Float { freq[index - base] }

    /// Średnia częstotliwość w przedziale próbek bezwzględnych [a, b).
    private func mean(_ a: Double, _ b: Double) -> Float {
        let start = max(Int(a.rounded()) - base, 0)
        let end = min(max(Int(b.rounded()) - base, start + 1), freq.count)
        guard start < end else { return 0 }
        var result: Float = 0
        freq.withUnsafeBufferPointer { p in
            vDSP_meanv(p.baseAddress! + start, 1, &result, vDSP_Length(end - start))
        }
        return result
    }

    // MARK: - Nagłówek VIS

    private func scanForVIS() {
        while (nextBlock + 1) * 240 <= total {
            let start = nextBlock * 240
            guard start >= base else {
                // początek strumienia został przycięty - zacznij bloki od nowa
                nextBlock = base / 240 + 1
                blocks.removeAll()
                blockBase = nextBlock
                continue
            }
            var block = Array(freq[(start - base)..<(start - base + 240)])
            vDSP_vsort(&block, 240, 1)
            blocks.append(block[120])
            nextBlock += 1
            toneCounter += 1
            if toneCounter % 10 == 0 { onEvent?(.tone(block[120])) }   // ~10×/s
            if blocks.count > 200 {
                blocks.removeFirst(blocks.count - 200)
                blockBase = nextBlock - blocks.count
            }
            if detectVIS(atBlock: nextBlock - 1) { return }
        }
    }

    /// Wzorzec na blokach 10 ms: leader (≥15 stabilnych), przerwa, leader (≥20), spadek ~700 Hz (bit startu).
    private func detectVIS(atBlock b: Int) -> Bool {
        let i = b - blockBase
        guard i >= 60 else { return false }
        let lead2 = Array(blocks[(i - 24)..<(i - 3)])
        guard let lo = lead2.min(), let hi = lead2.max(), hi - lo < 60 else { return false }
        let l = lead2.sorted()[lead2.count / 2]
        guard l > 1600, l < 2200, blocks[i] < l - 450 else { return false }
        let window = Array(blocks[(i - 60)..<(i - 24)])
        guard let breakIndex = window.firstIndex(where: { $0 < l - 350 }) else { return false }
        let lead1 = Array(window[..<breakIndex].suffix(20))
        guard lead1.count >= 15 else { return false }
        let lead1Median = lead1.sorted()[lead1.count / 2]
        guard abs(lead1Median - l) <= 60 else { return false }

        // dokładny początek bitu startu: przejście wygładzonej częstotliwości poniżej L-350
        let from = (b - 2) * 240, to = (b + 1) * 240
        guard from - 12 >= base, to + 12 <= total else { return false }
        var crossing = from
        for s in from..<to {
            var sum: Float = 0
            for k in (s - 12)..<(s + 12) { sum += value(at: k) }
            if sum / 24 < l - 350 { crossing = s; break }
        }
        visStart = crossing
        offset = 1900 - l
        state = .vis
        return true
    }

    private func readVIS() {
        let t0 = Double(visStart)
        guard Double(total) >= t0 + 310 * ms else { return }
        let startBit = mean(t0 + 5 * ms, t0 + 25 * ms) + offset
        guard abs(startBit - 1200) <= 120 else { state = .idle; return }
        var bits: [Int] = []
        for k in 0..<8 {
            let f = mean(t0 + (30 * Double(k + 1) + 6) * ms, t0 + (30 * Double(k + 2) - 6) * ms) + offset
            bits.append(f < 1200 ? 1 : 0)
        }
        let code = (0..<7).reduce(0) { $0 | (bits[$1] << $1) }
        guard bits[0..<7].reduce(0, +) % 2 == bits[7], let found = SSTVMode.byVIS(code) else {
            state = .idle
            return
        }
        startImage(found, at: t0 + 300 * ms + (found.kind == .scottie ? found.sync * ms : 0))
    }

    // MARK: - Obraz

    private func startImage(_ found: SSTVMode, at start: Double) {
        mode = found
        lineStart = start
        linePeriod = found.period * ms
        renderedPeriod = linePeriod
        renderedStart = lineStart
        nextLine = 0
        syncs = []
        missedSyncs = 0
        pixels = [UInt8](repeating: 0, count: found.width * found.height * 4)
        for p in stride(from: 3, to: pixels.count, by: 4) { pixels[p] = 255 }
        lumaRows = Array(repeating: [], count: found.height)
        chromaRows = Array(repeating: [], count: found.height)
        state = .receiving
        onEvent?(.started(found))
    }

    private func readLines() {
        guard let mode else { state = .idle; return }
        while nextLine < mode.transmissionLines {
            let end = lineStart + Double(nextLine + 1) * linePeriod + 6 * ms
            guard Double(total) >= end else { return }
            if let start = syncStart(line: nextLine, mode: mode) {
                syncs.append((nextLine, start))
                missedSyncs = 0
                if nextLine % 4 == 3 { refit(mode) }
            } else {
                missedSyncs += 1
            }
            if abs(linePeriod - renderedPeriod) > 0.05 || abs(lineStart - renderedStart) > 2 {
                // dopasowanie się zmieniło - przelicz wcześniejsze linie z nowym pochyleniem i przesunięciem
                renderedPeriod = linePeriod
                renderedStart = lineStart
                for line in 0..<nextLine { render(line: line, mode: mode) }
            }
            render(line: nextLine, mode: mode)
            nextLine += 1
            if nextLine % 4 == 0 || nextLine == mode.transmissionLines, let image = makeImage(mode) {
                onEvent?(.progress(image, Double(nextLine) / Double(mode.transmissionLines)))
            }
            if missedSyncs >= 15 {                     // nadawanie przerwane - kończymy z tym, co jest
                finish(mode, complete: false)
                return
            }
        }
        finish(mode, complete: true)
    }

    /// Początek linii wg impulsu synchronizacji (szukanie ±4 ms wokół oczekiwanego miejsca).
    private func syncStart(line: Int, mode: SSTVMode) -> Double? {
        let expected = lineStart + Double(line) * linePeriod + mode.syncOffset * ms
        let length = Int(mode.sync * ms)
        let span = Int(4 * ms)
        let a = Int(expected) - span, b = Int(expected) + span + length
        guard a - 12 >= base, b + 12 <= total else { return nil }
        // wygładzona częstotliwość (1 ms) poniżej 1350 Hz po korekcie rozstrojenia
        var below = [Float](repeating: 0, count: b - a)
        for s in a..<b {
            var sum: Float = 0
            for k in (s - 12)..<(s + 12) { sum += value(at: k) }
            below[s - a] = sum / 24 + offset < 1350 ? 1 : 0
        }
        var window: Float = below[0..<length].reduce(0, +)
        var best = window, bestIndex = 0
        if below.count > length {
            for p in 1...(below.count - length) {
                window += below[p + length - 1] - below[p - 1]
                if window > best { best = window; bestIndex = p }
            }
        }
        guard best >= 0.7 * Float(length) else { return nil }
        return Double(a + bestIndex) - mode.syncOffset * ms
    }

    /// Dopasowanie prostej do położeń synchronizacji (dwa przebiegi z odrzuceniem odstających).
    private func refit(_ mode: SSTVMode) {
        var points = syncs.map { (Double($0.line), $0.start) }
        guard points.count >= 6 else { return }
        var slope = linePeriod, intercept = lineStart
        for _ in 0..<2 {
            let n = Double(points.count)
            let sx = points.reduce(0) { $0 + $1.0 }, sy = points.reduce(0) { $0 + $1.1 }
            let sxx = points.reduce(0) { $0 + $1.0 * $1.0 }, sxy = points.reduce(0) { $0 + $1.0 * $1.1 }
            let d = n * sxx - sx * sx
            guard d != 0 else { return }
            slope = (n * sxy - sx * sy) / d
            intercept = (sy - slope * sx) / n
            let kept = points.filter { abs($0.1 - (slope * $0.0 + intercept)) < ms }
            guard kept.count >= 6 else { return }
            points = kept
        }
        let nominal = mode.period * ms
        if abs(slope / nominal - 1) < 0.003 {            // najwyżej 3000 ppm
            linePeriod = slope
            lineStart = intercept
        }
    }

    private func scanValues(start: Double, length: Double, width: Int) -> [Double] {
        let pixelSamples = length * ms / Double(width)
        var out = [Double](repeating: 0, count: width)
        for x in 0..<width {
            let f = mean(start + Double(x) * pixelSamples, start + Double(x + 1) * pixelSamples) + offset
            out[x] = Double(min(max((f - 1500) * 255 / 800, 0), 255))
        }
        return out
    }

    private func setPixel(_ row: Int, _ x: Int, _ width: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        let i = (row * width + x) * 4
        pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b
    }

    private func render(line: Int, mode: SSTVMode) {
        let w = mode.width
        let lineBase = lineStart + Double(line) * linePeriod
        var values: [SSTVMode.Channel: [Double]] = [:]
        for scan in mode.scans {
            values[scan.channel] = scanValues(start: lineBase + scan.offset * ms, length: scan.length, width: w)
        }
        switch mode.kind {
        case .martin, .scottie:
            guard let r = values[.r], let g = values[.g], let b = values[.b] else { return }
            for x in 0..<w { setPixel(line, x, w, UInt8(r[x]), UInt8(g[x]), UInt8(b[x])) }
        case .pd:
            guard let y1 = values[.y1], let y2 = values[.y2], let u = values[.u], let v = values[.v] else { return }
            for x in 0..<w {
                let top = SSTVColor.rgb(y: y1[x], u: u[x], v: v[x])
                let bottom = SSTVColor.rgb(y: y2[x], u: u[x], v: v[x])
                setPixel(2 * line, x, w, top.r, top.g, top.b)
                setPixel(2 * line + 1, x, w, bottom.r, bottom.g, bottom.b)
            }
        case .robot36:
            guard let y = values[.y], let c = values[.chroma] else { return }
            lumaRows[line] = y
            chromaRows[line] = c
            let pair = line - line % 2
            if line % 2 == 1, !chromaRows[pair].isEmpty {
                // linia parzysta niesie V (R-Y), nieparzysta U (B-Y) - kolor dla obu linii pary
                let v = chromaRows[pair], u = c
                for row in [pair, line] where !lumaRows[row].isEmpty {
                    for x in 0..<w {
                        let rgb = SSTVColor.rgb(y: lumaRows[row][x], u: u[x], v: v[x])
                        setPixel(row, x, w, rgb.r, rgb.g, rgb.b)
                    }
                }
            } else {
                for x in 0..<w { let g = UInt8(y[x]); setPixel(line, x, w, g, g, g) }   // do czasu pary - szarość
            }
        }
    }

    private func makeImage(_ mode: SSTVMode) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: mode.width, height: mode.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: mode.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func finish(_ mode: SSTVMode, complete: Bool) {
        // końcowe przeliczenie całego obrazu z ostatecznym dopasowaniem (jak w prototypie)
        refit(mode)
        for line in 0..<nextLine { render(line: line, mode: mode) }
        if let image = makeImage(mode), nextLine > 8 {
            onEvent?(.finished(image, mode, complete: complete))
        }
        self.mode = nil
        state = .idle
        blocks.removeAll()
        nextBlock = total / 240                      // szukaj kolejnego VIS od bieżącego miejsca
        blockBase = nextBlock
    }

    private func abortReception(emit: Bool) {
        if state == .receiving, let mode {
            if emit { finish(mode, complete: false) } else { self.mode = nil }
        }
        state = .idle
        blocks.removeAll()
        nextBlock = total / 240
        blockBase = nextBlock
    }

    /// Bez odbioru trzymamy najwyżej ~10 s strumienia (nagłówek VIS trwa niecałą sekundę).
    private func trimIdleBuffer() {
        let keep = Int(5 * Self.rate)
        guard freq.count > Int(10 * Self.rate) else { return }
        let drop = freq.count - keep
        freq.removeFirst(drop)
        base += drop
        if nextBlock * 240 < base {
            nextBlock = base / 240 + 1
            blocks.removeAll()
            blockBase = nextBlock
        }
    }
}
