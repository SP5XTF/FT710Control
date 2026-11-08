import SwiftUI
import AVFoundation
import AppKit
import Combine

/// PSK31 / PSK63: dekoder na dźwięku z radia (wspólny „kran” próbek), nadawanie BPSK przez USB z PTT (jak RTTY).
@MainActor
final class PSKManager: ObservableObject {
    @Published var outgoing = ""
    @Published var decoderEnabled: Bool { didSet { save("decoder", decoderEnabled); decoder.setPaused(!decoderEnabled); updateTap() } }
    /// 31,25 (PSK31) albo 62,5 (PSK63).
    @Published var baud: Double { didSet { save("baud", baud); decoder.configure(baud: baud) } }
    @Published var afc: Bool { didSet { save("afc", afc); decoder.setAFC(afc) } }
    /// Blokada szumu: minimalna zgodność fazy (0…1) - poniżej tekst nie jest wypisywany. Kalibracja: szum ≤ 0,3.
    @Published var squelch: Double { didSet { save("squelch", squelch); decoder.setSquelch(squelch) } }
    @Published var txLevel: Double { didSet { save("txLevel", txLevel) } }
    @Published var macros: [String] { didSet { UserDefaults.standard.set(macros, forKey: "psk.macros") } }
    @Published private(set) var text = ""
    /// Częstotliwość odbioru (ton audio, Hz) - śledzona przez AFC.
    @Published private(set) var carrier: Double
    @Published private(set) var quality = 0.0
    @Published private(set) var transmitting = false
    @Published private(set) var txProgress = 0.0
    @Published private(set) var txMessage: String?

    static let defaultMacros = ["CQ CQ CQ de {CALL} {CALL} {CALL} pse k\n", "{CALL} ", "ur rst 599 599 ",
                                "tnx fer qso 73 de {CALL} sk\n", "QRZ? de {CALL} k\n"]
    static let speeds: [(baud: Double, name: String)] = [(31.25, "PSK31"), (62.5, "PSK63")]

    var modeName: String { baud > 40 ? "PSK63" : "PSK31" }

    private let decoder = PSKDecoder()
    private weak var cat: CATClient?
    private weak var audio: AudioManager?
    private weak var logbook: LogbookStore?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var txStarted = Date()
    private var txDuration = 1.0
    private var progressTimer: Timer?
    private static let maxText = 8000

    init() {
        let d = UserDefaults.standard
        decoderEnabled = d.object(forKey: "psk.decoder") as? Bool ?? true
        baud = d.object(forKey: "psk.baud") as? Double ?? 31.25
        afc = d.object(forKey: "psk.afc") as? Bool ?? true
        squelch = d.object(forKey: "psk.squelch") as? Double ?? 0.5
        txLevel = d.object(forKey: "psk.txLevel") as? Double ?? 0.5
        carrier = d.object(forKey: "psk.carrier") as? Double ?? 1000
        let saved = d.stringArray(forKey: "psk.macros") ?? []
        macros = saved.count == 5 ? saved : Self.defaultMacros
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "psk." + key) }

    func attach(audio: AudioManager, cat: CATClient, logbook: LogbookStore) {
        guard self.cat == nil else { return }
        self.cat = cat
        self.audio = audio
        self.logbook = logbook
        decoder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        decoder.configure(baud: baud)
        decoder.setAFC(afc)
        decoder.setSquelch(squelch)
        decoder.setCarrier(carrier)
        decoder.setPaused(!decoderEnabled)
        updateTap()
    }

    private func updateTap() {
        guard let audio else { return }
        if decoderEnabled {
            audio.sampleTap.set("psk") { [decoder] samples, rate in decoder.append(samples, sampleRate: rate) }
        } else {
            audio.sampleTap.set("psk", nil)
        }
    }

    private func handle(_ event: PSKDecoder.Event) {
        switch event {
        case .text(let piece):
            text += piece.replacingOccurrences(of: "\r", with: "")
            if text.count > Self.maxText { text = String(text.suffix(Self.maxText)) }
        case .status(let hz, let q):
            if abs(hz - carrier) > 0.5 { carrier = hz }
            if abs(q - quality) > 0.02 { quality = q }
        }
    }

    /// Kliknięcie w widmo: częstotliwość stacji (AFC dostraja dalej).
    func setCarrier(_ hz: Double) {
        let value = min(max(hz, 200), 3000)
        carrier = value
        save("carrier", value)
        decoder.setCarrier(value)
    }

    func clearText() { text = "" }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Nadawanie (BPSK przez dźwięk USB)

    func expand(_ template: String) -> String {
        template.replacingOccurrences(of: "{CALL}", with: logbook?.myCall.uppercased() ?? "")
    }

    /// Radio w DATA-U (PSK nadaje się w górnej wstędze; ton audio = przesunięcie nad częstotliwością wybierania).
    func setRadioDataU() { cat?.setMode("C") }

    func transmit(_ raw: String, armed: Bool) {
        guard let cat, let audio else { return }
        let message = expand(raw)
        txMessage = nil
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !transmitting else { return }
        guard armed, cat.isConnected else {
            txMessage = L("Nadawanie wymaga połączenia z radiem i zaznaczenia „Odblokuj TX”.")
            return
        }
        guard audio.radioOut != 0 else {
            txMessage = L("Wybierz w zakładce AUDIO urządzenie „Do radia (TX)”.")
            return
        }
        let duration = PSKModulator.duration(of: message, baud: baud)
        guard duration + 1 <= cat.txTimeout else {
            txMessage = L("Tekst trwa {1} s, a limit nadawania to {2} s - skróć tekst albo zwiększ limit.",
                          Int(duration.rounded()), Int(cat.txTimeout))
            return
        }
        let rate = 48_000.0
        // nadajemy na częstotliwości odbioru - stacja po drugiej stronie trafi w nas
        let samples = PSKModulator.modulate(message, sampleRate: rate, carrier: carrier, baud: baud, amplitude: Float(txLevel))
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
        text += "\n» " + message.trimmingCharacters(in: .newlines) + "\n"
        transmitting = true
        txProgress = 0
        txDuration = Double(samples.count) / rate
        cat.ptt(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.transmitting, let player = self.player else { return }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self?.finishTX(message: nil)
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

    private func finishTX(message: String?) {
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
        decoder.setCarrier(carrier)
    }
}

@MainActor
final class PSKHolder: ObservableObject {
    let manager = PSKManager()
}
