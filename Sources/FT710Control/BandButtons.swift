import SwiftUI

/// Częstotliwości startowe przycisków pasm w modułach CW, RTTY i SSTV (Region 1) i tryb radia dla każdej.
enum ModeBandPlan {
    case cw, rtty, sstv

    var key: String {
        switch self {
        case .cw: return "cw"
        case .rtty: return "rtty"
        case .sstv: return "sstv"
        }
    }

    /// RTTY: środek aktywności (częstotliwość mark w eterze) + 2,125 kHz - radio w DATA-L z tonem mark 2125 Hz
    /// stawia sygnały na tonie mark. CW: początek odcinków CW. SSTV: typowe częstotliwości wywoławcze.
    var defaults: [Int] {
        switch self {
        case .cw:
            return [1_830_000, 3_530_000, 7_025_000, 10_115_000, 14_030_000, 18_080_000, 21_030_000,
                    24_900_000, 28_030_000, 50_090_000]
        case .rtty:
            return [1_838_000, 3_590_000, 7_040_000, 10_140_000, 14_085_000, 18_102_000, 21_085_000,
                    24_920_000, 28_085_000].map { $0 + 2_125 }
        case .sstv:
            return [3_733_000, 7_165_000, 14_230_000, 18_160_000, 21_340_000, 24_975_000, 28_680_000, 50_680_000]
        }
    }

    /// Kod trybu FT-710: CW-U „3”, DATA-L „8”, DATA-U „C”. SSTV jak fonia: DATA-L poniżej 10 MHz, DATA-U powyżej.
    func modeCode(for hz: Int) -> String {
        switch self {
        case .cw: return "3"
        case .rtty: return "8"
        case .sstv: return hz < 10_000_000 ? "8" : "C"
        }
    }

    var modeName: String {
        switch self {
        case .cw: return "CW-U"
        case .rtty: return "DATA-L"
        case .sstv: return L("DATA-L / DATA-U")
        }
    }
}

/// Pamięć pasma osobno dla modułu: ostatnia częstotliwość na każdym paśmie (jak „band stacking” w radiu).
@MainActor
enum ModeBandMemory {
    private static func key(_ plan: ModeBandPlan, _ band: String) -> String { "bandmem.\(plan.key).\(band)" }

    static func frequency(_ plan: ModeBandPlan, band: String, fallback: Int) -> Int {
        let saved = UserDefaults.standard.integer(forKey: key(plan, band))
        return saved > 0 && LogFrequency.band(for: saved) == band ? saved : fallback
    }

    static func remember(_ plan: ModeBandPlan, hz: Int) {
        guard let band = LogFrequency.band(for: hz) else { return }
        UserDefaults.standard.set(hz, forKey: key(plan, band))
    }

    static func forget(_ plan: ModeBandPlan, band: String) {
        UserDefaults.standard.removeObject(forKey: key(plan, band))
    }
}

/// Przyciski pasm w panelu strojenia (CW, RTTY, SSTV): kliknięcie stroi radio na ostatnią częstotliwość modułu
/// na tym paśmie (albo domyślną) i ustawia tryb; prawy przycisk - powrót do domyślnej.
struct ModeBandButtons: View {
    let plan: ModeBandPlan
    @ObservedObject var cat: CATClient
    /// Wywoływane przed strojeniem (np. przerwanie nadawania).
    var beforeTune: () -> Void = {}

    var body: some View {
        ColumnGrid(plan.defaults, id: \.self, columns: 4, spacing: 4) { hz in
                let band = LogFrequency.band(for: hz) ?? ""
                let target = ModeBandMemory.frequency(plan, band: band, fallback: hz)
                Button(band) { tune(band: band, fallback: hz) }
                    .buttonStyle(RigButtonStyle(selected: currentBand == band, height: 20, fontSize: 10))
                    .disabled(!cat.isConnected)
                    .help(L("{1} MHz, {2} · prawy przycisk: wróć do {3} MHz", mhz(target), plan.modeName, mhz(hz)))
                    .contextMenu {
                        Button(L("Wróć do domyślnej ({1} MHz)", mhz(hz))) {
                            ModeBandMemory.forget(plan, band: band)
                            tune(band: band, fallback: hz)
                        }
                    }
        }
    }

    private var currentBand: String? { LogFrequency.band(for: cat.activeFreq) }

    private func mhz(_ hz: Int) -> String { String(format: "%.3f", Double(hz) / 1_000_000) }

    private func tune(band: String, fallback: Int) {
        guard cat.isConnected else { return }
        beforeTune()
        // zapamiętaj, gdzie byłeś na bieżącym paśmie - jeśli to pasmo modułu i radio w jego trybie
        let current = cat.activeFreq
        if let currentBand, plan.defaults.contains(where: { LogFrequency.band(for: $0) == currentBand }),
           cat.modeCode == plan.modeCode(for: current) {
            ModeBandMemory.remember(plan, hz: current)
        }
        let target = ModeBandMemory.frequency(plan, band: band, fallback: fallback)
        cat.setActiveFrequency(target)
        let code = plan.modeCode(for: target)
        if cat.modeCode != code { cat.setMode(code) }
    }
}
