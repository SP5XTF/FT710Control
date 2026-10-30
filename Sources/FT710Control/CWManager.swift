import Foundation
import AppKit

/// CW: dekoder (dźwięk z radia) i nadawanie (klucz DTR/RTS na porcie Standard COM radia).
@MainActor
final class CWManager: ObservableObject {
    /// Tekst wpisywany do nadania - w menedżerze, żeby przełączenie zakładki go nie kasowało.
    @Published var outgoing = ""
    // MARK: Dekoder
    @Published var decoderEnabled: Bool {
        didSet { save("decoder", decoderEnabled); decoder.setPaused(!decoderEnabled); updateTap() }
    }
    @Published var useModel: Bool { didSet { save("model", useModel); configureModel() } }
    /// APF dekodera (100 Hz, tylko tor odczytu znaków).
    @Published var decoderAPF: Bool { didSet { save("decoderAPF", decoderAPF); decoder.setAPF(decoderAPF) } }
    @Published private(set) var text = ""
    @Published private(set) var provisional = ""
    @Published private(set) var pitch = 700.0
    @Published private(set) var wpm = 0.0
    @Published private(set) var snrDB = 0.0
    @Published private(set) var locked = false
    @Published private(set) var manualPitch: Double?

    // MARK: Nadawanie
    @Published var txWPM: Double { didSet { save("txWPM", txWPM) } }
    @Published var keyPort: String { didSet { save("keyPort", keyPort) } }
    @Published var keyLine: CWKeyer.Line { didSet { save("keyLine", keyLine.rawValue) } }
    /// Sposób nadawania: linia DTR/RTS drugiego portu albo wbudowany klucz radia przez CAT (KM/KY).
    @Published var method: TXMethod {
        didSet {
            save("method", method.rawValue)
            txMessage = nil                                         // komunikat dotyczył poprzedniej metody
            if !radioCheck.isEmpty { checkRadio() }                 // ocena PC KEYING zależy od metody
        }
    }
    /// Wynik sprawdzenia ustawień radia (PC KEYING, BK-IN, tryb).
    @Published private(set) var radioCheck: [RadioCheckItem] = []
    @Published private(set) var checkingRadio = false

    enum TXMethod: String, CaseIterable, Identifiable {
        case line, radioKeyer
        var id: String { rawValue }
        var name: String {
            self == .line ? L("Linia DTR/RTS (port CAT-2)") : L("Klucz radia (CAT)")
        }
    }

    struct RadioCheckItem: Identifiable {
        enum Status { case ok, problem, info }
        let id = UUID()
        let name: String
        let value: String
        let status: Status
        var ok: Bool { status != .problem }
    }

    private var radioKeyerTask: Task<Void, Never>?
    @Published var macros: [String] { didSet { UserDefaults.standard.set(macros, forKey: "cw.macros") } }
    @Published private(set) var sending = false
    @Published private(set) var sendProgress = 0.0
    @Published private(set) var sendingText = ""
    @Published private(set) var txMessage: String?

    static let defaultMacros = ["CQ CQ CQ DE {CALL} {CALL} K", "{CALL}", "TU 5NN", "QRZ? DE {CALL} K", "TU 73 DE {CALL} EE"]

    private let decoder = CWDecoder()
    private let keyer = CWKeyer()
    private weak var cat: CATClient?
    private weak var audio: AudioManager?

    /// Wyłączony dekoder - w ogóle nie dostaje dźwięku.
    private func updateTap() {
        guard let audio else { return }
        if decoderEnabled {
            audio.sampleTap.set("cw") { [decoder] samples, rate in decoder.append(samples, sampleRate: rate) }
        } else {
            audio.sampleTap.set("cw", nil)
        }
    }
    private weak var logbook: LogbookStore?
    private static let maxText = 6000

    init() {
        let d = UserDefaults.standard
        decoderEnabled = d.object(forKey: "cw.decoder") as? Bool ?? true
        useModel = d.object(forKey: "cw.model") as? Bool ?? true
        decoderAPF = d.object(forKey: "cw.decoderAPF") as? Bool ?? false
        txWPM = d.object(forKey: "cw.txWPM") as? Double ?? 20
        keyPort = d.string(forKey: "cw.keyPort") ?? ""
        keyLine = CWKeyer.Line(rawValue: d.string(forKey: "cw.keyLine") ?? "") ?? .dtr
        method = TXMethod(rawValue: d.string(forKey: "cw.method") ?? "") ?? .line
        let saved = d.stringArray(forKey: "cw.macros") ?? []
        macros = saved.count == 5 ? saved : Self.defaultMacros
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "cw." + key) }

    func attach(audio: AudioManager, cat: CATClient, logbook: LogbookStore) {
        guard self.cat == nil else { return }
        self.cat = cat
        self.logbook = logbook
        decoder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        decoder.setPaused(!decoderEnabled)
        decoder.setAPF(decoderAPF)
        configureModel()
        self.audio = audio
        updateTap()
        if keyPort.isEmpty { keyPort = Self.guessKeyPort(cat: cat) }
    }

    /// Model językowy: frazy QSO + Twój znak i znaki z dziennika (dekoder lepiej je rozpoznaje).
    private func configureModel() {
        var words: [String] = []
        if let logbook {
            words.append(logbook.myCall)
            words += logbook.qsos.prefix(2000).map { QRZClient.baseCall($0.call) }
        }
        decoder.configure(useModel: useModel, extraWords: Array(Set(words.filter { !$0.isEmpty })))
    }

    private func handle(_ event: CWDecoder.Event) {
        switch event {
        case .provisional(let word):
            provisional = word
        case .word(let word):
            text += word + " "
            if text.count > Self.maxText { text = String(text.suffix(Self.maxText)) }
            provisional = ""
        case .status(let p, let w, let snr, let isLocked):
            if abs(p - pitch) > 1 { pitch = p }
            if isLocked || manualPitch != nil { audio?.setAPFCenter(p) }   // APF w odsłuchu na tej samej stacji
            if abs(w - wpm) > 0.5 { wpm = w }
            if abs(snr - snrDB) > 0.5 { snrDB = snr }
            if isLocked != locked { locked = isLocked }
        }
    }

    func clearText() { text = ""; provisional = "" }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Kliknięcie w widmo: ustaw ton ręcznie; nil = automatyczne dostrajanie.
    func setPitch(_ hz: Double?) {
        manualPitch = hz
        decoder.lockPitch(hz)
        if let hz { audio?.setAPFCenter(hz) }
    }

    // MARK: - Nadawanie

    /// Port Standard COM (CAT-2): drugi port z pary, np. …C0 (CAT) → …C1 (klucz).
    static func guessKeyPort(cat: CATClient) -> String {
        let catPort = cat.selectedPort
        guard let last = catPort.last, last == "0" else { return "" }
        let candidate = String(catPort.dropLast()) + "1"
        return cat.ports.contains(candidate) ? candidate : ""
    }

    func expand(_ template: String) -> String {
        template.replacingOccurrences(of: "{CALL}", with: logbook?.myCall.uppercased() ?? "")
            .uppercased()
            .filter { Morse.table[$0] != nil || $0 == " " }
    }

    func send(_ raw: String, armed: Bool) {
        guard let cat else { return }
        let message = expand(raw).trimmingCharacters(in: .whitespaces)
        txMessage = nil
        guard !message.isEmpty else { return }
        guard armed, cat.isConnected else {
            txMessage = L("Nadawanie wymaga połączenia z radiem i zaznaczenia „Odblokuj TX”.")
            return
        }
        if method == .line {
            guard !keyPort.isEmpty else {
                txMessage = L("Wybierz port klucza (Standard COM / CAT-2 radia).")
                return
            }
            guard keyPort != cat.selectedPort else {
                txMessage = L("Port klucza musi być drugim portem radia (CAT-2), nie portem CAT.")
                return
            }
        }
        let duration = CWKeyer.duration(of: message, wpm: txWPM)
        guard duration + 1 <= cat.txTimeout else {
            txMessage = L("Tekst trwa {1} s, a limit nadawania to {2} s - skróć tekst albo zwiększ limit.",
                          Int(duration.rounded()), Int(cat.txTimeout))
            return
        }
        guard !sending else { return }
        if method == .radioKeyer {
            sendViaRadioKeyer(message, cat: cat)
            return
        }
        do {
            try keyer.open(path: keyPort, line: keyLine)
        } catch {
            txMessage = error.localizedDescription
            return
        }
        sending = true
        sendProgress = 0
        sendingText = message
        keyer.send(message, wpm: txWPM, progress: { [weak self] fraction in
            Task { @MainActor in self?.sendProgress = fraction }
        }, done: { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.sending = false
                self.sendProgress = 0
                switch outcome {
                case .completed: self.txMessage = L("Nadano: {1}", message)
                case .stopped: self.txMessage = L("Nadawanie zatrzymane.")
                case .failed(let reason): self.txMessage = reason
                }
            }
        })
    }

    func stop() {
        keyer.stop()
        if radioKeyerTask != nil {
            radioKeyerTask?.cancel()
            cat?.send("KY00;")                                       // natychmiastowy STOP klucza radia
        }
    }

    // MARK: - Klucz radia przez CAT (KM + KY, instrukcja CAT FT-710)

    /// Tekst w kawałkach do 50 znaków zapisywany do pamięci 5 klucza radia (KM5) i odtwarzany (KY05).
    /// Poprzednia zawartość pamięci 5, jej typ i prędkość klucza są odczytywane i przywracane po nadaniu.
    private func sendViaRadioKeyer(_ message: String, cat: CATClient) {
        let chunks = Self.chunks(message, limit: 50)
        let wpm = Int(txWPM.rounded())
        let total = max(CWKeyer.duration(of: message, wpm: txWPM), 0.1)
        sending = true
        sendProgress = 0
        sendingText = message
        radioKeyerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // kopia ustawień radia do przywrócenia
            let oldText = await cat.query("KM5;", expect: "KM5").map { String($0.dropFirst(3)) }
            let oldType = await cat.query("EX020210;", expect: "EX020210").map { String($0.dropFirst(8)) }
            let oldSpeed = await cat.query("KS;", expect: "KS").map { String($0.dropFirst(2)) }
            let oldKeyer = await cat.query("KR;", expect: "KR").map { String($0.dropFirst(2)) }
            cat.send("EX0202100;")                                   // pamięć 5 = TEXT
            cat.send(String(format: "KS%03d;", min(max(wpm, 4), 60)))
            cat.send("BI1;")                                         // BK-IN - inaczej radio nie nada
            cat.send("KR1;")                                         // klucz radia musi być włączony
            var elapsed = 0.0
            var cancelled = false
            var failure: String?
            for (index, chunk) in chunks.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                cat.send("KM5\(chunk);")
                // czy radio przyjęło tekst do pamięci 5?
                let stored = await cat.query("KM5;", expect: "KM5").map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                guard let stored, stored == chunk else {
                    failure = stored == nil
                        ? L("Radio nie odpowiada na odczyt pamięci klucza (KM) - sprawdź połączenie CAT.")
                        : L("Radio nie zapisało tekstu w pamięci 5 klucza (odczytano: „{1}”).", stored ?? "")
                    break
                }
                cat.send("KY05;")
                if index == 0 {
                    // czy radio faktycznie nadaje? (RI: P4 = 1 → TX)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let info = await cat.query("RI0;", expect: "RI0"), info.count >= 6 {
                        let characters = Array(info)
                        let txState = characters[5]                  // RI0 P2 P3 P4 …  → indeks 5 = P4
                        if txState == "2" {
                            failure = L("Radio odmawia nadawania (TX INHIBIT w menu radia).")
                        } else if txState != "1" {
                            let keyer = await cat.query("KR;", expect: "KR")
                            let keyerType = await cat.query("EX020201;", expect: "EX020201").map { String($0.dropFirst(8)) }
                            failure = L("Radio nie zaczęło nadawać. Klucz radia: {1}, typ klucza: {2}. Sprawdź „Sprawdź radio” i ustawienia KEYER w radiu.",
                                        keyer?.hasSuffix("1") == true ? "ON" : "OFF",
                                        Self.keyerTypes[keyerType ?? ""] ?? "?")
                            cat.send("KY00;")
                        }
                    }
                    if failure != nil { break }
                }
                let length = CWKeyer.duration(of: chunk, wpm: Double(wpm)) + 0.6     // + zapas na start i BK-IN
                let start = Date()
                while Date().timeIntervalSince(start) < length {
                    if Task.isCancelled { cancelled = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.sendProgress = min((elapsed + Date().timeIntervalSince(start)) / total, 1)
                }
                elapsed += length
                if cancelled { break }
            }
            if cancelled { cat.send("KY00;") }
            // przywrócenie pamięci 5, jej typu, prędkości i stanu klucza
            if let oldText { cat.send("KM5\(oldText);") }
            if let oldType, !oldType.isEmpty { cat.send("EX020210\(oldType);") }
            if let oldSpeed, oldSpeed.count == 3 { cat.send("KS\(oldSpeed);") }
            if let oldKeyer, oldKeyer == "0" { cat.send("KR0;") }
            self.radioKeyerTask = nil
            self.sending = false
            self.sendProgress = 0
            self.txMessage = failure ?? (cancelled ? L("Nadawanie zatrzymane.") : L("Nadano: {1}", message))
        }
    }

    static let keyerTypes = ["0": "OFF", "1": "BUG", "2": "ELEKEY-A", "3": "ELEKEY-B", "4": "ELEKEY-Y", "5": "ACS"]


    /// Podział na kawałki do `limit` znaków na granicach słów.
    static func chunks(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let piece = String(word.prefix(limit))
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Sprawdzenie ustawień radia (CAT)

    func checkRadio() {
        guard let cat, cat.isConnected, !checkingRadio else { return }
        checkingRadio = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var items: [RadioCheckItem] = []
            let names = ["0": "OFF", "1": "RTS", "2": "DTR", "3": "DAKY"]
            if let answer = await cat.query("EX020115;", expect: "EX020115") {
                let value = String(answer.dropFirst(8))
                let shown = names[value] ?? value
                if self.method == .radioKeyer {
                    // klucz radia przez CAT nie używa PC KEYING - informacja, nie ocena
                    items.append(RadioCheckItem(name: "PC KEYING", value: L("{1} – niepotrzebne przy kluczu radia", shown), status: .info))
                } else {
                    let expected = self.keyLine == .dtr ? "2" : "1"
                    items.append(RadioCheckItem(name: "PC KEYING", value: shown, status: value == expected ? .ok : .problem))
                }
            } else {
                items.append(RadioCheckItem(name: "PC KEYING", value: L("brak odpowiedzi"),
                                            status: self.method == .radioKeyer ? .info : .problem))
            }
            if let answer = await cat.query("BI;", expect: "BI") {
                let on = answer.hasSuffix("1")
                items.append(RadioCheckItem(name: "BK-IN", value: on ? "ON" : "OFF", status: on ? .ok : .problem))
            }
            let isCW = cat.modeCode == "3" || cat.modeCode == "7"
            items.append(RadioCheckItem(name: L("Tryb"), value: cat.modeName, status: isCW ? .ok : .problem))
            if self.method == .radioKeyer {
                // klucz radia odtwarza pamięci tylko, gdy jest włączony
                if let answer = await cat.query("KR;", expect: "KR") {
                    let on = answer.hasSuffix("1")
                    items.append(RadioCheckItem(name: "KEYER", value: on ? "ON" : "OFF", status: on ? .ok : .problem))
                }
                if let answer = await cat.query("EX020201;", expect: "EX020201") {
                    let type = String(answer.dropFirst(8))
                    let name = Self.keyerTypes[type] ?? type
                    items.append(RadioCheckItem(name: L("Typ klucza"),
                                                value: type == "0" ? L("{1} – ustaw w radiu typ klucza (np. ELEKEY-B)", name) : name,
                                                status: type == "0" ? .problem : .ok))
                }
            }
            self.radioCheck = items
            self.checkingRadio = false
        }
    }

    /// Ustawia w radiu: PC KEYING zgodnie z wybraną linią, BK-IN i tryb CW.
    func fixRadio() {
        guard let cat, cat.isConnected else { return }
        if method == .line { cat.send(keyLine == .dtr ? "EX0201152;" : "EX0201151;") }
        if method == .radioKeyer { cat.send("KR1;") }              // typ klucza zostaje - to ustawienie użytkownika
        cat.send("BI1;")
        if !(cat.modeCode == "3" || cat.modeCode == "7") { cat.setMode("3") }   // CW-U na aktywnym VFO
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.checkRadio()
        }
    }

    /// Zgoda na TX cofnięta albo rozłączenie - klucz natychmiast zwolniony, port zamknięty.
    func shutdownTX() {
        keyer.stop()
        keyer.close()
        if radioKeyerTask != nil {
            radioKeyerTask?.cancel()
            cat?.send("KY00;")
        }
    }
}

/// Trzyma moduł CW bez publikowania zmian - okno nie przerysowuje się przy każdym znaku.
@MainActor
final class CWHolder: ObservableObject {
    let manager = CWManager()
}
