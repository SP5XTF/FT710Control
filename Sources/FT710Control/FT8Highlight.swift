import SwiftUI
import Combine

/// Wyróżnianie komunikatów FT8/FT4 jak „Decode Highlighting” w WSJT-X: te same kategorie, kolejność
/// pierwszeństwa (pierwsza pasująca i włączona wyznacza kolor) i kolory domyślne WSJT-X (odczytane z jego
/// ustawień). Pominięte: stany USA i użytkownicy LoTW (program nie ma tych danych).
enum FTHighlight: String, CaseIterable, Identifiable {
    case myCall, newContinent, newContinentBand, newCQZone, newCQZoneBand, newITUZone, newITUZoneBand,
         newDXCC, unconfirmedDXCC, newDXCCBand, unconfirmedDXCCBand,
         newGrid, newGridBand, newCall, newCallBand, cq, transmitted

    var id: String { rawValue }

    /// Kolory domyślne WSJT-X (tło; tekst czarny) jako 0xRRGGBB - także dla panelu zdalnego.
    var rgb: UInt32 {
        switch self {
        case .myCall: return 0xFF6666
        case .newContinent: return 0xFF0063
        case .newContinentBand: return 0xFF99C2
        case .newCQZone: return 0xFFBF00
        case .newCQZoneBand: return 0xFFE499
        case .newITUZone: return 0xA6FF00
        case .newITUZoneBand: return 0xDDFF99
        case .newDXCC: return 0xFF00FF
        case .newDXCCBand: return 0xFFAAFF
        case .unconfirmedDXCC: return 0xB469FF            // kolory nieużywanych tu kategorii WSJT-X „New US State”
        case .unconfirmedDXCCBand: return 0xD2A5FF
        case .newGrid: return 0xFF8000
        case .newGridBand: return 0xFFCC99
        case .newCall: return 0x00FFFF
        case .newCallBand: return 0x99FFFF
        case .cq: return 0x66FF66
        case .transmitted: return 0xFFFF00
        }
    }

    var color: Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }

    /// „#RRGGBB” dla przeglądarki.
    var hex: String { String(format: "#%06X", rgb) }

    var name: String {
        switch self {
        case .myCall: return L("Mój znak w komunikacie")
        case .newContinent: return L("Nowy kontynent")
        case .newContinentBand: return L("Nowy kontynent na paśmie")
        case .newCQZone: return L("Nowa strefa CQ")
        case .newCQZoneBand: return L("Nowa strefa CQ na paśmie")
        case .newITUZone: return L("Nowa strefa ITU")
        case .newITUZoneBand: return L("Nowa strefa ITU na paśmie")
        case .newDXCC: return L("Nowy kraj DXCC")
        case .newDXCCBand: return L("Nowy kraj DXCC na paśmie")
        case .unconfirmedDXCC: return L("Kraj niepotwierdzony")
        case .unconfirmedDXCCBand: return L("Kraj niepotwierdzony na paśmie")
        case .newGrid: return L("Nowy kwadrat lokatora")
        case .newGridBand: return L("Nowy kwadrat lokatora na paśmie")
        case .newCall: return L("Nowy znak")
        case .newCallBand: return L("Nowy znak na paśmie")
        case .cq: return L("CQ w komunikacie")
        case .transmitted: return L("Komunikat nadany")
        }
    }

    /// Domyślnie włączone: mój znak, nowy kraj (ogólnie i na paśmie), kraj niepotwierdzony (ogólnie i na paśmie),
    /// CQ, komunikat nadany.
    static let defaultEnabled: Set<FTHighlight> = [.myCall, .newDXCC, .unconfirmedDXCC, .newDXCCBand,
                                                   .unconfirmedDXCCBand, .cq, .transmitted]
}

/// Co jest w dzienniku: kontynenty, strefy CQ i ITU, kraje DXCC, kwadraty lokatora i znaki -
/// ogólnie i z pasmem („klucz|pasmo”), w dowolnym trybie.
struct FTWorkedIndex {
    var continents = Set<String>(), continentsBand = Set<String>()
    var cqZones = Set<String>(), cqZonesBand = Set<String>()
    var ituZones = Set<String>(), ituZonesBand = Set<String>()
    var dxcc = Set<String>(), dxccBand = Set<String>()
    /// Kraje potwierdzone (LoTW, opcjonalnie eQSL/QRZ) - ogólnie i z pasmem.
    var confirmedDXCC = Set<String>(), confirmedDXCCBand = Set<String>()
    var grids = Set<String>(), gridsBand = Set<String>()
    var calls = Set<String>(), callsBand = Set<String>()

    /// Strefy i kontynent z pól ADIF łączności (CQZ, ITUZ, CONT), a gdy ich brak - z cty.dat.
    init(qsos: [QSO], cty: CTYTable?, includeEQSL: Bool = false, includeQRZ: Bool = false) {
        for qso in qsos {
            let band = "|" + qso.band
            let base = QRZClient.baseCall(qso.call.uppercased())
            calls.insert(base); callsBand.insert(base + band)
            let grid = String(qso.grid.uppercased().prefix(4))
            if grid.count == 4 { grids.insert(grid); gridsBand.insert(grid + band) }
            let match = cty?.lookup(qso.call)
            if let match {
                let key = CTYTable.dxccKey(match)
                dxcc.insert(key); dxccBand.insert(key + band)
                if qso.isConfirmed(includeEQSL: includeEQSL, includeQRZ: includeQRZ) {
                    confirmedDXCC.insert(key); confirmedDXCCBand.insert(key + band)
                }
            }
            let continent = qso.extra["CONT"].flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? match?.continent ?? ""
            if !continent.isEmpty { continents.insert(continent); continentsBand.insert(continent + band) }
            if let cqz = qso.extra["CQZ"].flatMap({ Int($0) }) ?? match?.cqZone, cqz > 0 {
                cqZones.insert(String(cqz)); cqZonesBand.insert(String(cqz) + band)
            }
            if let ituz = qso.extra["ITUZ"].flatMap({ Int($0) }) ?? match?.ituZone, ituz > 0 {
                ituZones.insert(String(ituz)); ituZonesBand.insert(String(ituz) + band)
            }
        }
    }

    init() {}

    /// Kategorie pasujące do CQ (nadawca `call`, lokator z komunikatu), w kolejności pierwszeństwa.
    /// W każdej parze „nowy” / „nowy na paśmie” pasuje co najwyżej jedna; bez pasma (brak CAT) - tylko ogólne.
    func evaluate(call: String, grid: String?, match: CTYMatch?, band: String) -> [FTHighlight] {
        var result: [FTHighlight] = []
        func check(_ key: String, _ set: Set<String>, _ setBand: Set<String>, _ new: FTHighlight, _ newBand: FTHighlight) {
            guard !key.isEmpty else { return }
            if !set.contains(key) { result.append(new) }
            else if !band.isEmpty, !setBand.contains(key + "|" + band) { result.append(newBand) }
        }
        if let match {
            check(match.continent, continents, continentsBand, .newContinent, .newContinentBand)
            check(String(match.cqZone), cqZones, cqZonesBand, .newCQZone, .newCQZoneBand)
            check(String(match.ituZone), ituZones, ituZonesBand, .newITUZone, .newITUZoneBand)
            switch dxccStatus(match: match, band: band) {
            case .newDXCC: result.append(.newDXCC)
            case .newBand: result.append(.newDXCCBand)
            case .unconfirmed: result.append(.unconfirmedDXCC)
            case .unconfirmedNewBand: result += [.unconfirmedDXCC, .newDXCCBand]
            case .unconfirmedBand: result.append(.unconfirmedDXCCBand)
            case .confirmed: break
            }
        }
        if let grid, grid.count == 4 { check(grid, grids, gridsBand, .newGrid, .newGridBand) }
        check(QRZClient.baseCall(call), calls, callsBand, .newCall, .newCallBand)
        // kolejność pierwszeństwa = kolejność kategorii na liście
        let order = Dictionary(uniqueKeysWithValues: FTHighlight.allCases.enumerated().map { ($1, $0) })
        return result.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    /// Stacja (znak podstawowy) jest już w dzienniku na tym paśmie, w dowolnym trybie.
    func workedOnBand(_ call: String, band: String) -> Bool {
        !band.isEmpty && callsBand.contains(QRZClient.baseCall(call.uppercased()) + "|" + band)
    }

    /// Kategorie „kraj niepotwierdzony” nie dotyczą stacji już zrobionej na tym paśmie - kolejne QSO z nią
    /// zwykle nic nie zmienia (potwierdzenie przyjdzie, gdy ona wyśle log); fiolet zostaje dla innych stacji z tego kraju.
    static let unconfirmedKinds: Set<FTHighlight> = [.unconfirmedDXCC, .unconfirmedDXCCBand]

    /// Stan kraju w dzienniku (FT8 i DX Cluster): nowy, nowy na paśmie, niepotwierdzony (ogólnie / na paśmie),
    /// potwierdzony. „Niepotwierdzony” = zrobiony, ale bez potwierdzenia.
    func dxccStatus(match: CTYMatch, band: String) -> DXCCStatus {
        let key = CTYTable.dxccKey(match)
        guard dxcc.contains(key) else { return .newDXCC }
        let confirmedAnywhere = confirmedDXCC.contains(key)
        guard !band.isEmpty else { return confirmedAnywhere ? .confirmed : .unconfirmed }
        let workedOnBand = dxccBand.contains(key + "|" + band)
        if !confirmedAnywhere { return workedOnBand ? .unconfirmed : .unconfirmedNewBand }
        if !workedOnBand { return .newBand }
        return confirmedDXCCBand.contains(key + "|" + band) ? .confirmed : .unconfirmedBand
    }
}

/// Stan kraju DXCC względem dziennika i potwierdzeń.
enum DXCCStatus {
    case newDXCC              // nie ma w dzienniku
    case newBand              // potwierdzony, ale na tym paśmie nie zrobiony
    case unconfirmed          // zrobiony (także na tym paśmie), nigdzie niepotwierdzony
    case unconfirmedNewBand   // nigdzie niepotwierdzony i na tym paśmie nie zrobiony
    case unconfirmedBand      // potwierdzony gdzie indziej, na tym paśmie zrobiony bez potwierdzenia
    case confirmed            // potwierdzony na tym paśmie

    /// Kolor jak kategorie FT8 (WSJT-X); potwierdzony - bez koloru.
    var highlight: FTHighlight? {
        switch self {
        case .newDXCC: return .newDXCC
        case .newBand: return .newDXCCBand
        case .unconfirmed, .unconfirmedNewBand: return .unconfirmedDXCC
        case .unconfirmedBand: return .unconfirmedDXCCBand
        case .confirmed: return nil
        }
    }

    var label: String {
        switch self {
        case .newDXCC: return L("Nowy kraj DXCC")
        case .newBand: return L("Nowy kraj DXCC na paśmie")
        case .unconfirmed: return L("Kraj niepotwierdzony")
        case .unconfirmedNewBand: return L("Kraj niepotwierdzony, nowy na paśmie")
        case .unconfirmedBand: return L("Kraj niepotwierdzony na paśmie")
        case .confirmed: return L("Kraj potwierdzony na tym paśmie")
        }
    }
}

/// Wspólny indeks dziennika dla DX Cluster: przebudowa (z opóźnieniem) po zmianie dziennika, bazy krajów
/// albo ustawień „licz też eQSL / QRZ”.
@MainActor
final class WorkedIndexStore: ObservableObject {
    static let shared = WorkedIndexStore()
    @Published private(set) var index = FTWorkedIndex()
    private weak var logbook: LogbookStore?
    private var observers: [AnyCancellable] = []
    private var pending = false
    private var flags = (eqsl: false, qrz: false)

    func attach(_ logbook: LogbookStore) {
        guard self.logbook == nil else { return }
        self.logbook = logbook
        observers.append(logbook.$qsos.sink { [weak self] _ in Task { @MainActor in self?.schedule() } })
        observers.append(CTYDatabase.shared.$table.sink { [weak self] _ in Task { @MainActor in self?.schedule() } })
        observers.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.flagsChanged() } })
        schedule()
    }

    private func flagsChanged() {
        let d = UserDefaults.standard
        let now = (eqsl: d.bool(forKey: "qsl.countEQSL"), qrz: d.bool(forKey: "qsl.countQRZ"))
        if now != flags { schedule() }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, let logbook = self.logbook else { return }
            self.pending = false
            let d = UserDefaults.standard
            self.flags = (eqsl: d.bool(forKey: "qsl.countEQSL"), qrz: d.bool(forKey: "qsl.countQRZ"))
            self.index = FTWorkedIndex(qsos: logbook.qsos, cty: CTYDatabase.shared.table,
                                       includeEQSL: self.flags.eqsl, includeQRZ: self.flags.qrz)
        }
    }
}
