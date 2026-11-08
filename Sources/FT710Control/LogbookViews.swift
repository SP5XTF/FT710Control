import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let utcFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

private let utcTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "HH:mm"
    return f
}()

// MARK: - Szybki wpis w głównym oknie

struct QuickLogView: View {
    @ObservedObject var store: LogbookStore
    @ObservedObject var cat: CATClient
    @ObservedObject var lookup: CallLookup
    @ObservedObject var qrz: QRZClient
    /// Szkic QSO poza widokiem - przełączenie zakładki nie kasuje wpisanych pól (widok znika, szkic zostaje).
    @ObservedObject var draft: QuickLogDraft
    let openLogbook: () -> Void

    @FocusState private var callFocused: Bool
    @State private var showManualQSO = false

    var body: some View {
        GroupBox(L("Dziennik łączności")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(L("Znak"), text: $draft.call)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                        .focused($callFocused)
                    Picker(L("Tryb"), selection: Binding(get: { draft.preset },
                                                      set: { draft.preset = $0; draft.modeTouched = true; applyDefaultRST() })) {
                        ForEach(LogModePreset.all) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    TextField(L("RST nad."), text: $draft.rstSent).frame(width: 64)
                    TextField(L("RST odb."), text: $draft.rstRcvd).frame(width: 64)
                    TextField(L("Imię"), text: $draft.name).frame(width: 110)
                    TextField(L("QTH"), text: $draft.qth).frame(width: 120)
                    TextField(L("Lokator"), text: $draft.grid).frame(width: 80)
                    TextField(L("Uwagi"), text: $draft.comment)
                }
                .onSubmit { save() }

                HStack(spacing: 12) {
                    Button(L("Zapisz QSO")) { save() }
                        .disabled(draft.call.isEmpty)
                    Button(L("Wyczyść")) { clear() }
                    Button(L("Dodaj ręcznie…")) { showManualQSO = true }
                        .help(L("Łączność z innego radia albo z inną datą (np. 2 m, 70 cm, 23 cm): pasmo, data UTC, emisja, propagacja, radio i moc - z tym, co już wpisano w formularzu"))
                        .sheet(isPresented: $showManualQSO) {
                            ManualQSOView(store: store,
                                          prefill: ManualQSOPrefill(call: draft.call, name: draft.name, qth: draft.qth,
                                                                    grid: draft.grid, comment: draft.comment,
                                                                    rstSent: draft.rstSent, rstRcvd: draft.rstRcvd,
                                                                    start: draft.startedAt),
                                          onSaved: { clear() })
                        }
                    Text(infoLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let message = draft.message.map(Lr) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        openLogbook()
                    } label: {
                        Text(verbatim: L("Otwórz dziennik ({1})", store.qsos.count))
                    }
                }

                if let ref = draft.activePOTARef {
                    HStack(spacing: 6) {
                        Image(systemName: "leaf").foregroundStyle(Theme.ok)
                        Text(verbatim: "POTA: " + ref + (draft.potaPark.isEmpty ? "" : " – " + draft.potaPark))
                            .font(.caption.bold())
                        Button { draft.potaRef = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .help(L("Usuń numer parku z tej łączności"))
                        Text(L("zapis: SIG=POTA, SIG_INFO, POTA_REF")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if draft.call.count >= 3 {
                    WorkedBeforeView(call: draft.call,
                                     previous: store.previous(call: draft.call),
                                     band: Bands.name(for: cat.activeFreq),
                                     modeFamily: LogbookStore.modeFamily(mode: draft.preset.mode, submode: draft.preset.submode))
                }
            }
            .padding(6)
        }
        // Znak z kliknięcia stacji (skop / DX Cluster) - od razu albo po przejściu do tej zakładki.
        .onAppear { applyPrefill() }
        .onChange(of: store.prefillCall?.id) { _ in applyPrefill() }
        .onChange(of: draft.call) { value in
            let cleaned = value.uppercased().filter { !$0.isWhitespace }
            if cleaned != value { draft.call = cleaned }
            if cleaned.isEmpty {
                draft.startedAt = nil
            } else if draft.startedAt == nil {
                draft.startedAt = Date()          // początek QSO = chwila wpisania pierwszego znaku
            }
            // znak się zmienił - dane poprzedniego znaku z QRZ (np. niepełnego „SP5X”) usuń, jeśli nie poprawione ręcznie
            draft.autoFill.clear([("name", $draft.name), ("qth", $draft.qth), ("grid", $draft.grid)])
            // Dane stacji z QRZ (z opóźnieniem - nie pytamy o każdą wpisaną literę).
            if !cleaned.isEmpty { lookup.request(cleaned, using: qrz, debounce: true) }
        }
        .onChange(of: lookup.record) { record in
            // Uzupełnij tylko puste pola - wpisanego ręcznie nic nie nadpisujemy.
            guard let record, !draft.call.isEmpty, QRZClient.baseCall(draft.call) == record.call else { return }
            if draft.name.isEmpty {
                draft.name = record.firstName.isEmpty ? record.displayName : record.firstName
                draft.autoFill.filled("name", draft.name)
            }
            // stacja spoza swojego kraju (P4/WE9V): QTH i lokator z QRZ to jej dom, nie miejsce pracy
            guard !OperatingLocation.isAwayFromHome(draft.call) else { return }
            if draft.qth.isEmpty { draft.qth = record.city; draft.autoFill.filled("qth", draft.qth) }
            if draft.grid.isEmpty {
                draft.grid = record.grid.isEmpty ? (record.coordinate.map { Geo.grid(for: $0) } ?? "") : record.grid
                draft.autoFill.filled("grid", draft.grid)
            }
        }
        .onChange(of: cat.modeCode) { code in
            guard !draft.modeTouched else { return }
            draft.preset = LogModePreset.forRadio(code)
            applyDefaultRST()
        }
        .onAppear {
            // Tryb i RST wg radia tylko przy pierwszym pokazaniu albo przy pustym formularzu -
            // po powrocie z innej zakładki wpisanego QSO nie nadpisujemy.
            guard !draft.initialized || (draft.call.isEmpty && !draft.modeTouched) else { return }
            draft.initialized = true
            draft.preset = LogModePreset.forRadio(cat.modeCode)
            applyDefaultRST()
        }
    }

    // MARK: - Pomocnicze

    private var currentBand: String { Bands.name(for: cat.activeFreq) ?? "?" }

    private var infoLine: String {
        var parts: [String] = []
        parts.append(cat.activeFreq > 0 ? L("{1} · {2}", formatFrequency(cat.activeFreq), currentBand) : L("brak częstotliwości z CAT"))
        if let startedAt = draft.startedAt { parts.append(L("start {1} UTC", utcTimeFormatter.string(from: startedAt))) }
        if store.myCall.isEmpty { parts.append(L("ustaw „Mój znak” w oknie dziennika")) }
        return parts.joined(separator: " · ")
    }

    /// Nowa stacja z kliknięcia: czyści dane poprzedniej i wpisuje znak (dalej jak przy ręcznym wpisaniu:
    /// czas początku QSO, dane z QRZ, „czy już była”).
    private func applyPrefill() {
        guard let prefill = store.prefillCall else { return }
        store.prefillCall = nil
        draft.name = ""
        draft.qth = ""
        draft.grid = ""
        draft.comment = ""
        draft.message = nil
        if draft.call == prefill.call {
            draft.startedAt = Date()                              // ta sama stacja - nowy początek QSO
        } else {
            draft.startedAt = nil
            draft.call = prefill.call
        }
    }

    private func applyDefaultRST() {
        draft.rstSent = draft.preset.defaultRST
        draft.rstRcvd = draft.preset.defaultRST
    }

    private func save() {
        let callsign = draft.call.trimmingCharacters(in: .whitespaces)
        guard callsign.count >= 3, callsign.range(of: "^[A-Z0-9/]+$", options: .regularExpression) != nil else {
            draft.message = L("Nieprawidłowy znak")
            return
        }
        guard cat.activeFreq > 0 else {
            draft.message = L("Brak częstotliwości z radia - połącz CAT")
            return
        }
        let now = Date()
        var qso = store.makeQSO(call: callsign, start: draft.startedAt ?? now, end: now, freqHz: cat.activeFreq,
                                preset: draft.preset, rstSent: draft.rstSent, rstRcvd: draft.rstRcvd, name: draft.name,
                                qth: draft.qth, grid: draft.grid, comment: draft.comment, record: lookup.record)
        // Park POTA ze spotu: pola ADIF liczone przez POTA po wysłaniu dziennika (SIG/SIG_INFO i POTA_REF)
        if let ref = draft.activePOTARef {
            qso.extra["SIG"] = "POTA"
            qso.extra["SIG_INFO"] = ref
            qso.extra["POTA_REF"] = ref
            if qso.comment.isEmpty { qso.comment = "POTA " + ref }
        }
        store.add(qso)
        draft.message = L("Zapisano {1} o {2} UTC", callsign, utcTimeFormatter.string(from: now))
        clear()
    }

    private func clear() {
        draft.reset(preset: LogModePreset.forRadio(cat.modeCode))
        callFocused = true
    }
}

/// Wpisywane QSO (zakładka DZIENNIK) - obiekt żyje razem z oknem głównym, więc przejście na inną zakładkę
/// i powrót nie kasuje znaku ani pozostałych pól.
@MainActor
final class QuickLogDraft: ObservableObject {
    /// Pola wypełnione z QRZ - czyszczone przy zmianie znaku (jeśli nie poprawione ręcznie).
    var autoFill = QRZAutoFill()
    @Published var call = ""
    @Published var preset = LogModePreset.all[0]
    @Published var modeTouched = false        // użytkownik sam wybrał tryb - nie nadpisuj trybem radia
    @Published var rstSent = "59"
    @Published var rstRcvd = "59"
    @Published var name = ""
    @Published var qth = ""
    @Published var grid = ""
    @Published var comment = ""
    @Published var startedAt: Date?
    @Published var message: String?
    /// Park POTA ze spotu (zakładka POTA) - dotyczy tylko znaku aktywatora `potaCall`.
    @Published var potaRef = ""
    @Published var potaPark = ""
    @Published var potaCall = ""

    /// Numer parku obowiązuje, dopóki w polu jest znak tego aktywatora.
    var activePOTARef: String? {
        guard !potaRef.isEmpty, !call.isEmpty,
              QRZClient.baseCall(call.uppercased()) == QRZClient.baseCall(potaCall.uppercased()) else { return nil }
        return potaRef
    }
    /// Czy tryb i RST zostały już raz ustawione wg radia (przy pierwszym pokazaniu formularza).
    var initialized = false

    /// Pusty formularz: tryb i RST wg radia.
    func reset(preset: LogModePreset) {
        autoFill = QRZAutoFill()
        call = ""
        name = ""
        qth = ""
        grid = ""
        comment = ""
        startedAt = nil
        modeTouched = false
        potaRef = ""
        potaPark = ""
        potaCall = ""
        self.preset = preset
        rstSent = preset.defaultRST
        rstRcvd = preset.defaultRST
    }

    /// QSO zapisane inną drogą (FT8, WSJT-X, zawody): jeśli w formularzu jest ta sama stacja - czyścimy,
    /// żeby nie została jako „do zapisania”. Inny wpisywany znak zostaje nietknięty.
    func loggedElsewhere(_ logged: String, radioMode: String) {
        guard !call.isEmpty, QRZClient.baseCall(call) == QRZClient.baseCall(logged.uppercased()) else { return }
        reset(preset: LogModePreset.forRadio(radioMode))
        message = L("Zapisano {1} o {2} UTC", logged.uppercased(), utcTimeFormatter.string(from: Date()))
    }
}

// MARK: - Okno dziennika

struct LogbookWindowView: View {
    @EnvironmentObject var store: LogbookStore
    @EnvironmentObject var qrz: QRZClient
    @EnvironmentObject var uploader: LogUploader
    @State private var showIntegrations = false
    @State private var editing: QSO?
    @State private var confirmDeleteAll = false
    @State private var showRestore = false
    @State private var importPreview: ImportPreview?
    @State private var qrzUser = ""
    @State private var qrzPassword = ""
    @State private var search = ""
    @State private var selection = Set<QSO.ID>()
    @State private var confirmDelete = false
    @State private var deletion: QSODeletion?
    @State private var info: String?

    /// Wyszukiwanie (znak, kraj, imię), filtry: potwierdzenia, pasmo, emisja, okres; potem sortowanie kolumn.
    private var filtered: [QSO] {
        let query = search.trimmingCharacters(in: .whitespaces).uppercased()
        let since = (QSOMapPeriod(rawValue: periodFilter) ?? .all).start
        let list = store.qsos.filter { q in
            if !query.isEmpty, !q.call.contains(query), !q.country.uppercased().contains(query),
               !q.name.uppercased().contains(query) { return false }
            if !bandFilter.isEmpty, q.band.lowercased() != bandFilter { return false }
            if !modeFilter.isEmpty, QSOMapView.modeGroup(q) != modeFilter { return false }
            if let since, q.start < since { return false }
            switch qslFilter {
            case 1: return q.isConfirmed(includeEQSL: countEQSL, includeQRZ: countQRZ)
            case 2: return !q.isConfirmed(includeEQSL: countEQSL, includeQRZ: countQRZ)
            default: return true
            }
        }
        return list.sorted(using: sortOrder)
    }

    @State private var sortOrder = [KeyPathComparator(\QSO.start, order: .reverse)]
    @State private var bandFilter = ""
    @State private var modeFilter = ""
    @State private var periodFilter = QSOMapPeriod.all.rawValue

    private var logBands: [String] {
        AwardCalculator.orderedBands(Set(store.qsos.map { $0.band.lowercased() }.filter { !$0.isEmpty }))
    }

    /// Filtr potwierdzeń: 0 wszystkie, 1 potwierdzone, 2 niepotwierdzone (wg źródeł liczonych do statystyk).
    @State private var qslFilter = 0
    @State private var showQSL = false
    @State private var showDXCC = false
    @State private var showMap = false
    @State private var showStats = false
    @State private var showManualQSO = false
    @AppStorage("qsl.countEQSL") private var countEQSL = false
    @AppStorage("qsl.countQRZ") private var countQRZ = false

    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.current.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settings
            toolbar
            table
            if let error = store.lastError.map(Lr) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text(verbatim: L("Plik dziennika: {1}", store.fileURL.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .id(languageCode)                              // zmiana języka przebudowuje okno
        .navigationTitle(L("Dziennik łączności"))
        .frame(minWidth: 980, minHeight: 520)
        .sheet(isPresented: $showIntegrations) {
            IntegrationsView(uploader: uploader, store: store)
        }
        .sheet(item: $importPreview) { preview in
            ImportPreviewView(preview: preview) {
                store.addImported(preview.analysis.newQSOs)
                info = L("Import: dodano {1}, duplikaty {2}, pominięte {3}",
                         preview.analysis.newQSOs.count, preview.analysis.duplicates.count, preview.analysis.invalid)
            }
        }
        .sheet(isPresented: $showRestore) {
            RestoreBackupView(store: store) { message in info = message }
        }
        .sheet(isPresented: $confirmDeleteAll) {
            DeleteAllConfirmView(count: store.qsos.count) {
                if let backup = store.deleteAll() {
                    selection.removeAll()
                    info = L("Usunięto cały dziennik. Kopia: {1}", backup.lastPathComponent)
                }
            }
        }
        .sheet(item: $editing) { qso in
            QSOEditView(qso: qso, qrz: qrz, fallbackMyGrid: store.myGrid,
                        onDelete: {
                            // po zamknięciu okna edycji - potwierdzenie (z serwisami)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { deletion = QSODeletion(qsos: [qso]) }
                        }) { store.edit($0) }
        }
        // przycisk Usuń…, menu, klawisz Delete - okno potwierdzenia z serwisami
        .onChange(of: confirmDelete) { requested in
            guard requested else { return }
            confirmDelete = false
            let list = store.qsos.filter { selection.contains($0.id) }
            if !list.isEmpty { deletion = QSODeletion(qsos: list) }
        }
        .sheet(item: $deletion) { d in
            DeleteQSOsView(qsos: d.qsos, uploader: uploader) { services in
                selection.subtract(d.qsos.map(\.id))
                store.delete(ids: Set(d.qsos.map(\.id)))
                guard !services.isEmpty else { info = L("Usunięto {1} QSO", d.qsos.count); return }
                info = L("Usunięto {1} QSO - usuwanie w serwisach…", d.qsos.count)
                Task { info = (await uploader.deleteRemote(d.qsos, services: services)).joined(separator: " · ") }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            stationSettings
            qrzSettings
        }
    }

    /// Konto QRZ.com: nazwa w ustawieniach, hasło w pęku kluczy macOS.
    private var qrzSettings: some View {
        HStack(spacing: 10) {
            Text("QRZ.com").font(.system(size: 12, weight: .semibold))
            TextField(L("Użytkownik QRZ"), text: $qrzUser).frame(width: 140)
            SecureField(qrz.hasPassword ? L("Hasło (zapisane)") : L("Hasło"), text: $qrzPassword).frame(width: 150)
            Button(L("Zapisz")) {
                qrz.saveCredentials(username: qrzUser, password: qrzPassword)
                qrzPassword = ""
            }
            .disabled(qrzUser.trimmingCharacters(in: .whitespaces).isEmpty)
            if qrz.hasPassword {
                Button(L("Usuń konto")) {
                    qrz.forget()
                    qrzPassword = ""
                }
            }
            Text(Lr(qrz.status))
                .font(.caption)
                .foregroundStyle(isErrorStatus(qrz.status) ? .red : .secondary)
                .lineLimit(1)
            Spacer()
            Text(L("Hasło jest przechowywane w pęku kluczy macOS."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            qrzUser = qrz.username
            QSLDownloader.shared.attach(store: store, uploader: uploader)
        }
        .sheet(isPresented: $showQSL) {
            QSLDownloadView(downloader: QSLDownloader.shared, store: store)
        }
        .sheet(isPresented: $showDXCC) { AwardsView(store: store) }
        .sheet(isPresented: $showStats) { StatisticsView(store: store) }
        .sheet(isPresented: $showManualQSO) { ManualQSOView(store: store) }
        .sheet(isPresented: $showMap) {
            QSOMapView(store: store) { qso in
                showMap = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { editing = qso }
            }
        }
    }

    private var stationSettings: some View {
        HStack(spacing: 14) {
            TextField(L("Mój znak"), text: $store.myCall).frame(width: 120)
            TextField(L("Mój lokator"), text: $store.myGrid).frame(width: 100)
            Divider().frame(height: 18)
            Toggle(L("Odbieraj QSO z WSJT-X / JTDX"), isOn: $store.wsjtxEnabled)
            HStack(spacing: 4) {
                Text(L("port UDP")).font(.caption)
                TextField("", value: $store.wsjtxPort, format: .number.grouping(.never))
                    .frame(width: 60)
                    .disabled(store.wsjtxEnabled)
            }
            Text(Lr(store.wsjtxStatus))
                .font(.caption)
                .foregroundStyle(isErrorStatus(store.wsjtxStatus) ? .red : .secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    /// Pasek nad tabelą: wiersz wyszukiwania i filtrów, wiersz działań, komunikaty (tylko gdy są).
    /// Przyciski mają stałą szerokość według treści - nie zgniatają się przy węższym oknie.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(L("Szukaj (znak, kraj, imię)"), text: $search).frame(width: 200)
                Picker("", selection: $bandFilter) {
                    Text(L("Wszystkie pasma")).tag("")
                    ForEach(logBands, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $modeFilter) {
                    Text(L("Wszystkie emisje")).tag("")
                    ForEach(QSOMapView.modeGroups, id: \.self) { Text(QSOMapView.modeGroupName($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $periodFilter) {
                    ForEach(QSOMapPeriod.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: $qslFilter) {
                    Text(L("Wszystkie")).tag(0)
                    Text(L("Potwierdzone")).tag(1)
                    Text(L("Niepotwierdzone")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(L("Potwierdzone przez LoTW (oraz eQSL / QRZ, jeśli włączone w oknie potwierdzeń)"))
                Spacer(minLength: 8)
                Text(verbatim: L("{1} z {2} QSO", filtered.count, store.qsos.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Button(L("Edytuj…")) { editSelected() }
                    .disabled(selection.count != 1)
                    .fixedSize()
                Button(L("Usuń…")) { confirmDelete = true }
                    .disabled(selection.isEmpty)
                    .fixedSize()
                Divider().frame(height: 16)
                Button(L("Dodaj QSO…")) { showManualQSO = true }
                    .help(L("Ręczne dodanie łączności - np. z drugiego radia (2 m, 70 cm, 23 cm): pasmo, data UTC, emisja, propagacja, radio i moc"))
                    .fixedSize()
                Button(L("Statystyki…")) { showStats = true }
                    .help(L("Wykresy: łączności w latach, pasma, emisje, kontynenty, godziny"))
                    .fixedSize()
                Button(L("Mapa łączności…")) { showMap = true }
                    .help(L("Kula ziemska 3D z Twoimi łącznościami - kolory pasm, emisji albo potwierdzeń, filtry, linie po kole wielkim"))
                    .fixedSize()
                Button(L("Dyplomy…")) { showDXCC = true }
                    .help(L("DXCC, WAZ, WPX, VUCC i POTA - zrobione i potwierdzone, ogólnie i na pasmach"))
                    .fixedSize()
                Button(L("Potwierdzenia QSL…")) { showQSL = true }
                    .help(L("Pobieranie potwierdzeń z LoTW, eQSL i QRZ Logbook, import z pliku ADIF"))
                    .fixedSize()
                Spacer(minLength: 8)
                Button(L("Usługi online…")) { showIntegrations = true }
                    .help(L("LoTW, QRZ Logbook, eQSL, Club Log, HRDLog.net, Cloudlog - ustawienia i wysyłka"))
                    .fixedSize()
                Menu(L("Plik i kopie")) {
                    Button(L("Importuj ADIF…")) { importADIF() }
                    Button(selection.isEmpty ? L("Eksportuj ADIF…") : L("Eksportuj zaznaczone…")) { exportADIF() }
                        .disabled(store.qsos.isEmpty)
                    Divider()
                    Toggle(L("Kopia w iCloud"), isOn: $store.iCloudBackupEnabled)
                    Button(L("Zrób kopię teraz")) { store.backupToICloud() }
                        .disabled(!store.iCloudBackupEnabled)
                    Button(L("Pokaż w Finderze")) { store.revealICloudBackups() }
                        .disabled(!store.iCloudBackupEnabled)
                    Button(L("Przywróć z kopii…")) { showRestore = true }
                    Divider()
                    Button(L("Usuń cały dziennik…"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(store.qsos.isEmpty)
                }
                .fixedSize()
                .help(store.iCloudStatus.isEmpty
                      ? L("Import i eksport ADIF, kopia w iCloud Drive, przywracanie z kopii, usuwanie dziennika")
                      : Lr(store.iCloudStatus))
            }
            if store.notice != nil || info != nil {
                HStack(spacing: 12) {
                    if let notice = store.notice.map(Lr) {
                        Text(notice).font(.caption).foregroundStyle(Theme.ok)
                    }
                    if let info {
                        Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Data / czas UTC"), value: \.start) { q in
                Text(utcFormatter.string(from: q.start)).monospacedDigit()
            }
            .width(min: 120, ideal: 130)
            TableColumn(L("Znak"), value: \.call) { q in CallSignLink(call: q.call) }
                .width(min: 80, ideal: 100)
            // Pasmo i tryb w jednej kolumnie - Table na macOS 13 przyjmuje najwyżej 10 kolumn, a doszła „QSL”
            TableColumn(L("Pasmo / tryb"), value: \.freqHz) { q in Text(q.band + " " + q.modeLabel) }
                .width(min: 70, ideal: 85)
            TableColumn(L("Częstotliwość"), value: \.freqHz) { q in
                Text(q.freqHz > 0 ? formatFrequency(q.freqHz) : "").monospacedDigit()
            }
            .width(min: 90, ideal: 100)
            TableColumn("QSL", value: \.qslMarks) { q in Text(q.qslMarks).monospaced().foregroundStyle(Theme.ok) }
                .width(min: 40, ideal: 55)
            TableColumn("RST") { q in Text("\(q.rstSent)/\(q.rstRcvd)") }
                .width(min: 45, ideal: 60)
            TableColumn(L("Kraj"), value: \.country) { q in Text(q.country) }
                .width(min: 60, ideal: 100)
            TableColumn(L("Imię / QTH")) { q in
                Text([q.name, q.qth].filter { !$0.isEmpty }.joined(separator: ", "))
            }
            TableColumn(L("Lokator"), value: \.grid) { q in Text(q.grid) }
                .width(min: 50, ideal: 60)
            TableColumn(L("Uwagi"), value: \.comment) { q in Text(q.comment) }
        }
        .contextMenu(forSelectionType: QSO.ID.self) { ids in
            Button(L("Edytuj…")) { edit(ids) }
                .disabled(ids.count != 1)
            Divider()
            Button(L("Uzupełnij z QRZ.com")) { fillFromQRZ(ids) }
                .disabled(ids.isEmpty || !qrz.canLookup)
            Button(L("Wyślij SPOT…")) { prepareSpot(ids) }
                .disabled(spotCommand(ids) == nil)
            Divider()
            Button(L("Usuń…")) {
                selection = ids
                confirmDelete = true
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            edit(ids)                                   // podwójne kliknięcie
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }   // klawisz Delete (z potwierdzeniem)
    }

    private func editSelected() { edit(selection) }

    private func fillFromQRZ(_ ids: Set<QSO.ID>) {
        info = L("Pobieranie danych z QRZ.com…")
        Task { info = await store.fillFromQRZ(ids: ids, qrz: qrz) }
    }

    private func spotCommand(_ ids: Set<QSO.ID>) -> String? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return store.qsos.first { $0.id == id }?.spotCommand
    }

    /// Spot trafia do pola komendy DX Cluster w głównym oknie (do sprawdzenia i wysłania).
    private func prepareSpot(_ ids: Set<QSO.ID>) {
        guard let command = spotCommand(ids) else { return }
        NotificationCenter.default.post(name: .prepareSpot, object: nil, userInfo: ["command": command])
    }

    private func edit(_ ids: Set<QSO.ID>) {
        guard ids.count == 1, let id = ids.first, let qso = store.qsos.first(where: { $0.id == id }) else { return }
        editing = qso
    }

    // MARK: - Import / eksport

    private func importADIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "adi"), UTType(filenameExtension: "adif"), .plainText]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Większość programów zapisuje UTF-8 albo czyste ASCII; starsze - Latin-1.
            let text = try (try? String(contentsOf: url, encoding: .utf8))
                ?? String(contentsOf: url, encoding: .isoLatin1)
            // Najpierw sprawdzenie i podgląd - zapis dopiero po zatwierdzeniu.
            importPreview = ImportPreview(fileName: url.lastPathComponent, analysis: store.analyzeImport(text))
        } catch {
            info = L("Nie udało się odczytać pliku: {1}", error.localizedDescription)
        }
    }

    private func exportADIF() {
        let chosen = selection.isEmpty ? store.qsos : store.qsos.filter { selection.contains($0.id) }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = L("dziennik-{1}.adi", stamp)
        panel.allowedContentTypes = [UTType(filenameExtension: "adi")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ADIF.asciiFile(ADIF.export(chosen)).write(to: url, atomically: true, encoding: .ascii)
            info = L("Wyeksportowano {1} QSO do {2}", chosen.count, url.lastPathComponent)
        } catch {
            info = L("Eksport nie powiódł się: {1}", error.localizedDescription)
        }
    }
}

/// Znak jako link: kliknięcie otwiera stronę stacji na QRZ.com (znak bazowy, bez /P itp.).
struct CallSignLink: View {
    let call: String
    @State private var hovering = false

    var body: some View {
        Text(call)
            .bold()
            .foregroundStyle(Theme.accent)
            .underline(hovering)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
            .onTapGesture {
                if let url = URL(string: "https://www.qrz.com/db/\(QRZClient.baseCall(call))") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help(L("Otwórz {1} w QRZ.com", call))
    }
}

/// Potwierdzenie usunięcia całego dziennika: trzeba wpisać słowo (USUŃ / DELETE).
struct DeleteAllConfirmView: View {
    let count: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var keyword: String { L("USUŃ") }
    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces).uppercased() == keyword }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Usunąć cały dziennik?"), systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text(L("Zostanie usuniętych {1} łączności. Przed usunięciem program zapisze ich kopię w katalogu danych (plik logbook-przed-usunieciem-….json), z której można je odtworzyć.", count))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Aby potwierdzić, wpisz {1}:", keyword))
                .font(.callout.bold())
            TextField(keyword, text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if matches { confirm() } }
            HStack {
                Spacer()
                Button(L("Anuluj"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { confirm() } label: {
                    Text(L("Usuń cały dziennik"))
                }
                .disabled(!matches)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func confirm() {
        guard matches else { return }
        onConfirm()
        dismiss()
    }
}

/// Przywracanie dziennika z kopii: lista kopii z katalogu danych albo dowolny plik.
struct RestoreBackupView: View {
    @ObservedObject var store: LogbookStore
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [LogbookBackup] = []
    @State private var selection: LogbookBackup.ID?
    @State private var otherFile: LogbookBackup?
    @State private var confirmReplace = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private var chosen: LogbookBackup? {
        if let otherFile, otherFile.id == selection { return otherFile }
        return backups.first { $0.id == selection }
    }

    private var rows: [LogbookBackup] {
        (otherFile.map { [$0] } ?? []) + backups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Przywróć dziennik z kopii")).font(.title2.bold())
            Text(L("Bieżący dziennik: {1} QSO. Wybierz kopię:", store.qsos.count))
                .foregroundStyle(.secondary)

            Table(rows, selection: $selection) {
                TableColumn(L("Data")) { b in Text(Self.dateFormatter.string(from: b.date)).monospacedDigit() }
                    .width(min: 150, ideal: 170)
                TableColumn("QSO") { b in Text("\(b.count)").monospacedDigit() }
                    .width(min: 45, ideal: 55)
                TableColumn(L("Rodzaj")) { b in Text(b.kind) }
                TableColumn(L("Plik")) { b in Text(b.url.lastPathComponent).foregroundStyle(.secondary) }
            }
            .frame(minHeight: 200)

            if backups.isEmpty && otherFile == nil {
                Text(L("Brak kopii w katalogu danych - wybierz plik ręcznie."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(L("Wybierz inny plik…")) { chooseFile() }
                Spacer()
                Button(L("Anuluj"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Dołącz do dziennika")) { restore(replace: false) }
                    .disabled(chosen == nil)
                    .help(L("Dodaje łączności z kopii, pomija te, które już są w dzienniku"))
                Button(L("Zastąp dziennik…")) { confirmReplace = true }
                    .disabled(chosen == nil)
                    .help(L("Zastępuje cały dziennik kopią (wcześniej zapisuje kopię bieżącego stanu)"))
            }
        }
        .padding(20)
        .frame(width: 680, height: 420)
        .onAppear {
            backups = store.backups()
            selection = backups.first?.id
        }
        .confirmationDialog(Text(L("Zastąpić bieżący dziennik ({1} QSO) kopią ({2} QSO)?",
                                   store.qsos.count, chosen?.count ?? 0)),
                            isPresented: $confirmReplace) {
            Button(L("Zastąp dziennik"), role: .destructive) { restore(replace: true) }
        } message: {
            Text(L("Przed zastąpieniem program zapisze kopię bieżącego dziennika, więc tę operację też można cofnąć."))
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let qsos = try? LogbookStore.decode(url) else {
            onResult(L("Ten plik nie jest kopią dziennika FT-710 Control (do plików ADIF użyj „Importuj ADIF…”)."))
            return
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let file = LogbookBackup(url: url, date: date, count: qsos.count)
        otherFile = file
        selection = file.id
    }

    private func restore(replace: Bool) {
        guard let chosen else { return }
        onResult(store.restore(from: chosen.url, replace: replace))
        dismiss()
    }
}

/// Dane podglądu importu (do arkusza).
struct ImportPreview: Identifiable {
    let id = UUID()
    let fileName: String
    let analysis: ImportAnalysis
}

/// Podgląd importu ADIF: ile nowych łączności, ile duplikatów (i z czym się pokrywają).
/// Zapisywane są tylko nowe łączności, po zatwierdzeniu.
struct ImportPreviewView: View {
    let preview: ImportPreview
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var analysis: ImportAnalysis { preview.analysis }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Import ADIF: {1}", preview.fileName)).font(.title2.bold())

            HStack(spacing: 18) {
                summary(L("Nowe łączności"), analysis.newQSOs.count, Theme.ok)
                summary(L("Duplikaty (pominięte)"), analysis.duplicates.count, Theme.header)
                summary(L("Błędne rekordy"), analysis.invalid, .secondary)
            }

            if analysis.duplicates.isEmpty {
                Text(L("W pliku nie ma łączności, które już są w dzienniku."))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text(L("Te łączności już są w dzienniku (ten sam znak, pasmo, tryb i czas w odstępie do 10 minut) - nie zostaną dodane:"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Table(analysis.duplicates) {
                    TableColumn(L("Znak")) { d in Text(d.imported.call).bold() }
                        .width(min: 70, ideal: 90)
                    TableColumn(L("W pliku (UTC)")) { d in Text(Self.formatter.string(from: d.imported.start)).monospacedDigit() }
                        .width(min: 110, ideal: 120)
                    TableColumn(L("Pasmo")) { d in Text(d.imported.band) }
                        .width(min: 40, ideal: 50)
                    TableColumn(L("Tryb")) { d in Text(d.imported.modeLabel) }
                        .width(min: 40, ideal: 55)
                    TableColumn(L("Pokrywa się z")) { d in
                        Text(d.inFile ? L("wcześniejszym rekordem w pliku")
                                      : L("QSO z {1}", Self.formatter.string(from: d.existing.start)))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 180)
            }

            if analysis.invalid > 0 {
                Text(L("Błędne rekordy (bez znaku albo daty) zostaną pominięte."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L("Anuluj"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Importuj nowe ({1})", analysis.newQSOs.count)) {
                    onImport()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(analysis.newQSOs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }

    private func summary(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 26, weight: .bold)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Podpowiedź „czy już robiłem tę stację”: plakietka (nowa stacja / nowe pasmo / nowy tryb / zrobione)
/// i ostatnie łączności z nią.
struct WorkedBeforeView: View {
    let call: String
    let previous: [QSO]          // najnowsze pierwsze
    let band: String?            // bieżące pasmo radia (nil = brak częstotliwości)
    let modeFamily: String       // rodzina trybu wybranego w formularzu

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var onBand: [QSO] { band.map { b in previous.filter { $0.band == b } } ?? [] }
    private var onBandAndMode: [QSO] { onBand.filter { LogbookStore.modeFamily($0) == modeFamily } }

    private var badge: (text: String, color: Color) {
        if previous.isEmpty { return (L("NOWA STACJA"), Theme.ok) }
        guard let band else { return (L("JUŻ W DZIENNIKU"), Theme.header) }
        if onBand.isEmpty { return (L("NOWE PASMO: {1}", band), Theme.header) }
        if onBandAndMode.isEmpty { return (L("NOWY TRYB NA {1}: {2}", band, modeFamily), Theme.header) }
        return (L("ZROBIONE: {1} {2} ({3}×)", band, modeFamily, onBandAndMode.count), .orange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(badge.text)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Color.black)
                    .background(badge.color, in: RoundedRectangle(cornerRadius: 3))
                if previous.isEmpty {
                    Text(L("Brak wcześniejszych łączności z {1}.", QRZClient.baseCall(call)))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let bands = Array(Set(previous.map(\.band))).filter { !$0.isEmpty }.sorted()
                    Text(L("{1} QSO z {2} · pasma: {3}", previous.count, QRZClient.baseCall(call), bands.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(previous.prefix(3)) { qso in
                HStack(spacing: 10) {
                    Text(Self.formatter.string(from: qso.start)).monospacedDigit()
                    Text(qso.band).frame(width: 36, alignment: .leading)
                    Text(qso.modeLabel).frame(width: 44, alignment: .leading)
                    Text("\(qso.rstSent)/\(qso.rstRcvd)").frame(width: 56, alignment: .leading)
                    Text(qso.call == call ? qso.name : qso.call + "  " + qso.name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .foregroundStyle(qso.band == band && LogbookStore.modeFamily(qso) == modeFamily ? Color.orange : Theme.text)
            }
            if previous.count > 3 {
                Text(L("… i jeszcze {1} - pełna lista w oknie dziennika", previous.count - 3))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
