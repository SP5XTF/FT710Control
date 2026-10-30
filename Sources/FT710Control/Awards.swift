import Foundation

/// Dyplomy w oknie „Dyplomy…” (okno dziennika). Wszystkie liczone z dziennika według tych samych zasad
/// potwierdzeń: LoTW zawsze, eQSL i QRZ - jeśli zaznaczone „licz też…”.
enum AwardKind: String, CaseIterable, Identifiable {
    case dxcc, waz, wpx, vucc, pota, iota, sota, wwff, pga

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dxcc: return "DXCC"
        case .waz: return "WAZ"
        case .wpx: return "WPX"
        case .vucc: return "VUCC"
        case .pota: return "POTA"
        case .iota: return "IOTA"
        case .sota: return "SOTA"
        case .wwff: return "WWFF"
        case .pga: return "PGA"
        }
    }

    var description: String {
        switch self {
        case .dxcc: return L("Kraje DXCC (ARRL)")
        case .waz: return L("40 stref CQ (CQ Magazine)")
        case .wpx: return L("Prefiksy znaków (CQ Magazine)")
        case .vucc: return L("Kwadraty lokatora na 6 m i wyżej (ARRL)")
        case .pota: return L("Upolowane parki (Parks on the Air)")
        case .iota: return L("Wyspy (Islands on the Air, RSGB)")
        case .sota: return L("Szczyty (Summits on the Air)")
        case .wwff: return L("Obszary przyrodnicze (World Wide Flora & Fauna)")
        case .pga: return L("Polskie gminy (PGA)")
        }
    }

    /// Czy dyplom ma kategorie emisji (mieszane / fonia / CW / cyfrowe).
    var hasCategories: Bool { self == .dxcc || self == .waz || self == .wpx }
    /// POTA, SOTA, WWFF i PGA liczone z dziennika (bez potwierdzeń QSL); IOTA - z potwierdzeniami.
    var usesConfirmations: Bool { ![.pota, .sota, .wwff, .pga].contains(self) }

    /// Referencje łączności dla dyplomów „z numerami” (pole ADIF albo SIG/SIG_INFO).
    @MainActor
    func references(of qso: QSO) -> [String] {
        func sig(_ name: String) -> String { (qso.extra["SIG"] ?? "").uppercased() == name ? (qso.extra["SIG_INFO"] ?? "") : "" }
        let raw: String
        switch self {
        case .pota: return POTAManager.parkRefs(of: qso)
        case .iota: raw = qso.extra["IOTA"] ?? sig("IOTA")
        case .sota: raw = qso.extra["SOTA_REF"] ?? sig("SOTA")
        case .wwff: raw = qso.extra["WWFF_REF"] ?? sig("WWFF")
        case .pga:
            // gminy tylko w łącznościach z Polską (kod gminy w CNTY)
            guard let match = CTYDatabase.shared.table?.lookup(qso.call), CTYTable.dxccKey(match) == "SP" else { return [] }
            raw = qso.extra["CNTY"] ?? ""
        default: return []
        }
        return raw.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Wiersz dyplomu: jednostka / strefa / prefiks / kwadrat / park, z pasmami zrobionymi i potwierdzonymi.
struct AwardRow: Identifiable {
    let id: String
    var name: String
    var detail: String
    var workedBands: Set<String> = []
    var confirmedBands: Set<String> = []
    var qsoCount = 0
    var firstDate: Date?
    var confirmed: Bool { !confirmedBands.isEmpty }
}

struct AwardResult {
    var rows: [AwardRow] = []
    var bands: [String] = []
    /// Liczba wszystkich możliwych pozycji (DXCC: aktualne jednostki, WAZ: 40), nil - bez limitu.
    var total: Int?
    /// Pozycje jeszcze nie zrobione (WAZ: brakujące strefy).
    var missing: [String] = []
    var unknownCalls = 0

    var worked: Int { rows.count }
    var confirmed: Int { rows.filter(\.confirmed).count }
    func worked(on band: String) -> Int { rows.filter { $0.workedBands.contains(band) }.count }
    func confirmed(on band: String) -> Int { rows.filter { $0.confirmedBands.contains(band) }.count }
}

@MainActor
enum AwardCalculator {
    static let vhfBands = ["6m", "4m", "2m", "1.25m", "70cm", "33cm", "23cm", "13cm", "9cm", "6cm", "3cm"]

    static func compute(_ kind: AwardKind, qsos: [QSO], table: CTYTable?, category: DXCCCategory,
                        includeEQSL: Bool, includeQRZ: Bool) -> AwardResult {
        let selected = kind.hasCategories ? qsos.filter { category.includes($0) } : qsos
        switch kind {
        case .dxcc:
            let stats = DXCCStatistics(qsos: qsos, table: table, category: category,
                                       includeEQSL: includeEQSL, includeQRZ: includeQRZ)
            var result = AwardResult()
            result.rows = stats.rows.map {
                AwardRow(id: $0.id, name: $0.name, detail: $0.continent, workedBands: $0.workedBands,
                         confirmedBands: $0.confirmedBands, qsoCount: $0.qsoCount)
            }
            result.bands = stats.bands
            result.total = table == nil ? nil : stats.totalEntities
            result.unknownCalls = stats.unknownCalls
            return result
        case .waz:
            var result = group(selected, includeEQSL: includeEQSL, includeQRZ: includeQRZ) { qso in
                let zone = qso.extra["CQZ"].flatMap { Int($0) } ?? table?.lookup(qso.call)?.cqZone
                guard let zone, (1...40).contains(zone) else { return nil }
                return (String(format: "%02d", zone), L("Strefa CQ {1}", zone), "")
            }
            result.total = 40
            let worked = Set(result.rows.map(\.id))
            result.missing = (1...40).map { String(format: "%02d", $0) }.filter { !worked.contains($0) }
            return result
        case .wpx:
            return group(selected, includeEQSL: includeEQSL, includeQRZ: includeQRZ) { qso in
                let prefix = wpxPrefix(qso.call)
                return prefix.isEmpty ? nil : (prefix, prefix, "")
            }
        case .vucc:
            let vhf = selected.filter { vhfBands.contains($0.band.lowercased()) }
            return group(vhf, includeEQSL: includeEQSL, includeQRZ: includeQRZ) { qso in
                let grid = String(qso.grid.uppercased().prefix(4))
                return grid.count == 4 ? (grid, grid, "") : nil
            }
        case .pota, .iota, .sota, .wwff, .pga:
            var parks: [String: AwardRow] = [:]
            for qso in qsos {
                for ref in kind.references(of: qso) {
                    var row = parks[ref] ?? AwardRow(id: ref, name: ref, detail: "")
                    row.qsoCount += 1
                    let band = qso.band.lowercased()
                    if !band.isEmpty { row.workedBands.insert(band) }
                    if qso.isConfirmed(includeEQSL: includeEQSL, includeQRZ: includeQRZ), !band.isEmpty {
                        row.confirmedBands.insert(band)
                    }
                    if row.firstDate.map({ qso.start < $0 }) ?? true { row.firstDate = qso.start }
                    if row.detail.isEmpty { row.detail = QRZClient.baseCall(qso.call) }
                    parks[ref] = row
                }
            }
            var result = AwardResult()
            result.rows = Array(parks.values)
            result.bands = orderedBands(Set(result.rows.flatMap(\.workedBands)))
            return result
        }
    }

    /// Wspólne grupowanie: klucz (id, nazwa, szczegół) dla łączności → pasma zrobione i potwierdzone.
    private static func group(_ qsos: [QSO], includeEQSL: Bool, includeQRZ: Bool,
                              key: (QSO) -> (id: String, name: String, detail: String)?) -> AwardResult {
        var map: [String: AwardRow] = [:]
        var unknown = 0
        for qso in qsos {
            guard let k = key(qso) else { unknown += 1; continue }
            var row = map[k.id] ?? AwardRow(id: k.id, name: k.name, detail: k.detail)
            let band = qso.band.lowercased()
            row.qsoCount += 1
            if !band.isEmpty { row.workedBands.insert(band) }
            if qso.isConfirmed(includeEQSL: includeEQSL, includeQRZ: includeQRZ) {
                row.confirmedBands.insert(band.isEmpty ? "?" : band)
            }
            if row.firstDate.map({ qso.start < $0 }) ?? true { row.firstDate = qso.start }
            map[k.id] = row
        }
        var result = AwardResult()
        result.rows = Array(map.values)
        result.bands = orderedBands(Set(result.rows.flatMap(\.workedBands)))
        result.unknownCalls = unknown
        return result
    }

    static func orderedBands(_ used: Set<String>) -> [String] {
        let order = DXCCStatistics.bandOrder + vhfBands.filter { !DXCCStatistics.bandOrder.contains($0) }
        return order.filter { used.contains($0) } + used.subtracting(order).sorted()
    }

    /// Prefiks WPX (zasady CQ WPX): część znaku do ostatniej cyfry przed sufiksem (SP5XTF → SP5, 3Z9X → 3Z9,
    /// S50A → S50); znak bez cyfry - dwie litery i 0 (RAEM → RA0); /cyfra zmienia okręg (W1AW/4 → W4);
    /// prefiks kraju przed znakiem (DL/SP5XTF → DL0, KH6/K1ABC → KH6); przyrostki /P /M /MM /QRP… pomijane.
    /// Sprawdzone prototypem na 19 przypadkach.
    nonisolated static func wpxPrefix(_ call: String) -> String {
        let suffixes: Set<String> = ["P", "M", "MM", "AM", "QRP", "A", "B", "LH", "R", "J"]
        var parts = call.uppercased().split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let filtered = parts.filter { !suffixes.contains($0) }
        if !filtered.isEmpty { parts = filtered }
        guard let first = parts.first else { return "" }

        func basePrefix(_ s: String) -> String {
            // ostatnia cyfra, po której są już tylko litery
            if let last = s.lastIndex(where: \.isNumber), s.index(after: last) < s.endIndex,
               s[s.index(after: last)...].allSatisfy(\.isLetter) {
                return String(s[...last])
            }
            if !s.contains(where: \.isNumber) { return String(s.prefix(2)) + "0" }
            return s
        }
        func replaceDistrict(_ prefix: String, with digit: String) -> String {
            var p = prefix
            while let c = p.last, c.isNumber { p.removeLast() }
            return p + digit
        }

        guard parts.count >= 2 else { return basePrefix(first) }
        let a = parts[0], b = parts[1]
        if b.count == 1, b.allSatisfy(\.isNumber) { return replaceDistrict(basePrefix(a), with: b) }
        if a.count == 1, a.allSatisfy(\.isNumber) { return replaceDistrict(basePrefix(b), with: a) }
        let short = a.count <= b.count ? a : b
        if let c = short.last, c.isNumber { return short }
        if short.contains(where: \.isNumber) { return basePrefix(short) }
        return short + "0"
    }
}
