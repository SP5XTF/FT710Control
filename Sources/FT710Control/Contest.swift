import Foundation

/// Zawody z wbudowaną punktacją. Reguły sprawdzone z regulaminami: CQ WPX 2025 (cqwpx.com), SP DX Contest
/// 2023-2024 (PZK), IARU HF (ARRL, wersja 1.21), ARRL DX; CQ WW wg regulaminu CQ. Logika sprawdzona
/// prototypem (52 testy). Przed zawodami warto sprawdzić aktualny regulamin (link w opisie zawodów).
enum ContestKind: String, CaseIterable, Identifiable, Codable {
    case cqww, cqwpx, iaru, spdx, arrldx, generic
    var id: String { rawValue }

    var name: String {
        switch self {
        case .cqww: return "CQ World Wide DX"
        case .cqwpx: return "CQ WPX"
        case .iaru: return "IARU HF World Championship"
        case .spdx: return "SP DX Contest"
        case .arrldx: return "ARRL International DX"
        case .generic: return L("Zawody ogólne (RST + numer)")
        }
    }

    var rulesURL: URL? {
        switch self {
        case .cqww: return URL(string: "https://www.cqww.com/rules.htm")
        case .cqwpx: return URL(string: "https://www.cqwpx.com/rules.htm")
        case .iaru: return URL(string: "https://www.arrl.org/iaru-hf-world-championship")
        case .spdx: return URL(string: "https://spdxcontest.pzk.org.pl")
        case .arrldx: return URL(string: "https://www.arrl.org/arrl-dx")
        case .generic: return nil
        }
    }

    /// Opis: termin, wymiana, punktacja (wyświetlany w oknie zawodów).
    var summary: String {
        switch self {
        case .cqww:
            return L("Ostatni pełny weekend października (SSB) i listopada (CW), 00:00-23:59 UTC niedzieli. Wymiana: RST + strefa CQ. Punkty: inny kontynent 3, ten sam kontynent 1 (Ameryka Płn. 2), własny kraj 0. Mnożniki: strefy CQ i kraje (DXCC + WAE) na każdym paśmie.")
        case .cqwpx:
            return L("SSB: koniec marca, CW: koniec maja. Wymiana: RST + numer od 001. Punkty: inny kontynent 3 (6 na 40/80/160 m), ten sam kontynent 1 (2), własny kraj 1. Mnożnik: różne prefiksy, raz w całych zawodach.")
        case .iaru:
            return L("Drugi pełny weekend lipca, 12:00-12:00 UTC, CW i SSB. Wymiana: RST + strefa ITU (stacje HQ: skrót organizacji). Punkty: własna strefa i stacje HQ 1, ten sam kontynent 3, inny kontynent 5. Mnożniki: strefy ITU i stacje HQ na każdym paśmie.")
        case .spdx:
            return L("Pierwszy pełny weekend kwietnia, 15:00 UTC sob. - 14:59 UTC niedz., CW i SSB. SP: RST + litera województwa; zagraniczne: RST + numer. Punkty SP: poza Europą 3, Europa 1, SP-SP 0; zagraniczne: 3 za stację SP. Mnożniki SP: kraje DXCC na każdym paśmie; zagraniczne: województwa na każdym paśmie.")
        case .arrldx:
            return L("CW: 3. weekend lutego, SSB: 1. weekend marca. Stacje DX pracują tylko z W/VE. Wymiana: W/VE - RST + stan/prowincja; DX - RST + moc. Punkty: 3 za łączność. Mnożniki: DX - stany i prowincje na każdym paśmie; W/VE - kraje DXCC na każdym paśmie.")
        case .generic:
            return L("Dowolne zawody z wymianą RST + numer. Punkty: 1 za łączność. Mnożniki: kraje DXCC na każdym paśmie.")
        }
    }

    var bands: [String] { ["160m", "80m", "40m", "20m", "15m", "10m"] }

    /// Nazwa zawodów w nagłówku Cabrillo i polu ADIF CONTEST_ID.
    func cabrilloName(mode: ContestMode) -> String {
        switch self {
        case .cqww: return mode == .cw ? "CQ-WW-CW" : mode == .rtty ? "CQ-WW-RTTY" : "CQ-WW-SSB"
        case .cqwpx: return mode == .cw ? "CQ-WPX-CW" : mode == .rtty ? "CQ-WPX-RTTY" : "CQ-WPX-SSB"
        case .iaru: return "IARU-HF"
        case .spdx: return "SPDX"
        case .arrldx: return mode == .cw ? "ARRL-DX-CW" : "ARRL-DX-SSB"
        case .generic: return "DX"
        }
    }

    /// Ta sama stacja: raz na pasmo (zawody jednej emisji) albo raz na pasmo i emisję (CW + SSB).
    var dupePerMode: Bool { self == .iaru || self == .spdx || self == .generic }
}

enum ContestMode: String, CaseIterable, Identifiable, Codable {
    case cw = "CW", ssb = "SSB", rtty = "RTTY", mixed = "MIXED"
    var id: String { rawValue }
    var defaultRST: String { self == .ssb ? "59" : "599" }
    var cabrilloCategory: String { self == .ssb ? "SSB" : rawValue }
}

/// Rola stacji w zawodach z dwiema stronami (wykrywana z mojego znaku).
enum ContestRole { case normal, spStation, spForeign, arrlWVE, arrlDX }

/// Sesja zawodów: wybór zawodów, emisja, moja wymiana, nagłówek Cabrillo. QSO sesji są w głównym dzienniku
/// (pole APP_FT710CONTROL_SESSION), wymiany w standardowych polach ADIF (CONTEST_ID, STX, SRX, *_STRING).
struct ContestSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ContestKind = .cqww
    var mode: ContestMode = .cw
    var started = Date()
    /// Moja stała wymiana (strefa, województwo, moc, stan) - pusta, gdy nadaję numer.
    var myExchange = ""
    // nagłówek Cabrillo
    var categoryOperator = "SINGLE-OP"
    var categoryBand = "ALL"
    var categoryPower = "LOW"
    var categoryAssisted = "NON-ASSISTED"
    var categoryTransmitter = "ONE"
    var club = ""
    var operators = ""
    var email = ""
    var address = ""
    var soapbox = ""
    var contestNameOverride = ""

    var cabrilloName: String {
        contestNameOverride.isEmpty ? kind.cabrilloName(mode: mode) : contestNameOverride
    }
}

/// Jedna łączność z punktu widzenia punktacji.
struct ContestQSOInfo {
    let call: String
    let band: String
    let mode: String            // CW / SSB / RTTY (grupa emisji)
    let exchange: String        // wymiana odebrana (bez RST)
}

/// Ocena łączności przed zapisem: dubel, punkty, nowe mnożniki.
struct ContestEvaluation {
    var match: CTYMatch?
    var dupe = false
    var points = 0
    var newMultipliers: [String] = []
    var note: String?           // np. „stacje DX pracują tylko z W/VE”
}

struct ContestScore: Equatable {
    struct BandLine: Equatable { var band: String; var qsos = 0; var points = 0; var mults = 0 }
    var qsos = 0
    var dupes = 0
    var points = 0
    var multipliers = 0
    var total: Int { points * multipliers }
    var bands: [BandLine] = []
}

enum ContestEngine {
    static let lowBands: Set<String> = ["160m", "80m", "40m"]
    static let polishProvinces: Set<String> = ["B", "C", "D", "F", "G", "J", "K", "L", "M", "O", "P", "R", "S", "U", "W", "Z"]

    static func role(kind: ContestKind, me: CTYMatch?) -> ContestRole {
        guard let me else { return .normal }
        switch kind {
        case .spdx: return me.entity.prefix == "SP" ? .spStation : .spForeign
        case .arrldx: return ["K", "VE"].contains(me.entity.prefix) ? .arrlWVE : .arrlDX
        default: return .normal
        }
    }

    /// Czy moja wymiana to numer kolejny (zamiast stałego tekstu).
    static func sendsSerial(kind: ContestKind, role: ContestRole) -> Bool {
        switch kind {
        case .cqwpx, .generic: return true
        case .spdx: return role == .spForeign
        default: return false
        }
    }

    /// Co odbieramy - opis pola wymiany.
    static func receivedLabel(kind: ContestKind, role: ContestRole) -> String {
        switch kind {
        case .cqww: return L("Strefa CQ")
        case .cqwpx, .generic: return L("Numer")
        case .iaru: return L("Strefa ITU / HQ")
        case .spdx: return role == .spStation ? L("Numer") : L("Województwo")
        case .arrldx: return role == .arrlDX ? L("Stan / prowincja") : L("Moc")
        }
    }

    /// Podpowiedź wymiany odebranej z bazy krajów (strefa CQ / ITU).
    static func suggestedExchange(kind: ContestKind, other: CTYMatch?) -> String {
        guard let other else { return "" }
        switch kind {
        case .cqww: return String(other.cqZone)
        case .iaru: return String(other.ituZone)
        default: return ""
        }
    }

    /// Domyślna moja wymiana (strefa z bazy krajów; województwo/moc/stan - do wpisania).
    static func defaultMyExchange(kind: ContestKind, me: CTYMatch?) -> String {
        guard let me else { return "" }
        switch kind {
        case .cqww: return String(format: "%02d", me.cqZone)
        case .iaru: return String(me.ituZone)
        case .arrldx: return role(kind: kind, me: me) == .arrlDX ? "100" : ""
        default: return ""
        }
    }

    /// Prefiks WPX wg regulaminu 2025 (przykłady z regulaminu sprawdzone testem).
    static func wpxPrefix(_ rawCall: String) -> String {
        let ignore: Set<String> = ["P", "M", "MM", "AM", "QRP", "A", "E", "J"]
        var parts = rawCall.uppercased().split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts = [parts[0]] + parts.dropFirst().filter { !ignore.contains($0) }
        if parts.count >= 2 {
            let a = parts[0], b = parts[1]
            if b.count == 1, b.first!.isNumber {                                   // W1ABC/4 -> W4ABC -> W4
                return singlePrefix(CTYTable.replacingAreaDigit(a, with: b))
            }
            let portable = a.count < b.count ? a : b                               // dopisek przenośny = prefiks
            if !portable.contains(where: { $0.isNumber }) { return String(portable.prefix(2)) + "0" }   // PA/N8BJQ -> PA0
            let last = portable.lastIndex(where: { $0.isNumber })!
            return String(portable[...last])
        }
        return singlePrefix(parts[0])
    }

    /// Prefiks zwykłego znaku: do ostatniej cyfry, po której są już tylko litery (3Z9A -> 3Z9, LY1000A -> LY1000);
    /// znak bez cyfry -> dwie litery + 0 (XEFTJW -> XE0).
    private static func singlePrefix(_ call: String) -> String {
        guard let last = call.lastIndex(where: { $0.isNumber }) else { return String(call.prefix(2)) + "0" }
        let rest = call[call.index(after: last)...]
        return !rest.isEmpty && rest.allSatisfy({ $0.isLetter }) ? String(call[...last]) : call
    }

    /// Punkty za łączność.
    static func points(kind: ContestKind, role: ContestRole, me: CTYMatch, other: CTYMatch, band: String, exchange: String) -> Int {
        let sameEntity = other.entity === me.entity
        let low = lowBands.contains(band)
        switch kind {
        case .cqww:
            if sameEntity { return 0 }
            if other.continent != me.continent { return 3 }
            return me.continent == "NA" ? 2 : 1
        case .cqwpx:
            if sameEntity { return 1 }
            if other.continent != me.continent { return low ? 6 : 3 }
            if me.continent == "NA" { return low ? 4 : 2 }
            return low ? 2 : 1
        case .iaru:
            guard let zone = Int(exchange) else { return 1 }                        // HQ / przedstawiciel IARU
            if zone == me.ituZone { return 1 }
            return other.continent != me.continent ? 5 : 3
        case .spdx:
            if role == .spStation {
                if other.entity.prefix == "SP" { return 0 }
                return other.continent == "EU" ? 1 : 3
            }
            return other.entity.prefix == "SP" ? 3 : 0
        case .arrldx:
            let otherWVE = ["K", "VE"].contains(other.entity.prefix)
            return (role == .arrlDX) == otherWVE ? 3 : 0
        case .generic:
            return 1
        }
    }

    /// Klucze mnożników łączności (z pasmem, gdy liczone na pasmo) i ich czytelne opisy.
    static func multipliers(kind: ContestKind, role: ContestRole, other: CTYMatch, call: String, band: String,
                            exchange: String) -> [(key: String, label: String)] {
        let exch = exchange.uppercased().trimmingCharacters(in: .whitespaces)
        switch kind {
        case .cqww:
            let zone = Int(exch) ?? other.cqZone
            return [("\(band)|C|\(other.entity.prefix)", other.entity.name), ("\(band)|Z|\(zone)", L("strefa {1}", zone))]
        case .cqwpx:
            let prefix = wpxPrefix(call)
            return [("P|\(prefix)", L("prefiks {1}", prefix))]
        case .iaru:
            if let zone = Int(exch) { return [("\(band)|Z|\(zone)", L("strefa ITU {1}", zone))] }
            return exch.isEmpty ? [] : [("\(band)|H|\(exch)", "HQ \(exch)")]
        case .spdx:
            if role == .spStation {
                guard other.entity.prefix != "SP" else { return [] }
                let key = CTYTable.dxccKey(other)
                return [("\(band)|D|\(key)", other.entity.name)]
            }
            guard other.entity.prefix == "SP", polishProvinces.contains(exch) else { return [] }
            return [("\(band)|W|\(exch)", L("województwo {1}", exch))]
        case .arrldx:
            if role == .arrlDX {
                guard ["K", "VE"].contains(other.entity.prefix), !exch.isEmpty else { return [] }
                return [("\(band)|S|\(exch)", exch)]
            }
            guard !["K", "VE"].contains(other.entity.prefix) else { return [] }
            return [("\(band)|D|\(CTYTable.dxccKey(other))", other.entity.name)]
        case .generic:
            return [("\(band)|D|\(CTYTable.dxccKey(other))", other.entity.name)]
        }
    }

    static func dupeKey(kind: ContestKind, call: String, band: String, mode: String) -> String {
        kind.dupePerMode ? "\(call.uppercased())|\(band)|\(mode)" : "\(call.uppercased())|\(band)"
    }

    /// Wynik sesji (dubel liczony raz; dalsze - bez punktów i mnożników).
    static func score(kind: ContestKind, myCall: String, qsos: [ContestQSOInfo], cty: CTYTable) -> ContestScore {
        var result = ContestScore()
        guard let me = cty.lookup(myCall) else { return result }
        let role = role(kind: kind, me: me)
        var seen = Set<String>(), mults = Set<String>()
        var perBand: [String: ContestScore.BandLine] = [:]
        for qso in qsos {
            let key = dupeKey(kind: kind, call: qso.call, band: qso.band, mode: qso.mode)
            guard !seen.contains(key) else { result.dupes += 1; continue }
            seen.insert(key)
            result.qsos += 1
            var line = perBand[qso.band] ?? .init(band: qso.band)
            line.qsos += 1
            if let other = cty.lookup(qso.call) {
                let p = points(kind: kind, role: role, me: me, other: other, band: qso.band, exchange: qso.exchange)
                result.points += p
                line.points += p
                for m in multipliers(kind: kind, role: role, other: other, call: qso.call, band: qso.band, exchange: qso.exchange)
                where !mults.contains(m.key) {
                    mults.insert(m.key)
                    line.mults += 1
                }
            }
            perBand[qso.band] = line
        }
        result.multipliers = mults.count
        result.bands = kind.bands.compactMap { perBand[$0] }
        return result
    }

    /// Ocena łączności w trakcie wpisywania (przed zapisem).
    static func evaluate(kind: ContestKind, myCall: String, call: String, band: String, mode: String, exchange: String,
                         previous: [ContestQSOInfo], cty: CTYTable) -> ContestEvaluation {
        var result = ContestEvaluation()
        let other = cty.lookup(call)
        result.match = other
        let key = dupeKey(kind: kind, call: call, band: band, mode: mode)
        result.dupe = previous.contains { dupeKey(kind: kind, call: $0.call, band: $0.band, mode: $0.mode) == key }
        guard let me = cty.lookup(myCall), let other, !result.dupe else { return result }
        let role = role(kind: kind, me: me)
        result.points = points(kind: kind, role: role, me: me, other: other, band: band, exchange: exchange)
        if kind == .arrldx, result.points == 0 {
            result.note = role == .arrlDX ? L("Stacje DX pracują w tych zawodach tylko z W/VE") : L("Stacje W/VE pracują tylko z DX")
        }
        if kind == .spdx, result.points == 0 {
            result.note = role == .spStation ? L("Łączności SP-SP nie są punktowane") : L("Punktowane są tylko łączności ze stacjami SP")
        }
        var worked = Set<String>()
        for q in previous {
            guard let o = cty.lookup(q.call) else { continue }
            for m in multipliers(kind: kind, role: role, other: o, call: q.call, band: q.band, exchange: q.exchange) { worked.insert(m.key) }
        }
        result.newMultipliers = multipliers(kind: kind, role: role, other: other, call: call, band: band, exchange: exchange)
            .filter { !worked.contains($0.key) }.map { $0.label }
        return result
    }
}

/// Eksport Cabrillo 3.0 (format zgłoszeń logów zawodów).
enum Cabrillo {
    static func modeCode(_ qso: QSO) -> String {
        switch qso.mode.uppercased() {
        case "CW": return "CW"
        case "SSB", "AM", "FM": return "PH"
        case "RTTY": return "RY"
        default: return "DG"
        }
    }

    static func export(session: ContestSession, qsos: [QSO], myCall: String, myGrid: String, name: String,
                       claimedScore: Int) -> String {
        let date = DateFormatter(), time = DateFormatter()
        for f in [date, time] { f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX") }
        date.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HHmm"
        var lines = ["START-OF-LOG: 3.0",
                     "CONTEST: \(session.cabrilloName)",
                     "CALLSIGN: \(myCall.uppercased())",
                     "CATEGORY-OPERATOR: \(session.categoryOperator)",
                     "CATEGORY-ASSISTED: \(session.categoryAssisted)",
                     "CATEGORY-BAND: \(session.categoryBand)",
                     "CATEGORY-MODE: \(session.mode.cabrilloCategory)",
                     "CATEGORY-POWER: \(session.categoryPower)",
                     "CATEGORY-STATION: FIXED",
                     "CATEGORY-TRANSMITTER: \(session.categoryTransmitter)",
                     "CLAIMED-SCORE: \(claimedScore)"]
        if !session.club.isEmpty { lines.append("CLUB: \(session.club)") }
        lines.append("CREATED-BY: FT-710 Control \(ADIF.programVersion)")
        if !session.email.isEmpty { lines.append("EMAIL: \(session.email)") }
        if !myGrid.isEmpty { lines.append("GRID-LOCATOR: \(myGrid.uppercased())") }
        if !name.isEmpty { lines.append("NAME: \(name)") }
        for line in session.address.split(separator: "\n") where !line.isEmpty { lines.append("ADDRESS: \(line)") }
        lines.append("OPERATORS: \(session.operators.isEmpty ? myCall.uppercased() : session.operators.uppercased())")
        for line in session.soapbox.split(separator: "\n") where !line.isEmpty { lines.append("SOAPBOX: \(line)") }
        for q in qsos.sorted(by: { $0.start < $1.start }) {
            let khz = String(q.freqHz / 1000)
            let sent = q.extra["STX_STRING"] ?? q.extra["STX"].map { String(format: "%03d", Int($0) ?? 0) } ?? ""
            let rcvd = q.extra["SRX_STRING"] ?? q.extra["SRX"].map { String(format: "%03d", Int($0) ?? 0) } ?? ""
            let fields = [pad(khz, 5), modeCode(q), date.string(from: q.start), time.string(from: q.start),
                          pad(myCall.uppercased(), 13), pad(q.rstSent, 3), pad(sent, 6),
                          pad(q.call.uppercased(), 13), pad(q.rstRcvd, 3), pad(rcvd, 6)]
            lines.append(ADIF.ascii("QSO: " + fields.joined(separator: " ")).trimmingCharacters(in: .whitespaces))
        }
        lines.append("END-OF-LOG:")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
