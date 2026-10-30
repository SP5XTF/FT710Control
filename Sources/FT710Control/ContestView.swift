import SwiftUI
import AppKit

/// Zakładka ZAWODY: wybór zawodów, szybkie wpisywanie z oceną na żywo, wynik, tempo, Cabrillo.
struct ContestView: View {
    @ObservedObject var contest: ContestManager
    @ObservedObject var cat: CATClient
    @ObservedObject var cluster: DXClusterClient
    @ObservedObject private var cty = CTYDatabase.shared
    @State private var spotting: ContestSpot?
    @State private var showArchive = false
    @State private var showHeader = false
    @State private var confirmNew = false
    @State private var pendingKind: ContestKind = .cqww
    @State private var pendingMode: ContestMode = .cw
    @State private var selection = Set<UUID>()
    @State private var editing: QSO?
    @State private var confirmDelete = false
    @State private var confirmAddToLog = false
    @FocusState private var callFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !contest.ctyReady {
                Text(L("Do liczenia punktów potrzebna jest baza krajów - kliknij „Aktualizuj bazę krajów” (wymaga internetu)."))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                entryPanel
                Divider()
                scorePanel.frame(width: 300)
            }
            Divider()
            recentList
        }
        .sheet(isPresented: $showHeader) { CabrilloHeaderView(session: $contest.session) }
        .sheet(item: $spotting) { spot in ContestSpotSheet(command: spot.command, cluster: cluster) }
        .sheet(isPresented: $showArchive) {
            ContestArchiveView(entries: contest.archive(), current: contest.session.id) { contest.open($0) }
        }
        .sheet(item: $editing) { qso in
            ContestQSOEditView(qso: qso, onDelete: { contest.delete([qso.id]) }) { contest.update($0) }
        }
        .confirmationDialog(Text(L("Usunąć z logu zawodów: {1}?", selection.count)), isPresented: $confirmDelete) {
            Button(L("Usuń"), role: .destructive) { contest.delete(selection); selection.removeAll() }
        } message: {
            Text(L("Łączności znikną z logu zawodów (wynik, Cabrillo). Główny dziennik pozostaje bez zmian."))
        }
        .confirmationDialog(Text(L("Dodać łączności zawodów do dziennika: {1}?", contest.notInLogbook().count)),
                            isPresented: $confirmAddToLog) {
            Button(L("Dodaj do dziennika")) { contest.addToLogbook() }
        } message: {
            Text(L("Łączności, które już są w dzienniku (ten sam znak, pasmo, czas ±2 min), zostaną pominięte. Automatycznej wysyłki do serwisów nie ma - po sprawdzeniu: Usługi online → Wyślij zaległe."))
        }
        .confirmationDialog(Text(L("Rozpocząć nowe zawody: {1} ({2})?", pendingKind.name, pendingMode.rawValue)),
                            isPresented: $confirmNew) {
            Button(L("Nowe zawody")) { contest.newSession(kind: pendingKind, mode: pendingMode); callFocused = true }
        } message: {
            Text(L("Numeracja zacznie się od 001, a wynik od zera. Log poprzednich zawodów zostaje zapisany (osobny plik)."))
        }
        .onAppear { callFocused = true }
    }

    // MARK: - Nagłówek

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(L("ZAWODY")).font(.caption.bold()).foregroundStyle(Theme.header)
                Text("\(contest.session.kind.name) · \(contest.session.mode.rawValue)").font(.headline)
                Menu(L("Nowe zawody…")) {
                    ForEach(ContestKind.allCases) { kind in
                        Menu(kind.name) {
                            ForEach(ContestMode.allCases) { mode in
                                Button(mode.rawValue) { pendingKind = kind; pendingMode = mode; confirmNew = true }
                            }
                        }
                    }
                }
                .fixedSize()
                Button(L("Poprzednie zawody…")) { showArchive = true }
                    .help(L("Lista wszystkich logów zawodów - otwarcie wcześniejszych zawodów"))
                if let url = contest.session.kind.rulesURL {
                    Link(L("Regulamin"), destination: url).font(.caption)
                }
                Spacer()
                Button(L("Nagłówek Cabrillo…")) { showHeader = true }
                Button(L("Eksport Cabrillo…")) { contest.exportCabrillo() }
                    .disabled(contest.score.qsos + contest.score.dupes == 0)
                Button(L("Dodaj do dziennika…")) { confirmAddToLog = true }
                    .disabled(contest.qsos.isEmpty)
                    .help(L("Łączności zawodów są w osobnym logu - tu można je dodać do głównego dziennika (bez dubli)"))
            }
            .controlSize(.small)
            HStack(spacing: 10) {
                Text(contest.session.kind.summary)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(Lr(cty.status)).font(.caption2).foregroundStyle(.secondary)
                Button(cty.updating ? L("Pobieranie…") : L("Aktualizuj bazę krajów")) { cty.update() }
                    .controlSize(.small)
                    .disabled(cty.updating)
                    .help(L("cty.dat (AD1C, country-files.com) - aktualizuj przed dużymi zawodami"))
            }
        }
    }

    // MARK: - Wpisywanie

    private var entryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                field(L("Znak")) {
                    TextField("", text: $contest.call)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .frame(width: 190)
                        .focused($callFocused)
                        .onSubmit(submit)
                }
                field("RST") {
                    TextField("", text: $contest.rstRcvd)
                        .font(.system(size: 16, design: .monospaced))
                        .frame(width: 56)
                        .onSubmit(submit)
                }
                field(contest.receivedLabel) {
                    TextField("", text: Binding(get: { contest.exchange },
                                                set: { contest.exchange = $0.uppercased(); contest.exchangeEdited() }))
                        .font(.system(size: 16, design: .monospaced))
                        .frame(width: 110)
                        .onSubmit(submit)
                }
                Button(L("Zapisz")) { submit() }                          // Enter obsługują pola (bez podwójnego zapisu)
                    .disabled(contest.call.count < 3)
                Button(L("Spot")) {
                    if let last = contest.lastLogged { spotting = ContestSpot(command: contest.spotCommand(last)) }
                }
                .disabled(contest.lastLogged == nil)
                .help(L("Wyślij na DX Cluster spot ostatnio zapisanej stacji (polecenie do poprawienia przed wysłaniem)"))
            }
            .onExitCommand { contest.clearEntry(); callFocused = true }
            evaluationLine
            ContestQRZLine(lookup: contest.lookup, call: contest.call)
            HStack(spacing: 6) {
                Text(L("Zrobione w zawodach na skopie:")).font(.caption)
                Picker("", selection: $contest.scopeWorked) {
                    ForEach(ContestScopeWorked.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help(L("Stacje z DX Cluster i POTA już zrobione w tych zawodach na tym paśmie (wg reguł dubli zawodów) - przy otwartej zakładce ZAWODY"))
            }
            .controlSize(.small)
            HStack(spacing: 12) {
                Text(L("Nadaję: {1}", contest.sentExchange)).font(.system(.callout, design: .monospaced))
                if !contest.sendsSerial {
                    Text(L("Moja wymiana")).font(.caption)
                    TextField("", text: $contest.session.myExchange)
                        .frame(width: 80)
                        .controlSize(.small)
                        .help(myExchangeHelp)
                }
                Text(L("Pasmo: {1}", contest.currentBand.isEmpty ? "–" : contest.currentBand)).font(.caption)
            }
            if let message = contest.message.map(Lr) {
                Text(message).font(.caption).foregroundStyle(message.hasPrefix(L("DUBEL")) ? Color.red : Color.secondary)
            }
            Text(L("Enter zapisuje, Esc czyści. Dubel: drugi Enter zapisuje mimo to (0 punktów)."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var myExchangeHelp: String {
        switch contest.session.kind {
        case .cqww: return L("Twoja strefa CQ (Polska: 15)")
        case .iaru: return L("Twoja strefa ITU (Polska: 28) albo skrót organizacji dla stacji HQ")
        case .spdx: return L("Litera Twojego województwa: B, C, D, F, G, J, K, L, M, O, P, R, S, U, W, Z")
        case .arrldx: return contest.role == .arrlDX ? L("Moc nadajnika (np. 100 albo KW)") : L("Twój stan lub prowincja")
        default: return ""
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func submit() {
        contest.log()
        callFocused = true
    }

    @ViewBuilder private var evaluationLine: some View {
        let e = contest.evaluation
        HStack(spacing: 8) {
            if let m = e.match {
                Text("\(m.entity.name) · \(m.continent) · CQ \(m.cqZone) · ITU \(m.ituZone)")
                    .font(.callout)
            } else if contest.call.count >= 3 {
                Text(L("nieznany prefiks")).font(.callout).foregroundStyle(.secondary)
            }
            if e.dupe {
                chip(L("DUBEL"), .red)
            } else if e.match != nil {
                chip(L("{1} pkt", e.points), e.points > 0 ? Theme.accent : .gray)
                ForEach(e.newMultipliers, id: \.self) { chip(L("NOWY: {1}", $0), Theme.ok) }
            }
            if let note = e.note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .frame(minHeight: 22)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Wynik

    private var scorePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("WYNIK")).font(.caption.bold()).foregroundStyle(Theme.header)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text(L("Pasmo")).gridColumnAlignment(.leading)
                    Text("QSO"); Text(L("Pkt")); Text(L("Mn."))
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(contest.score.bands, id: \.band) { line in
                    GridRow {
                        Text(line.band).gridColumnAlignment(.leading)
                        Text("\(line.qsos)"); Text("\(line.points)"); Text("\(line.mults)")
                    }
                    .font(.system(.callout, design: .monospaced))
                }
                Divider().gridCellColumns(4)
                GridRow {
                    Text(L("Razem")).gridColumnAlignment(.leading)
                    Text("\(contest.score.qsos)"); Text("\(contest.score.points)"); Text("\(contest.score.multipliers)")
                }
                .font(.system(.callout, design: .monospaced).bold())
            }
            Text(L("Wynik: {1}", contest.score.total.formatted()))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(L("Tempo: {1}/h (10 min) · {2} QSO w ostatniej godzinie", contest.rate10, contest.rate60))
                .font(.caption)
            if contest.score.dupes > 0 {
                Text(L("Duble w logu: {1} (bez punktów)", contest.score.dupes)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ostatnie łączności

    /// Log zawodów (najnowsze u góry): zaznaczanie, Edytuj… / Usuń (menu, dwuklik, klawisz Delete).
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("LOG ZAWODÓW ({1})", contest.qsos.count)).font(.caption.bold()).foregroundStyle(Theme.header)
                Button(L("Edytuj…")) {
                    if let id = selection.first, let q = contest.qsos.first(where: { $0.id == id }) { editing = q }
                }
                .disabled(selection.count != 1)
                Button(L("Usuń…")) { confirmDelete = true }
                    .disabled(selection.isEmpty)
                Spacer()
                Text(L("Dwuklik lub Edytuj… - zmiana, Delete - usunięcie (tylko z logu zawodów)"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Table(contest.recent, selection: $selection) {
                TableColumn("UTC") { q in Text(Self.utc.string(from: q.start)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn(L("Pasmo")) { q in Text(q.band) }.width(min: 40, ideal: 50)
                TableColumn(L("Tryb")) { q in Text(q.mode) }.width(min: 40, ideal: 50)
                TableColumn(L("Znak")) { q in Text(q.call).bold() }.width(min: 80, ideal: 110)
                TableColumn(L("Wysłane")) { q in
                    Text("\(q.rstSent) \(q.extra["STX_STRING"] ?? q.extra["STX"].map { String(format: "%03d", Int($0) ?? 0) } ?? "")")
                        .monospaced()
                }
                .width(min: 70, ideal: 90)
                TableColumn(L("Odebrane")) { q in
                    Text("\(q.rstRcvd) \(q.extra["SRX_STRING"] ?? q.extra["SRX"] ?? "")").monospaced()
                }
                .width(min: 70, ideal: 90)
                TableColumn(L("Kraj")) { q in Text(q.extra["COUNTRY"] ?? "").foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
                TableColumn(L("Imię / QTH")) { q in
                    Text([q.name, q.qth].filter { !$0.isEmpty }.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first, let q = contest.qsos.first(where: { $0.id == id }) {
                    Button(L("Edytuj…")) { editing = q }
                    Button(L("Wyślij spot na DX Cluster…")) { spotting = ContestSpot(command: contest.spotCommand(q)) }
                }
                if !ids.isEmpty {
                    Button(L("Usuń z logu zawodów…"), role: .destructive) { selection = ids; confirmDelete = true }
                }
            } primaryAction: { ids in
                if let id = ids.first, let q = contest.qsos.first(where: { $0.id == id }) { editing = q }
            }
            .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
        }
        .frame(minHeight: 120)
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd HH:mm"
        return f
    }()
}

/// Nagłówek Cabrillo: kategorie i dane zgłaszającego.
struct CabrilloHeaderView: View {
    @Binding var session: ContestSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Nagłówek Cabrillo")).font(.title3.bold())
            Form {
                Picker("CATEGORY-OPERATOR", selection: $session.categoryOperator) {
                    ForEach(["SINGLE-OP", "MULTI-OP", "CHECKLOG"], id: \.self) { Text($0) }
                }
                Picker("CATEGORY-ASSISTED", selection: $session.categoryAssisted) {
                    ForEach(["NON-ASSISTED", "ASSISTED"], id: \.self) { Text($0) }
                }
                Picker("CATEGORY-BAND", selection: $session.categoryBand) {
                    ForEach(["ALL", "160M", "80M", "40M", "20M", "15M", "10M"], id: \.self) { Text($0) }
                }
                Picker("CATEGORY-POWER", selection: $session.categoryPower) {
                    ForEach(["HIGH", "LOW", "QRP"], id: \.self) { Text($0) }
                }
                Picker("CATEGORY-TRANSMITTER", selection: $session.categoryTransmitter) {
                    ForEach(["ONE", "TWO", "LIMITED", "UNLIMITED"], id: \.self) { Text($0) }
                }
                TextField("CLUB", text: $session.club)
                TextField("OPERATORS", text: $session.operators)
                TextField("EMAIL", text: $session.email)
                TextField(L("ADDRESS (każda linia osobno)"), text: $session.address, axis: .vertical).lineLimit(2...4)
                TextField("SOAPBOX", text: $session.soapbox, axis: .vertical).lineLimit(2...4)
                TextField(L("CONTEST (puste = {1})", session.kind.cabrilloName(mode: session.mode)), text: $session.contestNameOverride)
            }
            Text(L("Moc FT-710: LOW do 100 W. Kategorie i nazwę zawodów sprawdź w regulaminie - organizatorzy czasem je zmieniają."))
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L("Gotowe")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}


/// Dane z QRZ dla wpisywanego znaku (imię, QTH, lokator) - pod polem znaku w zawodach.
struct ContestQRZLine: View {
    @ObservedObject var lookup: CallLookup
    let call: String

    var body: some View {
        HStack(spacing: 6) {
            Text("QRZ").font(.caption2.bold()).foregroundStyle(.secondary)
            switch lookup.phase {
            case .loading:
                Text(L("szukam…")).font(.caption).foregroundStyle(.secondary)
            case .found:
                if let r = lookup.record, r.call == QRZClient.baseCall(call.uppercased()) {
                    let name = r.firstName.isEmpty ? r.displayName : r.firstName
                    let away = OperatingLocation.isAwayFromHome(call)
                    Text([name, away ? "" : r.city, away ? "" : r.grid].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout)
                    if away { Text(L("(pracuje spoza swojego kraju)")).font(.caption).foregroundStyle(.secondary) }
                }
            case .notFound:
                Text(L("brak w QRZ")).font(.caption).foregroundStyle(.secondary)
            case .noAccount:
                Text(L("brak konta QRZ (profil stacji)")).font(.caption).foregroundStyle(.secondary)
            case .failed(let error):
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .frame(height: 18)
    }
}

/// Edycja łączności w logu zawodów: znak, czas UTC, pasmo, tryb, RST i wymiany.
struct ContestQSOEditView: View {
    @State var qso: QSO
    var onDelete: (() -> Void)? = nil
    let onSave: (QSO) -> Void
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @State private var sent = ""
    @State private var received = ""

    private static let bands = ["160m", "80m", "40m", "20m", "15m", "10m", "60m", "30m", "17m", "12m", "6m"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Edycja łączności (log zawodów)")).font(.headline)
            Form {
                TextField(L("Znak"), text: Binding(get: { qso.call }, set: { qso.call = $0.uppercased().filter { !$0.isWhitespace } }))
                DatePicker(L("Czas UTC"), selection: $qso.start, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                Picker(L("Pasmo"), selection: Binding(get: { qso.band.lowercased() }, set: { band in
                    qso.band = band
                    // częstotliwość w paśmie (dolna krawędź), jeśli dotychczasowa jest poza nim
                    if LogFrequency.band(for: qso.freqHz) != band,
                       let range = LogFrequency.bands.first(where: { $0.name == band })?.range {
                        qso.freqHz = range.lowerBound
                    }
                })) {
                    ForEach(Self.bands, id: \.self) { Text($0).tag($0) }
                }
                Picker(L("Tryb"), selection: $qso.mode) {
                    ForEach(["CW", "SSB", "RTTY"], id: \.self) { Text($0).tag($0) }
                }
                TextField(L("RST wysłany"), text: $qso.rstSent)
                TextField(L("Wymiana wysłana"), text: $sent)
                TextField(L("RST odebrany"), text: $qso.rstRcvd)
                TextField(L("Wymiana odebrana"), text: $received)
            }
            HStack {
                if onDelete != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(L("Usuń łączność…")).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(L("Anuluj")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Zapisz")) { save() }.keyboardShortcut(.defaultAction).disabled(qso.call.count < 3)
            }
        }
        .padding(18)
        .frame(width: 420)
        .confirmationDialog(Text(L("Usunąć łączność z {1}?", qso.call)), isPresented: $confirmDelete) {
            Button(L("Usuń"), role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(L("Łączność zniknie z logu zawodów (wynik, Cabrillo). Główny dziennik pozostaje bez zmian."))
        }
        .onAppear {
            sent = qso.extra["STX"] ?? qso.extra["STX_STRING"] ?? ""
            received = qso.extra["SRX"] ?? qso.extra["SRX_STRING"] ?? ""
        }
    }

    /// Wymiany zapisywane w tym samym polu ADIF co wcześniej (numer: STX/SRX, tekst: STX_STRING/SRX_STRING).
    private func save() {
        let s = sent.uppercased().trimmingCharacters(in: .whitespaces)
        let r = received.uppercased().trimmingCharacters(in: .whitespaces)
        if qso.extra["STX"] != nil, let n = Int(s) { qso.extra["STX"] = String(n) } else if qso.extra["STX"] == nil { qso.extra["STX_STRING"] = s } else { qso.extra["STX"] = nil; qso.extra["STX_STRING"] = s }
        if qso.extra["SRX"] != nil, let n = Int(r) { qso.extra["SRX"] = String(n) } else if qso.extra["SRX"] == nil { qso.extra["SRX_STRING"] = r } else { qso.extra["SRX"] = nil; qso.extra["SRX_STRING"] = r }
        onSave(qso)
        dismiss()
    }
}


/// Spot do wysłania (polecenie DX Cluster).
struct ContestSpot: Identifiable {
    let id = UUID()
    let command: String
}

/// Wysyłanie spotu stacji z zawodów na DX Cluster: gotowe polecenie „DX <kHz> <znak> <komentarz>” do poprawienia.
struct ContestSpotSheet: View {
    @State var command: String
    @ObservedObject var cluster: DXClusterClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Spot na DX Cluster")).font(.headline)
            TextField("", text: $command)
                .font(.system(.body, design: .monospaced))
                .frame(width: 420)
            Text(L("Format: DX <częstotliwość kHz> <znak> <komentarz>. Komentarz można zmienić (np. dodać „TNX QSO”)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cluster.state != .connected {
                Text(L("Brak połączenia z DX Cluster - połącz się w zakładce DX CLUSTER."))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L("Anuluj")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Wyślij")) {
                    cluster.send(command.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cluster.state != .connected || !command.uppercased().hasPrefix("DX "))
            }
        }
        .padding(18)
    }
}


/// „Poprzednie zawody…”: wszystkie logi zawodów (pliki i - ze starszych wersji - łączności w dzienniku).
struct ContestArchiveView: View {
    let entries: [ContestManager.ArchiveEntry]
    let current: UUID
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Poprzednie zawody")).font(.headline)
            Text(L("Logi zawodów są zapisywane osobno (folder Contests obok dziennika) i nic nie jest z nich usuwane przy rozpoczęciu nowych zawodów."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty {
                Text(L("Brak zapisanych zawodów.")).foregroundStyle(.secondary)
            } else {
                Table(entries) {
                    TableColumn(L("Zawody")) { e in
                        Text(e.title).bold().foregroundStyle(e.id == current ? Theme.ok : Theme.text)
                    }
                    TableColumn(L("QSO")) { e in Text("\(e.qsoCount)").monospacedDigit() }.width(min: 40, ideal: 50)
                    TableColumn(L("Od (UTC)")) { e in Text(e.first.map { Self.day.string(from: $0) } ?? "–").monospacedDigit() }
                    TableColumn(L("Do (UTC)")) { e in Text(e.last.map { Self.day.string(from: $0) } ?? "–").monospacedDigit() }
                    TableColumn("") { e in
                        if e.id == current {
                            Text(L("bieżące")).font(.caption).foregroundStyle(Theme.ok)
                        } else {
                            HStack {
                                Button(L("Otwórz")) { onOpen(e.id); dismiss() }
                                if e.inLogbookOnly { Text(L("w dzienniku")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .width(min: 130, ideal: 160)
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 700, height: 420)
    }
}
