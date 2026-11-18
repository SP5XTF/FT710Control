import SwiftUI

/// Okno „Konfiguracja” (menu programu, ⌘,): wszystkie ustawienia w jednym miejscu, z opisami działów.
/// Działy korzystają z tych samych widoków co wcześniej zakładki (EKRAN, CAT SHARE, ZDALNIE) i okna -
/// każde ustawienie istnieje w programie raz. Obiekty okna głównego (radio, praca zdalna, CAT Share) przez
/// rejestr DiagnosticsHub (okno Konfiguracji jest osobnym oknem).
struct ConfigurationView: View {
    enum Section: String, CaseIterable, Identifiable {
        case station, radio, display, services, alerts, catShare, remote, program
        var id: String { rawValue }

        var title: String {
            switch self {
            case .station: return L("Stacja")
            case .radio: return L("Radio i CAT")
            case .display: return L("Skop i wodospad")
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
