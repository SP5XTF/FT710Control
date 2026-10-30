import SwiftUI
import MapKit

/// Mapa: moja stacja, stacja korespondenta i trasa po kole wielkim (najkrótsza droga - kierunek anteny).
struct StationMap: NSViewRepresentable {
    let home: CLLocationCoordinate2D?
    let homeLabel: String
    let remote: CLLocationCoordinate2D?
    let remoteLabel: String
    /// Przyciski + / − / widok startowy (MapZoomButtons); kółko myszy przybliża zawsze.
    var zoom: MapZoomController? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = ZoomableMKMapView()
        zoom?.map = map
        map.delegate = context.coordinator
        map.appearance = NSAppearance(named: .darkAqua)
        map.mapType = .mutedStandard
        map.showsCompass = false
        map.showsZoomControls = true
        map.isPitchEnabled = false
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let key = "\(home.map { "\($0.latitude),\($0.longitude)" } ?? "-")|\(remote.map { "\($0.latitude),\($0.longitude)" } ?? "-")"
        guard key != context.coordinator.lastKey else { return }       // nie przerysowuj bez zmian
        context.coordinator.lastKey = key

        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)

        var points: [CLLocationCoordinate2D] = []
        if let home {
            let pin = HomeAnnotation()
            pin.coordinate = home
            pin.title = homeLabel
            map.addAnnotation(pin)
            points.append(home)
        }
        if let remote {
            let pin = MKPointAnnotation()
            pin.coordinate = remote
            pin.title = remoteLabel
            map.addAnnotation(pin)
            points.append(remote)
        }
        zoom?.map = map
        zoom?.homeRect = nil
        zoom?.homeRegion = nil
        if points.count == 2 {
            let path = MKGeodesicPolyline(coordinates: points, count: 2)
            map.addOverlay(path)
            let padding = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
            map.setVisibleMapRect(path.boundingMapRect, edgePadding: padding, animated: false)
            zoom?.homeRect = (path.boundingMapRect, padding)
        } else if let only = points.first {
            let region = MKCoordinateRegion(center: only, span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40))
            map.setRegion(region, animated: false)
            zoom?.homeRegion = region
        } else {
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 10),
                                            span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 340))
            map.setRegion(region, animated: false)
            zoom?.homeRegion = region
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastKey = ""

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.25, alpha: 0.95)
            renderer.lineWidth = 2.5
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let id = "stationDot"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? StationDotView
                ?? StationDotView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.configure(color: annotation is HomeAnnotation ? .systemBlue : .systemOrange,
                           label: (annotation.title ?? nil) ?? "")
            return view
        }
    }
}

/// Pinezka mojej stacji (niebieska); korespondent - pomarańczowa.
final class HomeAnnotation: MKPointAnnotation {}

/// Mały znacznik stacji: kropka 10 pt z białą obwódką i podpis znaku obok
/// (zamiast dużych standardowych pinezek MapKit).
final class StationDotView: MKAnnotationView {
    private static let dotSize: CGFloat = 10
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        centerOffset = .zero                       // środek kropki dokładnie w położeniu stacji

        dot.frame = bounds
        dot.cornerRadius = Self.dotSize / 2
        dot.borderWidth = 1.5
        dot.borderColor = NSColor.white.cgColor
        dot.shadowOpacity = 0.6
        dot.shadowRadius = 2
        dot.shadowOffset = .zero
        layer?.addSublayer(dot)

        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = false
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 2
        label.shadow = shadow
        addSubview(label)
        canShowCallout = false
    }

    required init?(coder: NSCoder) { nil }

    func configure(color: NSColor, label text: String) {
        dot.backgroundColor = color.cgColor
        label.stringValue = text
        label.sizeToFit()
        // Podpis obok kropki, po prawej i nieco wyżej - nie zasłania trasy.
        label.frame.origin = CGPoint(x: Self.dotSize + 3, y: (Self.dotSize - label.frame.height) / 2 + 6)
    }
}
