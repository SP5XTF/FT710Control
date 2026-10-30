import SwiftUI
import MapKit
import AppKit

/// Podział kolorów na mapie łączności.
enum QSOMapColoring: String, CaseIterable, Identifiable {
    case band, mode, confirmation
    var id: String { rawValue }
    var name: String {
        switch self {
        case .band: return L("Pasmo")
        case .mode: return L("Emisja")
        case .confirmation: return L("Potwierdzenie")
        }
    }
}

/// Okres na mapie łączności.
enum QSOMapPeriod: String, CaseIterable, Identifiable {
    case all, hours24, days30, months12, thisYear
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: return L("Cały okres")
        case .hours24: return L("24 godziny")
        case .days30: return L("30 dni")
        case .months12: return L("12 miesięcy")
        case .thisYear: return L("Ten rok")
        }
    }
    var start: Date? {
        let calendar = Calendar(identifier: .gregorian)
        switch self {
        case .all: return nil
        case .hours24: return Date().addingTimeInterval(-24 * 3600)
        case .days30: return calendar.date(byAdding: .day, value: -30, to: Date())
        case .months12: return calendar.date(byAdding: .month, value: -12, to: Date())
        case .thisYear: return calendar.date(from: calendar.dateComponents([.year], from: Date()))
        }
    }
}

/// Punkt łączności na mapie: położenie z lokatora albo (przybliżone) ze środka kraju z cty.dat.
struct QSOMapPoint: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let approximate: Bool
    let colorKey: String
    let call: String
    let start: Date
    let band: String
    let mode: String
    let km: Int?
    let continent: String
    let country: String
}

/// Mapa łączności (okno dziennika → „Mapa łączności…”): kula ziemska 3D (MapKit), punkty w kolorach pasm,
/// emisji albo potwierdzeń, linie po kole wielkim od Twojej stacji, filtry, legenda i statystyka.
struct QSOMapView: View {
    @ObservedObject var store: LogbookStore
    let onEdit: (QSO) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qsoMap.coloring") private var coloringRaw = QSOMapColoring.band.rawValue
    @AppStorage("qsoMap.lines") private var showLines = false
    @AppStorage("qsoMap.approximate") private var showApproximate = true
    @AppStorage("qsoMap.period") private var periodRaw = QSOMapPeriod.all.rawValue
    @AppStorage("qsl.countEQSL") private var countEQSL = false
    @AppStorage("qsl.countQRZ") private var countQRZ = false
    @State private var bandFilter = ""
    @State private var modeFilter = ""
    @State private var continentFilter = ""
    @State private var onlyConfirmed = false
    @State private var selected: UUID?
    @StateObject private var zoom = MapZoomController()

    private var coloring: QSOMapColoring { QSOMapColoring(rawValue: coloringRaw) ?? .band }
    private var period: QSOMapPeriod { QSOMapPeriod(rawValue: periodRaw) ?? .all }
    private var home: CLLocationCoordinate2D? { Geo.coordinate(fromGrid: store.myGrid) }

    var body: some View {
        let points = self.points
        VStack(alignment: .leading, spacing: 8) {
            header
            filters
            ZStack(alignment: .topTrailing) {
                QSOGlobeMap(points: points, home: home, homeLabel: store.myCall, showLines: showLines,
                            colors: colorTable, zoom: zoom, selected: $selected)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                MapZoomButtons(controller: zoom)
            }
            .overlay(alignment: .bottomLeading) { legend(points).padding(8) }
            footer(points)
        }
        .padding(14)
        .frame(minWidth: 1050, minHeight: 760)
    }

    // MARK: - Nagłówek i filtry

    private var header: some View {
        HStack {
            Text(L("Mapa łączności")).font(.title2.bold())
            Picker(L("Kolory"), selection: $coloringRaw) {
                ForEach(QSOMapColoring.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            Toggle(L("Linie po kole wielkim"), isOn: $showLines)
                .help(L("Linie od Twojej stacji do łączności - przy dużej liczbie punktów warto zawęzić filtry"))
            Toggle(L("Punkty przybliżone"), isOn: $showApproximate)
                .help(L("Łączności bez lokatora - w środku kraju według cty.dat (półprzezroczyste)"))
            Spacer()
            Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker(L("Pasmo"), selection: $bandFilter) {
                Text(L("Wszystkie")).tag("")
                ForEach(bands, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 150)
            Picker(L("Emisja"), selection: $modeFilter) {
                Text(L("Wszystkie")).tag("")
                ForEach(Self.modeGroups, id: \.self) { Text(Self.modeGroupName($0)).tag($0) }
            }
            .frame(width: 170)
            Picker(L("Okres"), selection: $periodRaw) {
                ForEach(QSOMapPeriod.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .frame(width: 170)
            Picker(L("Kontynent"), selection: $continentFilter) {
                Text(L("Wszystkie")).tag("")
                ForEach(["EU", "AS", "AF", "NA", "SA", "OC", "AN"], id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 160)
            Toggle(L("Tylko potwierdzone"), isOn: $onlyConfirmed)
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: - Punkty

    private var bands: [String] {
        AwardCalculator.orderedBands(Set(store.qsos.map { $0.band.lowercased() }.filter { !$0.isEmpty }))
    }

    static let modeGroups = ["CW", "PHONE", "FT8", "FT4", "RTTY", "DIGI"]

    static func modeGroupName(_ group: String) -> String {
        switch group {
        case "PHONE": return L("Fonia")
        case "DIGI": return L("Inne cyfrowe")
        default: return group
        }
    }

    static func modeGroup(_ qso: QSO) -> String {
        switch LogbookStore.modeFamily(qso) {
        case "CW": return "CW"
        case "SSB", "AM", "FM", "DV": return "PHONE"
        case "FT8": return "FT8"
        case "FT4": return "FT4"
        case "RTTY": return "RTTY"
        default: return "DIGI"
        }
    }

    private var points: [QSOMapPoint] {
        let table = CTYDatabase.shared.table
        let since = period.start
        let home = self.home
        var result: [QSOMapPoint] = []
        for qso in store.qsos {
            let band = qso.band.lowercased()
            if !bandFilter.isEmpty, band != bandFilter { continue }
            let group = Self.modeGroup(qso)
            if !modeFilter.isEmpty, group != modeFilter { continue }
            if let since, qso.start < since { continue }
            let confirmed = qso.isConfirmed(includeEQSL: countEQSL, includeQRZ: countQRZ)
            if onlyConfirmed, !confirmed { continue }
            let match = table?.lookup(qso.call)
            let continent = qso.extra["CONT"] ?? match?.continent ?? ""
            if !continentFilter.isEmpty, continent != continentFilter { continue }
            var coordinate = Geo.coordinate(fromGrid: qso.grid)
            var approximate = false
            if coordinate == nil, let entity = match?.entity {
                coordinate = CLLocationCoordinate2D(latitude: entity.latitude, longitude: entity.longitude)
                approximate = true
            }
            guard let coordinate, showApproximate || !approximate else { continue }
            let key: String
            switch coloring {
            case .band: key = band
            case .mode: key = group
            case .confirmation: key = confirmed ? "Y" : "N"
            }
            let km = home.map { Int(Geo.distanceKm($0, coordinate).rounded()) }
            result.append(QSOMapPoint(id: qso.id, coordinate: coordinate, approximate: approximate, colorKey: key,
                                      call: qso.call, start: qso.start, band: qso.band, mode: qso.modeLabel, km: km,
                                      continent: continent,
                                      country: qso.extra["COUNTRY"] ?? match.map { table?.dxccName(CTYTable.dxccKey($0)) ?? $0.entity.name } ?? ""))
        }
        return result
    }

    /// Kolor dla klucza (pasmo jak na mapie propagacji, emisja, potwierdzenie).
    private var colorTable: [String: NSColor] {
        var table: [String: NSColor] = [:]
        switch coloring {
        case .band:
            for band in bands { table[band] = NSColor(PropagationView.bandColor(band)) }
        case .mode:
            table = ["CW": .systemYellow, "PHONE": .systemOrange, "FT8": .systemGreen, "FT4": .systemMint,
                     "RTTY": .systemPurple, "DIGI": .systemTeal]
        case .confirmation:
            table = ["Y": .systemGreen, "N": .systemOrange]
        }
        return table
    }

    private func label(_ key: String) -> String {
        switch coloring {
        case .band: return key
        case .mode: return Self.modeGroupName(key)
        case .confirmation: return key == "Y" ? L("potwierdzone") : L("niepotwierdzone")
        }
    }

    // MARK: - Legenda i stopka

    private func legend(_ points: [QSOMapPoint]) -> some View {
        let counts = Dictionary(grouping: points, by: \.colorKey).mapValues(\.count)
        let order: [String] = coloring == .band ? bands : coloring == .mode ? Self.modeGroups : ["Y", "N"]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(order.filter { counts[$0] != nil }, id: \.self) { key in
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: colorTable[key] ?? .gray)).frame(width: 9, height: 9)
                    Text(label(key)).font(.caption)
                    Spacer(minLength: 8)
                    Text("\(counts[key] ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(width: 170)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func footer(_ points: [QSOMapPoint]) -> some View {
        let countries = Set(points.map(\.country).filter { !$0.isEmpty }).count
        let continents = Set(points.map(\.continent).filter { !$0.isEmpty }).count
        let farthest = points.filter { !$0.approximate }.max { ($0.km ?? 0) < ($1.km ?? 0) }
        let approx = points.filter(\.approximate).count
        return HStack(spacing: 16) {
            Text(L("Na mapie: {1} QSO", points.count)).bold()
            Text(L("kraje: {1}", countries))
            Text(L("kontynenty: {1}", continents))
            if let f = farthest, let km = f.km { Text(L("najdalej: {1} – {2} km", f.call, km)) }
            if approx > 0 { Text(L("przybliżone: {1}", approx)).foregroundStyle(.secondary) }
            Spacer()
            if let id = selected, let qso = store.qsos.first(where: { $0.id == id }) {
                Text("\(qso.call) · \(QSOMapFormat.date.string(from: qso.start)) UTC · \(qso.band) \(qso.modeLabel)")
                    .font(.callout.monospaced())
                Button(L("Edytuj…")) { onEdit(qso) }
            }
        }
        .font(.caption)
    }

}

/// Format daty na mapie (UTC) - poza widokiem, bo korzysta z niego też punkt MapKit.
enum QSOMapFormat {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// Wszystkie punkty łączności jako jedna warstwa (szybciej niż tysiące znaczników MapKit).
final class QSODotsOverlay: NSObject, MKOverlay {
    struct Dot {
        let point: MKMapPoint
        let color: NSColor
        let approximate: Bool
    }
    let dots: [Dot]
    @objc let boundingMapRect = MKMapRect.world
    @objc let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    init(dots: [Dot]) { self.dots = dots }
}

/// Rysowanie kropek w kafelkach mapy - tylko te, które leżą na danym kafelku; stała wielkość na ekranie.
final class QSODotsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? QSODotsOverlay else { return }
        let radius = 4.5 / Double(zoomScale)                   // 4,5 punktu ekranu niezależnie od przybliżenia
        let area = mapRect.insetBy(dx: -radius * 2, dy: -radius * 2)
        context.setLineWidth(CGFloat(1 / Double(zoomScale)))
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        for dot in overlay.dots where area.contains(dot.point) {
            let p = point(for: dot.point)
            let r = CGFloat(radius)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            context.setFillColor(dot.color.withAlphaComponent(dot.approximate ? 0.45 : 1).cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }
}

/// Punkt wybrany kliknięciem (jeden znacznik z dymkiem).
final class QSOAnnotation: NSObject, MKAnnotation {
    @objc let coordinate: CLLocationCoordinate2D              // MapKit czyta pola przez Objective-C
    let qsoID: UUID
    @objc let title: String?
    @objc let subtitle: String?

    init(_ point: QSOMapPoint) {
        coordinate = point.coordinate
        qsoID = point.id
        title = point.call
        subtitle = "\(QSOMapFormat.date.string(from: point.start)) · \(point.band) \(point.mode)"
            + (point.km.map { " · \($0) km" } ?? "") + (point.approximate ? " · " + L("położenie przybliżone") : "")
    }
}

/// Kula ziemska MapKit (obraz satelitarny z rzeźbą terenu - po oddaleniu globus 3D na Macach z procesorem Apple).
/// Punkty: jedna warstwa rysowana (QSODotsOverlay); kliknięcie - najbliższa kropka w promieniu 10 pikseli.
struct QSOGlobeMap: NSViewRepresentable {
    let points: [QSOMapPoint]
    let home: CLLocationCoordinate2D?
    let homeLabel: String
    let showLines: Bool
    let colors: [String: NSColor]
    var zoom: MapZoomController?
    @Binding var selected: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeNSView(context: Context) -> MKMapView {
        let map = ZoomableMKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        map.showsZoomControls = false
        map.showsCompass = true
        let center = home ?? CLLocationCoordinate2D(latitude: 30, longitude: 10)
        map.camera = MKMapCamera(lookingAtCenter: center, fromDistance: 25_000_000, pitch: 0, heading: 0)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        context.coordinator.map = map
        zoom?.map = map
        zoom?.homeRegion = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 340))
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.selected = $selected
        context.coordinator.points = points
        zoom?.map = map
        // przebudowa tylko po zmianie danych, kolorów albo linii (nie przy każdym odświeżeniu widoku)
        var hasher = Hasher()
        for p in points { hasher.combine(p.id); hasher.combine(p.colorKey) }
        hasher.combine(showLines)
        hasher.combine(home?.latitude)
        hasher.combine(home?.longitude)
        let signature = hasher.finalize()
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature

        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)
        context.coordinator.lineColors.removeAll()
        if showLines, let home {
            // jedna wielolinia na kolor - pod kropkami
            var byColor: [String: [MKPolyline]] = [:]
            for p in points {
                byColor[p.colorKey, default: []].append(MKGeodesicPolyline(coordinates: [home, p.coordinate], count: 2))
            }
            for (key, lines) in byColor {
                let multi = MKMultiPolyline(lines)
                context.coordinator.lineColors[ObjectIdentifier(multi)] = colors[key] ?? .systemGray
                map.addOverlay(multi, level: .aboveRoads)
            }
        }
        let dots = points.map {
            QSODotsOverlay.Dot(point: MKMapPoint($0.coordinate), color: colors[$0.colorKey] ?? .systemGray, approximate: $0.approximate)
        }
        map.addOverlay(QSODotsOverlay(dots: dots), level: .aboveLabels)
        if let home {
            let mark = MKPointAnnotation()
            mark.coordinate = home
            mark.title = homeLabel.isEmpty ? L("Moja stacja") : homeLabel
            map.addAnnotation(mark)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var selected: Binding<UUID?>
        var signature: Int?
        var lineColors: [ObjectIdentifier: NSColor] = [:]
        var points: [QSOMapPoint] = []
        weak var map: MKMapView?
        private var marker: QSOAnnotation?

        init(selected: Binding<UUID?>) { self.selected = selected }

        /// Kliknięcie: najbliższa kropka w promieniu 10 pikseli → znacznik z dymkiem i szczegóły na dole okna.
        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let map else { return }
            let location = gesture.location(in: map)
            var best: (point: QSOMapPoint, distance: CGFloat)?
            for p in points {
                let screen = map.convert(p.coordinate, toPointTo: map)
                let d = hypot(screen.x - location.x, screen.y - location.y)
                if d <= 10, d < (best?.distance ?? .infinity) { best = (p, d) }
            }
            if let marker { map.removeAnnotation(marker) }
            marker = nil
            guard let best else { selected.wrappedValue = nil; return }
            let annotation = QSOAnnotation(best.point)
            map.addAnnotation(annotation)
            map.selectAnnotation(annotation, animated: true)
            marker = annotation
            selected.wrappedValue = best.point.id
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is QSOAnnotation {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "selected")
                view.markerTintColor = .systemYellow
                view.canShowCallout = true
                view.displayPriority = .required
                return view
            }
            if annotation is MKPointAnnotation {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "home")
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let dots = overlay as? QSODotsOverlay { return QSODotsRenderer(overlay: dots) }
            if let multi = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
                renderer.strokeColor = (lineColors[ObjectIdentifier(multi)] ?? .systemGray).withAlphaComponent(0.35)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
