import Foundation
import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

@MainActor
final class AudioManager: ObservableObject {
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []

    @Published var radioIn: AudioDeviceID = 0      // RX: dźwięk z radia
    @Published var speakerOut: AudioDeviceID = 0   // RX: głośniki / słuchawki Maca
    @Published var micIn: AudioDeviceID = 0        // TX: mikrofon Maca
    @Published var radioOut: AudioDeviceID = 0     // TX: wejście audio USB radia

    @Published var txOverUSB = false
    /// Redukcja szumu w odsłuchu (DSP na Macu): poziom, filtr pasma głosu, wyrównanie głośności.
    @Published var nrLevel: AudioDenoiser.Level = .off { didSet { applyNR() } }
    @Published var nrVoiceBand = false { didSet { applyNR() } }
    @Published var nrAGC = true { didSet { applyNR() } }
    @Published var nrANF = false { didSet { applyNR() } }
    @Published var nrNB = false { didSet { applyNR() } }
    /// Siła AI (RNNoise): udział wyniku sieci; reszta to oryginał - słabe stacje nie znikają.
    @Published var aiStrength = 0.7 { didSet { applyNR() } }
    /// APF (wąski filtr szczytowy CW) w odsłuchu; środek podąża za tonem dekodera CW.
    @Published var apfEnabled = false { didSet { applyNR() } }
    @Published var apfBandwidth = 100.0 { didSet { applyNR() } }
    /// Korektor (EQ) odsłuchu: gotowe ustawienie albo „Własne” po ruszeniu suwaka.
    @Published var eqEnabled = false { didSet { applyNR() } }
    /// Korektor nadawania (12 pasm): mikrofon Maca i mikrofon panelu zdalnego → radio.
    @Published var txEQEnabled = UserDefaults.standard.bool(forKey: "txEQ.enabled") {
        didSet { UserDefaults.standard.set(txEQEnabled, forKey: "txEQ.enabled"); applyTXEQ() }
    }
    @Published var txEQPreset: TXEQPreset = TXEQPreset(rawValue: UserDefaults.standard.string(forKey: "txEQ.preset") ?? "") ?? .flat {
        didSet {
            UserDefaults.standard.set(txEQPreset.rawValue, forKey: "txEQ.preset")
            if let gains = txEQPreset.gains, gains != txEQGains { txEQGains = gains }
        }
    }
    @Published var txEQGains: [Double] = {
        let saved = UserDefaults.standard.array(forKey: "txEQ.gains") as? [Double]
        return saved?.count == TXEqualizer.bands.count ? saved! : TXEqualizer.flat
    }() {
        didSet {
            UserDefaults.standard.set(txEQGains, forKey: "txEQ.gains")
            if txEQPreset.gains != txEQGains { txEQPreset = .custom }   // ruszony suwak - ustawienie własne
            applyTXEQ()
        }
    }

    private func applyTXEQ() {
        TXEqualizerConfig.shared.set(enabled: txEQEnabled, gains: txEQGains)
    }
    @Published var eqPreset: EQPreset = .flat {
        didSet { if let gains = eqPreset.gains, gains != eqGains { eqGains = gains } }
    }
    @Published var eqGains: [Double] = [0, 0, 0, 0, 0, 0, 0, 0] {
        didSet {
            if eqPreset.gains != eqGains { eqPreset = .custom }      // ruszony suwak - ustawienie własne
            applyNR()
        }
    }

    /// Środek APF - nie publikowany (zmienia się kilka razy na sekundę, okno nie musi się przerysowywać).
    private(set) var apfCenter = 700.0

    /// Ton z dekodera CW (albo wskazany w widmie) - APF przestraja się razem z nim.
    func setAPFCenter(_ hz: Double) {
        guard hz > 200, hz < 2000, abs(hz - apfCenter) > 1 else { return }
        apfCenter = hz
        if apfEnabled { applyNR() }
    }

    private func applyNR() {
        rx.denoiser.setConfig(AudioDenoiser.Config(level: nrLevel, voiceBand: nrVoiceBand, agc: nrAGC,
                                                   anf: nrANF, nb: nrNB, apf: apfEnabled,
                                                   apfHz: apfCenter, apfBandwidth: apfBandwidth,
                                                   aiStrength: aiStrength, eq: eqEnabled, eqGains: eqGains))
    }

    /// Ustawienia zapisane przyciskiem „Zapisz ustawienia” - program startuje z nimi do następnego zapisu.
    @Published private(set) var saved: AudioSettings? = AudioSettings.load()
    /// Głośność odsłuchu (zapamiętywana); wyciszenie zeruje odtwarzanie, ale pamięta ustawiony poziom.
    @Published var rxVolume: Float = UserDefaults.standard.object(forKey: "audio.rxVolume") as? Float ?? 0.8 {
        didSet {
            rx.volume = rxMuted ? 0 : rxVolume
            UserDefaults.standard.set(rxVolume, forKey: "audio.rxVolume")
        }
    }
    @Published var rxMuted = false { didSet { rx.volume = rxMuted ? 0 : rxVolume } }
    @Published var txVolume: Float = 0.7 { didSet { tx.volume = txVolume } }

    @Published private(set) var listening = false
    @Published private(set) var txReady = false
    /// Poziomy RX/TX zmieniają się kilkadziesiąt razy na sekundę - osobny obiekt, obserwowany tylko
    /// przez paski poziomu, żeby nie przerysowywać całego okna.
    let levels = AudioLevels()
    var txLevel: Float { levels.tx }
    @Published var message: String?

    /// Widmo i waterfall liczone z dźwięku odbiornika (działa, gdy odsłuch jest włączony).
    let spectrum: SpectrumModel

    private let rx = AudioBridge()
    private let analyzer = SpectrumAnalyzer(fftSize: 4096)
    /// Dodatkowy odbiorca dźwięku z radia (dekoder SSTV) - wywoływany na wątku audio.
    let sampleTap = SampleTap()
    /// Widmo audio liczone tylko wtedy, gdy jest widoczne (WIDMO AUDIO, SSTV, CW) - bez tego FFT i obraz
    /// waterfalla liczyły się przez cały czas odsłuchu.
    private let spectrumGate = SampleGate()
    private var spectrumUsers: Set<String> = []

    func setSpectrumNeeded(_ user: String, _ needed: Bool) {
        if needed { spectrumUsers.insert(user) } else { spectrumUsers.remove(user) }
        spectrumGate.set(!spectrumUsers.isEmpty)
    }
    private let tx = AudioBridge()
    private var keyed = false

    init() {
        spectrum = SpectrumModel(role: .audio)
        rx.volume = rxMuted ? 0 : rxVolume
        tx.volume = txVolume
        tx.muted = true
        tx.appliesTXEqualizer = true                       // korektor nadawania tylko w torze mikrofon → radio
        applyTXEQ()
        // Odzyskiwanie toru dźwięku: zmiana konfiguracji silnika (np. głośniki monitora znikają po jego uśpieniu),
        // wybudzenie monitora albo Maca i strażnik - odsłuch włączony, a dźwięk z radia nie płynie.
        rx.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.recoverAudio(L("zmiana urządzeń audio")) }
        }
        tx.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.recoverAudio(L("zmiana urządzeń audio")) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)      // system kończy przywracanie urządzeń
                    guard let self, self.listening, self.rx.secondsSinceInput > 1.5 else { return }
                    self.recoverAudio(L("wybudzenie"))
                }
            }
        }
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.listening, self.rx.secondsSinceInput > 5 { self.recoverAudio(L("brak dźwięku z radia")) }
            }
        }
        rx.onLevel = { [levels = self.levels] level in Task { @MainActor in levels.update(rx: level) } }
        tx.onLevel = { [levels = self.levels] level in Task { @MainActor in levels.update(tx: level) } }
        rx.onSamples = { [analyzer = self.analyzer, tap = self.sampleTap, gate = self.spectrumGate] samples, rate in
            if gate.isOpen { analyzer.append(samples, sampleRate: rate) }   // widmo tylko, gdy ktoś je ogląda
            tap.deliver(samples, rate)                 // np. dekoder SSTV
        }
        analyzer.onSpectrum = { [weak spectrum = self.spectrum] db, rate in
            Task { @MainActor in spectrum?.ingest(db: db, sampleRate: rate) }
        }
        refreshDevices()
        if let saved {
            rxVolume = saved.rxVolume
            txVolume = saved.txVolume
            txOverUSB = saved.txOverUSB
            nrLevel = saved.nrLevel.flatMap(AudioDenoiser.Level.init(rawValue:)) ?? .off
            nrVoiceBand = saved.nrVoiceBand ?? false
            nrAGC = saved.nrAGC ?? true
            nrANF = saved.nrANF ?? false
            nrNB = saved.nrNB ?? false
            apfEnabled = saved.apf ?? false
            apfBandwidth = saved.apfBandwidth ?? 100
            aiStrength = saved.aiStrength ?? 0.7
            if let gains = saved.eqGains, gains.count == 8 { eqGains = gains }
            eqPreset = saved.eqPreset.flatMap(EQPreset.init(rawValue:)) ?? .flat
            if let gains = saved.eqGains, gains.count == 8, eqPreset == .custom { eqGains = gains }
            eqEnabled = saved.eq ?? false
            if saved.listening {
                Task { @MainActor [weak self] in self?.startListeningIfStopped() }
            }
        }
    }

    // MARK: - Zapisane ustawienia

    /// Zapis bieżących ustawień: urządzenia (po UID), głośności, nadawanie przez USB, stan odsłuchu.
    func saveSettings() {
        let settings = currentSettings()
        settings.store()
        saved = settings
        message = nil
    }

    /// Czy bieżące ustawienia różnią się od zapisanych.
    var hasUnsavedChanges: Bool { saved != currentSettings() }

    private func currentSettings() -> AudioSettings {
        func uid(_ id: AudioDeviceID, _ list: [AudioDevice]) -> String { list.first { $0.id == id }?.uid ?? "" }
        return AudioSettings(radioIn: uid(radioIn, inputs), speakerOut: uid(speakerOut, outputs),
                             micIn: uid(micIn, inputs), radioOut: uid(radioOut, outputs),
                             rxVolume: rxVolume, txVolume: txVolume, txOverUSB: txOverUSB, listening: listening,
                             nrLevel: nrLevel.rawValue, nrVoiceBand: nrVoiceBand, nrAGC: nrAGC,
                             nrANF: nrANF, nrNB: nrNB, apf: apfEnabled, apfBandwidth: apfBandwidth,
                             eq: eqEnabled, eqPreset: eqPreset.rawValue, eqGains: eqGains, aiStrength: aiStrength)
    }

    private func startListeningIfStopped() {
        if !listening, radioIn != 0 { toggleListening() }
    }

    // MARK: - Urządzenia

    func refreshDevices() {
        inputs = AudioDevices.all(input: true)
        outputs = AudioDevices.all(input: false)

        // Gdy wybrane urządzenie zniknęło (albo jeszcze nic nie wybrano): najpierw zapisane (po UID),
        // potem dobór automatyczny. Zapisane urządzenie radia pojawia się np. po włączeniu radia.
        let saved = self.saved
        func savedID(_ uid: String?, _ list: [AudioDevice]) -> AudioDeviceID? {
            guard let uid, !uid.isEmpty else { return nil }
            return list.first { $0.uid == uid }?.id
        }
        if !inputs.contains(where: { $0.id == radioIn }) {
            radioIn = savedID(saved?.radioIn, inputs)
                ?? inputs.first(where: { Self.looksLikeRadio($0.name) })?.id ?? 0
        }
        if !outputs.contains(where: { $0.id == speakerOut }) {
            speakerOut = savedID(saved?.speakerOut, outputs)
                ?? outputs.first(where: { !Self.looksLikeRadio($0.name) })?.id ?? 0
        }
        // Mikrofon nigdy nie jest wybierany automatycznie jako wejście radia.
        if !inputs.contains(where: { $0.id == micIn }) || (micIn != 0 && micIn == radioIn) {
            micIn = savedID(saved?.micIn, inputs).flatMap { $0 == radioIn ? nil : $0 }
                ?? inputs.first(where: { !Self.looksLikeRadio($0.name) && $0.id != radioIn })?.id ?? 0
        }
        if !outputs.contains(where: { $0.id == radioOut }) {
            radioOut = savedID(saved?.radioOut, outputs)
                ?? outputs.first(where: { Self.looksLikeRadio($0.name) })?.id ?? 0
        }
    }

    private static func looksLikeRadio(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("usb audio") || n.contains("codec") || n.contains("ft-710") || n.contains("ft710")
    }

    // MARK: - Zgoda na mikrofon

    func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            message = L("Brak zgody na mikrofon: Ustawienia systemowe → Prywatność i ochrona → Mikrofon (zaznacz Terminal lub Xcode)")
            return false
        }
    }

    // MARK: - RX

    func toggleListening() {
        if listening {
            rx.stop()
            analyzer.reset()
            listening = false
            levels.update(rx: 0)
            return
        }
        Task {
            guard await ensureMicPermission() else { return }
            do {
                try rx.start(inputID: radioIn, outputID: speakerOut)
                rx.muted = keyed
                listening = true
                message = nil
            } catch {
                message = L("Odsłuch: {1}", error.localizedDescription)
            }
        }
    }

    /// Ponowne uruchomienie torów dźwięku z odświeżoną listą urządzeń (po uśpieniu numery urządzeń mogą się zmienić).
    /// Odsłuch i wodospad FT8 (karmiony tym samym dźwiękiem) wracają same - bez ręcznego wyłączania odsłuchu.
    private var recoveringAudio = false

    func recoverAudio(_ reason: String) {
        guard !recoveringAudio else { return }
        recoveringAudio = true
        Task { @MainActor in
            defer { recoveringAudio = false }
            try? await Task.sleep(nanoseconds: 700_000_000)
            refreshDevices()
            if listening {
                rx.stop()
                do {
                    try rx.start(inputID: radioIn, outputID: speakerOut)
                    rx.muted = keyed
                    message = nil
                    NSLog("FT710Control: odsłuch uruchomiony ponownie (%@)", reason)
                } catch {
                    message = L("Odsłuch: ponowne uruchamianie ({1}) - {2}", reason, error.localizedDescription)
                }
            }
            if tx.running, !keyed {                            // tor mikrofonu - nie w trakcie nadawania
                stopTXPath()
                updateTXPath(armed: txArmed)
            }
        }
    }

    // MARK: - TX

    /// Mikrofon jest „na gorąco" (ale wyciszony) dopiero po odblokowaniu nadawania,
    /// dzięki czemu start PTT nie czeka na uruchomienie silnika audio.
    func updateTXPath(armed: Bool) {
        txArmed = armed                                              // aktualny stan - sprawdzany po czekaniu na zgodę
        guard armed, txOverUSB else {
            stopTXPath()
            return
        }
        guard !tx.running, !txStarting else { return }               // jedno uruchomienie naraz
        guard micIn != radioIn else {
            message = L("Mikrofon (TX) to to samo urządzenie co „Z radia (RX)” - odbierany dźwięk trafiłby do nadajnika. Wybierz mikrofon Maca.")
            txReady = false
            return
        }
        txStarting = true
        Task {
            defer { txStarting = false }
            guard await ensureMicPermission() else { return }
            // w czasie pytania o zgodę mogły się zmienić warunki (zgoda TX, opcja, inne uruchomienie)
            guard txArmed, txOverUSB, !tx.running else { return }
            do {
                tx.muted = true
                try tx.start(inputID: micIn, outputID: radioOut)
                txReady = true
                message = nil
            } catch {
                txReady = false
                message = L("Audio TX: {1}", error.localizedDescription)
            }
        }
    }

    private var txStarting = false
    private var txArmed = false

    func stopTXPath() {
        keyed = false
        tx.muted = true
        tx.stop()
        txReady = false
        levels.update(tx: 0)
        rx.muted = false
    }

    /// Zwraca false, gdy audio z Maca jest włączone, ale nie jest gotowe (wtedy nie kluczujemy radia).
    func beginTX() -> Bool {
        guard txOverUSB else { return true }
        guard txReady else {
            message = micIn == radioIn
                ? L("Nie nadaję: mikrofon (TX) to wejście z radia. Wybierz mikrofon Maca.")
                : L("Audio TX nie jest gotowe - sprawdź urządzenia i zgodę na mikrofon")
            return false
        }
        keyed = true
        rx.muted = true      // nie odtwarzaj odbioru podczas nadawania (ryzyko sprzężenia przez mikrofon)
        tx.muted = false
        return true
    }

    func endTX() {
        guard keyed || tx.muted == false else { return }
        keyed = false
        tx.muted = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !keyed { rx.muted = false }
        }
    }

    func stopAll() {
        stopTXPath()
        rx.stop()
        analyzer.reset()
        listening = false
        levels.update(rx: 0)
    }
}

/// Poziomy audio do pasków (0…1). Publikowane najwyżej ~15 razy na sekundę i tylko przy widocznej zmianie.
@MainActor
final class AudioLevels: ObservableObject {
    @Published private(set) var rx: Float = 0
    @Published private(set) var tx: Float = 0
    private var lastRX = Date.distantPast
    private var lastTX = Date.distantPast

    func update(rx value: Float) {
        guard value == 0 ? rx != 0 : (abs(value - rx) > 0.003 && Date().timeIntervalSince(lastRX) > 0.066) else { return }
        rx = value
        lastRX = Date()
    }

    func update(tx value: Float) {
        guard value == 0 ? tx != 0 : (abs(value - tx) > 0.003 && Date().timeIntervalSince(lastTX) > 0.066) else { return }
        tx = value
        lastTX = Date()
    }
}

/// Pasek poziomu audio obserwujący tylko poziomy (nie całe AudioManager).
struct AudioLevelBar: View {
    @ObservedObject var levels: AudioLevels
    let transmit: Bool

    var body: some View {
        ProgressView(value: Double(min((transmit ? levels.tx : levels.rx) * 4, 1)))
    }
}

/// Przekazanie próbek z wątku audio do wielu odbiorców (SSTV, CW…), każdy pod własnym kluczem.
final class SampleTap: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable ([Float], Double) -> Void] = [:]

    func set(_ key: String, _ handler: (@Sendable ([Float], Double) -> Void)?) {
        lock.lock()
        handlers[key] = handler
        lock.unlock()
    }

    func deliver(_ samples: [Float], _ rate: Double) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current { handler(samples, rate) }
    }
}

/// Zapisane ustawienia audio (urządzenia po UID - stałe między uruchomieniami).
struct AudioSettings: Codable, Equatable {
    var radioIn: String
    var speakerOut: String
    var micIn: String
    var radioOut: String
    var rxVolume: Float
    var txVolume: Float
    var txOverUSB: Bool
    var listening: Bool
    // redukcja szumu (opcjonalne - starsze zapisy ich nie mają)
    var nrLevel: Int?
    var nrVoiceBand: Bool?
    var nrAGC: Bool?
    var nrANF: Bool?
    var nrNB: Bool?
    var apf: Bool?
    var apfBandwidth: Double?
    var eq: Bool?
    var eqPreset: String?
    var eqGains: [Double]?
    var aiStrength: Double?

    private static let key = "audioSettings"

    static func load() -> AudioSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AudioSettings.self, from: data)
    }

    func store() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Przełącznik czytany z wątku audio.
final class SampleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    func set(_ value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }
}


/// Gotowe ustawienia korektora nadawania (12 pasm: 60…3300 Hz).
enum TXEQPreset: String, CaseIterable, Identifiable {
    case flat, dx, ragchew, contest, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .flat: return L("Płasko")
        case .dx: return L("DX - przebicie")
        case .ragchew: return L("Rozmowa - pełny głos")
        case .contest: return L("Zawody")
        case .custom: return L("Własne")
        }
    }

    /// 60, 100, 160, 250, 400, 630, 1000, 1400, 1800, 2300, 2800, 3300 Hz
    var gains: [Double]? {
        switch self {
        case .flat: return TXEqualizer.flat
        case .dx: return [-12, -10, -6, -3, -1, 0, 1, 3, 5, 6, 5, 2]
        case .ragchew: return [-4, 0, 3, 3, 1, 0, 0, 1, 2, 2, 1, 0]
        case .contest: return [-14, -12, -8, -4, -2, 0, 2, 4, 6, 7, 6, 3]
        case .custom: return nil
        }
    }
}
