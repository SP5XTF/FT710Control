import Foundation

/// Nadajnik SSTV: obraz RGB (wiersze, 3 bajty na piksel) → próbki audio z ciągłą fazą.
/// Częstotliwości: 1200 Hz synchronizacja, 1500 Hz czerń … 2300 Hz biel, nagłówek VIS 1900/1200/1100/1300 Hz.
enum SSTVEncoder {
    /// Generator tonów: czas liczony narastająco w ms, więc zaokrąglenia do próbek się nie kumulują.
    private struct ToneWriter {
        let rate: Double
        var phase = 0.0
        var elapsedMs = 0.0
        var samples: [Float] = []
        let amplitude: Float

        init(rate: Double, capacity: Int, amplitude: Float) {
            self.rate = rate
            self.amplitude = amplitude
            samples.reserveCapacity(capacity)
        }

        private mutating func sampleCount(for ms: Double) -> Int {
            let start = Int((elapsedMs * rate / 1000).rounded())
            elapsedMs += ms
            return Int((elapsedMs * rate / 1000).rounded()) - start
        }

        mutating func tone(_ hz: Double, _ ms: Double) {
            let n = sampleCount(for: ms)
            guard n > 0 else { return }
            let step = 2 * Double.pi * hz / rate
            for _ in 0..<n {
                phase += step
                samples.append(amplitude * Float(sin(phase)))
            }
            phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        }

        /// Linia pikseli 0…255 rozciągnięta równo na `ms`.
        mutating func scan(_ values: [Double], _ ms: Double) {
            let n = sampleCount(for: ms)
            guard n > 0, !values.isEmpty else { return }
            for i in 0..<n {
                let index = min(i * values.count / n, values.count - 1)
                let hz = 1500 + values[index] * 800 / 255
                phase += 2 * Double.pi * hz / rate
                samples.append(amplitude * Float(sin(phase)))
            }
            phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    /// `rgb`: width × height × 3 bajtów (wiersz po wierszu) w rozdzielczości trybu.
    static func encode(rgb: [UInt8], mode: SSTVMode, sampleRate: Double, amplitude: Float = 0.7) -> [Float] {
        let w = mode.width, h = mode.height
        precondition(rgb.count == w * h * 3, "Obraz musi mieć rozdzielczość trybu")
        var t = ToneWriter(rate: sampleRate, capacity: Int(mode.duration * sampleRate) + 1024, amplitude: amplitude)

        // Nagłówek VIS: leader, przerwa, leader, bit startu, 7 bitów (od najmłodszego), parzystość, bit stopu.
        t.tone(1900, 300); t.tone(1200, 10); t.tone(1900, 300); t.tone(1200, 30)
        var parity = 0
        for bit in 0..<7 {
            let value = (mode.vis >> bit) & 1
            parity ^= value
            t.tone(value == 1 ? 1100 : 1300, 30)
        }
        t.tone(parity == 1 ? 1100 : 1300, 30)
        t.tone(1200, 30)

        func channel(_ row: Int, _ c: Int) -> [Double] {
            (0..<w).map { Double(rgb[(row * w + $0) * 3 + c]) }
        }
        func yuvRow(_ row: Int) -> (y: [Double], u: [Double], v: [Double]) {
            var y = [Double](), u = [Double](), v = [Double]()
            y.reserveCapacity(w); u.reserveCapacity(w); v.reserveCapacity(w)
            for x in 0..<w {
                let i = (row * w + x) * 3
                let c = SSTVColor.yuv(r: Double(rgb[i]), g: Double(rgb[i + 1]), b: Double(rgb[i + 2]))
                y.append(c.y); u.append(c.u); v.append(c.v)
            }
            return (y, u, v)
        }
        func average(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { ($0 + $1) / 2 } }

        switch mode.kind {
        case .martin:
            for row in 0..<h {
                t.tone(1200, mode.sync); t.tone(1500, mode.porch)
                for c in [1, 2, 0] {                       // G, B, R
                    t.scan(channel(row, c), mode.scan); t.tone(1500, mode.sep)
                }
            }
        case .scottie:
            t.tone(1200, mode.sync)                        // synchronizacja startowa
            for row in 0..<h {
                t.tone(1500, mode.sep); t.scan(channel(row, 1), mode.scan)
                t.tone(1500, mode.sep); t.scan(channel(row, 2), mode.scan)
                t.tone(1200, mode.sync); t.tone(1500, mode.porch); t.scan(channel(row, 0), mode.scan)
            }
        case .robot36:
            for row in 0..<h {
                let pair = (row / 2) * 2
                let first = yuvRow(pair)
                let second = yuvRow(min(pair + 1, h - 1))
                let current = row == pair ? first : second
                t.tone(1200, mode.sync); t.tone(1500, mode.porch); t.scan(current.y, mode.scan)
                let even = row % 2 == 0
                // linia parzysta: R-Y (V), nieparzysta: B-Y (U); znacznik w separatorze 1500 / 2300 Hz
                t.tone(even ? 1500 : 2300, mode.sep); t.tone(1900, 1.5)
                t.scan(even ? average(first.v, second.v) : average(first.u, second.u), 44.0)
            }
        case .pd:
            for row in stride(from: 0, to: h, by: 2) {
                let a = yuvRow(row), b = yuvRow(row + 1)
                t.tone(1200, mode.sync); t.tone(1500, mode.porch)
                t.scan(a.y, mode.scan)
                t.scan(average(a.v, b.v), mode.scan)
                t.scan(average(a.u, b.u), mode.scan)
                t.scan(b.y, mode.scan)
            }
        }
        return t.samples
    }
}
