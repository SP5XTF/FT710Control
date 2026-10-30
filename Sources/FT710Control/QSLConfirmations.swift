import Foundation

/// Źródło potwierdzeń QSL. Potwierdzenia są zapisywane w standardowych polach ADIF łączności, więc trafiają
/// do eksportu ADIF i kopii dziennika.
enum QSLSource: String, CaseIterable, Identifiable {
    case lotw, eqsl, qrz, clublog

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lotw: return "LoTW"
        case .eqsl: return "eQSL"
        case .qrz: return "QRZ Logbook"
        case .clublog: return "Club Log"
        }
    }

    /// Litera w kolumnie „QSL” dziennika.
    var mark: String {
        switch self {
        case .lotw: return "L"
        case .eqsl: return "E"
        case .qrz: return "Q"
        case .clublog: return "C"
        }
    }

    /// Pole ADIF „potwierdzone” i pole z datą potwierdzenia.
    var receivedField: String {
        switch self {
        case .lotw: return "LOTW_QSL_RCVD"
        case .eqsl: return "EQSL_QSL_RCVD"
        case .qrz: return "APP_QRZLOG_STATUS"
        case .clublog: return "APP_FT710CONTROL_CLUBLOG_RCVD"      // ADIF nie ma pola na dopasowanie Club Log
        }
    }

    var dateField: String {
        switch self {
        case .lotw: return "LOTW_QSLRDATE"
        case .eqsl: return "EQSL_QSLRDATE"
        case .qrz: return "APP_QRZLOG_QSLDATE"
        case .clublog: return "APP_FT710CONTROL_CLUBLOG_RCVDDATE"
        }
    }
}

extension QSO {
    /// Potwierdzenie z danego źródła (LoTW/eQSL: Y albo V, QRZ: C).
    func isConfirmed(by source: QSLSource) -> Bool {
        let value = (extra[source.receivedField] ?? "").uppercased()
        return source == .qrz ? value == "C" : (value == "Y" || value == "V")
    }

    /// Potwierdzona do statystyk: zawsze LoTW, opcjonalnie eQSL i QRZ (do DXCC ARRL liczy się tylko LoTW).
    func isConfirmed(includeEQSL: Bool, includeQRZ: Bool) -> Bool {
        isConfirmed(by: .lotw) || (includeEQSL && isConfirmed(by: .eqsl)) || (includeQRZ && isConfirmed(by: .qrz))
    }

    /// Kolumna „QSL”: litery źródeł, które potwierdziły (np. „L E”).
    var qslMarks: String {
        QSLSource.allCases.filter { isConfirmed(by: $0) }.map(\.mark).joined(separator: " ")
    }
}

/// Potwierdzenie, które nie pasuje do żadnej łączności w dzienniku.
struct QSLUnmatched: Identifiable {
    let id = UUID()
    let source: QSLSource
    let call: String
    let start: Date
    let band: String
    let mode: String
}

/// Dopasowanie potwierdzeń do dziennika wg zaleceń ARRL: znak, pasmo i czas (±30 min); tryb tylko rozstrzyga,
/// gdy pasuje kilka łączności (tryb mógł być zmieniony przy wysyłce). Kolejność: ten sam znak (z /P itp.),
/// ten sam rodzaj trybu, najbliższy czas. Sprawdzone prototypem (7 przypadków).
@MainActor
enum QSLMatcher {
    static let window: TimeInterval = 30 * 60

    /// Indeks: znak podstawowy → pozycje w dzienniku.
    static func index(_ log: [QSO]) -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        for (i, qso) in log.enumerated() { map[QRZClient.baseCall(qso.call), default: []].append(i) }
        return map
    }

    static func match(_ confirmation: QSO, in log: [QSO], index: [String: [Int]]) -> Int? {
        let base = QRZClient.baseCall(confirmation.call)
        let band = confirmation.band.lowercased()
        let family = LogbookStore.modeFamily(mode: confirmation.mode, submode: confirmation.submode)
        var best: (exact: Int, mode: Int, delta: Double, index: Int)?
        for i in index[base] ?? [] {
            let qso = log[i]
            if !band.isEmpty, !qso.band.isEmpty, qso.band.lowercased() != band { continue }
            let delta = abs(qso.start.timeIntervalSince(confirmation.start))
            guard delta <= window else { continue }
            let candidate = (exact: qso.call.uppercased() == confirmation.call.uppercased() ? 0 : 1,
                             mode: LogbookStore.modeFamily(mode: qso.mode, submode: qso.submode) == family ? 0 : 1,
                             delta: delta, index: i)
            if let b = best {
                if (candidate.exact, candidate.mode, candidate.delta) < (b.exact, b.mode, b.delta) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best?.index
    }
}

/// Pobieranie potwierdzeń z LoTW, eQSL i QRZ Logbook oraz import z pliku ADIF (np. HRDLog, który nie ma
/// interfejsu pobierania). Pobierane są tylko nowe potwierdzenia od ostatniego razu (albo wszystkie - „od początku”).
@MainActor
final class QSLDownloader: ObservableObject {
    static let shared = QSLDownloader()

    @Published private(set) var busy: QSLSource?
    @Published private(set) var importing = false
    @Published private(set) var status: [QSLSource: String] = [:]
    @Published private(set) var errors: Set<QSLSource> = []
    @Published private(set) var unmatched: [QSLUnmatched] = []
    @Published private(set) var lastSummary = ""

    private weak var store: LogbookStore?
    private weak var uploader: LogUploader?
    private let defaults = UserDefaults.standard

    func attach(store: LogbookStore, uploader: LogUploader) {
        self.store = store
        self.uploader = uploader
    }

    /// Data ostatniego pobrania (do opisu w oknie).
    func lastDownload(_ source: QSLSource) -> Date? {
        defaults.object(forKey: "qsl.\(source.rawValue).lastRun") as? Date
    }

    func isConfigured(_ source: QSLSource) -> Bool {
        guard let uploader else { return false }
        switch source {
        case .lotw:
            let cfg = uploader.config(.lotw)
            return !cfg.account.isEmpty && cfg.hasSecondSecret
        case .eqsl: return uploader.config(.eqsl).isConfigured
        case .qrz: return uploader.config(.qrzLogbook).hasSecret
        case .clublog: return uploader.config(.clublog).isConfigured
        }
    }

    // MARK: - Pobieranie

    func download(_ source: QSLSource, full: Bool) {
        guard busy == nil else { return }
        Task { _ = await perform(source, full: full) }
    }

    /// Pobranie z jednego źródła i zapis do dziennika; wynik (albo nil przy błędzie) - do podsumowania.
    private func perform(_ source: QSLSource, full: Bool) async -> ApplyResult? {
        guard busy == nil, let uploader else { return nil }
        busy = source
        errors.remove(source)
        status[source] = L("Pobieranie…")
        defer { busy = nil }
        let result: Result<[QSO], QSLError>
        switch source {
        case .lotw: result = await fetchLoTW(uploader.config(.lotw), full: full)
        case .eqsl: result = await fetchEQSL(uploader.config(.eqsl), full: full)
        case .qrz: result = await fetchQRZ(uploader.config(.qrzLogbook), full: full)
        case .clublog: result = await fetchClubLog(uploader.config(.clublog), full: full)
        }
        switch result {
        case .success(let confirmations):
            let applied = apply(confirmations, source: source)
            status[source] = applied.summary
            defaults.set(Date(), forKey: "qsl.\(source.rawValue).lastRun")
            return applied
        case .failure(let error):
            status[source] = L("Błąd: {1}", error.message)
            errors.insert(source)
            return nil
        }
    }

    // MARK: - Automatyczne pobieranie (raz dziennie, w tle)

    /// Pobieranie raz na dobę z każdego skonfigurowanego serwisu; po nowych potwierdzeniach - alert
    /// („5 nowych potwierdzeń, w tym nowy kraj: …”).
    @Published var autoDownload: Bool = UserDefaults.standard.object(forKey: "qsl.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoDownload, forKey: "qsl.auto") }
    }
    @Published private(set) var lastAutoCheck: Date?
    private var autoTimer: Timer?
    private static let autoInterval: TimeInterval = 24 * 3600

    /// Start harmonogramu: pierwsze sprawdzenie 2 min po starcie programu, potem co godzinę.
    func startAuto() {
        guard autoTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            Task { @MainActor in await self?.autoCheck() }
        }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoCheck() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
    }

    /// Serwisy, których ostatnie pobranie było ponad dobę temu (albo nigdy) - po kolei, tylko nowe potwierdzenia.
    func autoCheck() async {
        guard autoDownload, busy == nil, !importing else { return }
        lastAutoCheck = Date()
        var total = 0
        var entities: [String] = []
        var sources: [String] = []
        for source in QSLSource.allCases where isConfigured(source) {
            if let last = lastDownload(source), Date().timeIntervalSince(last) < Self.autoInterval - 600 { continue }
            guard let result = await perform(source, full: false) else { continue }
            if result.newly > 0 {
                total += result.newly
                sources.append(source.name)
                for name in result.newEntities where !entities.contains(name) { entities.append(name) }
            }
        }
        if total > 0 { AlertCenter.shared.confirmationsArrived(count: total, entities: entities, sources: sources) }
    }

    /// Następne automatyczne pobranie danego serwisu (do opisu w oknie).
    func nextAuto(_ source: QSLSource) -> Date? {
        guard autoDownload, isConfigured(source) else { return nil }
        return (lastDownload(source) ?? Date()).addingTimeInterval(Self.autoInterval)
    }

    /// Po kolei, z czekaniem na wynik każdego serwisu (równoległe pobieranie jest blokowane).
    func downloadAll() {
        guard busy == nil else { return }
        Task {
            for source in QSLSource.allCases where isConfigured(source) { _ = await perform(source, full: false) }
        }
    }

    struct QSLError: Error {
        let message: String
    }

    /// LoTW: lotwreport.adi, tylko potwierdzenia (qso_qsl=yes) od ostatniego APP_LoTW_LASTQSL, ze szczegółami
    /// stacji potwierdzającej (kraj, strefy, lokator). Błąd = strona HTML bez znacznika <eoh>.
    private func fetchLoTW(_ cfg: LogServiceSettings, full: Bool) async -> Result<[QSO], QSLError> {
        guard !cfg.account.isEmpty, let password = cfg.secondSecret() else {
            return .failure(QSLError(message: L("podaj login i hasło do strony LoTW w „Usługach online”")))
        }
        let key = "qsl.lotw.lastQSL"
        let since = full ? "1945-01-01" : (defaults.string(forKey: key) ?? "1945-01-01")
        let query = [("login", cfg.account), ("password", password), ("qso_query", "1"), ("qso_qsl", "yes"),
                     ("qso_qslsince", since), ("qso_qsldetail", "yes")]
            .map { $0.0 + "=" + LogUploader.formEncode($0.1) }.joined(separator: "&")
        guard let url = URL(string: "https://lotw.arrl.org/lotwuser/lotwreport.adi?" + query) else {
            return .failure(QSLError(message: L("Nieprawidłowy adres")))
        }
        switch await Self.get(url, timeout: 300) {                 // LoTW bywa wolne - duże dzienniki do kilku minut
        case .failure(let error): return .failure(error)
        case .success(let text):
            guard text.range(of: "<eoh>", options: .caseInsensitive) != nil else {
                return .failure(QSLError(message: Self.htmlText(text, fallback: L("LoTW odrzucił logowanie"))))
            }
            if let last = Self.headerValue("APP_LoTW_LASTQSL", in: text) { defaults.set(last, forKey: key) }
            return .success(ADIF.parse(text).compactMap(ADIF.qso(from:)))
        }
    }

    /// eQSL: DownloadInBox.cfm buduje plik ADIF ze skrzynki odbiorczej (potwierdzenia od innych) i zwraca stronę
    /// z odnośnikiem do niego; drugi krok pobiera plik. RcvdSince = ostatnie pobranie (RRRRMMDDGGMM, UTC).
    private func fetchEQSL(_ cfg: LogServiceSettings, full: Bool) async -> Result<[QSO], QSLError> {
        guard !cfg.account.isEmpty, let password = cfg.secret() else {
            return .failure(QSLError(message: L("podaj użytkownika i hasło eQSL w „Usługach online”")))
        }
        let key = "qsl.eqsl.rcvdSince"
        var fields = [("UserName", cfg.account), ("Password", password)]
        if !cfg.location.isEmpty { fields.append(("QTHNickname", cfg.location)) }
        if !full, let since = defaults.string(forKey: key) { fields.append(("RcvdSince", since)) }
        let started = Self.eqslStamp(Date())
        let query = fields.map { $0.0 + "=" + LogUploader.formEncode($0.1) }.joined(separator: "&")
        guard let pageURL = URL(string: "https://www.eqsl.cc/qslcard/DownloadInBox.cfm?" + query) else {
            return .failure(QSLError(message: L("Nieprawidłowy adres")))
        }
        let page: String
        switch await Self.get(pageURL, timeout: 120) {
        case .failure(let error): return .failure(error)
        case .success(let text): page = text
        }
        // Odnośnik do zbudowanego pliku ADIF; bez niego - komunikat eQSL („Error: …”) albo po prostu brak nowych eQSL.
        guard let link = Self.adifLink(in: page, base: pageURL) else {
            let text = Self.plainText(fromHTML: page)
            if let error = text.range(of: "error", options: .caseInsensitive) {
                let message = String(text[error.lowerBound...])
                return .failure(QSLError(message: message.count > 200 ? String(message.prefix(200)) + "…" : message))
            }
            defaults.set(started, forKey: key)
            return .success([])                                       // nic nowego w skrzynce
        }
        switch await Self.get(link, timeout: 120) {
        case .failure(let error): return .failure(error)
        case .success(let text):
            defaults.set(started, forKey: key)
            // skrzynka odbiorcza eQSL = potwierdzenia od korespondentów
            return .success(ADIF.parse(text).compactMap(ADIF.qso(from:)))
        }
    }

    /// QRZ Logbook: FETCH ze STATUS:CONFIRMED, stronami po 250 (MAX:250,AFTERLOGID:n - zalecenie QRZ);
    /// kolejne pobrania tylko rekordy zmienione od ostatniego (MODSINCE). Wymaga subskrypcji QRZ.
    private func fetchQRZ(_ cfg: LogServiceSettings, full: Bool) async -> Result<[QSO], QSLError> {
        guard let key = cfg.secret() else {
            return .failure(QSLError(message: L("podaj klucz API dziennika QRZ w „Usługach online”")))
        }
        let sinceKey = "qsl.qrz.modSince"
        let today = Self.isoDay(Date())
        let since = full ? nil : defaults.string(forKey: sinceKey)
        var all: [QSO] = []
        var afterLogID = 0
        for _ in 0..<400 {                                            // do 100 000 rekordów
            var option = "STATUS:CONFIRMED,MAX:250,AFTERLOGID:\(afterLogID)"
            if let since { option += ",MODSINCE:\(since)" }
            guard let url = URL(string: "https://logbook.qrz.com/api") else { break }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = LogUploader.formBody(["KEY": key, "ACTION": "FETCH", "OPTION": option])
            let body: String
            switch await Self.send(request, timeout: 120) {
            case .failure(let error): return .failure(error)
            case .success(let text): body = text
            }
            let fields = Self.qrzFields(body)
            guard fields["RESULT"] == "OK" else {
                let reason = fields["REASON"] ?? ""
                // brak pasujących rekordów to nie błąd
                if Int(fields["COUNT"] ?? "") == 0 || reason.lowercased().contains("no log entries")
                    || reason.lowercased().contains("not found") { break }
                return .failure(QSLError(message: reason.isEmpty ? L("QRZ odrzucił zapytanie (subskrypcja?)") : reason))
            }
            let records = ADIF.parse(fields["ADIF"] ?? "")
            all += records.compactMap(ADIF.qso(from:))
            let ids = records.compactMap { Int($0["APP_QRZLOG_LOGID"] ?? "") }
            guard records.count >= 250, let maxID = ids.max() else { break }
            afterLogID = maxID + 1
        }
        defaults.set(today, forKey: sinceKey)
        return .success(all)
    }

    /// Club Log: getmatches.php (oficjalna dokumentacja Club Log) - dopasowania dzienników obu stacji (±15 min),
    /// JSON: [[znak, DXCC, "RRRR-MM-DD GG:MM:SS", pasmo, tryb], …]. Tylko nowe od ostatniego pobrania, z dniem
    /// zapasu (zalecenie Club Log). Wymaga klucza API programu i hasła aplikacji (jak wysyłka).
    private func fetchClubLog(_ cfg: LogServiceSettings, full: Bool) async -> Result<[QSO], QSLError> {
        guard !cfg.account.isEmpty, !cfg.callsign.isEmpty, let password = cfg.secret(), let apiKey = cfg.secondSecret() else {
            return .failure(QSLError(message: L("uzupełnij Club Log w „Usługach online” (e-mail, znak, hasło aplikacji, klucz API)")))
        }
        if let halted = uploader?.clubLogHalted {
            return .failure(QSLError(message: L("Club Log wstrzymany po błędzie wysyłki ({1}) - popraw ustawienia", halted)))
        }
        let key = "qsl.clublog.since"
        let started = Date()
        var fields = [("api", apiKey), ("email", cfg.account), ("password", password), ("callsign", cfg.callsign)]
        if !full, let since = defaults.string(forKey: key) {
            let parts = since.split(separator: "-").map(String.init)
            if parts.count == 3 { fields += [("startyear", parts[0]), ("startmonth", parts[1]), ("startday", parts[2])] }
        }
        let query = fields.map { $0.0 + "=" + LogUploader.formEncode($0.1) }.joined(separator: "&")
        guard let url = URL(string: "https://clublog.org/getmatches.php?" + query) else {
            return .failure(QSLError(message: L("Nieprawidłowy adres")))
        }
        switch await Self.get(url, timeout: 120) {
        case .failure(let error): return .failure(error)
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                if trimmed.isEmpty || trimmed == "[]" || trimmed == "null" {
                    defaults.set(Self.isoDay(started.addingTimeInterval(-86_400)), forKey: key)
                    return .success([])
                }
                return .failure(QSLError(message: Self.htmlText(text, fallback: L("nieoczekiwana odpowiedź Club Log"))))
            }
            // następnym razem: od wczoraj (dzień zapasu)
            defaults.set(Self.isoDay(started.addingTimeInterval(-86_400)), forKey: key)
            return .success(rows.compactMap(Self.clubLogMatch))
        }
    }

    /// Jedno dopasowanie Club Log → łączność do porównania z dziennikiem.
    static func clubLogMatch(_ row: [Any]) -> QSO? {
        func text(_ i: Int) -> String {
            guard row.indices.contains(i) else { return "" }
            if let s = row[i] as? String { return s }
            if let n = row[i] as? NSNumber { return n.stringValue }
            return ""
        }
        let call = text(0).uppercased()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard !call.isEmpty, let date = f.date(from: text(2)) else { return nil }
        var q = QSO(call: call, start: date, end: nil, freqHz: 0, band: clubLogBand(text(3)), mode: text(4) == "false" ? "" : text(4),
                    submode: nil)
        if !text(1).isEmpty, text(1) != "0" { q.extra["DXCC"] = text(1) }
        return q
    }

    /// Identyfikator pasma Club Log (np. 20 = 20 m, 70 = 70 cm) → nazwa pasma w dzienniku.
    static func clubLogBand(_ id: String) -> String {
        switch id {
        case "70": return "70cm"
        case "23": return "23cm"
        case "13": return "13cm"
        case "222": return "1.25m"
        case "": return ""
        default: return id + "m"
        }
    }

    // MARK: - Import potwierdzeń z pliku ADIF

    /// Plik ADIF z potwierdzeniami (np. raport LoTW, eksport z eQSL, QRZ albo innego programu). Brane są pola
    /// LOTW_QSL_RCVD, EQSL_QSL_RCVD, APP_QRZLOG_STATUS; plik raportu LoTW (PROGRAMID LoTW) - pole QSL_RCVD.
    func importFile(_ url: URL) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            lastSummary = L("Nie udało się odczytać pliku.")
            return
        }
        importing = true
        let isLoTWReport = text.range(of: "<PROGRAMID:4>LoTW", options: .caseInsensitive) != nil
        let records = ADIF.parse(text).compactMap(ADIF.qso(from:))
        var parts: [String] = []
        for source in QSLSource.allCases {
            let confirmations = records.filter { record in
                if source == .lotw, isLoTWReport { return ["Y", "V"].contains((record.extra["QSL_RCVD"] ?? "").uppercased()) }
                return record.isConfirmed(by: source)
            }
            if !confirmations.isEmpty { parts.append(source.name + ": " + apply(confirmations, source: source).summary) }
        }
        lastSummary = parts.isEmpty ? L("W pliku nie ma potwierdzeń (pola LOTW_QSL_RCVD, EQSL_QSL_RCVD, APP_QRZLOG_STATUS).")
                                    : parts.joined(separator: " · ")
        importing = false
    }

    // MARK: - Zapis do dziennika

    /// Oznacza dopasowane łączności jako potwierdzone (jeden zapis pliku). Uzupełnia też puste pola danymi
    /// stacji potwierdzającej (kraj, DXCC, strefy, kontynent, lokator) - wpisanych danych nie nadpisuje.
    struct ApplyResult {
        var newly = 0, already = 0, unmatched = 0
        /// Kraje DXCC, które tym pobraniem stały się potwierdzone (wg ustawień „licz też…”).
        var newEntities: [String] = []
        var summary: String {
            L("nowe potwierdzenia: {1}, już były: {2}, bez dopasowania: {3}", newly, already, unmatched)
                + (newEntities.isEmpty ? "" : " · " + L("nowe kraje: {1}", newEntities.joined(separator: ", ")))
        }
    }

    /// Kraje potwierdzone w dzienniku (klucze DXCC) - do wykrycia nowo potwierdzonych.
    private func confirmedEntities(_ qsos: [QSO]) -> Set<String> {
        guard let table = CTYDatabase.shared.table else { return [] }
        let d = UserDefaults.standard
        let eqsl = d.bool(forKey: "qsl.countEQSL"), qrz = d.bool(forKey: "qsl.countQRZ")
        var keys = Set<String>()
        for qso in qsos where qso.isConfirmed(includeEQSL: eqsl, includeQRZ: qrz) {
            if let match = table.lookup(qso.call) { keys.insert(CTYTable.dxccKey(match)) }
        }
        return keys
    }

    private func apply(_ confirmations: [QSO], source: QSLSource) -> ApplyResult {
        guard let store else { return ApplyResult() }
        let confirmedBefore = confirmedEntities(store.qsos)
        var log = store.qsos
        let index = QSLMatcher.index(log)
        var changed: [Int: QSO] = [:]
        var newly = 0, already = 0
        var orphans: [QSLUnmatched] = []
        let today = ADIF.adifDate(Date())
        for confirmation in confirmations {
            guard let i = QSLMatcher.match(confirmation, in: log, index: index) else {
                orphans.append(QSLUnmatched(source: source, call: confirmation.call, start: confirmation.start,
                                            band: confirmation.band, mode: confirmation.submode ?? confirmation.mode))
                continue
            }
            var qso = changed[i] ?? log[i]
            if qso.isConfirmed(by: source) { already += 1 } else { newly += 1 }
            qso.extra[source.receivedField] = source == .qrz ? "C" : "Y"
            let date: String?
            switch source {
            case .lotw: date = confirmation.extra["QSLRDATE"] ?? confirmation.extra["LOTW_QSLRDATE"]
            case .eqsl: date = confirmation.extra["QSLRDATE"] ?? confirmation.extra["EQSL_QSLRDATE"]
            case .qrz: date = confirmation.extra["APP_QRZLOG_QSLDATE"]
            case .clublog: date = nil                              // Club Log nie podaje daty dopasowania
            }
            if qso.extra[source.dateField]?.isEmpty ?? true { qso.extra[source.dateField] = date ?? today }
            // Club Log: numer DXCC z jego dokładnego mapowania (także P4/WE9V) - tylko do pustego pola
            if source == .clublog, let dxcc = confirmation.extra["DXCC"], !dxcc.isEmpty, qso.extra["DXCC"]?.isEmpty ?? true {
                qso.extra["DXCC"] = dxcc
            }
            if source == .lotw {
                for field in ["DXCC", "COUNTRY", "CQZ", "ITUZ", "CONT", "STATE", "CNTY", "IOTA", "CREDIT_GRANTED"] {
                    if let value = confirmation.extra[field], !value.isEmpty, qso.extra[field]?.isEmpty ?? true {
                        qso.extra[field] = value
                    }
                }
                if qso.grid.isEmpty, !confirmation.grid.isEmpty { qso.grid = confirmation.grid }
            }
            changed[i] = qso
            log[i] = qso
        }
        store.update(Array(changed.values))
        unmatched.removeAll { $0.source == source }
        unmatched += orphans
        var result = ApplyResult(newly: newly, already: already, unmatched: orphans.count)
        if newly > 0, let table = CTYDatabase.shared.table {
            result.newEntities = confirmedEntities(store.qsos).subtracting(confirmedBefore)
                .map { table.dxccName($0) ?? $0 }.sorted()
        }
        return result
    }

    // MARK: - HTTP i pomocnicze

    private static func get(_ url: URL, timeout: TimeInterval) async -> Result<String, QSLError> {
        await send(URLRequest(url: url), timeout: timeout)
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) async -> Result<String, QSLError> {
        var request = request
        request.timeoutInterval = timeout
        request.setValue(LogUploader.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard code == 200 else {
                return .failure(QSLError(message: L("Kod HTTP {1}: {2}", code, htmlText(text, fallback: ""))))
            }
            return .success(text)
        } catch {
            return .failure(QSLError(message: error.localizedDescription))
        }
    }

    /// Pola odpowiedzi QRZ (NAZWA=wartość&…). ADIF bywa zwykły, zakodowany URL-em albo z encjami HTML (&lt;),
    /// więc dzielimy tylko na znanych nazwach pól (sprawdzone prototypem dla wszystkich trzech wariantów).
    static func qrzFields(_ body: String) -> [String: String] {
        let keys = ["RESULT", "COUNT", "LOGIDS", "REASON", "LOGID", "DATA", "ADIF"]
        guard let regex = try? NSRegularExpression(pattern: "(?:^|&)(" + keys.joined(separator: "|") + ")=") else { return [:] }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var fields: [String: String] = [:]
        for (n, match) in matches.enumerated() {
            let name = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = n + 1 < matches.count ? matches[n + 1].range.location : ns.length
            var value = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            if name == "ADIF" {
                if value.uppercased().contains("%3C") {
                    value = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
                }
                if value.contains("&lt;") {
                    value = value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                        .replacingOccurrences(of: "&amp;", with: "&")
                }
            } else {
                value = value.removingPercentEncoding ?? value
            }
            fields[name] = value
        }
        return fields
    }

    /// Wartość pola nagłówka ADIF (np. APP_LoTW_LASTQSL).
    static func headerValue(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "<" + name + ":", options: .caseInsensitive),
              let close = text[range.upperBound...].firstIndex(of: ">"),
              let length = Int(text[range.upperBound..<close].split(separator: ":").first ?? "") else { return nil }
        let start = text.index(after: close)
        guard let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) else { return nil }
        return String(text[start..<end])
    }

    /// Tekst ze strony HTML (komunikat błędu serwisu), skrócony.
    static func htmlText(_ html: String, fallback: String) -> String {
        let text = plainText(fromHTML: html)
        if text.isEmpty { return fallback }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    /// Widoczny tekst strony: bez skryptów, stylów i komentarzy (inaczej komunikat ginie za kodem JavaScript),
    /// z podstawowymi encjami HTML zamienionymi na znaki.
    static func plainText(fromHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "(?is)<script\\b.*?</script\\s*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style\\b.*?</style\\s*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Odnośnik do pliku .adi na stronie eQSL (cudzysłów podwójny, pojedynczy albo bez; .adi / .ADI).
    static func adifLink(in page: String, base: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "href\\s*=\\s*[\"']?([^\"' >]+\\.adi)", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let range = Range(match.range(at: 1), in: page) else { return nil }
        return URL(string: String(page[range]), relativeTo: base)?.absoluteURL
    }

    private static func eqslStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: date)
    }

    private static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
