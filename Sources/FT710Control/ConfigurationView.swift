import SwiftUI

/// Okno „Konfiguracja” (menu programu, ⌘,): wszystkie ustawienia w jednym miejscu, z opisami działów.
/// Działy korzystają z tych samych widoków co wcześniej zakładki (EKRAN, CAT SHARE, ZDALNIE) i okna -
/// każde ustawienie istnieje w programie raz. Obiekty okna głównego (radio, praca zdalna, CAT Share) przez
/// rejestr DiagnosticsHub (okno Konfiguracji jest osobnym oknem).
struct ConfigurationView: View {
    enum Section: String, CaseIterable, Identifiable {
        case station, radio, display, cluster, ft8, cw, services, alerts, catShare, remote, program
        var id: String { rawValue }

        var title: String {
            switch self {
            case .station: return L("Stacja")
            case .radio: return L("Radio i CAT")
            case .display: return L("Skop i wodospad")
            case .cluster: return "DX Cluster"
            case .ft8: return "FT8/FT4"
            case .cw: return L("CW – kluczowanie")
            case .services: return L("Dziennik i serwisy")
            case .alerts: return L("Alerty")
            case .catShare: return "CAT Share"
            case .remote: return L("Praca zdalna")
            case .program: return L("Program")
            }
        }

        var icon: String {
            switch self {
            case .station: return "person.text.rectangle"
            case .radio: return "cable.connector"
            case .display: return "waveform"
            case .cluster: return "antenna.radiowaves.left.and.right"
            case .ft8: return "square.grid.3x3"
            case .cw: return "dot.radiowaves.right"
            case .services: return "book.closed"
            case .alerts: return "bell"
            case .catShare: return "point.3.connected.trianglepath.dotted"
            case .remote: return "iphone.radiowaves.left.and.right"
            case .program: return "gearshape"
            }
        }

        var summary: String {
            switch self {
            case .station: return L("Twój znak, lokator, strefy i dane do dziennika; konta QRZ.com i HamQTH do wyszukiwania stacji.")
            case .radio: return L("Połączenie z FT-710 przez USB (port CAT i prędkość), automatyczne łączenie i limit czasu nadawania.")
            case .display: return L("Wygląd skopu RF i wodospadu: tryb (płaski / 3D), paleta, prędkość, skala, spoty DX Cluster i POTA na skopie.")
            case .cluster: return L("Węzeł DX Cluster (adres, port, logowanie), automatyczne łączenie i filtry spotów. Lista spotów i łączenie - zakładka DX CLUSTER.")
            case .ft8: return L("Zachowanie sekwencji FT8/FT4 (limit wywołań, kolejność wołających, praca split) i zgłaszanie odebranych stacji do PSKReporter.")
            case .cw: return L("Jak program nadaje CW: przez linię portu (DTR/RTS, dokładne tempo) albo przez klucz radia; sprawdzenie i poprawienie ustawień FT-710.")
            case .services: return L("Wysyłanie łączności i pobieranie potwierdzeń: LoTW, eQSL, QRZ Logbook, Club Log, HRDLog, WRL.")
            case .alerts: return L("Powiadomienia o stacjach i krajach: rodzaje alertów, źródła (DX Cluster, FT8, POTA, QSL), dźwięk, obserwowane znaki.")
            case .catShare: return L("Serwer zgodny z Hamlib rigctld (127.0.0.1:4532): WSJT-X, JTDX i inne programy sterują radiem przez FT-710 Control.")
            case .remote: return L("Praca zdalna z przeglądarki (telefon, tablet, komputer): hasło, sieć domowa, nadawanie zdalne, tunel Cloudflare.")
            case .program: return L("Język, aktualizacje, kopia ustawień i raport diagnostyczny.")
            }
        }
    }

    @AppStorage("config.section") private var sectionRaw = Section.station.rawValue
    private var section: Section { Section(rawValue: sectionRaw) ?? .station }

    var body: some View {
        // stała lista działów (bez przycisku zwijania paska bocznego)
        HStack(spacing: 0) {
            List(Section.allCases, selection: Binding(get: { section }, set: { if let s = $0 { sectionRaw = s.rawValue } })) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            .fixedSize(horizontal: true, vertical: false)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(section.title).font(.title2.bold())
                    Text(section.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .clipped()                                               // treść nigdy nie wychodzi na listę działów
        }
        // rozmiar optymalny (szerokość stała): mieści profil stacji z mapą i pozostałe działy bez przewijania w bok
        .frame(width: 1110)
        .frame(minHeight: 600, idealHeight: 875, maxHeight: .infinity)
        .navigationTitle(L("Konfiguracja"))
    }

    @ViewBuilder
    private var content: some View {
        let hub = DiagnosticsHub.shared
        let services = AppServices.shared
        switch section {
        case .station:
            StationProfileView(embedded: true)
                .environmentObject(services.logbook)
                .environmentObject(services.qrz)
                .environmentObject(services.uploader)
        case .radio:
            if let cat = hub.cat { RadioConnectionSettings(cat: cat) } else { mainWindowNeeded }
        case .display:
            DisplayView(display: DisplaySettings.shared, vertical: true)
        case .cluster:
            if let cluster = hub.cluster { ClusterSettingsForm(cluster: cluster) } else { mainWindowNeeded }
        case .ft8:
            if let ft8 = hub.ft8 { FT8ConfigSection(ft8: ft8) } else { mainWindowNeeded }
        case .cw:
            if let cw = hub.cw, let cat = hub.cat { CWKeyingSettings(cw: cw, cat: cat).frame(maxWidth: 520, alignment: .leading) } else { mainWindowNeeded }
        case .services:
            IntegrationsView(uploader: services.uploader, store: services.logbook, embedded: true)
        case .alerts:
            AlertSettingsView(center: AlertCenter.shared)
        case .catShare:
            if let share = hub.catShare { CATShareSection(share: share) } else { mainWindowNeeded }
        case .remote:
            if let remote = hub.remote { RemoteSectionView(remote: remote) } else { mainWindowNeeded }
        case .program:
            ProgramSettings()
        }
    }

    private var mainWindowNeeded: some View {
        Text(L("To ustawienie jest dostępne, gdy okno główne programu jest otwarte."))
            .foregroundStyle(.secondary)
    }
}

/// Dział „Radio i CAT”: port, prędkość, automatyczne łączenie, limit czasu nadawania.
/// Port i prędkość zmienia się przy rozłączonym radiu (jak na pasku stanu).
struct RadioConnectionSettings: View {
    @ObservedObject var cat: CATClient

    var body: some View {
        Form {
            HStack {
                Picker(L("Port CAT"), selection: $cat.selectedPort) {
                    if cat.ports.isEmpty { Text(L("brak portów")).tag("") }
                    ForEach(cat.ports, id: \.self) { Text($0).tag($0) }
                }
                Button(L("Odśwież")) { cat.refreshPorts() }
            }
            .disabled(cat.isConnected)
            Text(L("FT-710 tworzy dwa porty USB – CAT to zwykle ten z końcówką „0” (np. …-01D1055C0)."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Prędkość"), selection: $cat.baud) {
                ForEach([4800, 9600, 19200, 38400, 115200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .disabled(cat.isConnected)
            Text(L("Ta sama co w radiu: MENU → OPERATION SETTING → GENERAL → CAT RATE (zalecane 38400)."))
                .font(.caption).foregroundStyle(.secondary)
            if cat.isConnected {
                Text(L("Radio połączone – port i prędkość zmienisz po rozłączeniu (pasek stanu okna głównego)."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle(L("Łącz automatycznie"), isOn: $cat.autoConnect)
            Text(L("Program łączy się z radiem przy starcie i po ponownym podłączeniu USB."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L("Limit czasu nadawania"), selection: $cat.txTimeout) {
                Text("1 min").tag(60.0)
                Text("3 min").tag(180.0)
                Text("5 min").tag(300.0)
            }
            Text(L("Ochrona przed zablokowanym nadawaniem: po tym czasie program sam kończy nadawanie."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Dział „Program”: język, aktualizacje, kopia ustawień, raport diagnostyczny.
struct ProgramSettings: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.current.rawValue
    @State private var updateMessage: String?
    @State private var checking = false

    var body: some View {
        Form {
            Picker(L("Język"), selection: $languageCode) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            Text(L("Język interfejsu, pomocy i komunikatów (polski albo angielski)."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L("Wersja {1}", ADIF.programVersion))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button(L("Sprawdź aktualizacje")) {
                    checking = true
                    Task { @MainActor in
                        updateMessage = await UpdateChecker.shared.check()
                        checking = false
                    }
                }
                .disabled(checking)
            }
            if let updateMessage { Text(updateMessage).font(.caption) }
            Text(L("Program sprawdza nowe wersje na GitHubie przy starcie i raz na dobę."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Zapisz ustawienia programu…")) { SettingsBackup.saveWithPanel() }
                Button(L("Przywróć ustawienia programu…")) { SettingsBackup.restoreWithPanel() }
            }
            Text(L("Kopia wszystkich ustawień (bez haseł i bez dziennika) – np. przy przenosinach na nowego Maca."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L("Zapisz raport diagnostyczny…")) { DiagnosticsHub.saveWithPanel() }
            Text(L("Jeden plik do zgłoszenia błędu na GitHubie (bez haseł)."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}


/// Dział „DX Cluster”: węzeł, logowanie, łączenie i filtry - te same ustawienia co w zakładce DX CLUSTER.
struct ClusterSettingsForm: View {
    @ObservedObject var cluster: DXClusterClient
    @AppStorage("clusterBandFilter") private var bandFilter = "all"
    @AppStorage("clusterModeFilter") private var modeFilter = "all"
    @AppStorage("clusterHideWorked") private var hideWorked = false
    @AppStorage("clusterSetsMode") private var setsMode = true
    @State private var password = ""

    var body: some View {
        Form {
            Section(L("Węzeł")) {
                HStack {
                    TextField(L("Adres węzła"), text: $cluster.host)
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
                }
                TextField(L("Port"), value: $cluster.port, format: .number.grouping(.never))
                TextField(L("Znak (pusty = Mój znak)"), text: $cluster.login)
                SecureField(cluster.hasPassword ? L("Hasło – zapisane") : L("Hasło (jeśli węzeł wymaga)"), text: $password)
                    .onSubmit { cluster.setPassword(password); password = "" }
                Text(L("Enter zapisuje hasło w pęku kluczy; puste pole + Enter usuwa zapisane hasło"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Łącz automatycznie"), isOn: $cluster.autoConnect)
                Text(L("Połącz przy starcie programu i ponawiaj po zerwaniu połączenia")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("Ostatnie spoty po połączeniu"), isOn: $cluster.fetchRecent)
                Text(L("Po zalogowaniu wysyła sh/dx 30, żeby od razu zobaczyć ostatnie spoty")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Filtry spotów")) {
                Picker(L("Pasmo"), selection: $bandFilter) {
                    Text(L("wszystkie")).tag("all")
                    Text(L("moje pasmo")).tag("mine")
                    ForEach(Bands.table.map { $0.name }, id: \.self) { name in Text(name).tag(name) }
                }
                Picker(L("Tryb"), selection: $modeFilter) {
                    Text(L("wszystkie")).tag("all")
                    Text("CW").tag("CW")
                    Text("SSB").tag("SSB")
                    Divider()
                    Text(L("cyfrowe – wszystkie")).tag("DIGI")
                    ForEach(DXClusterView.digiModes, id: \.self) { Text($0).tag($0) }
                    Text(L("inne cyfrowe")).tag("OTHER")
                }
                Toggle(L("Ukryj zrobione na tym paśmie"), isOn: $hideWorked)
                Toggle(L("Ustaw tryb przy strojeniu"), isOn: $setsMode)
                Text(L("Podwójne kliknięcie ustawia też tryb (CW / SSB / DATA) zgodnie ze spotem")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620, alignment: .leading)
    }
}


/// Dział „FT8/FT4”: opcje sekwencji (wspólne z okienkiem „Opcje…”) i PSKReporter.
struct FT8ConfigSection: View {
    @ObservedObject var ft8: FT8Manager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FT8SequenceOptionsForm(ft8: ft8)
            Divider()
            Toggle(L("Zgłaszaj odebrane stacje do PSKReporter"), isOn: $ft8.pskEnabled)
            Text(L("Zgłaszanie odebranych stacji do pskreporter.info (co 5 min, każda stacja najwyżej raz na godzinę na paśmie)"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("Opis anteny wysyłany do PSKReporter (opcjonalnie)"), text: $ft8.pskAntenna)
                .frame(width: 320)
                .disabled(!ft8.pskEnabled)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
