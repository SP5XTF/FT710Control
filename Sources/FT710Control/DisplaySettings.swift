import SwiftUI
import AppKit

/// Paleta waterfalla: punkty (położenie 0…1, kolor RGB 0…1).
enum WaterfallPalette: String, CaseIterable, Identifiable {
    case classic, turbo, inferno, fire, ocean, phosphor, rainbow, gray

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: return L("Klasyczna")
        case .turbo: return L("Turbo (SDR)")
        case .inferno: return L("Inferno")
        case .fire: return L("Ogień")
        case .ocean: return L("Morska")
        case .phosphor: return L("Zielony fosfor")
        case .rainbow: return L("Tęcza")
        case .gray: return L("Skala szarości")
        }
    }

    var stops: [(t: Double, r: Double, g: Double, b: Double)] {
        switch self {
        case .classic:
            return [(0, 0, 0, 0), (0.25, 0, 0, 0.55), (0.45, 0, 0.6, 0.9), (0.65, 0.1, 0.85, 0.2),
                    (0.8, 1, 0.9, 0), (0.92, 1, 0.25, 0), (1, 1, 1, 1)]
        case .turbo:
            // „Turbo” (Google) - jak w nowoczesnych programach SDR: szum granatowo-niebieski, sygnały zielone → czerwone
            // dół przyciemniony: szum (ok. 25% skali przy automatycznym tle) granatowy, sygnały wyraźnie odcinają się od tła
            return [(0, 0, 0, 0.04), (0.15, 0.02, 0.04, 0.22), (0.28, 0.06, 0.14, 0.48), (0.38, 0.12, 0.38, 0.85),
                    (0.47, 0.10, 0.70, 0.95), (0.56, 0.15, 0.90, 0.70), (0.65, 0.45, 0.98, 0.35), (0.74, 0.85, 0.92, 0.18),
                    (0.83, 0.99, 0.65, 0.18), (0.92, 0.95, 0.33, 0.08), (1, 0.75, 0.06, 0.03)]
        case .inferno:
            // „Inferno” - fiolet → pomarańcz → biel (jak w analizatorach widma)
            return [(0, 0, 0, 0.02), (0.13, 0.09, 0.04, 0.22), (0.25, 0.26, 0.04, 0.41), (0.38, 0.42, 0.09, 0.43),
                    (0.5, 0.58, 0.15, 0.40), (0.63, 0.74, 0.22, 0.33), (0.75, 0.87, 0.32, 0.23), (0.88, 0.96, 0.58, 0.04),
                    (1, 0.99, 1, 0.65)]
        case .fire:
            return [(0, 0, 0, 0), (0.3, 0.35, 0, 0.05), (0.55, 0.85, 0.15, 0), (0.75, 1, 0.55, 0),
                    (0.9, 1, 0.9, 0.3), (1, 1, 1, 1)]
        case .ocean:
            return [(0, 0, 0, 0.02), (0.3, 0, 0.12, 0.35), (0.55, 0, 0.45, 0.65), (0.75, 0.1, 0.8, 0.85),
                    (0.9, 0.6, 1, 1), (1, 1, 1, 1)]
        case .phosphor:
            return [(0, 0, 0, 0), (0.3, 0, 0.18, 0.02), (0.6, 0.05, 0.6, 0.1), (0.85, 0.4, 1, 0.35), (1, 0.9, 1, 0.8)]
        case .rainbow:
            return [(0, 0, 0, 0), (0.2, 0.2, 0, 0.5), (0.35, 0, 0.2, 1), (0.5, 0, 0.9, 0.9), (0.65, 0.1, 0.95, 0.1),
                    (0.8, 1, 0.95, 0), (0.92, 1, 0.3, 0), (1, 1, 0, 0.6)]
        case .gray:
            return [(0, 0, 0, 0), (1, 1, 1, 1)]
        }
    }

    /// Kolor dla poziomu 0…1.
    func color(at t: Double) -> (r: Double, g: Double, b: Double) {
        let s = stops
        let x = min(max(t, 0), 1)
        var k = 1
        while k < s.count - 1 && s[k].t < x { k += 1 }
        let a = s[k - 1], b = s[k]
        let f = min(max((x - a.t) / max(b.t - a.t, 0.0001), 0), 1)
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }

    /// Tablica 256 kolorów 0xAARRGGBB (do obrazu waterfalla).
    func lookupTable() -> [UInt32] {
        (0..<256).map { i in
            let c = color(at: Double(i) / 255)
            return 0xFF00_0000 | (UInt32(c.r * 255) << 16) | (UInt32(c.g * 255) << 8) | UInt32(c.b * 255)
        }
    }

    var swiftUIGradient: Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: Color(red: $0.r, green: $0.g, blue: $0.b), location: $0.t) })
    }
}

enum WaterfallMode: String, CaseIterable, Identifiable {
    case flat, threeD
    var id: String { rawValue }
    var name: String { self == .flat ? L("2D – waterfall") : L("3D – perspektywa") }
}

/// Ustawienia wyglądu skopu (zakładka EKRAN), zapamiętywane. Warstwa rysująca skop subskrybuje je
/// bezpośrednio - zmiana nie przelicza okna SwiftUI.
@MainActor
final class DisplaySettings: ObservableObject {
    static let shared = DisplaySettings()

    @Published var palette: WaterfallPalette { didSet { save("palette", palette.rawValue) } }
    @Published var audioSamePalette: Bool { didSet { save("audioSamePalette", audioSamePalette) } }
    @Published var mode: WaterfallMode { didSet { save("mode", mode.rawValue) } }
    /// Udział linii widma w wysokości skopu (reszta to waterfall).
    @Published var spectrumFraction: Double { didSet { save("spectrumFraction", spectrumFraction) } }
    @Published var traceColor: Color { didSet { saveColor() } }
    @Published var traceFill: Bool { didSet { save("traceFill", traceFill) } }
    /// Wypełnienie pod linią widma kolorami palety waterfalla (zamiast koloru linii).
    @Published var fillWithPalette: Bool { didSet { save("fillWithPalette", fillWithPalette) } }
    /// Druga, cienka linia szczytów, powoli opadająca.
    @Published var peakHold: Bool { didSet { save("peakHold", peakHold) } }
    /// Skala dB z lewej strony widma (względna: 0 dB = góra skali).
    @Published var dbScale: Bool { didSet { save("dbScale", dbScale) } }
    /// Znaczniki czasu (UTC) na waterfallu.
    @Published var timeStamps: Bool { didSet { save("timeStamps", timeStamps) } }
    /// Pasek planu pasma (IARU R1) pod waterfallem.
    @Published var bandPlan: Bool { didSet { save("bandPlan", bandPlan) } }
    /// 3D: liczba linii w głąb, wysokość szczytów (część wysokości), perspektywa (zwężenie w głąb).
    @Published var depth3D: Double { didSet { save("depth3D", depth3D) } }
    @Published var height3D: Double { didSet { save("height3D", height3D) } }
    @Published var tilt3D: Double { didSet { save("tilt3D", tilt3D) } }
    /// Prędkość przesuwu waterfalla i widoku 3D: nowa linia co 1 / 2 / 4 / 8 ramek widma.
    @Published var speed: Int { didSet { save("speed", speed) } }
    static let speeds: [(value: Int, name: String)] = [(1, "szybko"), (2, "średnio"), (4, "wolno"), (8, "bardzo wolno")]

    private static let prefix = "display."
    static let defaultTrace = Color(red: 0.2, green: 0.95, blue: 0.3)

    private init() {
        let d = UserDefaults.standard
        let p = Self.prefix
        palette = WaterfallPalette(rawValue: d.string(forKey: p + "palette") ?? "") ?? .classic
        audioSamePalette = d.object(forKey: p + "audioSamePalette") as? Bool ?? true
        mode = WaterfallMode(rawValue: d.string(forKey: p + "mode") ?? "") ?? .flat
        spectrumFraction = d.object(forKey: p + "spectrumFraction") as? Double ?? 0.3
        traceFill = d.object(forKey: p + "traceFill") as? Bool ?? true
        fillWithPalette = d.object(forKey: p + "fillWithPalette") as? Bool ?? false
        peakHold = d.object(forKey: p + "peakHold") as? Bool ?? true
        dbScale = d.object(forKey: p + "dbScale") as? Bool ?? true
        timeStamps = d.object(forKey: p + "timeStamps") as? Bool ?? true
        bandPlan = d.object(forKey: p + "bandPlan") as? Bool ?? true
        depth3D = d.object(forKey: p + "depth3D") as? Double ?? 50
        height3D = d.object(forKey: p + "height3D") as? Double ?? 0.45
        tilt3D = d.object(forKey: p + "tilt3D") as? Double ?? 0.35
        let savedSpeed = d.integer(forKey: p + "speed")
        speed = [1, 2, 4, 8].contains(savedSpeed) ? savedSpeed : 1
        if let rgb = d.array(forKey: p + "traceColor") as? [Double], rgb.count == 3 {
            traceColor = Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        } else {
            traceColor = Self.defaultTrace
        }
    }

    var traceNSColor: NSColor { NSColor(traceColor).usingColorSpace(.sRGB) ?? .systemGreen }

    func resetToDefaults() {
        palette = .classic
        audioSamePalette = true
        mode = .flat
        spectrumFraction = 0.3
        traceColor = Self.defaultTrace
        traceFill = true
        fillWithPalette = false
        peakHold = true
        dbScale = true
        timeStamps = true
        bandPlan = true
        depth3D = 50
        height3D = 0.45
        tilt3D = 0.35
        speed = 1
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }

    private func saveColor() {
        let c = traceNSColor
        save("traceColor", [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)])
    }
}
