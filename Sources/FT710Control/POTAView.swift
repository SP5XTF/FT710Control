import SwiftUI
import AppKit

/// Zakładka POTA: statystyki użytkownika (znak edytowalny, domyślnie z profilu), spoty aktywatorów i aktywacje
/// zakończone w ostatniej godzinie; sortowanie po kolumnach, filtr pasma i trybu.
/// Kliknięcie: radio na częstotliwość i tryb aktywatora, znak i park do dziennika; dwuklik: także zakładka DZIENNIK.
struct POTAView: View {
    @ObservedObject var pota: POTAManager
    @ObservedObject var cat: CATClient
    @State private var selection: POTASpot.ID?
    @State private var sortOrder = [KeyPathComparator(\POTASpot.spotTime, order: .reverse)]
    @State private var sortChoice = 0

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statsPanel
            filters
            table
            legend
        }
        .onAppear { pota.start() }
        .onChange(of: selection) { id in
            if let id, let spot = allRows.first(where: { $0.id == id }) { pota.select(spot) }
        }
    }

    // MARK: - Statystyki użytkownika

    private var statsPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("STATYSTYKI POTA")).font(.caption.bold()).foregroundStyle(Theme.header)
                HStack(spacing: 6) {
                    TextField(pota.effectiveStatsCall.isEmpty ? L("Znak") : pota.effectiveStatsCall, text: $pota.statsCall)
                        .frame(width: 110)
                        .onSubmit { pota.refreshStats() }
                        .help(L("Znak do statystyk - puste pole = znak z profilu stacji"))
                    Button(L("Pobierz")) { pota.refreshStats() }
                    Button(L("Profil na pota.app")) {
                        if let url = URL(string: "https://pota.app/#/profile/" + pota.effectiveStatsCall) { NSWorkspace.shared.open(url) }
                    }
                    .disabled(pota.effectiveStatsCall.isEmpty)
                }
                .controlSize(.small)
                if !pota.statsStatus.isEmpty {
                    Text(Lr(pota.statsStatus)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = pota.stats {
                statBlock(L("Operator"), [s.callsign, s.name])
                statBlock(L("Aktywator"), [L("aktywacje: {1} (prób {2})", s.activations, s.attemptActivations),
                                          L("parki: {1}", s.activatedParks), L("QSO: {1}", s.activatorQSOs)])
                statBlock(L("Łowca"), [L("parki: {1}", s.huntedParks), L("QSO: {1}", s.hunterQSOs)])
                statBlock(L("Dyplomy"), [L("dyplomy: {1}", s.awards), L("wyróżnienia: {1}", s.endorsements)])
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button(L("Odśwież spoty")) { pota.refreshSpots() }.controlSize(.small)
                if let last = pota.lastUpdate {
                    Text(L("aktualizacja {1} UTC · co 60 s", Self.timeFormatter.string(from: last)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !pota.spotsStatus.isEmpty {
                    Text(Lr(pota.spotsStatus)).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func statBlock(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: - Filtry

    private var bands: [String] {
        var seen: [String] = []
        for spot in (pota.spots + pota.ended).sorted(by: { $0.frequencyHz < $1.frequencyHz })
        where !spot.band.isEmpty && !seen.contains(spot.band) { seen.append(spot.band) }
        return seen
    }

    /// Filtry jak na pota.app: pasmo, emisja, program, wiek, sortowanie, QRT, ukryte, upolowane, wyróżnianie, ⏸.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker(L("Pasmo"), selection: $pota.bandFilter) {
                    Text(L("Wszystkie ({1})", baseRows.count)).tag("")
                    ForEach(bands, id: \.self) { band in
                        Text("\(band) (\(baseRows.filter { $0.band == band }.count))").tag(band)
                    }
                }
                .frame(width: 170)
                Picker(L("Emisja"), selection: $pota.modeFilter) {
                    Text(L("Wszystkie ({1})", baseRows.count)).tag("")
                    Text("CW (\(count(mode: "CW")))").tag("CW")
                    Text(L("Fonia ({1})", count(mode: "SSB"))).tag("SSB")
                    Text(L("Cyfrowe ({1})", count(mode: "DATA"))).tag("DATA")
                }
                .frame(width: 170)
                Picker(L("Program"), selection: $pota.programFilter) {
                    Text(L("Wszystkie ({1})", baseRows.count)).tag("")
                    ForEach(programs, id: \.self) { program in
                        Text("\(program) (\(baseRows.filter { POTAManager.program(of: $0) == program }.count))").tag(program)
                    }
                }
                .frame(width: 170)
                Picker(L("Wiek"), selection: $pota.maxAgeMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text(L("{1} min", $0)).tag($0) }
                    Text(L("wszystkie")).tag(0)
                }
                .frame(width: 130)
                .help(L("Tylko spoty nie starsze niż… (czas ostatniego spotu aktywacji)"))
                Picker(L("Sortowanie"), selection: $sortChoice) {
                    Text(L("Czas")).tag(0)
                    Text(L("Częstotliwość")).tag(1)
                    Text(L("Aktywator")).tag(2)
                    Text(L("Park")).tag(3)
                    Text(L("Tryb")).tag(4)
                }
                .frame(width: 190)
                Spacer()
                refreshControl
            }
            HStack(spacing: 14) {
                labeled(L("QRT / zakończone:"), $pota.showEnded,
                        help: L("Aktywacje, które zniknęły z listy albo zgłosiły QRT - widziane, gdy program był uruchomiony (do 1 h)"))
                labeled(L("Ukryte:"), $pota.showHidden,
                        help: L("Aktywacje ukryte ręcznie (menu prawego przycisku → Ukryj); wracają po 24 h"))
                labeled(L("Upolowane:"), Binding(get: { !pota.onlyNewParks }, set: { pota.onlyNewParks = !$0 }),
                        help: L("Parki, które już masz w dzienniku (w emisji z „Wyróżnianie”)"))
                HStack(spacing: 4) {
                    Text(L("Wyróżnianie:")).font(.caption.bold())
                    Picker("", selection: $pota.highlightCategory) {
                        ForEach(DXCCCategory.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                .help(L("„Nowy park” liczony w tej emisji - np. CW: park zrobiony tylko fonią nadal jest nowy"))
                Spacer()
                Text(L("widoczne: {1} · aktywne: {2} · zakończone: {3}", rows.count, pota.spots.count, pota.ended.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .onChange(of: sortChoice) { choice in sortOrder = Self.sortOrder(for: choice) }
    }

    /// „Pokaż / Ukryj” jak na pota.app.
    private func labeled(_ title: String, _ value: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.bold())
            Picker("", selection: value) {
                Text(L("Pokaż")).tag(true)
                Text(L("Ukryj")).tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .help(help)
    }

    /// ⏸ / ▶ i odliczanie do następnego odświeżenia (co 60 s).
    private var refreshControl: some View {
        HStack(spacing: 6) {
            Button { pota.paused.toggle() } label: { Image(systemName: pota.paused ? "play.fill" : "pause.fill") }
                .help(pota.paused ? L("Wznów odświeżanie") : L("Wstrzymaj odświeżanie"))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(pota.paused ? L("wstrzymane")
                                 : L("odświeżenie za {1} s", max(0, Int(pota.nextRefresh.timeIntervalSince(context.date).rounded(.up)))))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
            }
        }
    }

    static func sortOrder(for choice: Int) -> [KeyPathComparator<POTASpot>] {
        switch choice {
        case 1: return [KeyPathComparator(\POTASpot.frequencyKHz)]
        case 2: return [KeyPathComparator(\POTASpot.activator)]
        case 3: return [KeyPathComparator(\POTASpot.reference)]
        case 4: return [KeyPathComparator(\POTASpot.mode)]
        default: return [KeyPathComparator(\POTASpot.spotTime, order: .reverse)]
        }
    }

    // MARK: - Tabela

    private var programs: [String] {
        Set((pota.spots + pota.ended).map(POTAManager.program(of:)).filter { !$0.isEmpty }).sorted()
    }

    private func count(mode: String) -> Int { baseRows.filter { $0.modeGroup == mode }.count }

    private var allRows: [POTASpot] {
        pota.spots + (pota.showEnded ? pota.ended : [])
    }

    /// Po filtrach QRT, ukrytych i wieku - podstawa liczników przy pasmach, emisjach i programach.
    private var baseRows: [POTASpot] {
        let now = Date()
        return allRows.filter { spot in
            (pota.showHidden || !pota.isHidden(spot))
                && (pota.maxAgeMinutes == 0 || spot.endedAt != nil
                    || now.timeIntervalSince(spot.spotTime) <= Double(pota.maxAgeMinutes) * 60)
        }
    }

    private var rows: [POTASpot] {
        baseRows.filter { spot in
            (pota.bandFilter.isEmpty || spot.band == pota.bandFilter)
                && (pota.modeFilter.isEmpty || spot.modeGroup == pota.modeFilter)
                && (pota.programFilter.isEmpty || POTAManager.program(of: spot) == pota.programFilter)
                && (!pota.onlyNewParks || pota.isNewPark(spot))
        }
        .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("UTC"), value: \.spotTime) { s in
                Text(s.endedAt == nil ? Self.timeFormatter.string(from: s.spotTime) : L("koniec"))
                    .monospacedDigit().foregroundStyle(color(s))
            }
            .width(min: 45, ideal: 50)
            TableColumn(L("Aktywator"), value: \.activator) { s in
                Text(s.activator).bold().foregroundStyle(color(s))
            }
            .width(min: 80, ideal: 95)
            TableColumn("kHz", value: \.frequencyKHz) { s in
                Text(String(format: "%.1f", s.frequencyKHz)).monospacedDigit().foregroundStyle(color(s))
            }
            .width(min: 65, ideal: 75)
            TableColumn(L("Pasmo"), value: \.bandOrder) { s in Text(s.band).foregroundStyle(color(s)) }
                .width(min: 40, ideal: 50)
            TableColumn(L("Tryb"), value: \.mode) { s in Text(s.mode).foregroundStyle(color(s)) }
                .width(min: 40, ideal: 50)
            TableColumn(L("Park"), value: \.reference) { s in
                Text(s.reference)
                    .fontWeight(pota.isNewPark(s) ? .bold : .regular)
                    .foregroundStyle(pota.isNewPark(s) && s.endedAt == nil ? Color.purple : color(s))
            }
            .width(min: 70, ideal: 80)
            TableColumn(L("Nazwa parku"), value: \.parkName) { s in Text(s.parkName).foregroundStyle(color(s)) }
                .width(min: 120, ideal: 220)
            TableColumn(L("Lokalizacja"), value: \.location) { s in Text(s.location).foregroundStyle(color(s)) }
                .width(min: 50, ideal: 70)
            TableColumn(L("Spoty"), value: \.count) { s in Text("\(s.count)").monospacedDigit().foregroundStyle(color(s)) }
                .width(min: 35, ideal: 45)
            TableColumn(L("Komentarz"), value: \.comments) { s in Text(s.comments).foregroundStyle(color(s)) }
        }
        .contextMenu(forSelectionType: POTASpot.ID.self) { ids in
            if let id = ids.first, let spot = allRows.first(where: { $0.id == id }) {
                Button(L("Strój radio i wpisz do dziennika")) { pota.select(spot) }
                Button(pota.isHidden(spot) ? L("Pokaż tę aktywację") : L("Ukryj tę aktywację")) {
                    pota.setHidden(spot, !pota.isHidden(spot))
                }
                Button(L("Park {1} na pota.app", spot.reference)) {
                    if let url = URL(string: "https://pota.app/#/park/" + spot.reference) { NSWorkspace.shared.open(url) }
                }
                Button(L("Aktywator {1} na QRZ.com", spot.activator)) {
                    if let url = URL(string: "https://www.qrz.com/db/" + QRZClient.baseCall(spot.activator)) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let spot = allRows.first(where: { $0.id == id }) {
                pota.select(spot)
                NotificationCenter.default.post(name: .showLogTab, object: nil)
            }
        }
    }

    /// Szary: aktywacja zakończona albo stacja z tym parkiem zrobiona dziś na tym paśmie.
    private func color(_ s: POTASpot) -> Color {
        s.endedAt != nil || pota.isWorkedToday(s) || pota.isHidden(s) ? Color.secondary : Theme.text
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text(L("Kliknięcie: radio na częstotliwość i tryb, znak i park do dziennika · dwuklik: także zakładka DZIENNIK"))
            Text(L("fioletowy park = nowy (brak w dzienniku)")).foregroundStyle(.purple)
            Text(L("szary = zakończona albo dziś już zrobiona na tym paśmie"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
