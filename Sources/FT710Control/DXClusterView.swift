import SwiftUI
import AppKit

/// Zakładka DX CLUSTER: połączenie, tabela spotów z filtrami, konsola węzła.
struct DXClusterView: View {
    @ObservedObject var cluster: DXClusterClient
    @ObservedObject var logbook: LogbookStore
    /// Stan krajów z dziennika i potwierdzeń (kolumna DXCC).
    @ObservedObject private var worked = WorkedIndexStore.shared
    @ObservedObject private var cty = CTYDatabase.shared
    let currentBand: String
    let canTune: Bool
    let onTune: (DXSpot) -> Void
    /// Zwykłe kliknięcie spotu - znak do formularza dziennika (bez zmiany zakładki).
    var onSelect: (DXSpot) -> Void = { _ in }

    @AppStorage("clusterBandFilter") private var bandFilter = "all"
    @AppStorage("clusterModeFilter") private var modeFilter = "all"
    @AppStorage("clusterHideWorked") private var hideWorked = false
    @AppStorage("clusterSetsMode") private var setsMode = true
    @State private var selection = Set<DXSpot.ID>()
    @State private var password = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                connectionRow
                filterRow
                spotTable
            }
            consolePanel.frame(width: 360)
        }
    }

    // MARK: - Połączenie i filtry

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Menu(L("Węzły")) {
                ForEach(DXClusterClient.presets.indices, id: \.self) { index in
                    let preset = DXClusterClient.presets[index]
                    Button("\(preset.name) – \(preset.host):\(preset.port)") {
                        cluster.host = preset.host
                        cluster.port = preset.port
                    }
                }
            }
            .fixedSize()
            TextField(L("Adres węzła"), text: $cluster.host).frame(width: 200)
            TextField(L("Port"), value: $cluster.port, format: .number.grouping(.never)).frame(width: 60)
            TextField(L("Znak (pusty = Mój znak)"), text: $cluster.login).frame(width: 150)
            SecureField(cluster.hasPassword ? L("Hasło – zapisane") : L("Hasło (jeśli węzeł wymaga)"), text: $password)
                .frame(width: 150)
                .onSubmit {
                    cluster.setPassword(password)
                    password = ""
                }
                .help(L("Enter zapisuje hasło w pęku kluczy; puste pole + Enter usuwa zapisane hasło"))
            if cluster.state == .disconnected {
                Button(L("Połącz")) { cluster.connect(fallbackCall: logbook.myCall) }
            } else {
                Button(L("Rozłącz")) { cluster.disconnect() }
            }
            Toggle(L("Łącz automatycznie"), isOn: $cluster.autoConnect)
                .help(L("Połącz przy starcie programu i ponawiaj po zerwaniu połączenia"))
            Toggle(L("Ostatnie spoty po połączeniu"), isOn: $cluster.fetchRecent)
                .help(L("Po zalogowaniu wysyła sh/dx 30, żeby od razu zobaczyć ostatnie spoty"))
            Text(Lr(cluster.status))
                .font(.caption)
                .foregroundStyle(cluster.state == .connected ? Theme.ok : (isErrorStatus(cluster.status) ? .red : .secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var filterRow: some View {
        HStack(spacing: 10) {
            Picker(L("Pasmo"), selection: $bandFilter) {
                Text(L("wszystkie")).tag("all")
                Text(L("moje pasmo")).tag("mine")
                ForEach(Bands.table.map { $0.name }, id: \.self) { name in Text(name).tag(name) }
            }
            .frame(width: 170)
            Picker(L("Tryb"), selection: $modeFilter) {
                Text(L("wszystkie")).tag("all")
                Text("CW").tag("CW")
                Text("SSB").tag("SSB")
                Divider()
                Text(L("cyfrowe – wszystkie")).tag("DIGI")
                ForEach(Self.digiModes, id: \.self) { Text($0).tag($0) }
                Text(L("inne cyfrowe")).tag("OTHER")
            }
            .frame(width: 190)
            Toggle(L("Ukryj zrobione na tym paśmie"), isOn: $hideWorked)
            Toggle(L("Ustaw tryb przy strojeniu"), isOn: $setsMode)
                .help(L("Podwójne kliknięcie ustawia też tryb (CW / SSB / DATA) zgodnie ze spotem"))
            Spacer()
            Text(L("{1} z {2} spotów", filteredSpots.count, cluster.spots.count))
                .font(.caption)
                .foregroundStyle(filteredSpots.count < cluster.spots.count ? Color.orange : .secondary)
                .help(L("Pokazane po filtrach / wszystkie odebrane"))
            Button(L("Wyczyść")) { cluster.clearSpots() }
        }
        .controlSize(.small)
    }

    // MARK: - Tabela spotów

    /// Znaki z dziennika: na jakich pasmach już były łączności.

    private var filteredSpots: [DXSpot] {
        return cluster.spots.filter { spot in
            switch bandFilter {
            case "all": break
            case "mine": if spot.band != currentBand { return false }
            default: if spot.band != bandFilter { return false }
            }
            if !Self.matchesMode(spot, modeFilter) { return false }
            if hideWorked, logbook.workedBands(baseCall: QRZClient.baseCall(spot.call))?.contains(spot.band) == true { return false }
            return true
        }
    }

    /// Emisje cyfrowe z osobną pozycją w filtrze (rozpoznawane z komentarza spotu albo częstotliwości FT8).
    private static let digiModes = ["FT8", "FT4", "RTTY", "PSK", "JS8", "Q65"]

    /// Filtr trybu: wszystkie / CW / SSB / cyfrowe (wszystkie) / konkretna emisja cyfrowa / inne cyfrowe.
    private static func matchesMode(_ spot: DXSpot, _ filter: String) -> Bool {
        switch filter {
        case "all": return true
        case "CW", "SSB", "DIGI": return spot.mode.rawValue == filter
        case "OTHER":
            guard spot.mode == .digi else { return false }
            let digi = (spot.digiMode ?? "").hasPrefix("PSK") ? "PSK" : (spot.digiMode ?? "")
            return !digiModes.contains(digi)
        case "PSK": return spot.mode == .digi && (spot.digiMode ?? "").hasPrefix("PSK")
        default: return spot.mode == .digi && spot.digiMode == filter
        }
    }

    /// Kraj spotu na tle w kolorze stanu (jak kategorie FT8 / WSJT-X): nowy kraj, nowy na paśmie,
    /// niepotwierdzony (ogólnie / na paśmie); potwierdzony na paśmie - bez tła.
    @ViewBuilder
    private func dxccCell(_ s: DXSpot) -> some View {
        if let match = cty.table?.lookup(s.call) {
            let status = worked.index.dxccStatus(match: match, band: s.band)
            let name = cty.table?.dxccName(CTYTable.dxccKey(match)) ?? match.entity.name
            if let color = status.highlight?.color {
                Text(name).lineLimit(1).foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .background(color, in: RoundedRectangle(cornerRadius: 3))
                    .help(status.label)
            } else {
                Text(name).lineLimit(1).foregroundStyle(.secondary).help(status.label)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private var spotTable: some View {
        return Table(filteredSpots, selection: $selection) {
            TableColumn("UTC") { s in Text(s.timeUTC).monospacedDigit() }
                .width(min: 40, ideal: 48)
            TableColumn("kHz") { s in
                Text(s.kHzText).monospacedDigit()
                    .foregroundStyle(s.band.isEmpty ? Theme.dim : Theme.text)
            }
            .width(min: 60, ideal: 75)
            TableColumn("DX") { s in CallSignLink(call: s.call) }
                .width(min: 70, ideal: 90)
            TableColumn(L("Pasmo")) { s in Text(s.band) }
                .width(min: 40, ideal: 45)
            TableColumn(L("Tryb")) { s in Text(s.digiMode ?? s.mode.rawValue) }
                .width(min: 40, ideal: 50)
            TableColumn(L("Dziennik")) { s in
                let bands = logbook.workedBands(baseCall: QRZClient.baseCall(s.call))   // z indeksu dziennika
                if bands?.contains(s.band) == true {
                    Text("✓ " + s.band).foregroundStyle(Theme.ok)
                } else if bands != nil {
                    Text(L("inne pasmo")).foregroundStyle(Theme.header)
                } else {
                    Text(L("nowy")).foregroundStyle(Theme.accent).bold()
                }
            }
            .width(min: 60, ideal: 75)
            TableColumn("DXCC") { s in dxccCell(s) }
                .width(min: 90, ideal: 130)
            TableColumn(L("Komentarz")) { s in Text(s.comment).lineLimit(1) }
            TableColumn("Spotter") { s in Text(s.spotter).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: DXSpot.ID.self) { ids in
            if let spot = spot(for: ids) {
                Button(L("Dostrój {1} ({2} kHz)", spot.call, spot.kHzText)) { tune(spot) }
                    .disabled(!canTune || spot.band.isEmpty)
                Button(L("Otwórz {1} w QRZ.com", spot.call)) {
                    if let url = URL(string: "https://www.qrz.com/db/\(QRZClient.baseCall(spot.call))") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } primaryAction: { ids in
            // Podwójne kliknięcie: dostrój radio do spotu.
            if let spot = spot(for: ids) { tune(spot) }
        }
        .help(L("Kliknięcie: znak do dziennika · podwójne kliknięcie: dostrój radio · prawy przycisk: więcej"))
        .onChange(of: selection) { ids in
            if ids.count == 1, let spot = spot(for: ids) { onSelect(spot) }
        }
    }

    private func spot(for ids: Set<DXSpot.ID>) -> DXSpot? {
        guard let id = ids.first else { return nil }
        return cluster.spots.first { $0.id == id }
    }

    private func tune(_ spot: DXSpot) {
        guard canTune, !spot.band.isEmpty else { return }    // poza pasmami FT-710 (np. 2 m) nie stroimy
        onTune(spot)
    }

    // MARK: - Konsola

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Konsola węzła")).font(.caption.bold()).foregroundStyle(Theme.header)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(cluster.console.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.hasPrefix(">") ? Theme.accent : Theme.text)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {                                            // po powrocie na zakładkę - od razu na koniec
                    let last = cluster.console.count - 1
                    guard last >= 0 else { return }
                    DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: cluster.console.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .padding(4)
            .background(Theme.panelInner, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                TextField(L("Komenda, np. sh/dx 20"), text: $cluster.draftCommand)
                    .onSubmit(sendCommand)
                Button(L("Wyślij"), action: sendCommand)
                    .disabled(cluster.state != .connected || cluster.draftCommand.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func sendCommand() {
        let text = cluster.draftCommand.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        cluster.send(text)
        cluster.draftCommand = ""
    }
}

/// Kolor znaku stacji na skopie - wspólny dla skopu w programie i w panelu zdalnym (przeglądarka):
/// obserwowany znak (turkus), potem stan kraju (nowy, nowy na paśmie, niepotwierdzony…); stacja już zrobiona
/// na tym paśmie - bez fioletu „niepotwierdzony” (jak w FT8). nil = zwykły znak (bursztyn).
@MainActor
enum ScopeMarkStyle {
    static func highlight(call: String, band: String) -> FTHighlight? {
        let base = QRZClient.baseCall(call.uppercased())
        let watched = AlertCenter.shared.watchList.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\n" })
            .contains { QRZClient.baseCall(String($0)) == base }
        if watched { return .newCall }                     // ten sam turkus co alert „Obserwowany znak”
        let index = WorkedIndexStore.shared.index
        guard let match = CTYDatabase.shared.table?.lookup(call),
              let highlight = index.dxccStatus(match: match, band: band).highlight else { return nil }
        if FTWorkedIndex.unconfirmedKinds.contains(highlight), index.workedOnBand(call, band: band) { return nil }
        return highlight
    }
}

/// Znaczniki stacji nad linią widma skopu RF: spoty z DX Cluster i aktywacje POTA, w miejscu ich częstotliwości.
/// Rzędy dobierane tak, żeby etykiety na siebie nie nachodziły; kreska biegnie od etykiety w dół do dokładnej
/// częstotliwości. Tło etykiety jak kolory FT8 / kolumna DXCC / alerty: obserwowany znak, nowy kraj, kraj
/// niepotwierdzony (ogólnie i na paśmie); bez nich - dotychczasowy bursztyn. POTA: zielona kreska i obwódka.
/// Kliknięcie: strojenie (POTA - jak w zakładce POTA). Obserwuje tylko swoje źródła - nie przerysowuje skopu.
struct ScopeSpotOverlay: View {
    @ObservedObject var cluster: DXClusterClient
    @ObservedObject var pota: POTAManager
    /// Zawody: w zakładce ZAWODY stacje już zrobione (na paśmie, wg reguł zawodów) - czerwone albo ukryte.
    @ObservedObject var contest: ContestManager
    let contestActive: Bool
    @ObservedObject private var worked = WorkedIndexStore.shared
    @ObservedObject private var alerts = AlertCenter.shared
    @ObservedObject private var cty = CTYDatabase.shared
    @AppStorage("scope.showCluster") private var showCluster = true
    @AppStorage("scope.showPOTA") private var showPOTA = true
    let lowHz: Int
    let highHz: Int
    let canTune: Bool
    let onTune: (DXSpot) -> Void
    let onPOTA: (POTASpot) -> Void

    private static let rowHeight: CGFloat = 15
    private static let labelHeight: CGFloat = 13
    private static let maxRows = 4

    enum Source {
        case cluster(DXSpot)
        case pota(POTASpot)
    }

    struct Mark: Identifiable {
        let id: String
        let call: String
        let hz: Int
        let source: Source
        let color: Color
        let tooltip: String
        var isPOTA: Bool { if case .pota = source { return true } else { return false } }
    }

    struct Placed: Identifiable {
        let mark: Mark
        let x: CGFloat              // dokładna częstotliwość
        let labelX: CGFloat         // lewa krawędź etykiety (w granicach skopu)
        let width: CGFloat
        let row: Int
        var id: String { mark.id }
    }

    /// Rzędy „zachłannie” od lewej: etykieta trafia do pierwszego rzędu, w którym się mieści.
    static func layout(_ marks: [Mark], lowHz: Int, highHz: Int, width: CGFloat) -> [Placed] {
        guard width > 20, highHz > lowHz else { return [] }
        let items = marks.map { mark -> (Mark, CGFloat) in
            (mark, width * CGFloat(Double(mark.hz - lowHz) / Double(highHz - lowHz)))
        }.sorted { $0.1 < $1.1 }
        var rowEnds = [CGFloat](repeating: -.infinity, count: maxRows)
        var placed: [Placed] = []
        for (mark, x) in items {
            let w = CGFloat(mark.call.count) * 6.6 + 8
            let labelX = min(max(x - w / 2, 0), max(width - w, 0))
            let row = rowEnds.firstIndex { $0 + 3 <= labelX }
                ?? rowEnds.indices.min { rowEnds[$0] < rowEnds[$1] } ?? 0
            rowEnds[row] = labelX + w
            placed.append(Placed(mark: mark, x: x, labelX: labelX, width: w, row: row))
        }
        return placed
    }

    /// Kolor tła: obserwowany znak, potem stan kraju; nic ciekawego - bursztyn (Theme.header).
    /// (Obserwowane obiekty `alerts`, `worked`, `cty` odświeżają widok po zmianie listy lub dziennika.)
    private func color(call: String, band: String) -> Color {
        _ = (alerts.watchList, worked.index, cty.table)
        return ScopeMarkStyle.highlight(call: call, band: band)?.color ?? Theme.header.opacity(0.92)
    }

    private func statusText(call: String, band: String) -> String {
        guard let match = cty.table?.lookup(call) else { return "" }
        let name = cty.table?.dxccName(CTYTable.dxccKey(match)) ?? match.entity.name
        return name + " – " + worked.index.dxccStatus(match: match, band: band).label
    }

    /// Zawody: czy stacja jest już zrobiona (tylko przy otwartej zakładce ZAWODY).
    private func workedInContest(_ call: String, band: String, mode: String) -> Bool {
        contestActive && contest.isWorked(call: call, band: band, mode: mode)
    }

    /// Znaczniki z obu źródeł; ten sam znak w klastrze i POTA - zostaje POTA (ma numer parku).
    private var marks: [Mark] {
        var byCall: [String: Mark] = [:]
        let contestWorked = L("Zrobiona w zawodach (dubel)")
        if showCluster {
            for spot in cluster.scopeSpots(lowHz: lowHz, highHz: highHz) {
                // emisja do reguły dubli: spoty cyfrowe jak RTTY (jedyna emisja cyfrowa w zawodach programu)
                let mode = spot.mode == .digi ? "RTTY" : spot.mode.rawValue
                let done = workedInContest(spot.call, band: spot.band, mode: mode)
                if done, contest.scopeWorked == .hide { continue }
                let tip = "\(spot.call)  \(spot.kHzText) kHz  \(spot.digiMode ?? spot.mode.rawValue)  \(spot.comment)  (\(spot.spotter), \(spot.timeUTC))"
                    + "\n" + statusText(call: spot.call, band: spot.band) + (done ? "\n" + contestWorked : "")
                let color = done && contest.scopeWorked == .red ? Color.red : color(call: spot.call, band: spot.band)
                byCall[spot.call] = Mark(id: "c-" + spot.id.uuidString, call: spot.call, hz: spot.frequencyHz,
                                         source: .cluster(spot), color: color, tooltip: tip)
            }
        }
        if showPOTA {
            for spot in pota.spots where spot.frequencyHz >= lowHz && spot.frequencyHz <= highHz {
                let done = workedInContest(spot.activator, band: spot.band, mode: spot.mode)
                if done, contest.scopeWorked == .hide { continue }
                let tip = "POTA \(spot.reference) \(spot.parkName)\n\(spot.activator)  \(String(format: "%.1f", spot.frequencyKHz)) kHz  \(spot.mode)  \(spot.comments)"
                    + "\n" + statusText(call: spot.activator, band: spot.band)
                    + (pota.isNewPark(spot) ? "\n" + L("Nowy park POTA") : "")
                byCall[spot.activator] = Mark(id: "p-" + spot.id, call: spot.activator, hz: spot.frequencyHz,
                                              source: .pota(spot),
                                              color: done && contest.scopeWorked == .red ? Color.red
                                                                                           : color(call: spot.activator, band: spot.band),
                                              tooltip: tip + (done ? "\n" + contestWorked : ""))
            }
        }
        return Array(byCall.values)
    }

    private func activate(_ mark: Mark) {
        guard canTune else { return }
        switch mark.source {
        case .cluster(let spot): onTune(spot)
        case .pota(let spot): onPOTA(spot)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let placed = Self.layout(marks, lowHz: lowHz, highHz: highHz, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    let top = 2 + CGFloat(item.row) * Self.rowHeight
                    let lineTop = top + Self.labelHeight
                    let lineHeight = max(geo.size.height - lineTop, 0)
                    // kreska do dokładnej częstotliwości (z szerszym, niewidocznym polem kliknięcia)
                    Rectangle()
                        .fill(item.mark.isPOTA ? Theme.ok : Theme.header.opacity(0.8))
                        .frame(width: 1, height: lineHeight)
                        .frame(width: 9, height: lineHeight)
                        .contentShape(Rectangle())
                        .offset(x: item.x - 4.5, y: lineTop)
                        .onTapGesture { activate(item.mark) }
                    Text(item.mark.call)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color.black)
                        .frame(width: item.width, height: Self.labelHeight)
                        .background(item.mark.color, in: RoundedRectangle(cornerRadius: 2))
                        .overlay {
                            if item.mark.isPOTA {
                                RoundedRectangle(cornerRadius: 2).stroke(Theme.ok, lineWidth: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .offset(x: item.labelX, y: top)
                        .onTapGesture { activate(item.mark) }
                        .help(item.mark.tooltip)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}
