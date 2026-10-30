import SwiftUI

/// Uproszczony plan pasm IARU Region 1 (160-6 m) z zakresami FT8 i pasmami radiofonii - pasek pod waterfallem.
enum BandPlan {
    enum Kind {
        case cw, digital, phone, beacon, satellite, fm, ft8, broadcast

        var color: Color {
            switch self {
            case .cw: return Color(red: 0.23, green: 0.43, blue: 0.65)
            case .digital: return Color(red: 0.48, green: 0.31, blue: 0.69)
            case .phone: return Color(red: 0.18, green: 0.55, blue: 0.34)
            case .beacon: return Color(red: 0.79, green: 0.54, blue: 0.11)
            case .satellite: return Color(red: 0.70, green: 0.62, blue: 0.15)
            case .fm: return Color(red: 0.12, green: 0.55, blue: 0.55)
            case .ft8: return Color(red: 0.10, green: 0.70, blue: 0.75)
            case .broadcast: return Color(red: 0.55, green: 0.23, blue: 0.23)
            }
        }

        var label: String {
            switch self {
            case .cw: return "CW"
            case .digital: return L("CYFROWE")
            case .phone: return "SSB"
            case .beacon: return L("RADIOLATARNIE")
            case .satellite: return L("SATELITY")
            case .fm: return "FM"
            case .ft8: return "FT8"
            case .broadcast: return L("RADIOFONIA")
            }
        }
    }

    struct Segment {
        let low: Int
        let high: Int
        let kind: Kind
        var name: String? = nil                         // np. „41 m” dla radiofonii
    }

    private static func k(_ value: Double) -> Int { Int(value * 1000) }

    /// Odcinki główne (rysowane najpierw).
    static let segments: [Segment] = [
        // 160 m
        Segment(low: k(1810), high: k(1838), kind: .cw), Segment(low: k(1838), high: k(1840), kind: .digital),
        Segment(low: k(1840), high: k(2000), kind: .phone),
        // 80 m
        Segment(low: k(3500), high: k(3570), kind: .cw), Segment(low: k(3570), high: k(3600), kind: .digital),
        Segment(low: k(3600), high: k(3800), kind: .phone),
        // 60 m
        Segment(low: k(5351.5), high: k(5354), kind: .digital), Segment(low: k(5354), high: k(5366), kind: .phone),
        // 40 m
        Segment(low: k(7000), high: k(7040), kind: .cw), Segment(low: k(7040), high: k(7060), kind: .digital),
        Segment(low: k(7060), high: k(7200), kind: .phone),
        // 30 m
        Segment(low: k(10100), high: k(10130), kind: .cw), Segment(low: k(10130), high: k(10150), kind: .digital),
        // 20 m
        Segment(low: k(14000), high: k(14070), kind: .cw), Segment(low: k(14070), high: k(14099), kind: .digital),
        Segment(low: k(14099), high: k(14101), kind: .beacon), Segment(low: k(14101), high: k(14350), kind: .phone),
        // 17 m
        Segment(low: k(18068), high: k(18095), kind: .cw), Segment(low: k(18095), high: k(18109), kind: .digital),
        Segment(low: k(18109), high: k(18111), kind: .beacon), Segment(low: k(18111), high: k(18168), kind: .phone),
        // 15 m
        Segment(low: k(21000), high: k(21070), kind: .cw), Segment(low: k(21070), high: k(21149), kind: .digital),
        Segment(low: k(21149), high: k(21151), kind: .beacon), Segment(low: k(21151), high: k(21450), kind: .phone),
        // 12 m
        Segment(low: k(24890), high: k(24915), kind: .cw), Segment(low: k(24915), high: k(24929), kind: .digital),
        Segment(low: k(24929), high: k(24931), kind: .beacon), Segment(low: k(24931), high: k(24990), kind: .phone),
        // 10 m
        Segment(low: k(28000), high: k(28070), kind: .cw), Segment(low: k(28070), high: k(28190), kind: .digital),
        Segment(low: k(28190), high: k(28225), kind: .beacon), Segment(low: k(28225), high: k(29200), kind: .phone),
        Segment(low: k(29300), high: k(29510), kind: .satellite), Segment(low: k(29520), high: k(29700), kind: .fm),
        // 6 m
        Segment(low: k(50000), high: k(50100), kind: .cw), Segment(low: k(50100), high: k(50500), kind: .phone),
        Segment(low: k(50500), high: k(51000), kind: .digital), Segment(low: k(51000), high: k(52000), kind: .fm),
        // radiofonia (FT-710 odbiera także poza pasmami amatorskimi)
        Segment(low: k(531), high: k(1602), kind: .broadcast, name: "MW"),
        Segment(low: k(2300), high: k(2495), kind: .broadcast, name: "120 m"),
        Segment(low: k(3200), high: k(3400), kind: .broadcast, name: "90 m"),
        Segment(low: k(3900), high: k(4000), kind: .broadcast, name: "75 m"),
        Segment(low: k(4750), high: k(5060), kind: .broadcast, name: "60 m"),
        Segment(low: k(5900), high: k(6200), kind: .broadcast, name: "49 m"),
        Segment(low: k(7200), high: k(7450), kind: .broadcast, name: "41 m"),
        Segment(low: k(9400), high: k(9900), kind: .broadcast, name: "31 m"),
        Segment(low: k(11600), high: k(12100), kind: .broadcast, name: "25 m"),
        Segment(low: k(13570), high: k(13870), kind: .broadcast, name: "22 m"),
        Segment(low: k(15100), high: k(15800), kind: .broadcast, name: "19 m"),
        Segment(low: k(17480), high: k(17900), kind: .broadcast, name: "16 m"),
        Segment(low: k(18900), high: k(19020), kind: .broadcast, name: "15 m"),
        Segment(low: k(21450), high: k(21850), kind: .broadcast, name: "13 m"),
        Segment(low: k(25670), high: k(26100), kind: .broadcast, name: "11 m"),
    ]

    /// Zakresy FT8 (częstotliwość wybierania + 3 kHz) - rysowane na wierzchu.
    static let ft8: [Segment] = [1840, 3573, 5357, 7074, 10136, 14074, 18100, 21074, 24915, 28074, 50313]
        .map { Segment(low: k(Double($0)), high: k(Double($0) + 3), kind: .ft8) }

    /// Odcinki widoczne w zakresie low…high (główne, potem FT8).
    static func visible(low: Int, high: Int) -> [Segment] {
        (segments + ft8).filter { $0.high > low && $0.low < high }
    }
}

/// Pasek planu pasma pod waterfallem: kolorowe odcinki CW / cyfrowe / SSB / radiolatarnie / FT8 / radiofonia.
struct BandPlanStrip: View {
    let lowHz: Int
    let highHz: Int

    var body: some View {
        Canvas { context, size in
            guard highHz > lowHz else { return }
            let span = Double(highHz - lowHz)
            func x(_ hz: Int) -> CGFloat { CGFloat(Double(hz - lowHz) / span) * size.width }
            func rect(_ segment: BandPlan.Segment) -> CGRect? {
                let left = max(0, x(segment.low)), right = min(size.width, x(segment.high))
                return right - left >= 1 ? CGRect(x: left, y: 0, width: right - left, height: size.height) : nil
            }
            let visible = BandPlan.visible(low: lowHz, high: highHz)
            // najpierw wszystkie kolory, potem napisy - napis nie może zniknąć pod odcinkiem FT8
            for segment in visible {
                guard let r = rect(segment) else { continue }
                context.fill(Path(r), with: .color(segment.kind.color.opacity(0.75)))
                context.stroke(Path(CGRect(x: r.minX, y: 0, width: 0.5, height: size.height)),
                               with: .color(.black.opacity(0.5)), lineWidth: 0.5)
            }
            let ft8Rects = visible.filter { $0.kind == .ft8 }.compactMap(rect)
            for segment in visible {
                guard var r = rect(segment) else { continue }
                if segment.kind != .ft8 {
                    // najszersza część odcinka niezasłonięta przez FT8
                    var pieces = [r]
                    for cover in ft8Rects {
                        pieces = pieces.flatMap { piece -> [CGRect] in
                            guard piece.intersects(cover) else { return [piece] }
                            return [CGRect(x: piece.minX, y: 0, width: max(0, cover.minX - piece.minX), height: piece.height),
                                    CGRect(x: cover.maxX, y: 0, width: max(0, piece.maxX - cover.maxX), height: piece.height)]
                                .filter { $0.width >= 1 }
                        }
                    }
                    guard let widest = pieces.max(by: { $0.width < $1.width }) else { continue }
                    r = widest
                }
                let text = segment.name.map { segment.kind.label + " " + $0 } ?? segment.kind.label
                let resolved = context.resolve(Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(.white))
                if resolved.measure(in: r.size).width + 6 <= r.width {
                    context.draw(resolved, at: CGPoint(x: r.midX, y: r.midY))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .help(L("Plan pasma IARU Region 1 (uproszczony): CW, cyfrowe, SSB, radiolatarnie, FT8, radiofonia"))
    }
}
