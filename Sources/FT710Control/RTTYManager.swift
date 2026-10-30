import Foundation
import AVFoundation
import Combine
import AppKit

/// RTTY: dekoder (dźwięk z radia) i nadawanie AFSK przez dźwięk USB (radio w DATA-L).
@MainActor
final class RTTYManager: ObservableObject {
    /// Tekst wpisywany do nadania - w menedżerze, żeby przełączenie zakładki go nie kasowało.
    @Published var outgoing = ""
    // MARK: Odbiór
    @Published var decoderEnabled: Bool { didSet { save("decoder", decoderEnabled); decoder.setPaused(!decoderEnabled); updateTap() } }
    @Published var shift: Double { didSet { save("shift", shift); applySettings() } }
    @Published var baud: Double { didSet { save("baud", baud); applySettings() } }
    @Published var autoReverse: Bool { didSet { save("autoReverse", autoReverse); applySettings() } }
    @Published var reverse: Bool { didSet { save("reverse", reverse); applySettings() } }
    @Published var usos: Bool { didSet { save("usos", usos); applySettings() } }
    @Published var afc: Bool { didSet { save("afc", afc); applySettings() } }
    @Published private(set) var text = ""
    @Published private(set) var markHz = 2125.0
    @Published private(set) var spaceHz = 2295.0
    @Published private(set) var locked = false
    @Published private(set) var signal = 0.0

    // MARK: Nadawanie
    @Published var txLevel: Double { didSet { save("txLevel", txLevel) } }
    @Published var macros: [String] { didSet { UserDefaults.standard.set(macros, forKey: "rtty.macros") } }
    @Published private(set) var transmitting = false
    @Published private(set) var txProgress = 0.0
    @Published private(set) var txMessage: String?

    static let defaultMacros = ["CQ CQ CQ DE {CALL} {CALL} {CALL} PSE K", "{CALL}", "UR 599 599 ", "TU 73 DE {CALL} SK", "QRZ? DE {CALL} K"]
    static let shifts: [Double] = [170, 200, 425, 850]
    static let bauds: [Double] = [45.45, 50, 75]

    private let decoder = RTTYDecoder()
    private weak var cat: CATClient?
    private weak var audio: AudioManager?
    private weak var logbook: LogbookStore?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var txStarted = Date()
    private var txDuration = 1.0
    private var progressTimer: Timer?
    private var modeObserver: Any?
    private static let maxText = 8000

    /// Tony mark/space odwrócone, gdy radio jest w górnej wstędze (USB, DATA-U, RTTY-U) -
    /// wtedy mark (wyżej w częstotliwości radiowej) to wyższy ton audio.
    var effectiveReverse: Bool {
        guard autoReverse, let code = cat?.modeCode else { return reverse }
        return ["2", "C", "9"].contains(code)
    }

    init() {
        let d = UserDefaults.standard
        decoderEnabled = d.object(forKey: "rtty.decoder") as? Bool ?? true
        shift = d.object(forKey: "rtty.shift") as? Double ?? 170
        baud = d.object(forKey: "rtty.baud") as? Double ?? 45.45
        autoReverse = d.object(forKey: "rtty.autoReverse") as? Bool ?? true
        reverse = d.object(forKey: "rtty.reverse") as? Bool ?? false
        usos = d.object(forKey: "rtty.usos") as? Bool ?? true
        afc = d.object(forKey: "rtty.afc") as? Bool ?? true
        txLevel = d.object(forKey: "rtty.txLevel") as? Double ?? 0.5
        let saved = d.stringArray(forKey: "rtty.macros") ?? []
        macros = saved.count == 5 ? saved : Self.defaultMacros
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "rtty." + key) }

    func attach(audio: AudioManager, cat: CATClient, logbook: LogbookStore) {
        guard self.cat == nil else { return }
        self.cat = cat
        self.audio = audio
        self.logbook = logbook
        decoder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        decoder.setPaused(!decoderEnabled)
        applySettings()
        updateTap()
        // zmiana trybu radia (LSB/USB) - automatyczne odwrócenie tonów
        modeObserver = cat.$modeCode.sink { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
    }

    private func applySettings() {
        decoder.configure(RTTYSettings(shift: shift, baud: baud, reverse: effectiveReverse, usos: usos, afc: afc))
    }

    private func updateTap() {
        guard let audio else { return }
        if decoderEnabled {
            audio.sampleTap.set("rtty") { [decoder] samples, rate in decoder.append(samples, sampleRate: rate) }
        } else {
            audio.sampleTap.set("rtty", nil)
        }
    }

    private func handle(_ event: RTTYDecoder.Event) {
        switch event {
        case .text(let piece):
            text += piece
            if text.count > Self.maxText { text = String(text.suffix(Self.maxText)) }
        case .status(let m, let s, let isLocked, let ratio):
            if abs(m - markHz) > 0.5 { markHz = m }
            if abs(s - spaceHz) > 0.5 { spaceHz = s }
            if isLocked != locked { locked = isLocked }
            if abs(ratio - signal) > 0.5 { signal = ratio }
        }
    }

    func clearText() { text = "" }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Kliknięcie w widmo: wskazany ton to mark (przy odwróceniu - wyższy ton).
    func setMark(_ hz: Double) { decoder.setMark(hz) }

    // MARK: - Nadawanie (AFSK przez dźwięk USB)

    func expand(_ template: String) -> String {
        template.replacingOccurrences(of: "{CALL}", with: logbook?.myCall.uppercased() ?? "").uppercased()
    }

    /// Ustawia radio w DATA-L (zalecany tryb AFSK RTTY).
    func setRadioDataL() { cat?.setMode("8") }

    func transmit(_ raw: String, armed: Bool) {
        guard let cat, let audio else { return }
        let message = expand(raw).trimmingCharacters(in: .whitespaces)
        txMessage = nil
        guard !message.isEmpty, !transmitting else { return }
        guard armed, cat.isConnected else {
            txMessage = L("Nadawanie wymaga połączenia z radiem i zaznaczenia „Odblokuj TX”.")
            return
        }
        guard audio.radioOut != 0 else {
            txMessage = L("Wybierz w zakładce AUDIO urządzenie „Do radia (TX)”.")
            return
        }
        let duration = RTTYEncoder.duration(of: message, baud: baud)
        guard duration + 1 <= cat.txTimeout else {
            txMessage = L("Tekst trwa {1} s, a limit nadawania to {2} s - skróć tekst albo zwiększ limit.",
                          Int(duration.rounded()), Int(cat.txTimeout))
            return
        }
        let rate = 48_000.0
        // nadajemy na tonach, na których odbieramy (mark z dekodera) - stacja po drugiej stronie trafi w nas
        let samples = RTTYEncoder.modulate(message, sampleRate: rate, mark: effectiveReverse ? spaceHz : markHz,
                                           shift: shift, baud: baud, reverse: effectiveReverse,
                                           amplitude: Float(txLevel))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(audio.radioOut)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            txMessage = L("Audio TX: {1}", error.localizedDescription)
            return
        }
        self.engine = engine
        self.player = player
        decoder.setPaused(true)                                     // nie dekodujemy własnego nadawania
        transmitting = true
        txProgress = 0
        txDuration = Double(samples.count) / rate
        cat.ptt(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.transmitting, let player = self.player else { return }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self?.finishTX(message: L("Nadano: {1}", message))
                }
            }
            player.play()
            self.txStarted = Date()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickTX() }
            }
        }
    }

    private func tickTX() {
        guard transmitting else { return }
        let elapsed = Date().timeIntervalSince(txStarted)
        txProgress = min(elapsed / max(txDuration, 0.1), 1)
        if elapsed > 2, let cat, !cat.transmitting || !cat.isConnected {
            finishTX(message: L("Nadawanie przerwane - radio nie nadaje (limit czasu albo rozłączenie)."))
        }
    }

    func stopTX() {
        finishTX(message: L("Nadawanie zatrzymane."))
    }

    private func finishTX(message: String) {
        guard transmitting else { return }
        transmitting = false
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        cat?.ptt(false)
        txMessage = message
        txProgress = 0
        decoder.setPaused(!decoderEnabled)
    }
}

@MainActor
final class RTTYHolder: ObservableObject {
    let manager = RTTYManager()
}
