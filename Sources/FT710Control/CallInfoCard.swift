import SwiftUI
import AppKit
import CoreLocation

/// Karta oglądanej stacji: dane z QRZ, odległość i azymut od mojego lokatora, mapa z trasą.
struct CallInfoCard: View {
    /// Przybliżanie mapy stacji (przyciski + / − / widok startowy, kółko myszy).
    @StateObject private var mapZoom = MapZoomController()
    @ObservedObject var lookup: CallLookup
    @ObservedObject var qrz: QRZClient
    let myGrid: String
    let myCall: String

    private var home: CLLocationCoordinate2D? { Geo.coordinate(fromGrid: myGrid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            StationMap(home: home,
                       homeLabel: myCall.isEmpty ? myGrid.uppercased() : myCall,
                       remote: lookup.coordinate,
                       remoteLabel: lookup.call,
                       zoom: mapZoom)
                .overlay(alignment: .topTrailing) { MapZoomButtons(controller: mapZoom) }
                .frame(minHeight: 110, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            details
            HStack(spacing: 8) {
                Button(L("Szukaj w QRZ")) { lookup.request(lookup.call, using: qrz, gridHint: lookup.gridHint) }
                    .buttonStyle(RigButtonStyle(height: 26, fontSize: 12))
                    .disabled(lookup.call.isEmpty || !qrz.canLookup)
                Button("QRZ.com") {
                    if let url = URL(string: "https://www.qrz.com/db/\(QRZClient.baseCall(lookup.call))") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(RigButtonStyle(height: 26, fontSize: 12))
                .disabled(lookup.call.isEmpty)
            }
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(isErrorPhase ? Theme.tx : Theme.dim)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panelInner, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    // MARK: - Części

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lookup.call.isEmpty ? "—" : lookup.call)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let place = lookup.record?.place, !place.isEmpty {
                    Text("— " + place)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if lookup.phase == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            if let path = pathText {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            GridRow {
                label(L("Imię"))
                value(lookup.record?.displayName ?? "")
                label(L("Kraj"))
                value(lookup.record?.country ?? "")
            }
            GridRow {
                label("QTH")
                value(lookup.record.map { [$0.city, $0.state].filter { !$0.isEmpty }.joined(separator: ", ") } ?? "")
                label(L("Lokator"))
                value(lookup.grid.isEmpty ? "" : lookup.grid + (lookup.record?.grid.isEmpty == false ? "" : L(" (przybl.)")))
            }
            GridRow {
                label("Lat / Lon")
                value(lookup.coordinate.map { String(format: "%.3f, %.3f", $0.latitude, $0.longitude) } ?? "")
                label("DXCC / CQ / ITU")
                value(zonesText)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.header)
    }

    private func value(_ text: String) -> some View {
        Text(text.isEmpty ? "–" : text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
    }

    // MARK: - Teksty

    private var pathText: String? {
        guard let home, let remote = lookup.coordinate else { return nil }
        let km = Geo.distanceKm(home, remote)
        let bearing = Geo.bearing(home, remote)
        let longPath = (bearing + 180).truncatingRemainder(dividingBy: 360)
        return String(format: "~ %.0f km / %.0f mi  •  %.0f° %@  •  LP %.0f°",
                      km, km * 0.621371, bearing, Geo.compass(bearing), longPath)
    }

    private var zonesText: String {
        guard let record = lookup.record else { return "" }
        let parts = [record.dxcc, record.cqZone, record.ituZone]
        return parts.allSatisfy(\.isEmpty) ? "" : parts.map { $0.isEmpty ? "–" : $0 }.joined(separator: " / ")
    }

    private var isErrorPhase: Bool {
        if case .failed = lookup.phase { return true }
        return false
    }

    private var statusText: String {
        var parts: [String] = []
        switch lookup.phase {
        case .idle: parts.append(L("Wpisz znak, aby zobaczyć dane stacji."))
        case .loading: parts.append(L("Szukam w QRZ…"))
        case .found: if qrz.limitedData { parts.append(L("QRZ bez subskrypcji XML: część danych jest niedostępna.")) }
        case .notFound: parts.append(L("Znaku nie ma w QRZ."))
        case .noAccount: parts.append(L("Podaj konto QRZ w oknie dziennika, aby pobierać dane."))
        case .failed(let message): parts.append(L("QRZ: {1}", message))
        }
        if home == nil { parts.append(L("Ustaw „Mój lokator” w oknie dziennika, aby liczyć odległość.")) }
        return parts.joined(separator: " ")
    }
}
