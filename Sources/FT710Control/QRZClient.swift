import Foundation
import CoreLocation

/// Dane stacji z QRZ.com (pola interfejsu XML; bez subskrypcji QRZ część pól jest pusta).
struct QRZRecord: Equatable {
    let call: String
    let firstName: String
    let lastName: String
    let nameFormatted: String
    let address: String
    let city: String
    let state: String
    let country: String
    let grid: String
    let latitude: Double?
    let longitude: Double?
    let dxcc: String
    let cqZone: String
    let ituZone: String
    let email: String

    init?(_ fields: [String: String]) {
        guard let call = fields["call"], !call.isEmpty else { return nil }
        self.call = call.uppercased()
        firstName = fields["fname"] ?? ""
        lastName = fields["name"] ?? ""
        nameFormatted = fields["name_fmt"] ?? ""
        address = fields["addr1"] ?? ""
        city = fields["addr2"] ?? ""
        state = fields["state"] ?? ""
        country = fields["country"] ?? fields["land"] ?? ""
        grid = fields["grid"] ?? ""
        latitude = fields["lat"].flatMap { Double($0) }
        longitude = fields["lon"].flatMap { Double($0) }
        dxcc = fields["dxcc"] ?? ""
        cqZone = fields["cqzone"] ?? ""
        ituZone = fields["ituzone"] ?? ""
        email = fields["email"] ?? ""
    }

    /// Pola w nazwach QRZ (do łączenia danych z dwóch źródeł).
    var asFields: [String: String] {
        ["call": call, "fname": firstName, "name": lastName, "name_fmt": nameFormatted, "addr1": address, "addr2": city,
         "state": state, "country": country, "grid": grid, "lat": latitude.map { String($0) } ?? "",
         "lon": longitude.map { String($0) } ?? "", "dxcc": dxcc, "cqzone": cqZone, "ituzone": ituZone, "email": email]
    }

    /// Rekord z odpowiedzi HamQTH (pola: callsign, nick, qth, country, adif, itu, cq, grid, adr_*, latitude, longitude).
    static func fromHamQTH(_ f: [String: String]) -> QRZRecord? {
        guard let call = f["callsign"], !call.isEmpty else { return nil }
        return QRZRecord(["call": call, "fname": f["nick"] ?? "", "name_fmt": f["adr_name"] ?? "",
                          "addr1": f["adr_street1"] ?? "", "addr2": f["qth"] ?? f["adr_city"] ?? "",
                          "country": f["country"] ?? "", "grid": (f["grid"] ?? "").uppercased(),
                          "lat": f["latitude"] ?? "", "lon": f["longitude"] ?? "", "dxcc": f["adif"] ?? "",
                          "cqzone": f["cq"] ?? "", "ituzone": f["itu"] ?? "", "email": f["email"] ?? ""])
    }

    /// Ten rekord z pustymi polami uzupełnionymi z drugiego źródła.
    func filled(from other: QRZRecord) -> QRZRecord {
        var fields = asFields
        for (key, value) in other.asFields where (fields[key] ?? "").isEmpty && !value.isEmpty { fields[key] = value }
        return QRZRecord(fields) ?? self
    }

    var displayName: String {
        if !nameFormatted.isEmpty { return nameFormatted }
        return [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Miasto, region, kraj.
    var place: String {
        [city, state, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Pozycja: współrzędne z QRZ, a gdy ich brak - środek lokatora.
    var coordinate: CLLocationCoordinate2D? {
        if let latitude, let longitude, latitude != 0 || longitude != 0 {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return Geo.coordinate(fromGrid: grid)
    }
}

/// Parser odpowiedzi XML QRZ: zbiera pola sekcji <Session> i <Callsign> (nazwy pól małymi literami).
final class QRZXMLParser: NSObject, XMLParserDelegate {
    private(set) var session: [String: String] = [:]
    private(set) var callsign: [String: String] = [:]
    private var section: String?
    private var element: String?
    private var text = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        // QRZ: Session / Callsign; HamQTH: session / search
        if ["Session", "Callsign", "session", "search"].contains(elementName) {
            section = elementName
        } else if section != nil {
            element = elementName.lowercased()
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == section {
            section = nil
        } else if let current = element, current == elementName.lowercased() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if section == "Session" || section == "session" { session[current] = value } else { callsign[current] = value }
            element = nil
        }
    }
}

/// Klient interfejsu XML QRZ.com. Hasło w pęku kluczy, sesja odnawiana automatycznie,
/// wyniki zapamiętywane do końca działania programu (bez zbędnych zapytań).
@MainActor
final class QRZClient: ObservableObject {
    enum Outcome {
        case found(QRZRecord)
        case notFound
        case failed(String)
    }

    @Published private(set) var username: String
    @Published private(set) var hasPassword: Bool
    @Published private(set) var status: String
    /// Konto bez subskrypcji XML - QRZ zwraca tylko część danych.
    @Published private(set) var limitedData = false

    private var sessionKey: String?
    private var cache: [String: QRZRecord] = [:]
    /// Hasło odczytane z pęku kluczy - trzymane do końca sesji, żeby macOS pytał o zgodę najwyżej raz.
    private var cachedPassword: String?

    private static let endpoint = URL(string: "https://xmldata.qrz.com/xml/current/")!
    private static let agent = "FT710Control-1.0"
    private static let keychainService = "FT710Control.QRZ"
    private static let usernameKey = "qrzUsername"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
        username = saved
        // Przy starcie tylko sprawdzamy, czy hasło jest zapisane (bez odczytu - bez pytania systemu).
        let stored = !saved.isEmpty && Keychain.exists(service: Self.keychainService, account: saved)
        hasPassword = stored
        status = stored ? L("Konto QRZ zapisane") : L("Brak konta QRZ")
    }

    var isConfigured: Bool { !username.isEmpty && hasPassword }

    // MARK: - HamQTH (darmowa baza znaków; samodzielnie albo uzupełnienie QRZ)

    @Published private(set) var hamqthUser = UserDefaults.standard.string(forKey: "hamqthUsername") ?? ""
    @Published private(set) var hasHamQTH: Bool = {
        let user = UserDefaults.standard.string(forKey: "hamqthUsername") ?? ""
        return !user.isEmpty && Keychain.exists(service: "FT710Control.HamQTH", account: user)
    }()
    private static let hamqthService = "FT710Control.HamQTH"
    private static let hamqthEndpoint = URL(string: "https://www.hamqth.com/xml.php")!
    private var hamqthSession: String?
    private var hamqthSessionTime = Date.distantPast
    private var hamqthPassword: String?

    /// Wyszukiwanie możliwe (QRZ albo HamQTH) - przyciski „Uzupełnij…”, karta stacji, panel zdalny.
    var canLookup: Bool { isConfigured || hasHamQTH }

    func setHamQTH(user: String, password: String) {
        let name = user.trimmingCharacters(in: .whitespaces).uppercased()
        if !hamqthUser.isEmpty, hamqthUser != name { Keychain.delete(service: Self.hamqthService, account: hamqthUser) }
        hamqthUser = name
        UserDefaults.standard.set(name, forKey: "hamqthUsername")
        if !password.isEmpty { Keychain.set(password, service: Self.hamqthService, account: name) }
        hasHamQTH = !name.isEmpty && Keychain.exists(service: Self.hamqthService, account: name)
        hamqthSession = nil
        hamqthPassword = nil
        cache.removeAll()
    }

    func clearHamQTH() {
        if !hamqthUser.isEmpty { Keychain.delete(service: Self.hamqthService, account: hamqthUser) }
        hamqthUser = ""
        UserDefaults.standard.removeObject(forKey: "hamqthUsername")
        hasHamQTH = false
        hamqthSession = nil
        hamqthPassword = nil
    }

    /// HamQTH: sesja (ważna godzinę, odnawiana po 55 min albo po błędzie), potem wyszukanie znaku.
    private func lookupHamQTH(_ call: String) async -> Outcome {
        if hamqthPassword == nil { hamqthPassword = Keychain.get(service: Self.hamqthService, account: hamqthUser) }
        guard let password = hamqthPassword else { return .failed(L("Brak konta HamQTH")) }
        for _ in 0..<2 {
            if hamqthSession == nil || Date().timeIntervalSince(hamqthSessionTime) > 3300 {
                guard let login = await requestHamQTH([URLQueryItem(name: "u", value: hamqthUser),
                                                       URLQueryItem(name: "p", value: password)]) else {
                    return .failed(L("Brak połączenia z HamQTH"))
                }
                guard let id = login.session["session_id"], !id.isEmpty else {
                    return .failed(L("HamQTH: {1}", login.session["error"] ?? L("logowanie nieudane")))
                }
                hamqthSession = id
                hamqthSessionTime = Date()
            }
            guard let id = hamqthSession,
                  let response = await requestHamQTH([URLQueryItem(name: "id", value: id),
                                                      URLQueryItem(name: "callsign", value: call),
                                                      URLQueryItem(name: "prg", value: "FT710Control")]) else {
                return .failed(L("Brak połączenia z HamQTH"))
            }
            if let record = QRZRecord.fromHamQTH(response.callsign) { return .found(record) }
            let error = (response.session["error"] ?? "").lowercased()
            if error.contains("not found") { return .notFound }
            if error.contains("session") { hamqthSession = nil; continue }      // sesja wygasła
            return .failed(L("HamQTH: {1}", response.session["error"] ?? L("nieoczekiwana odpowiedź")))
        }
        return .failed(L("HamQTH: nie udało się odnowić sesji"))
    }

    private func requestHamQTH(_ items: [URLQueryItem]) async -> (session: [String: String], callsign: [String: String])? {
        guard var components = URLComponents(url: Self.hamqthEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: ";", with: "%3B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = QRZXMLParser()
        guard parser.parse(data) else { return nil }
        return (parser.session, parser.callsign)
    }

    /// Zapisuje konto; puste hasło = zostaw dotychczasowe. Od razu sprawdza logowanie.
    func saveCredentials(username newName: String, password: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let previous = username
        if name != previous, !previous.isEmpty {
            Keychain.delete(service: Self.keychainService, account: previous)
        }
        username = name
        UserDefaults.standard.set(name, forKey: Self.usernameKey)
        if !password.isEmpty, !name.isEmpty {
            Keychain.set(password, service: Self.keychainService, account: name)
            cachedPassword = password
        } else if name != previous {
            cachedPassword = nil              // inne konto - hasło poprzedniego nie może zostać w pamięci
        }
        hasPassword = !name.isEmpty && Keychain.exists(service: Self.keychainService, account: name)
        sessionKey = nil
        cache.removeAll()
        guard isConfigured else {
            status = L("Brak konta QRZ")
            return
        }
        status = L("Logowanie…")
        Task { _ = await self.login() }
    }

    func forget() {
        if !username.isEmpty { Keychain.delete(service: Self.keychainService, account: username) }
        cachedPassword = nil
        hasPassword = false
        sessionKey = nil
        cache.removeAll()
        status = L("Brak konta QRZ")
    }

    /// Znak do wyszukania: z „SP5XX/P” albo „DL/SP5XX” bierzemy część właściwą (najdłuższą z cyfrą).
    /// Czysta funkcja na tekście - `nonisolated`, więc można jej używać także poza wątkiem głównym
    /// (np. w indeksie dziennika FT8, który nie jest przypisany do MainActor).
    nonisolated static func baseCall(_ call: String) -> String {
        let parts = call.uppercased().split(separator: "/").map(String.init)
        return parts.filter { $0.contains(where: \.isNumber) }.max(by: { $0.count < $1.count }) ?? call.uppercased()
    }

    /// Wyszukanie znaku: QRZ.com, a HamQTH - gdy nie ma konta QRZ, gdy QRZ nie zna znaku albo zwraca okrojone dane
    /// (bez subskrypcji XML brak lokatora i adresu: puste pola uzupełnia HamQTH). Wyniki zapamiętywane.
    func lookup(_ rawCall: String) async -> Outcome {
        let call = Self.baseCall(rawCall)
        if let cached = cache[call] { return .found(cached) }
        var fromQRZ: Outcome?
        if isConfigured { fromQRZ = await lookupQRZ(call) }
        if case .found(let record)? = fromQRZ {
            var result = record
            if hasHamQTH, record.grid.isEmpty || record.city.isEmpty, case .found(let extra) = await lookupHamQTH(call) {
                result = record.filled(from: extra)
            }
            cache[call] = result
            return .found(result)
        }
        if hasHamQTH {
            let fromHamQTH = await lookupHamQTH(call)
            if case .found(let record) = fromHamQTH {
                cache[call] = record
                return fromHamQTH
            }
            if fromQRZ == nil { return fromHamQTH }
        }
        return fromQRZ ?? .failed(L("Brak konta QRZ ani HamQTH"))
    }

    /// QRZ.com XML (sesja odnawiana po wygaśnięciu).
    private func lookupQRZ(_ call: String) async -> Outcome {

        for _ in 0..<2 {                                       // druga próba po wygaśnięciu sesji
            if sessionKey == nil, let error = await login() { return .failed(error) }
            guard let key = sessionKey else { return .failed(L("Brak sesji QRZ")) }
            guard let response = await request([URLQueryItem(name: "s", value: key),
                                                URLQueryItem(name: "callsign", value: call)]) else {
                return .failed(L("Brak połączenia z QRZ.com"))
            }
            if let record = QRZRecord(response.callsign) { return .found(record) }
            let error = response.session["error"] ?? ""
            if error.lowercased().contains("not found") { return .notFound }
            if response.session["key"] == nil || error.lowercased().contains("session") {
                sessionKey = nil                               // sesja wygasła - zaloguj ponownie
                continue
            }
            return .failed(error.isEmpty ? L("Nieoczekiwana odpowiedź QRZ") : error)
        }
        return .failed(L("Nie udało się odnowić sesji QRZ"))
    }

    /// Logowanie; zwraca opis błędu albo nil.
    private func login() async -> String? {
        if cachedPassword == nil {
            cachedPassword = Keychain.get(service: Self.keychainService, account: username)
        }
        guard let password = cachedPassword else {
            hasPassword = false
            status = L("Brak konta QRZ")
            return L("Brak konta QRZ")
        }
        guard let response = await request([URLQueryItem(name: "username", value: username),
                                            URLQueryItem(name: "password", value: password),
                                            URLQueryItem(name: "agent", value: Self.agent)]) else {
            status = L("Brak połączenia z QRZ.com")
            return status
        }
        if let key = response.session["key"], !key.isEmpty {
            sessionKey = key
            let subscription = (response.session["subexp"] ?? "").lowercased()
            limitedData = subscription.isEmpty || subscription.contains("non")
            status = limitedData ? L("Zalogowano do QRZ (bez subskrypcji XML - dane ograniczone)")
                                 : L("Zalogowano do QRZ")
            return nil
        }
        let error = response.session["error"] ?? L("Logowanie nie powiodło się")
        status = L("Błąd: {1}", error)
        return error
    }

    private func request(_ items: [URLQueryItem]) async -> (session: [String: String], callsign: [String: String])? {
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items
        // „+” i „;” w haśle muszą być zakodowane (QRZ traktuje „;” jak separator parametrów).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: ";", with: "%3B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let parser = QRZXMLParser()
            guard parser.parse(data) else { return nil }
            return (parser.session, parser.callsign)
        } catch {
            return nil
        }
    }
}

/// Bieżąco oglądana stacja (wpisywany znak albo zaznaczona łączność) i stan wyszukiwania.
@MainActor
final class CallLookup: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, found, notFound, noAccount
        case failed(String)
    }

    @Published private(set) var call = ""
    @Published private(set) var record: QRZRecord?
    @Published private(set) var phase: Phase = .idle
    /// Lokator z dziennika - pozwala pokazać mapę i odległość także bez danych z QRZ.
    @Published private(set) var gridHint: String?

    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        call = ""
        record = nil
        gridHint = nil
        phase = .idle
    }

    /// Pokazuje stację. `debounce`: przy wpisywaniu znaku czekamy chwilę, zanim zapytamy QRZ.
    func request(_ rawCall: String, using qrz: QRZClient, gridHint hint: String? = nil, debounce: Bool = false) {
        let callsign = rawCall.trimmingCharacters(in: .whitespaces).uppercased()
        task?.cancel()
        guard callsign.count >= 3 else {
            clear()
            return
        }
        if callsign == call, phase == .found {
            if let hint, !hint.isEmpty { gridHint = hint }
            return
        }
        call = callsign
        gridHint = hint
        record = nil
        guard qrz.canLookup else {
            phase = .noAccount
            return
        }
        phase = .loading
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 700_000_000) }
            guard !Task.isCancelled else { return }
            let outcome = await qrz.lookup(callsign)
            guard !Task.isCancelled, let self, self.call == callsign else { return }
            switch outcome {
            case .found(let record):
                self.record = record
                self.phase = .found
            case .notFound:
                self.phase = .notFound
            case .failed(let message):
                self.phase = .failed(message)
            }
        }
    }

    /// Pozycja oglądanej stacji: QRZ, a w drugiej kolejności lokator z dziennika.
    var coordinate: CLLocationCoordinate2D? {
        record?.coordinate ?? gridHint.flatMap { Geo.coordinate(fromGrid: $0) }
    }

    var grid: String {
        if let grid = record?.grid, !grid.isEmpty { return grid }
        if let gridHint, !gridHint.isEmpty { return gridHint }
        return record?.coordinate.map { Geo.grid(for: $0) } ?? ""
    }
}
