import Foundation
import Accelerate

/// Widmo dźwięku odbiornika: FFT z oknem Hanna i 50% nakładaniem ramek.
/// Liczone na własnej kolejce, żeby nie obciążać wątku audio.
///
/// UWAGA: to jest widmo pasma audio (ok. 0–3 kHz wokół częstotliwości strojenia),
/// a nie skop RF radia. Prawdziwy skop FT-710 idzie osobnym interfejsem USB (FT4222).
final class SpectrumAnalyzer: @unchecked Sendable {
    let fftSize: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let reference: Float      // moc sinusa o pełnej skali -> 0 dBFS
    private let queue = DispatchQueue(label: "ft710.spectrum", qos: .userInitiated)

    private var fifo: [Float] = []
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var db: [Float]

    /// Wywoływane z kolejki analizatora: dBFS dla binów 0..<fftSize/2 oraz częstotliwość próbkowania.
    var onSpectrum: (@Sendable ([Float], Double) -> Void)?

    init(fftSize: Int = 4096) {
        precondition(fftSize >= 256 && fftSize & (fftSize - 1) == 0, "fftSize musi być potęgą 2")
        self.fftSize = fftSize
        half = fftSize / 2
        log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup nie powiodło się")
        }
        setup = fftSetup

        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        window = w

        // vDSP_fft_zrip zwraca wartości 2x większe niż klasyczna DFT, więc sinus
        // o amplitudzie 1 daje w swoim binie |X| = N * (średnia wartość okna).
        let coherentGain = w.reduce(0, +) / Float(fftSize)
        let peak = Float(fftSize) * coherentGain
        reference = peak * peak

        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        db = [Float](repeating: -200, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func reset() {
        queue.async { [self] in fifo.removeAll(keepingCapacity: true) }
    }

    /// Dokłada próbki (mono). Bezpieczne do wywołania z wątku audio - tylko kopiuje i kolejkuje.
    func append(_ samples: [Float], sampleRate: Double) {
        queue.async { [self] in
            fifo.append(contentsOf: samples)
            // Jeśli analiza nie nadąża, gubimy najstarsze próbki zamiast narastać opóźnienie.
            let maxBacklog = fftSize * 4
            if fifo.count > maxBacklog { fifo.removeFirst(fifo.count - maxBacklog) }
            while fifo.count >= fftSize {
                process(sampleRate: sampleRate)
                fifo.removeFirst(half)
            }
        }
    }

    // MARK: - Kolejka analizatora

    private func process(sampleRate: Double) {
        let n = vDSP_Length(fftSize)
        let h = vDSP_Length(half)

        vDSP_vmul(fifo, 1, window, 1, &windowed, 1, n)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, h)
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0   // imagp[0] zawiera składową Nyquista - nie mieszamy jej ze składową stałą
                vDSP_zvmags(&split, 1, &power, 1, h)
            }
        }

        var epsilon: Float = 1e-20   // brak log(0) dla ciszy
        power.withUnsafeMutableBufferPointer { p in
            vDSP_vsadd(p.baseAddress!, 1, &epsilon, p.baseAddress!, 1, h)
        }
        var ref = reference
        vDSP_vdbcon(power, 1, &ref, &db, 1, h, 0)   // 0 = moc: 10·log10(p / ref)

        onSpectrum?(db, sampleRate)
    }
}
