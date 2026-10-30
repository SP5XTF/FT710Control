import Foundation
import SwiftUI
import Combine

/// Diagnostyka płynności. Liczniki odświeżeń są zbierane przez cały czas, a raz na sekundę
/// osobny zegar (niezależny od przerysowań okna) zamienia je na wartości „na sekundę”
/// i mierzy opóźnienie głównego wątku. Wynik pokazuje mały, odizolowany widok w pasku stanu.
enum RenderStats {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func tick(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    /// Zwraca liczniki i je zeruje.
    static func take() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let result = counts
        counts.removeAll(keepingCapacity: true)
        return result
    }
}

@MainActor
final class RenderStatsModel: ObservableObject {
    static let shared = RenderStatsModel()

    @Published private(set) var text = ""

    private var timer: Timer?
    private var lastSample = Date()
    /// Najgorsze w ostatniej sekundzie spóźnienie głównego wątku (ms).
    private var worstLagMs = 0.0
    private var lagTimer: Timer?

    private var expected = Date()

    private init() {
        // Co 50 ms sprawdzamy, o ile spóźnił się zegar - to opóźnienie głównego wątku
        // (gdy główny wątek jest zajęty rysowaniem, zegar wykonuje się później).
        lagTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measureLag() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func measureLag() {
        let now = Date()
        let lag = max(0, now.timeIntervalSince(expected) - 0.05) * 1000
        expected = now
        worstLagMs = max(worstLagMs, lag)
    }

    private func sample() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastSample), 0.001)
        lastSample = now
        let counts = RenderStats.take()
        func rate(_ key: String) -> Int { Int((Double(counts[key] ?? 0) / elapsed).rounded()) }
        text = L("UI okno {1} · skop {2} · linia {3} · wf {4} · ramki {5} /s · opóźnienie {6} ms",
                 rate("okno"), rate("skop"), rate("linia"), rate("wf"), rate("ramki"), Int(worstLagMs.rounded()))
        worstLagMs = 0
    }
}

/// Odczyt diagnostyczny w pasku stanu - obserwuje tylko model statystyk (raz na sekundę).
struct RenderStatsView: View {
    @ObservedObject var stats = RenderStatsModel.shared

    var body: some View {
        Text(stats.text)
            .monospacedDigit()
            .foregroundStyle(Theme.dim)
            .help(L("Ile razy na sekundę odświeża się okno, panel skopu, linia widma i waterfall, ile ramek skopu przychodzi z radia oraz największe spóźnienie głównego wątku w ostatniej sekundzie"))
    }
}
