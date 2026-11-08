import Foundation
import SwiftUI
import AppKit

/// Jedna łączność. Czas zawsze w UTC (Date jest niezależna od strefy; formatowanie w UTC).
struct QSO: Identifiable, Codable, Hashable {
    var id = UUID()
    var call: String
    var start: Date
    var end: Date?
    var freqHz: Int
    var band: String
    var mode: String            // pole MODE w ADIF, np. SSB, CW, FT8, MFSK
    var submode: String?        // pole SUBMODE, np. FT4, JS8, PSK31
    var rstSent = ""
    var rstRcvd = ""
    var name = ""
    var qth = ""
    var grid = ""
    var comment = ""
    var stationCall = ""
    var myGrid = ""
    /// Pola ADIF, których dziennik nie obsługuje osobno - zachowywane przy imporcie i oddawane przy eksporcie.
    var extra: [String: String] = [:]

    var modeLabel: String { submode ?? mode }

    /// Kraj (pole ADIF COUNTRY - z QRZ albo z importu).
    var country: String { extra["COUNTRY"] ?? "" }

    /// Odległość w km: zapisana (ADIF DISTANCE) albo liczona z lokatorów.
    func distanceKm(fallbackMyGrid: String) -> Int? {
        if let saved = extra["DISTANCE"].flatMap({ Double($0) }) { return Int(saved.rounded()) }
        let home = myGrid.isEmpty ? fallbackMyGrid : myGrid
        guard let a = Geo.coordinate(fromGrid: home), let b = Geo.coordinate(fromGrid: grid) else { return nil }
        return Int(Geo.distanceKm(a, b).rounded())
    }

    /// Azymut z mojego lokatora do lokatora korespondenta.
    func bearing(fallbackMyGrid: String) -> Int? {
        let home = myGrid.isEmpty ? fallbackMyGrid : myGrid
        guard let a = Geo.coordinate(fromGrid: home), let b = Geo.coordinate(fromGrid: grid) else { return nil }
        return Int(Geo.bearing(a, b).rounded()) % 360
    }
}

enum Bands {
    /// Pasma ADIF w zakresie FT-710.
    static let table: [(name: String, range: ClosedRange<Int>)] = [
        ("160m", 1_800_000...2_000_000),
        ("80m", 3_500_000...4_000_000),
        ("60m", 5_060_000...5_450_000),
        ("40m", 7_000_000...7_300_000),
        ("30m", 10_100_000...10_150_000),
        ("20m", 14_000_000...14_350_000),
        ("17m", 18_068_000...18_168_000),
        ("15m", 21_000_000...21_450_000),
        ("12m", 24_890_000...24_990_000),
        ("10m", 28_000_000...29_700_000),
        ("6m", 50_000_000...54_000_000),
        ("4m", 70_000_000...71_000_000)
    ]

    static func name(for hz: Int) -> String? {
        table.first(where: { $0.range.contains(hz) })?.name
    }
}

/// Tryby do wyboru przy logowaniu, z poprawnym zapisem ADIF (np. FT4 to MODE=MFSK, SUBMODE=FT4).
struct LogModePreset: Hashable, Identifiable {
    let label: String
    let mode: String
    let submode: String?
    let defaultRST: String
    var id: String { label }

    static let all: [LogModePreset] = [
        LogModePreset(label: "SSB", mode: "SSB", submode: nil, defaultRST: "59"),
        LogModePreset(label: "CW", mode: "CW", submode: nil, defaultRST: "599"),
        LogModePreset(label: "FT8", mode: "FT8", submode: nil, defaultRST: ""),
        LogModePreset(label: "FT4", mode: "MFSK", submode: "FT4", defaultRST: ""),
        LogModePreset(label: "RTTY", mode: "RTTY", submode: nil, defaultRST: "599"),
        LogModePreset(label: "PSK31", mode: "PSK", submode: "PSK31", defaultRST: "599"),
        LogModePreset(label: "PSK63", mode: "PSK", submode: "PSK63", defaultRST: "599"),
        LogModePreset(label: "JS8", mode: "MFSK", submode: "JS8", defaultRST: ""),
        LogModePreset(label: "AM", mode: "AM", submode: nil, defaultRST: "59"),
        LogModePreset(label: "FM", mode: "FM", submode: nil, defaultRST: "59"),
        // SSTV: raport RSV (czytelność, siła, jakość obrazu)
        LogModePreset(label: "SSTV", mode: "SSTV", submode: nil, defaultRST: "595")
    ]

    /// Domyślny tryb dziennika na podstawie trybu radia (kod MD). DATA-x -> FT8 (najczęstszy przypadek).
    static func forRadio(_ code: String) -> LogModePreset {
        let label: String
        switch code {
        case "3", "7": label = "CW"
        case "5", "D": label = "AM"
        case "4", "B": label = "FM"
        case "6", "9": label = "RTTY"
        case "8", "C", "A": label = "FT8"
        default: label = "SSB"
        }
        return all.first(where: { $0.label == label }) ?? all[0]
    }
}

@MainActor
final class LogbookStore: ObservableObject {
    @Published private(set) var qsos: [QSO] = [] {         // najnowsze pierwsze
        didSet { indexDirty = true }
    }

    // MARK: Indeks według znaku (budowany raz po zmianie dziennika - nie przy każdym przerysowaniu)
    private var indexDirty = true
    private var byBaseCall: [String: [QSO]] = [:]
    private var bandsByBaseCall: [String: Set<String>] = [:]

    private func ensureIndex() {
        guard indexDirty else { return }
        var calls: [String: [QSO]] = [:]
        var bands: [String: Set<String>] = [:]
        for qso in qsos {                                      // qsos są posortowane - listy też (najnowsze pierwsze)
            let base = QRZClient.baseCall(qso.call)
            calls[base, default: []].append(qso)
            bands[base, default: []].insert(qso.band)
        }
        byBaseCall = calls
        bandsByBaseCall = bands
        indexDirty = false
    }

    /// Pasma, na których była łączność z danym znakiem podstawowym (np. dla kolumny „Dziennik” w DX Cluster).
    func workedBands(baseCall: String) -> Set<String>? {
        ensureIndex()
        return bandsByBaseCall[baseCall]
    }

    // MARK: Zapis w tle
    private let saveQueue = DispatchQueue(label: "ft710.logbook.save", qos: .utility)
    private var saveScheduled = false
    /// Dziennik, którego oczekujące zmiany zapisuje AppDelegate przy zamykaniu programu.
    static weak var active: LogbookStore?
    @Published var myCall: String { didSet { defaults.set(myCall, forKey: "myCall") } }
    @Published var myGrid: String { didSet { defaults.set(myGrid, forKey: "myGrid") } }
    // Profil stacji (okno „Profil stacji”) - trafia do pól ADIF MY_* każdej łączności.
    @Published var myName: String { didSet { defaults.set(myName, forKey: "myName") } }
    @Published var myQTH: String { didSet { defaults.set(myQTH, forKey: "myQTH") } }
    @Published var myCountry: String { didSet { defaults.set(myCountry, forKey: "myCountry") } }
    @Published var myDXCC: String { didSet { defaults.set(myDXCC, forKey: "myDXCC") } }
    @Published var myCQZone: String { didSet { defaults.set(myCQZone, forKey: "myCQZone") } }
    @Published var myITUZone: String { didSet { defaults.set(myITUZone, forKey: "myITUZone") } }

    /// Pola ADIF z profilu stacji (tylko niepuste).
    var profileADIFFields: [String: String] {
        let fields = ["MY_NAME": myName, "MY_CITY": myQTH, "MY_COUNTRY": myCountry,
                      "MY_DXCC": myDXCC, "MY_CQ_ZONE": myCQZone, "MY_ITU_ZONE": myITUZone]
        return fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    @Published var wsjtxEnabled: Bool {
        didSet {
            guard wsjtxEnabled != oldValue else { return }
            defaults.set(wsjtxEnabled, forKey: "wsjtxEnabled")
            updateListener()
        }
    }
    @Published var wsjtxPort: Int {
        didSet {
            guard wsjtxPort != oldValue else { return }
            defaults.set(wsjtxPort, forKey: "wsjtxPort")
            if wsjtxEnabled { updateListener() }
        }
    }
    @Published private(set) var wsjtxStatus = L("Wyłączony")
    @Published var lastError: String?
    /// Informacja dla użytkownika (np. o naprawionych łącznościach) - pokazywana w oknie dziennika.
    @Published var notice: String?
    /// Znak do wpisania w formularz dziennika (kliknięcie stacji na skopie albo w DX Cluster).
    /// Formularz pobiera go, gdy jest widoczny (od razu albo po przejściu do zakładki DZIENNIK).
    @Published var prefillCall: (call: String, id: UUID)?

    func prefill(_ call: String) {
        let cleaned = call.uppercased().filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return }
        prefillCall = (cleaned, UUID())
    }

    let fileURL: URL
    private let defaults = UserDefaults.standard

    // MARK: Kopia w iCloud Drive
    /// Dodatkowa kopia dziennika w iCloud Drive (folder „FT-710 Control/Kopie dziennika”): JSON z dnia
    /// (30 ostatnich dni, do przywrócenia w programie) i ADIF z całym dziennikiem (dla dowolnego programu).
    @Published var iCloudBackupEnabled: Bool {
        didSet {
            defaults.set(iCloudBackupEnabled, forKey: "iCloudBackup")
            if iCloudBackupEnabled { iCloudDirty = true; scheduleICloudBackup(soon: true) }
            else { iCloudTimer?.invalidate(); iCloudTimer = nil; iCloudStatus = L("Kopia w iCloud wyłączona.") }
        }
    }
    @Published private(set) var iCloudStatus = ""
    private var iCloudDirty = false
    private var iCloudTimer: Timer?
    private var lastICloudBackup = Date.distantPast
    nonisolated private static let iCloudKeepDays = 30
    private let listener = WSJTXListener()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FT710Control", isDirectory: true)
        // Program nazywał się wcześniej FT710Console - przy pierwszym uruchomieniu skopiuj jego dane.
        // Stary katalog zostaje nietknięty jako kopia zapasowa.
        let legacy = support.appendingPathComponent("FT710Console", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("logbook.json")

        myCall = UserDefaults.standard.string(forKey: "myCall") ?? ""
        myGrid = UserDefaults.standard.string(forKey: "myGrid") ?? ""
        myName = UserDefaults.standard.string(forKey: "myName") ?? ""
        myQTH = UserDefaults.standard.string(forKey: "myQTH") ?? ""
        myCountry = UserDefaults.standard.string(forKey: "myCountry") ?? ""
        myDXCC = UserDefaults.standard.string(forKey: "myDXCC") ?? ""
        myCQZone = UserDefaults.standard.string(forKey: "myCQZone") ?? ""
        myITUZone = UserDefaults.standard.string(forKey: "myITUZone") ?? ""
        wsjtxEnabled = UserDefaults.standard.bool(forKey: "wsjtxEnabled")
        let port = UserDefaults.standard.integer(forKey: "wsjtxPort")
        wsjtxPort = (1...65535).contains(port) ? port : 2237
        iCloudBackupEnabled = UserDefaults.standard.object(forKey: "iCloudBackup") as? Bool ?? true

        load()
        if iCloudBackupEnabled {                       // kopia dnia także wtedy, gdy w tej sesji nic się nie zmieni
            iCloudDirty = true
            scheduleICloudBackup(soon: true)
        }
        listener.onADIF = { [weak self] text in
            Task { @MainActor in self?.receivedFromWSJTX(text) }
        }
        if wsjtxEnabled { updateListener() }
    }

    // MARK: - Plik

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            qsos = try decoder.decode([QSO].self, from: data).sorted { $0.start > $1.start }
            let repaired = repairScaledFrequencies()
            if repaired > 0 {
                notice = L("Naprawiono częstotliwość w {1} łącznościach (zapisana 1000× za mała - dawny błąd okna edycji).", repaired)
            }
            // Kopia z chwili uruchomienia - na wypadek, gdyby coś poszło nie tak w tej sesji.
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("logbook-kopia.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        } catch {
            // Nie nadpisuj nieczytelnego pliku - odłóż go na bok.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("logbook-nieczytelny-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            lastError = L("Nie udało się wczytać dziennika ({1}). Plik odłożono jako {2}.", error.localizedDescription, aside.lastPathComponent)
        }
    }

    /// Zapis w tle: seria zmian w krótkim czasie (wysyłka do usług, import, naprawy) daje jeden zapis,
    /// a kodowanie i zapis pliku nie zatrzymują interfejsu. Przy zamykaniu programu - zapis natychmiast.
    private func save() {
        Self.active = self                                     // zapis przy zamykaniu: AppDelegate
        if iCloudBackupEnabled { iCloudDirty = true; scheduleICloudBackup(soon: false) }
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)          // zmiany z tej chwili - jeden zapis
            guard let self, self.saveScheduled else { return }
            self.saveScheduled = false
            let snapshot = self.qsos, url = self.fileURL
            self.saveQueue.async { [weak self] in                       // słabo także w zewnętrznym domknięciu
                if let message = Self.write(snapshot, to: url) {
                    Task { @MainActor in self?.lastError = message }
                }
            }
        }
    }

    /// Natychmiastowy zapis (zamykanie programu) - po zakończeniu zapisów oczekujących w tle.
    func flushSave() {
        saveScheduled = false
        let snapshot = qsos, url = fileURL
        saveQueue.sync {
            if let message = Self.write(snapshot, to: url) { lastError = message }
        }
        // przy zamykaniu programu - zaległa kopia w iCloud od razu
        if iCloudBackupEnabled, iCloudDirty, let folder = Self.iCloudBackupFolder {
            iCloudDirty = false
            _ = saveQueue.sync { Self.writeICloudBackup(snapshot, to: folder) }
        }
    }

    // MARK: - Kopia w iCloud Drive

    /// iCloud Drive użytkownika (gdy jest włączony w Ustawieniach systemowych).
    static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    static var iCloudBackupFolder: URL? {
        iCloudDriveURL?.appendingPathComponent("FT-710 Control", isDirectory: true)
            .appendingPathComponent("Kopie dziennika", isDirectory: true)
    }

    /// Kopia nie częściej niż co 10 minut (plik kilku MB nie obciąża synchronizacji przy każdym QSO);
    /// `soon` - pierwsza kopia sesji albo włączenie opcji: po minucie.
    private func scheduleICloudBackup(soon: Bool) {
        guard iCloudTimer == nil else { return }
        let sinceLast = Date().timeIntervalSince(lastICloudBackup)
        let delay = soon || sinceLast > 600 ? 60 : 600 - sinceLast
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.iCloudTimer = nil
                self?.backupToICloud()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        iCloudTimer = timer
    }

    /// Kopia w iCloud teraz (w tle).
    func backupToICloud() {
        guard let folder = Self.iCloudBackupFolder else {
            iCloudStatus = L("iCloud Drive jest wyłączony - włącz go w Ustawieniach systemowych (Apple ID → iCloud → iCloud Drive).")
            return
        }
        iCloudTimer?.invalidate()
        iCloudTimer = nil
        iCloudDirty = false
        lastICloudBackup = Date()
        let snapshot = qsos
        saveQueue.async { [weak self] in
            let result = Self.writeICloudBackup(snapshot, to: folder)
            Task { @MainActor in self?.iCloudStatus = result }
        }
    }

    /// Zapis kopii dnia (JSON) i całego dziennika w ADIF; usuwa kopie dzienne starsze niż 30 ostatnich.
    /// Pustego dziennika nie zapisuje - nieudane wczytanie nie może nadpisać dobrej kopii w chmurze.
    nonisolated private static func writeICloudBackup(_ qsos: [QSO], to folder: URL) -> String {
        guard !qsos.isEmpty else { return L("Dziennik jest pusty - kopii w iCloud nie nadpisano.") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(identifier: "UTC")
            day.dateFormat = "yyyy-MM-dd"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(qsos).write(to: folder.appendingPathComponent("dziennik-\(day.string(from: Date())).json"),
                                           options: .atomic)
            try ADIF.export(qsos).write(to: folder.appendingPathComponent("dziennik-najnowszy.adi"),
                                        atomically: true, encoding: .utf8)
            // tylko 30 ostatnich kopii dziennych (nazwy z datą sortują się chronologicznie)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let daily = files.filter { $0.lastPathComponent.hasPrefix("dziennik-20") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in daily.dropFirst(iCloudKeepDays) { try? FileManager.default.removeItem(at: old) }
            let time = DateFormatter()
            time.timeZone = TimeZone(identifier: "UTC")
            time.dateFormat = "HH:mm"
            return L("Kopia w iCloud: {1} QSO, {2} UTC.", qsos.count, time.string(from: Date()))
        } catch {
            return L("Nie udało się zapisać kopii w iCloud: {1}", error.localizedDescription)
        }
    }

    /// Folder kopii w Finderze.
    func revealICloudBackups() {
        guard let folder = Self.iCloudBackupFolder else {
            iCloudStatus = L("iCloud Drive jest wyłączony - włącz go w Ustawieniach systemowych (Apple ID → iCloud → iCloud Drive).")
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Zwięzły JSON (bez formatowania - szybszy zapis i mniejszy plik). Zwraca opis błędu albo nil.
    nonisolated private static func write(_ qsos: [QSO], to url: URL) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(qsos).write(to: url, options: .atomic)
            return nil
        } catch {
            return L("Nie udało się zapisać dziennika: {1}", error.localizedDescription)
        }
    }

    // MARK: - Operacje

    /// Wywoływane dla każdej NOWEJ łączności (zapis ręczny, WSJT-X) - np. automatyczna wysyłka
    /// do serwisów. Import pliku ADIF i przywracanie kopii tego nie wywołują.
    var onLogged: ((QSO) -> Void)?
    /// Wywoływane po ręcznej poprawce łączności (np. aktualizacja w World Radio League).
    var onEdited: ((QSO) -> Void)?

    /// Poprawka łączności przez użytkownika (okno edycji).
    func edit(_ qso: QSO) {
        update(qso)
        onEdited?(qso)
    }

    func add(_ qso: QSO) {
        qsos.append(qso)
        qsos.sort { $0.start > $1.start }
        save()
        onLogged?(qso)
        announceLogged(qso)
    }

    /// Powiadomienie „QSO zapisane” (ręcznie, FT8, zawody, WSJT-X) - np. formularz w zakładce DZIENNIK czyści
    /// wpisany znak, jeśli to ta sama stacja. Import pliku ADIF go nie wysyła.
    private func announceLogged(_ qso: QSO) {
        NotificationCenter.default.post(name: .qsoLogged, object: nil, userInfo: ["call": qso.call])
    }

    /// Zbiorcza zmiana wielu łączności z jednym zapisem pliku.
    func update(_ list: [QSO]) {
        guard !list.isEmpty else { return }
        let changed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for index in qsos.indices {
            if let replacement = changed[qsos[index].id] { qsos[index] = replacement }
        }
        qsos.sort { $0.start > $1.start }
        save()
    }

    /// Zapisuje zmienioną łączność (ta sama `id`).
    func update(_ qso: QSO) {
        guard let index = qsos.firstIndex(where: { $0.id == qso.id }) else { return }
        qsos[index] = qso
        qsos.sort { $0.start > $1.start }
        save()
    }

    /// Usuwa cały dziennik. Wcześniej zapisuje kopię wszystkich łączności (JSON) w katalogu danych
    /// programu i zwraca jej adres - dziennik da się odtworzyć. Bez udanej kopii nic nie jest usuwane.
    @discardableResult
    func deleteAll() -> URL? {
        guard !qsos.isEmpty else { return nil }
        let backup: URL
        do {
            backup = try writeBackup(prefix: "logbook-przed-usunieciem")
        } catch {
            lastError = L("Nie udało się zrobić kopii - dziennik NIE został usunięty: {1}", error.localizedDescription)
            return nil
        }
        qsos.removeAll()
        save()
        return backup
    }

    // MARK: - Kopie zapasowe

    /// Kopie w katalogu danych (logbook-kopia.json, logbook-przed-…json), najnowsze pierwsze.
    /// Pliki, których nie da się odczytać, są pomijane.
    func backups() -> [LogbookBackup] {
        let dir = fileURL.deletingLastPathComponent()
        var files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if let cloud = Self.iCloudBackupFolder {
            let cloudFiles = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in cloudFiles where file.lastPathComponent.hasSuffix(".icloud") {
                // kopia tylko w chmurze („Optymalizuj miejsce”) - poproś o pobranie; pojawi się przy następnym otwarciu
                var name = file.lastPathComponent
                if name.hasPrefix(".") { name.removeFirst() }
                name = String(name.dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: cloud.appendingPathComponent(name))
            }
            files += cloudFiles
        }
        return files
            .filter { url in
                let name = url.lastPathComponent
                return (name.hasPrefix("logbook-") || name.hasPrefix("dziennik-20")) && name.hasSuffix(".json")
                    && !name.contains("nieczytelny")
            }
            .compactMap { url in
                guard let qsos = try? Self.decode(url) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return LogbookBackup(url: url, date: date, count: qsos.count)
            }
            .sorted { $0.date > $1.date }
    }

    static func decode(_ url: URL) throws -> [QSO] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QSO].self, from: Data(contentsOf: url))
    }

    /// Zapis bieżących łączności do pliku kopii (np. przed usunięciem lub zastąpieniem).
    private func writeBackup(prefix: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(qsos).write(to: url, options: .atomic)
        return url
    }

    /// Przywraca kopię. `replace`: zastępuje cały dziennik (najpierw kopia bieżącego stanu);
    /// inaczej dołącza łączności z kopii, pomijając te, które już są w dzienniku.
    /// Zwraca opis wyniku do pokazania użytkownikowi.
    func restore(from url: URL, replace: Bool) -> String {
        let restored: [QSO]
        do {
            restored = try Self.decode(url)
        } catch {
            return L("Nie udało się odczytać kopii: {1}", error.localizedDescription)
        }
        if replace {
            var safety = ""
            if !qsos.isEmpty {
                do {
                    safety = try writeBackup(prefix: "logbook-przed-przywroceniem").lastPathComponent
                } catch {
                    return L("Nie udało się zrobić kopii bieżącego dziennika - nic nie zmieniono: {1}", error.localizedDescription)
                }
            }
            qsos = restored.sorted { $0.start > $1.start }
            save()
            return safety.isEmpty
                ? L("Przywrócono {1} QSO z {2}", restored.count, url.lastPathComponent)
                : L("Przywrócono {1} QSO z {2}. Poprzedni stan: {3}", restored.count, url.lastPathComponent, safety)
        }
        var added = 0, skipped = 0
        let existingIDs = Set(qsos.map(\.id))
        for qso in restored {
            if existingIDs.contains(qso.id) || isDuplicate(qso) {
                skipped += 1
            } else {
                qsos.append(qso)
                added += 1
            }
        }
        if added > 0 {
            qsos.sort { $0.start > $1.start }
            save()
        }
        return L("Dołączono {1} QSO z {2}, pominięto {3} (już w dzienniku)", added, url.lastPathComponent, skipped)
    }

    func delete(ids: Set<QSO.ID>) {
        guard !ids.isEmpty else { return }
        qsos.removeAll { ids.contains($0.id) }
        save()
    }

    /// Wcześniejsze łączności ze stacją (najnowsze pierwsze). Porównanie po znaku podstawowym:
    /// SP5XX, SP5XX/P i DL/SP5XX to ta sama stacja.
    func previous(call: String) -> [QSO] {
        ensureIndex()
        return byBaseCall[QRZClient.baseCall(call)] ?? []
    }

    /// Ta sama łączność: znak, pasmo, tryb i początek w odstępie do 2 minut.
    // MARK: - Duplikaty i import

    /// Okno czasowe duplikatu: różne programy zapisują początek albo koniec łączności.
    static let duplicateWindow: TimeInterval = 600

    /// Rodzina trybu do porównań: SSB/USB/LSB → SSB, CW/CWR → CW, MFSK+FT4 → FT4, FT8 → FT8…
    static func modeFamily(_ qso: QSO) -> String {
        modeFamily(mode: qso.mode, submode: qso.submode)
    }

    static func modeFamily(mode rawMode: String, submode: String?) -> String {
        let mode = rawMode.uppercased()
        let sub = (submode ?? "").uppercased()
        if ["SSB", "USB", "LSB"].contains(mode) || ["USB", "LSB"].contains(sub) { return "SSB" }
        if mode == "CW" || mode == "CWR" { return "CW" }
        if mode == "RTTY" || sub == "RTTY" { return "RTTY" }
        return sub.isEmpty ? mode : sub
    }

    /// Ta sama łączność: ten sam znak, pasmo (brak pasma pasuje do każdego), rodzina trybu
    /// i początek w odstępie do 10 minut.
    func duplicate(of qso: QSO, in list: [QSO]) -> QSO? {
        let call = qso.call.uppercased()
        let family = Self.modeFamily(qso)
        return list.first {
            $0.call.uppercased() == call
                && ($0.band == qso.band || $0.band.isEmpty || qso.band.isEmpty)
                && Self.modeFamily($0) == family
                && abs($0.start.timeIntervalSince(qso.start)) < Self.duplicateWindow
        }
    }

    func isDuplicate(_ qso: QSO) -> Bool {
        duplicate(of: qso, in: qsos) != nil
    }

    /// Sprawdzenie pliku ADIF przed zapisem: nowe łączności, duplikaty (względem dziennika
    /// i wewnątrz samego pliku) oraz rekordy bez znaku/daty.
    func analyzeImport(_ text: String) -> ImportAnalysis {
        var result = ImportAnalysis()
        for record in ADIF.parse(text) {
            guard let qso = ADIF.qso(from: record) else {
                result.invalid += 1
                continue
            }
            if let existing = duplicate(of: qso, in: qsos) {
                result.duplicates.append(ImportDuplicate(imported: qso, existing: existing, inFile: false))
            } else if let earlier = duplicate(of: qso, in: result.newQSOs) {
                result.duplicates.append(ImportDuplicate(imported: qso, existing: earlier, inFile: true))
            } else {
                result.newQSOs.append(qso)
            }
        }
        return result
    }

    /// Zapisuje łączności zatwierdzone po analizie importu.
    func addImported(_ list: [QSO]) {
        guard !list.isEmpty else { return }
        qsos.append(contentsOf: list)
        qsos.sort { $0.start > $1.start }
        save()
    }

    /// Import bez podglądu (np. QSO przysłane przez WSJT-X): duplikaty są pomijane.
    /// Zwraca (dodane, duplikaty, rekordy bez znaku/daty).
    @discardableResult
    func importADIF(_ text: String) -> (added: Int, duplicates: Int, invalid: Int) {
        let analysis = analyzeImport(text)
        addImported(analysis.newQSOs)
        return (analysis.newQSOs.count, analysis.duplicates.count, analysis.invalid)
    }

    // MARK: - WSJT-X

    private func updateListener() {
        guard wsjtxEnabled else {
            listener.stop()
            wsjtxStatus = L("Wyłączony")
            return
        }
        do {
            try listener.start(port: UInt16(wsjtxPort))
            wsjtxStatus = L("Nasłuch UDP 127.0.0.1:{1}", wsjtxPort)
        } catch {
            wsjtxEnabled = false       // najpierw wyłącz (to ustawia status), potem pokaż błąd
            wsjtxStatus = L("Błąd: {1}", error.localizedDescription)
        }
    }

    private func receivedFromWSJTX(_ text: String) {
        // Łączność z WSJT-X to nowe QSO z bieżącej pracy - po zapisie idzie też do automatycznej wysyłki.
        let analysis = analyzeImport(text)
        // Pola profilu stacji (MY_NAME, MY_CITY…) - tylko te, których WSJT-X nie przysłał.
        let profile = profileADIFFields
        let newQSOs: [QSO] = analysis.newQSOs.map { qso in
            var updated = qso
            for (key, value) in profile where updated.extra[key] == nil { updated.extra[key] = value }
            if updated.myGrid.isEmpty { updated.myGrid = myGrid.uppercased() }
            if updated.stationCall.isEmpty { updated.stationCall = myCall.uppercased() }
            return updated
        }
        addImported(newQSOs)
        newQSOs.forEach { onLogged?($0); announceLogged($0) }
        // dane z QRZ/HamQTH (imię, QTH…) - WSJT-X ich nie przysyła; tylko puste pola, lokator z WSJT-X zostaje
        if !newQSOs.isEmpty, AppServices.shared.qrz.canLookup {
            let ids = Set(newQSOs.map(\.id))
            Task { @MainActor [weak self] in _ = await self?.fillFromQRZ(ids: ids, qrz: AppServices.shared.qrz) }
        }
        let result = (added: newQSOs.count, duplicates: analysis.duplicates.count)
        let calls = ADIF.parse(text).compactMap { $0["CALL"] }.joined(separator: ", ")
        if result.added > 0 {
            wsjtxStatus = L("Dodano z WSJT-X: {1}", calls)
        } else if result.duplicates > 0 {
            wsjtxStatus = L("Pominięto duplikat z WSJT-X: {1}", calls)
        }
    }
}

/// Plik kopii dziennika.
struct LogbookBackup: Identifiable, Hashable {
    let url: URL
    let date: Date
    let count: Int
    var id: URL { url }

    /// Rodzaj kopii z nazwy pliku.
    var kind: String {
        let name = url.lastPathComponent
        if url.path.contains("com~apple~CloudDocs") { return L("kopia dnia w iCloud Drive") }
        if name == "logbook-kopia.json" { return L("stan z ostatniego uruchomienia") }
        if name.hasPrefix("logbook-przed-usunieciem") { return L("przed usunięciem dziennika") }
        if name.hasPrefix("logbook-przed-przywroceniem") { return L("przed przywróceniem kopii") }
        return L("kopia")
    }
}

/// Wynik sprawdzenia pliku ADIF przed importem.
struct ImportAnalysis {
    var newQSOs: [QSO] = []
    var duplicates: [ImportDuplicate] = []
    var invalid = 0
}

/// Łączność z pliku, która pokrywa się z już zapisaną (albo z wcześniejszą w tym samym pliku).
struct ImportDuplicate: Identifiable {
    let id = UUID()
    let imported: QSO
    let existing: QSO
    let inFile: Bool
}

// MARK: - Spot i uzupełnianie z QRZ (menu prawego przycisku na łączności)

extension Notification.Name {
    /// Przygotowany spot (userInfo["command"]) - główne okno wpisuje go w pole komendy DX Cluster.
    static let prepareSpot = Notification.Name("ft710.prepareSpot")
    /// Zapisano nową łączność (userInfo["call"]).
    static let qsoLogged = Notification.Name("ft710.qsoLogged")
}

extension QSO {
    /// Komenda spotu klastra: „DX 14025.0 DL1ABC CW 599 tnx QSO” (nil bez częstotliwości).
    var spotCommand: String? {
        guard freqHz > 0 else { return nil }
        let kHz = String(format: "%.1f", Double(freqHz) / 1000)
        var comment = modeLabel
        if !rstSent.isEmpty { comment += " " + rstSent }
        comment += " tnx QSO"
        return "DX \(kHz) \(call) \(comment)"
    }

    /// Uzupełnia tylko puste pola danymi z QRZ; nil = nic do zmiany.
    /// `awayFields` - stacja pracuje spoza swojego kraju (P4/WE9V): z QRZ tylko imię, kraj i strefy z prefiksu
    /// (cty.dat), bez QTH, lokatora i odległości z jej domowego adresu.
    func filled(from record: QRZRecord, fallbackMyGrid: String, awayFields: [String: String]? = nil) -> QSO? {
        var q = self
        if q.name.isEmpty {
            q.name = record.firstName.isEmpty ? record.displayName : record.firstName
        }
        if let awayFields {
            for (key, value) in awayFields where !value.isEmpty && (q.extra[key] ?? "").isEmpty { q.extra[key] = value }
            return q == self ? nil : q
        }
        if q.qth.isEmpty { q.qth = record.city }
        if q.grid.isEmpty {
            q.grid = record.grid.isEmpty ? (record.coordinate.map { Geo.grid(for: $0) } ?? "") : record.grid.uppercased()
        }
        let extras = ["COUNTRY": record.country, "DXCC": record.dxcc, "CQZ": record.cqZone, "ITUZ": record.ituZone]
        for (key, value) in extras where !value.isEmpty && (q.extra[key] ?? "").isEmpty {
            q.extra[key] = value
        }
        if (q.extra["DISTANCE"] ?? "").isEmpty {
            let home = q.myGrid.isEmpty ? fallbackMyGrid : q.myGrid
            if let a = Geo.coordinate(fromGrid: home), let b = Geo.coordinate(fromGrid: q.grid) {
                q.extra["DISTANCE"] = String(Int(Geo.distanceKm(a, b).rounded()))
            }
        }
        return q == self ? nil : q
    }
}

extension LogbookStore {
    /// Uzupełnia zaznaczone łączności z QRZ.com (tylko puste pola). Zwraca podsumowanie.
    func fillFromQRZ(ids: Set<QSO.ID>, qrz: QRZClient) async -> String {
        let targets = qsos.filter { ids.contains($0.id) }
        var updated = 0, unchanged = 0, notFound = 0
        var failure: String?
        for qso in targets {
            switch await qrz.lookup(qso.call) {
            case .found(let record):
                // aktualna wersja (mogła zostać zmieniona w międzyczasie)
                guard let current = qsos.first(where: { $0.id == qso.id }) else { continue }
                let away = OperatingLocation.isAwayFromHome(current.call) ? OperatingLocation.ctyFields(current.call) : nil
                if let filled = current.filled(from: record, fallbackMyGrid: myGrid, awayFields: away) {
                    edit(filled)
                    updated += 1
                } else {
                    unchanged += 1
                }
            case .notFound:
                notFound += 1
            case .failed(let message):
                failure = message
            }
            if failure != nil { break }
        }
        if let failure { return L("QRZ: {1}", failure) }
        return L("QRZ: uzupełniono {1}, bez zmian {2}, nie znaleziono {3}", updated, unchanged, notFound)
    }
}

// MARK: - Częstotliwość w dzienniku (wszystkie pasma amatorskie, nie tylko FT-710)

/// Dziennik przyjmuje łączności także z innych radiotelefonów (WSJT-X, import ADIF), więc pasma
/// i odczyt częstotliwości obejmują całe zakresy amatorskie - inaczej niż sterowanie FT-710.
enum LogFrequency {
    /// Pasma wg ADIF 3.1 (Hz).
    static let bands: [(name: String, range: ClosedRange<Int>)] = [
        ("2190m", 135_700...137_800), ("630m", 472_000...479_000), ("560m", 501_000...504_000),
        ("160m", 1_800_000...2_000_000), ("80m", 3_500_000...4_000_000), ("60m", 5_060_000...5_450_000),
        ("40m", 7_000_000...7_300_000), ("30m", 10_100_000...10_150_000), ("20m", 14_000_000...14_350_000),
        ("17m", 18_068_000...18_168_000), ("15m", 21_000_000...21_450_000), ("12m", 24_890_000...24_990_000),
        ("10m", 28_000_000...29_700_000), ("8m", 40_000_000...45_000_000), ("6m", 50_000_000...54_000_000),
        ("5m", 54_000_001...69_900_000), ("4m", 70_000_000...71_000_000), ("2m", 144_000_000...148_000_000),
        ("1.25m", 222_000_000...225_000_000), ("70cm", 420_000_000...450_000_000),
        ("33cm", 902_000_000...928_000_000), ("23cm", 1_240_000_000...1_300_000_000),
        ("13cm", 2_300_000_000...2_450_000_000), ("9cm", 3_300_000_000...3_500_000_000),
        ("6cm", 5_650_000_000...5_925_000_000), ("3cm", 10_000_000_000...10_500_000_000)
    ]

    static func band(for hz: Int) -> String? {
        bands.first { $0.range.contains(hz) }?.name
    }

    /// Pole „MHz” w dzienniku: liczba bez jednostki to zawsze MHz (144.176 = 144,176 MHz);
    /// można dopisać jednostkę: kHz, MHz, GHz, Hz.
    static func parseMHz(_ input: String) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        var multiplier = 1_000_000.0
        for (suffix, factor) in [("ghz", 1e9), ("mhz", 1e6), ("khz", 1e3), ("hz", 1.0)] where text.hasSuffix(suffix) {
            multiplier = factor
            text = String(text.dropLast(suffix.count))
            break
        }
        guard let value = Double(text), value > 0 else { return nil }
        let hz = (value * multiplier).rounded()
        guard hz >= 1_000, hz <= 300e9 else { return nil }
        return Int(hz)
    }
}

extension LogbookStore {
    /// Naprawa łączności zapisanych z częstotliwością 1000× za małą (dawny błąd okna edycji:
    /// „144.176” traktowane jak kHz). Poprawiane tylko, gdy zapisane pasmo jasno to potwierdza.
    func repairScaledFrequencies() -> Int {
        var fixed: [QSO] = []
        for qso in qsos where qso.freqHz > 0 && !qso.band.isEmpty {
            let band = qso.band.lowercased()
            guard LogFrequency.band(for: qso.freqHz) != band,
                  LogFrequency.band(for: qso.freqHz * 1000) == band else { continue }
            var repaired = qso
            repaired.freqHz = qso.freqHz * 1000
            fixed.append(repaired)
        }
        if !fixed.isEmpty { update(fixed) }
        return fixed.count
    }
}


extension LogbookStore {
    /// Łączność z formularza - wspólna dla okna (zakładka DZIENNIK) i panelu zdalnego: pola stacji i profilu,
    /// kraj i strefy (z QRZ dla stacji w domu; dla pracującej spoza kraju, np. P4/WE9V - z prefiksu, cty.dat),
    /// odległość (DISTANCE) z lokatora albo położenia z QRZ.
    func makeQSO(call: String, start: Date, end: Date, freqHz: Int, preset: LogModePreset, rstSent: String,
                 rstRcvd: String, name: String, qth: String, grid: String, comment: String, record: QRZRecord?) -> QSO {
        var qso = QSO(call: call, start: start, end: end, freqHz: freqHz, band: Bands.name(for: freqHz) ?? "",
                      mode: preset.mode, submode: preset.submode)
        qso.rstSent = rstSent.trimmingCharacters(in: .whitespaces)
        qso.rstRcvd = rstRcvd.trimmingCharacters(in: .whitespaces)
        qso.name = name.trimmingCharacters(in: .whitespaces)
        qso.qth = qth.trimmingCharacters(in: .whitespaces)
        qso.grid = grid.trimmingCharacters(in: .whitespaces).uppercased()
        qso.comment = comment.trimmingCharacters(in: .whitespaces)
        qso.stationCall = myCall.uppercased()
        qso.myGrid = myGrid.uppercased()
        for (key, value) in profileADIFFields { qso.extra[key] = value }      // MY_NAME, MY_CITY, …
        let matching = record?.call == QRZClient.baseCall(call) ? record : nil
        let away = OperatingLocation.isAwayFromHome(call)
        if away {
            for (key, value) in OperatingLocation.ctyFields(call) { qso.extra[key] = value }
        } else if let matching {
            let fields = ["COUNTRY": matching.country, "DXCC": matching.dxcc, "CQZ": matching.cqZone, "ITUZ": matching.ituZone]
            for (key, value) in fields where !value.isEmpty { qso.extra[key] = value }
        }
        if let home = Geo.coordinate(fromGrid: qso.myGrid),
           let remote = Geo.coordinate(fromGrid: qso.grid) ?? (away ? nil : matching?.coordinate) {
            qso.extra["DISTANCE"] = String(Int(Geo.distanceKm(home, remote).rounded()))
        }
        return qso
    }
}
