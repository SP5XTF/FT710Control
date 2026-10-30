import Foundation
import CoreLocation

// MARK: - Modele

struct SolarData {
    var updated = ""
    var values: [String: String] = [:]                  // pola XML HamQSL (solarflux, kindex, xray…)
    var hf: [(band: String, day: String, night: String)] = []
    var vhf: [(name: String, location: String, status: String)] = []

    func number(_ key: String) -> Double? {
        values[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
    }
}

struct KpPoint: Identifiable {
    let time: Date
    let kp: Double
    var id: Date { time }
}

/// Raport PSKReporter: kto odebrał Twoją stację.
struct ReceptionReport: Identifiable {
    let id = UUID()
    let sender: String
    let receiver: String
    let locator: String
    let frequencyHz: Int
    let mode: String
    let snr: Int?
    let time: Date
    var band: String { LogFrequency.band(for: frequencyHz) ?? "?" }
    var coordinate: CLLocationCoordinate2D? { Geo.coordinate(fromGrid: locator) }
}

// MARK: - Usługa

/// Dane o propagacji: HamQSL (N0NBH) - dane słoneczne i warunki KF/VHF; NOAA SWPC - indeks Kp;
/// PSKReporter - kto słyszy Twoją stację. Odświeżanie z umiarem (HamQSL co godzinę, Kp co 30 min,
/// PSKReporter najwyżej co 5 min - zgodnie z prośbą serwisu).
@MainActor
final class PropagationService: ObservableObject {
    /// Jedna usługa dla zakładki PROPAGACJA i okna mapy - dane pobierane raz.
    static let shared = PropagationService()
    private var users = 0                                         // ile widoków korzysta z odświeżania
    @Published private(set) var solar: SolarData?
    @Published private(set) var kp: [KpPoint] = []
    @Published private(set) var reports: [ReceptionReport] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var lastSolar: Date?
    @Published private(set) var lastReports: Date?
    /// Zakres raportów PSK Reporter: kwadrat lokatora (np. KO02), pole (KO) albo własny znak.
    @Published var scope: ReportScope = ReportScope(rawValue: UserDefaults.standard.string(forKey: "prop.scope") ?? "") ?? .square {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "prop.scope") }
    }
    @Published private(set) var reportsKey = ""                  // dla jakiego zakresu są bieżące raporty

    enum ReportScope: String, CaseIterable, Identifiable {
        case square, field, callsign
        var id: String { rawValue }
        var name: String {
            switch self {
            case .square: return L("Mój kwadrat")
            case .field: return L("Moje pole")
            case .callsign: return L("Mój znak")
            }
        }
        /// Wartość zapytania i czy to lokator (modify=grid).
        func query(call: String, grid: String) -> (value: String, isGrid: Bool)? {
            let g = grid.uppercased().filter { $0.isLetter || $0.isNumber }
            switch self {
            case .square: return g.count >= 4 ? (String(g.prefix(4)), true) : nil
            case .field: return g.count >= 2 ? (String(g.prefix(2)), true) : nil
            case .callsign:
                let c = call.trimmingCharacters(in: .whitespaces).uppercased()
                return c.isEmpty ? nil : (c, false)
            }
        }
    }

    static let hamqslURL = URL(string: "https://www.hamqsl.com/solarxml.php")!
    static let kpURL = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!
    // adresy z oficjalnych stron produktów NOAA SWPC (D-RAP, Aurora - 30 Minute Forecast)
    static let drapURL = URL(string: "https://services.swpc.noaa.gov/images/animations/d-rap/global/latest.png")!
    static let auroraURL = URL(string: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg")!

    private var lastKp: Date?
    private var timer: Timer?

    /// Odświeża to, co jest „nieświeże”. `force` - wszystko (przycisk), z zachowaniem limitu PSKReporter
    /// (nie częściej niż co 5 min - także przy zmianie zakresu).
    func refresh(callsign: String, grid: String, force: Bool = false) {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            var problems: [String] = []
            if force || lastSolar.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                do { solar = try await Self.fetchSolar(); lastSolar = Date() }
                catch { problems.append("HamQSL: \(error.localizedDescription)") }
            }
            if force || lastKp.map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
                do { kp = try await Self.fetchKp(); lastKp = Date() }
                catch { problems.append("NOAA Kp: \(error.localizedDescription)") }
            }
            if let query = scope.query(call: callsign, grid: grid) {
                let key = "\(scope.rawValue):\(query.value)"
                let age = lastReports.map { Date().timeIntervalSince($0) } ?? .infinity
                let due = key != reportsKey ? age > 300 : age > (force ? 300 : 600)
                if due {
                    do {
                        reports = try await Self.fetchReports(value: query.value, isGrid: query.isGrid)
                        lastReports = Date()
                        reportsKey = key
                    } catch { problems.append("PSKReporter: \(error.localizedDescription)") }
                } else if key != reportsKey {
                    problems.append(L("PSK Reporter: nowy zakres za {1} min (limit serwisu: raz na 5 min)", Int((300 - age) / 60) + 1))
                }
            }
            status = problems.isEmpty ? L("Dane aktualne") : problems.joined(separator: " · ")
            loading = false
        }
    }

    /// Automatyczne odświeżanie (co minutę sprawdza, co jest do pobrania) - tylko gdy zakładka jest otwarta.
    func startAutoRefresh(station: @escaping () -> (call: String, grid: String)) {
        users += 1
        let s = station()
        refresh(callsign: s.call, grid: s.grid)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let s = station()
                self?.refresh(callsign: s.call, grid: s.grid)
            }
        }
    }

    /// Odświeżanie zatrzymuje się dopiero, gdy zamknięte są i zakładka, i okno mapy.
    func stopAutoRefresh() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: Wspólne obliczenia dla zakładki i okna mapy

    static let bandOrder = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "4m", "2m", "70cm"]

    /// Liczba odbiorów i największa odległość od Twojego lokatora na każdym paśmie.
    static func bandStats(_ reports: [ReceptionReport], myGrid: String) -> [(band: String, count: Int, maxKm: Int)] {
        guard let home = Geo.coordinate(fromGrid: myGrid) else { return [] }
        var stats: [String: (Int, Double)] = [:]
        for report in reports {
            guard let c = report.coordinate else { continue }
            let current = stats[report.band] ?? (0, 0)
            stats[report.band] = (current.0 + 1, max(current.1, Geo.distanceKm(home, c)))
        }
        return bandOrder.compactMap { band in stats[band].map { (band, $0.0, Int($0.1.rounded())) } }
    }

    // MARK: Pobieranie

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("FT710Control (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "HTTP", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: L("błąd HTTP {1}", http.statusCode)])
        }
        return data
    }

    static func fetchSolar() async throws -> SolarData {
        try parseSolar(try await get(hamqslURL))
    }

    static func fetchKp() async throws -> [KpPoint] {
        parseKp(try await get(kpURL))
    }

    /// Raporty odbioru: dla znaku albo - z modify=grid - dla wszystkich stacji nadających z kwadratu/pola lokatora.
    static func fetchReports(value: String, isGrid: Bool) async throws -> [ReceptionReport] {
        var components = URLComponents(string: "https://retrieve.pskreporter.info/query")!
        components.queryItems = [
            URLQueryItem(name: "senderCallsign", value: value),
            URLQueryItem(name: "rptlimit", value: "500"),
            URLQueryItem(name: "flowStartSeconds", value: "-3600"),        // ostatnia godzina
            URLQueryItem(name: "rronly", value: "1"),                      // tylko raporty odbioru
            URLQueryItem(name: "appcontact", value: "FT710Control-macOS")
        ] + (isGrid ? [URLQueryItem(name: "modify", value: "grid")] : [])
        return parseReports(try await get(components.url!))
    }

    // MARK: Odczyt danych (statyczne - łatwe do sprawdzenia)

    /// HamQSL solarxml.php: <solardata><solarflux>…</solarflux>…<calculatedconditions><band name= time=>…
    static func parseSolar(_ data: Data) throws -> SolarData {
        let parser = SimpleXML()
        guard parser.parse(data) else {
            throw NSError(domain: "XML", code: 1, userInfo: [NSLocalizedDescriptionKey: L("nieczytelne dane")])
        }
        var solar = SolarData()
        for element in parser.elements {
            switch element.name {
            case "band":
                let band = element.attributes["name"] ?? "", time = element.attributes["time"] ?? ""
                if let index = solar.hf.firstIndex(where: { $0.band == band }) {
                    if time == "day" { solar.hf[index].day = element.text } else { solar.hf[index].night = element.text }
                } else {
                    solar.hf.append((band, time == "day" ? element.text : "", time == "night" ? element.text : ""))
                }
            case "phenomenon":
                solar.vhf.append((element.attributes["name"] ?? "", element.attributes["location"] ?? "", element.text))
            default:
                if !element.text.isEmpty, element.attributes.isEmpty { solar.values[element.name] = element.text }
            }
        }
        // HamQSL ma literówkę w nazwie pola strumienia elektronów
        if solar.values["electronflux"] == nil, let value = solar.values["electonflux"] { solar.values["electronflux"] = value }
        solar.updated = solar.values["updated"] ?? ""
        return solar
    }

    /// NOAA: tablica wierszy [czas, Kp, …] z nagłówkiem albo tablica obiektów {time_tag, Kp} - obsługa obu.
    static func parseKp(_ data: Data) -> [KpPoint] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let formats = ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]
        func date(_ text: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            for format in formats { f.dateFormat = format; if let d = f.date(from: text) { return d } }
            return nil
        }
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        var points: [KpPoint] = []
        for row in json {
            if let array = row as? [Any], array.count >= 2, let t = array[0] as? String, let d = date(t), let k = number(array[1]) {
                points.append(KpPoint(time: d, kp: k))
            } else if let object = row as? [String: Any], let t = object["time_tag"] as? String, let d = date(t),
                      let k = number(object["Kp"] ?? object["kp_index"] ?? object["estimated_kp"]) {
                points.append(KpPoint(time: d, kp: k))
            }
        }
        return points.sorted { $0.time < $1.time }.suffix(56).map { $0 }     // ~7 dni (co 3 h)
    }

    /// PSKReporter: <receptionReport receiverCallsign= receiverLocator= frequency= mode= sNR= flowStartSeconds= />
    static func parseReports(_ data: Data) -> [ReceptionReport] {
        let parser = SimpleXML()
        guard parser.parse(data) else { return [] }
        return parser.elements.filter { $0.name == "receptionReport" }.compactMap { e in
            guard let receiver = e.attributes["receiverCallsign"], let locator = e.attributes["receiverLocator"],
                  locator.count >= 4, let freq = e.attributes["frequency"].flatMap(Int.init) else { return nil }
            let time = e.attributes["flowStartSeconds"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
            return ReceptionReport(sender: e.attributes["senderCallsign"] ?? "", receiver: receiver, locator: locator, frequencyHz: freq,
                                   mode: e.attributes["mode"] ?? "", snr: e.attributes["sNR"].flatMap(Int.init), time: time)
        }
    }
}

// MARK: - Prosty czytnik XML (płaska lista elementów: nazwa, atrybuty, tekst)

final class SimpleXML: NSObject, XMLParserDelegate {
    struct Element { let name: String; let attributes: [String: String]; var text: String }
    private(set) var elements: [Element] = []
    private var stack: [Element] = []

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        stack.append(Element(name: name, attributes: attributes, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard var element = stack.popLast() else { return }
        element.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        elements.append(element)
    }
}

// MARK: - Linia szarości (dzień / noc)

enum Greyline {
    /// Punkt podsłoneczny: deklinacja i długość geograficzna (°). Przybliżenie NOAA/USNO - dokładność ~0,01°.
    static func subsolarPoint(at date: Date = Date()) -> (declination: Double, longitude: Double) {
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let g = fmod(357.529 + 0.98560028 * d, 360) * .pi / 180
        let q = fmod(280.459 + 0.98564736 * d, 360)
        let l = fmod(q + 1.915 * sin(g) + 0.020 * sin(2 * g), 360) * .pi / 180
        let e = (23.439 - 0.00000036 * d) * .pi / 180
        var ra = atan2(cos(e) * sin(l), cos(l)) * 180 / .pi
        if ra < 0 { ra += 360 }
        let declination = asin(sin(e) * sin(l)) * 180 / .pi
        let equationOfTime = fmod(q - ra + 540, 360) - 180                // stopnie
        let utc = Calendar(identifier: .gregorian)
        var cal = utc
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        var longitude = -15 * (hours - 12) - equationOfTime
        longitude = fmod(longitude + 540, 360) - 180
        return (declination, longitude)
    }

    enum SunDay {
        case normal(sunrise: Date, sunset: Date)
        case polarDay
        case polarNight
    }

    /// Wschód i zachód Słońca (UTC) w danym miejscu. Wysokość −0,833° (refrakcja + promień tarczy).
    /// Zgodność z biblioteką astral ±1 min (sprawdzone dla Warszawy, Londynu, Sydney, Reykjavíku).
    static func sunTimes(latitude: Double, longitude: Double, on date: Date = Date()) -> SunDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: date)
        let sun = subsolarPoint(at: midnight.addingTimeInterval(12 * 3600))
        let noon = 12 + (sun.longitude - longitude) / 15                   // godziny UTC
        let rad = Double.pi / 180
        let x = (sin(-0.833 * rad) - sin(latitude * rad) * sin(sun.declination * rad))
            / (cos(latitude * rad) * cos(sun.declination * rad))
        if x <= -1 { return .polarDay }
        if x >= 1 { return .polarNight }
        let half = acos(x) / rad / 15
        return .normal(sunrise: midnight.addingTimeInterval((noon - half) * 3600),
                       sunset: midnight.addingTimeInterval((noon + half) * 3600))
    }

    /// Wielokąt strefy nocnej (szerokość, długość) od −180° do +180°, domknięty przy biegunie po stronie nocy.
    static func nightPolygon(at date: Date = Date()) -> [CLLocationCoordinate2D] {
        let sun = subsolarPoint(at: date)
        let dec = abs(sun.declination) < 0.01 ? 0.01 : sun.declination
        var points: [CLLocationCoordinate2D] = []
        for step in 0...180 {
            let lon = -180.0 + Double(step) * 2
            let lat = atan(-cos((lon - sun.longitude) * .pi / 180) / tan(dec * .pi / 180)) * 180 / .pi
            points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        let pole = dec > 0 ? -89.9 : 89.9                                  // noc przy biegunie w cieniu
        points.append(CLLocationCoordinate2D(latitude: pole, longitude: 180))
        points.append(CLLocationCoordinate2D(latitude: pole, longitude: -180))
        return points
    }
}
