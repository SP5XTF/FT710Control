import SwiftUI
import AppKit
import Combine

/// Wskaźnik łukowy (S, PO, SWR, COMP, ALC) rysowany w AppKit. Sam subskrybuje wartości z radia (CATMeters)
/// i przerysowuje tylko siebie - zmiana wskazówki nie uruchamia aktualizacji SwiftUI. Wskaźniki w SwiftUI,
/// nawet w odizolowanym NSHostingView, kosztowały przy każdej zmianie przeliczenie dużej części okna
/// (test: ukrycie wskaźników i VFO obniżyło opóźnienie głównego wątku z ~470 do ~24 ms).
struct MeterGauge: NSViewRepresentable {
    let kind: MeterGaugeNSView.Kind
    let meters: CATMeters
    let transmitting: Bool

    func makeNSView(context: Context) -> MeterGaugeNSView {
        MeterGaugeNSView(kind: kind, meters: meters)
    }

    func updateNSView(_ view: MeterGaugeNSView, context: Context) {
        view.transmitting = transmitting
    }
}

final class MeterGaugeNSView: NSView {
    enum Kind {
        case s, po, swr, comp, alc
    }

    private let kind: Kind
    private var raw = 0

    // Kolory i czcionki tworzone raz (nie przy każdym rysowaniu). Czcionki przez funkcje zwracające wartość
    // opcjonalną z zapasem - pusta czcionka w słowniku atrybutów kończyła program („attempt to insert nil”).
    private enum Palette {
        static let panel = NSColor(srgbRed: 0.05, green: 0.058, blue: 0.07, alpha: 1)
        static let border = NSColor(white: 1, alpha: 0.08)
        static let accent = NSColor(srgbRed: 0.25, green: 0.62, blue: 1.0, alpha: 1)
        static let header = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.28, alpha: 1)
        static let text = NSColor(white: 0.92, alpha: 1)
        static let dim = NSColor(white: 0.52, alpha: 1)
        static let tx = NSColor(srgbRed: 0.93, green: 0.27, blue: 0.24, alpha: 1)
    }
    private static func font(_ names: [String], size: CGFloat) -> NSFont { SafeFont.make(names, size: size) }
    private static let tickAttributes: [NSAttributedString.Key: Any] = [
        .font: font(["HelveticaNeue", "Helvetica"], size: 8), .foregroundColor: Palette.dim]
    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: font(["HelveticaNeue-Bold", "Helvetica-Bold"], size: 12), .foregroundColor: Palette.header]
    private static let valueAttributes: [NSAttributedString.Key: Any] = [
        .font: font(["Menlo-Regular", "Monaco"], size: 14), .foregroundColor: Palette.text]
    private static let valueDimAttributes: [NSAttributedString.Key: Any] = [
        .font: font(["Menlo-Regular", "Monaco"], size: 14), .foregroundColor: Palette.dim]
    private var subscription: AnyCancellable?

    var transmitting = false {
        didSet { if transmitting != oldValue { needsDisplay = true } }
    }

    init(kind: Kind, meters: CATMeters) {
        self.kind = kind
        super.init(frame: .zero)
        raw = Self.value(kind, meters.shown)
        subscription = meters.$shown.sink { [weak self] values in
            guard let self else { return }
            let value = Self.value(self.kind, values)
            if value != self.raw {
                self.raw = value
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nie jest używany") }

    override var isFlipped: Bool { true }                       // y w dół, jak w SwiftUI

    private static func value(_ kind: Kind, _ v: CATMeters.Values) -> Int {
        switch kind {
        case .s: return v.s
        case .po: return v.po
        case .swr: return v.swr
        case .comp: return v.comp
        case .alc: return v.alc
        }
    }

    private var title: String {
        switch kind {
        case .s: return "S"
        case .po: return "PO"
        case .swr: return "SWR"
        case .comp: return "COMP"
        case .alc: return "ALC"
        }
    }

    private var ticks: [(Double, String)] {
        switch kind {
        case .s: return ContentView.sTicks
        case .po: return ContentView.poTicks
        case .swr: return ContentView.swrTicks
        case .comp, .alc: return ContentView.percentTicks
        }
    }

    private var redFrom: Double? {
        switch kind {
        case .swr: return ContentView.position(3.0, MeterCalibration.swr)
        case .alc: return 0.7
        default: return nil
        }
    }

    private var active: Bool { kind == .s ? !transmitting : transmitting }

    private var valueText: String {
        switch kind {
        case .s: return MeterCalibration.sMeterText(raw: raw)
        case .po: return MeterCalibration.powerText(raw: raw)
        case .swr: return MeterCalibration.swrText(raw: raw)
        case .comp, .alc: return MeterCalibration.percentText(raw: raw)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        // tło i ramka panelu (jak RoundedRectangle w SwiftUI)
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Palette.panel.setFill()
        panel.fill()
        Palette.border.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let center = CGPoint(x: size.width / 2, y: size.height * 0.86)
        let radius = min(size.width * 0.40, size.height * 0.66)
        func point(_ f: Double, _ r: CGFloat) -> CGPoint {
            let angle = (205 + 130 * f) * .pi / 180              // od lewej-dołu przez górę do prawej-dołu
            return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        }
        func strokeArc(_ from: Double, _ to: Double, color: NSColor, width: CGFloat) {
            let steps = max(2, Int((to - from) * 60))
            context.beginPath()
            for i in 0...steps {
                let p = point(from + (to - from) * Double(i) / Double(steps), radius)
                if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.strokePath()
        }

        strokeArc(0, 1, color: NSColor.white.withAlphaComponent(0.12), width: 3)
        if let redFrom { strokeArc(redFrom, 1, color: Palette.tx.withAlphaComponent(0.75), width: 3) }
        let f = min(max(Double(raw) / 255, 0), 1)
        if active && f > 0.001 {
            let red = redFrom.map { f >= $0 } ?? false
            strokeArc(0, f, color: red ? Palette.tx : Palette.accent, width: 4)
            context.beginPath()
            context.move(to: point(f, radius * 0.55))
            context.addLine(to: point(f, radius * 1.08))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        for (position, label) in ticks {
            context.beginPath()
            context.move(to: point(position, radius - 4))
            context.addLine(to: point(position, radius + 3))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            let text = NSAttributedString(string: label, attributes: Self.tickAttributes)
            let at = point(position, radius + 11)
            let textSize = text.size()
            text.draw(at: CGPoint(x: at.x - textSize.width / 2, y: at.y - textSize.height / 2))
        }

        NSAttributedString(string: title, attributes: Self.titleAttributes).draw(at: CGPoint(x: 6, y: 6))
        let value = NSAttributedString(string: active ? valueText : "–",
                                       attributes: active ? Self.valueAttributes : Self.valueDimAttributes)
        let valueSize = value.size()
        value.draw(at: CGPoint(x: (size.width - valueSize.width) / 2, y: size.height - valueSize.height - 4))
    }
}


/// Czcionka do słowników atrybutów AppKit - zawsze niepusta: funkcje zwracające wartość opcjonalną, z zapasem.
/// (Systemowe fabryki czcionek są w Swifcie „nieopcjonalne”; pusta wartość w słowniku kończy program.)
enum SafeFont {
    static func make(_ names: [String], size: CGFloat) -> NSFont {
        for name in names { if let font = NSFont(name: name, size: size) { return font } }
        return NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.labelFont(ofSize: size)
    }
}
