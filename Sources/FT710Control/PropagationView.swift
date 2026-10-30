import SwiftUI
import Charts
import MapKit

/// Zakładka PROPAGACJA: Słońce i geomagnetyka, Kp, warunki KF i VHF/UKF, aktywność pasm z DX Cluster,
/// mapa (linia szarości + kto Cię słyszy z PSKReporter), mapy NOAA.
struct PropagationView: View {
    @ObservedObject var service: PropagationService
    @ObservedObject var cluster: DXClusterClient
    let myCall: String
    let myGrid: String
    /// Mapa NOAA otwarta w podglądzie z przybliżaniem.
    @State private var zoomedImage: NOAAImage?

    private static let bandOrder = PropagationService.bandOrder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                qthPanel
                HStack(alignment: .top, spacing: 14) {
                    solarPanel
                    kpPanel.frame(width: 340)
                }
                HStack(alignment: .top, spacing: 14) {
                    hfPanel.frame(width: 300)
                    vhfPanel
                    activityPanel.frame(width: 300)
                }
                HStack(alignment: .top, spacing: 14) {
                    openBandsPanel.frame(width: 340)       // mapa jest w miejscu skopu (środkowa kolumna)
                    noaaPanel
                }
                Text(L("Dane: N0NBH (hamqsl.com) · NOAA SWPC · PSK Reporter (pskreporter.info, Philip Gladstone N1DQ) · DX Cluster"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear { service.startAutoRefresh { (myCall, myGrid) } }
        .onChange(of: service.scope) { _ in service.refresh(callsign: myCall, grid: myGrid) }
        .onDisappear { service.stopAutoRefresh() }
        .sheet(item: $zoomedImage) { item in ZoomableRemoteImageView(url: item.url, title: item.title) }
    }

    // MARK: - Nagłówek

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("PROPAGACJA")).font(.headline).foregroundStyle(Theme.header)
            Button(L("Odśwież")) { service.refresh(callsign: myCall, grid: myGrid, force: true) }
                .disabled(service.loading)
            if service.loading { ProgressView().controlSize(.small) }
            Text(Lr(service.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let updated = service.solar?.updated, !updated.isEmpty {
                Text(L("Dane słoneczne: {1}", updated)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Twoje QTH (lokator z profilu stacji)

    private static func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private var qthPanel: some View {
        RigPanel(title: L("TWOJE QTH")) {
            if let home = Geo.coordinate(fromGrid: myGrid) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 18) {
                        Text(myGrid.uppercased()).font(.title3.monospaced().bold()).foregroundStyle(Theme.accent)
                        switch Greyline.sunTimes(latitude: home.latitude, longitude: home.longitude, on: context.date) {
                        case .normal(let sunrise, let sunset):
                            Label(L("wschód {1} UTC", Self.utc(sunrise)), systemImage: "sunrise.fill")
                            Label(L("zachód {1} UTC", Self.utc(sunset)), systemImage: "sunset.fill")
                            let now = context.date
                            let near = [sunrise, sunset].contains { abs($0.timeIntervalSince(now)) < 1800 }
                            if near {
                                Text(L("Jesteś teraz na linii szarości – dobry czas na DX na 160–40 m"))
                                    .bold().foregroundStyle(.orange)
                            } else {
                                Text(now > sunrise && now < sunset ? L("dzień u Ciebie") : L("noc u Ciebie"))
                                    .foregroundStyle(.secondary)
                            }
                        case .polarDay:
                            Text(L("dzień polarny"))
                        case .polarNight:
                            Text(L("noc polarna"))
                        }
                        Spacer()
                        Picker(L("Raporty PSK"), selection: $service.scope) {
                            ForEach(PropagationService.ReportScope.allCases) { scope in
                                Text(scopeLabel(scope)).tag(scope)
                            }
                        }
                        .frame(width: 260)
                        .help(L("Kwadrat / pole: gdzie słychać stacje nadające z Twojej okolicy (działa także, gdy sam nie nadajesz). Znak: gdzie słychać Ciebie."))
                    }
                    .font(.callout)
                }
            } else {
                Text(L("Ustaw lokator w Profilu stacji (menu FT710Control → Profil stacji…) - propagacja będzie liczona dla Twojego miejsca."))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func scopeLabel(_ scope: PropagationService.ReportScope) -> String {
        if let query = scope.query(call: myCall, grid: myGrid) { return "\(scope.name) (\(query.value))" }
        return scope.name
    }

    // MARK: - Słońce i geomagnetyka

    /// Ocena wartości: 0 dobrze, 1 uwaga, 2 źle, nil - bez oceny.
    private struct Indicator {
        let key: String
        let label: String
        let unit: String
        let help: String
        let rate: (String, Double?) -> Int?
    }

    private static var indicators: [Indicator] { [            // obliczane - etykiety w bieżącym języku
        Indicator(key: "solarflux", label: "SFI", unit: "", help: L("Strumień słoneczny 10,7 cm - im wyższy, tym lepsze wyższe pasma KF (powyżej 150 bardzo dobrze)")) { _, v in
            v.map { $0 >= 150 ? 0 : ($0 >= 100 ? 1 : 2) } },
        Indicator(key: "sunspots", label: L("Plamy"), unit: "", help: L("Liczba plam słonecznych - więcej plam to zwykle lepsza propagacja KF")) { _, v in
            v.map { $0 >= 100 ? 0 : ($0 >= 50 ? 1 : 2) } },
        Indicator(key: "aindex", label: "A", unit: "", help: L("Wskaźnik A - aktywność geomagnetyczna dobowa; niski = spokojnie (poniżej 8 dobrze)")) { _, v in
            v.map { $0 <= 7 ? 0 : ($0 <= 15 ? 1 : 2) } },
        Indicator(key: "kindex", label: "K", unit: "", help: L("Wskaźnik K - bieżące zaburzenia pola magnetycznego (0-2 spokojnie, 5+ burza)")) { _, v in
            v.map { $0 <= 2 ? 0 : ($0 <= 4 ? 1 : 2) } },
        Indicator(key: "xray", label: L("Rentgen"), unit: "", help: L("Rozbłyski rentgenowskie: A/B spokojnie, C umiarkowanie, M/X - możliwe zaniki KF po stronie dziennej")) { text, _ in
            switch text.first { case "A", "B": return 0; case "C": return 1; case "M", "X": return 2; default: return nil } },
        Indicator(key: "solarwind", label: L("Wiatr słon."), unit: "km/s", help: L("Prędkość wiatru słonecznego - powyżej ~500 km/s rośnie ryzyko zaburzeń")) { _, v in
            v.map { $0 < 400 ? 0 : ($0 < 600 ? 1 : 2) } },
        Indicator(key: "magneticfield", label: "Bz", unit: "nT", help: L("Składowa Bz pola międzyplanetarnego - ujemna (na południe) sprzyja burzom geomagnetycznym")) { _, v in
            v.map { $0 >= 0 ? 0 : ($0 > -5 ? 1 : 2) } },
        Indicator(key: "protonflux", label: L("Protony"), unit: "", help: L("Strumień protonów - wysoki pogarsza propagację przez okolice polarne")) { _, v in
            v.map { $0 < 10 ? 0 : ($0 < 100 ? 1 : 2) } },               // protony
        Indicator(key: "geomagfield", label: L("Pole geomagn."), unit: "", help: L("Stan pola geomagnetycznego (QUIET - spokojne, STORM - burza)")) { text, _ in
            let t = text.uppercased()
            if t.contains("QUIET") { return 0 }
            if t.contains("UNSETT") { return 1 }
            if t.contains("ACTIVE") || t.contains("STORM") { return 2 }
            return nil },
        Indicator(key: "signalnoise", label: L("Szum"), unit: "", help: L("Przewidywany poziom szumu w paśmie (S-metr)")) { _, _ in nil },
        Indicator(key: "muf", label: "MUF", unit: "MHz", help: L("Maksymalna użyteczna częstotliwość (stacja referencyjna)")) { _, _ in nil },
        Indicator(key: "fof2", label: "foF2", unit: "MHz", help: L("Częstotliwość krytyczna warstwy F2 - do pracy NVIS na bliskie odległości")) { _, _ in nil },
    ] }

    private static func color(_ level: Int?) -> Color {
        switch level { case 0: return Theme.ok; case 1: return .orange; case 2: return .red; default: return Theme.text }
    }

    private var solarPanel: some View {
        RigPanel(title: L("SŁOŃCE I GEOMAGNETYKA")) {
            if let solar = service.solar {
                ColumnGrid(Self.indicators, id: \.key, columns: 6, spacing: 8) { item in
                        let text = solar.values[item.key] ?? "–"
                        let level = item.rate(text, solar.number(item.key))
                        VStack(spacing: 2) {
                            Text(item.label).font(.caption2).foregroundStyle(.secondary)
                            Text(text).font(.system(.title3, design: .rounded).bold())
                                .foregroundStyle(Self.color(level))
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(item.unit).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .help(item.help)
                }
            } else {
                Text(service.loading ? L("Pobieranie…") : L("Brak danych - kliknij „Odśwież”."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Kp

    private var kpPanel: some View {
        RigPanel(title: L("INDEKS Kp (NOAA, ostatnie dni)")) {
            if service.kp.isEmpty {
                Text(L("Brak danych")).foregroundStyle(.secondary).frame(height: 120)
            } else {
                Chart(service.kp) { point in
                    // jednostka czasu = szerokość słupka (bez niej Swift Charts zgaduje i ostrzega w konsoli)
                    BarMark(x: .value("UTC", point.time, unit: .hour), y: .value("Kp", point.kp))
                        .foregroundStyle(point.kp >= 5 ? Color.red : (point.kp >= 4 ? Color.orange : Theme.ok))
                }
                .chartYScale(domain: 0...9)
                .frame(height: 130)
                if let last = service.kp.last {
                    Text(L("Ostatni Kp: {1} - {2}", String(format: "%.2f", last.kp),
                           last.kp >= 5 ? L("burza geomagnetyczna") : (last.kp >= 4 ? L("niespokojnie") : L("spokojnie"))))
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - KF i VHF

    private static func conditionColor(_ text: String) -> Color {
        switch text.lowercased() {
        case "good": return Theme.ok
        case "fair": return .orange
        case "poor": return .red
        default: return .secondary
        }
    }

    private static func conditionText(_ text: String) -> String {
        switch text.lowercased() {
        case "good": return L("Dobre")
        case "fair": return L("Średnie")
        case "poor": return L("Słabe")
        default: return text.isEmpty ? "–" : text
        }
    }

    private var hfPanel: some View {
        RigPanel(title: L("WARUNKI KF (prognoza)")) {
            if let solar = service.solar, !solar.hf.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text(L("Pasma")).font(.caption.bold())
                        Text(L("Dzień")).font(.caption.bold())
                        Text(L("Noc")).font(.caption.bold())
                    }
                    ForEach(solar.hf, id: \.band) { row in
                        GridRow {
                            Text(row.band).font(.callout.monospaced())
                            Text(Self.conditionText(row.day)).foregroundStyle(Self.conditionColor(row.day)).bold()
                            Text(Self.conditionText(row.night)).foregroundStyle(Self.conditionColor(row.night)).bold()
                        }
                    }
                }
            } else {
                Text(L("Brak danych")).foregroundStyle(.secondary)
            }
        }
    }

    private static func vhfName(_ name: String, _ location: String) -> String {
        switch (name.lowercased(), location.lowercased()) {
        case ("vhf-aurora", _): return L("Zorza (VHF)")
        case ("e-skip", "europe"): return L("Es Europa – 2 m")
        case ("e-skip", "europe_4m"): return L("Es Europa – 4 m")
        case ("e-skip", "europe_6m"): return L("Es Europa – 6 m")
        case ("e-skip", "north_america"): return L("Es Ameryka Płn.")
        default: return "\(name) \(location)"
        }
    }

    /// Spoty VHF/UKF z klastra z ostatniej godziny - rzeczywiste otwarcia.
    private var vhfSpots: [DXSpot] {
        let since = Date().addingTimeInterval(-3600)
        return cluster.spots.filter { $0.received > since && $0.frequencyHz >= 50_000_000 }
            .sorted { $0.received > $1.received }
    }

    private var vhfPanel: some View {
        RigPanel(title: L("WARUNKI VHF / UKF")) {
            VStack(alignment: .leading, spacing: 6) {
                if let solar = service.solar, !solar.vhf.isEmpty {
                    ForEach(Array(solar.vhf.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(Self.vhfName(item.name, item.location)).frame(width: 150, alignment: .leading)
                            Text(Lr(item.status))
                                .bold()
                                .foregroundStyle(item.status.lowercased().contains("closed") ? Color.secondary : Theme.ok)
                        }
                        .font(.callout)
                    }
                }
                Divider()
                Text(L("Spoty 6 m / 4 m / 2 m / 70 cm z DX Cluster (1 h): {1}", vhfSpots.count)).font(.caption.bold())
                if vhfSpots.isEmpty {
                    Text(L("Brak - przy otwarciu Es albo tropo pojawią się tutaj.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(vhfSpots.prefix(8)) { spot in
                        HStack(spacing: 8) {
                            Text(spot.timeUTC).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(LogFrequency.band(for: spot.frequencyHz) ?? "").font(.caption.bold()).frame(width: 40, alignment: .leading)
                            Text(spot.call).font(.caption.bold()).foregroundStyle(Theme.header)
                            Text(spot.comment).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Aktywność pasm (DX Cluster)

    private var activity: [(band: String, count: Int)] {
        let since = Date().addingTimeInterval(-1800)
        var counts: [String: Int] = [:]
        for spot in cluster.spots where spot.received > since {
            if let band = LogFrequency.band(for: spot.frequencyHz) { counts[band, default: 0] += 1 }
        }
        return Self.bandOrder.compactMap { band in counts[band].map { (band, $0) } }
    }

    private var activityPanel: some View {
        RigPanel(title: L("AKTYWNOŚĆ PASM (spoty, 30 min)")) {
            if activity.isEmpty {
                Text(cluster.state == .connected ? L("Brak spotów w ostatnich 30 minutach") : L("Połącz DX Cluster, żeby zobaczyć aktywność pasm"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(activity, id: \.band) { item in
                    BarMark(x: .value(L("Spoty"), item.count), y: .value(L("Pasmo"), item.band))
                        .foregroundStyle(Theme.accent)
                        .annotation(position: .trailing) { Text("\(item.count)").font(.caption2) }
                }
                .frame(height: max(80, CGFloat(activity.count) * 18))
            }
        }
    }

    // MARK: - Mapa

    /// Otwarte pasma z Twojego miejsca - ranking wg liczby odbiorów (i największej odległości).
    private var openBandsPanel: some View {
        RigPanel(title: L("OTWARTE PASMA Z TWOJEGO MIEJSCA – TERAZ")) {
            let stats = bandStats.sorted { $0.count > $1.count }
            if stats.isEmpty {
                Text(L("Brak raportów w ostatniej godzinie (PSK Reporter zbiera odbiory emisji cyfrowych, np. FT8)."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let top = max(stats.first?.count ?? 1, 1)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stats, id: \.band) { stat in
                        HStack(spacing: 8) {
                            Text(stat.band).font(.callout.monospaced().bold()).frame(width: 44, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Self.bandColor(stat.band))
                                    .frame(width: max(3, geo.size.width * CGFloat(stat.count) / CGFloat(top)))
                            }
                            .frame(height: 10)
                            Text(L("{1} odb. · do {2} km", stat.count, stat.maxKm))
                                .font(.caption.monospacedDigit())
                                .frame(width: 150, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var bandStats: [(band: String, count: Int, maxKm: Int)] {
        PropagationService.bandStats(service.reports, myGrid: myGrid)
    }

    static func bandColor(_ band: String) -> Color {
        let colors: [String: Color] = ["160m": .brown, "80m": .purple, "60m": .indigo, "40m": .blue, "30m": .cyan,
                                       "20m": .green, "17m": .mint, "15m": .yellow, "12m": .orange, "10m": .red,
                                       "6m": .pink, "4m": .teal, "2m": .white, "70cm": .gray]
        return colors[band] ?? .gray
    }

    // MARK: - Mapy NOAA

    private var noaaPanel: some View {
        RigPanel(title: L("MAPY NOAA (kliknij, żeby powiększyć)")) {
            VStack(alignment: .leading, spacing: 10) {
                noaaImage(PropagationService.drapURL, title: L("D-RAP – pochłanianie na KF (zaniki po rozbłyskach)"))
                noaaImage(PropagationService.auroraURL, title: L("Owal zorzy – półkula północna"))
            }
        }
    }

    private func noaaImage(_ url: URL, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: Text(L("Nie udało się pobrać obrazu")).font(.caption).foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
            .frame(width: 260, height: 150)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { zoomedImage = NOAAImage(url: url, title: title) }
            .help(L("Kliknij, żeby otworzyć mapę z przybliżaniem"))
        }
    }
}

/// Mapa NOAA do podglądu z przybliżaniem.
struct NOAAImage: Identifiable {
    let url: URL
    let title: String
    var id: String { url.absoluteString }
}

// MARK: - Mapa (MapKit): strefa nocy, Twoja stacja, odbiorcy z PSKReporter

struct PropagationMapView: NSViewRepresentable {
    let reports: [ReceptionReport]
    let home: CLLocationCoordinate2D?
    let night: [CLLocationCoordinate2D]
    var interactive = true
    /// Przyciski + / − / widok startowy (MapZoomButtons) - w oknie mapy.
    var zoom: MapZoomController? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = ZoomableMKMapView()                              // kółko myszy przybliża (gdy mapa interaktywna)
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        if !interactive {                                          // miniatura - bez przesuwania i powiększania
            map.isZoomEnabled = false
            map.isScrollEnabled = false
            map.isRotateEnabled = false
            map.isPitchEnabled = false
        }
        let region = MKCoordinateRegion(center: home ?? CLLocationCoordinate2D(latitude: 30, longitude: 10),
                                        span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 340))
        map.setRegion(region, animated: false)
        zoom?.map = map
        zoom?.homeRegion = region
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let key = "\(reports.count)-\(reports.first?.id.uuidString ?? "")-\(night.first?.latitude ?? 0)"
        guard key != context.coordinator.lastKey else { return }
        context.coordinator.lastKey = key
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        var points = night
        map.addOverlay(MKPolygon(coordinates: &points, count: points.count))
        if let home {
            let annotation = MKPointAnnotation()
            annotation.coordinate = home
            annotation.title = L("Moja stacja")
            map.addAnnotation(annotation)
        }
        for report in reports {
            guard let coordinate = report.coordinate else { continue }
            let annotation = ReportAnnotation(report: report)
            annotation.coordinate = coordinate
            annotation.title = report.receiver
            annotation.subtitle = "\(report.band) \(report.mode) \(report.snr.map { "\($0) dB" } ?? "")"
            map.addAnnotation(annotation)
        }
    }

    final class ReportAnnotation: MKPointAnnotation {
        let report: ReceptionReport
        init(report: ReceptionReport) { self.report = report }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastKey = ""

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = NSColor.black.withAlphaComponent(0.35)
            renderer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.6)
            renderer.lineWidth = 1
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            let size: CGFloat
            let color: NSColor
            if let report = annotation as? ReportAnnotation {
                size = 9
                color = NSColor(PropagationView.bandColor(report.report.band))
            } else {
                size = 13
                color = .systemRed
            }
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.white.setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                border.lineWidth = 1
                border.stroke()
                return true
            }
            view.image = image
            view.canShowCallout = true
            return view
        }
    }
}

// MARK: - Osobne okno mapy propagacji

/// Mapa propagacji w środkowej kolumnie okna (w miejscu skopu RF), gdy otwarta jest zakładka PROPAGACJA:
/// strefa nocy, Twoja stacja, odbiorcy z PSK Reporter, filtr pasma, przybliżanie. Odświeżanie raportów
/// prowadzi zakładka (PropagationView) - jedno źródło zapytań do PSK Reporter.
struct PropagationMapPanel: View {
    @ObservedObject var service: PropagationService
    @EnvironmentObject var logbook: LogbookStore
    /// Przybliżanie mapy (przyciski + / − / widok startowy, kółko myszy).
    @StateObject private var mapZoom = MapZoomController()
    @State private var bandFilter = ""

    private var reports: [ReceptionReport] {
        bandFilter.isEmpty ? service.reports : service.reports.filter { $0.band == bandFilter }
    }

    private var bands: [String] {
        let present = Set(service.reports.map(\.band))
        return PropagationService.bandOrder.filter { present.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L("MAPA – LINIA SZAROŚCI I PROPAGACJA Z TWOJEGO MIEJSCA")).font(.caption.bold()).foregroundStyle(Theme.header)
                Picker(L("Raporty PSK"), selection: $service.scope) {
                    ForEach(PropagationService.ReportScope.allCases) { scope in
                        let query = scope.query(call: logbook.myCall, grid: logbook.myGrid)
                        Text(query.map { "\(scope.name) (\($0.value))" } ?? scope.name).tag(scope)
                    }
                }
                .frame(width: 280)
                Picker(L("Pasmo"), selection: $bandFilter) {
                    Text(L("Wszystkie")).tag("")
                    ForEach(bands, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 170)
                if service.scope.query(call: logbook.myCall, grid: logbook.myGrid) == nil {
                    Text(service.scope == .callsign ? L("Ustaw swój znak w Profilu stacji.") : L("Ustaw lokator w Profilu stacji."))
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(L("{1} raportów", reports.count)).font(.caption).foregroundStyle(.secondary)
                }
                if service.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Odśwież")) { service.refresh(callsign: logbook.myCall, grid: logbook.myGrid, force: true) }
            }
            HStack(spacing: 6) {
                ForEach(PropagationService.bandStats(service.reports, myGrid: logbook.myGrid), id: \.band) { stat in
                    Text("\(stat.band) \(stat.count)× · \(stat.maxKm) km")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(PropagationView.bandColor(stat.band).opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                PropagationMapView(reports: reports, home: Geo.coordinate(fromGrid: logbook.myGrid),
                                   night: Greyline.nightPolygon(at: context.date), zoom: mapZoom)
            }
            .overlay(alignment: .topTrailing) { MapZoomButtons(controller: mapZoom) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(L("Ciemniejszy obszar to noc; jej krawędź (linia szarości) to najlepszy czas na DX na niskich pasmach. Kolor punktu = pasmo."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }
}
