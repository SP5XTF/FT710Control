import SwiftUI

/// Szerokości filtra odpowiadające indeksom komendy SH (tabele Yaesu z rodziny FTDX10/FTDX101).
/// Indeks 0 = szerokość domyślna dla trybu. Jeśli FT-710 ma inną tabelę, opis może się różnić
/// od wyświetlacza radia - sam indeks (pokazany obok) jest zawsze tym, co radio zgłosiło.
enum FilterTables {
    static let ssb = [0, 300, 400, 600, 850, 1100, 1200, 1500, 1650, 1800, 1950, 2100, 2250,
                      2400, 2450, 2500, 2600, 2700, 2800, 2900, 3000, 3200, 3500, 4000]
    static let narrow = [0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 600, 800,
                         1200, 1400, 1700, 2000, 2400, 3000, 3200, 3500, 4000]

    enum Kind { case ssb, narrow, wide }

    static func kind(for modeCode: String) -> Kind {
        switch modeCode {
        case "1", "2": return .ssb                         // LSB, USB
        case "3", "7", "6", "9", "8", "C": return .narrow  // CW, RTTY, DATA
        default: return .wide                              // AM, FM - szerokość stała
        }
    }

    /// Szerokość w Hz dla indeksu; nil dla indeksu 0 (domyślna) lub spoza tabeli.
    static func widthHz(index: Int, modeCode: String) -> Int? {
        let table: [Int]
        switch kind(for: modeCode) {
        case .ssb: table = ssb
        case .narrow: table = narrow
        case .wide: return nil
        }
        guard index > 0, index < table.count else { return nil }
        return table[index]
    }

    static func label(index: Int, modeCode: String) -> String {
        if kind(for: modeCode) == .wide { return L("stała") }
        if index == 0 { return L("domyślna") }
        guard let hz = widthHz(index: index, modeCode: modeCode) else { return "#\(index)" }
        return hz >= 1000 ? String(format: "%.2f kHz", Double(hz) / 1000) : "\(hz) Hz"
    }

    /// Szerokość zakładana, gdy radio podaje „domyślną”.
    static func defaultWidth(for modeCode: String) -> Int {
        switch kind(for: modeCode) {
        case .ssb: return 2400
        case .narrow: return modeCode == "3" || modeCode == "7" ? 500 : 2400
        case .wide: return 4000
        }
    }

    /// Środek pasma w częstotliwości audio: SSB/DATA ok. 1500 Hz, CW na tonie (zakładamy 700 Hz).
    static func center(for modeCode: String) -> Int {
        switch modeCode {
        case "3", "7": return 700
        default: return 1500
        }
    }
}

/// Wykres pasma przepustowego odbiornika w dziedzinie audio (0–4 kHz):
/// szerokość + SHIFT, ręczny NOTCH (czerwone wcięcie), CONTOUR (bursztynowe przegięcie), znacznik DNF.
struct FilterGraph: View {
    let modeCode: String
    let widthIndex: Int?
    let shift: Int
    let notchOn: Bool
    let notchHz: Int?
    let contourOn: Bool
    let contourHz: Int?
    let dnfOn: Bool

    private let maxHz = 4000.0

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let base = h - 12
            let top: CGFloat = 12
            func x(_ hz: Double) -> CGFloat { CGFloat(min(max(hz / maxHz, 0), 1)) * w }

            // Siatka i oś
            for k in 0...4 {
                var line = Path()
                line.move(to: CGPoint(x: x(Double(k) * 1000), y: top))
                line.addLine(to: CGPoint(x: x(Double(k) * 1000), y: base))
                context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)
                let label = k == 0 ? "0" : "\(k)k"
                context.draw(Text(label).font(.system(size: 8)).foregroundColor(Theme.dim),
                             at: CGPoint(x: min(max(x(Double(k) * 1000), 6), w - 8), y: h - 5))
            }

            // Pasmo przepustowe
            let width: Double
            if FilterTables.kind(for: modeCode) == .wide {
                width = maxHz
            } else {
                width = Double(widthIndex.flatMap { FilterTables.widthHz(index: $0, modeCode: modeCode) }
                               ?? FilterTables.defaultWidth(for: modeCode))
            }
            let center = Double(FilterTables.center(for: modeCode) + shift)
            let low = max(0, center - width / 2)
            let high = min(maxHz, center + width / 2)
            let slope = max(40, width * 0.08)

            var band = Path()
            band.move(to: CGPoint(x: x(max(0, low - slope)), y: base))
            band.addLine(to: CGPoint(x: x(low), y: top))
            // CONTOUR: łagodne przegięcie na zadanej częstotliwości (jeśli wypada w paśmie)
            if contourOn, let contourHz, Double(contourHz) > low, Double(contourHz) < high {
                let c = Double(contourHz)
                let half = max(60, width * 0.07)
                band.addLine(to: CGPoint(x: x(max(low, c - half)), y: top))
                band.addQuadCurve(to: CGPoint(x: x(min(high, c + half)), y: top),
                                  control: CGPoint(x: x(c), y: top + (base - top) * 0.55))
            }
            band.addLine(to: CGPoint(x: x(high), y: top))
            band.addLine(to: CGPoint(x: x(min(maxHz, high + slope)), y: base))
            band.closeSubpath()
            context.fill(band, with: .color(Theme.accent.opacity(0.22)))
            context.stroke(band, with: .color(Theme.accent), lineWidth: 1.5)

            // Ręczny NOTCH: wąskie wcięcie do podstawy
            if notchOn, let notchHz {
                let n = Double(notchHz)
                var notch = Path()
                notch.move(to: CGPoint(x: x(n - 60), y: top))
                notch.addLine(to: CGPoint(x: x(n), y: base))
                notch.addLine(to: CGPoint(x: x(n + 60), y: top))
                context.stroke(notch, with: .color(Theme.tx), lineWidth: 1.5)
            }

            // Środek pasma (znacznik SHIFT)
            var mid = Path()
            mid.move(to: CGPoint(x: x(center), y: base))
            mid.addLine(to: CGPoint(x: x(center), y: base - 6))
            context.stroke(mid, with: .color(.white.opacity(0.5)), lineWidth: 1)

            // Podstawa
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: base))
            axis.addLine(to: CGPoint(x: w, y: base))
            context.stroke(axis, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if contourOn { badge("CONTOUR", Theme.header) }
                if notchOn { badge("NOTCH", Theme.tx) }
                if dnfOn { badge("DNF", Theme.ok) }
            }
            .padding(4)
        }
        .background(Theme.panelInner, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.6)))
    }
}
