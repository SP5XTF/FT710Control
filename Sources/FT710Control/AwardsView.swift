import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Okno „Dyplomy…” (okno dziennika): zakładki DXCC, WAZ, WPX, VUCC, POTA - ta sama siatka pasm, filtry,
/// wyszukiwanie i eksport CSV. Własna siatka zamiast Table - kolumn pasm bywa więcej niż 10.
struct AwardsView: View {
    @ObservedObject var store: LogbookStore
    @ObservedObject var cty = CTYDatabase.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qsl.countEQSL") private var countEQSL = false
    @AppStorage("qsl.countQRZ") private var countQRZ = false
    @AppStorage("awards.kind") private var kindRaw = AwardKind.dxcc.rawValue
    @AppStorage("dxcc.category") private var categoryRaw = DXCCCategory.mixed.rawValue
    @State private var filter = 0            // 0 wszystkie, 1 bez potwierdzenia
    @State private var sort = 0              // 0 kolejność, 1 nazwa, 2 pierwsze QSO
    @State private var search = ""

    private var kind: AwardKind { AwardKind(rawValue: kindRaw) ?? .dxcc }
    private var category: DXCCCategory { DXCCCategory(rawValue: categoryRaw) ?? .mixed }

    private var result: AwardResult {
        AwardCalculator.compute(kind, qsos: store.qsos, table: cty.table, category: category,
                                includeEQSL: countEQSL, includeQRZ: countQRZ)
    }

    private static let cell: CGFloat = 38
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let r = result
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Dyplomy")).font(.title2.bold())
                Picker("", selection: $kindRaw) {
                    ForEach(AwardKind.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 600)
                Text(kind.description).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if kind.hasCategories {
                    Picker("", selection: $categoryRaw) {
                        ForEach(DXCCCategory.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
            }
            if cty.table == nil, kind == .dxcc || kind == .waz {
                Text(L("Brak bazy krajów - zakładka ZAWODY → „Aktualizuj bazę krajów”."))
                    .foregroundStyle(.orange)
            }
            summary(r)
            controls
            grid(r)
            HStack {
                if kind.usesConfirmations {
                    Text(L("✓ potwierdzone · W zrobione, bez potwierdzenia · potwierdzenia: LoTW{1}{2}",
                           countEQSL ? " + eQSL" : "", countQRZ ? " + QRZ" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("✓ park upolowany na paśmie (POTA nie wymaga potwierdzeń QSL)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if kind.usesConfirmations {
                    Toggle(L("licz też eQSL"), isOn: $countEQSL)
                    Toggle(L("licz też QRZ Logbook"), isOn: $countQRZ)
                }
                Button(L("Eksport CSV…")) { exportCSV(r) }
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(minWidth: 1000, minHeight: 660)
    }

    // MARK: - Podsumowanie

    @ViewBuilder
    private func summary(_ r: AwardResult) -> some View {
        HStack(alignment: .top, spacing: 24) {
            switch kind {
            case .dxcc:
                figure(L("Zrobione"), "\(r.worked)", r.total.map { L("z {1} jednostek", $0) } ?? "")
                figure(L("Potwierdzone"), "\(r.confirmed)", dxccAward(r.confirmed, total: r.total ?? 340))
                figure(L("Bez potwierdzenia"), "\(r.worked - r.confirmed)", L("kraje do potwierdzenia"))
                if category == .mixed { figure("DXCC Challenge", "\(challenge(r))", L("kraj-pasmo potwierdzone, 160–6 m")) }
            case .waz:
                figure(L("Zrobione"), "\(r.worked)/40", r.missing.isEmpty ? L("wszystkie strefy") : L("brakuje: {1}", r.missing.joined(separator: ", ")))
                let unconfirmed = r.rows.filter { !$0.confirmed }.map(\.id).sorted()
                figure(L("Potwierdzone"), "\(r.confirmed)/40",
                       unconfirmed.isEmpty ? (r.confirmed == 40 ? L("dyplom WAZ - komplet") : "")
                                           : L("bez potwierdzenia: {1}", unconfirmed.joined(separator: ", ")))
            case .wpx:
                figure(L("Prefiksy zrobione"), "\(r.worked)", "")
                figure(L("Potwierdzone"), "\(r.confirmed)", "")
            case .vucc:
                figure(L("Kwadraty zrobione"), "\(r.worked)", L("pasma 6 m i wyżej"))
                ForEach(r.bands, id: \.self) { band in
                    figure(band, "\(r.confirmed(on: band))", L("potwierdzone · próg {1}", vuccThreshold(band)))
                }
            case .pota:
                figure(L("Upolowane parki"), "\(r.worked)", L("z dziennika (POTA_REF / SIG_INFO)"))
                figure(L("Łączności z parkami"), "\(r.rows.reduce(0) { $0 + $1.qsoCount })", "")
            case .iota:
                figure(L("Wyspy zrobione"), "\(r.worked)", L("pole IOTA (np. EU-005)"))
                figure(L("Potwierdzone"), "\(r.confirmed)", L("dyplom IOTA: od 100 potwierdzonych"))
            case .sota:
                figure(L("Szczyty"), "\(r.worked)", L("pole SOTA_REF (np. SP/BZ-057)"))
                figure(L("Łączności"), "\(r.rows.reduce(0) { $0 + $1.qsoCount })", "")
            case .wwff:
                figure(L("Obszary"), "\(r.worked)", L("pole WWFF_REF (np. SPFF-0001)"))
                figure(L("Łączności"), "\(r.rows.reduce(0) { $0 + $1.qsoCount })", "")
            case .pga:
                figure(L("Gminy"), "\(r.worked)", L("łączności z SP z kodem gminy w polu CNTY"))
                figure(L("Łączności"), "\(r.rows.reduce(0) { $0 + $1.qsoCount })", L("kod gminy: okno edycji QSO → Referencje dyplomów"))
            }
            if r.unknownCalls > 0, kind == .dxcc || kind == .waz || kind == .wpx {
                figure(L("Pominięte"), "\(r.unknownCalls)", kind == .wpx ? L("QSO bez prefiksu") : L("QSO nierozpoznane przez cty.dat"))
            }
            Spacer()
        }
    }

    /// DXCC: 100, potem co 50 do 300, Honor Roll - wszystkie aktualne jednostki oprócz najwyżej 9.
    private func dxccAward(_ confirmed: Int, total: Int) -> String {
        if confirmed < 100 { return L("do dyplomu DXCC brakuje {1}", 100 - confirmed) }
        let honorRoll = max(300, total - 9)
        if confirmed >= honorRoll { return L("poziom Honor Roll (od {1} z {2})", honorRoll, total) }
        let next = [150, 200, 250, 300, honorRoll].first { $0 > confirmed } ?? honorRoll
        return next == honorRoll ? L("dyplom DXCC zdobyty · do Honor Roll ({1}) brakuje {2}", honorRoll, honorRoll - confirmed)
                                 : L("dyplom DXCC zdobyty · do {1} brakuje {2}", next, next - confirmed)
    }

    private func challenge(_ r: AwardResult) -> Int {
        let bands: Set<String> = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m"]
        return r.rows.reduce(0) { $0 + $1.confirmedBands.intersection(bands).count }
    }

    /// VUCC (ARRL): 6 m i 2 m - 100 kwadratów, 1,25 m i 70 cm - 50, wyższe pasma - 25.
    private func vuccThreshold(_ band: String) -> Int {
        switch band {
        case "6m", "2m": return 100
        case "1.25m", "70cm": return 50
        default: return 25
        }
    }

    private func figure(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            if !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    // MARK: - Filtry

    private var controls: some View {
        HStack(spacing: 10) {
            TextField(L("Szukaj"), text: $search).frame(width: 200)
            if kind.usesConfirmations {
                Picker("", selection: $filter) {
                    Text(L("Wszystkie")).tag(0)
                    Text(L("Bez potwierdzenia")).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            Picker(L("Sortuj"), selection: $sort) {
                Text(L("Kolejność")).tag(0)
                Text(L("Nazwa")).tag(1)
                Text(L("Pierwsze QSO")).tag(2)
            }
            .frame(width: 200)
            Spacer()
        }
        .controlSize(.small)
    }

    private func visibleRows(_ r: AwardResult) -> [AwardRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return r.rows
            .filter { !kind.usesConfirmations || filter == 0 || !$0.confirmed }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.id.lowercased().hasPrefix(query)
                      || $0.detail.lowercased().contains(query) }
            .sorted { a, b in
                switch sort {
                case 1: return a.name < b.name
                case 2: return (a.firstDate ?? .distantFuture) < (b.firstDate ?? .distantFuture)
                default: return a.id < b.id
                }
            }
    }

    // MARK: - Siatka

    private var columnTitles: (id: String, name: String, detail: String) {
        switch kind {
        case .dxcc: return (L("Prefiks"), L("Kraj"), L("Kont."))
        case .waz: return (L("Strefa"), "", "")
        case .wpx: return (L("Prefiks"), "", "")
        case .vucc: return (L("Kwadrat"), "", "")
        case .pota: return (L("Park"), L("Pierwsze QSO"), L("Stacja"))
        case .iota: return (L("Wyspa"), L("Pierwsze QSO"), L("Stacja"))
        case .sota: return (L("Szczyt"), L("Pierwsze QSO"), L("Stacja"))
        case .wwff: return (L("Obszar"), L("Pierwsze QSO"), L("Stacja"))
        case .pga: return (L("Gmina"), L("Pierwsze QSO"), L("Stacja"))
        }
    }

    private func grid(_ r: AwardResult) -> some View {
        let rows = visibleRows(r)
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(r)
                totalsRow(r)
                Divider()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in entityRow(row, bands: r.bands) }
                }
            }
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
    }

    private func headerRow(_ r: AwardResult) -> some View {
        let t = columnTitles
        return HStack(spacing: 0) {
            Text(t.id).frame(width: 80, alignment: .leading)
            Text(t.name).frame(width: 200, alignment: .leading)
            Text(t.detail).frame(width: 70, alignment: .leading)
            Text("QSO").frame(width: 50, alignment: .trailing)
            Text("").frame(width: 12)
            ForEach(r.bands, id: \.self) { band in Text(band).frame(width: Self.cell) }
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func totalsRow(_ r: AwardResult) -> some View {
        HStack(spacing: 0) {
            Text(kind.usesConfirmations ? L("Razem (potw./zrob.)") : L("Razem")).frame(width: 350, alignment: .leading)
            Text(kind.usesConfirmations ? "\(r.confirmed)/\(r.worked)" : "\(r.worked)").frame(width: 50, alignment: .trailing)
            Text("").frame(width: 12)
            ForEach(r.bands, id: \.self) { band in
                Text(kind.usesConfirmations ? "\(r.confirmed(on: band))/\(r.worked(on: band))" : "\(r.worked(on: band))")
                    .frame(width: Self.cell)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }

    private func entityRow(_ row: AwardRow, bands: [String]) -> some View {
        let referenceKinds: [AwardKind] = [.pota, .iota, .sota, .wwff, .pga]
        let secondColumn = referenceKinds.contains(kind) ? (row.firstDate.map { Self.day.string(from: $0) } ?? "")
                                                         : row.name == row.id ? "" : row.name
        let highlight = kind.usesConfirmations && !row.confirmed
        return HStack(spacing: 0) {
            Text(row.id).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 80, alignment: .leading)
            Text(secondColumn).lineLimit(1).frame(width: 200, alignment: .leading)
                .foregroundStyle(highlight ? Color.orange : Theme.text)
            Text(row.detail).lineLimit(1).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            Text("\(row.qsoCount)").monospacedDigit().frame(width: 50, alignment: .trailing).foregroundStyle(.secondary)
            Text("").frame(width: 12)
            ForEach(bands, id: \.self) { band in
                cell(confirmed: kind.usesConfirmations ? row.confirmedBands.contains(band) : row.workedBands.contains(band),
                     worked: row.workedBands.contains(band))
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }

    private func cell(confirmed: Bool, worked: Bool) -> some View {
        Text(confirmed ? "✓" : worked ? "W" : "")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(confirmed ? Color.black : Color.white)
            .frame(width: Self.cell - 4, height: 16)
            .background(confirmed ? Theme.ok : worked ? Color.orange.opacity(0.7) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .frame(width: Self.cell)
    }

    // MARK: - Eksport

    /// CSV: id, nazwa, szczegół, QSO, potwierdzone, kolumna na pasmo (C = potwierdzone, W = zrobione).
    private func exportCSV(_ r: AwardResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(kind.name)" + (kind.hasCategories ? "-\(category.rawValue)" : "") + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [(["ID", "Name", "Detail", "QSOs", "Confirmed"] + r.bands).joined(separator: ",")]
        for row in r.rows.sorted(by: { $0.id < $1.id }) {
            let cells = r.bands.map { row.confirmedBands.contains($0) ? "C" : row.workedBands.contains($0) ? "W" : "" }
            lines.append(([row.id, quoted(row.name), quoted(row.detail), "\(row.qsoCount)", row.confirmed ? "Y" : "N"] + cells)
                .joined(separator: ","))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
