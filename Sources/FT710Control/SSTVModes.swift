import Foundation

/// Tryb SSTV: parametry z dokumentacji trybów (czasy w milisekundach).
/// Algorytm sprawdzony prototypem (nadajnik → kanał z szumem, rozstrojeniem i rozjazdem zegara → dekoder).
struct SSTVMode: Identifiable, Hashable {
    enum Kind { case martin, scottie, robot36, pd }

    let name: String
    let vis: Int
    let kind: Kind
    let width: Int
    let height: Int
    let scan: Double        // czas jednego skanu koloru (ms)
    let sync: Double
    let porch: Double
    let sep: Double

    var id: Int { vis }

    static let all: [SSTVMode] = [
        SSTVMode(name: "Martin M1", vis: 44, kind: .martin, width: 320, height: 256, scan: 146.432, sync: 4.862, porch: 0.572, sep: 0.572),
        SSTVMode(name: "Martin M2", vis: 40, kind: .martin, width: 320, height: 256, scan: 73.216, sync: 4.862, porch: 0.572, sep: 0.572),
        SSTVMode(name: "Scottie S1", vis: 60, kind: .scottie, width: 320, height: 256, scan: 138.240, sync: 9.0, porch: 1.5, sep: 1.5),
        SSTVMode(name: "Scottie S2", vis: 56, kind: .scottie, width: 320, height: 256, scan: 88.064, sync: 9.0, porch: 1.5, sep: 1.5),
        SSTVMode(name: "Robot 36", vis: 8, kind: .robot36, width: 320, height: 240, scan: 88.0, sync: 9.0, porch: 3.0, sep: 4.5),
        SSTVMode(name: "PD 90", vis: 99, kind: .pd, width: 320, height: 256, scan: 170.240, sync: 20.0, porch: 2.08, sep: 0),
        SSTVMode(name: "PD 120", vis: 95, kind: .pd, width: 640, height: 496, scan: 121.600, sync: 20.0, porch: 2.08, sep: 0),
        SSTVMode(name: "PD 180", vis: 96, kind: .pd, width: 640, height: 496, scan: 183.040, sync: 20.0, porch: 2.08, sep: 0)
    ]

    static func byVIS(_ code: Int) -> SSTVMode? { all.first { $0.vis == code } }

    /// Kanał skanu: kolor albo składowa YUV.
    enum Channel { case r, g, b, y, chroma, y1, v, u, y2 }

    struct Scan {
        let channel: Channel
        let offset: Double      // ms od początku linii transmisji
        let length: Double      // ms
    }

    /// Okres linii transmisji (ms), liczba linii transmisji, położenie synchronizacji i skany.
    /// W PD jedna linia transmisji niesie dwa wiersze obrazu.
    var period: Double {
        switch kind {
        case .martin: return sync + porch + 3 * (scan + sep)
        case .scottie: return sep + scan + sep + scan + sync + porch + scan
        case .robot36: return 150.0
        case .pd: return sync + porch + 4 * scan
        }
    }

    var transmissionLines: Int { kind == .pd ? height / 2 : height }

    var syncOffset: Double { kind == .scottie ? sep + scan + sep + scan : 0 }

    var scans: [Scan] {
        switch kind {
        case .martin:
            let g = sync + porch
            let b = g + scan + sep
            let r = b + scan + sep
            return [Scan(channel: .g, offset: g, length: scan), Scan(channel: .b, offset: b, length: scan),
                    Scan(channel: .r, offset: r, length: scan)]
        case .scottie:
            let g = sep
            let b = g + scan + sep
            let r = b + scan + sync + porch
            return [Scan(channel: .g, offset: g, length: scan), Scan(channel: .b, offset: b, length: scan),
                    Scan(channel: .r, offset: r, length: scan)]
        case .robot36:
            let y = sync + porch
            return [Scan(channel: .y, offset: y, length: scan),
                    Scan(channel: .chroma, offset: y + scan + sep + 1.5, length: 44.0)]
        case .pd:
            let y1 = sync + porch
            return [Scan(channel: .y1, offset: y1, length: scan), Scan(channel: .v, offset: y1 + scan, length: scan),
                    Scan(channel: .u, offset: y1 + 2 * scan, length: scan), Scan(channel: .y2, offset: y1 + 3 * scan, length: scan)]
        }
    }

    /// Czas nadawania (s): nagłówek VIS (910 ms) + obraz.
    var duration: Double {
        (910 + (kind == .scottie ? sync : 0) + period * Double(transmissionLines)) / 1000
    }
}

/// Konwersje RGB ↔ YUV (pełny zakres, jak w JPEG) - tak samo w nadajniku i dekoderze.
enum SSTVColor {
    @inline(__always) static func clamp(_ v: Double) -> Double { min(max(v, 0), 255) }

    static func yuv(r: Double, g: Double, b: Double) -> (y: Double, u: Double, v: Double) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        return (clamp(y), clamp(128 + (b - y) * 0.564), clamp(128 + (r - y) * 0.713))
    }

    static func rgb(y: Double, u: Double, v: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r = y + 1.402 * (v - 128)
        let g = y - 0.344136 * (u - 128) - 0.714136 * (v - 128)
        let b = y + 1.772 * (u - 128)
        return (UInt8(clamp(r)), UInt8(clamp(g)), UInt8(clamp(b)))
    }
}
