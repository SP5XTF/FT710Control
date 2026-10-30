import SwiftUI
import MapKit
import AppKit

// MARK: - Mapy MapKit: przybliżanie przyciskami i kółkiem myszy

/// Sterowanie powiększeniem mapy z SwiftUI (przyciski + / − / widok startowy).
@MainActor
final class MapZoomController: ObservableObject {
    weak var map: MKMapView?
    /// Widok startowy (do przycisku ⟲): prostokąt z marginesem albo region.
    var homeRect: (rect: MKMapRect, padding: NSEdgeInsets)?
    var homeRegion: MKCoordinateRegion?

    /// factor < 1 przybliża, > 1 oddala.
    func zoom(_ factor: Double) {
        guard let map else { return }
        ZoomableMKMapView.zoom(map, factor: factor, around: map.region.center)
    }

    func reset() {
        guard let map else { return }
        if let home = homeRect {
            map.setVisibleMapRect(home.rect, edgePadding: home.padding, animated: true)
        } else if let region = homeRegion {
            map.setRegion(region, animated: true)
        }
    }
}

/// MKMapView z przybliżaniem kółkiem myszy (wokół kursora). Gładzik działa po staremu:
/// szczypanie przybliża, przesuwanie dwoma palcami przesuwa mapę.
final class ZoomableMKMapView: MKMapView {
    override func scrollWheel(with event: NSEvent) {
        guard isZoomEnabled, !event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)                      // gładzik albo mapa bez powiększania
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = pow(0.85, Double(max(-6, min(6, delta))))   // ząbek w górę - przybliżenie o ok. 15 %
        let point = convert(event.locationInWindow, from: nil)
        Self.zoom(self, factor: factor, around: convert(point, toCoordinateFrom: self))
    }

    /// Zmiana skali z zachowaniem punktu `anchor` w tym samym miejscu ekranu.
    @MainActor
    static func zoom(_ map: MKMapView, factor: Double, around anchor: CLLocationCoordinate2D) {
        let region = map.region
        let latSpan = min(170, max(0.005, region.span.latitudeDelta * factor))
        let lonSpan = min(359, max(0.005, region.span.longitudeDelta * factor))
        let scale = latSpan / max(region.span.latitudeDelta, 1e-9)
        let center = CLLocationCoordinate2D(
            latitude: max(-85, min(85, anchor.latitude + (region.center.latitude - anchor.latitude) * scale)),
            longitude: anchor.longitude + (region.center.longitude - anchor.longitude) * scale)
        map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)),
                      animated: true)
    }
}

/// Przyciski powiększenia w rogu mapy (dobrze widoczne także w ciemnym motywie i małym oknie).
struct MapZoomButtons: View {
    @ObservedObject var controller: MapZoomController

    var body: some View {
        VStack(spacing: 2) {
            button("plus", L("Przybliż (także kółko myszy albo szczypanie na gładziku)")) { controller.zoom(0.5) }
            button("minus", L("Oddal")) { controller.zoom(2) }
            button("arrow.counterclockwise", L("Widok startowy")) { controller.reset() }
        }
        .padding(6)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Obrazy (mapy NOAA): podgląd z przybliżaniem

/// Sterowanie powiększeniem obrazu.
@MainActor
final class ImageZoomController: ObservableObject {
    weak var scrollView: NSScrollView?
    @Published var magnification: CGFloat = 1

    func zoom(_ factor: CGFloat) {
        guard let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let center = NSPoint(x: visible.midX, y: visible.midY)
        let value = min(scrollView.maxMagnification, max(scrollView.minMagnification, scrollView.magnification * factor))
        scrollView.setMagnification(value, centeredAt: center)
        magnification = value
    }

    func fit() {
        guard let scrollView else { return }
        scrollView.magnification = scrollView.minMagnification
        magnification = scrollView.magnification
    }
}

/// Obraz w NSScrollView: szczypanie i kółko myszy przybliżają (wokół kursora), przeciąganie lub przewijanie
/// gładzikiem przesuwa; na starcie cały obraz mieści się w oknie.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    @ObservedObject var controller: ImageZoomController

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.backgroundColor = .black
        scroll.onMagnify = { [weak controller] value in
            Task { @MainActor in controller?.magnification = value }
        }
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleNone
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scroll.documentView = imageView
        controller.scrollView = scroll
        DispatchQueue.main.async { scroll.fitToWindow() }
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        controller.scrollView = scroll
    }

    final class ZoomScrollView: NSScrollView {
        var onMagnify: ((CGFloat) -> Void)?

        /// Najmniejsze powiększenie = cały obraz w oknie; największe - 8×.
        func fitToWindow() {
            guard let size = documentView?.frame.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            let fit = min(bounds.width / size.width, bounds.height / size.height, 1)
            minMagnification = fit
            maxMagnification = max(8, fit * 8)
            magnification = fit
            onMagnify?(fit)
        }

        override func scrollWheel(with event: NSEvent) {
            guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 else {
                super.scrollWheel(with: event)                  // gładzik: przesuwanie
                return
            }
            let factor = pow(1.15, max(-6, min(6, event.scrollingDeltaY)))
            let point = contentView.convert(event.locationInWindow, from: nil)
            let value = min(maxMagnification, max(minMagnification, magnification * factor))
            setMagnification(value, centeredAt: point)
            onMagnify?(value)
        }

        override func magnify(with event: NSEvent) {
            super.magnify(with: event)
            onMagnify?(magnification)
        }

        override func layout() {
            super.layout()
            if magnification <= minMagnification + 0.0001 { fitToWindow() }   // zmiana rozmiaru okna przy widoku całości
        }
    }
}

/// Okno podglądu mapy NOAA z przybliżaniem; obraz pobierany przy otwarciu (zawsze aktualny).
struct ZoomableRemoteImageView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ImageZoomController()
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(String(format: "%.0f %%", controller.magnification * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                Button { controller.zoom(0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L("Oddal"))
                Button { controller.zoom(2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("Przybliż (także kółko myszy albo szczypanie na gładziku)"))
                Button(L("Cały obraz")) { controller.fit() }
                Button(L("Otwórz w przeglądarce")) { NSWorkspace.shared.open(url) }
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            ZStack {
                Color.black
                if let image {
                    ZoomableImageView(image: image, controller: controller)
                } else if failed {
                    Text(L("Nie udało się pobrać obrazu")).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Text(L("Kółko myszy albo szczypanie - przybliżanie; przeciąganie paskami albo dwoma palcami - przesuwanie."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 560)
        .task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let loaded = NSImage(data: data) { image = loaded } else { failed = true }
            } catch {
                failed = true
            }
        }
    }
}
