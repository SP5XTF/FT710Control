import Foundation

/// Varicode PSK31 (G3PLX) - znaki ASCII 0…127. Kody zaczynają i kończą się „1”, nie zawierają „00”;
/// między znakami nadaje się „00”.
enum Varicode {
    static let codes: [String] = [
        "1010101011", "1011011011", "1011101101", "1101110111", "1011101011", "1101011111", "1011101111", "1011111101",
        "1011111111", "11101111", "11101", "1101101111", "1011011101", "11111", "1101110101", "1110101011", "1011110111",
        "1011110101", "1110101101", "1110101111", "1101011011", "1101101011", "1101101101", "1101010111", "1101111011",
        "1101111101", "1110110111", "1101010101", "1101011101", "1110111011", "1011111011", "1101111111", "1", "111111111",
        "101011111", "111110101", "111011011", "1011010101", "1010111011", "101111111", "11111011", "11110111", "101101111",
        "111011111", "1110101", "110101", "1010111", "110101111", "10110111", "10111101", "11101101", "11111111", "101110111",
        "101011011", "101101011", "110101101", "110101011", "110110111", "11110101", "110111101", "111101101", "1010101",
        "111010111", "1010101111", "1010111101", "1111101", "11101011", "10101101", "10110101", "1110111", "11011011",
        "11111101", "101010101", "1111111", "111111101", "101111101", "11010111", "10111011", "11011101", "10101011",
        "11010101", "111011101", "10101111", "1101111", "1101101", "101010111", "110110101", "101011101", "101110101",
        "101111011", "1010101101", "111110111", "111101111", "111111011", "1010111111", "101101101", "1011011111", "1011",
        "1011111", "101111", "101101", "11", "111101", "1011011", "101011", "1101", "111101011", "10111111", "11011",
        "111011", "1111", "111", "111111", "110111111", "10101", "10111", "101", "110111", "1111011", "1101011", "11011111",
        "1011101", "111010101", "1010110111", "110111011", "1010110101", "1011010111", "1110110101"
    ]
    static let decoding: [String: Character] = {
        var table: [String: Character] = [:]
        for (i, code) in codes.enumerated() { table[code] = Character(UnicodeScalar(UInt8(i))) }
        return table
    }()

    /// Bity do nadania: preambuła (zmiany fazy), znaki z „00”, postambuła (nośna bez zmian).
    static func bits(for text: String) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 32)
        for scalar in text.unicodeScalars where scalar.value < 128 {
            bits += codes[Int(scalar.value)].map { $0 == "1" ? 1 : 0 }
            bits += [0, 0]
        }
        bits += [UInt8](repeating: 1, count: 32)
        return bits
    }
}

/// Modulator BPSK (PSK31: 31,25 Bd, PSK63: 62,5 Bd). Bit 0 = zmiana fazy z łagodnym przejściem (obwiednia
/// cosinusowa - wąskie widmo), bit 1 = faza bez zmian.
enum PSKModulator {
    static func duration(of text: String, baud: Double) -> Double {
        Double(Varicode.bits(for: text).count) / baud
    }

    static func modulate(_ text: String, sampleRate: Double, carrier: Double, baud: Double, amplitude: Float) -> [Float] {
        let bits = Varicode.bits(for: text)
        let perSymbol = sampleRate / baud
        var out: [Float] = []
        out.reserveCapacity(Int(Double(bits.count) * perSymbol) + 1)
        var sign: Double = 1
        var position = 0.0
        var n = 0
        let omega = 2 * Double.pi * carrier / sampleRate
        for bit in bits {
            let previous = sign
            if bit == 0 { sign = -sign }
            position += perSymbol
            let end = Int(position.rounded())
            let length = max(end - n, 1)
            for k in 0..<(end - n) {
                let envelope = previous == sign ? sign : previous * cos(Double.pi * Double(k) / Double(length))
                out.append(amplitude * Float(envelope * sin(omega * Double(n + k))))
            }
            n = end
        }
        return out
    }
}

/// Dekoder PSK31/PSK63: mieszanie do pasma podstawowego, decymacja do 16 próbek na symbol, filtr dolnoprzepustowy,
/// synchronizacja bitowa (jak gmfsk/fldigi), detekcja różnicowa, AFC z kwadratu sygnału (zakres ±4·baud…),
/// Varicode. Blokada szumu: tekst tylko przy zgodnej fazie (sygnał, nie szum). Działa na własnej kolejce.
final class PSKDecoder: @unchecked Sendable {
    enum Event: Sendable {
        case text(String)
        case status(carrier: Double, quality: Double)
    }

    var onEvent: (@Sendable (Event) -> Void)?
    private let queue = DispatchQueue(label: "ft710.psk.decoder", qos: .userInitiated)

    private var baud = 31.25
    private var carrier = 1000.0
    private var afcEnabled = true
    private var squelch = 0.5
    private var paused = false

    private var sampleRate = 0.0
    private var phase = 0.0
    private var accI = 0.0, accQ = 0.0, accCount = 0
    private var timeAcc = 0.0
    private var taps: [Double] = []
    private var bufI: [Double] = [], bufQ: [Double] = []
    private var bufPos = 0
    private var sync = [Double](repeating: 0, count: 16)
    private var bitClock = 0.0
    private var prevI = 0.0, prevQ = 0.0, havePrev = false
    private var prevSqI = 0.0, prevSqQ = 0.0
    private var afcI = 0.0, afcQ = 0.0
    private var zeros = 0
    private var code = ""
    private var pending = ""
    private var symbolsSinceStatus = 0
    /// Tryb testowy: tekst zbierany tutaj (na kolejce dekodera) zamiast wysyłania zdarzeń.
    private var collected: String?
    private var quality = 0.0
    /// Blokada: liczba kolejnych symboli z jakością ≥ progu; znaki sprzed otwarcia odłożone (symbol, w którym je
    /// zdekodowano) - wypisane, gdy blokada otworzy się w ciągu ok. 1 s (sygnał), inaczej przepadają (szum).
    private var symbolsAbove = 0
    private var symbolCount = 0
    private var heldBack: [(character: Character, symbol: Int)] = []

    func configure(baud newBaud: Double) {
        queue.async { [self] in baud = newBaud; reset() }
    }

    /// Kliknięcie w widmo / ręczna częstotliwość - AFC zaczyna od nowa.
    func setCarrier(_ hz: Double) {
        queue.async { [self] in carrier = hz; reset() }
    }

    func setAFC(_ on: Bool) { queue.async { [self] in afcEnabled = on } }
    func setSquelch(_ value: Double) { queue.async { [self] in squelch = value } }
    func setPaused(_ value: Bool) { queue.async { [self] in paused = value; if value { reset() } } }

    func append(_ samples: [Float], sampleRate rate: Double) {
        queue.async { [self] in
            guard !paused else { return }
            if rate != sampleRate { sampleRate = rate; reset() }
            process(samples)
        }
    }

    /// Do testów: przetworzenie od razu, zwraca odebrany tekst (zbierany na kolejce dekodera - bez współdzielonych
    /// zmiennych między wątkami).
    func decodeSynchronously(_ samples: [Float], sampleRate rate: Double) -> String {
        queue.sync {
            collected = ""
            sampleRate = rate
            reset()
            process(samples)
            flush()
            let text = collected ?? ""
            collected = nil
            return text
        }
    }

    private func reset() {
        phase = 0; accI = 0; accQ = 0; accCount = 0; timeAcc = 0
        // filtr dolnoprzepustowy (Hann, 65 współczynników) przy 16 próbkach/symbol: odcięcie = baud
        let n = 65
        let cutoff = 1.0 / 16.0
        taps = (0..<n).map { i in
            let x = Double(i) - Double(n - 1) / 2
            let sinc = x == 0 ? 1.0 : sin(2 * Double.pi * cutoff * x) / (2 * Double.pi * cutoff * x)
            return sinc * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        bufI = [Double](repeating: 0, count: n); bufQ = bufI; bufPos = 0
        sync = [Double](repeating: 0, count: 16); bitClock = 0
        havePrev = false; prevSqI = 0; prevSqQ = 0; afcI = 0; afcQ = 0
        zeros = 0; code = ""; quality = 0
        symbolsAbove = 0; symbolCount = 0; heldBack = []
    }

    private func process(_ samples: [Float]) {
        guard sampleRate > 0 else { return }
        let step = sampleRate / (16 * baud)
        let twoPi = 2 * Double.pi
        for sample in samples {
            let s = Double(sample)
            accI += s * cos(phase)
            accQ -= s * sin(phase)
            accCount += 1
            phase += twoPi * carrier / sampleRate
            if phase > twoPi { phase -= twoPi }
            timeAcc += 1
            if timeAcc >= step {
                timeAcc -= step
                decimated(accI / Double(accCount), accQ / Double(accCount))
                accI = 0; accQ = 0; accCount = 0
            }
        }
        flush()
    }

    private func decimated(_ i: Double, _ q: Double) {
        let n = taps.count
        bufI[bufPos] = i; bufQ[bufPos] = q
        var yi = 0.0, yq = 0.0
        for k in 0..<n {
            let index = (bufPos - k + n) % n
            yi += taps[k] * bufI[index]; yq += taps[k] * bufQ[index]
        }
        bufPos = (bufPos + 1) % n
        // AFC: kwadrat sygnału BPSK usuwa modulację - przesunięcie fazy między próbkami
        let sqI = yi * yi - yq * yq, sqQ = 2 * yi * yq
        afcI = 0.99 * afcI + (sqI * prevSqI + sqQ * prevSqQ)
        afcQ = 0.99 * afcQ + (sqQ * prevSqI - sqI * prevSqQ)
        prevSqI = sqI; prevSqQ = sqQ
        // synchronizacja bitowa: energia w 16 przedziałach symbolu, zegar przesuwany płynnie
        let amplitude = (yi * yi + yq * yq).squareRoot()
        let slot = Int(bitClock) & 15
        sync[slot] = 0.8 * sync[slot] + 0.2 * amplitude
        var difference = 0.0, total = 0.0
        for k in 0..<8 { difference += sync[k] - sync[k + 8]; total += sync[k] + sync[k + 8] }
        if total > 0 { bitClock -= (difference / total) / 5 }
        bitClock += 1
        if bitClock < 0 { bitClock += 16 }
        if bitClock >= 16 {
            bitClock -= 16
            symbol(yi, yq)
        }
    }

    private func symbol(_ i: Double, _ q: Double) {
        defer { prevI = i; prevQ = q; havePrev = true }
        guard havePrev else { return }
        let dotI = i * prevI + q * prevQ                     // d = y · conj(prev)
        let cross = q * prevI - i * prevQ
        let bit = dotI > 0 ? 1 : 0
        if afcEnabled, afcI != 0 || afcQ != 0 {
            let errorHz = atan2(afcQ, afcI) / 2 * (16 * baud) / (2 * Double.pi)
            carrier += (abs(errorHz) > 5 ? 0.2 : 0.05) * errorHz      // szybkie łapanie, potem łagodnie
        }
        // jakość = zgodność fazy (jak w fldigi): cos(2Δφ) - sygnał BPSK ma Δφ ≈ 0° albo 180° (blisko 1),
        // szum przypadkowe (ok. 0). Kalibracja: szum zwykle ≤ 0,3 (maks. 0,57 w 360 s), sygnał −5 dB ≥ 0,6 - próg 0,5.
        let power = dotI * dotI + cross * cross
        let consistency = power > 0 ? (dotI * dotI - cross * cross) / power : 0
        // uśrednianie ze stałą czasową ok. 0,32 s niezależnie od prędkości (PSK63 - dwa razy więcej symboli/s;
        // przy uśrednianiu „po 10 symbolach” szum PSK63 przekraczał próg - test: 6 znaków w 240 s samego szumu)
        let alpha = 0.1 * 31.25 / baud
        quality = (1 - alpha) * quality + alpha * consistency
        symbolsAbove = quality >= squelch ? symbolsAbove + 1 : 0
        symbolCount += 1
        receive(bit)
        symbolsSinceStatus += 1
        if symbolsSinceStatus >= Int(baud / 4) {               // ok. 4 razy na sekundę
            symbolsSinceStatus = 0
            onEvent?(.status(carrier: carrier, quality: quality))
        }
    }

    private func receive(_ bit: Int) {
        if bit == 0 {
            zeros += 1
            if zeros == 2, !code.isEmpty {
                if let character = Varicode.decoding[code] {
                    // blokada otwarta, gdy jakość ≥ progu przez 0,5 s - szum utrzymywał jakość powyżej 0,45 najdłużej
                    // 5 symboli w 360 s (0,25 s dawało za mały zapas: pojedyncze znaki z szumu w teście)
                    if symbolsAbove >= Int((0.5 * baud).rounded()) {
                        pending.append(contentsOf: heldBack.map(\.character))
                        pending.append(character)
                        heldBack.removeAll()
                    } else {
                        heldBack = heldBack.filter { symbolCount - $0.symbol < Int(baud) } + [(character, symbolCount)]
                    }
                }
                code = ""
            }
        } else {
            if zeros == 1 { code += "0" }
            zeros = 0
            code += "1"
            if code.count > 12 { code = "" }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        if collected != nil { collected? += text } else { onEvent?(.text(text)) }
    }
}
