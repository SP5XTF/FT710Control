import Foundation
import Combine
import AppKit

/// Spot aktywatora POTA (api.pota.app/spot/activator - API nieoficjalne, publiczne, bez logowania).
struct POTASpot: Identifiable, Equatable {
    let id: String                 // aktywator|park - jedna aktywacja (kolejne spoty ją aktualizują)
    let spotID: Int
    let activator: String
    let frequencyKHz: Double
    let mode: String
    let reference: String
    let parkName: String
    let location: String
    let grid: String
    let spotTime: Date
    let spotter: String
    let comments: String
    let count: Int
    /// Koniec aktywacji (zniknęła z listy albo QRT) - pokazywana jeszcze przez godzinę.
    var endedAt: Date?

    var frequencyHz: Int { Int((frequencyKHz * 1000).rounded()) }
    var band: String { LogFrequency.band(for: frequencyHz) ?? "" }
    /// Pozycja pasma (sortowanie od 160 m w górę zamiast alfabetycznie).
    var bandOrder: Int { frequencyHz }
    var isQRT: Bool { comments.uppercased().contains("QRT") }

    /// Grupa trybu do filtra: CW, SSB (fonia) albo cyfrowe.
    var modeGroup: String {
        switch mode.uppercased() {
        case "CW": return "CW"
        case "SSB", "USB", "LSB", "AM", "FM": return "SSB"
        case "": return ""
        default: return "DATA"
        }
    }

    /// Parsowanie jednego spotu (pola bywają liczbą albo tekstem, nazwa parku w „name” albo „parkName”).
    init?(json: [String: Any]) {
        func text(_ key: String) -> String {
            if let s = json[key] as? String { return s.trimmingCharacters(in: .whitespaces) }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return ""
        }
        let activator = text("activator").uppercased()
        let reference = text("reference").uppercased()
        guard !activator.isEmpty, let khz = Double(text("frequency")), khz > 0 else { return nil }
        self.activator = activator
        self.reference = reference
        self.id = activator + "|" + reference
        self.spotID = Int(text("spotId")) ?? 0
        self.frequencyKHz = khz
        self.mode = text("mode").uppercased()
        let parkName = text("name")
        self.parkName = parkName.isEmpty ? text("parkName") : parkName
        self.location = text("locationDesc")
        let grid6 = text("grid6")
        self.grid = grid6.isEmpty ? text("grid4") : grid6
        self.spotTime = POTASpot.parseTime(text("spotTime")) ?? Date()
        self.spotter = text("spotter").uppercased()
        self.comments = text("comments")
        self.count = Int(text("count")) ?? 0
        self.endedAt = nil
    }

    /// „2026-03-04T20:08:51” - UTC bez strefy (czasem z ułamkiem sekundy albo „Z”).
    static func parseTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let core = String(s.replacingOccurrences(of: "Z", with: "").prefix(19))
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: core)
    }
}

/// Statystyki użytkownika POTA (api.pota.app/stats/user/{znak} - publiczne).
struct POTAUserStats {
    var callsign = ""
    var name = ""
    var activations = 0, activatedParks = 0, activatorQSOs = 0
    var attemptActivations = 0, attemptParks = 0
    var huntedParks = 0, hunterQSOs = 0
    var awards = 0, endorsements = 0

    init?(json: [String: Any]) {
        func int(_ object: Any?, _ key: String) -> Int {
            guard let dict = object as? [String: Any] else { return 0 }
            return (dict[key] as? NSNumber)?.intValue ?? Int(dict[key] as? String ?? "") ?? 0
        }
        guard let call = json["callsign"] as? String, !call.isEmpty else { return nil }
        callsign = call.uppercased()
        name = json["name"] as? String ?? ""
        activations = int(json["activator"], "activations")
        activatedParks = int(json["activator"], "parks")
        activatorQSOs = int(json["activator"], "qsos")
        attemptActivations = int(json["attempts"], "activations")
        attemptParks = int(json["attempts"], "parks")
        huntedParks = int(json["hunter"], "parks")
        hunterQSOs = int(json["hunter"], "qsos")
        awards = (json["awards"] as? NSNumber)?.intValue ?? 0
        endorsements = (json["endorsements"] as? NSNumber)?.intValue ?? 0
    }
}

/// Zakładka POTA: spoty aktywatorów (odświeżane co 60 s - API utrzymują wolontariusze), aktywacje zakończone
/// w ostatniej godzinie (pamiętane przez program), statystyki dowolnego znaku (domyślnie z profilu stacji),
/// parki już upolowane według dziennika, kliknięcie = strojenie radia i znak do dziennika.
@MainActor
final class POTAManager: ObservableObject {
    @Published private(set) var spots: [POTASpot] = []
    @Published private(set) var ended: [POTASpot] = []
    @Published private(set) var spotsStatus = ""
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var stats: POTAUserStats?
    @Published private(set) var statsStatus = ""
    /// Znak do statystyk - edytowalny; pusty = znak z profilu stacji.
    @Published var statsCall: String { didSet { UserDefaults.standard.set(statsCall, forKey: "pota.statsCall") } }
    @Published var showEnded: Bool { didSet { UserDefaults.standard.set(showEnded, forKey: "pota.showEnded") } }
    @Published var onlyNewParks: Bool { didSet { UserDefaults.standard.set(onlyNewParks, forKey: "pota.onlyNew") } }
    @Published var bandFilter: String { didSet { UserDefaults.standard.set(bandFilter, forKey: "pota.band") } }
    @Published var modeFilter: String { didSet { UserDefaults.standard.set(modeFilter, forKey: "pota.mode") } }
    /// Program (kraj programu POTA, np. US, SP, DL) - z numeru parku; pusty = wszystkie.
    @Published var programFilter: String { didSet { UserDefaults.standard.set(programFilter, forKey: "pota.program") } }
    /// Wiek spotu w minutach (0 = wszystkie) - jak „Wiek” na pota.app.
    @Published var maxAgeMinutes: Int { didSet { UserDefaults.standard.set(maxAgeMinutes, forKey: "pota.maxAge") } }
    /// „Spot Highlight”: nowy park liczony w tej emisji (mieszane / fonia / CW / cyfrowe).
    @Published var highlightCategory: String { didSet { UserDefaults.standard.set(highlightCategory, forKey: "pota.highlight") } }
    /// Ręcznie ukryte aktywacje (id → kiedy ukryte; po 24 h wracają) i czy je pokazywać.
    @Published private(set) var hidden: [String: Date] = [:]
    @Published var showHidden = false
    /// Pauza automatycznego odświeżania (⏸) i czas następnego odświeżenia (odliczanie).
    @Published var paused = false { didSet { if !paused { nextRefresh = Date().addingTimeInterval(1); } } }
    @Published private(set) var nextRefresh = Date()

    /// Parki z dziennika (pola POTA_REF / SIG_INFO przy SIG=POTA) oraz łączności z dzisiaj (znak|park|pasmo).
    @Published private(set) var huntedParks: Set<String> = []
    private var workedToday: Set<String> = []
    private var huntedByCategory: [DXCCCategory: Set<String>] = [:]

    private weak var cat: CATClient?
    private weak var logbook: LogbookStore?
    private var timer: Timer?
    private var firstFetchDone = false
    private var observers: [AnyCancellable] = []
    private static let base = "https://api.pota.app"
    private static let interval: TimeInterval = 60

    init() {
        let d = UserDefaults.standard
        statsCall = d.string(forKey: "pota.statsCall") ?? ""
        showEnded = d.object(forKey: "pota.showEnded") as? Bool ?? true
        onlyNewParks = d.object(forKey: "pota.onlyNew") as? Bool ?? false
        bandFilter = d.string(forKey: "pota.band") ?? ""
        modeFilter = d.string(forKey: "pota.mode") ?? ""
        programFilter = d.string(forKey: "pota.program") ?? ""
        maxAgeMinutes = d.object(forKey: "pota.maxAge") as? Int ?? 30
        highlightCategory = d.string(forKey: "pota.highlight") ?? DXCCCategory.mixed.rawValue
        let saved = d.dictionary(forKey: "pota.hidden") as? [String: Date] ?? [:]
        hidden = saved.filter { Date().timeIntervalSince($0.value) < 24 * 3600 }
    }

    func attach(cat: CATClient, logbook: LogbookStore) {
        guard self.cat == nil else { return }
        self.cat = cat
        self.logbook = logbook
        observers.append(logbook.$qsos.sink { [weak self] _ in Task { @MainActor in self?.rebuildLogIndex() } })
        rebuildLogIndex()
    }

    /// Znak, dla którego pokazujemy statystyki (wpisany albo z profilu).
    var effectiveStatsCall: String {
        let typed = statsCall.trimmingCharacters(in: .whitespaces).uppercased()
        return typed.isEmpty ? (logbook?.myCall.uppercased() ?? "") : typed
    }

    // MARK: - Odświeżanie

    /// Start po pierwszym pokazaniu zakładki; działa dalej w tle, żeby wychwycić koniec aktywacji.
    func start() {
        guard timer == nil else { return }
        refreshSpots()
        if stats == nil { refreshStats() }
        nextRefresh = Date().addingTimeInterval(Self.interval)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Co sekundę: gdy nie ma pauzy i minął czas - odświeżenie (co 60 s).
    private func tick() {
        guard !paused, Date() >= nextRefresh else { return }
        nextRefresh = Date().addingTimeInterval(Self.interval)
        refreshSpots()
    }

    func refreshSpots() {
        nextRefresh = Date().addingTimeInterval(Self.interval)
        Task {
            switch await Self.getJSON(Self.base + "/spot/activator") {
            case .failure(let error):
                spotsStatus = L("POTA: {1}", error.message)
            case .success(let object):
                guard let list = object as? [[String: Any]] else {
                    spotsStatus = L("POTA: nieoczekiwana odpowiedź serwera")
                    return
                }
                apply(list.compactMap(POTASpot.init(json:)))
                lastUpdate = Date()
                spotsStatus = ""
            }
        }
    }

    /// Nowa lista: jedna pozycja na aktywację (najnowszy spot); aktywacje, które zniknęły albo zgłosiły QRT,
    /// przechodzą do „zakończonych” na godzinę; powrót aktywatora zdejmuje go z zakończonych.
    private func apply(_ fresh: [POTASpot]) {
        let now = Date()
        let previousIDs = Set(spots.map(\.id))
        var latest: [String: POTASpot] = [:]
        for spot in fresh where latest[spot.id].map({ $0.spotTime < spot.spotTime }) ?? true { latest[spot.id] = spot }
        var active: [POTASpot] = []
        var newlyEnded: [POTASpot] = []
        for spot in latest.values {
            if spot.isQRT { var s = spot; s.endedAt = now; newlyEnded.append(s) } else { active.append(spot) }
        }
        let activeIDs = Set(active.map(\.id))
        for old in spots where latest[old.id] == nil {                // zniknęła z listy
            var s = old
            s.endedAt = now
            newlyEnded.append(s)
        }
        var endedMap = Dictionary(ended.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in newlyEnded where endedMap[s.id] == nil { endedMap[s.id] = s }
        for id in activeIDs { endedMap[id] = nil }                       // aktywator wrócił
        ended = endedMap.values.filter { now.timeIntervalSince($0.endedAt ?? now) < 3600 }
            .sorted { ($0.endedAt ?? now) > ($1.endedAt ?? now) }
        spots = active.sorted { $0.spotTime > $1.spotTime }
        // alerty: aktywacje, których nie było w poprzedniej liście (pierwsza lista po starcie - bez alertów)
        if firstFetchDone {
            let newcomers = active.filter { !previousIDs.contains($0.id) }
            if !newcomers.isEmpty { AlertCenter.shared.pota(newcomers, isNewPark: { self.isNewPark($0) }) }
        }
        firstFetchDone = true
    }

    func refreshStats() {
        let call = effectiveStatsCall
        guard !call.isEmpty else {
            stats = nil
            statsStatus = L("Wpisz znak albo uzupełnij znak w profilu stacji.")
            return
        }
        statsStatus = L("Pobieranie…")
        let path = call.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? call
        Task {
            switch await Self.getJSON(Self.base + "/stats/user/" + path) {
            case .failure(let error):
                stats = nil
                statsStatus = L("POTA: {1}", error.message)
            case .success(let object):
                if let dict = object as? [String: Any], let parsed = POTAUserStats(json: dict) {
                    stats = parsed
                    statsStatus = ""
                } else {
                    stats = nil
                    statsStatus = L("POTA nie ma danych dla znaku {1}.", call)
                }
            }
        }
    }

    // MARK: - Dziennik

    /// Parki z dziennika i dzisiejsze łączności z aktywatorami (do kolorów „nowy park” / „dziś już zrobiony”).
    private func rebuildLogIndex() {
        guard let logbook else { return }
        var parks = Set<String>()
        var today = Set<String>()
        var byCategory: [DXCCCategory: Set<String>] = [:]
        let day = Self.utcDay(Date())
        for qso in logbook.qsos {
            let refs = Self.parkRefs(of: qso)
            guard !refs.isEmpty else { continue }
            parks.formUnion(refs)
            for category in DXCCCategory.allCases where category.includes(qso) {
                byCategory[category, default: []].formUnion(refs)
            }
            if Self.utcDay(qso.start) == day {
                for ref in refs { today.insert(QRZClient.baseCall(qso.call) + "|" + ref + "|" + qso.band.lowercased()) }
            }
        }
        huntedParks = parks
        huntedByCategory = byCategory
        workedToday = today
    }

    // MARK: - Ukrywanie aktywacji

    func isHidden(_ spot: POTASpot) -> Bool { hidden[spot.id] != nil }

    func setHidden(_ spot: POTASpot, _ hide: Bool) {
        if hide { hidden[spot.id] = Date() } else { hidden[spot.id] = nil }
        UserDefaults.standard.set(hidden, forKey: "pota.hidden")
    }

    /// Program POTA z numeru parku („US-0062” → „US”).
    static func program(of spot: POTASpot) -> String {
        String(spot.reference.split(separator: "-").first ?? "")
    }

    /// Numery parków łączności: POTA_REF albo SIG_INFO przy SIG=POTA (dwa parki naraz rozdzielone przecinkiem).
    static func parkRefs(of qso: QSO) -> [String] {
        var raw = qso.extra["POTA_REF"] ?? ""
        if raw.isEmpty, (qso.extra["SIG"] ?? "").uppercased() == "POTA" { raw = qso.extra["SIG_INFO"] ?? "" }
        return raw.uppercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { $0.split(separator: "@").first.map(String.init) ?? $0 }   // „US-0001@US-ME” → „US-0001”
            .filter { !$0.isEmpty }
    }

    /// Nowy park - w emisji wybranej w „Wyróżnianie” (mieszane: w dowolnej).
    func isNewPark(_ spot: POTASpot) -> Bool {
        guard !spot.reference.isEmpty else { return false }
        let category = DXCCCategory(rawValue: highlightCategory) ?? .mixed
        return !(huntedByCategory[category] ?? []).contains(spot.reference)
    }

    func isWorkedToday(_ spot: POTASpot) -> Bool {
        workedToday.contains(QRZClient.baseCall(spot.activator) + "|" + spot.reference + "|" + spot.band.lowercased())
    }

    // MARK: - Kliknięcie: strojenie i dziennik

    /// Radio na częstotliwość aktywatora z trybem (CW-U, LSB poniżej 10 MHz / USB, AM, FM, DATA-U dla cyfrowych)
    /// i znak z numerem parku do formularza dziennika.
    func select(_ spot: POTASpot) {
        if let cat, cat.isConnected {
            cat.setActiveFrequency(spot.frequencyHz)
            if let code = Self.radioMode(for: spot), cat.modeCode != code { cat.setMode(code) }
        }
        logbook?.prefill(spot.activator)
        NotificationCenter.default.post(name: .potaSelected, object: nil, userInfo: [
            "call": spot.activator, "reference": spot.reference, "park": spot.parkName
        ])
    }

    static func radioMode(for spot: POTASpot) -> String? {
        switch spot.mode.uppercased() {
        case "CW": return "3"
        case "SSB", "USB", "LSB": return spot.frequencyHz < 10_000_000 ? "1" : "2"
        case "AM": return "5"
        case "FM": return "4"
        case "FT8", "FT4", "DATA", "PSK31", "PSK", "JS8", "RTTY", "DIGITAL": return "C"
        default: return nil
        }
    }

    // MARK: - HTTP

    struct POTAError: Error {
        let message: String
    }

    private static func getJSON(_ url: String) async -> Result<Any, POTAError> {
        guard let target = URL(string: url) else { return .failure(POTAError(message: L("Nieprawidłowy adres"))) }
        var request = URLRequest(url: target)
        request.timeoutInterval = 20
        request.setValue(LogUploader.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return .failure(POTAError(message: L("Kod HTTP {1}", code))) }
            if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                return .success(NSNull())
            }
            return .success(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            return .failure(POTAError(message: error.localizedDescription))
        }
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

extension Notification.Name {
    /// Wybrano spot POTA (userInfo: call, reference, park) - formularz dziennika dostaje numer parku.
    static let potaSelected = Notification.Name("ft710.potaSelected")
    /// Prośba o pokazanie zakładki DZIENNIK (dwuklik spotu POTA).
    static let showLogTab = Notification.Name("ft710.showLogTab")
}

extension POTAManager {
    /// Pusty menedżer (bez odświeżania) - gdy skop nie dostał POTA.
    static let idle = POTAManager()
}

@MainActor
final class POTAHolder: ObservableObject {
    let manager = POTAManager()
}
