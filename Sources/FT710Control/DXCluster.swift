import Foundation
import Network

/// Jeden spot z klastra.
struct DXSpot: Identifiable, Equatable {
    enum Mode: String { case cw = "CW", ssb = "SSB", digi = "DIGI" }

    let id = UUID()
    let received: Date
    let spotter: String
    let frequencyHz: Int
    let call: String
    let comment: String
    let timeUTC: String          // „1234Z” z linii klastra
    let mode: Mode
    let digiMode: String?        // FT8 / FT4 / … gdy rozpoznany w komentarzu

    var band: String { Bands.name(for: frequencyHz) ?? "" }
    var kHzText: String { String(format: "%.1f", Double(frequencyHz) / 1000) }

    /// Częstotliwość do ustawienia na VFO. W trybach cyfrowych spot podaje częstotliwość sygnału,
    /// a radio trzeba ustawić na częstotliwość „dial” (standard FT8/FT4 albo sygnał − 1500 Hz).
    var tuneHz: Int {
        guard mode == .digi else { return frequencyHz }
        let table = digiMode == "FT4" ? DXBandPlan.ft4Dials : DXBandPlan.ft8Dials
        if let dial = table.first(where: { frequencyHz >= $0 && frequencyHz - $0 <= 3_500 }) { return dial }
        return frequencyHz - 1_500
    }

    /// Kod trybu radia (MD): CW-U, DATA-U, LSB poniżej 10 MHz, USB powyżej.
    var radioModeCode: String {
        switch mode {
        case .cw: return "3"
        case .digi: return "C"
        case .ssb: return frequencyHz < 10_000_000 ? "1" : "2"
        }
    }
}

/// Uproszczony plan pasm (IARU R1) do odgadnięcia trybu spotu bez opisu w komentarzu.
enum DXBandPlan {
    static let ft8Dials = [1_840_000, 3_573_000, 5_357_000, 7_074_000, 10_136_000, 14_074_000,
                           18_100_000, 21_074_000, 24_915_000, 28_074_000, 50_313_000, 70_154_000]
    static let ft4Dials = [3_575_000, 7_047_500, 10_140_000, 14_080_000, 18_104_000, 21_140_000,
                           24_919_000, 28_180_000, 50_318_000]
    static let cwSegments: [ClosedRange<Int>] = [
        1_810_000...1_838_000, 3_500_000...3_570_000, 7_000_000...7_040_000, 10_100_000...10_130_000,
        14_000_000...14_070_000, 18_068_000...18_095_000, 21_000_000...21_070_000,
        24_890_000...24_915_000, 28_000_000...28_070_000, 50_000_000...50_100_000
    ]

    static func guessMode(hz: Int, comment: String) -> (DXSpot.Mode, String?) {
        let text = " " + comment.uppercased() + " "
        for digi in ["FT8", "FT4", "JS8", "RTTY", "PSK31", "PSK", "MSK144", "Q65", "JT65"] where text.contains(digi) {
            return (.digi, digi)
        }
        if text.contains(" CW ") || text.contains("WPM") { return (.cw, nil) }
        if text.contains(" SSB ") || text.contains(" USB ") || text.contains(" LSB ") { return (.ssb, nil) }
        if ft8Dials.contains(where: { hz >= $0 && hz - $0 <= 3_000 }) { return (.digi, "FT8") }
        if cwSegments.contains(where: { $0.contains(hz) }) { return (.cw, nil) }
        return (.ssb, nil)
    }
}

/// Klient klastra DX (telnet: DXSpider, AR-Cluster, CC Cluster, Reverse Beacon Network).
@MainActor
final class DXClusterClient: ObservableObject {
    enum State: Equatable { case disconnected, connecting, connected }

    /// Przykładowe publiczne węzły (adresy węzłów się zmieniają - w razie problemu wpisz inny).
    static let presets: [(name: String, host: String, port: Int)] = [
        ("SP – dxcluster.pl (DXSpider)", "dxcluster.pl", 7300),
        ("VE7CC (CC Cluster)", "dxc.ve7cc.net", 23),
        ("GB7DJK (DXSpider)", "gb7djk.dxcluster.net", 7300),
        ("NC7J (AR-Cluster)", "dxc.nc7j.com", 7373),
        ("RBN – CW / RTTY", "telnet.reversebeacon.net", 7000),
        ("RBN – FT8 / FT4", "telnet.reversebeacon.net", 7001)
    ]

    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "clusterHost") } }
    @Published var port: Int { didSet { UserDefaults.standard.set(port, forKey: "clusterPort") } }
    @Published var login: String { didSet { UserDefaults.standard.set(login, forKey: "clusterLogin") } }
    @Published var autoConnect: Bool { didSet { UserDefaults.standard.set(autoConnect, forKey: "clusterAutoConnect") } }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var status = L("Rozłączony")
    @Published private(set) var spots: [DXSpot] = []          // najnowsze pierwsze
    @Published private(set) var console: [String] = []
    /// Treść pola komendy (np. przygotowany spot z dziennika - do sprawdzenia i wysłania).
    @Published var draftCommand = ""

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ft710.dxcluster")
    private var textBuffer = ""
    private var loginSent = false
    private var loginCall = ""
    private var userDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var loginFallback: Task<Void, Never>?
    private var partialFlush: Task<Void, Never>?
    private var passwordSent = false
    private var receivedBytes = 0
    static let keychainService = "FT710Control.cluster"
    /// Po zalogowaniu pobierz ostatnie spoty (sh/dx 30), żeby tabela nie była pusta.
    @Published var fetchRecent: Bool { didSet { UserDefaults.standard.set(fetchRecent, forKey: "clusterFetchRecent") } }
    @Published private(set) var hasPassword: Bool

    func setPassword(_ value: String) {
        if value.isEmpty {
            Keychain.delete(service: Self.keychainService, account: "password")
            hasPassword = false
        } else {
            Keychain.set(value, service: Self.keychainService, account: "password")
            hasPassword = true
        }
    }

    private static let maxSpots = 500
    private static let spotPattern = try! NSRegularExpression(
        pattern: #"^DX de\s+([^:\s]+?):?\s+(\d+(?:\.\d+)?)\s+(\S+)\s+(.*?)\s*(\d{4})Z"#,
        options: [.caseInsensitive])

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "clusterHost") ?? "dxcluster.pl"
        let savedPort = defaults.integer(forKey: "clusterPort")
        port = (1...65535).contains(savedPort) ? savedPort : 7300
        login = defaults.string(forKey: "clusterLogin") ?? ""
        autoConnect = defaults.bool(forKey: "clusterAutoConnect")
        fetchRecent = defaults.object(forKey: "clusterFetchRecent") as? Bool ?? true
        hasPassword = Keychain.exists(service: Self.keychainService, account: "password")
    }

    // MARK: - Połączenie

    /// `fallbackCall`: znak z dziennika, gdy pole logowania jest puste.
    func connect(fallbackCall: String) {
        let call = (login.isEmpty ? fallbackCall : login).trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else {
            status = L("Podaj znak do logowania (albo „Mój znak” w oknie dziennika)")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else {
            status = L("Nieprawidłowy adres węzła")
            return
        }
        disconnectSocket()
        userDisconnect = false
        reconnectTask?.cancel()
        loginCall = call
        loginSent = false
        passwordSent = false
        receivedBytes = 0
        textBuffer = ""
        state = .connecting
        status = L("Łączenie z {1}:{2}…", host, port)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.connectionChanged(newState) }
        }
        connection = conn
        conn.start(queue: queue)
        receive(on: conn)
    }

    func disconnect() {
        userDisconnect = true
        reconnectTask?.cancel()
        if state == .connected { send("bye", echo: false) }
        disconnectSocket()
        state = .disconnected
        status = L("Rozłączony")
    }

    private func disconnectSocket() {
        loginFallback?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func connectionChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            status = L("Połączono z {1}", host)
            appendConsole(L("— połączono z {1}:{2} —", host, port))
            // Część węzłów nie kończy monitu logowania znakiem nowej linii - po 4 s logujemy się i tak.
            loginFallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, !self.loginSent, self.state == .connected else { return }
                self.sendLogin()
            }
        case .failed(let error), .waiting(let error):
            connectionLost(L("Błąd: {1}", error.localizedDescription))
        case .cancelled:
            if !userDisconnect { connectionLost(L("Połączenie zamknięte przez węzeł")) }
        default:
            break
        }
    }

    private func connectionLost(_ message: String) {
        disconnectSocket()
        state = .disconnected
        status = message
        appendConsole("— " + message + " —")
        guard autoConnect, !userDisconnect else { return }
        status = message + " · " + L("ponowne łączenie za 30 s")
        let call = loginCall
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled, !self.userDisconnect else { return }
            self.connect(fallbackCall: call)
        }
    }

    /// Komenda do węzła (np. „sh/dx 20”, „set/filter”).
    func send(_ command: String, echo: Bool = true) {
        guard let connection, state == .connected else { return }
        if echo { appendConsole("> " + command) }
        connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private func sendLogin() {
        guard !loginSent else { return }
        loginSent = true
        loginFallback?.cancel()
        send(loginCall, echo: false)
        appendConsole(L("> (logowanie jako {1})", loginCall))
        guard fetchRecent else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)        // po powitaniu węzła
            guard let self, self.state == .connected else { return }
            self.send("sh/dx 30")
        }
    }

    // MARK: - Odbiór

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty { self.process(Array(data), on: conn) }
                if complete || error != nil {
                    if !self.userDisconnect { self.connectionLost(L("Połączenie zamknięte przez węzeł")) }
                } else {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func process(_ bytes: [UInt8], on conn: NWConnection) {
        // Negocjacja telnet (IAC): odmawiamy wszystkich opcji, z danych zostaje sam tekst.
        var text: [UInt8] = []
        var reply: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard byte == 255, i + 1 < bytes.count else {
                if byte != 255 { text.append(byte) }
                i += 1
                continue
            }
            let command = bytes[i + 1]
            switch command {
            case 251, 252, 253, 254:                          // WILL, WONT, DO, DONT + opcja
                if i + 2 < bytes.count {
                    let option = bytes[i + 2]
                    if command == 253 { reply += [255, 252, option] }   // DO -> WONT
                    if command == 251 { reply += [255, 254, option] }   // WILL -> DONT
                }
                i += 3
            case 250:                                         // SB … IAC SE - pomijamy
                var j = i + 2
                while j + 1 < bytes.count, !(bytes[j] == 255 && bytes[j + 1] == 240) { j += 1 }
                i = j + 2
            case 255:
                text.append(255)
                i += 2
            default:
                i += 2
            }
        }
        if !reply.isEmpty { conn.send(content: Data(reply), completion: .contentProcessed { _ in }) }

        receivedBytes += bytes.count
        // Koniec linii na poziomie bajtów: \r zamieniamy na \n (puste linie z \r\n są pomijane).
        // Na tekście tak się nie da - w Swift "\r\n" to jeden znak i firstIndex(of: "\n") go nie znajduje.
        let cleaned = text.compactMap { byte -> UInt8? in
            if byte == 13 { return 10 }
            return byte == 10 || byte >= 32 ? byte : nil
        }
        textBuffer += String(decoding: cleaned, as: UTF8.self)
        while let newline = textBuffer.firstIndex(of: "\n") {
            let line = textBuffer[..<newline].trimmingCharacters(in: .whitespaces)
            textBuffer.removeSubrange(...newline)
            if !line.isEmpty { handle(line) }
        }
        handlePrompt()
        if textBuffer.count > 4_096 { textBuffer = "" }
        // Niepełna linia (monit węzła) - pokaż ją w konsoli po chwili ciszy.
        partialFlush?.cancel()
        if !textBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            partialFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !Task.isCancelled else { return }
                let pending = self.textBuffer.trimmingCharacters(in: .whitespaces)
                guard !pending.isEmpty else { return }
                self.textBuffer = ""
                self.handle(pending)
            }
        }
        status = L("Połączono z {1} · odebrano {2}", host,
                   ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file))
    }

    /// Monity bez nowej linii: logowanie (znak) i hasło.
    private func handlePrompt() {
        let prompt = textBuffer.lowercased()
        if !loginSent, prompt.contains("login") || prompt.contains("call") || prompt.hasSuffix(":") {
            if !textBuffer.trimmingCharacters(in: .whitespaces).isEmpty { appendConsole(textBuffer) }
            textBuffer = ""
            sendLogin()
        } else if loginSent, !passwordSent, prompt.contains("password") {
            appendConsole(textBuffer)
            textBuffer = ""
            sendPassword()
        }
    }

    private func sendPassword() {
        passwordSent = true
        if let password = Keychain.get(service: Self.keychainService, account: "password"), !password.isEmpty {
            send(password, echo: false)
            appendConsole(L("> (hasło wysłane)"))
        } else {
            status = L("Węzeł pyta o hasło - wpisz je w polu „Hasło” i połącz ponownie, albo wybierz inny węzeł.")
            appendConsole(L("— węzeł wymaga hasła —"))
        }
    }

    private func handle(_ line: String) {
        if !loginSent, line.lowercased().contains("login") || line.lowercased().contains("your call") {
            appendConsole(line)
            sendLogin()
            return
        }
        if loginSent, !passwordSent, line.lowercased().contains("password") {
            appendConsole(line)
            sendPassword()
            return
        }
        if let spot = Self.parseSpot(line) {
            add(spot)
        } else {
            appendConsole(line)
        }
    }

    /// Odpowiedź na „sh/dx”: „ 14025.0  JA1ABC  12-Oct-2026 1720Z  komentarz  <SP5XX>”.
    private static let showDXPattern = try! NSRegularExpression(
        pattern: #"^\s*(\d+(?:\.\d+)?)\s+(\S+)\s+\d{1,2}-[A-Za-z]{3}-\d{4}\s+(\d{4})Z\s*(.*?)\s*<([^>]+)>\s*$"#)

    static func parseShowDX(_ line: String) -> DXSpot? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = showDXPattern.firstMatch(in: line, range: range), m.numberOfRanges == 6 else { return nil }
        func group(_ n: Int) -> String {
            guard let r = Range(m.range(at: n), in: line) else { return "" }
            return String(line[r])
        }
        guard let kHz = Double(group(1)), kHz > 100 else { return nil }
        let hz = Int((kHz * 1000).rounded())
        let comment = group(4).trimmingCharacters(in: .whitespaces)
        let guess = DXBandPlan.guessMode(hz: hz, comment: comment)
        return DXSpot(received: Date(), spotter: group(5).uppercased(), frequencyHz: hz,
                      call: group(2).uppercased(), comment: comment, timeUTC: group(3) + "Z",
                      mode: guess.0, digiMode: guess.1)
    }

    static func parseSpot(_ line: String) -> DXSpot? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = spotPattern.firstMatch(in: line, range: range), m.numberOfRanges == 6 else {
            return parseShowDX(line)
        }
        func group(_ n: Int) -> String {
            guard let r = Range(m.range(at: n), in: line) else { return "" }
            return String(line[r])
        }
        guard let kHz = Double(group(2)), kHz > 100 else { return nil }
        let hz = Int((kHz * 1000).rounded())
        let comment = group(4).trimmingCharacters(in: .whitespaces)
        let guess = DXBandPlan.guessMode(hz: hz, comment: comment)
        return DXSpot(received: Date(), spotter: group(1).uppercased(), frequencyHz: hz,
                      call: group(3).uppercased(), comment: comment, timeUTC: group(5) + "Z",
                      mode: guess.0, digiMode: guess.1)
    }

    /// Ten sam znak na tej samej częstotliwości (±1 kHz) w ciągu 10 minut zastępuje poprzedni spot.
    private func add(_ spot: DXSpot) {
        spots.removeAll {
            $0.call == spot.call && abs($0.frequencyHz - spot.frequencyHz) <= 1_000
                && spot.received.timeIntervalSince($0.received) < 600
        }
        spots.insert(spot, at: 0)
        if spots.count > Self.maxSpots { spots.removeLast(spots.count - Self.maxSpots) }
    }

    func clearSpots() { spots.removeAll() }

    /// Spoty do pokazania na skopie: w zakresie, z ostatnich 30 minut, najnowszy na znak.
    func scopeSpots(lowHz: Int, highHz: Int, limit: Int = 40) -> [DXSpot] {
        guard highHz > lowHz else { return [] }
        let cutoff = Date().addingTimeInterval(-1_800)
        var seen = Set<String>()
        var result: [DXSpot] = []
        for spot in spots where spot.received > cutoff && spot.frequencyHz >= lowHz && spot.frequencyHz <= highHz {
            if seen.insert(spot.call).inserted { result.append(spot) }
            if result.count >= limit { break }
        }
        return result
    }

    private func appendConsole(_ line: String) {
        console.append(line)
        if console.count > 300 { console.removeFirst(console.count - 300) }
    }
}

/// Trzyma klienta klastra bez publikowania zmian - okno nie przerysowuje się przy każdym spocie
/// (spoty obserwują tylko zakładka klastra i znaczniki na skopie).
@MainActor
final class DXClusterHolder: ObservableObject {
    let client = DXClusterClient()
}
