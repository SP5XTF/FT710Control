import Foundation

/// Kraj (jednostka DXCC / WAE) z pliku cty.dat.
final class CTYEntity: @unchecked Sendable {
    let name: String
    let prefix: String          // prefiks główny, np. "SP", "IG9"
    let waeOnly: Bool           // „*” w cty.dat: kraj z listy WAE (zawody CQ), nie DXCC
    let cqZone: Int
    let ituZone: Int
    let continent: String
    let latitude: Double
    let longitude: Double       // + na wschód (w cty.dat + oznacza zachód - odwracamy przy odczycie)

    init(name: String, prefix: String, waeOnly: Bool, cqZone: Int, ituZone: Int, continent: String,
         latitude: Double, longitude: Double) {
        self.name = name; self.prefix = prefix; self.waeOnly = waeOnly
        self.cqZone = cqZone; self.ituZone = ituZone; self.continent = continent
        self.latitude = latitude; self.longitude = longitude
    }
}

/// Wynik rozpoznania znaku: kraj plus strefy/kontynent (cty.dat może je nadpisywać dla prefiksu lub znaku).
struct CTYMatch {
    let entity: CTYEntity
    let cqZone: Int
    let ituZone: Int
    let continent: String
}

/// Baza krajów z pliku cty.dat (AD1C, country-files.com - wolno używać i rozpowszechniać z zachowaniem
/// informacji o prawach autorskich). Algorytm sprawdzony prototypem (52 testy: znaki przenośne, /P, /MM,
/// zmiana okręgu, wyjątki stref i kontynentów, kraje WAE).
final class CTYTable: @unchecked Sendable {
    private var prefixes: [String: CTYMatch] = [:]
    private var exact: [String: CTYMatch] = [:]
    private var maxLength = 0
    private(set) var entityCount = 0
    /// Jednostki wg prefiksu głównego (do nazw krajów DXCC i liczby wszystkich jednostek).
    private(set) var entitiesByPrefix: [String: CTYEntity] = [:]

    /// Liczba jednostek DXCC (bez krajów tylko WAE, oznaczonych w cty.dat gwiazdką).
    var dxccEntityCount: Int { entitiesByPrefix.values.filter { !$0.waeOnly }.count }

    /// Nazwa jednostki DXCC dla klucza z dxccKey (dla WAE - nazwa kraju macierzystego, np. IT9 → Italy).
    func dxccName(_ key: String) -> String? { entitiesByPrefix[key]?.name }

    /// Kraje tylko z listy WAE -> kraj DXCC (dla zawodów liczących DXCC).
    static let waeToDXCC = ["IG9": "I", "IT9": "I", "4U1V": "OE", "GM/s": "GM", "TA1": "TA", "JW/b": "JW"]

    init(text: String) {
        for block in text.split(separator: ";") {
            let parts = block.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 9,
                  let cq = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let itu = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let lat = Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let lon = Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let rawPrimary = parts[7].trimmingCharacters(in: .whitespacesAndNewlines)
            let entity = CTYEntity(name: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                   prefix: rawPrimary.hasPrefix("*") ? String(rawPrimary.dropFirst()) : rawPrimary,
                                   waeOnly: rawPrimary.hasPrefix("*"), cqZone: cq, ituZone: itu,
                                   continent: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
                                   latitude: lat, longitude: -lon)
            entityCount += 1
            if entitiesByPrefix[entity.prefix] == nil { entitiesByPrefix[entity.prefix] = entity }
            for alias in parts[8].split(separator: ",") {
                var item = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else { continue }
                let isExact = item.hasPrefix("=")
                if isExact { item.removeFirst() }
                let key = String(item.prefix { $0.isLetter || $0.isNumber || $0 == "/" }).uppercased()
                guard !key.isEmpty else { continue }
                let modifiers = String(item.dropFirst(key.count))
                let match = CTYMatch(entity: entity,
                                     cqZone: Self.number(in: modifiers, open: "(", close: ")") ?? cq,
                                     ituZone: Self.number(in: modifiers, open: "[", close: "]") ?? itu,
                                     continent: Self.text(in: modifiers, open: "{", close: "}") ?? entity.continent)
                if isExact {
                    exact[key] = match
                } else {
                    prefixes[key] = match
                    maxLength = max(maxLength, key.count)
                }
            }
        }
    }

    private static func text(in s: String, open: Character, close: Character) -> String? {
        guard let a = s.firstIndex(of: open), let b = s[a...].firstIndex(of: close), s.index(after: a) < b else { return nil }
        return String(s[s.index(after: a)..<b])
    }

    private static func number(in s: String, open: Character, close: Character) -> Int? {
        text(in: s, open: open, close: close).flatMap { Int($0) }
    }

    private func longest(_ s: String) -> CTYMatch? {
        var n = min(s.count, maxLength)
        while n > 0 {
            if let m = prefixes[String(s.prefix(n))] { return m }
            n -= 1
        }
        return nil
    }

    static let ignoredSuffixes: Set<String> = ["P", "M", "QRP", "A", "AM", "J", "E", "LH", "B"]

    /// Znak -> kraj, strefy, kontynent (albo nil: nieznany albo morski /MM).
    func lookup(_ rawCall: String) -> CTYMatch? {
        let call = rawCall.uppercased().trimmingCharacters(in: .whitespaces)
        guard !call.isEmpty else { return nil }
        if let m = exact[call] { return m }
        var parts = call.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.dropFirst().contains("MM") { return nil }                       // morski: bez kraju
        parts = [parts[0]] + parts.dropFirst().filter { !Self.ignoredSuffixes.contains($0) }
        if parts.count == 1 { return exact[parts[0]] ?? longest(parts[0]) }
        let a = parts[0], b = parts[1]
        if b.count == 1, b.first!.isNumber {                                      // W1ABC/4 -> okręg 4
            let changed = Self.replacingAreaDigit(a, with: b)
            return exact[changed] ?? longest(changed) ?? longest(a)
        }
        let portable = a.count <= b.count ? a : b                                 // DL/SP5XTF, SP5XTF/DL
        return exact[portable] ?? longest(portable) ?? longest(a)
    }

    /// W1ABC + "4" -> W4ABC (cyfra okręgu po części literowej prefiksu).
    static func replacingAreaDigit(_ call: String, with digit: String) -> String {
        let chars = Array(call)
        var i = 0
        while i < chars.count, !chars[i].isNumber || i == 0 { i += 1 }           // pierwsza cyfra po pierwszym znaku
        guard i < chars.count else { return call }
        var j = i
        while j < chars.count, chars[j].isNumber { j += 1 }
        return String(chars[..<i]) + digit + String(chars[j...])
    }

    /// Klucz kraju DXCC (kraje WAE -> kraj DXCC).
    static func dxccKey(_ match: CTYMatch) -> String {
        waeToDXCC[match.entity.prefix] ?? match.entity.prefix
    }
}

/// Plik cty.dat programu: pobieranie z country-files.com, zapis w katalogu programu, odczyt przy starcie.
@MainActor
final class CTYDatabase: ObservableObject {
    static let shared = CTYDatabase()

    @Published private(set) var table: CTYTable?
    @Published private(set) var status = ""
    @Published private(set) var updating = false

    static let sourceURL = URL(string: "https://www.country-files.com/cty/cty.dat")!

    private var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FT710Control", isDirectory: true).appendingPathComponent("cty.dat")
    }

    var fileDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private init() {
        load()
    }

    private func load() {
        // nawiasy konieczne: „try? A ?? B” obejmuje całe wyrażenie, więc B nigdy by się nie wykonało
        guard let text = (try? String(contentsOf: fileURL, encoding: .utf8))
                ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1)) else {
            status = L("Brak bazy krajów - kliknij „Aktualizuj bazę krajów”.")
            return
        }
        let parsed = CTYTable(text: text)
        table = parsed.entityCount > 0 ? parsed : nil
        if let date = fileDate {
            status = L("Baza krajów: {1} krajów, z {2}", parsed.entityCount, date.formatted(date: .abbreviated, time: .omitted))
        }
    }

    /// Pobiera aktualny cty.dat (zalecane przed dużymi zawodami - plik jest aktualizowany co kilka dni).
    func update() {
        guard !updating else { return }
        updating = true
        status = L("Pobieranie bazy krajów…")
        Task {
            defer { updating = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.sourceURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                      CTYTable(text: text).entityCount > 300 else {
                    status = L("Pobrany plik nie wygląda na bazę krajów - spróbuj później.")
                    return
                }
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                load()
            } catch {
                status = L("Nie udało się pobrać bazy krajów: {1}", error.localizedDescription)
            }
        }
    }
}


/// Stacja pracująca spoza swojego kraju: P4/WE9V (Aruba), FM/VE3DZ (Martynika), DL/SP5XTF (Niemcy).
/// Wtedy dane z QRZ (kraj, numer DXCC, strefy, QTH, lokator) opisują dom stacji, a nie miejsce pracy -
/// o kraju decyduje prefiks (cty.dat), tak jak w Club Log i LoTW.
@MainActor
enum OperatingLocation {
    /// Kraj pełnego znaku różni się od kraju znaku macierzystego. /P, /M, /QRP czy zmiana okręgu (W1AW/4)
    /// to ten sam kraj. Bez bazy krajów - ostrożnie: każdy dodatkowy człon poza przyrostkami i cyfrą okręgu.
    static func isAwayFromHome(_ call: String) -> Bool {
        let c = call.uppercased().trimmingCharacters(in: .whitespaces)
        guard c.contains("/") else { return false }
        if let table = CTYDatabase.shared.table,
           let full = table.lookup(c), let home = table.lookup(QRZClient.baseCall(c)) {
            return CTYTable.dxccKey(full) != CTYTable.dxccKey(home)
        }
        let parts = c.split(separator: "/").map(String.init)
        let extra = parts.filter { part in
            part != QRZClient.baseCall(c) && !CTYTable.ignoredSuffixes.contains(part) && !(part.count == 1 && part.first!.isNumber)
        }
        return !extra.isEmpty
    }

    /// Pola ADIF z cty.dat dla miejsca pracy: kraj (nazwa jednostki DXCC), strefy CQ i ITU, kontynent.
    /// Numeru DXCC cty.dat nie podaje - uzupełni go potwierdzenie z LoTW.
    static func ctyFields(_ call: String) -> [String: String] {
        guard let table = CTYDatabase.shared.table, let match = table.lookup(call) else { return [:] }
        return ["COUNTRY": table.dxccName(CTYTable.dxccKey(match)) ?? match.entity.name,
                "CQZ": String(match.cqZone), "ITUZ": String(match.ituZone), "CONT": match.continent]
    }
}
