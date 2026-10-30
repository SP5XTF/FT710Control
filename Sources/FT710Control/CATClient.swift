import Foundation
import SwiftUI

struct Band: Identifiable {
    let name: String
    let freq: Int
    var id: String { name }

    // Domyślne częstotliwości startowe po kliknięciu pasma (do zmiany wg uznania).
    static let all: [Band] = [
        Band(name: "160", freq: 1_840_000),
        Band(name: "80", freq: 3_700_000),
        Band(name: "40", freq: 7_100_000),
        Band(name: "30", freq: 10_120_000),
        Band(name: "20", freq: 14_200_000),
        Band(name: "17", freq: 18_120_000),
        Band(name: "15", freq: 21_200_000),
        Band(name: "12", freq: 24_940_000),
        Band(name: "10", freq: 28_400_000),
        Band(name: "6", freq: 50_150_000)
    ]
}

struct RadioMode: Identifiable {
    let label: String
    let code: String
    var id: String { code }

    // Kody trybów wg dokumentacji CAT (komenda MD) - zweryfikuj z instrukcją CAT FT-710.
    static let selectable: [RadioMode] = [
        RadioMode(label: "LSB", code: "1"),
        RadioMode(label: "USB", code: "2"),
        RadioMode(label: "CW-U", code: "3"),
        RadioMode(label: "CW-L", code: "7"),
        RadioMode(label: "AM", code: "5"),
        RadioMode(label: "FM", code: "4"),
        RadioMode(label: "DATA-L", code: "8"),
        RadioMode(label: "DATA-U", code: "C")
    ]

    static let names: [String: String] = [
        "1": "LSB", "2": "USB", "3": "CW-U", "4": "FM", "5": "AM", "6": "RTTY-L",
        "7": "CW-L", "8": "DATA-L", "9": "RTTY-U", "A": "DATA-FM", "B": "FM-N",
        "C": "DATA-U", "D": "AM-N"
    ]
}

@MainActor
final class CATClient: ObservableObject {
    @Published var ports: [String] = SerialPort.availablePorts()
    @Published var selectedPort: String = ""
    @Published var baud: Int = 38400
    /// Łączenie przy starcie z zapamiętanym portem (port i prędkość zapisywane po udanym połączeniu).
    @Published var autoConnect = UserDefaults.standard.object(forKey: "catAutoConnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "catAutoConnect")
            if !autoConnect { stopAutoConnect() }
        }
    }
    private var autoConnectTask: Task<Void, Never>?
    private static let savedPortKey = "catPort"
    private static let savedBaudKey = "catBaud"

    @Published private(set) var isConnected = false
    @Published private(set) var status = L("Rozłączony")
    @Published private(set) var freqA = 0
    @Published private(set) var freqB = 0
    /// Tryb PRACY - aktywnego VFO (używany w całym programie: przyciski, dziennik, pasma, RTTY, CW…).
    @Published private(set) var modeCode = ""
    /// Tryby według litery VFO: FT-710 podaje MD0 = VFO-A, MD1 = VFO-B (sprawdzone przy radiu).
    @Published private(set) var modeCodeA = ""
    /// Mierniki zmieniają się kilka razy na sekundę - osobny obiekt obserwowany tylko przez panel mierników,
    /// żeby nie przeliczać całego okna przy każdym ruchu S-metra.
    let meters = CATMeters()
    var sMeter: Int { meters.latest.s }
    @Published private(set) var transmitting = false
    var rawPO: Int { meters.latest.po }
    var rawSWR: Int { meters.latest.swr }
    var rawALC: Int { meters.latest.alc }
    var rawCOMP: Int { meters.latest.comp }

    /// Ustawienia radia (AF, RF, SQL, moc, preamp, ATT, AGC…) - patrz RadioControls.swift.
    @Published private(set) var controls: [RadioControl: Int] = [:]
    /// Ustawienia, na które radio odpowiedziało (pozostałe są w panelu wyłączone).
    @Published private(set) var supportedControls: Set<RadioControl> = []
    /// Po tym czasie od połączenia brak odpowiedzi oznacza nieobsługiwane ustawienie.
    @Published private(set) var controlsProbed = false
    private var lastLocalChange: [RadioControl: Date] = [:]
    private var pendingValue: [RadioControl: Int] = [:]
    private var throttleTasks: [RadioControl: Task<Void, Never>] = [:]
    /// Dziennik komunikacji CAT - osobny obiekt, obserwowany tylko przez zakładkę LOG CAT. Jako właściwość
    /// publikowana tego obiektu każdy wpis (także odpowiedzi z odpytywania) przebudowywał wszystkie widoki
    /// zależne od radia - suwaki, przyciski, panele - i blokował główny wątek (pomiar Instruments).
    let logModel = CATLogModel()
    var log: [String] { logModel.lines }

    /// Maksymalny czas jednego nadawania; potem aplikacja sama wysyła TX0 (zabezpieczenie przed „zawieszonym" PTT).
    @Published var txTimeout: TimeInterval = 180
    /// Zwiększany przy każdym zadziałaniu limitu czasu - widok blokuje wtedy PTT do puszczenia przycisku.
    @Published private(set) var txTimeoutCount = 0

    private let port = SerialPort()
    private var rxBuffer = ""
    private var pollTask: Task<Void, Never>?
    private var lastRX = Date()
    private var pollCycle = 0
    /// Tryb VFO-B (MD1). Gdy radio nie odpowie na 3 kolejne zapytania - przestajemy pytać.
    @Published private(set) var modeCodeB = ""
    private var modeBSupported = true
    private var modeBAnswered = true            // pierwsze zapytanie nie liczy się jako bez odpowiedzi
    private var modeBUnanswered = 0

    var modeNameB: String { RadioMode.names[modeCodeB] ?? "" }
    var modeNameA: String { RadioMode.names[modeCodeA] ?? "" }

    /// Tryb pracy = tryb aktywnego VFO.
    private func updateOperatingMode() {
        let code = activeVFO == "B" ? modeCodeB : modeCodeA
        if !code.isEmpty, code != modeCode { modeCode = code }
    }

    /// Pasmo nadawania SSB (menu RADIO SETTING → MODE SSB → TX BPF SEL, EX010113), np. „2.8k”.
    @Published private(set) var ssbTxBandwidth = ""
    private static let txBPFNames = ["0": "3.0k", "1": "2.8k", "2": "2.6k", "3": "2.4k", "4": "2.2k"]

    // MARK: Aktywne VFO
    // W FT-710 „SV” (przycisk A/B) przełącza, na którym VFO pracuje radio - częstotliwości A i B zostają
    // na miejscu. Program musi więc wiedzieć, które VFO jest aktywne: odczyt „VS” (0 = A, 1 = B), a gdy
    // radio go nie obsługuje - śledzenie własnego przycisku A/B (przełączeń z panelu radia wtedy nie widać).

    @Published private(set) var activeVFO = "A"
    private(set) var vfoSelectSupported = true
    private var vfoSelectAnswered = true
    private var vfoSelectUnanswered = 0

    /// Częstotliwość pracy (aktywnego VFO) - do dziennika, skopu, pasm, spotów, pamięci, CAT Share.
    var activeFreq: Int { activeVFO == "B" ? freqB : freqA }

    /// Strojenie aktywnego VFO.
    func setActiveFrequency(_ hz: Int) { setFrequency(vfo: activeVFO, hz: hz) }

    private func requestVFOSelect() -> String {
        if vfoSelectAnswered { vfoSelectUnanswered = 0 } else { vfoSelectUnanswered += 1 }
        vfoSelectAnswered = false
        if vfoSelectUnanswered >= 3 { vfoSelectSupported = false; return "" }
        return "VS;"
    }

    private func requestModeB() -> String {
        if modeBAnswered { modeBUnanswered = 0 } else { modeBUnanswered += 1 }
        modeBAnswered = false
        if modeBUnanswered >= 3 { modeBSupported = false; return "" }
        return "MD1;"
    }
    private var lastErrorLog = Date.distantPast
    private var txWatchdog: Task<Void, Never>?

    var modeName: String { RadioMode.names[modeCode] ?? "—" }

    init() {
        let savedPort = UserDefaults.standard.string(forKey: Self.savedPortKey) ?? ""
        selectedPort = ports.contains(savedPort) ? savedPort : (ports.first ?? "")
        let savedBaud = UserDefaults.standard.integer(forKey: Self.savedBaudKey)
        if savedBaud > 0 { baud = savedBaud }
        port.sendOnTerminate = "TX0;"   // zamknięcie aplikacji zawsze zwalnia nadawanie
        port.onData = { [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.handleIncoming(text) }
        }
    }

    // MARK: - Połączenie

    func refreshPorts() {
        let current = SerialPort.availablePorts()
        if current != ports { ports = current }
        if !ports.contains(selectedPort) {
            let saved = UserDefaults.standard.string(forKey: Self.savedPortKey) ?? ""
            selectedPort = ports.contains(saved) ? saved : (ports.first ?? "")
        }
    }

    /// Automatyczne łączenie z zapamiętanym portem. Gdy radio jest wyłączone, próba co 5 s,
    /// aż port się pojawi. Ręczne „Rozłącz” zatrzymuje próby.
    func startAutoConnect() {
        guard autoConnect, autoConnectTask == nil, !isConnected,
              let saved = UserDefaults.standard.string(forKey: Self.savedPortKey), !saved.isEmpty else { return }
        autoConnectTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.autoConnect, !self.isConnected {
                self.refreshPortsIfIdle()
                if self.ports.contains(saved) {
                    self.selectedPort = saved
                    self.connect()
                    if self.isConnected { break }
                } else {
                    self.status = L("Czekam na radio (port {1})…", saved)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            self?.autoConnectTask = nil
        }
    }

    func stopAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
    }

    /// Odświeża listę portów bez zmiany wybranego portu podczas połączenia.
    func refreshPortsIfIdle() {
        if isConnected {
            let current = SerialPort.availablePorts()
            if current != ports { ports = current }             // publikuj tylko zmiany
        } else {
            refreshPorts()
        }
    }

    func connect() {
        guard !isConnected, !selectedPort.isEmpty else { return }
        do {
            try port.open(path: selectedPort, baud: baud)
            isConnected = true
            status = L("Łączenie…")
            awaitingFirstResponse = true
            lastRX = Date()
            rxBuffer = ""
            send("AI0;")   // wyłącz automatyczne raporty, odpytujemy sami
            send("ID;")
            controls = [:]
            supportedControls = []
            controlsProbed = false
            queryControls()
            startPolling()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isConnected else { return }
                self.controlsProbed = true
                let missing = RadioControl.allCases.filter { !self.supportedControls.contains($0) }
                if !missing.isEmpty {
                    self.appendLog(L("! brak odpowiedzi na: {1} - te kontrolki są wyłączone", missing.map(\.prefix).joined(separator: ", ")))
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() {
        // Zawsze TX0, nawet gdy odpytywanie jeszcze nie zauważyło nadawania
        // (PTT mogło być wciśnięte ułamek sekundy wcześniej). W odbiorze TX0 nic nie zmienia.
        send("PB00;TX0;")          // zatrzymaj też ewentualny komunikat z pamięci
        txWatchdog?.cancel()
        txWatchdog = nil
        selfKeyed = false
        pollTask?.cancel()
        pollTask = nil
        port.close()
        isConnected = false
        transmitting = false
        status = L("Rozłączony")
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollCycle += 1
                var command = "TX;"
                command += self.transmitting ? "RM3;RM4;RM5;RM6;" : "SM0;"   // COMP, ALC, PO, SWR albo S-metr
                if self.pollCycle % 3 == 1 {
                    command += "FA;FB;MD0;"
                    if self.activeVFO == "B", self.modeBSupported { command += "MD1;" }   // tryb pracy na VFO-B - równie często
                }
                if self.pollCycle % 6 == 4, self.vfoSelectSupported { command += self.requestVFOSelect() }
                if self.pollCycle % 25 == 12, self.modeBSupported { command += self.requestModeB() }
                if self.pollCycle % 80 == 40 { command += "EX010113;" }          // TX BW (SSB) co ~10 s
                if self.pollCycle % 25 == 0 && !self.transmitting {
                    // co ok. 3 s: zsynchronizuj ustawienia zmienione gałkami na radiu
                    command += RadioControl.allCases.map(\.query).joined()
                }
                self.send(command, quiet: true)
                if Date().timeIntervalSince(self.lastRX) > 2 {
                    self.status = L("Brak odpowiedzi - sprawdź port (drugi z pary?) i CAT RATE")
                    self.noResponseShown = true
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    // MARK: - Komendy

    func send(_ command: String, quiet: Bool = false) {
        port.write(command)
        if !quiet { appendLog("→ \(command)") }
    }

    /// Czas ostatniej lokalnej zmiany częstotliwości - odczyt z odpytywania, wysłany przed zmianą,
    /// nie może cofnąć wyświetlacza (np. przy szybkim kręceniu kółkiem myszy).
    private var localFrequencyChange: [String: Date] = [:]

    func setFrequency(vfo: String, hz: Int) {
        let clamped = min(max(hz, 30_000), 75_000_000)
        send("F\(vfo)" + String(format: "%09d", clamped) + ";", quiet: true)
        if vfo == "A" { freqA = clamped } else { freqB = clamped }
        localFrequencyChange[vfo] = Date()
    }

    private func acceptsPolledFrequency(_ vfo: String) -> Bool {
        Date().timeIntervalSince(localFrequencyChange[vfo] ?? .distantPast) > 0.4
    }

    func tune(by delta: Int) {
        guard freqA > 0 else { return }   // nie znamy jeszcze częstotliwości - nie przestrajaj na 30 kHz
        setFrequency(vfo: "A", hz: freqA + delta)
    }

    /// Zmiana trybu AKTYWNEGO VFO (MD0 - VFO-A, MD1 - VFO-B).
    func setMode(_ code: String) {
        if activeVFO == "B" {
            send("MD1\(code);")
            modeCodeB = code
        } else {
            send("MD0\(code);")
            modeCodeA = code
        }
        modeCode = code
    }

    func copyAtoB() { send(modeBSupported ? "AB;MD1;" : "AB;") }
    func swapVFO() {
        if !vfoSelectSupported {
            activeVFO = activeVFO == "A" ? "B" : "A"                  // bez odczytu VS - śledzimy własny przycisk
            updateOperatingMode()
        }
        send("SV;" + (vfoSelectSupported ? "VS;" : "") + "FA;FB;MD0;" + (modeBSupported ? "MD1;" : ""))
    }

    func ptt(_ on: Bool) {
        send(on ? "TX1;" : "TX0;")
        selfKeyed = false
        if on { startWatchdog() } else { cancelWatchdog() }
    }

    /// Nadawanie uruchomione przez aplikację bez PTT (komunikat z pamięci radia, strojenie tunera):
    /// limit czasu obowiązuje, a koniec nadawania zgłoszony przez radio kończy dozór.
    private var selfKeyed = false
    /// Stan napisu statusu (zamiast porównywania tekstów, które zależą od języka).
    private var awaitingFirstResponse = false
    private var noResponseShown = false
    private var selfKeyedSawTX = false      // radio już zgłosiło nadawanie po komendzie
    private var selfKeyedAt = Date.distantPast

    private func startWatchdog() {
        txWatchdog?.cancel()
        let limit = txTimeout
        txWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.send("PB00;TX0;")
            self.selfKeyed = false
            self.status = L("Limit czasu nadawania ({1} s) - wysłano TX0", Int(limit))
            self.appendLog(L("! limit czasu nadawania, TX0"))
            self.txTimeoutCount += 1
        }
    }

    private func beginSelfKeyed() {
        selfKeyed = true
        selfKeyedSawTX = false
        selfKeyedAt = Date()
        startWatchdog()
    }

    private func cancelWatchdog() {
        txWatchdog?.cancel()
        txWatchdog = nil
    }

    // MARK: - Pamięć komunikatów radia (MESSAGE MEMORY)

    /// Odtwarza komunikat z pamięci radia - radio samo zaklucza nadajnik.
    /// Fonia: PB0n (n = 1…5), CW: KYn. Wywoływać tylko przy odblokowanym nadawaniu.
    func playMessage(_ channel: Int, cw: Bool) {
        guard isConnected, (1...5).contains(channel) else { return }
        send(cw ? "KY\(channel);" : "PB0\(channel);")
        appendLog(L("! komunikat {1} z pamięci radia ({2}) - nadawanie", channel, cw ? "CW" : L("fonia")))
        beginSelfKeyed()
    }

    /// Zatrzymuje odtwarzanie komunikatu i zawsze kończy nadawanie.
    func stopMessage() {
        guard isConnected else { return }
        send("PB00;TX0;")
        selfKeyed = false
        cancelWatchdog()
    }

    // MARK: - Ustawienia radia

    private func queryControls() {
        send(RadioControl.allCases.map(\.query).joined(), quiet: true)
    }

    func value(_ control: RadioControl) -> Int? { controls[control] }

    func isAvailable(_ control: RadioControl) -> Bool {
        isConnected && (supportedControls.contains(control) || !controlsProbed)
    }

    /// Ustawia wartość. Przy przesuwaniu suwaka komendy są wysyłane najwyżej co 60 ms
    /// (zawsze z ostatnią wartością), żeby nie zasypać radia.
    func set(_ control: RadioControl, _ value: Int) {
        guard isConnected else { return }
        let v = min(max(value, control.range.lowerBound), control.range.upperBound)
        controls[control] = v
        lastLocalChange[control] = Date()
        pendingValue[control] = v
        guard throttleTasks[control] == nil else { return }
        send(control.setCommand(v))
        pendingValue[control] = nil
        throttleTasks[control] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self else { return }
            self.throttleTasks[control] = nil
            if let latest = self.pendingValue[control] {
                self.pendingValue[control] = nil
                self.set(control, latest)
            }
        }
    }

    /// Strojenie skrzynki antenowej: radio nadaje krótko nośną. Wywoływać tylko przy odblokowanym nadawaniu.
    func startTuning() {
        guard isConnected else { return }
        send("AC002;")
        appendLog(L("! strojenie tunera (nadawanie nośnej)"))
        beginSelfKeyed()
    }

    // MARK: - Odbiór

    private func handleIncoming(_ text: String) {
        rxBuffer += text
        while let idx = rxBuffer.firstIndex(of: ";") {
            let token = String(rxBuffer[..<idx])
            rxBuffer.removeSubrange(...idx)
            parse(token)
        }
        if rxBuffer.count > 256 { rxBuffer = "" }
    }

    // MARK: - Pojedyncze odczyty (menu EX, pamięć klucza KM, prędkość klucza KS…)

    private struct QueryWaiter {
        let id: UUID
        let prefix: String
        let continuation: CheckedContinuation<String?, Never>
    }
    private var queryWaiters: [QueryWaiter] = []

    /// Wysyła komendę odczytu i czeka na odpowiedź zaczynającą się od `prefix` (bez średnika).
    /// nil = brak odpowiedzi w czasie `timeout` albo radio odrzuciło komendę.
    func query(_ command: String, expect prefix: String, timeout: Double = 1.0) async -> String? {
        guard isConnected else { return nil }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            queryWaiters.append(QueryWaiter(id: id, prefix: prefix, continuation: continuation))
            send(command, quiet: true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let index = self.queryWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.queryWaiters.remove(at: index).continuation.resume(returning: nil)
            }
        }
    }

    private func parse(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRX = Date()
        if let index = queryWaiters.firstIndex(where: { token.hasPrefix($0.prefix) }) {
            queryWaiters.remove(at: index).continuation.resume(returning: token)   // dalej - zwykła obsługa
        }
        if isConnected && (awaitingFirstResponse || noResponseShown) {
            awaitingFirstResponse = false
            noResponseShown = false
            status = L("Połączono")
            // Radio odpowiada - zapamiętaj port i prędkość na następne uruchomienia.
            UserDefaults.standard.set(selectedPort, forKey: Self.savedPortKey)
            UserDefaults.standard.set(baud, forKey: Self.savedBaudKey)
        }

        guard token.count >= 2 else {
            if token == "?" && Date().timeIntervalSince(lastErrorLog) > 2 {
                lastErrorLog = Date()
                appendLog(L("← ? (radio odrzuciło komendę)"))
            }
            return
        }

        if let matched = RadioControl.match(token) {
            let control = matched.0
            let value = matched.1
            if !supportedControls.contains(control) { supportedControls.insert(control) }
            // Nie nadpisuj wartości, którą użytkownik właśnie zmienia suwakiem.
            if Date().timeIntervalSince(lastLocalChange[control] ?? .distantPast) > 1, controls[control] != value {
                controls[control] = value
            }
            return
        }

        let cmd = String(token.prefix(2))
        let args = String(token.dropFirst(2))

        switch cmd {
        case "EX":
            if args.hasPrefix("010113"), let name = Self.txBPFNames[String(args.dropFirst(6))], name != ssbTxBandwidth {
                ssbTxBandwidth = name
            }
        case "FA": if let v = Int(args), acceptsPolledFrequency("A"), v != freqA { freqA = v }
        case "FB": if let v = Int(args), acceptsPolledFrequency("B"), v != freqB { freqB = v }
        case "VS":                                              // "VS0" = VFO-A, "VS1" = VFO-B
            vfoSelectAnswered = true
            let vfo = args.hasPrefix("1") ? "B" : "A"
            if vfo != activeVFO {
                activeVFO = vfo
                updateOperatingMode()                                   // tryb pracy = tryb nowego aktywnego VFO
                send("MD0;" + (modeBSupported ? "MD1;" : ""), quiet: true)
            }
        case "MD":                                              // FT-710: "MD0x" = VFO-A, "MD1x" = VFO-B
            let code = String(args.dropFirst())
            if args.first == "1" {
                modeBAnswered = true
                if code != modeCodeB { modeCodeB = code }
            } else if code != modeCodeA {
                modeCodeA = code
            }
            updateOperatingMode()
        case "SM": if let v = Int(args.dropFirst()), v != sMeter { meters.latest.s = v } // "SM0xxx"
        case "TX":
            let tx = args != "0"
            if tx != transmitting { transmitting = tx }
            if transmitting && selfKeyed { selfKeyedSawTX = true }
            if !transmitting {
                if rawPO != 0 { meters.latest.po = 0 }
                if rawSWR != 0 { meters.latest.swr = 0 }
                if rawALC != 0 { meters.latest.alc = 0 }
                if rawCOMP != 0 { meters.latest.comp = 0 }
                // Koniec komunikatu / strojenia: radio najpierw zgłosiło nadawanie, a teraz odbiór.
                // (Zaraz po komendzie radio może jeszcze odpowiadać TX0 - wtedy dozór trwa.
                //  Jeśli po 5 s nadal nie nadaje, komenda nie zadziałała - też kończymy dozór.)
                if selfKeyed && (selfKeyedSawTX || Date().timeIntervalSince(selfKeyedAt) > 5) {
                    selfKeyed = false
                    cancelWatchdog()
                }
            }
        case "RM":                                              // "RM" + numer miernika + 3 cyfry + "000"
            guard let id = args.first, let value = Int(args.dropFirst().prefix(3)) else { return }
            switch id {
            case "3": if rawCOMP != value { meters.latest.comp = value }
            case "4": if rawALC != value { meters.latest.alc = value }
            case "5": if rawPO != value { meters.latest.po = value }
            case "6": if rawSWR != value { meters.latest.swr = value }
            default: appendLog("← \(token);")
            }
        case "ID":
            let connected = args == "0800" ? L("Połączono z FT-710") : L("Połączono (ID radia: {1})", args)
            if connected != status { status = connected }                    // publikuj tylko zmianę
            appendLog("← ID\(args);")
        default:
            appendLog("← \(token);")
        }
    }

    private func appendLog(_ line: String) {
        logModel.lines.append(line)
        if logModel.lines.count > 60 { logModel.lines.removeFirst(logModel.lines.count - 60) }
    }
}

/// Bieżące odczyty mierników radia (surowe 0–255).
@MainActor
final class CATMeters: ObservableObject {
    struct Values: Equatable {
        var s = 0, po = 0, swr = 0, alc = 0, comp = 0
    }
    /// Najświeższe wartości z radia (zapis od razu; czytają je np. panel zdalny i alerty).
    fileprivate(set) var latest = Values() { didSet { if latest != oldValue { scheduleCommit() } } }
    /// Wartości na ekranie - publikowane razem, najwyżej 10 razy/s (każdy z pięciu wskaźników osobno
    /// publikował kilka razy na sekundę, a każda publikacja odświeżała panel wskaźników).
    @Published private(set) var shown = Values()
    private var commitScheduled = false

    var s: Int { shown.s }
    var po: Int { shown.po }
    var swr: Int { shown.swr }
    var alc: Int { shown.alc }
    var comp: Int { shown.comp }

    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)          // najwyżej 10 publikacji na sekundę
            guard let self else { return }
            self.commitScheduled = false
            if self.latest != self.shown { self.shown = self.latest }
        }
    }
}


/// Dziennik komunikacji CAT (ostatnie 60 wpisów) - osobno od CATClient, żeby wpisy nie odświeżały całego okna.
@MainActor
final class CATLogModel: ObservableObject {
    @Published fileprivate(set) var lines: [String] = []
}
