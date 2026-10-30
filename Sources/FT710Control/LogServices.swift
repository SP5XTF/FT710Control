import Foundation

/// Serwisy, do których dziennik wysyła łączności.
enum LogService: String, CaseIterable, Identifiable {
    case lotw, qrzLogbook, eqsl, clublog, hrdlog, cloudlog, wrl

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lotw: return "LoTW"
        case .qrzLogbook: return "QRZ Logbook"
        case .eqsl: return "eQSL"
        case .clublog: return "Club Log"
        case .hrdlog: return "HRDLog.net"
        case .cloudlog: return "Cloudlog / Wavelog"
        case .wrl: return "World Radio League"
        }
    }

    /// Pole ADIF ze stanem wysyłki („Y” = wysłano) i pole z datą wysyłki (standard ADIF 3.1).
    var sentField: String {
        switch self {
        case .lotw: return "LOTW_QSL_SENT"
        case .qrzLogbook: return "QRZCOM_QSO_UPLOAD_STATUS"
        case .eqsl: return "EQSL_QSL_SENT"
        case .clublog: return "CLUBLOG_QSO_UPLOAD_STATUS"
        case .hrdlog: return "HRDLOG_QSO_UPLOAD_STATUS"
        case .cloudlog: return "APP_FT710CONTROL_CLOUDLOG"
        case .wrl: return "APP_FT710CONTROL_WRL"
        }
    }

    var dateField: String {
        switch self {
        case .lotw: return "LOTW_QSLSDATE"
        case .qrzLogbook: return "QRZCOM_QSO_UPLOAD_DATE"
        case .eqsl: return "EQSL_QSLSDATE"
        case .clublog: return "CLUBLOG_QSO_UPLOAD_DATE"
        case .hrdlog: return "HRDLOG_QSO_UPLOAD_DATE"
        case .cloudlog: return "APP_FT710CONTROL_CLOUDLOG_DATE"
        case .wrl: return "APP_FT710CONTROL_WRL_DATE"
        }
    }

    func isSent(_ qso: QSO) -> Bool { qso.extra[sentField]?.uppercased() == "Y" }

    /// Czy serwis ma osobny test połączenia.
    var hasTest: Bool {
        switch self {
        case .lotw, .qrzLogbook, .eqsl, .cloudlog, .wrl: return true
        case .clublog, .hrdlog: return false
        }
    }
}

/// Ustawienia serwisu: zwykłe pola w ustawieniach programu, hasła i klucze w pęku kluczy macOS.
@MainActor
final class LogServiceSettings: ObservableObject {
    let service: LogService

    @Published var autoUpload: Bool { didSet { defaults.set(autoUpload, forKey: key("auto")) } }
    /// Konto / znak / e-mail - zależnie od serwisu.
    @Published var account: String { didSet { defaults.set(account, forKey: key("account")) } }
    @Published var callsign: String { didSet { defaults.set(callsign, forKey: key("callsign")) } }
    /// LoTW: lokalizacja stacji w TQSL; eQSL: QTH Nickname; Cloudlog: adres serwera.
    @Published var location: String { didSet { defaults.set(location, forKey: key("location")) } }
    /// LoTW: ścieżka do programu tqsl; Cloudlog: identyfikator profilu stacji.
    @Published var path: String { didSet { defaults.set(path, forKey: key("path")) } }
    /// LoTW: czy przekazywać hasło certyfikatu do TQSL przełącznikiem -p. TQSL w trybie wsadowym przyjmuje hasło
    /// tylko w linii poleceń, a ta jest przez chwilę widoczna dla innych procesów (np. `ps`). Domyślnie wyłączone:
    /// gdy certyfikat ma hasło, TQSL sam pyta o nie w swoim okienku - hasło nie przechodzi przez program.
    @Published var passPasswordToTQSL: Bool { didSet { defaults.set(passPasswordToTQSL, forKey: key("passPassword")) } }
    @Published private(set) var hasSecret: Bool
    @Published private(set) var hasSecondSecret: Bool

    @Published private(set) var lastUpload: Date?
    @Published private(set) var lastMessage = ""
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    private let defaults = UserDefaults.standard
    private var secretCache: String?
    private var secondSecretCache: String?

    private var keychainService: String { "FT710Control.\(service.rawValue)" }
    private func key(_ name: String) -> String { "svc.\(service.rawValue).\(name)" }

    static let defaultTQSLPath = "/Applications/TrustedQSL/tqsl.app/Contents/MacOS/tqsl"

    init(service: LogService) {
        self.service = service
        let d = UserDefaults.standard
        let prefix = "svc.\(service.rawValue)."
        autoUpload = d.bool(forKey: prefix + "auto")
        account = d.string(forKey: prefix + "account") ?? ""
        callsign = d.string(forKey: prefix + "callsign") ?? ""
        location = d.string(forKey: prefix + "location") ?? ""
        path = d.string(forKey: prefix + "path") ?? (service == .lotw ? Self.defaultTQSLPath : "")
        passPasswordToTQSL = d.bool(forKey: prefix + "passPassword")
        hasSecret = Keychain.exists(service: "FT710Control.\(service.rawValue)", account: "secret")
        hasSecondSecret = Keychain.exists(service: "FT710Control.\(service.rawValue)", account: "secret2")
        lastUpload = d.object(forKey: prefix + "lastUpload") as? Date
    }

    // MARK: - Sekrety (pęk kluczy; odczyt najwyżej raz na sesję)

    func setSecret(_ value: String) {
        guard !value.isEmpty else { return }
        Keychain.set(value, service: keychainService, account: "secret")
        secretCache = value
        hasSecret = true
    }

    func setSecondSecret(_ value: String) {
        guard !value.isEmpty else { return }
        Keychain.set(value, service: keychainService, account: "secret2")
        secondSecretCache = value
        hasSecondSecret = true
    }

    func secret() -> String? {
        if secretCache == nil { secretCache = Keychain.get(service: keychainService, account: "secret") }
        return secretCache
    }

    func secondSecret() -> String? {
        if secondSecretCache == nil { secondSecretCache = Keychain.get(service: keychainService, account: "secret2") }
        return secondSecretCache
    }

    func forgetCredentials() {
        Keychain.delete(service: keychainService, account: "secret")
        Keychain.delete(service: keychainService, account: "secret2")
        secretCache = nil
        secondSecretCache = nil
        hasSecret = false
        hasSecondSecret = false
        autoUpload = false
    }

    /// Czy są wszystkie dane potrzebne do wysyłki (bez odczytu haseł).
    var isConfigured: Bool {
        switch service {
        case .lotw: return !location.isEmpty && FileManager.default.isExecutableFile(atPath: path)
        case .qrzLogbook: return hasSecret
        case .eqsl: return !account.isEmpty && hasSecret
        case .clublog: return !account.isEmpty && !callsign.isEmpty && hasSecret && hasSecondSecret
        case .hrdlog: return !callsign.isEmpty && hasSecret
        case .cloudlog: return !location.isEmpty && !path.isEmpty && hasSecret
        case .wrl: return hasSecret
        }
    }

    /// Krótki opis konta do listy serwisów.
    var accountSummary: String {
        switch service {
        case .lotw: return location
        case .qrzLogbook: return hasSecret ? L("klucz API") : ""
        case .eqsl: return account
        case .clublog: return callsign
        case .hrdlog: return callsign
        case .cloudlog: return URL(string: location)?.host ?? location
        case .wrl: return hasSecret ? (path.isEmpty ? L("dziennik domyślny") : L("wybrany dziennik")) : ""
        }
    }

    // MARK: - Stan (ustawiany przez moduł wysyłki)

    func markBusy(_ value: Bool) { busy = value }

    func recordSuccess(_ message: String) {
        lastUpload = Date()
        defaults.set(lastUpload, forKey: key("lastUpload"))
        lastMessage = message
        lastError = nil
    }

    func recordFailure(_ message: String) {
        lastError = message
        lastMessage = message
    }

    func recordInfo(_ message: String) {
        lastMessage = message
        lastError = nil
    }
}

/// Wynik wysłania jednej łączności (albo paczki dla LoTW).
enum UploadResult {
    case sent(String)
    case duplicate(String)          // serwis ma już tę łączność - traktujemy jak wysłaną
    case failed(String)

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }

    var message: String {
        switch self {
        case .sent(let m), .duplicate(let m), .failed(let m): return m
        }
    }
}

/// Wysyłka łączności do serwisów: automatycznie po zapisaniu QSO (jeśli włączona) i na żądanie
/// („Wyślij zaległe”). Stan wysyłki trafia do pól ADIF łączności.
@MainActor
final class LogUploader: ObservableObject {
    let settings: [LogService: LogServiceSettings]
    /// Podsumowanie ostatniej automatycznej wysyłki (np. „SP5XX: LoTW ✓ · QRZ Logbook ✓”).
    @Published private(set) var lastSummary = ""

    private weak var store: LogbookStore?
    private var running: Set<LogService> = []
    private var queues: [LogService: [UUID]] = [:]
    private var summary: [UUID: [String]] = [:]
    /// Club Log: po błędzie (kod HTTP inny niż 200 albo nieoczekiwana odpowiedź) automatyczna wysyłka
    /// zostaje wstrzymana - nowe QSO nie ponawiają prób (np. złe hasło nie może blokować konta).
    /// Wznowienie: ręcznie, przyciskiem „Wyślij zaległe”, po poprawieniu ustawień.
    @Published private(set) var clubLogHalted: String?

    static let userAgent = "FT710Control/" + ADIF.programVersion

    /// Identyfikator łączności w World Radio League (do poprawek przez PATCH).
    static let wrlIDField = "APP_FT710CONTROL_WRL_ID"
    private var wrlContactIDs: [UUID: String] = [:]
    /// Numer łączności w QRZ Logbook (LOGID z odpowiedzi INSERT) - potrzebny do usunięcia jej w QRZ.
    static let qrzIDField = "APP_QRZLOG_LOGID"
    private var qrzLogIDs: [UUID: String] = [:]

    init() {
        var map: [LogService: LogServiceSettings] = [:]
        for service in LogService.allCases { map[service] = LogServiceSettings(service: service) }
        settings = map
    }

    func attach(_ store: LogbookStore) {
        self.store = store
        store.onLogged = { [weak self] qso in self?.qsoLogged(qso) }
        store.onEdited = { [weak self] qso in self?.qsoEdited(qso) }
    }

    /// Poprawiona łączność: World Radio League ma PATCH, więc zmiany idą też tam
    /// (jeśli łączność była wysłana z tego programu i wysyłka do WRL jest skonfigurowana).
    func qsoEdited(_ qso: QSO) {
        let cfg = config(.wrl)
        guard cfg.isConfigured, let remote = qso.extra[Self.wrlIDField], !remote.isEmpty else { return }
        Task {
            let result = await patchWRL(qso, id: remote, cfg)
            if result.succeeded { cfg.recordInfo(result.message) } else { cfg.recordFailure(L("Błąd: {1}", result.message)) }
        }
    }

    func config(_ service: LogService) -> LogServiceSettings { settings[service]! }

    // MARK: - Kolejka

    /// Nowa łączność (zapis ręczny albo z WSJT-X) - do serwisów z włączoną automatyczną wysyłką.
    func qsoLogged(_ qso: QSO) {
        let targets = LogService.allCases.filter {
            config($0).autoUpload && config($0).isConfigured && !($0 == .clublog && clubLogHalted != nil)
        }
        guard !targets.isEmpty else { return }
        summary[qso.id] = []
        for service in targets { enqueue([qso.id], to: service) }
    }

    /// Łączności jeszcze niewysłane do serwisu.
    func pending(_ service: LogService) -> [QSO] {
        (store?.qsos ?? []).filter { !service.isSent($0) }
    }

    func uploadPending(_ service: LogService) {
        if service == .clublog { clubLogHalted = nil }      // ręczne wznowienie po poprawieniu ustawień
        enqueue(pending(service).map(\.id), to: service)
    }

    /// Oznacza wszystkie łączności jako wysłane (np. stary dziennik wysłany wcześniej innym programem).
    func markAllSent(_ service: LogService) {
        guard let store else { return }
        let today = ADIF.adifDate(Date())
        let changed: [QSO] = store.qsos.filter { !service.isSent($0) }.map { qso in
            var updated = qso
            updated.extra[service.sentField] = "Y"
            updated.extra[service.dateField] = today
            return updated
        }
        store.update(changed)                           // jeden zapis pliku dla całego dziennika
        config(service).recordInfo(L("Wszystkie łączności oznaczone jako wysłane"))
    }

    private func enqueue(_ ids: [UUID], to service: LogService) {
        guard !ids.isEmpty else { return }
        var queue = queues[service] ?? []
        for id in ids where !queue.contains(id) { queue.append(id) }
        queues[service] = queue
        guard !running.contains(service) else { return }
        running.insert(service)
        Task { await self.drain(service) }
    }

    private func drain(_ service: LogService) async {
        let cfg = config(service)
        cfg.markBusy(true)
        defer {
            running.remove(service)
            cfg.markBusy(false)
        }
        var sent = 0, duplicates = 0
        var lastFailure: String?
        while let ids = takeBatch(for: service), !ids.isEmpty {
            let qsos = ids.compactMap { id in store?.qsos.first { $0.id == id } }
            guard !qsos.isEmpty else { continue }
            let result = await upload(qsos, to: service)
            switch result {
            case .sent: sent += qsos.count
            case .duplicate: duplicates += qsos.count
            case .failed(let message): lastFailure = message
            }
            if result.succeeded { markSent(qsos.map(\.id), service) }
            for qso in qsos { note(qso, service, ok: result.succeeded) }
            if case .failed(let message) = result {
                if service == .clublog { clubLogHalted = message }   // bez automatycznych ponowień
                queues[service] = []            // reszta zostaje jako zaległa - do ponowienia przyciskiem
                break
            }
            if service == .wrl, !(queues[service] ?? []).isEmpty {
                try? await Task.sleep(nanoseconds: 1_100_000_000)   // limit WRL: 60 zapisów na minutę
            }
        }
        if let lastFailure {
            cfg.recordFailure(service == .clublog
                ? L("Błąd: {1} - automatyczna wysyłka do Club Log wstrzymana; popraw ustawienia i kliknij „Wyślij zaległe”.", lastFailure)
                : L("Błąd: {1}", lastFailure))
        } else if sent + duplicates > 0 {
            cfg.recordSuccess(L("Wysłano {1}, duplikaty {2}", sent, duplicates))
        }
    }

    /// LoTW: cała kolejka naraz (jedno uruchomienie TQSL); pozostałe serwisy: po jednej łączności.
    private func takeBatch(for service: LogService) -> [UUID]? {
        guard var queue = queues[service], !queue.isEmpty else { return nil }
        // LoTW: jedno uruchomienie TQSL; Club Log: zaległe jednym plikiem ADIF (putlogs.php) - realtime.php
        // tylko dla pojedynczego QSO (Club Log zabrania seryjnej wysyłki przez realtime.php)
        let count = service == .lotw ? min(queue.count, 500) : service == .clublog ? min(queue.count, 10_000) : 1
        let batch = Array(queue.prefix(count))
        queue.removeFirst(count)
        queues[service] = queue
        return batch
    }

    /// Oznacza łączności jako wysłane - na bieżącej wersji z dziennika (mogły być w międzyczasie edytowane).
    private func markSent(_ ids: [UUID], _ service: LogService) {
        guard let store else { return }
        let today = ADIF.adifDate(Date())
        let wanted = Set(ids)
        let changed: [QSO] = store.qsos.filter { wanted.contains($0.id) }.map { qso in
            var updated = qso
            updated.extra[service.sentField] = "Y"
            updated.extra[service.dateField] = today
            if service == .wrl, let remote = wrlContactIDs.removeValue(forKey: qso.id) {
                updated.extra[Self.wrlIDField] = remote
            }
            if service == .qrzLogbook, let remote = qrzLogIDs.removeValue(forKey: qso.id) {
                updated.extra[Self.qrzIDField] = remote
            }
            return updated
        }
        store.update(changed)
    }

    private func note(_ qso: QSO, _ service: LogService, ok: Bool) {
        guard summary[qso.id] != nil else { return }
        summary[qso.id]?.append(service.name + (ok ? " ✓" : " ✗"))
        lastSummary = qso.call + ": " + (summary[qso.id] ?? []).joined(separator: " · ")
    }

    // MARK: - Test połączenia

    func test(_ service: LogService) async {
        let cfg = config(service)
        cfg.markBusy(true)
        defer { cfg.markBusy(false) }
        let result: UploadResult
        switch service {
        case .lotw: result = await testLoTW(cfg)
        case .qrzLogbook: result = await testQRZ(cfg)
        case .eqsl: result = await testEQSL(cfg)
        case .cloudlog: result = await testCloudlog(cfg)
        case .wrl: result = await testWRL(cfg)
        case .clublog, .hrdlog: result = .failed(L("Ten serwis nie ma testu - sprawdzenie nastąpi przy pierwszej wysyłce."))
        }
        if result.succeeded { cfg.recordInfo(result.message) } else { cfg.recordFailure(result.message) }
    }

    // MARK: - Wysyłka do serwisów

    private func upload(_ qsos: [QSO], to service: LogService) async -> UploadResult {
        let cfg = config(service)
        switch service {
        case .lotw: return await uploadLoTW(qsos, cfg)
        case .qrzLogbook: return await uploadQRZ(qsos[0], cfg)
        case .eqsl: return await uploadEQSL(qsos[0], cfg)
        case .clublog:
            if qsos.count == 1 { return await uploadClubLog(qsos[0], cfg) }
            return await uploadClubLogFile(qsos, cfg)
        case .hrdlog: return await uploadHRDLog(qsos[0], cfg)
        case .cloudlog: return await uploadCloudlog(qsos[0], cfg)
        case .wrl: return await uploadWRL(qsos[0], cfg)
        }
    }

    // MARK: - Usuwanie łączności w serwisach

    /// Serwisy, w których program potrafi usunąć łączność (Club Log: delete.php, QRZ Logbook: ACTION=DELETE).
    /// LoTW z zasady nie usuwa wysłanych łączności; eQSL i pozostałe - ręcznie na stronie serwisu.
    static let remoteDeletable: [LogService] = [.clublog, .qrzLogbook]
    /// Club Log: usuwanie w czasie rzeczywistym tylko w tempie operatora - najwyżej 10 łączności naraz.
    static let clubLogDeleteLimit = 10

    /// Usuwa łączności w wybranych serwisach (tylko te, które były do nich wysłane); zwraca opis wyników.
    func deleteRemote(_ qsos: [QSO], services: Set<LogService>) async -> [String] {
        var lines: [String] = []
        for service in Self.remoteDeletable where services.contains(service) {
            let cfg = config(service)
            let targets = qsos.filter { service.isSent($0) }
            guard !targets.isEmpty else { continue }
            if service == .clublog, targets.count > Self.clubLogDeleteLimit {
                lines.append(L("{1}: ponad {2} łączności - usuń w Club Log ręcznie (Log Inspector) albo wyślij dziennik ponownie z opcją „clear”.",
                               service.name, Self.clubLogDeleteLimit))
                continue
            }
            var ok = 0
            var failed: [String] = []
            for qso in targets {
                let result = service == .clublog ? await deleteClubLog(qso, cfg) : await deleteQRZ(qso, cfg)
                if result.succeeded { ok += 1 } else { failed.append(qso.call + ": " + result.message) }
            }
            lines.append(L("{1}: usunięto {2} z {3}", service.name, ok, targets.count)
                         + (failed.isEmpty ? "" : " · " + failed.joined(separator: "; ")))
        }
        return lines
    }

    /// Club Log delete.php (dokumentacja Club Log): email, password, callsign (dziennik), dxcall, datetime
    /// „RRRR-MM-DD GG:MM:SS” - dokładnie czas wysłany (TIME_ON z sekundami), bandid (20, 70 = 70 cm…), api.
    private func deleteClubLog(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard !cfg.account.isEmpty, !cfg.callsign.isEmpty, let password = cfg.secret(), let apiKey = cfg.secondSecret() else {
            return .failed(L("uzupełnij Club Log w „Usługach online”"))
        }
        if let halted = clubLogHalted { return .failed(L("Club Log wstrzymany po błędzie ({1})", halted)) }
        guard let bandID = Self.clubLogBandID(qso.band) else { return .failed(L("pasmo {1} nieobsługiwane przez Club Log", qso.band)) }
        let response = await Self.post("https://clublog.org/delete.php", [
            "email": cfg.account, "password": password, "callsign": cfg.callsign.uppercased(),
            "dxcall": qso.call.uppercased(), "datetime": Self.clubLogDateTime(qso.start), "bandid": bandID, "api": apiKey
        ])
        if response.status == 200 { return .sent(L("Usunięto z Club Log")) }
        let text = Self.plainText(response.body ?? "")
        return .failed(text.isEmpty ? (response.error ?? L("Kod HTTP {1}", response.status)) : text)
    }

    static func clubLogBandID(_ band: String) -> String? {
        let b = band.lowercased()
        let id = b.hasSuffix("cm") ? String(b.dropLast(2)) : b.hasSuffix("m") ? String(b.dropLast()) : b
        let valid: Set<String> = ["160", "80", "60", "40", "30", "20", "17", "15", "12", "10", "6", "4", "2", "70", "23", "13"]
        return valid.contains(id) ? id : nil
    }

    static func clubLogDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// QRZ Logbook: ACTION=DELETE&LOGIDS=… Numer łączności zapamiętany przy wysyłce, a dla starszych - wyszukany
    /// w QRZ (FETCH po znaku) po paśmie i czasie (±2 min), żeby nie usunąć innej łączności z tą stacją.
    private func deleteQRZ(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        var logID = qso.extra[Self.qrzIDField]
        if logID == nil || logID?.isEmpty == true { logID = await findQRZLogID(qso, key: key) }
        guard let logID, !logID.isEmpty else { return .failed(L("nie znaleziono tej łączności w QRZ Logbook")) }
        let response = await Self.post("https://logbook.qrz.com/api", ["KEY": key, "ACTION": "DELETE", "LOGIDS": logID])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let fields = Self.queryFields(body)
        if fields["RESULT"] == "OK" { return .sent(L("Usunięto z QRZ Logbook")) }
        return .failed(fields["REASON"] ?? body)
    }

    private func findQRZLogID(_ qso: QSO, key: String) async -> String? {
        let response = await Self.post("https://logbook.qrz.com/api",
                                       ["KEY": key, "ACTION": "FETCH", "OPTION": "CALL:\(qso.call.uppercased()),MAX:250"])
        guard let body = response.body else { return nil }
        let fields = QSLDownloader.qrzFields(body)
        guard fields["RESULT"] == "OK", let adif = fields["ADIF"] else { return nil }
        for record in ADIF.parse(adif) {
            guard let remote = ADIF.qso(from: record), let id = record["APP_QRZLOG_LOGID"] else { continue }
            if remote.band.lowercased() == qso.band.lowercased(), abs(remote.start.timeIntervalSince(qso.start)) <= 120 {
                return id
            }
        }
        return nil
    }

    /// QRZ Logbook: POST KEY, ACTION=INSERT, ADIF; odpowiedź „RESULT=OK&LOGID=…” albo „RESULT=FAIL&REASON=…”.
    private func uploadQRZ(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let response = await Self.post("https://logbook.qrz.com/api",
                                       ["KEY": key, "ACTION": "INSERT", "ADIF": ADIF.record(qso, forUpload: true)])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let fields = Self.queryFields(body)
        if fields["RESULT"] == "OK" {
            if let logID = fields["LOGID"], !logID.isEmpty { qrzLogIDs[qso.id] = logID }   // do późniejszego usunięcia
            return .sent(L("Wysłano do QRZ Logbook"))
        }
        let reason = fields["REASON"] ?? body
        if reason.lowercased().contains("duplicate") { return .duplicate(L("Już jest w QRZ Logbook")) }
        return .failed(reason)
    }

    private func testQRZ(_ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let response = await Self.post("https://logbook.qrz.com/api", ["KEY": key, "ACTION": "STATUS"])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let fields = Self.queryFields(body)
        guard fields["RESULT"] == "OK" else { return .failed(fields["REASON"] ?? body) }
        return .sent(L("Połączenie OK: dziennik {1}, {2} QSO", fields["CALLSIGN"] ?? "?", fields["COUNT"] ?? "?"))
    }

    /// eQSL: POST EQSL_USER, EQSL_PSWD, ADIFData; odpowiedź HTML z „Result: N out of M records added”.
    private func uploadEQSL(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let password = cfg.secret() else { return .failed(L("Brak hasła")) }
        var extra: [String: String] = [:]
        if !cfg.location.isEmpty { extra["APP_EQSL_QTH_NICKNAME"] = cfg.location }
        let adif = ADIF.header() + ADIF.record(qso, forUpload: true, extra: extra)
        let response = await Self.post("https://www.eqsl.cc/qslcard/ImportADIF.cfm",
                                       ["EQSL_USER": cfg.account, "EQSL_PSWD": password, "ADIFData": adif])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let text = Self.plainText(body)
        if let match = text.range(of: #"Result:\s*(\d+)\s*out of\s*(\d+)\s*records added"#, options: .regularExpression) {
            let digits = text[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if let added = digits.first, added > 0 { return .sent(L("Wysłano do eQSL")) }
        }
        if text.lowercased().contains("duplicate") { return .duplicate(L("Już jest w eQSL")) }
        return .failed(Self.firstLine(containing: ["Error", "Warning"], in: text) ?? L("Nieoczekiwana odpowiedź eQSL"))
    }

    private func testEQSL(_ cfg: LogServiceSettings) async -> UploadResult {
        guard let password = cfg.secret() else { return .failed(L("Brak hasła")) }
        let response = await Self.get("https://www.eqsl.cc/qslcard/DisplayLastUploadDate.cfm",
                                      ["UserName": cfg.account, "Password": password])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let text = Self.plainText(body)
        if text.lowercased().contains("error") { return .failed(Self.firstLine(containing: ["Error"], in: text) ?? text) }
        return .sent(L("Połączenie OK: {1}", Self.firstLine(containing: ["upload"], in: text) ?? "eQSL"))
    }

    /// Club Log (czas rzeczywisty): POST email, password, callsign, adif, api; „OK” albo „Dupe”.
    private func uploadClubLog(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let password = cfg.secret(), let apiKey = cfg.secondSecret() else { return .failed(L("Brak hasła lub klucza API")) }
        let response = await Self.post("https://clublog.org/realtime.php",
                                       ["email": cfg.account, "password": password, "callsign": cfg.callsign,
                                        "adif": ADIF.record(qso, forUpload: true), "api": apiKey])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().contains("dupe") { return .duplicate(L("Już jest w Club Log")) }
        if response.status == 200 && (text.uppercased().hasPrefix("OK") || text.lowercased().contains("qso ok")) {
            return .sent(L("Wysłano do Club Log"))
        }
        return .failed(text.isEmpty ? L("Kod HTTP {1}", response.status) : text)
    }

    /// Club Log, paczka (zaległe): plik ADIF przez putlogs.php (multipart: file, email, password, callsign, api).
    /// Kod 200 = plik przyjęty (Club Log przetwarza go w tle); inny kod = błąd z treścią odpowiedzi.
    private func uploadClubLogFile(_ qsos: [QSO], _ cfg: LogServiceSettings) async -> UploadResult {
        guard let password = cfg.secret(), let apiKey = cfg.secondSecret() else { return .failed(L("Brak hasła lub klucza API")) }
        let adif = ADIF.header() + "\n" + qsos.sorted { $0.start < $1.start }
            .map { ADIF.record($0, forUpload: true) }.joined(separator: "\n") + "\n"
        let response = await Self.postMultipart("https://clublog.org/putlogs.php",
                                                ["email": cfg.account, "password": password, "callsign": cfg.callsign,
                                                 "api": apiKey],
                                                fileField: "file", fileName: "ft710control.adi", fileData: Data(adif.utf8))
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let text = Self.plainText(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.status == 200 else {
            return .failed(text.isEmpty ? L("Kod HTTP {1}", response.status) : L("Kod HTTP {1}: {2}", response.status, text))
        }
        return .sent(L("Club Log przyjął plik ({1} QSO) - przetworzenie może potrwać kilka minut", qsos.count))
    }

    /// HRDLog.net: POST Callsign (znak podstawowy), Code (kod wysyłania), App, ADIFData; „<insert>1</insert>”.
    private func uploadHRDLog(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let code = cfg.secret() else { return .failed(L("Brak kodu wysyłania")) }
        let response = await Self.post("https://robot.hrdlog.net/NewEntry.aspx",
                                       ["Callsign": QRZClient.baseCall(cfg.callsign), "Code": code, "App": "FT710Control",
                                        "ADIFData": ADIF.record(qso, forUpload: true)])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        if body.contains("<insert>1</insert>") { return .sent(L("Wysłano do HRDLog.net")) }
        if body.lowercased().contains("already") || body.lowercased().contains("duplicate") {
            return .duplicate(L("Już jest w HRDLog.net"))
        }
        if let start = body.range(of: "<error>"), let end = body.range(of: "</error>"), start.upperBound <= end.lowerBound {
            return .failed(String(body[start.upperBound..<end.lowerBound]))
        }
        return .failed(Self.plainText(body).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Cloudlog / Wavelog: POST {serwer}/index.php/api/qso (JSON: key, station_profile_id, type=adif, string).
    private func uploadCloudlog(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let base = cfg.location.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let payload: [String: Any] = ["key": key, "station_profile_id": cfg.path, "type": "adif",
                                      "string": ADIF.record(qso, forUpload: true)]
        let response = await Self.postJSON(base + "/index.php/api/qso", payload)
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let status = (json?["status"] as? String ?? "").lowercased()
        if status == "created" || status == "ok" || response.status == 201 { return .sent(L("Wysłano do Cloudlog")) }
        let reason = json?["reason"] as? String ?? (json?["messages"] as? [String])?.joined(separator: "; ") ?? body
        if reason.lowercased().contains("duplicate") || reason.lowercased().contains("dupe") {
            return .duplicate(L("Już jest w Cloudlog"))
        }
        return .failed(reason)
    }

    private func testCloudlog(_ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let base = cfg.location.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let response = await Self.get(base + "/index.php/api/auth/" + key, [:])
        guard let body = response.body else { return .failed(response.error ?? L("Brak odpowiedzi")) }
        if body.lowercased().contains("valid") && !body.lowercased().contains("invalid") {
            return .sent(L("Połączenie OK: klucz API poprawny"))
        }
        return .failed(Self.plainText(body).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: World Radio League

    private static let wrlBase = "https://api.worldradioleague.com/v1"
    private static let wrlGridPattern = "^[A-Ra-r]{2}(?:[0-9]{2}(?:[A-Xa-x]{2}(?:[0-9]{2})?)?)?$"

    /// Pola łączności w nazwach WRL (ADIF w camelCase). Puste i niepoprawne pola są pomijane,
    /// bo WRL odrzuca nieznane pola i błędne lokatory.
    private static func wrlFields(_ qso: QSO) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = [
            "call": qso.call,
            "timestamp": iso.string(from: qso.start),
            "mode": (qso.submode?.isEmpty == false ? qso.submode! : qso.mode).uppercased()
        ]
        if qso.freqHz > 0 { body["freq"] = Double(qso.freqHz) / 1_000_000 }
        let band = qso.band.isEmpty ? (LogFrequency.band(for: qso.freqHz) ?? "") : qso.band
        if !band.isEmpty { body["band"] = band }
        func text(_ key: String, _ value: String, max: Int) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { body[key] = String(trimmed.prefix(max)) }
        }
        text("rstSent", qso.rstSent, max: 10)
        text("rstRcvd", qso.rstRcvd, max: 10)
        text("name", qso.name, max: 255)
        text("qth", qso.qth, max: 100)
        text("notes", qso.comment, max: 2000)
        text("stationCallsign", qso.stationCall, max: 20)
        if qso.grid.range(of: wrlGridPattern, options: .regularExpression) != nil { body["gridsquare"] = qso.grid }
        if qso.myGrid.range(of: wrlGridPattern, options: .regularExpression) != nil { body["myGridsquare"] = qso.myGrid }
        return body
    }

    /// Odpowiedź WRL: {data, meta, error}; przy błędzie opis z `error.message` i `error.hint`.
    private static func wrlError(_ response: HTTPResponse) -> String {
        guard let body = response.body,
              let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return response.error ?? L("Kod HTTP {1}", response.status)
        }
        var parts = [error["message"] as? String ?? (error["code"] as? String ?? "")]
        if let field = error["field"] as? String { parts.append(L("pole: {1}", field)) }
        if let hint = error["hint"] as? String { parts.append(hint) }
        if response.status == 429, let retry = response.retryAfter { parts.append(L("ponów za {1} s", retry)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " – ")
    }

    private func uploadWRL(_ qso: QSO, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        guard qso.freqHz > 0 else { return .failed(L("World Radio League wymaga częstotliwości - uzupełnij ją w edycji łączności")) }
        var body = Self.wrlFields(qso)
        body["programId"] = "FT710Control"
        let logbook = cfg.path.trimmingCharacters(in: .whitespaces)
        if !logbook.isEmpty { body["logbookId"] = logbook }
        let response = await Self.sendJSON("POST", Self.wrlBase + "/contacts", body, bearer: key)
        guard response.status == 201 || response.status == 200,
              let text = response.body,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            return .failed(Self.wrlError(response))
        }
        if let id = data["id"] as? String { wrlContactIDs[qso.id] = id }
        if data["isDuplicate"] as? Bool == true { return .duplicate(L("Zapisano w World Radio League (oznaczone tam jako duplikat)")) }
        return .sent(L("Wysłano do World Radio League"))
    }

    private func patchWRL(_ qso: QSO, id: String, _ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let response = await Self.sendJSON("PATCH", Self.wrlBase + "/contacts/" + id, Self.wrlFields(qso), bearer: key)
        guard response.status == 200 else { return .failed(Self.wrlError(response)) }
        return .sent(L("Poprawka {1} wysłana do World Radio League", qso.call))
    }

    private func testWRL(_ cfg: LogServiceSettings) async -> UploadResult {
        guard let key = cfg.secret() else { return .failed(L("Brak klucza API")) }
        let response = await Self.sendJSON("GET", Self.wrlBase + "/me", nil, bearer: key)
        guard response.status == 200, let text = response.body,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            return .failed(Self.wrlError(response))
        }
        let tier = data["membershipTier"] as? String ?? "?"
        let resolution = (data["defaultLogbook"] as? [String: Any])?["resolution"] as? String ?? ""
        if !cfg.path.isEmpty || resolution == "configured" || resolution == "sole" {
            return .sent(L("Połączenie OK (konto: {1}). Łączności trafią do {2}.", tier,
                           cfg.path.isEmpty ? L("dziennika domyślnego") : L("wybranego dziennika")))
        }
        // Brak dziennika domyślnego - pokaż listę dzienników z identyfikatorami do wpisania.
        let list = await Self.sendJSON("GET", Self.wrlBase + "/logbooks?limit=100", nil, bearer: key)
        var names: [String] = []
        if let text = list.body,
           let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           let books = json["data"] as? [[String: Any]] {
            names = books.compactMap { book in
                guard let id = book["id"] as? String else { return nil }
                return "\(book["name"] as? String ?? "?") – \(id)"
            }
        }
        if resolution == "none" { return .failed(L("W World Radio League nie ma dziennika - utwórz go na stronie WRL.")) }
        return .failed(L("Masz kilka dzienników i żaden nie jest domyślny. Wpisz ID dziennika: {1}", names.joined(separator: "; ")))
    }

    /// LoTW: podpis i wysyłka programem TQSL (ARRL). Ostatnia linia wyjścia błędów:
    /// „Final Status: Opis (kod)”; 0 = sukces, 8/9 = wszystkie / część to duplikaty.
    private func uploadLoTW(_ qsos: [QSO], _ cfg: LogServiceSettings) async -> UploadResult {
        let adif = ADIF.header() + qsos.map { ADIF.record($0, forUpload: true) }.joined(separator: "\n") + "\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ft710control-lotw-\(UUID().uuidString).adi")
        do {
            try ADIF.asciiFile(adif).write(to: file, atomically: true, encoding: .ascii)
        } catch {
            return .failed(L("Nie udało się zapisać pliku dla TQSL: {1}", error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        var arguments = ["-d", "-u", "-l", cfg.location]
        // hasło w linii poleceń tylko na wyraźne życzenie (widoczne dla innych procesów); bez niego TQSL,
        // jeśli certyfikat ma hasło, pyta o nie sam w swoim okienku
        if cfg.passPasswordToTQSL, let password = cfg.secret(), !password.isEmpty { arguments += ["-p", password] }
        arguments += [file.path, "-x"]
        let result = await Self.run(cfg.path, arguments)
        return Self.interpretTQSL(result.output, exitCode: result.exitCode, count: qsos.count)
    }

    private func testLoTW(_ cfg: LogServiceSettings) async -> UploadResult {
        guard FileManager.default.isExecutableFile(atPath: cfg.path) else {
            return .failed(L("Nie znaleziono programu TQSL: {1}", cfg.path))
        }
        let result = await Self.run(cfg.path, ["-v"])
        let version = result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return .sent(L("TQSL znaleziony {1}. Lokalizacja stacji: „{2}”", version, cfg.location))
    }

    static func interpretTQSL(_ output: String, exitCode: Int32, count: Int) -> UploadResult {
        var code = Int(exitCode)
        let finalLine = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("Final Status") }).map(String.init)
        if let finalLine, let open = finalLine.lastIndex(of: "("), let close = finalLine.lastIndex(of: ")"), open < close,
           let parsed = Int(finalLine[finalLine.index(after: open)..<close]) {
            code = parsed
        }
        switch code {
        case 0: return .sent(L("Wysłano do LoTW: {1} QSO", count))
        case 8: return .duplicate(L("Wszystkie QSO już są w LoTW"))
        case 9: return .sent(L("Wysłano do LoTW (część QSO była już wysłana)"))
        case 11: return .failed(L("Brak połączenia z LoTW"))
        default: return .failed(finalLine ?? L("TQSL zakończył się kodem {1}", code))
        }
    }

    // MARK: - HTTP i procesy

    private struct HTTPResponse {
        var status = 0
        var body: String?
        var error: String?
        var retryAfter: String?
    }

    private static func sendJSON(_ method: String, _ url: String, _ payload: [String: Any]?, bearer: String) async -> HTTPResponse {
        guard let target = URL(string: url) else { return HTTPResponse(error: L("Nieprawidłowy adres")) }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let payload {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return HTTPResponse(error: L("Nieprawidłowe dane łączności"))
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        return await perform(request)
    }

    /// Wartość zakodowana jak w formularzu (ASCII A-Z a-z 0-9 „-._*” bez zmian, reszta %XX z UTF-8).
    static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func formBody(_ fields: [String: String]) -> Data {
        // application/x-www-form-urlencoded: bez kodowania tylko ASCII A-Z a-z 0-9 i „-._*” (WHATWG);
        // CharacterSet.alphanumerics obejmuje też litery Unicode (ą, é) - te muszą być zakodowane jako %XX (UTF-8)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func post(_ url: String, _ fields: [String: String]) async -> HTTPResponse {
        guard let target = URL(string: url) else { return HTTPResponse(error: L("Nieprawidłowy adres")) }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = formBody(fields)
        return await perform(request)
    }

    /// POST multipart/form-data z polami tekstowymi i jednym plikiem.
    private static func postMultipart(_ url: String, _ fields: [String: String], fileField: String, fileName: String,
                                      fileData: Data) async -> HTTPResponse {
        guard let target = URL(string: url) else { return HTTPResponse(error: L("Nieprawidłowy adres")) }
        let boundary = "FT710Control-" + UUID().uuidString
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n"
                          + "Content-Type: application/octet-stream\r\n\r\n").utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return await perform(request, timeout: 120)                // plik całego dziennika - kilka MB
    }

    private static func postJSON(_ url: String, _ payload: [String: Any]) async -> HTTPResponse {
        guard let target = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return HTTPResponse(error: L("Nieprawidłowy adres"))
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        return await perform(request)
    }

    private static func get(_ url: String, _ query: [String: String]) async -> HTTPResponse {
        guard var components = URLComponents(string: url) else { return HTTPResponse(error: L("Nieprawidłowy adres")) }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let target = components.url else { return HTTPResponse(error: L("Nieprawidłowy adres")) }
        var request = URLRequest(url: target)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return await perform(request)
    }

    private static func perform(_ request: URLRequest, timeout: TimeInterval = 20) async -> HTTPResponse {
        var request = request
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return HTTPResponse(status: http?.statusCode ?? 0, body: body,
                                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return HTTPResponse(error: error.localizedDescription)
        }
    }

    /// Uruchamia program (TQSL) w tle; zwraca połączone wyjście i kod zakończenia.
    private static func run(_ path: String, _ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (L("Nie udało się uruchomić TQSL: {1}", error.localizedDescription), -1))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (String(decoding: data, as: UTF8.self), process.terminationStatus))
            }
        }
    }

    /// „A=1&B=2” -> [A: 1, B: 2] (odpowiedzi QRZ Logbook).
    private static func queryFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].uppercased()] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    /// HTML -> zwykły tekst (bez znaczników).
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func firstLine(containing words: [String], in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in words.contains { line.localizedCaseInsensitiveContains($0) } }
    }
}
