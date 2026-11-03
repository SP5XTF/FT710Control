import Foundation
import AVFoundation
import CoreAudio

enum AudioError: LocalizedError {
    case noDevice
    case badFormat

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return L("Nie wybrano urządzenia audio")
        case .badFormat:
            return L("Urządzenie wejściowe zgłasza nieprawidłowy format (sprawdź próbkowanie 48 kHz w aplikacji Konfiguracja Audio MIDI)")
        }
    }
}

/// Przenosi dźwięk z jednego urządzenia (wejście) na inne (wyjście).
/// AVAudioEngine na macOS używa jednego urządzenia na silnik, więc używamy dwóch:
/// jeden nagrywa (tap na inputNode), drugi odtwarza (AVAudioPlayerNode).
final class AudioBridge: @unchecked Sendable {
    private var captureEngine = AVAudioEngine()
    private var playEngine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var pending = 0

    private(set) var running = false
    /// Czas ostatniej próbki z wejścia - strażnik w AudioManager wykrywa zatrzymany tor (np. po uśpieniu monitora).
    private var lastInputTime: CFAbsoluteTime = 0
    /// Zmiana konfiguracji silnika audio (zniknęło urządzenie, np. głośniki monitora po uśpieniu) - silnik
    /// zatrzymuje się i wymaga ponownego uruchomienia; wywoływane na głównym wątku.
    var onConfigurationChange: (@Sendable () -> Void)?
    private var configObservers: [NSObjectProtocol] = []
    private var startedAt: CFAbsoluteTime = 0

    /// Oba silniki działają (po zmianie konfiguracji macOS zatrzymuje silnik - wtedy false).
    var enginesRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running && captureEngine.isRunning && playEngine.isRunning
    }

    /// Sekundy od ostatniej próbki z wejścia (nieskończoność - tor nie działa).
    var secondsSinceInput: Double {
        lock.lock(); defer { lock.unlock() }
        guard running, lastInputTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastInputTime
    }
    /// Gdy true, dźwięk nie jest przekazywany dalej (miernik poziomu nadal działa).
    var muted = false
    var onLevel: (@Sendable (Float) -> Void)?
    /// Próbki kanału 0 i częstotliwość próbkowania (wątek audio - tylko kopiuj i kolejkuj).
    var onSamples: (@Sendable ([Float], Double) -> Void)?
    /// Redukcja szumu odsłuchu (tylko ścieżka do słuchawek - widmo, SSTV i miernik dostają sygnał bez filtra).
    let denoiser = AudioDenoiser()
    /// Tor nadawania (mikrofon → radio): korektor nadawania (ustawienia wspólne, filtry - na wątku audio).
    var appliesTXEqualizer = false
    private var txEqualizer = TXEqualizer()
    var volume: Float = 0.8 {
        didSet { if running { playEngine.mainMixerNode.outputVolume = volume } }
    }

    func start(inputID: AudioDeviceID, outputID: AudioDeviceID) throws {
        stop()
        guard inputID != 0, outputID != 0 else { throw AudioError.noDevice }

        // nowe obiekty podmieniane pod blokadą - wątek audio czyta je też pod blokadą (bez wyścigu)
        let newCapture = AVAudioEngine(), newPlay = AVAudioEngine(), newPlayer = AVAudioPlayerNode()
        lock.lock()
        captureEngine = newCapture
        playEngine = newPlay
        player = newPlayer
        pending = 0
        lastInputTime = CFAbsoluteTimeGetCurrent()            // start - strażnik daje czas na pierwsze próbki
        startedAt = lastInputTime
        lock.unlock()
        for engine in [newCapture, newPlay] {
            configObservers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    // Sam start silnika (wskazanie urządzeń) wywołuje to powiadomienie - reakcja na nie dawała pętlę
                    // ponownych uruchomień co ok. 1 s (szarpanie skopu, opóźnienie 200 ms). Tylko gdy silnik
                    // naprawdę stanął i nie tuż po starcie.
                    guard CFAbsoluteTimeGetCurrent() - self.startedAt > 3, !self.enginesRunning else { return }
                    self.onConfigurationChange?()
                })
        }

        do {
            let input = captureEngine.inputNode
            try input.auAudioUnit.setDeviceID(inputID)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.badFormat }

            try playEngine.outputNode.auAudioUnit.setDeviceID(outputID)
            playEngine.attach(player)
            playEngine.connect(player, to: playEngine.mainMixerNode, format: format)
            playEngine.mainMixerNode.outputVolume = volume
            playEngine.prepare()
            try playEngine.start()
            player.play()
            lock.lock(); running = true; lock.unlock()

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.forward(buffer)
            }
            captureEngine.prepare()
            try captureEngine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for observer in configObservers { NotificationCenter.default.removeObserver(observer) }
        configObservers.removeAll()
        lock.lock()
        let wasRunning = running
        running = false                                       // wątek audio przestaje kolejkować od razu
        lock.unlock()
        guard wasRunning else { return }
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        player.stop()
        playEngine.stop()
    }

    // MARK: - Wątek audio

    private func forward(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        lock.lock(); lastInputTime = CFAbsoluteTimeGetCurrent(); lock.unlock()
        if let channel = buffer.floatChannelData?[0], frames > 0 {
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            onLevel?((sum / Float(frames)).squareRoot())
        }

        // Widmo liczymy także podczas wyciszenia (np. w trakcie nadawania).
        if let onSamples, let channel = buffer.floatChannelData?[0], frames > 0 {
            onSamples(Array(UnsafeBufferPointer(start: channel, count: frames)), buffer.format.sampleRate)
        }

        if muted { return }

        // własna, mocna referencja do odtwarzacza - nie zniknie w trakcie użycia, nawet gdy wątek główny
        // właśnie zatrzymuje albo podmienia tor
        lock.lock()
        let queued = pending, isRunning = running, player = self.player
        lock.unlock()
        guard isRunning else { return }
        if queued > 8 { return }   // różnica zegarów urządzeń: gubimy nadmiar zamiast narastać opóźnienie

        guard let copy = Self.copy(of: buffer) else { return }
        if let data = copy.floatChannelData, copy.frameLength > 0 {
            let count = Int(copy.frameLength)
            var processed = denoiser.process(data[0], count: count, sampleRate: copy.format.sampleRate)
            if appliesTXEqualizer, let gains = TXEqualizerConfig.shared.activeGains {
                txEqualizer.process(data[0], count: count, gains: gains, sampleRate: copy.format.sampleRate)
                processed = true
            }
            if processed {
                // mono - wynik kanału 0 do pozostałych kanałów
                for channel in 1..<max(Int(copy.format.channelCount), 1) {
                    data[channel].update(from: data[0], count: count)
                }
            }
        }
        lock.lock(); pending += 1; lock.unlock()
        player.scheduleBuffer(copy) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }

    private static func copy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !source.format.isInterleaved,
              let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength),
              let src = source.floatChannelData,
              let dst = destination.floatChannelData else { return nil }
        destination.frameLength = source.frameLength
        let bytes = Int(source.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(source.format.channelCount) {
            memcpy(dst[channel], src[channel], bytes)
        }
        return destination
    }
}
