import Foundation
import AVFoundation
import CoreAudio

/// Audio stacji dla pracy zdalnej. Format sieciowy: PCM 16 bit, mono, 12 kHz (wystarcza na pasmo SSB ~3 kHz,
/// ok. 24 kB/s w każdą stronę - bez problemu przez Tailscale, także na LTE).
///
/// - RX: osobny silnik czyta wejście USB radia i przez AVAudioConverter (filtr + zmiana częstotliwości) daje 12 kHz.
///   macOS pozwala kilku silnikom czytać to samo urządzenie, więc lokalny odsłuch może działać równolegle.
/// - TX: dźwięk z przeglądarki trafia do wyjścia USB radia, ale TYLKO gdy bramka jest otwarta (zdalne PTT).
///   Krótkie wstępne buforowanie (80 ms) wygładza nierówne docieranie pakietów.
final class RemoteAudioStation: @unchecked Sendable {

    /// Kawałki audio RX: Int16 little-endian, mono, 12 kHz. Wywoływane z wątku audio.
    var onRXChunk: (@Sendable (Data) -> Void)?
    /// Błąd toru RX (zgłaszany raz na uruchomienie, żeby nie zalać logu).
    var onError: (@Sendable (String) -> Void)?
    private var errorReported = false

    private let networkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 12_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 12_000, channels: 1)!

    private var captureEngine: AVAudioEngine?
    private var playEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Korektor nadawania dla mikrofonu z przeglądarki (te same ustawienia co dla mikrofonu Maca).
    private var txEqualizer = TXEqualizer()

    private let lock = NSLock()
    private var gateOpen = false
    private var queuedFrames = 0
    private var playing = false
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var prebufferFrames = 0

    private static let prebufferTarget = 960          // 80 ms przy 12 kHz
    private static let maxQueuedFrames = 4_800        // 400 ms - powyżej gubimy, żeby nie rosło opóźnienie

    var rxRunning: Bool { captureEngine != nil }

    // Diagnostyka RX: liczba paczek i szczyt od ostatniego odczytu.
    private var rxChunkCount = 0
    private var rxPeak: Int16 = 0

    /// Zwraca (paczki, szczyt w dBFS albo nil dla ciszy) od poprzedniego wywołania i zeruje liczniki.
    func takeRXStats() -> (chunks: Int, peakDB: Int?) {
        lock.lock()
        let chunks = rxChunkCount
        let peak = rxPeak
        rxChunkCount = 0
        rxPeak = 0
        lock.unlock()
        guard peak > 0 else { return (chunks, nil) }
        return (chunks, Int((20 * log10(Double(peak) / 32_768)).rounded()))
    }
    var txRunning: Bool { playEngine != nil }

    // MARK: - RX

    func startRX(inputID: AudioDeviceID) throws {
        stopRX()
        guard inputID != 0 else { throw AudioError.noDevice }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.auAudioUnit.setDeviceID(inputID)
        let inputFormat = input.outputFormat(forBus: 0)
        // Kodek radia jest stereo. Bierzemy kanał 0 do bufora mono, a konwerter robi tylko
        // zmianę częstotliwości i format Int16 - bez polegania na miksowaniu kanałów przez konwerter.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: monoFormat, to: networkFormat) else {
            throw AudioError.badFormat
        }
        errorReported = false
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer, monoFormat: monoFormat, converter: converter)
        }
        engine.prepare()
        try engine.start()
        captureEngine = engine
    }

    func stopRX() {
        guard let engine = captureEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        captureEngine = nil
    }

    private func reportOnce(_ message: String) {
        guard !errorReported else { return }
        errorReported = true
        onError?(message)
    }

    private func convertAndSend(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat, converter: AVAudioConverter) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        guard let source = buffer.floatChannelData else {
            reportOnce(L("wejście audio nie jest w formacie float ({1})", buffer.format))
            return
        }
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let target = mono.floatChannelData else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        memcpy(target[0], source[0], frames * MemoryLayout<Float>.size)

        let ratio = networkFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: networkFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // Jeden bufor na wywołanie; .noDataNow zachowuje stan filtra konwertera między wywołaniami.
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        if status == .error {
            reportOnce(L("konwersja audio nie powiodła się: {1}", error?.localizedDescription ?? "?"))
            return
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData else { return }
        var peak: Int16 = 0
        for i in 0..<Int(output.frameLength) {
            let v = channel[0][i]
            let magnitude = v == Int16.min ? Int16.max : abs(v)
            if magnitude > peak { peak = magnitude }
        }
        lock.lock()
        rxChunkCount += 1
        if peak > rxPeak { rxPeak = peak }
        lock.unlock()
        onRXChunk?(Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }

    // MARK: - TX

    func startTX(outputID: AudioDeviceID) throws {
        stopTX()
        guard outputID != 0 else { throw AudioError.noDevice }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        try engine.outputNode.auAudioUnit.setDeviceID(outputID)
        engine.attach(node)
        // Mikser silnika sam przelicza 12 kHz mono na format urządzenia.
        engine.connect(node, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        try engine.start()
        node.play()
        playEngine = engine
        player = node
    }

    func stopTX() {
        setGate(false)
        player?.stop()
        playEngine?.stop()
        player = nil
        playEngine = nil
    }

    /// Otwiera/zamyka przepływ mikrofonu do radia. Zamknięcie natychmiast wyrzuca wszystko z kolejki.
    func setGate(_ open: Bool) {
        lock.lock()
        gateOpen = open
        prebuffer.removeAll()
        prebufferFrames = 0
        playing = false
        lock.unlock()
        if !open, let player {
            player.stop()       // usuwa zaplanowane bufory (wywołuje ich completion handlery)
            player.play()
            lock.lock(); queuedFrames = 0; lock.unlock()
        }
    }

    /// Dane z przeglądarki: Int16 little-endian, mono, 12 kHz.
    func playTX(_ data: Data) {
        guard let player, data.count >= 2 else { return }
        let frames = data.count / 2

        lock.lock()
        guard gateOpen, queuedFrames + prebufferFrames < Self.maxQueuedFrames else { lock.unlock(); return }
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let sample = Int16(bitPattern: UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8)
                out[i] = Float(sample) / 32_768
            }
        }
        if let gains = TXEqualizerConfig.shared.activeGains {
            txEqualizer.process(out, count: frames, gains: gains, sampleRate: playFormat.sampleRate)
        }

        lock.lock()
        guard gateOpen else { lock.unlock(); return }
        if !playing {
            prebuffer.append(buffer)
            prebufferFrames += frames
            guard prebufferFrames >= Self.prebufferTarget else { lock.unlock(); return }
            let ready = prebuffer
            prebuffer.removeAll()
            prebufferFrames = 0
            playing = true
            lock.unlock()
            ready.forEach { schedule($0, on: player) }
            return
        }
        lock.unlock()
        schedule(buffer, on: player)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        let frames = Int(buffer.frameLength)
        lock.lock(); queuedFrames += frames; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frames)
            if self.queuedFrames == 0 { self.playing = false }   // kolejka pusta - znów buforuj wstępnie
            self.lock.unlock()
        }
    }
}
