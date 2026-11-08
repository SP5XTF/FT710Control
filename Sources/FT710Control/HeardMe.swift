import SwiftUI
import MapKit
import Combine

/// Raport odbioru z PSKReporter: kto i gdzie odebrał Twój sygnał.
struct HeardReport: Identifiable, Equatable {
    var id: String { receiver + "|" + band }
    let receiver: String
    let grid: String
    let hz: Int
    let mode: String
    let snr: Int?
    let time: Date
    var band: String { LogFrequency.band(for: hz) ?? "?" }
    var coordinate: CLLocationCoordinate2D? { Geo.coordinate(fromGrid: grid) }

    static func == (a: HeardReport, b: HeardReport) -> Bool {
        a.receiver == b.receiver && a.hz == b.hz && a.time == b.time && a.snr == b.snr
    }
}

/// Położenie Słońca i terminator (linia dnia i nocy) - wzory astronomiczne (deklinacja, równanie czasu).
enum SolarTerminator {
    /// Punkt podsłoneczny (szerokość = deklinacja Słońca, długość z czasu UTC i równania czasu), stopnie.
    static func subsolarPoint(at date: Date) -> (latitude: Double, longitude: Double) {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0     // dni od J2000
        let meanLongitude = (280.460 + 0.985_647_4 * n).truncatingRemainder(dividingBy: 360)
        let anomaly = (357.528 + 0.985_600_3 * n) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.000_000_4 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclipticLongitude)) / rad
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude)) / rad
        var equationDeg = meanLongitude - rightAscension                       // równanie czasu w stopniach
        equationDeg = (equationDeg + 540).truncatingRemainder(dividingBy: 360) - 180
        let seconds = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let utcHours = seconds / 3600
        var longitude = -15 * (utcHours - 12) - equationDeg
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return (declination, longitude)
    }

    /// Terminator: szerokość, na której Słońce jest na horyzoncie, dla długości co `step` stopni.
    static func terminator(at date: Date, step: Double = 2) -> [CLLocationCoordinate2D] {
        let sun = subsolarPoint(at: date)
        let rad = Double.pi / 180
        let declination = abs(sun.latitude) < 0.01 ? 0.01 : sun.latitude
        return stride(from: -180.0, through: 180.0, by: step).map { lon in
            let lat = atan(-cos((lon - sun.longitude) * rad) / tan(declination * rad)) / rad
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    /// Strona nocna: od terminatora do bieguna w ciemności (południowy, gdy Słońce nad półkulą północną).
    static func nightPolygon(at date: Date) -> [CLLocationCoordinate2D] {
        let line = terminator(at: date)
        let pole = subsolarPoint(at: date).latitude >= 0 ? -85.0 : 85.0
        return line + [CLLocationCoordinate2D(latitude: pole, longitude: 180),
                       CLLocationCoordinate2D(latitude: pole, longitude: -180)]
    }

    /// Czy w danym miejscu jest noc (Słońce pod horyzontem).
    static func isNight(_ coordinate: CLLocationCoordinate2D, at date: Date) -> Bool {
        let sun = subsolarPoint(at: date)
        let rad = Double.pi / 180
        let elevation = sin(coordinate.latitude * rad) * sin(sun.latitude * rad)
            + cos(coordinate.latitude * rad) * cos(sun.latitude * rad) * cos((coordinate.longitude - sun.longitude) * rad)
        return elevation < 0
    }
}

/// Odbiór raportów z PSKReporter (XML: elementy receptionReport) - odpytywanie najwyżej co 5 minut.
@MainActor
final class HeardMeService: ObservableObject {
    static let shared = HeardMeService()
    static let minimumInterval: TimeInterval = 300
    static let windows: [(seconds: Int, name: String)] = [(900, "15 min"), (3600, "1 h"), (21_600, "6 h"), (86_400, "24 h")]

    @Published var windowSeconds: Int { didSet { UserDefaults.standard.set(windowSeconds, forKey: "heard.window") } }
    @Published var bandFilter = ""
    @Published var autoRefresh: Bool { didSet { UserDefaults.standard.set(autoRefresh, forKey: "heard.auto") } }
    @Published private(set) var reports: [HeardReport] = []
    @Published private(set) var status = ""
    @Published private(set) var lastFetch: Date?
    @Published private(set) var loading = false
    private var autoTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "heard.window")
        windowSeconds = Self.windows.contains { $0.seconds == saved } ? saved : 3600
        autoRefresh = UserDefaults.standard.object(forKey: "heard.auto") as? Bool ?? true
    }

    var myCall: String { AppServices.shared.logbook.myCall.uppercased() }
    var myGrid: String { AppServices.shared.logbook.myGrid }

    /// Okres i pasmo filtrowane lokalnie (pobierane jest zawsze ostatnie 24 h) - przełączanie bez nowych zapytań.
    var filtered: [HeardReport] {
        let cutoff = Date().addingTimeInterval(-Double(windowSeconds))
        return reports.filter { $0.time >= cutoff && (bandFilter.isEmpty || $0.band == bandFilter) }
    }

    func distanceKm(_ report: HeardReport) -> Int? {
        guard let home = Geo.coordinate(fromGrid: myGrid), let there = report.coordinate else { return nil }
        return Int(Geo.distanceKm(home, there).rounded())
    }

    /// Okno otwarte: pierwsze pobranie i (opcja) odświeżanie co 5 minut.
    func start() {
        refresh()
        guard autoTask == nil else { return }
        autoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.minimumInterval * 1_000_000_000))
                guard let self else { return }
                if self.autoRefresh { self.refresh() }
            }
        }
    }

    func stop() { autoTask?.cancel(); autoTask = nil }

    func refresh() {
        guard !loading else { return }
        let call = myCall
        guard QRZClient.baseCall(call).count >= 3 else { status = L("Wpisz swój znak w Profilu stacji."); return }
        if let last = lastFetch, Date().timeIntervalSince(last) < Self.minimumInterval {
            let wait = Int(Self.minimumInterval - Date().timeIntervalSince(last))
            status = L("PSKReporter prosi o odpytywanie najwyżej co 5 minut - następne za {1} s.", wait)
            return
        }
        var components = URLComponents(string: "https://retrieve.pskreporter.info/query")!
        components.queryItems = [URLQueryItem(name: "senderCallsign", value: call),
                                 URLQueryItem(name: "flowStartSeconds", value: "-86400"),
                                 URLQueryItem(name: "rronly", value: "1"),
                                 URLQueryItem(name: "noactive", value: "1"),
                                 URLQueryItem(name: "appcontact", value: "FT710Control")]
        guard let url = components.url else { return }
        loading = true
        status = L("Pobieranie z PSKReporter…")
        Task { @MainActor in
            defer { loading = false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("FT710Control/" + ADIF.programVersion, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = L("PSKReporter nie odpowiada - spróbuj później.")
                lastFetch = Date()
                return
            }
            lastFetch = Date()
            reports = Self.latestPerReceiver(Self.parse(data))
            status = reports.isEmpty
                ? L("Brak raportów - nadawaj FT8/FT4/PSK/JS8 z włączonym raportowaniem do PSKReporter.")
                : L("{1} odbiorców · pobrano {2}", reports.count, DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))
        }
    }

    /// Najnowszy raport dla każdej pary odbiorca + pasmo.
    static func latestPerReceiver(_ reports: [HeardReport]) -> [HeardReport] {
        var best: [String: HeardReport] = [:]
        for report in reports where report.time > (best[report.id]?.time ?? .distantPast) { best[report.id] = report }
        return best.values.sorted { $0.time > $1.time }
    }

    /// XML PSKReporter: <receptionReport receiverCallsign=… receiverLocator=… frequency=… flowStartSeconds=… mode=… sNR=…/>
    static func parse(_ data: Data) -> [HeardReport] {
        let delegate = ReportParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.reports
    }

    private final class ReportParser: NSObject, XMLParserDelegate {
        var reports: [HeardReport] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard elementName == "receptionReport", let receiver = attributes["receiverCallsign"],
                  let grid = attributes["receiverLocator"], let freq = attributes["frequency"].flatMap(Int.init),
                  let seconds = attributes["flowStartSeconds"].flatMap(Double.init) else { return }
            reports.append(HeardReport(receiver: receiver.uppercased(), grid: grid, hz: freq,
                                       mode: attributes["mode"] ?? "", snr: attributes["sNR"].flatMap(Int.init),
                                       time: Date(timeIntervalSince1970: seconds)))
        }
    }
}

// MARK: - Mapa

/// Mapa płaska: odbiorcy (kolor pasma), Twoja stacja, linie po kole wielkim, noc i terminator.
struct HeardMeMap: NSViewRepresentable {
    let reports: [HeardReport]
    let home: CLLocationCoordinate2D?
    let now: Date

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        map.delegate = context.coordinator
        map.showsCompass = false
        map.setRegion(MKCoordinateRegion(center: home ?? CLLocationCoordinate2D(latitude: 30, longitude: 10),
                                         span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 330)), animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        // noc i terminator - co minutę
        let minute = Int(now.timeIntervalSince1970 / 60)
        if minute != c.drawnMinute {
            c.drawnMinute = minute
            map.removeOverlays(map.overlays.filter { $0 is NightPolygon || $0 is TerminatorLine })
            let night = SolarTerminator.nightPolygon(at: now)
            map.addOverlay(NightPolygon(coordinates: night, count: night.count), level: .aboveRoads)
            let line = SolarTerminator.terminator(at: now)
            map.addOverlay(TerminatorLine(coordinates: line, count: line.count), level: .aboveRoads)
        }
        // odbiorcy - tylko po zmianie listy
        let signature = reports.map { $0.id + "\($0.time.timeIntervalSince1970)" }.joined(separator: ",") + "\(home?.latitude ?? 0)"
        guard signature != c.drawnSignature else { return }
        c.drawnSignature = signature
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays.filter { $0 is PathLine })
        if let home {
            let annotation = ReceiverAnnotation(coordinate: home, color: .white, title: L("Twoja stacja"), subtitle: nil)
            annotation.isHome = true
            map.addAnnotation(annotation)
        }
        for report in reports.prefix(500) {
            guard let coordinate = report.coordinate else { continue }
            let color = NSColor(PropagationView.bandColor(report.band))
            let snr = report.snr.map { " \($0 > 0 ? "+" : "")\($0) dB" } ?? ""
            map.addAnnotation(ReceiverAnnotation(coordinate: coordinate, color: color, title: report.receiver,
                                                 subtitle: "\(report.band) \(report.mode)\(snr)"))
            if let home, reports.count <= 300 {
                let path = PathLine(coordinates: [home, coordinate], count: 2)
                path.color = color
                map.addOverlay(path, level: .aboveRoads)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class NightPolygon: MKPolygon {}
    final class TerminatorLine: MKPolyline {}
    final class PathLine: MKGeodesicPolyline { var color: NSColor = .white }

    final class ReceiverAnnotation: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let color: NSColor
        let title: String?
        let subtitle: String?
        var isHome = false
        init(coordinate: CLLocationCoordinate2D, color: NSColor, title: String?, subtitle: String?) {
            self.coordinate = coordinate; self.color = color; self.title = title; self.subtitle = subtitle
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var drawnMinute = -1
        var drawnSignature = ""

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let night = overlay as? NightPolygon {
                let renderer = MKPolygonRenderer(polygon: night)
                renderer.fillColor = NSColor.black.withAlphaComponent(0.38)
                return renderer
            }
            if let line = overlay as? TerminatorLine {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                return renderer
            }
            if let path = overlay as? PathLine {
                let renderer = MKPolylineRenderer(polyline: path)
                renderer.strokeColor = path.color.withAlphaComponent(0.45)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let receiver = annotation as? ReceiverAnnotation else { return nil }
            let view = MKAnnotationView(annotation: receiver, reuseIdentifier: nil)
            let size: CGFloat = receiver.isHome ? 14 : 9
            view.image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                (receiver.isHome ? NSColor.systemRed : receiver.color).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSColor.black.withAlphaComponent(0.6).setStroke()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                return true
            }
            view.canShowCallout = true
            return view
        }
    }
}

/// Okno „Kto mnie słyszy” (menu Okno): mapa odbiorców z PSKReporter, noc i linia dnia i nocy.
struct HeardMeView: View {
    @ObservedObject var service = HeardMeService.shared
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var bands: [String] {
        let present = Set(service.reports.map(\.band))
        return SWRSweep.bands.map(\.name).filter { present.contains($0) } + (present.contains("2m") ? ["2m"] : [])
    }

    var body: some View {
        HStack(spacing: 0) {
            HeardMeMap(reports: service.filtered, home: Geo.coordinate(fromGrid: service.myGrid), now: now)
            Divider()
            sidePanel.frame(width: 290).padding(12)
        }
        .frame(minWidth: 960, minHeight: 560)
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .onReceive(clock) { now = $0 }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Kto mnie słyszy")).font(.title3.bold())
            Text(service.myCall.isEmpty ? "–" : service.myCall).font(.headline.monospaced())
            Picker(L("Okres"), selection: $service.windowSeconds) {
                ForEach(HeardMeService.windows, id: \.seconds) { Text($0.name).tag($0.seconds) }
            }
            .pickerStyle(.segmented)
            Picker(L("Pasmo"), selection: $service.bandFilter) {
                Text(L("Wszystkie")).tag("")
                ForEach(bands, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button(L("Odśwież")) { service.refresh() }.disabled(service.loading)
                Toggle(L("co 5 min"), isOn: $service.autoRefresh)
                if service.loading { ProgressView().controlSize(.small) }
            }
            Text(Lr(service.status)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            summary
            Divider()
            receiverList
            Text(L("Dane: PSKReporter.info (raporty z ostatnich {1}). Ciemna strona - noc; pomarańczowa linia - terminator (linia dnia i nocy).",
                   HeardMeService.windows.first { $0.seconds == service.windowSeconds }?.name ?? ""))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        let list = service.filtered
        let farthest = list.compactMap { r in service.distanceKm(r).map { (r, $0) } }.max { $0.1 < $1.1 }
        let perBand = Dictionary(grouping: list, by: \.band).mapValues(\.count).sorted { $0.key < $1.key }
        let night = list.filter { r in r.coordinate.map { SolarTerminator.isNight($0, at: now) } ?? false }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Odbiorców: {1}", list.count)).font(.callout.bold())
            if let farthest {
                Text(L("Najdalej: {1} – {2} km", farthest.0.receiver, farthest.1)).font(.callout)
            }
            if !list.isEmpty {
                Text(L("Po nocnej stronie: {1}", night)).font(.caption).foregroundStyle(.secondary)
            }
            if !perBand.isEmpty {
                HStack(spacing: 6) {
                    ForEach(perBand, id: \.key) { band, count in
                        Text("\(band) \(count)").font(.caption.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(PropagationView.bandColor(band).opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
    }

    private var receiverList: some View {
        let sorted = service.filtered.sorted { (service.distanceKm($0) ?? 0) > (service.distanceKm($1) ?? 0) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sorted) { report in
                    HStack(spacing: 6) {
                        Text(report.receiver).bold().frame(width: 78, alignment: .leading)
                        Text(report.band).frame(width: 38, alignment: .leading).foregroundStyle(PropagationView.bandColor(report.band))
                        Text(report.snr.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "").frame(width: 30, alignment: .trailing)
                        Text(service.distanceKm(report).map { "\($0) km" } ?? "").frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .help(L("{1} · {2} · {3} UTC", report.grid, report.mode, Self.time.string(from: report.time)))
                }
            }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()
}
