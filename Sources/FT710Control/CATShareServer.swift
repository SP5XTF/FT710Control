import Foundation
import Network

/// Serwer zgodny z rigctld (Hamlib „NET rigctl", domyślnie 127.0.0.1:4532).
/// WSJT-X, JTDX i programy do logowania sterują radiem przez tę aplikację,
/// która pozostaje jedynym właścicielem portu szeregowego FT-710.
///
/// Obsługiwany podzbiór: częstotliwość VFO A, tryb, PTT, VFO, split (tylko wyłączony).
/// Split w WSJT-X: „Fake It” (najprostsze) albo „Rig” (split radia przez komendę ST).
@MainActor
final class CATShareServer: ObservableObject {
    static let port: UInt16 = 4532

    @Published var enabled = false { didSet { enabled ? start() : stop() } }
    /// PTT z zewnętrznych programów wymaga osobnej zgody (jak „Odblokuj nadawanie" dla przycisku).
    @Published var allowPTT = UserDefaults.standard.bool(forKey: "catShare.allowPTT") {
        didSet {
            UserDefaults.standard.set(allowPTT, forKey: "catShare.allowPTT")
            if !allowPTT { releaseAllPTT() }
        }
    }

    /// Przełącznik w oknie: zapamiętuje wybór użytkownika (nie chwilowy stan serwera - stop() przy zamykaniu
    /// programu albo błąd startu go nie nadpisują) i po ponownym uruchomieniu serwer włącza się sam (attach).
    var enabledByUser: Bool {
        get { enabled }
        set {
            UserDefaults.standard.set(newValue, forKey: "catShare.enabled")
            enabled = newValue
        }
    }
    @Published private(set) var status = L("Wyłączony")
    @Published private(set) var clients = 0
    @Published private(set) var log: [String] = []

    private weak var cat: CATClient?
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let queue = DispatchQueue(label: "ft710.catshare")

    private final class Session {
        let connection: NWConnection
        var buffer = ""
        var pttOn = false
        var warnedNative = false
        init(connection: NWConnection) { self.connection = connection }
    }

    func attach(_ cat: CATClient) {
        self.cat = cat
        // przywrócenie stanu z poprzedniego uruchomienia
        if UserDefaults.standard.bool(forKey: "catShare.enabled"), !enabled { enabled = true }
    }

    // MARK: - Nasłuch

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback      // tylko ten Mac, nic z sieci
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener = l
            status = L("Uruchamianie…")
            l.start(queue: queue)
        } catch {
            listener = nil
            enabled = false     // najpierw wyłącz (stop() ustawia status), potem pokaż błąd
            status = L("Błąd: {1}", error.localizedDescription)
        }
    }

    func stop() {
        releaseAllPTT()
        for session in sessions.values { session.connection.cancel() }
        sessions.removeAll()
        clients = 0
        listener?.cancel()
        listener = nil
        if enabled { enabled = false }
        status = L("Wyłączony")
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = L("Nasłuch 127.0.0.1:{1}", Self.port)
        case .failed(let error):
            // Najczęściej: port zajęty (np. działa rigctld albo inna instancja).
            listener?.cancel()
            listener = nil
            if enabled { enabled = false }
            status = L("Błąd: {1} - czy port {2} nie jest zajęty?", error.localizedDescription, Self.port)
        default:
            break
        }
    }

    // MARK: - Połączenia

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        clients = sessions.count
        appendLog(L("+ klient {1}", connection.endpoint))

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: ObjectIdentifier) {
        guard let session = sessions[id] else { return }
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.handle(data, id: id) }
                if isComplete || error != nil {
                    self.drop(id)
                } else {
                    self.receive(id)    // następny odczyt dopiero po odpowiedzi - zachowana kolejność
                }
            }
        }
    }

    /// Rozłączenie klienta zawsze zwalnia PTT, które ten klient włączył.
    private func drop(_ id: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if session.pttOn {
            cat?.ptt(false)
            appendLog(L("! klient rozłączony podczas nadawania - TX0"))
        }
        session.connection.cancel()
        clients = sessions.count
        appendLog(L("− klient rozłączony"))
    }

    private func releaseAllPTT() {
        for session in sessions.values where session.pttOn {
            session.pttOn = false
            cat?.ptt(false)
        }
    }

    private func handle(_ data: Data, id: ObjectIdentifier) {
        guard let session = sessions[id] else { return }
        session.buffer += String(decoding: data, as: UTF8.self)

        // Natywne komendy CAT Yaesu („FA;”, „MD0;” - bez końca linii): program ma ustawiony model radia
        // „Yaesu FT-710” zamiast „Hamlib NET rigctl”. Wskazówka w logu i zamknięcie połączenia.
        if !session.warnedNative, !session.buffer.contains(where: { $0.isNewline }),
           let sample = Self.nativeYaesuCommand(in: session.buffer) {
            session.warnedNative = true
            appendLog(L("Klient wysyła natywne komendy CAT Yaesu ({1}) - w programie wybierz model radia „Hamlib NET rigctl” zamiast „Yaesu FT-710”.", sample))
            session.connection.cancel()
            return
        }

        var reply = ""
        var quit = false
        // isNewline obejmuje też "\r\n", które Swift traktuje jako jeden znak
        while let newline = session.buffer.firstIndex(where: { $0.isNewline }) {
            let line = session.buffer[..<newline].trimmingCharacters(in: .whitespaces)
            session.buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            if line == "q" || line == "Q" || line == "\\quit" { quit = true; break }
            reply += respond(to: line, session: session)
        }
        if session.buffer.count > 1024 { session.buffer = "" }

        let connection = session.connection
        if !reply.isEmpty || quit {
            connection.send(content: reply.isEmpty ? nil : Data(reply.utf8),
                            completion: .contentProcessed { _ in if quit { connection.cancel() } })
        }
    }

    /// Pierwsza komenda w stylu natywnego CAT Yaesu: dwie wielkie litery, parametry, średnik.
    private static func nativeYaesuCommand(in text: String) -> String? {
        guard let range = text.range(of: "^[A-Z]{2}[0-9A-Z+\\-]{0,40};", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: - Protokół rigctld

    private static let aliases: [String: String] = [
        "\\get_freq": "f", "\\set_freq": "F",
        "\\get_mode": "m", "\\set_mode": "M",
        "\\get_vfo": "v", "\\set_vfo": "V",
        "\\get_ptt": "t", "\\set_ptt": "T",
        "\\get_split_vfo": "s", "\\set_split_vfo": "S",
        "\\get_split_freq": "i", "\\set_split_freq": "I",
        "\\get_split_mode": "x", "\\set_split_mode": "X"
    ]

    /// Kody trybów FT-710 (komenda MD) <-> nazwy trybów Hamlib.
    private static let toHamlib: [String: String] = [
        "1": "LSB", "2": "USB", "3": "CW", "7": "CWR", "4": "FM", "B": "FM",
        "5": "AM", "D": "AM", "6": "RTTY", "9": "RTTYR",
        "8": "PKTLSB", "C": "PKTUSB", "A": "PKTFM"
    ]
    private static let fromHamlib: [String: String] = [
        "LSB": "1", "USB": "2", "CW": "3", "CWR": "7", "FM": "4", "AM": "5",
        "RTTY": "6", "RTTYR": "9", "PKTLSB": "8", "PKTUSB": "C", "PKTFM": "A"
    ]

    private static let longNames: [String: String] = [
        "f": "get_freq", "F": "set_freq", "m": "get_mode", "M": "set_mode", "v": "get_vfo", "V": "set_vfo",
        "t": "get_ptt", "T": "set_ptt", "s": "get_split_vfo", "S": "set_split_vfo",
        "i": "get_split_freq", "I": "set_split_freq", "x": "get_split_mode", "X": "set_split_mode"
    ]
    private static let fieldLabels: [String: [String]] = [
        "f": ["Frequency"], "m": ["Mode", "Passband"], "v": ["VFO"], "t": ["PTT"], "s": ["Split", "TX VFO"],
        "i": ["TX Frequency"], "x": ["TX Mode", "TX Passband"],
        "\\get_lock_mode": ["Locked mode"], "\\get_powerstat": ["Power Status"], "\\chk_vfo": ["ChkVFO"]
    ]

    /// Odpowiedź podstawowa -> rozszerzona: „get_freq:”, „Frequency: 14074000”, „RPRT 0” (wg dokumentacji Hamlib).
    private static func extended(command: String, raw: String, separator: String) -> String {
        let tokens = command.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return raw }
        let cmd = aliases[first] ?? first
        let name = longNames[cmd] ?? (cmd.hasPrefix("\\") ? String(cmd.dropFirst()) : cmd)
        let args = tokens.dropFirst().joined(separator: " ")
        var parts = [args.isEmpty ? "\(name):" : "\(name): \(args)"]
        let lines = raw.split(separator: "\n").map(String.init)
        if raw.hasPrefix("RPRT") {
            parts.append(lines.first ?? "RPRT 0")                    // wynik ustawienia albo błąd
        } else {
            let labels = fieldLabels[cmd] ?? []
            for (i, value) in lines.enumerated() { parts.append(i < labels.count ? "\(labels[i]): \(value)" : value) }
            parts.append("RPRT 0")
        }
        return parts.joined(separator: separator) + "\n"
    }

    private static let ok = "RPRT 0\n"
    private static let invalid = "RPRT -1\n"       // RIG_EINVAL
    private static let notImplemented = "RPRT -4\n" // RIG_ENIMPL
    private static let ioError = "RPRT -6\n"        // RIG_EIO - radio nie jest połączone
    private static let rejected = "RPRT -9\n"       // RIG_ERJCTED - PTT niedozwolone

    private func respond(to line: String, session: Session) -> String {
        // Rozszerzony format rigctld: „+f” (pola w liniach) albo „;f”, „|f”, „,f” (pola rozdzielone tym znakiem)
        if let marker = line.first, "+;|,".contains(marker), line.count > 1 {
            let inner = String(line.dropFirst())
            return Self.extended(command: inner, raw: respond(to: inner, session: session),
                                 separator: marker == "+" ? "\n" : String(marker))
        }
        let tokens = line.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return "" }
        let command = Self.aliases[first] ?? first
        let arg = tokens.count > 1 ? tokens[1] : nil

        // Te odpowiedzi nie wymagają połączenia z radiem (otwarcie połączenia przez Hamlib).
        switch command {
        case "\\chk_vfo": return "0\n"
        case "\\dump_state": return Self.dumpState
        case "\\get_lock_mode":                 // Hamlib 4.6+: blokada sterowania - u nas zawsze wyłączona
            return "0\n"
        case "\\set_lock_mode":
            return Self.ok
        case "\\get_powerstat": return "1\n"
        default: break
        }

        guard let cat, cat.isConnected else { return Self.ioError }

        switch command {
        case "f":
            return "\(cat.activeFreq)\n"
        case "F":
            guard let value = arg.flatMap({ Double($0) }), value > 0 else { return Self.invalid }
            let hz = Int(value.rounded())
            if hz != cat.activeFreq { cat.setActiveFrequency(hz) }
            return Self.ok
        case "m", "x":
            let name = Self.toHamlib[cat.modeCode] ?? "USB"
            return "\(name)\n\(Self.passband(for: name))\n"
        case "M":
            guard let name = arg?.uppercased(), let code = Self.fromHamlib[name] else { return Self.invalid }
            if code != cat.modeCode { cat.setMode(code) }
            return Self.ok     // szerokość filtra (drugi argument) jest ignorowana
        case "X":
            return Self.ok
        case "v":
            return "VFOA\n"
        case "V":
            return Self.ok
        case "t":
            return (cat.transmitting || session.pttOn) ? "1\n" : "0\n"
        case "T":
            let on = (arg.flatMap({ Int($0) }) ?? 0) != 0
            if on {
                guard allowPTT else {
                    appendLog(L("! PTT odrzucone - włącz „Pozwól na PTT”"))
                    return Self.rejected
                }
                session.pttOn = true
                cat.ptt(true)
            } else {
                session.pttOn = false
                cat.ptt(false)
            }
            return Self.ok
        case "s":
            // Split radia: odbiór na VFO-A, nadawanie na VFO-B (komenda ST).
            return (cat.value(.split) ?? 0) != 0 ? "1\nVFOB\n" : "0\nVFOA\n"
        case "S":
            let on = arg == "1"
            guard on || arg == "0" else { return Self.invalid }
            guard cat.isAvailable(.split) else { return on ? Self.notImplemented : Self.ok }
            cat.set(.split, on ? 1 : 0)          // drugi argument (VFO nadawania) to zawsze VFO-B
            return Self.ok
        case "i":
            return "\(cat.freqB)\n"
        case "I":
            guard let value = arg.flatMap({ Double($0) }), value > 0 else { return Self.invalid }
            cat.setFrequency(vfo: "B", hz: Int(value.rounded()))
            return Self.ok
        default:
            appendLog(L("? nieobsługiwane: {1}", line))
            return Self.notImplemented
        }
    }

    private static func passband(for mode: String) -> Int {
        switch mode {
        case "CW", "CWR": return 500
        case "AM": return 6000
        case "FM", "PKTFM": return 12000
        default: return 3000
        }
    }

    /// Opis możliwości „radia" dla Hamlib (protokół w wersji 0, jak w innych serwerach zgodnych z rigctld).
    /// Maska trybów 0x1dbf = AM, CW, USB, LSB, RTTY, FM, CWR, RTTYR, PKTLSB, PKTUSB, PKTFM.
    private static let dumpState = [
        "0",                                                        // wersja protokołu
        "2",                                                        // model (NET rigctl)
        "2",                                                        // region ITU
        "30000.000000 75000000.000000 0x1dbf -1 -1 0x3 0x1",        // zakres RX
        "0 0 0 0 0 0 0",                                            // koniec zakresów RX
        "0 0 0 0 0 0 0",                                            // koniec zakresów TX
        "0x1dbf 1",                                                 // krok strojenia
        "0 0",
        "0x1dbf 3000",                                              // filtry
        "0x82 500",
        "0 0",
        "0", "0", "0", "0",                                         // max RIT, XIT, IF shift, announces
        "",                                                         // preamp
        "",                                                         // attenuator
        "0x0", "0x0", "0x0", "0x0", "0x0", "0x0"                    // funkcje / poziomy / parametry
    ].joined(separator: "\n") + "\n"

    private func appendLog(_ line: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(time)  \(line)")
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }
}
