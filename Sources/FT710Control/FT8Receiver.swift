import Foundation
import Accelerate
import CoreGraphics
import FTX

/// Tryby z rodziny FT (stała długość cyklu, dekodowanie po każdym cyklu).
enum FTMode: String, CaseIterable, Identifiable {
    case ft8 = "FT8"
    case ft4 = "FT4"

    var id: String { rawValue }
    /// Długość cyklu w sekundach (FT8 15 s, FT4 7,5 s).
    var period: Double { self == .ft8 ? 15 : 7.5 }
    /// Sekunda cyklu, w której dekodujemy. Sygnał FT8 trwa 0,5 + 12,64 s, FT4 0,5 + 5,04 s;
    /// zapas pozwala złapać stacje ze spóźnionym zegarem, a zostaje czas na odpowiedź w następnym cyklu.
    var decodeAt: Double { self == .ft8 ? 14.0 : 6.6 }
    /// Kod protokołu dla ftxw (0 = FT8, 1 = FT4).
    var protocolCode: Int32 { self == .ft8 ? 0 : 1 }
    /// Szerokość sygnału w Hz (8 tonów × 6,25 Hz albo 4 tony × 20,83 Hz).
    var bandwidth: Double { self == .ft8 ? 50 : 83.3 }
    /// Standardowe częstotliwości (dial, USB/DATA-U) wg WSJT-X dla Regionu 1.
    var dialFrequencies: [Int] {
        switch self {
        case .ft8:
            return [1_840_000, 3_573_000, 5_357_000, 7_074_000, 10_136_000, 14_074_000, 18_100_000,
                    21_074_000, 24_915_000, 28_074_000, 50_313_000]
        case .ft4:
            return [3_575_000, 7_047_500, 10_140_000, 14_080_000, 18_104_000, 21_140_000,
                    24_919_000, 28_180_000, 50_318_000]
        }
    }

    /// Standardowa częstotliwość tego trybu na paśmie, na którym jest `hz` (np. 7 074 000 → FT4: 7 047 500);
    /// nil - tryb nie ma częstotliwości na tym paśmie (FT4 na 160 i 60 m) albo `hz` jest poza pasmami.
    func dialFrequency(sameBandAs hz: Int) -> Int? {
        guard let band = LogFrequency.band(for: hz) else { return nil }
        return dialFrequencies.first { LogFrequency.band(for: $0) == band }
    }
}

/// Jeden zdekodowany komunikat (wynik dekodera C, przed opisem kraju i statusu w dzienniku).
struct FTRawDecode: Sendable {
    let slot: Date
    let mode: FTMode
    let snr: Int
    let dt: Double
    let freq: Double
    let text: String
}

/// Zakodowany komunikat do nadania: liczba tonów (< 0 = błąd kodowania), echo i próbki dźwięku.
struct FTTxAudio: Sendable {
    let code: Int
    let echo: String
    let samples: [Float]

    /// Czy odbiorca zobaczy to, co chcieliśmy nadać (pomijając nawiasy <> przy znakach ze skrótu).
    func matches(_ text: String) -> Bool {
        code > 0 && FTTxAudio.normalized(echo) == FTTxAudio.normalized(text)
    }

    static func normalized(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            .split(separator: " ").joined(separator: " ")
    }
}

/// Początek cyklu na wodospadzie.
struct FTWaterfallMark: Hashable {
    let row: Int
    let label: String
}

/// Wodospad gotowy do narysowania: obraz (najnowszy wiersz u góry) i znaczniki początków cykli.
struct FTWaterfallFrame: @unchecked Sendable {   // CGImage jest niezmienny
    let image: CGImage
    let maxHz: Double
    /// Wiersze, w których zaczął się cykl: odległość od góry (w wierszach) i opis (czas UTC).
    let boundaries: [FTWaterfallMark]
    let rows: Int
}

/// Przepróbkowanie do 12 kHz: filtr dolnoprzepustowy FIR (sinc z oknem Blackmana, 4,8 kHz) w częstotliwości
/// wejściowej, potem interpolacja liniowa. Sprawdzone prototypem: 12 kHz → 48 kHz → 12 kHz w losowych porcjach
/// zachowuje 100% dekodów FT8 (44,1 kHz: 99,3%).
final class Resampler12k {
    static let outputRate = 12_000.0
    private var rate = 0.0
    private var taps: [Float] = []
    private var history: [Float] = []
    private var phase = 0.0
    private var lastY: Float = 0

    private func configure(_ r: Double) {
        rate = r
        let m = Int(r / Self.outputRate * 16) | 1
        let fc = 4800.0 / r
        let mid = Double(m - 1) / 2
        var t = [Float](repeating: 0, count: m)
        for k in 0..<m {
            let x = Double(k) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(k) / Double(m - 1)) + 0.08 * cos(4 * Double.pi * Double(k) / Double(m - 1))
            t[k] = Float(sinc * w)
        }
        let sum = t.reduce(0, +)
        taps = t.map { $0 / sum }
        history = [Float](repeating: 0, count: m - 1)
        phase = 0
        lastY = 0
    }

    func process(_ x: [Float], rate r: Double) -> [Float] {
        guard !x.isEmpty, r >= Self.outputRate else { return [] }
        if r != rate { configure(r) }
        let n = x.count, m = taps.count
        let buf = history + x
        var y = [Float](repeating: 0, count: n)
        // vDSP_conv: y[i] = Σ buf[i + k] · taps[k] (filtr symetryczny - kierunek bez znaczenia)
        buf.withUnsafeBufferPointer { b in
            taps.withUnsafeBufferPointer { t in
                vDSP_conv(b.baseAddress!, 1, t.baseAddress!, 1, &y, 1, vDSP_Length(n), vDSP_Length(m))
            }
        }
        history = Array(buf.suffix(m - 1))
        let step = r / Self.outputRate
        var out = [Float]()
        out.reserveCapacity(Int(Double(n) / step) + 2)
        var p = phase
        while p < Double(n - 1) {
            let i = Int(p.rounded(.down))
            let f = Float(p - Double(i))
            let a = i < 0 ? lastY : y[i]
            let b = y[i + 1]
            out.append(a + (b - a) * f)
            p += step
        }
        phase = p - Double(n)
        lastY = y[n - 1]
        return out
    }
}

/// Odbiornik FT8/FT4: dźwięk z radia → 12 kHz → bufor z czasem UTC każdej próbki → dekodowanie po każdym cyklu.
/// Liczy też wodospad. Pracuje na własnych kolejkach; wyniki oddaje przez wywołania zwrotne.
final class FT8Receiver: @unchecked Sendable {
    // MARK: Ustawienia (zmieniane z wątku głównego, czytane na kolejce)
    private let lock = NSLock()
    private var _mode: FTMode = .ft8
    private var _depth = 2
    private var _enabled = false
    private var _waterfallWanted = false
    private var _suppressedSlot: Double = -1
    private var _myCall = ""

    var onDecodes: (@Sendable (_ slot: Date, _ decodes: [FTRawDecode], _ seconds: Double) -> Void)?
    var onWaterfall: (@Sendable (FTWaterfallFrame) -> Void)?
    /// Brak dźwięku albo jego przerwa - do komunikatu w zakładce.
    var onAudioState: (@Sendable (_ receiving: Bool) -> Void)?

    func configure(mode: FTMode, depth: Int, enabled: Bool, myCall: String) {
        lock.lock()
        let modeChanged = mode != _mode
        _mode = mode; _depth = depth; _enabled = enabled; _myCall = myCall
        lock.unlock()
        if modeChanged { queue.async { self.lastDecodedSlot = -1 } }
    }

    func setWaterfallWanted(_ wanted: Bool) {
        lock.lock(); _waterfallWanted = wanted; lock.unlock()
    }

    /// Cykl, w którym nadajemy - nie dekodujemy własnego sygnału.
    func suppress(slotStart: Double) {
        lock.lock(); _suppressedSlot = slotStart; lock.unlock()
    }

    private var settings: (mode: FTMode, depth: Int, enabled: Bool, waterfall: Bool, suppressed: Double, myCall: String) {
        lock.lock(); defer { lock.unlock() }
        return (_mode, _depth, _enabled, _waterfallWanted, _suppressedSlot, _myCall)
    }

    // MARK: Stan kolejki odbioru
    private let queue = DispatchQueue(label: "ft710.ft8.rx", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "ft710.ft8.decode", qos: .userInitiated)
    private let resampler = Resampler12k()
    private var samples: [Float] = []            // 12 kHz
    private var firstIndex: Int64 = 0            // indeks bezwzględny samples[0]
    private var totalOut: Int64 = 0              // liczba wszystkich próbek 12 kHz
    private var anchor: Double?                  // czas UNIX (s) próbki o indeksie 0
    private var lastChunkTime = 0.0
    private var lastDecodedSlot: Double = -1
    private var timer: DispatchSourceTimer?
    private var decoding = false
    private static let keepSeconds = 40.0

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        setupWaterfall()
    }

    deinit { timer?.cancel() }

    /// Wywoływane z wątku audio (sampleTap).
    func append(_ chunk: [Float], sampleRate: Double) {
        let now = Date().timeIntervalSince1970
        queue.async { self.ingest(chunk, rate: sampleRate, now: now) }
    }

    private func ingest(_ chunk: [Float], rate: Double, now: Double) {
        guard settings.enabled else { return }
        let out = resampler.process(chunk, rate: rate)
        guard !out.isEmpty else { return }
        samples.append(contentsOf: out)
        totalOut += Int64(out.count)
        // Czas próbki 0: ostatnia próbka porcji przyszła „teraz”. Opóźnienia dostarczenia są zawsze dodatnie,
        // więc śledzimy najwcześniejsze oszacowanie, z bardzo powolnym powrotem (dryft zegara karty dźwiękowej).
        let estimate = now - Double(totalOut) / Resampler12k.outputRate
        if let a = anchor, abs(estimate - a) < 0.5, now - lastChunkTime < 1 {
            anchor = estimate < a ? estimate : a + (estimate - a) * 0.002
        } else {
            // początek albo przerwa w dźwięku - stary bufor nie pasuje już do zegara
            anchor = estimate
            firstIndex = totalOut - Int64(out.count)
            samples = out
            onAudioState?(true)
        }
        lastChunkTime = now
        let excess = samples.count - Int(Self.keepSeconds * Resampler12k.outputRate)
        if excess > 0 {
            samples.removeFirst(excess)
            firstIndex += Int64(excess)
        }
        if settings.waterfall { waterfallIngest(out, endIndex: totalOut) }
    }

    // MARK: Dekodowanie po każdym cyklu

    private func tick() {
        let s = settings
        guard s.enabled else { return }
        let now = Date().timeIntervalSince1970
        if lastChunkTime > 0, now - lastChunkTime > 2 {
            lastChunkTime = 0
            onAudioState?(false)
        }
        let period = s.mode.period
        let slotStart = (now / period).rounded(.down) * period
        guard now - slotStart >= s.mode.decodeAt, slotStart != lastDecodedSlot, !decoding else { return }
        lastDecodedSlot = slotStart
        guard slotStart != s.suppressed, let anchor else { return }

        // Próbki od początku cyklu; brakujące (początek nagrania, jeszcze nie odebrane) = cisza.
        let count = Int(period * Resampler12k.outputRate)
        let startIndex = Int64(((slotStart - anchor) * Resampler12k.outputRate).rounded())
        var slot = [Float](repeating: 0, count: count)
        var have = 0
        for j in 0..<count {
            let idx = startIndex + Int64(j) - firstIndex
            if idx >= 0, idx < Int64(samples.count) { slot[j] = samples[Int(idx)]; have += 1 }
        }
        // Za mało dźwięku z tego cyklu (np. odsłuch włączony w połowie) - sygnały i tak byłyby urwane.
        guard Double(have) >= 0.6 * Double(count) else { return }

        decoding = true
        let audio = slot                                   // niezmienna kopia dla innej kolejki
        let mode = s.mode, depth = s.depth, myCall = s.myCall
        let slotDate = Date(timeIntervalSince1970: slotStart)
        decodeQueue.async { [weak self] in
            let started = Date()
            let found = FT8Receiver.decode(audio, mode: mode, depth: depth, myCall: myCall, slot: slotDate)
            let seconds = Date().timeIntervalSince(started)
            self?.queue.async { self?.decoding = false }
            self?.onDecodes?(slotDate, found, seconds)
        }
    }

    /// Wywołanie dekodera C (zawsze na decodeQueue - ftxw nie jest wielowątkowy).
    private static func decode(_ audio: [Float], mode: FTMode, depth: Int, myCall: String, slot: Date) -> [FTRawDecode] {
        if !myCall.isEmpty { ftxw_remember_call(myCall) }      // <...> z własnym znakiem rozwija się w pełny znak
        var results = [ftxw_result_t](repeating: ftxw_result_t(), count: 200)
        let n = audio.withUnsafeBufferPointer { a in
            results.withUnsafeMutableBufferPointer { r in
                ftxw_decode(a.baseAddress, Int32(a.count), mode.protocolCode, 100, 3100, Int32(depth),
                            r.baseAddress, Int32(r.count))
            }
        }
        ftxw_age_hashes()
        var list: [FTRawDecode] = []
        for i in 0..<max(0, Int(n)) {
            let r = results[i]
            let message = text(of: r)
            guard !message.isEmpty else { continue }
            list.append(FTRawDecode(slot: slot, mode: mode, snr: Int(r.snr.rounded()), dt: Double(r.dt),
                                    freq: Double(r.freq), text: message))
        }
        return list.sorted { $0.freq < $1.freq }
    }

    // MARK: Nadawanie - kodowanie i synteza (na kolejce dekodera: tablica skrótów znaków w C jest wspólna)

    /// Koduje tekst, odczytuje go z powrotem (echo = to, co zobaczy odbiorca) i - gdy sampleRate > 0 -
    /// syntetyzuje sygnał GFSK o tonie 0 na f0 Hz. Wynik oddaje na dowolnym wątku.
    func prepare(_ text: String, mode: FTMode, f0: Double, sampleRate: Double,
                 completion: @escaping @Sendable (FTTxAudio) -> Void) {
        decodeQueue.async {
            completion(FT8Receiver.encode(text, mode: mode, f0: f0, sampleRate: sampleRate))
        }
    }

    private static func encode(_ text: String, mode: FTMode, f0: Double, sampleRate: Double) -> FTTxAudio {
        var tones = [UInt8](repeating: 0, count: 105)
        var echo = [CChar](repeating: 0, count: 64)
        let n = tones.withUnsafeMutableBufferPointer { t in
            echo.withUnsafeMutableBufferPointer { e in
                ftxw_encode_echo(text, mode.protocolCode, t.baseAddress, e.baseAddress, Int32(e.count))
            }
        }
        let echoText = echo.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard n > 0 else { return FTTxAudio(code: Int(n), echo: echoText, samples: []) }
        guard sampleRate > 0 else { return FTTxAudio(code: Int(n), echo: echoText, samples: []) }
        let count = Int(ftxw_synth_length(n, mode.protocolCode, Int32(sampleRate)))
        var samples = [Float](repeating: 0, count: count)
        tones.withUnsafeBufferPointer { t in
            samples.withUnsafeMutableBufferPointer { s in
                ftxw_synth(t.baseAddress, n, mode.protocolCode, Float(f0), Int32(sampleRate), s.baseAddress)
            }
        }
        return FTTxAudio(code: Int(n), echo: echoText, samples: samples)
    }

    private static func text(of result: ftxw_result_t) -> String {
        var copy = result.text
        let size = MemoryLayout.size(ofValue: copy)
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Wodospad (styl WSJT-X: najnowszy wiersz u góry, linie i czas na początku cyklu)

    static let waterfallMaxHz = 3200.0
    private static let fftSize = 4096                     // 12 kHz / 4096 = 2,93 Hz na bin (jak WSJT-X)
    private static let hop = 1800                         // 0,15 s na wiersz (100 wierszy na cykl FT8)
    static let waterfallRows = 480                       // 72 s - prawie 5 cykli FT8 w miejscu skopu
    private var wfWidth = 0
    private var wfSetup: FFTSetup?
    private var wfWindow: [Float] = []
    private var wfFifo: [Float] = []
    private var wfFifoStart: Int64 = 0                    // indeks bezwzględny wfFifo[0]
    private var wfPixels: [UInt32] = []                   // waterfallRows × wfWidth, wiersz 0 = najnowszy
    private var wfBoundary: [String?] = []                // opis początku cyklu w danym wierszu
    private var wfFloor: Float?                           // poziom szumu (dB), wolno śledzony
    private var wfLastSlot: Double = -1
    private var palette: [UInt32] = []
    private var _brightness: Float = 0                    // przesunięcie w dB
    private var _contrast: Float = 40                     // zakres w dB od szumu do pełnej jasności

    func setWaterfallLevels(brightness: Double, contrast: Double) {
        lock.lock(); _brightness = Float(brightness); _contrast = Float(contrast); lock.unlock()
    }

    private func setupWaterfall() {
        let log2n = vDSP_Length(log2(Double(Self.fftSize)).rounded())
        wfSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        wfWindow = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&wfWindow, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
        wfWidth = Int(Self.waterfallMaxHz / (Resampler12k.outputRate / Double(Self.fftSize)))
        wfPixels = [UInt32](repeating: 0xFF000000, count: Self.waterfallRows * wfWidth)
        wfBoundary = [String?](repeating: nil, count: Self.waterfallRows)
        palette = Self.makePalette()
    }

    /// Paleta podobna do domyślnej w WSJT-X: czerń → granat → niebieski → turkus → żółty → czerwony.
    private static func makePalette() -> [UInt32] {
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.00, 0.00, 0.05), (0.25, 0.00, 0.05, 0.45), (0.45, 0.05, 0.35, 0.85),
            (0.62, 0.20, 0.80, 0.85), (0.78, 0.95, 0.90, 0.20), (0.92, 1.00, 0.45, 0.05), (1.00, 1.00, 0.95, 0.85)
        ]
        var result = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Double(i) / 255
            var k = 0
            while k < stops.count - 2, x > stops[k + 1].0 { k += 1 }
            let a = stops[k], b = stops[k + 1]
            let f = max(0, min(1, (x - a.0) / (b.0 - a.0)))
            let r = UInt32((a.1 + (b.1 - a.1) * f) * 255)
            let g = UInt32((a.2 + (b.2 - a.2) * f) * 255)
            let bl = UInt32((a.3 + (b.3 - a.3) * f) * 255)
            result[i] = 0xFF000000 | (bl << 16) | (g << 8) | r      // RGBA w pamięci (little-endian)
        }
        return result
    }

    private func waterfallIngest(_ chunk: [Float], endIndex: Int64) {
        if wfFifo.isEmpty || wfFifoStart + Int64(wfFifo.count) != endIndex - Int64(chunk.count) {
            wfFifo = []                                         // pierwsza porcja albo przerwa w dźwięku
            wfFifoStart = endIndex - Int64(chunk.count)
        }
        wfFifo.append(contentsOf: chunk)
        var consumed = 0
        while wfFifo.count - consumed >= Self.fftSize {
            let frame = Array(wfFifo[consumed..<(consumed + Self.fftSize)])
            // czas środka ramki (UTC) - do znaczników początku cyklu
            let center = wfFifoStart + Int64(consumed + Self.fftSize / 2)
            let t = (anchor ?? 0) + Double(center) / Resampler12k.outputRate
            consumed += Self.hop
            addWaterfallRow(frame, time: t)
        }
        if consumed > 0 {
            wfFifo.removeFirst(consumed)
            wfFifoStart += Int64(consumed)
        }
    }

    private func addWaterfallRow(_ frame: [Float], time: Double) {
        guard let setup = wfSetup else { return }
        let n = Self.fftSize, half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, wfWindow, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n)).rounded()), FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        let width = wfWidth
        var db = [Float](repeating: 0, count: width)
        for i in 0..<width { db[i] = 10 * log10(power[i] + 1e-20) }
        // poziom szumu = mediana wiersza (sygnały zajmują mały ułamek pasma), wolno śledzona
        let median = db.sorted()[width / 2]
        wfFloor = wfFloor.map { $0 + (median - $0) * 0.05 } ?? median
        lock.lock(); let brightness = _brightness, contrast = max(_contrast, 5); lock.unlock()
        let low = (wfFloor ?? median) - 3 - brightness
        var row = [UInt32](repeating: 0, count: width)
        for i in 0..<width {
            let v = (db[i] - low) / contrast
            row[i] = palette[Int(max(0, min(1, v)) * 255)]
        }
        // początek cyklu: linia i czas, jak w WSJT-X
        lock.lock(); let period = _mode.period; lock.unlock()
        let slot = (time / period).rounded(.down) * period
        var label: String?
        if slot != wfLastSlot {
            if wfLastSlot >= 0 {
                let f = DateFormatter()
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "HH:mm:ss"
                label = f.string(from: Date(timeIntervalSince1970: slot))
                for i in 0..<width { row[i] = 0xFFB0B0B0 }
            }
            wfLastSlot = slot
        }
        // przesunięcie w dół i nowy wiersz u góry
        let rows = Self.waterfallRows
        wfPixels.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            memmove(base + width, base, (rows - 1) * width * MemoryLayout<UInt32>.size)
            row.withUnsafeBufferPointer { r in base.update(from: r.baseAddress!, count: width) }
        }
        wfBoundary.removeLast()
        wfBoundary.insert(label, at: 0)
        publishWaterfall()
    }

    private func publishWaterfall() {
        guard let onWaterfall else { return }
        let width = wfWidth, rows = Self.waterfallRows
        let data = wfPixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        var marks: [FTWaterfallMark] = []
        for (i, label) in wfBoundary.enumerated() { if let label { marks.append(FTWaterfallMark(row: i, label: label)) } }
        onWaterfall(FTWaterfallFrame(image: image, maxHz: Self.waterfallMaxHz, boundaries: marks, rows: rows))
    }
}
