import Foundation

/// Kategoria dyplomu DXCC (ARRL): mieszane, fonia, CW, emisje cyfrowe.
enum DXCCCategory: String, CaseIterable, Identifiable {
    case mixed, phone, cw, digital

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mixed: return L("Mieszane")
        case .phone: return L("Fonia")
        case .cw: return "CW"
        case .digital: return L("Cyfrowe")
        }
    }

    /// Czy łączność należy do kategorii (fonia: SSB, AM, FM i emisje obrazowe; CW; reszta - cyfrowe).
    @MainActor
    func includes(_ qso: QSO) -> Bool {
        guard self != .mixed else { return true }
        let family = LogbookStore.modeFamily(qso)
        let group: DXCCCategory
        switch family {
        case "SSB", "AM", "FM", "DV", "SSTV", "ATV", "FAX": group = .phone
        case "CW": group = .cw
        default: group = .digital
        }
        return group == self
    }
}

/// Jedna jednostka DXCC w statystyce: pasma zrobione i potwierdzone.
struct DXCCRow: Identifiable {
    let id: String               // klucz jednostki (prefiks główny z cty.dat)
    let name: String
    let continent: String
    var workedBands: Set<String> = []
    var confirmedBands: Set<String> = []
    var qsoCount = 0
    var confirmed: Bool { !confirmedBands.isEmpty }
}

/// Statystyka DXCC z dziennika: dla każdej jednostki - na jakich pasmach zrobiona i potwierdzona.
/// Potwierdzenie: LoTW zawsze, eQSL i QRZ - jeśli włączone („licz też…” w oknie potwierdzeń).
struct DXCCStatistics {
    /// Pasma DXCC w kolejności (kolumny tabeli; pokazywane tylko te, które są w dzienniku).
    static let bandOrder = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "4m", "2m", "70cm"]

    var rows: [DXCCRow] = []
    var bands: [String] = []
    var totalEntities = 0
    var unknownCalls = 0              // łączności, dla których cty.dat nie zna kraju

    var worked: Int { rows.count }
    var confirmed: Int { rows.filter(\.confirmed).count }

    func worked(on band: String) -> Int { rows.filter { $0.workedBands.contains(band) }.count }
    func confirmed(on band: String) -> Int { rows.filter { $0.confirmedBands.contains(band) }.count }


    @MainActor
    init(qsos: [QSO], table: CTYTable?, category: DXCCCategory, includeEQSL: Bool, includeQRZ: Bool) {
        guard let table else { return }
        totalEntities = table.dxccEntityCount
        var map: [String: DXCCRow] = [:]
        var usedBands = Set<String>()
        for qso in qsos where category.includes(qso) {
            guard let match = table.lookup(qso.call) else { unknownCalls += 1; continue }
            let key = CTYTable.dxccKey(match)
            var row = map[key] ?? DXCCRow(id: key, name: table.dxccName(key) ?? match.entity.name,
                                          continent: match.continent)
            let band = qso.band.lowercased()
            row.qsoCount += 1
            if !band.isEmpty {
                row.workedBands.insert(band)
                usedBands.insert(band)
            }
            if qso.isConfirmed(includeEQSL: includeEQSL, includeQRZ: includeQRZ) {
                row.confirmedBands.insert(band.isEmpty ? "?" : band)
            }
            map[key] = row
        }
        rows = Array(map.values)
        bands = Self.bandOrder.filter { usedBands.contains($0) }
            + usedBands.subtracting(Self.bandOrder).sorted()
    }
}
