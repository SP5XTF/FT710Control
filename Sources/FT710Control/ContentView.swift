import SwiftUI
import AppKit
import CoreAudio

/// Główne okno: panel radia w układzie trzech kolumn (pasma/tryby/DSP – VFO, mierniki, skop – suwaki/TX),
/// zakładki narzędzi na dole i pasek stanu połączenia.
struct ContentView: View {
    @StateObject private var cat = CATClient()
    @StateObject private var audio = AudioManager()
    // Skop, CAT Share i praca zdalna: tworzone raz, ale NIE obserwowane przez okno - ich częste publikacje
    // (liczniki co sekundę, dzienniki przy każdym zapytaniu CAT Share) przebudowywały całe okno (pomiar
    // Instruments). Ich stan pokazują małe widoki, które obserwują je same (RFScopeView, LiveStatusText,
    // ConnectionBadges, CATShareSection, zakładka ZDALNIE).
    @StateObject private var shareBox = Unobserved(CATShareServer())
    @StateObject private var rfScopeBox = Unobserved(RFScopeController())
    @StateObject private var remoteBox = Unobserved(RemoteStation())
    private var share: CATShareServer { shareBox.value }
    private var rfScope: RFScopeController { rfScopeBox.value }
    private var remote: RemoteStation { remoteBox.value }
    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var qrz: QRZClient
    @EnvironmentObject private var uploader: LogUploader
    @StateObject private var lookup = CallLookup()
    /// Klient klastra DX w „uchwycie” bez publikowania - okno nie przerysowuje się przy każdym spocie.
    @StateObject private var clusterHolder = DXClusterHolder()
    /// Moduł SSTV w „uchwycie” bez publikowania - okno nie przerysowuje się przy każdej linii obrazu.
    @StateObject private var sstvHolder = SSTVHolder()
    /// Moduł CW w „uchwycie” bez publikowania - okno nie przerysowuje się przy każdym znaku.
    @StateObject private var cwHolder = CWHolder()
    @StateObject private var rttyHolder = RTTYHolder()
    @StateObject private var ft8Holder = FT8Holder()
    /// Wpisywane QSO - poza widokiem zakładki, żeby przełączanie zakładek go nie kasowało.
    @StateObject private var quickLogDraft = QuickLogDraft()
    @StateObject private var potaHolder = POTAHolder()
    @StateObject private var contestHolder = ContestHolder()
    /// Wspólna usługa propagacji (zakładka i okno mapy); okno jej nie obserwuje - bez zbędnych przerysowań.
    private let propagation = PropagationService.shared
    private var cluster: DXClusterClient { clusterHolder.client }
    @State private var selectedQSO = Set<QSO.ID>()
    @State private var editingQSO: QSO?
    @State private var logInfo: String?
    @State private var qsoDeletion: QSODeletion?
    @Environment(\.openWindow) private var openWindow
    @State private var txArmed = false
    @State private var pttPressed = false
    @State private var pttLockedOut = false     // po limicie czasu: PTT nieaktywne do puszczenia przycisku
    @State private var showDiagnostics = false
    @State private var tab: BottomTab = .log
    @State private var tuneStep = 500
    @State private var txStartedAt: Date?
    @State private var digitSelection: DigitSelection?
    /// Język interfejsu - zmiana przebudowuje widoki (bez rozłączania radia: modele zostają).
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.current.rawValue

    enum BottomTab: String, CaseIterable, Identifiable {
        case log = "DZIENNIK"
        case dxCluster = "DX CLUSTER"
        case sstv = "SSTV"
        case cw = "CW"
        case rtty = "RTTY"
        case ft8 = "FT8/FT4"
        case pota = "POTA"
        case contest = "ZAWODY"
        case propagation = "PROPAGACJA"
        case display = "EKRAN"
        case audio = "AUDIO"
        case spectrum = "WIDMO AUDIO"
        case catShare = "CAT SHARE"
        case remote = "ZDALNIE"
        case catLog = "LOG CAT"
        var id: String { rawValue }
    }

    var body: some View {
        let _ = RenderStats.tick("okno")
        // Górna część zajmuje całą wysokość nad panelem zakładek. Skop w środku się rozciąga,
        // a boczne kolumny mają dokładnie tę samą wysokość (przy małym oknie przewijają się wewnątrz),
        // więc kończą się równo z dołem waterfalla. Panel zakładek jest na stałe tuż pod skopem.
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                sideColumn { leftColumn }.frame(width: 214)
                centerColumn
                rightColumn.frame(width: 240)
            }
            .frame(maxHeight: .infinity)
            bottomPanel
                .frame(height: Self.bottomPanelHeight)
        }
        .padding(8)
        .id(languageCode)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1480, minHeight: 900)
        .onChange(of: txArmed) { armed in
            if !armed { releasePTT() }      // wyłączenie odblokowania zawsze kończy nadawanie
            audio.updateTXPath(armed: armed)
        }
        .onChange(of: audio.txOverUSB) { _ in audio.updateTXPath(armed: txArmed) }
        .onChange(of: cat.txTimeoutCount) { _ in
            // CATClient już wysłał TX0; wycisz mikrofon i nie pozwól zakluczyć ponownie do puszczenia przycisku.
            if pttPressed {
                pttPressed = false
                pttLockedOut = true
                audio.endTX()
            }
        }
        .onChange(of: cat.transmitting) { tx in txStartedAt = tx ? Date() : nil }
        .onChange(of: cat.isConnected) { connected in if !connected { digitSelection = nil } }
        .background(
            ArrowKeyMonitor(active: digitSelection != nil && cat.isConnected) { code in handleArrow(code) }
        )
        .onChange(of: txArmed) { armed in
            if !armed { cwHolder.manager.shutdownTX() }          // klucz CW zwolniony niezależnie od zakładki
            if !armed, rttyHolder.manager.transmitting { rttyHolder.manager.stopTX() }
            ft8Holder.manager.setTXArmed(armed)                 // cofnięcie zgody przerywa też FT8
        }
        // Spot POTA: numer parku do formularza dziennika (znak przychodzi przez logbook.prefill).
        .onReceive(NotificationCenter.default.publisher(for: .potaSelected)) { note in
            quickLogDraft.potaCall = note.userInfo?["call"] as? String ?? ""
            quickLogDraft.potaRef = note.userInfo?["reference"] as? String ?? ""
            quickLogDraft.potaPark = note.userInfo?["park"] as? String ?? ""
        }
        // Kliknięty alert (lista albo powiadomienie macOS) - to samo, co kliknięcie w źródle.
        .onReceive(NotificationCenter.default.publisher(for: .alertActivated)) { note in
            guard let id = note.userInfo?["id"] as? UUID, let item = AlertCenter.shared.item(id) else { return }
            switch item.origin {
            case .cluster(let spot):
                tuneToSpot(spot)
                logbook.prefill(spot.call)
            case .pota(let spot):
                potaHolder.manager.select(spot)
            case .ft8(let decode):
                tab = .ft8
                ft8Holder.manager.select(decode)
            case .qsl:
                openWindow(id: "logbook")                          // nowe potwierdzenia - okno dziennika
            }
        }
        // Dwuklik spotu POTA - przejście do zakładki DZIENNIK.
        .onReceive(NotificationCenter.default.publisher(for: .showLogTab)) { _ in tab = .log }
        // QSO zapisane inną drogą (FT8, WSJT-X, zawody) - formularz dziennika nie trzyma już tej stacji.
        .onReceive(NotificationCenter.default.publisher(for: .qsoLogged)) { note in
            if let call = note.userInfo?["call"] as? String {
                quickLogDraft.loggedElsewhere(call, radioMode: cat.modeCode)
            }
        }
        // Spot przygotowany w oknie dziennika (menu prawego przycisku) - do pola komendy DX Cluster.
        .onReceive(NotificationCenter.default.publisher(for: .prepareSpot)) { note in
            openSpot(note.userInfo?["command"] as? String)
        }
        .onChange(of: cat.isConnected) { connected in
            if !connected { cwHolder.manager.shutdownTX() }
            if !connected, rttyHolder.manager.transmitting { rttyHolder.manager.stopTX() }
            if !connected { ft8Holder.manager.haltTX() }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(cat: cat, audio: audio)
        }
        .sheet(item: $editingQSO) { qso in
            QSOEditView(qso: qso, qrz: qrz, fallbackMyGrid: logbook.myGrid,
                        onDelete: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { qsoDeletion = QSODeletion(qsos: [qso]) }
                        }) { logbook.edit($0) }
        }
        .sheet(item: $qsoDeletion) { d in
            DeleteQSOsView(qsos: d.qsos, uploader: uploader) { services in
                logbook.delete(ids: Set(d.qsos.map(\.id)))
                guard !services.isEmpty else { logInfo = L("Usunięto {1} QSO", d.qsos.count); return }
                logInfo = L("Usunięto {1} QSO - usuwanie w serwisach…", d.qsos.count)
                Task { logInfo = (await uploader.deleteRemote(d.qsos, services: services)).joined(separator: " · ") }
            }
        }
        .onAppear {
            UpdateChecker.shared.startAutomatic()       // nowa wersja na GitHub - przy starcie i raz na dobę
            uploader.attach(logbook)                    // automatyczna wysyłka nowych QSO do serwisów
            cat.startAutoConnect()                      // zapamiętany port radia
            rfScope.startIfEnabled()                    // waterfall domyślnie włączony
            let book = logbook
            sstvHolder.manager.attach(audio: audio, cat: cat, callsign: { book.myCall })
            cwHolder.manager.attach(audio: audio, cat: cat, logbook: logbook)
            rttyHolder.manager.attach(audio: audio, cat: cat, logbook: logbook)
            ft8Holder.manager.attach(audio: audio, cat: cat, logbook: logbook)
            ft8Holder.manager.setTXArmed(txArmed)
            potaHolder.manager.attach(cat: cat, logbook: logbook)
            potaHolder.manager.start()                             // spoty POTA od startu: skop i alerty
            QSLDownloader.shared.attach(store: logbook, uploader: uploader)
            QSLDownloader.shared.startAuto()                       // potwierdzenia QSL raz dziennie w tle
            WorkedIndexStore.shared.attach(logbook)                // stan krajów dla DX Cluster
            AlertCenter.shared.attach(cluster: cluster)            // alerty: DX Cluster (FT8 i POTA zgłaszają same)
            contestHolder.manager.attach(logbook: logbook, cat: cat, qrz: qrz)
            // Pierwsze uruchomienie: okno powitalne z profilem stacji.
            if !UserDefaults.standard.bool(forKey: StationProfileView.completedKey) {
                openWindow(id: "profile")
            }
            if cluster.autoConnect, cluster.state == .disconnected {
                cluster.connect(fallbackCall: logbook.myCall)
            }
            share.attach(cat)
            remote.attach(cat: cat, audio: audio, scope: rfScope)
            remote.attachSpots(cluster: cluster, pota: potaHolder.manager)
            remote.attachOperating(logbook: logbook, qrz: qrz, cw: cwHolder.manager)
            remote.attachFT8(ft8Holder.manager)
        }
        .onDisappear {
            cluster.disconnect()
            remote.stop()
            rfScope.enabled = false
            share.stop()
            releasePTT()
            audio.stopAll()
            cat.disconnect()
        }
    }

    private var splitOn: Bool { (cat.value(.split) ?? 0) != 0 }

    /// Zmiana częstotliwości VFO o `steps` jednostek cyfry o wadze `weight` (kółko myszy, strzałki).
    private func stepVFO(_ vfo: String, weight: Int, steps: Int) {
        let current = vfo == "A" ? cat.freqA : cat.freqB
        guard cat.isConnected, current > 0, steps != 0 else { return }
        cat.setFrequency(vfo: vfo, hz: current + weight * steps)
    }

    /// Strzałki dla zaznaczonej cyfry: ↑↓ zmiana, ←→ sąsiednia cyfra, Esc koniec zaznaczenia.
    private func handleArrow(_ code: UInt16) -> Bool {
        guard var selection = digitSelection else { return false }
        switch code {
        case 126: stepVFO(selection.vfo, weight: selection.weight, steps: 1)      // ↑
        case 125: stepVFO(selection.vfo, weight: selection.weight, steps: -1)     // ↓
        case 123:                                                                  // ←
            selection.weight = min(selection.weight * 10, 10_000_000)
            digitSelection = selection
        case 124:                                                                  // →
            selection.weight = max(selection.weight / 10, 1)
            digitSelection = selection
        case 53: digitSelection = nil                                              // Esc
        default: return false
        }
        return true
    }

    /// Strojenie do spotu z klastra: częstotliwość (w trybach cyfrowych - „dial” FT8/FT4)
    /// i opcjonalnie tryb. Spoty spoza pasm FT-710 są pomijane.
    private func tuneToSpot(_ spot: DXSpot) {
        guard cat.isConnected, Bands.name(for: spot.frequencyHz) != nil else { return }
        cat.setActiveFrequency(spot.tuneHz)
        let setsMode = UserDefaults.standard.object(forKey: "clusterSetsMode") as? Bool ?? true
        if setsMode, cat.modeCode != spot.radioModeCode { cat.setMode(spot.radioModeCode) }
    }

    /// Aktywacja POTA ze skopu w zakładce ZAWODY: tylko strojenie i tryb (znak trafia do pola zawodów).
    private func tuneToSpot(potaSpot spot: POTASpot) {
        guard cat.isConnected else { return }
        cat.setActiveFrequency(spot.frequencyHz)
        if let code = POTAManager.radioMode(for: spot), cat.modeCode != code { cat.setMode(code) }
    }

    /// Spot w polu komendy DX Cluster: zakładka klastra na wierzchu, nic nie jest wysyłane bez Twojej decyzji.
    private func openSpot(_ command: String?) {
        guard let command else { return }
        cluster.draftCommand = command
        tab = .dxCluster
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "FT-710 Control" }?.makeKeyAndOrderFront(nil)
    }

    /// Wysokość panelu zakładek pod skopem.
    private static let bottomPanelHeight: CGFloat = 360

    /// Boczna kolumna: wysokość jak środek; nadmiar przewija się wewnątrz kolumny.
    private func sideColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func releasePTT() {
        guard pttPressed else { return }
        pttPressed = false
        audio.endTX()
        cat.ptt(false)
    }

    // MARK: - Lewa kolumna: pasma, tryby, DSP

    private struct BandButton: Identifiable {
        let label: String
        let hz: Int
        let band: String
        var id: String { label }
    }

    private static let bandButtons: [BandButton] = [
        BandButton(label: "1.8", hz: 1_840_000, band: "160m"), BandButton(label: "3.5", hz: 3_700_000, band: "80m"),
        BandButton(label: "5", hz: 5_354_000, band: "60m"), BandButton(label: "7", hz: 7_100_000, band: "40m"),
        BandButton(label: "10", hz: 10_120_000, band: "30m"), BandButton(label: "14", hz: 14_200_000, band: "20m"),
        BandButton(label: "18", hz: 18_120_000, band: "17m"), BandButton(label: "21", hz: 21_200_000, band: "15m"),
        BandButton(label: "24", hz: 24_940_000, band: "12m"), BandButton(label: "28", hz: 28_400_000, band: "10m"),
        BandButton(label: "50", hz: 50_150_000, band: "6m"), BandButton(label: "70", hz: 70_200_000, band: "4m")
    ]


    /// Tryb po zmianie pasma: "ssb" - zawsze SSB z właściwą wstęgą (domyślnie), "sideband" - tylko popraw
    /// wstęgę, gdy radio jest w SSB, "keep" - bez zmian.
    @AppStorage("bandModePolicy") private var bandModePolicy = "ssb"

    /// Wstęga wg konwencji (band plan IARU): LSB poniżej 10 MHz, USB od 10 MHz; wyjątek 60 m (5 MHz) - USB.
    static func sideband(for hz: Int) -> String {
        let is60m = (5_000_000..<5_500_000).contains(hz)
        return hz < 10_000_000 && !is60m ? "1" : "2"                  // MD: 1 = LSB, 2 = USB
    }

    private func selectBand(_ item: BandButton) {
        cat.setActiveFrequency(item.hz)
        let sideband = Self.sideband(for: item.hz)
        switch bandModePolicy {
        case "ssb":
            if cat.modeCode != sideband { cat.setMode(sideband) }
        case "sideband":
            if ["1", "2"].contains(cat.modeCode), cat.modeCode != sideband { cat.setMode(sideband) }
        default:
            break
        }
    }

    private func bandPolicyItem(_ value: String, _ title: String) -> some View {
        Button((bandModePolicy == value ? "✓ " : "    ") + title) { bandModePolicy = value }
    }

    /// Tryby jak na panelu radia: 6 przycisków; CW i DATA przy ponownym kliknięciu przełączają wstęgę.
    private struct ModeButton: Identifiable {
        let label: String
        let codes: [String]           // pierwszy = domyślny
        let toggles: Bool
        var id: String { label }
    }

    private static let modeButtons = [
        ModeButton(label: "LSB", codes: ["1"], toggles: false),
        ModeButton(label: "USB", codes: ["2"], toggles: false),
        ModeButton(label: "CW", codes: ["3", "7"], toggles: true),        // CW-U <-> CW-L
        ModeButton(label: "AM", codes: ["5", "D"], toggles: false),
        ModeButton(label: "FM", codes: ["4", "B"], toggles: false),
        ModeButton(label: "DATA", codes: ["C", "8"], toggles: true)       // DATA-U <-> DATA-L
    ]

    private func modeButton(_ mode: ModeButton) -> some View {
        let active = mode.codes.contains(cat.modeCode)
        let label = active && mode.toggles ? (RadioMode.names[cat.modeCode] ?? mode.label) : mode.label
        return Button(label) {
            if active, mode.toggles, let index = mode.codes.firstIndex(of: cat.modeCode) {
                cat.setMode(mode.codes[(index + 1) % mode.codes.count])
            } else {
                cat.setMode(mode.codes[0])
            }
        }
        .buttonStyle(RigButtonStyle(selected: active))
        .help(mode.toggles ? L("Ponowne kliknięcie przełącza wstęgę (U/L)") : "")
    }

    private var leftColumn: some View {
        VStack(spacing: 8) {
            RigPanel(title: L("Pasmo")) {
                ColumnGrid(Self.bandButtons, id: \.id, columns: 3) { item in
                    Button(item.label) { selectBand(item) }
                        .buttonStyle(RigButtonStyle(selected: Bands.name(for: cat.activeFreq) == item.band))
                        .help(L("Prawy przycisk: tryb po zmianie pasma"))
                }
                .disabled(!cat.isConnected)
                .contextMenu {
                    Text(L("Po zmianie pasma:"))
                    bandPolicyItem("ssb", L("Zawsze SSB – LSB poniżej 10 MHz, USB powyżej (60 m: USB)"))
                    bandPolicyItem("sideband", L("Tylko popraw wstęgę, gdy jest SSB (CW i DATA bez zmian)"))
                    bandPolicyItem("keep", L("Nie zmieniaj trybu"))
                }
            }

            RigPanel(title: L("Tryb")) {
                ColumnGrid(Self.modeButtons, id: \.id, columns: 3) { mode in modeButton(mode) }
                .disabled(!cat.isConnected)
            }

            filterPanel

            RigPanel(title: "AGC") {
                HStack(spacing: 4) {
                    agcButton("FAST", 1)
                    agcButton("MID", 2)
                    agcButton("SLOW", 3)
                    agcButton("AUTO", 4)
                }
            }

            // Szybki wybór redukcji szumu odsłuchu na Macu (pełne ustawienia: zakładka AUDIO)
            RigPanel(title: L("NR Mac (odsłuch)")) {
                HStack(spacing: 4) {
                    ForEach(AudioDenoiser.Level.allCases, id: \.self) { level in
                        Button(level == .off ? "OFF" : (level == .ai ? "AI" : (level == .dx ? "DX" : "\(level.rawValue)"))) { audio.nrLevel = level }
                            .buttonStyle(RigButtonStyle(selected: audio.nrLevel == level))
                            .help(level == .ai ? L("AI – sieć neuronowa RNNoise")
                                  : (level == .dx ? L("Głos DX – wyciąga słabą mowę z szumu (OM-LSA)") : level.name))
                    }
                }
                .disabled(!audio.listening)
                HStack(spacing: 4) {
                    Button("ANF") { audio.nrANF.toggle() }
                        .buttonStyle(RigButtonStyle(selected: audio.nrANF))
                        .help(L("Automatycznie wycina gwizdy i nośne (np. stacja strojąca obok)"))
                    Button("NB") { audio.nrNB.toggle() }
                        .buttonStyle(RigButtonStyle(selected: audio.nrNB))
                        .help(L("Wygasza trzaski i impulsy (wyładowania atmosferyczne, zakłócenia iskrowe)"))
                    Button("APF") { audio.apfEnabled.toggle() }
                        .buttonStyle(RigButtonStyle(selected: audio.apfEnabled))
                        .help(L("Wąski filtr szczytowy dla CW, dostrojony do tonu dekodera"))
                }
                .disabled(!audio.listening)
            }
        }
    }

    /// Filtr odbiornika: wykres pasma, szerokość, przesunięcie, ręczny notch, DNF, contour.
    private var filterPanel: some View {
        let mode = cat.modeCode
        let fixedWidth = FilterTables.kind(for: mode) == .wide
        return RigPanel(title: L("RX DSP / Filtr")) {
            FilterGraph(modeCode: mode,
                        widthIndex: cat.value(.width),
                        shift: cat.value(.ifShift) ?? 0,
                        notchOn: (cat.value(.notch) ?? 0) != 0,
                        notchHz: cat.value(.notchFreq).map { $0 * 10 },
                        contourOn: (cat.value(.contour) ?? 0) != 0,
                        contourHz: cat.value(.contourFreq),
                        dnfOn: (cat.value(.notchAuto) ?? 0) != 0)
                .frame(height: 64)

            controlSlider("RX BW", .width) { FilterTables.label(index: $0, modeCode: mode) + "  #\($0)" }
                .disabled(fixedWidth)
                .help(fixedWidth ? L("W AM/FM szerokość filtra jest stała") : L("Szerokość filtra (indeks komendy SH)"))

            HStack(alignment: .bottom, spacing: 6) {
                RigSlider(title: "SHIFT", value: cat.value(.ifShift), range: RadioControl.ifShift.range,
                          display: { "\($0 > 0 ? "+" : "")\($0) Hz" }) { v in
                    cat.set(.ifShift, v / 20 * 20)          // krok 20 Hz
                }
                .disabled(!cat.isAvailable(.ifShift))
                .opacity(cat.isAvailable(.ifShift) ? 1 : 0.4)
                Button("0") { cat.set(.ifShift, 0) }
                    .buttonStyle(RigButtonStyle(height: 22, fontSize: 11))
                    .frame(width: 30)
                    .disabled(!cat.isAvailable(.ifShift))
                    .help(L("Wyzeruj SHIFT"))
            }

            HStack(spacing: 4) {
                toggleButton("NOTCH", .notch)
                toggleButton("DNF", .notchAuto)
                toggleButton("CONTOUR", .contour)
            }
            controlSlider("NOTCH", .notchFreq) { "\($0 * 10) Hz" }
            controlSlider("CONTOUR", .contourFreq) { "\($0) Hz" }
        }
    }

    private func agcButton(_ label: String, _ value: Int) -> some View {
        let current = cat.value(.agc) ?? -1
        // Radio zgłasza AUTO jako 4, 5 lub 6 (AUTO-FAST/MID/SLOW).
        let selected = value == 4 ? current >= 4 : current == value
        return Button(label) { cat.set(.agc, value) }
            .buttonStyle(RigButtonStyle(selected: selected, fontSize: 11))
            .disabled(!cat.isAvailable(.agc))
    }

    private func toggleButton(_ label: String, _ control: RadioControl) -> some View {
        let on = (cat.value(control) ?? 0) != 0
        return Button(label) { cat.set(control, on ? 0 : 1) }
            .buttonStyle(RigButtonStyle(selected: on))
            .disabled(!cat.isAvailable(control))
    }

    private func controlSlider(_ title: String, _ control: RadioControl,
                               display: ((Int) -> String)? = nil) -> some View {
        RigSlider(title: title, value: cat.value(control), range: control.range, display: display) { v in
            cat.set(control, v)
        }
        .disabled(!cat.isAvailable(control))
        .opacity(cat.isAvailable(control) ? 1 : 0.4)
    }

    // MARK: - Środek: VFO, mierniki, skop

    /// Główny (lewy) wyświetlacz pokazuje aktywne VFO - po A/B okna zamieniają się miejscami, jak na radiu.
    private var vfoADisplay: some View { vfoDisplay(cat.activeVFO, isMain: true) }
    private var vfoBDisplay: some View { vfoDisplay(cat.activeVFO == "A" ? "B" : "A", isMain: false) }

    private func vfoDisplay(_ vfo: String, isMain: Bool) -> some View {
        let isA = vfo == "A"
        // tryby wg litery VFO (MD0 - VFO-A, MD1 - VFO-B) - wędrują razem z częstotliwością
        return VFODisplay(label: isA ? "VFO-A" : "VFO-B", vfo: vfo, hz: isA ? cat.freqA : cat.freqB,
                          mode: isA ? cat.modeNameA : cat.modeNameB, isMain: isMain,
                          role: isMain ? (splitOn ? "RX" : "RX / TX") : (splitOn ? "TX" : nil),
                          transmitting: cat.transmitting && (isMain ? !splitOn : splitOn), enabled: cat.isConnected,
                          selection: $digitSelection,
                          onStep: { weight, steps in stepVFO(vfo, weight: weight, steps: steps) },
                          onSet: { hz in cat.setFrequency(vfo: vfo, hz: hz) },
                          info: isMain ? vfoAInfo : vfoBInfo)
    }

    private var centerColumn: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    // VFO-A i VFO-B obok siebie (minimalna szerokość okna 1480 pt - mieszczą się zawsze).
                    // Bez ViewThatFits: przy każdej zmianie mierzył od nowa oba warianty układu (test wydajności).
                    HStack(alignment: .top, spacing: 8) {
                        vfoADisplay.frame(idealWidth: 360)
                        vfoBDisplay.frame(idealWidth: 290)
                    }
                    .clipped()
                    vfoControls
                }
                meters.frame(minWidth: 300, idealWidth: 400, maxWidth: 400)
            }
            if tab == .ft8 {
                // zakładka FT8/FT4: wodospad FT8 w miejscu skopu - panel zakładki ma miejsce na listy stacji
                FT8WaterfallView(model: ft8Holder.manager.waterfall, ft8: ft8Holder.manager)
                    .frame(minHeight: 180, maxHeight: .infinity)
            } else if tab == .propagation {
                // zakładka PROPAGACJA: duża mapa w miejscu skopu (zamiast miniatury i osobnego okna)
                PropagationMapPanel(service: propagation)
                    .frame(minHeight: 180, maxHeight: .infinity)
            } else {
            RFScopeView(scope: rfScope,
                        model: rfScope.model,
                        vfoHz: cat.activeFreq,
                        modeName: cat.modeName,
                        canTune: cat.isConnected,
                        onTune: { hz in cat.setActiveFrequency(hz) },
                        embedded: true,
                        cluster: cluster,
                        stepHz: tuneStep,
                        onSpot: { spot in
                            tuneToSpot(spot)
                            if tab == .contest {
                                contestHolder.manager.call = spot.call      // w zawodach: znak do pola zawodów
                            } else {
                                // poza zawodami: znak do dziennika i zakładka DZIENNIK
                                logbook.prefill(spot.call)
                                tab = .log
                            }
                        },
                        pota: potaHolder.manager,
                        onPOTA: { spot in
                            if tab == .contest {
                                tuneToSpot(potaSpot: spot)
                                contestHolder.manager.call = spot.activator
                            } else {
                                // aktywacja POTA ze skopu: jak kliknięcie w zakładce POTA, potem DZIENNIK
                                potaHolder.manager.select(spot)
                                tab = .log
                            }
                        },
                        contest: contestHolder.manager,
                        contestActive: tab == .contest)
                .equatable()
            }
        }
    }

    // MARK: - Informacje pod częstotliwością

    private static func stepText(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    /// VFO-A (odbiornik): RX BW, AGC, STEP oraz włączone funkcje (przedwzmacniacz, tłumik, NB, DNR, NOTCH, DNF, CONTOUR).
    private var vfoAInfo: [VFOTag] {
        guard cat.isConnected else { return [] }
        var tags: [VFOTag] = []
        if let width = cat.value(.width) {
            tags.append(VFOTag(label: "RX BW", value: FilterTables.label(index: width, modeCode: cat.modeCode)))
        }
        if let agc = cat.value(.agc) {
            let names = [0: "OFF", 1: "FAST", 2: "MID", 3: "SLOW"]
            tags.append(VFOTag(label: "AGC", value: names[agc] ?? "AUTO"))
        }
        if (cat.modeCode == "1" || cat.modeCode == "2"), !cat.ssbTxBandwidth.isEmpty {   // LSB / USB
            tags.append(VFOTag(label: "TX BW", value: cat.ssbTxBandwidth))
        }
        tags.append(VFOTag(label: "STEP", value: Self.stepText(tuneStep)))
        if let pre = cat.value(.preamp), pre > 0 {
            tags.append(VFOTag(label: "", value: pre == 1 ? "AMP1" : "AMP2", highlighted: true))
        }
        if let att = cat.value(.attenuator), att > 0 {
            tags.append(VFOTag(label: "ATT", value: "\(att * 6)dB", highlighted: true))
        }
        let flags: [(RadioControl, String)] = [(.noiseBlanker, "NB"), (.noiseReduction, "DNR"),
                                               (.notch, "NOTCH"), (.notchAuto, "DNF"), (.contour, "CONT")]
        for (control, name) in flags where (cat.value(control) ?? 0) != 0 {
            tags.append(VFOTag(label: "", value: name, highlighted: true))
        }
        return tags
    }

    /// VFO-B: STEP i rola przy SPLIT (tryb VFO-B jest w etykiecie trybu).
    private var vfoBInfo: [VFOTag] {
        guard cat.isConnected else { return [] }
        var tags = [VFOTag(label: "STEP", value: Self.stepText(tuneStep))]
        if splitOn { tags.append(VFOTag(label: "", value: "SPLIT", highlighted: true)) }
        return tags
    }

    private var vfoControls: some View {
        HStack(spacing: 6) {
            Button("−") { cat.tune(by: -tuneStep) }.buttonStyle(RigButtonStyle(height: 30, fontSize: 16)).frame(width: 48)
            Button("+") { cat.tune(by: tuneStep) }.buttonStyle(RigButtonStyle(height: 30, fontSize: 16)).frame(width: 48)
            Picker("", selection: $tuneStep) {
                ForEach([10, 100, 500, 1_000, 5_000, 10_000], id: \.self) { step in
                    Text(step >= 1_000 ? "\(step / 1_000) kHz" : "\(step) Hz").tag(step)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            Text(L("KROK")).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.header)
            Divider().frame(height: 22)
            // Nazwy jak na panelu FT-710: A/B przełącza VFO (zamiana A↔B, komenda SV), A=B kopiuje A do B (AB).
            Button("A/B") { cat.swapVFO() }.buttonStyle(RigButtonStyle(height: 30)).frame(width: 70)
                .help(L("Przełącz aktywne VFO (jak przycisk A/B w radiu); aktywne VFO jest wyświetlane po lewej"))
            Button("A=B") { cat.copyAtoB() }.buttonStyle(RigButtonStyle(height: 30)).frame(width: 70)
                .help(L("Skopiuj VFO-A do VFO-B (jak przycisk A=B w radiu); VFO-A bez zmian"))
            Button("SPLIT") { cat.set(.split, splitOn ? 0 : 1) }
                .buttonStyle(RigButtonStyle(selected: splitOn, tint: Theme.header, height: 30))
                .frame(width: 80)
                .disabled(!cat.isAvailable(.split))
                .help(L("Praca z rozstawem: odbiór na VFO-A, nadawanie na VFO-B"))
            Spacer()
            Text(Lr(cat.status))
                .font(.system(size: 12))
                .foregroundStyle(cat.isConnected ? Theme.ok : Theme.dim)
        }
        .disabled(!cat.isConnected)
    }

    /// Wskaźniki zmieniają się ~10 razy/s - w osobnym kontenerze, żeby nie wymuszały układania całego okna.
    private var meters: some View {
        MeterGauges(meters: cat.meters, transmitting: cat.transmitting, tile: txTile)
            .frame(height: 200)
    }

    private var txTile: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(spacing: 4) {
                Text(cat.transmitting ? "TX" : "RX")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(cat.transmitting ? Theme.tx : Theme.ok)
                if let start = txStartedAt, cat.transmitting {
                    let seconds = Int(context.date.timeIntervalSince(start))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                } else {
                    Text(L("limit {1} min", Int(cat.txTimeout / 60)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panelInner, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(cat.transmitting ? Theme.tx : Theme.border))
        }
    }

    /// Położenie (0...1) wartości fizycznej na skali odczytu 0–255 wg tabeli kalibracji.
    static func position(_ value: Double, _ table: [MeterCalibration.Point]) -> Double {
        for i in 1..<table.count {
            let a = table[i - 1], b = table[i]
            if value <= b.value && b.value > a.value {
                let t = max(0, (value - a.value) / (b.value - a.value))
                return (a.raw + t * (b.raw - a.raw)) / 255
            }
        }
        return 1
    }

    static func ticks(_ marks: [(Double, String)], _ table: [MeterCalibration.Point]) -> [(Double, String)] {
        marks.map { mark in (ContentView.position(mark.0, table), mark.1) }
    }

    static let sTicks = ticks([(-48, "1"), (-36, "3"), (-24, "5"), (-12, "7"), (0, "9"),
                                       (20, "+20"), (40, "+40"), (60, "+60")], MeterCalibration.sMeterDB)
    static let poTicks = ticks([(0, "0"), (10, "10"), (25, "25"), (50, "50"), (100, "100")],
                                       MeterCalibration.powerWatts)
    static let swrTicks = ticks([(1.0, "1"), (1.5, "1.5"), (2.0, "2"), (3.0, "3"), (4.0, "4")],
                                        MeterCalibration.swr)
    static let percentTicks: [(Double, String)] = [(0, "0"), (0.25, "25"), (0.5, "50"), (0.75, "75"), (1, "100")]

    // MARK: - Prawa kolumna: poziomy, wejście, TX

    /// Prawa kolumna; blok TX dosunięty do dołu (równo z dołem waterfalla), a gdy okno jest za niskie -
    /// cała kolumna przewija się wewnątrz.
    private var rightColumn: some View {
        ViewThatFits(in: .vertical) {
            rightColumnContent(pinTXToBottom: true)
            ScrollView(.vertical, showsIndicators: false) {
                rightColumnContent(pinTXToBottom: false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func rightColumnContent(pinTXToBottom: Bool) -> some View {
        VStack(spacing: 8) {
            RigPanel(title: nil) {
                controlSlider("AF", .afGain) { "\(Int((Double($0) / 255 * 100).rounded()))" }
                controlSlider("SQL", .squelch)
                controlSlider("TX", .power) { "\($0) W" }
                controlSlider("RF", .rfGain) { "\(Int((Double($0) / 255 * 100).rounded()))" }
                HStack(spacing: 4) {
                    choiceButton("IPO", .preamp, 0)
                    choiceButton("AMP1", .preamp, 1)
                    choiceButton("AMP2", .preamp, 2)
                }
                Text("ATT").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.header)
                HStack(spacing: 4) {
                    choiceButton("Off", .attenuator, 0)
                    choiceButton("6dB", .attenuator, 1)
                    choiceButton("12dB", .attenuator, 2)
                    choiceButton("18dB", .attenuator, 3)
                }
                levelSlider("DNR", onOff: .noiseReduction, level: .nrLevel, maximum: 15)
                levelSlider("NB", onOff: .noiseBlanker, level: .nbLevel, maximum: 10)
            }

            RigPanel(title: nil) {
                controlSlider("MIC", .micGain)
                levelSlider("PROC", onOff: .processor, level: .procLevel, maximum: 100)
                controlSlider("AMC", .amc)
            }

            if pinTXToBottom { Spacer(minLength: 0) }

            txPanel
        }
        .frame(maxHeight: pinTXToBottom ? .infinity : nil, alignment: .top)
    }

    /// Suwak poziomu z wyłączaniem jak na panelu radia: 0 = funkcja wyłączona (np. DNR OFF),
    /// powyżej zera = włączona z tym poziomem.
    private func levelSlider(_ title: String, onOff: RadioControl, level: RadioControl, maximum: Int) -> some View {
        let isOn = (cat.value(onOff) ?? 0) != 0
        let current = isOn ? max(1, cat.value(level) ?? 1) : 0
        let available = cat.isAvailable(onOff) && cat.isAvailable(level)
        return RigSlider(title: title, value: cat.value(onOff) == nil ? nil : current, range: 0...maximum,
                         display: { $0 == 0 ? "OFF" : "\($0)" }) { newValue in
            if newValue <= 0 {
                if (cat.value(onOff) ?? 0) != 0 { cat.set(onOff, 0) }
            } else {
                if (cat.value(onOff) ?? 0) == 0 { cat.set(onOff, 1) }
                cat.set(level, newValue)
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
    }

    private func choiceButton(_ label: String, _ control: RadioControl, _ value: Int) -> some View {
        Button(label) { cat.set(control, value) }
            .buttonStyle(RigButtonStyle(selected: cat.value(control) == value, fontSize: 12))
            .disabled(!cat.isAvailable(control))
    }

    private var txPanel: some View {
        RigPanel(title: nil) {
            HStack(spacing: 6) {
                Toggle(L("Odblokuj TX"), isOn: $txArmed)
                    .disabled(!cat.isConnected)
                    .fixedSize()
                    .help(L("Odblokuj nadawanie"))
                Spacer(minLength: 4)
                Picker("", selection: $cat.txTimeout) {
                    Text("1 min").tag(60.0)
                    Text("3 min").tag(180.0)
                    Text("5 min").tag(300.0)
                }
                .labelsHidden()
                .frame(width: 76)
                .help(L("Limit TX"))
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                Text("TUNE").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.header)
                Spacer()
                choiceButton("ON", .tuner, 1).frame(width: 48)
                Button("OFF") { cat.set(.tuner, 0) }
                    .buttonStyle(RigButtonStyle(selected: cat.value(.tuner) == 0, fontSize: 12))
                    .frame(width: 48)
                    .disabled(!cat.isAvailable(.tuner))
            }
            // Strojenie tunera nadaje nośną - tylko przy odblokowanym nadawaniu.
            Button("TUNE") { cat.startTuning() }
                .buttonStyle(RigButtonStyle(height: 30, fontSize: 15))
                .disabled(!(txArmed && cat.isAvailable(.tuner)))

            Text("PTT")
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(pttPressed ? Theme.tx : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pttPressed ? Theme.tx : Color.white.opacity(0.15)))
                .foregroundStyle(pttPressed ? .white : Theme.text)
                .opacity(txArmed && cat.isConnected ? 1 : 0.35)
                .help(L("Przytrzymaj, aby nadawać"))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard txArmed, cat.isConnected, !pttPressed, !pttLockedOut else { return }
                            guard audio.beginTX() else { return }   // audio z Maca niegotowe: nie kluczuj
                            pttPressed = true
                            cat.ptt(true)
                        }
                        .onEnded { _ in
                            pttLockedOut = false
                            releasePTT()
                        }
                )

            MessagePanel(cat: cat, txArmed: txArmed, compact: true)
        }
    }

    // MARK: - Dół: zakładki

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(BottomTab.allCases) { item in
                    Button { tab = item } label: {
                        Text(L(item.rawValue)).padding(.horizontal, 6)
                    }
                    .buttonStyle(RigButtonStyle(selected: tab == item, height: 22, fontSize: 11))
                    .fixedSize()
                }
                Spacer()
                AlertBellButton()
                Button { showDiagnostics = true } label: {
                    Text(L("Diagnostyka USB")).padding(.horizontal, 6)
                }
                .buttonStyle(RigButtonStyle(height: 22, fontSize: 11))
                .fixedSize()
            }
            Divider()
            Group {
                switch tab {
                case .log: logTab
                case .display:
                    DisplayView(display: DisplaySettings.shared)
                case .cw:
                    CWView(cw: cwHolder.manager, audio: audio, cat: cat, txArmed: txArmed)
                case .rtty:
                    RTTYView(rtty: rttyHolder.manager, audio: audio, cat: cat, txArmed: txArmed)
                case .ft8:
                    FT8View(ft8: ft8Holder.manager, audio: audio, cat: cat, txArmed: txArmed)
                case .pota:
                    POTAView(pota: potaHolder.manager, cat: cat)
                case .contest:
                    ContestView(contest: contestHolder.manager, cat: cat, cluster: cluster)
                case .propagation:
                    PropagationView(service: propagation, cluster: cluster,
                                    myCall: logbook.myCall, myGrid: logbook.myGrid)
                case .sstv:
                    SSTVView(sstv: sstvHolder.manager, audio: audio, cat: cat, txArmed: txArmed)
                case .dxCluster:
                    DXClusterView(cluster: cluster, logbook: logbook,
                                  currentBand: Bands.name(for: cat.activeFreq) ?? "",
                                  canTune: cat.isConnected,
                                  onTune: { spot in tuneToSpot(spot); logbook.prefill(spot.call) },
                                  onSelect: { spot in logbook.prefill(spot.call) })   // bez zmiany zakładki
                case .audio: scrollingTab { audioSection }
                case .spectrum:
                    scrollingTab {
                        SpectrumView(model: audio.spectrum, dialHz: cat.activeFreq,
                                     modeCode: cat.modeCode, receiving: audio.listening)
                            .onAppear { audio.setSpectrumNeeded("audioTab", true) }
                            .onDisappear { audio.setSpectrumNeeded("audioTab", false) }
                    }
                case .catShare: scrollingTab { catShareSection }
                case .remote: scrollingTab { RemoteSectionView(remote: remote) }
                case .catLog: logSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func scrollingTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical) {
            content().frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var logTab: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                QuickLogView(store: logbook, cat: cat, lookup: lookup, qrz: qrz, draft: quickLogDraft,
                             openLogbook: { openWindow(id: "logbook") })
                UploadSummaryLine(uploader: uploader)
                if let logInfo {
                    Text(logInfo).font(.caption).foregroundStyle(.secondary)
                }
                RecentQSOTable(qsos: Array(logbook.qsos.prefix(200)), myGrid: logbook.myGrid,
                               selection: $selectedQSO, onEdit: { qso in editingQSO = qso },
                               canFillFromQRZ: qrz.canLookup,
                               onFillFromQRZ: { ids in
                                   logInfo = L("Pobieranie danych z QRZ.com…")
                                   Task { logInfo = await logbook.fillFromQRZ(ids: ids, qrz: qrz) }
                               },
                               onSpot: { qso in openSpot(qso.spotCommand) })
                .equatable()                                    // bez przerysowań przy strojeniu radia
                    .frame(maxHeight: .infinity)
            }
            CallInfoCard(lookup: lookup, qrz: qrz, myGrid: logbook.myGrid, myCall: logbook.myCall)
                .frame(width: 440)
                .frame(maxHeight: .infinity)
        }
        .onChange(of: selectedQSO) { ids in
            // Zaznaczona łączność: pokaż jej stację (dane z QRZ, a lokator z dziennika jako zapas).
            guard let id = ids.first, let qso = logbook.qsos.first(where: { $0.id == id }) else { return }
            lookup.request(qso.call, using: qrz, gridHint: qso.grid)
        }
    }

    // MARK: - Pasek stanu

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(cat.isConnected ? Theme.ok : Theme.tx)
                .frame(width: 8, height: 8)
            Text(cat.isConnected ? L("Połączono") : L("Rozłączono"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(cat.isConnected ? Theme.accent : Theme.dim)
            Picker("", selection: $cat.selectedPort) {
                if cat.ports.isEmpty { Text(L("brak portów")).tag("") }
                ForEach(cat.ports, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 260)
            .disabled(cat.isConnected)
            Button(L("Odśwież")) { cat.refreshPorts() }
                .disabled(cat.isConnected)
            Picker("", selection: $cat.baud) {
                ForEach([4800, 9600, 19200, 38400, 115200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            .disabled(cat.isConnected)
            Button(cat.isConnected ? L("Rozłącz") : L("Połącz")) {
                if cat.isConnected {
                    txArmed = false
                    audio.stopAll()
                    cat.stopAutoConnect()                   // ręczne rozłączenie - bez ponownych prób
                    cat.disconnect()
                } else {
                    cat.connect()
                }
            }
            .keyboardShortcut(.defaultAction)
            Toggle(L("Auto"), isOn: $cat.autoConnect)
                .toggleStyle(.checkbox)
                .help(L("Łącz automatycznie przy starcie z ostatnio działającym portem; gdy radio jest wyłączone - czekaj, aż się pojawi"))
            Spacer()
            UpdateBadge()
            StatusAudioControl(audio: audio)
            Picker("", selection: $languageCode) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .help(L("Język"))
            ConnectionBadges(remote: remote, share: share)
            // liczniki i zegar zmieniają się co sekundę - w osobnym kontenerze o stałej szerokości
            IsolatedHost { LiveStatusText(scope: rfScope) }
                .frame(width: 600, height: 16)
            Button { openWindow(id: "help") } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Pomoc FT-710 Control"))
            IsolatedHost {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.utcClock.string(from: context.date) + " UTC")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 170, height: 16)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.35))
    }

    private static let utcClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f
    }()

    // MARK: - Zakładki (sekcje z poprzedniej wersji)

    private var audioSection: some View {
        GroupBox(L("Audio USB")) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        devicePicker(L("Z radia (RX)"), selection: $audio.radioIn, devices: audio.inputs)
                        devicePicker(L("Głośniki / słuchawki"), selection: $audio.speakerOut, devices: audio.outputs)
                    }
                    GridRow {
                        devicePicker(L("Mikrofon (TX)"), selection: $audio.micIn, devices: audio.inputs)
                        devicePicker(L("Do radia (TX)"), selection: $audio.radioOut, devices: audio.outputs)
                    }
                }
                .disabled(audio.listening || audio.txReady)

                HStack(spacing: 12) {
                    Button(audio.listening ? L("Zatrzymaj odsłuch") : L("Włącz odsłuch")) {
                        audio.toggleListening()
                    }
                    .frame(width: 150)
                    Slider(value: $audio.rxVolume, in: 0...1).frame(width: 140)
                    AudioLevelBar(levels: audio.levels, transmit: false).frame(width: 100)
                    Spacer()
                    Button(L("Odśwież urządzenia")) { audio.refreshDevices() }
                        .disabled(audio.listening || audio.txReady)
                }

                HStack(spacing: 12) {
                    Toggle(L("Nadawaj audio z Maca przez USB"), isOn: $audio.txOverUSB)
                        .frame(width: 270, alignment: .leading)
                    Slider(value: $audio.txVolume, in: 0...1).frame(width: 140)
                    AudioLevelBar(levels: audio.levels, transmit: true).frame(width: 100)
                }

                // Redukcja szumu: między wyjściem audio radia a słuchawkami (DSP na Macu)
                HStack(spacing: 12) {
                    Text(L("Redukcja szumu")).font(.callout.bold())
                    Picker("", selection: $audio.nrLevel) {
                        ForEach(AudioDenoiser.Level.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 460)
                    Toggle(L("Pasmo głosu 250–2900 Hz"), isOn: $audio.nrVoiceBand)
                    Toggle(L("Wyrównanie głośności"), isOn: $audio.nrAGC)
                        .disabled(audio.nrLevel == .off)
                    Toggle(L("ANF – gwizdy"), isOn: $audio.nrANF)
                        .help(L("Automatycznie wycina gwizdy i nośne (np. stacja strojąca obok)"))
                    Toggle(L("NB – trzaski"), isOn: $audio.nrNB)
                        .help(L("Wygasza trzaski i impulsy (wyładowania atmosferyczne, zakłócenia iskrowe)"))
                }
                .help(L("Filtr działa tylko na odsłuch na Macu (słuchawki/głośniki); widmo, SSTV i praca zdalna dostają dźwięk bez zmian. Opóźnienie ok. 21 ms."))

                if audio.nrLevel == .ai {
                    HStack(spacing: 10) {
                        Text(L("Siła AI: {1}%", Int((audio.aiStrength * 100).rounded()))).font(.caption.monospacedDigit())
                        Slider(value: $audio.aiStrength, in: 0.3...1).frame(width: 160)
                        Text(L("AI najlepiej działa przy stacjach dobrze słyszalnych w hałasie. Słabe stacje DX (na poziomie szumu) wycina - dla nich wybierz poziom Głos DX."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // korektory odsłuchu (RX) i nadawania (TX) obok siebie
                HStack(alignment: .top, spacing: 20) {
                    EqualizerView(audio: audio)
                    Divider().frame(height: 160)
                    TXEqualizerView(audio: audio)
                }

                // APF - wąski filtr szczytowy dla CW (to samo ustawienie co w zakładce CW)
                HStack(spacing: 12) {
                    Toggle(L("APF (CW)"), isOn: $audio.apfEnabled)
                        .font(.callout.bold())
                    Picker("", selection: $audio.apfBandwidth) {
                        Text("50 Hz").tag(50.0)
                        Text("100 Hz").tag(100.0)
                        Text("200 Hz").tag(200.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(!audio.apfEnabled)
                    Text(L("Środek filtra podąża za tonem dekodera CW (albo stacją wskazaną w widmie zakładki CW)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(L("Zapisz ustawienia")) { audio.saveSettings() }
                        .help(L("Zapisuje urządzenia, głośności, nadawanie przez USB i stan odsłuchu - program będzie startował z tymi ustawieniami do następnego zapisu"))
                    if audio.saved == nil {
                        Text(L("Ustawienia nie są zapisane - po ponownym uruchomieniu program dobierze urządzenia sam."))
                            .font(.caption).foregroundStyle(.orange)
                    } else if audio.hasUnsavedChanges {
                        Text(L("Zmiany niezapisane")).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(audio.listening ? L("Zapisane - program startuje z tymi ustawieniami i włączonym odsłuchem.")
                                             : L("Zapisane - program startuje z tymi ustawieniami."))
                            .font(.caption).foregroundStyle(Theme.ok)
                    }
                }

                if let message = audio.message.map(Lr) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }

    private var catShareSection: some View {
        CATShareSection(share: share)
    }

    private func devicePicker(_ title: String,
                              selection: Binding<AudioDeviceID>,
                              devices: [AudioDevice]) -> some View {
        Picker(title, selection: selection) {
            Text(L("— brak —")).tag(AudioDeviceID(0))
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }

    private var logSection: some View {
        CATLogView(log: cat.logModel)
    }
}

/// Zakładka LOG CAT: obserwuje tylko dziennik CAT (nie całe radio).
struct CATLogView: View {
    @ObservedObject var log: CATLogModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(6)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .onAppear {                                                // otwarcie diagnostyki - od razu na koniec
                guard !log.lines.isEmpty else { return }
                DispatchQueue.main.async { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
            }
            .onChange(of: log.lines.last) { _ in                       // także po zapełnieniu 60 wpisów
                proxy.scrollTo(log.lines.count - 1, anchor: .bottom)
            }
        }
    }
}

/// Ostatnie łączności w zakładce DZIENNIK (pełna lista, import i eksport: okno dziennika).
struct RecentQSOTable: View {
    let qsos: [QSO]
    let myGrid: String
    @Binding var selection: Set<QSO.ID>
    /// Podwójne kliknięcie albo menu kontekstowe → edycja łączności.
    var onEdit: (QSO) -> Void = { _ in }
    /// Menu kontekstowe: uzupełnienie z QRZ.com i przygotowanie spotu.
    var canFillFromQRZ = false
    var onFillFromQRZ: (Set<QSO.ID>) -> Void = { _ in }
    var onSpot: (QSO) -> Void = { _ in }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd  HH:mm"
        return f
    }()

    var body: some View {
        Table(qsos, selection: $selection) {
            TableColumn(L("Data / czas UTC")) { q in Text(Self.formatter.string(from: q.start)).monospacedDigit() }
                .width(min: 120, ideal: 130)
            TableColumn(L("Znak")) { q in CallSignLink(call: q.call) }
                .width(min: 70, ideal: 90)
            TableColumn("MHz") { q in
                Text(q.freqHz > 0 ? String(format: "%.6f", Double(q.freqHz) / 1_000_000) : "").monospacedDigit()
            }
            .width(min: 75, ideal: 85)
            TableColumn(L("Tryb")) { q in Text(q.modeLabel) }
                .width(min: 40, ideal: 50)
            TableColumn("RST") { q in Text("\(q.rstSent)/\(q.rstRcvd)") }
                .width(min: 45, ideal: 60)
            TableColumn(L("Kraj")) { q in Text(q.country) }
                .width(min: 60, ideal: 90)
            TableColumn(L("Imię")) { q in Text(q.name) }
            TableColumn(L("Lokator")) { q in Text(q.grid) }
                .width(min: 45, ideal: 60)
            TableColumn(L("Odległość")) { q in
                Text(q.distanceKm(fallbackMyGrid: myGrid).map { "\($0) km" } ?? "").monospacedDigit()
            }
            .width(min: 60, ideal: 75)
            TableColumn(L("Azymut")) { q in
                Text(q.bearing(fallbackMyGrid: myGrid).map { "\($0)°" } ?? "").monospacedDigit()
            }
            .width(min: 45, ideal: 55)
        }
        .contextMenu(forSelectionType: QSO.ID.self) { ids in
            Button(L("Edytuj…")) { edit(ids) }
                .disabled(ids.count != 1)
            Divider()
            Button(L("Uzupełnij z QRZ.com")) { onFillFromQRZ(ids) }
                .disabled(ids.isEmpty || !canFillFromQRZ)
            Button(L("Wyślij SPOT…")) {
                if let id = ids.first, let qso = qsos.first(where: { $0.id == id }) { onSpot(qso) }
            }
            .disabled(ids.count != 1 || ids.first.flatMap { id in qsos.first { $0.id == id } }?.spotCommand == nil)
        } primaryAction: { ids in
            edit(ids)                                   // podwójne kliknięcie
        }
    }
}

/// Zegarowe mierniki - obserwują tylko odczyty mierników (nie całe CATClient).
/// Panel wskaźników: pięć wskaźników AppKit (każdy sam śledzi wartości z radia i przerysowuje tylko siebie)
/// i kafelek RX/TX. Panel nie obserwuje wartości - zmiana wskazówki nie przebudowuje widoków SwiftUI.
struct MeterGauges<Tile: View>: View {
    let meters: CATMeters
    let transmitting: Bool
    let tile: Tile

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                MeterGauge(kind: .s, meters: meters, transmitting: transmitting)
                MeterGauge(kind: .po, meters: meters, transmitting: transmitting)
                MeterGauge(kind: .swr, meters: meters, transmitting: transmitting)
            }
            HStack(spacing: 6) {
                MeterGauge(kind: .comp, meters: meters, transmitting: transmitting)
                MeterGauge(kind: .alc, meters: meters, transmitting: transmitting)
                tile
            }
        }
    }
}

extension RecentQSOTable {
    fileprivate func edit(_ ids: Set<QSO.ID>) {
        guard ids.count == 1, let id = ids.first, let qso = qsos.first(where: { $0.id == id }) else { return }
        onEdit(qso)
    }
}

/// Wynik automatycznej wysyłki ostatniej łączności (np. „SP5XX: LoTW ✓ · QRZ Logbook ✓”).
/// Osobny widok - zmiany stanu wysyłki nie przerysowują okna.
struct UploadSummaryLine: View {
    @ObservedObject var uploader: LogUploader

    var body: some View {
        if !uploader.lastSummary.isEmpty {
            Text(L("Wysyłka: {1}", uploader.lastSummary))
                .font(.caption)
                .foregroundStyle(uploader.lastSummary.contains("✗") ? Color.orange : Theme.ok)
        }
    }
}

/// Tabela 200 ostatnich QSO przerysowuje się tylko przy zmianie łączności, zaznaczenia albo lokatora -
/// nie przy każdej zmianie częstotliwości radia (domknięcia uniemożliwiały SwiftUI porównanie).
extension RecentQSOTable: Equatable {
    static func == (lhs: RecentQSOTable, rhs: RecentQSOTable) -> Bool {
        lhs.qsos == rhs.qsos && lhs.myGrid == rhs.myGrid
            && lhs.canFillFromQRZ == rhs.canFillFromQRZ && lhs.selection == rhs.selection
    }
}


/// Zwykła (nie leniwa) siatka o stałej liczbie kolumn - dla kilku–kilkunastu elementów. LazyVGrid przy takich
/// ilościach tylko kosztuje: obsługuje komórki osobno przy każdej przebudowie (pomiar Instruments).
struct ColumnGrid<Element, ID: Hashable, Cell: View>: View {
    let items: [Element]
    let id: KeyPath<Element, ID>
    let columns: Int
    let spacing: CGFloat
    let cell: (Element) -> Cell

    init(_ items: [Element], id: KeyPath<Element, ID>, columns: Int, spacing: CGFloat = 5,
         @ViewBuilder cell: @escaping (Element) -> Cell) {
        self.items = items
        self.id = id
        self.columns = max(1, columns)
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: id) { item in
                        cell(item).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}


/// Widok SwiftUI we własnym kontenerze AppKit, który nie zgłasza zmian rozmiaru na zewnątrz (sizingOptions = []).
/// Zmiany w środku (wskaźniki ~10 razy/s, liczniki i zegar co sekundę) są układane tylko w tym kontenerze -
/// bez przebiegu układania całego okna (pomiar Instruments: ~12 razy/s po ~13 ms). Rozmiar nadaje rodzic (.frame).
struct IsolatedHost<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    // NSHostingView zwracany wprost jest rozpoznawany przez SwiftUI jako zagnieżdżony i jego aktualizacje
    // planowały przeliczenie korzenia całego okna (pomiar: ~12/s w rytmie wskaźników). Zwykły NSView jako
    // kontener o stałym rozmiarze, bez zgłaszania zmian rozmiaru, odcina to połączenie.
    func makeNSView(context: Context) -> IsolatedContainer<Content> {
        IsolatedContainer(content)
    }

    func updateNSView(_ container: IsolatedContainer<Content>, context: Context) {
        container.host.rootView = content
    }
}

/// Kontener AppKit dla odizolowanej treści SwiftUI: rozmiar nadaje rodzic, zmiany wewnątrz nie wychodzą na zewnątrz.
final class IsolatedContainer<Content: View>: NSView {
    let host: IsolatedHostingView<Content>

    init(_ content: Content) {
        host = IsolatedHostingView(rootView: content)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        super.init(frame: .zero)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nie jest używany") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}          // nie zgłaszaj zmian na zewnątrz

    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }
}

/// NSHostingView bez zgłaszania zmian rozmiaru do widoku nadrzędnego.
final class IsolatedHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}
}

/// Pasek stanu: liczba ramek skopu z radia i liczniki wydajności (obserwuje tylko skop i statystyki).
struct LiveStatusText: View {
    @ObservedObject var scope: RFScopeController

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if scope.receiving {
                Text(verbatim: L("RF {1} kl./s", scope.fps)).foregroundStyle(Theme.header)
            }
            RenderStatsView()
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}


/// Znaczki „ZDALNIE” i „CAT SHARE” na pasku stanu - obserwują tylko pracę zdalną i CAT Share.
struct ConnectionBadges: View {
    @ObservedObject var remote: RemoteStation
    @ObservedObject var share: CATShareServer

    var body: some View {
        HStack(spacing: 10) {
            if remote.operatorInfo != nil {
                Text(L("ZDALNIE")).foregroundStyle(Theme.accent)
            }
            if share.clients > 0 {
                Text("CAT SHARE").foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Zakładka CAT SHARE - obserwuje tylko serwer CAT Share (dziennik zapytań zmienia się często).
struct CATShareSection: View {
    @ObservedObject var share: CATShareServer

    var body: some View {
        GroupBox(L("CAT Share (WSJT-X, JTDX, logi)")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    // Text(verbatim:) - inaczej SwiftUI sformatuje port jako „4 532"
                    Toggle(isOn: $share.enabledByUser) { Text(verbatim: L("Serwer rigctl 127.0.0.1:{1}", CATShareServer.port)) }
                    Toggle(L("Pozwól na PTT"), isOn: $share.allowPTT)
                        .help(L("Zgoda na kluczowanie radia przez programy zewnętrzne. Rozłączenie programu zawsze wysyła TX0."))
                    Spacer()
                    Text(Lr(share.status))
                        .font(.callout)
                        .foregroundStyle(isErrorStatus(share.status) ? .red : .secondary)
                    if share.clients > 0 {
                        Text(L("klienci: {1}", share.clients))
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
                Text(verbatim: L("WSJT-X → Settings → Radio: Rig „Hamlib NET rigctl”, Network Server 127.0.0.1:{1}, PTT Method: CAT, Mode: Data/Pkt, Split Operation: Fake It.", CATShareServer.port))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !share.log.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(share.log.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 70)
                }
            }
            .padding(6)
        }
    }
}

/// Obiekt trzymany przez widok bez obserwowania jego zmian (jeden egzemplarz na czas życia widoku).
final class Unobserved<Value>: ObservableObject {
    let value: Value
    init(_ value: @autoclosure () -> Value) { self.value = value() }
}


/// Pasek stanu: głośność odsłuchu (ta sama co w zakładce AUDIO) i wyciszenie. Bez wskaźnika poziomu - element
/// odświeżany kilkanaście razy na sekundę obciążałby okno.
struct StatusAudioControl: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(spacing: 4) {
            Button { audio.rxMuted.toggle() } label: {
                Image(systemName: audio.rxMuted ? "speaker.slash.fill" : volumeSymbol)
                    .foregroundStyle(audio.rxMuted ? Theme.tx : (audio.listening ? Theme.text : .secondary))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(audio.rxMuted ? L("Włącz dźwięk odsłuchu") : L("Wycisz odsłuch"))
            Slider(value: Binding(get: { audio.rxVolume }, set: { audio.rxVolume = $0; if audio.rxMuted { audio.rxMuted = false } }),
                   in: 0...1)
                .controlSize(.mini)
                .frame(width: 100)
                .help(audio.listening ? L("Głośność odsłuchu") : L("Głośność odsłuchu (odsłuch wyłączony - włącz w zakładce AUDIO)"))
            Text(audio.rxMuted ? L("wycisz.") : "\(Int((audio.rxVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
    }

    private var volumeSymbol: String {
        audio.rxVolume < 0.01 ? "speaker.fill" : audio.rxVolume < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}
