import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Zawody: wpisywanie łączności, ocena w trakcie pisania (dubel, punkty, nowe mnożniki), osobny log zawodów
/// (plik na sesję, edycja i usuwanie), dane z QRZ, wynik i tempo na żywo, eksport Cabrillo, przeniesienie
/// łączności do głównego dziennika na żądanie („Dodaj do dziennika…”).
@MainActor
final class ContestManager: ObservableObject {
    @Published var session: ContestSession {
        didSet {
            saveSession()
            if session.id != oldValue.id { loadLog() }
            refresh()
        }
    }
    /// Log bieżących zawodów (osobny od głównego dziennika), najstarsze pierwsze.
    @Published private(set) var qsos: [QSO] = []
    /// Dane z QRZ dla wpisywanego znaku (imię, QTH, lokator).
    let lookup = CallLookup()
    /// Stacje zrobione w zawodach (na paśmie, wg reguł dubli zawodów) na skopie: czerwone, ukryte albo bez zmian.
    @Published var scopeWorked: ContestScopeWorked {
        didSet { UserDefaults.standard.set(scopeWorked.rawValue, forKey: "contest.scopeWorked") }
    }
    /// Klucze dubli zrobionych łączności (znak|pasmo albo znak|pasmo|emisja) - do skopu.
    @Published private(set) var workedKeys: Set<String> = []
    @Published var call = "" { didSet { callChanged(oldValue) } }
    @Published var rstRcvd = "599"
    @Published var exchange = "" { didSet { if exchange != oldValue { evaluate() } } }
    @Published private(set) var evaluation = ContestEvaluation()
    @Published private(set) var score = ContestScore()
    @Published private(set) var recent: [QSO] = []
    @Published private(set) var rate10 = 0
    @Published private(set) var rate60 = 0
    @Published var message: String?

    static let sessionField = "APP_FT710CONTROL_SESSION"
    private weak var logbook: LogbookStore?
    private weak var cat: CATClient?
    private weak var qrz: QRZClient?
    private let cty = CTYDatabase.shared
    private var infos: [ContestQSOInfo] = []
    private var sessionQSOs: [QSO] = []
    private var exchangeIsSuggestion = true
    private var dupeConfirmed = false
    private var observers: [AnyCancellable] = []

    init() {
        scopeWorked = ContestScopeWorked(rawValue: UserDefaults.standard.string(forKey: "contest.scopeWorked") ?? "") ?? .red
        if let data = UserDefaults.standard.data(forKey: "contest.session"),
           let saved = try? JSONDecoder().decode(ContestSession.self, from: data) {
            session = saved
        } else if let latest = Self.latestArchivedSession() {
            // brak zapisanych bieżących zawodów (np. inna kopia programu: z Xcode / z DMG) - ostatnio używany log
            session = latest
        } else {
            session = ContestSession()
        }
        loadLog()
    }

    func attach(logbook: LogbookStore, cat: CATClient, qrz: QRZClient) {
        guard self.logbook == nil else { return }
        self.logbook = logbook
        self.cat = cat
        self.qrz = qrz
        observers.append(cty.$table.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } })
        observers.append(cat.$modeCode.sink { [weak self] _ in DispatchQueue.main.async { self?.applyDefaultRST() } })
        if session.myExchange.isEmpty { session.myExchange = ContestEngine.defaultMyExchange(kind: session.kind, me: me) }
        refresh()
    }

    private func saveSession() {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: "contest.session")
        try? data.write(to: Self.sessionURL(session.id), options: .atomic)   // ustawienia zawodów obok ich logu
    }

    // MARK: - Archiwum zawodów („Poprzednie zawody…”)

    private static var contestsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FT710Control/Contests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sessionURL(_ id: UUID) -> URL {
        contestsDirectory.appendingPathComponent(id.uuidString + ".session.json")
    }

    /// Zawody z archiwum: plik logu (i ustawień) albo - ze starszych wersji - łączności w głównym dzienniku.
    struct ArchiveEntry: Identifiable {
        let id: UUID
        let title: String
        let qsoCount: Int
        let first: Date?
        let last: Date?
        let inLogbookOnly: Bool
    }

    /// Ustawienia zawodów: z pliku obok logu, a dla starszych logów - odtworzone z łączności (CONTEST_ID, czas).
    private static func archivedSession(_ id: UUID, qsos: [QSO]) -> ContestSession {
        if let data = try? Data(contentsOf: sessionURL(id)), let saved = try? JSONDecoder().decode(ContestSession.self, from: data) {
            return saved
        }
        var session = ContestSession(id: id)
        if let contestID = qsos.first(where: { $0.extra["CONTEST_ID"] != nil })?.extra["CONTEST_ID"] {
            outer: for kind in ContestKind.allCases {
                for mode in ContestMode.allCases where kind.cabrilloName(mode: mode) == contestID {
                    session.kind = kind
                    session.mode = mode
                    break outer
                }
            }
        }
        if let first = qsos.map(\.start).min() { session.started = first }
        return session
    }

    private static func readLog(_ id: UUID) -> [QSO] {
        guard let data = try? Data(contentsOf: fileURL(id)),
              let list = try? JSONDecoder().decode([QSO].self, from: data) else { return [] }
        return list
    }

    /// Ostatnio zmieniany log zawodów (z jego ustawieniami) - albo nil, gdy nie ma żadnego.
    private static func latestArchivedSession() -> ContestSession? {
        let files = (try? FileManager.default.contentsOfDirectory(at: contestsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let logs = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".session.json") }
        let newest = logs.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        guard let newest, let id = UUID(uuidString: newest.deletingPathExtension().lastPathComponent) else { return nil }
        return archivedSession(id, qsos: readLog(id))
    }

    /// Wszystkie zawody: pliki logów oraz sesje ze starszych wersji zapisane tylko w głównym dzienniku.
    func archive() -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var seen = Set<UUID>()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.contestsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".session.json") {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let list = id == session.id ? qsos : Self.readLog(id)
            let s = id == session.id ? session : Self.archivedSession(id, qsos: list)
            entries.append(ArchiveEntry(id: id, title: s.cabrilloName, qsoCount: list.count,
                                        first: list.map(\.start).min(), last: list.map(\.start).max(), inLogbookOnly: false))
            seen.insert(id)
        }
        if let logbook {
            let grouped = Dictionary(grouping: logbook.qsos.filter { $0.extra[Self.sessionField] != nil }) { $0.extra[Self.sessionField] ?? "" }
            for (key, list) in grouped {
                guard let id = UUID(uuidString: key), !seen.contains(id) else { continue }
                let s = Self.archivedSession(id, qsos: list)
                entries.append(ArchiveEntry(id: id, title: s.cabrilloName, qsoCount: list.count,
                                            first: list.map(\.start).min(), last: list.map(\.start).max(), inLogbookOnly: true))
            }
        }
        return entries.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    /// Otwarcie zawodów z archiwum: log z pliku albo - dla starszych wersji - skopiowany z głównego dziennika.
    func open(_ id: UUID) {
        guard id != session.id else { return }
        if !FileManager.default.fileExists(atPath: Self.fileURL(id).path), let logbook {
            let list = logbook.qsos.filter { $0.extra[Self.sessionField] == id.uuidString }.sorted { $0.start < $1.start }
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.fileURL(id), options: .atomic) }
        }
        session = Self.archivedSession(id, qsos: Self.readLog(id))   // didSet: zapis, wczytanie logu, przeliczenie
        clearEntry()
        message = L("Otwarto zawody: {1} ({2} QSO)", session.cabrilloName, qsos.count)
    }

    // MARK: - Log zawodów (plik na sesję)

    /// ~/Library/Application Support/FT710Control/Contests/<id sesji>.json
    private static func fileURL(_ id: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FT710Control/Contests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.uuidString + ".json")
    }

    private func loadLog() {
        let url = Self.fileURL(session.id)
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([QSO].self, from: data) {
            qsos = list.sorted { $0.start < $1.start }
        } else {
            qsos = []
        }
    }

    private func saveLog() {
        guard let data = try? JSONEncoder().encode(qsos) else { return }
        do {
            try data.write(to: Self.fileURL(session.id), options: .atomic)
        } catch {
            message = L("Zapis logu zawodów nie powiódł się: {1}", error.localizedDescription)
        }
    }

    /// Zmiana łączności w logu zawodów (okno edycji).
    func update(_ qso: QSO) {
        guard let index = qsos.firstIndex(where: { $0.id == qso.id }) else { return }
        qsos[index] = qso
        qsos.sort { $0.start < $1.start }
        saveLog()
        refresh()
    }

    /// Usunięcie łączności z logu zawodów (główny dziennik bez zmian).
    func delete(_ ids: Set<UUID>) {
        let before = qsos.count
        qsos.removeAll { ids.contains($0.id) }
        guard qsos.count != before else { return }
        saveLog()
        refresh()
        message = L("Usunięto z logu zawodów: {1}", before - qsos.count)
    }

    /// Ile łączności zawodów nie ma jeszcze w głównym dzienniku (ten sam znak, pasmo, czas ±2 min albo ta sama łączność).
    func notInLogbook() -> [QSO] {
        guard let logbook else { return [] }
        var index: [String: [QSO]] = [:]
        for q in logbook.qsos { index[QRZClient.baseCall(q.call), default: []].append(q) }
        let ids = Set(logbook.qsos.map(\.id))
        return qsos.filter { q in
            if ids.contains(q.id) { return false }
            return !(index[QRZClient.baseCall(q.call)] ?? []).contains {
                $0.band.lowercased() == q.band.lowercased() && abs($0.start.timeIntervalSince(q.start)) <= 120
            }
        }
    }

    /// Stacja zrobiona już w tych zawodach - ta sama reguła co ostrzeżenie o dublu (CQ WW: znak + pasmo;
    /// zawody liczone na emisje: także emisja).
    func isWorked(call: String, band: String, mode: String) -> Bool {
        workedKeys.contains(ContestEngine.dupeKey(kind: session.kind, call: call, band: band, mode: Self.group(mode)))
    }

    /// Ostatnio zapisana łączność zawodów (do przycisku „Spot”).
    var lastLogged: QSO? { qsos.max { $0.start < $1.start } }

    /// Polecenie spotu dla DX Cluster: „DX <kHz> <znak> <komentarz>” (komentarz: nazwa zawodów).
    func spotCommand(_ qso: QSO) -> String {
        "DX " + String(format: "%.1f", Double(qso.freqHz) / 1000) + " " + qso.call.uppercased() + " " + session.kind.name
    }

    /// Dodanie łączności zawodów do głównego dziennika (bez automatycznej wysyłki - „Wyślij zaległe” w Usługach).
    func addToLogbook() {
        guard let logbook else { return }
        let list = notInLogbook()
        logbook.addImported(list)
        message = L("Dodano do dziennika: {1}, pominięto już obecne: {2}. Wysyłka do serwisów: Usługi online → Wyślij zaległe.",
                    list.count, qsos.count - list.count)
    }

    // MARK: - Stan

    var myCall: String { logbook?.myCall.uppercased() ?? "" }
    var me: CTYMatch? { cty.table?.lookup(myCall) }
    var role: ContestRole { ContestEngine.role(kind: session.kind, me: me) }
    var sendsSerial: Bool { ContestEngine.sendsSerial(kind: session.kind, role: role) }
    var nextSerial: Int { sessionQSOs.count + 1 }
    var receivedLabel: String { ContestEngine.receivedLabel(kind: session.kind, role: role) }
    var ctyReady: Bool { cty.table != nil }

    /// Czy odbierana wymiana to numer kolejny.
    var receivesSerial: Bool {
        switch session.kind {
        case .cqwpx, .generic: return true
        case .spdx: return role == .spStation
        default: return false
        }
    }

    /// Grupa emisji bieżącej łączności (dla dubli i pola MODE).
    var modeGroup: String {
        if session.mode != .mixed { return session.mode.rawValue }
        switch cat?.modeCode ?? "" {
        case "3", "7": return "CW"
        case "6", "9", "8", "C": return "RTTY"
        default: return "SSB"
        }
    }

    var rstSent: String { modeGroup == "SSB" ? "59" : "599" }

    /// Tekst wymiany, którą nadaję (do wyświetlenia).
    var sentExchange: String {
        sendsSerial ? "\(rstSent) \(String(format: "%03d", nextSerial))" : "\(rstSent) \(session.myExchange)"
    }

    var currentBand: String { LogFrequency.band(for: cat?.activeFreq ?? 0) ?? "" }

    // MARK: - Wpisywanie

    private func callChanged(_ old: String) {
        let cleaned = call.uppercased().filter { !$0.isWhitespace }
        if cleaned != call { call = cleaned; return }
        dupeConfirmed = false
        if cleaned.count >= 3, let qrz { lookup.request(cleaned, using: qrz, debounce: true) } else { lookup.clear() }
        if exchangeIsSuggestion || exchange.isEmpty {
            let suggestion = ContestEngine.suggestedExchange(kind: session.kind, other: cty.table?.lookup(call))
            exchange = suggestion
            exchangeIsSuggestion = true
        }
        evaluate()
    }

    /// Ręczna zmiana wymiany - podpowiedź z bazy krajów przestaje ją nadpisywać.
    func exchangeEdited() { exchangeIsSuggestion = false }

    private func applyDefaultRST() {
        if call.isEmpty { rstRcvd = rstSent }
    }

    func evaluate() {
        guard let table = cty.table, call.count >= 3 else { evaluation = ContestEvaluation(); return }
        evaluation = ContestEngine.evaluate(kind: session.kind, myCall: myCall, call: call, band: currentBand, mode: modeGroup,
                                            exchange: exchange, previous: infos, cty: table)
    }

    func clearEntry() {
        call = ""
        exchange = ""
        exchangeIsSuggestion = true
        rstRcvd = rstSent
        dupeConfirmed = false
        evaluation = ContestEvaluation()
        lookup.clear()
    }

    /// Zapis łączności (Enter). Dubel wymaga drugiego Enter.
    func log() {
        guard let logbook, let cat else { return }
        let callsign = call.trimmingCharacters(in: .whitespaces)
        guard callsign.count >= 3, callsign.range(of: "^[A-Z0-9/]+$", options: .regularExpression) != nil else {
            message = L("Nieprawidłowy znak"); return
        }
        guard !myCall.isEmpty else { message = L("Wpisz swój znak w profilu stacji"); return }
        guard cat.activeFreq > 0, let band = LogFrequency.band(for: cat.activeFreq) else {
            message = L("Brak częstotliwości z radia - połącz CAT"); return
        }
        let exch = exchange.uppercased().trimmingCharacters(in: .whitespaces)
        guard !exch.isEmpty else { message = L("Wpisz wymianę: {1}", receivedLabel); return }
        if receivesSerial, Int(exch) == nil { message = L("Numer musi składać się z cyfr"); return }
        if evaluation.dupe, !dupeConfirmed {
            dupeConfirmed = true
            message = L("DUBEL - naciśnij Enter jeszcze raz, żeby zapisać mimo to (0 punktów)")
            return
        }
        let match = cty.table?.lookup(callsign)
        var qso = QSO(call: callsign, start: Date(), end: nil, freqHz: cat.activeFreq, band: band, mode: modeGroup, submode: nil)
        qso.rstSent = rstSent
        qso.rstRcvd = rstRcvd.isEmpty ? rstSent : rstRcvd
        qso.stationCall = myCall
        qso.myGrid = logbook.myGrid.uppercased()
        qso.extra["CONTEST_ID"] = session.cabrilloName
        qso.extra[Self.sessionField] = session.id.uuidString
        if sendsSerial { qso.extra["STX"] = String(nextSerial) } else { qso.extra["STX_STRING"] = session.myExchange.uppercased() }
        if receivesSerial { qso.extra["SRX"] = String(Int(exch) ?? 0) } else { qso.extra["SRX_STRING"] = exch }
        if let match {
            qso.extra["COUNTRY"] = match.entity.name
            qso.extra["CQZ"] = String(match.cqZone)
            qso.extra["ITUZ"] = String(match.ituZone)
            qso.extra["CONT"] = match.continent
        }
        // dane z QRZ: imię zawsze; QTH i lokator - tylko gdy stacja nadaje ze swojego kraju (nie P4/WE9V)
        if let record = lookup.record, record.call == QRZClient.baseCall(callsign) {
            qso.name = record.firstName.isEmpty ? record.displayName : record.firstName
            if !OperatingLocation.isAwayFromHome(callsign) {
                qso.qth = record.city
                qso.grid = record.grid.isEmpty ? (record.coordinate.map { Geo.grid(for: $0) } ?? "") : record.grid.uppercased()
            }
        }
        let points = evaluation.dupe ? 0 : evaluation.points
        let mults = evaluation.newMultipliers
        qsos.append(qso)                                       // log zawodów - nie główny dziennik
        saveLog()
        refresh()
        message = L("Zapisano {1}: {2} pkt", callsign, points) + (mults.isEmpty ? "" : " · " + L("nowe: {1}", mults.joined(separator: ", ")))
        clearEntry()
    }

    // MARK: - Wynik

    func refresh() {
        sessionQSOs = qsos
        workedKeys = Set(qsos.map { ContestEngine.dupeKey(kind: session.kind, call: $0.call, band: $0.band, mode: Self.group($0.mode)) })
        infos = sessionQSOs.map { q in
            ContestQSOInfo(call: q.call, band: q.band, mode: Self.group(q.mode),
                           exchange: q.extra["SRX_STRING"] ?? q.extra["SRX"] ?? "")
        }
        recent = Array(sessionQSOs.reversed())
        if let table = cty.table {
            let newScore = ContestEngine.score(kind: session.kind, myCall: myCall, qsos: infos, cty: table)
            if newScore != score { score = newScore }
        }
        let now = Date()
        rate10 = sessionQSOs.filter { now.timeIntervalSince($0.start) <= 600 }.count * 6
        rate60 = sessionQSOs.filter { now.timeIntervalSince($0.start) <= 3600 }.count
        evaluate()
    }

    private static func group(_ mode: String) -> String {
        switch mode.uppercased() {
        case "CW": return "CW"
        case "RTTY": return "RTTY"
        default: return "SSB"
        }
    }

    /// Nowe zawody: nowa sesja z własnym logiem (numeracja od 001, osobny wynik). Log poprzednich zawodów zostaje w pliku.
    func newSession(kind: ContestKind, mode: ContestMode) {
        var fresh = ContestSession()
        fresh.kind = kind
        fresh.mode = mode
        // nagłówek Cabrillo przenosimy z poprzednich zawodów (te same dane stacji)
        fresh.categoryPower = session.categoryPower
        fresh.categoryOperator = session.categoryOperator
        fresh.categoryAssisted = session.categoryAssisted
        fresh.club = session.club
        fresh.email = session.email
        fresh.address = session.address
        fresh.myExchange = ContestEngine.defaultMyExchange(kind: kind, me: me)
        session = fresh
        clearEntry()
        message = L("Nowe zawody: {1} ({2})", kind.name, mode.rawValue)
    }

    // MARK: - Cabrillo

    func exportCabrillo() {
        guard let logbook else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.nameFieldStringValue = "\(myCall.replacingOccurrences(of: "/", with: "-"))-\(session.cabrilloName).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Cabrillo.export(session: session, qsos: sessionQSOs, myCall: myCall, myGrid: logbook.myGrid,
                                   name: logbook.myName, claimedScore: score.total)
        do {
            try ADIF.asciiFile(text).write(to: url, atomically: true, encoding: .ascii)
            message = L("Zapisano log Cabrillo: {1} ({2} QSO)", url.lastPathComponent, sessionQSOs.count)
        } catch {
            message = L("Zapis Cabrillo nie powiódł się: {1}", error.localizedDescription)
        }
    }
}

@MainActor
final class ContestHolder: ObservableObject {
    let manager = ContestManager()
}


extension ContestManager {
    /// Gdy skop nie dostał zawodów (nieużywane przez okno główne, które zawsze je przekazuje).
    static let placeholder = ContestManager()
}

/// Wyświetlanie na skopie stacji zrobionych w zawodach (zakładka ZAWODY).
enum ContestScopeWorked: String, CaseIterable, Identifiable {
    case red, hide, normal
    var id: String { rawValue }
    var name: String {
        switch self {
        case .red: return L("czerwone")
        case .hide: return L("ukryj")
        case .normal: return L("normalnie")
        }
    }
}
