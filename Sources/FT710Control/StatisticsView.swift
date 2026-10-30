import SwiftUI
import Charts

/// Statystyka dziennika (okno dziennika → „Statystyki…”): podsumowanie i wykresy - lata, pasma, emisje,
/// kontynenty, godziny UTC; okres do wyboru.
struct StatisticsView: View {
    @ObservedObject var store: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stats.period") private var periodRaw = QSOMapPeriod.all.rawValue

    private var period: QSOMapPeriod { QSOMapPeriod(rawValue: periodRaw) ?? .all }

    struct Bar: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    struct Summary {
        var qsos = 0, calls = 0, entities = 0, days = 0
        var first: Date?, last: Date?
        var bestDay = "", bestDayCount = 0
        var years: [Bar] = [], bands: [Bar] = [], modes: [Bar] = [], continents: [Bar] = [], hours: [Bar] = []
    }

    private var summary: Summary {
        let since = period.start
        let list = store.qsos.filter { since == nil || $0.start >= since! }
        var s = Summary()
        s.qsos = list.count
        s.calls = Set(list.map { QRZClient.baseCall($0.call) }).count
        let table = CTYDatabase.shared.table
        var entities = Set<String>()
        var continents: [String: Int] = [:]
        for q in list {
            let match = table?.lookup(q.call)
            if let match { entities.insert(CTYTable.dxccKey(match)) }
            let cont = q.extra["CONT"] ?? match?.continent ?? ""
            if !cont.isEmpty { continents[cont, default: 0] += 1 }
        }
        s.entities = entities.count
        s.first = list.map(\.start).min()
        s.last = list.map(\.start).max()

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = utc.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let perDay = Dictionary(grouping: list) { dayFormatter.string(from: $0.start) }.mapValues(\.count)
        s.days = perDay.count
        if let best = perDay.max(by: { $0.value < $1.value }) { s.bestDay = best.key; s.bestDayCount = best.value }

        let years = Dictionary(grouping: list) { utc.component(.year, from: $0.start) }.mapValues(\.count)
        s.years = years.keys.sorted().map { Bar(label: String($0), count: years[$0] ?? 0) }
        let bands = Dictionary(grouping: list) { $0.band.lowercased() }.mapValues(\.count)
        s.bands = AwardCalculator.orderedBands(Set(bands.keys.filter { !$0.isEmpty })).map { Bar(label: $0, count: bands[$0] ?? 0) }
        let modes = Dictionary(grouping: list) { QSOMapView.modeGroup($0) }.mapValues(\.count)
        s.modes = QSOMapView.modeGroups.filter { modes[$0] != nil }
            .map { Bar(label: QSOMapView.modeGroupName($0), count: modes[$0] ?? 0) }
        s.continents = ["EU", "AS", "NA", "SA", "AF", "OC", "AN"].filter { continents[$0] != nil }
            .map { Bar(label: $0, count: continents[$0] ?? 0) }
        let hours = Dictionary(grouping: list) { utc.component(.hour, from: $0.start) }.mapValues(\.count)
        s.hours = (0..<24).map { Bar(label: String(format: "%02d", $0), count: hours[$0] ?? 0) }
        return s
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Statystyki dziennika")).font(.title2.bold())
                Picker(L("Okres"), selection: $periodRaw) {
                    ForEach(QSOMapPeriod.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .frame(width: 220)
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            HStack(spacing: 22) {
                figure(L("Łączności"), "\(s.qsos)")
                figure(L("Różne stacje"), "\(s.calls)")
                figure(L("Kraje DXCC"), "\(s.entities)")
                figure(L("Dni z łącznościami"), "\(s.days)")
                figure(L("Najlepszy dzień"), s.bestDayCount > 0 ? "\(s.bestDayCount)" : "–", note: s.bestDay)
                if let first = s.first, let last = s.last {
                    figure(L("Okres w dzienniku"), Self.day.string(from: first), note: L("do {1}", Self.day.string(from: last)))
                }
                Spacer()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    if period == .all || s.years.count > 1 { chart(L("Łączności w latach"), s.years, color: .blue) }
                    chart(L("Pasma"), s.bands, color: .orange)
                    chart(L("Emisje"), s.modes, color: .green)
                    chart(L("Kontynenty"), s.continents, color: .purple)
                    chart(L("Godziny (UTC)"), s.hours, color: .teal)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 700)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func figure(_ title: String, _ value: String, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func chart(_ title: String, _ bars: [Bar], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if bars.isEmpty {
                Text(L("Brak danych")).foregroundStyle(.secondary).frame(height: 220)
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value(title, bar.label), y: .value(L("QSO"), bar.count))
                        .foregroundStyle(color.gradient)
                        .annotation(position: .top) {
                            if bars.count <= 12 {
                                Text("\(bar.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().font(.caption2) }
                }
                .frame(height: 220)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
