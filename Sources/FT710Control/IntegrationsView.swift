import SwiftUI
import AppKit

/// Usługi online dziennika: lista ze stanem (jak „LoTW · działa · ostatnia wysyłka 27 h temu”)
/// i ustawienia wybranej usługi.
struct IntegrationsView: View {
    @ObservedObject var uploader: LogUploader
    @ObservedObject var store: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: LogService? = .lotw

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Usługi online")).font(.title2.bold())
            HStack(alignment: .top, spacing: 14) {
                List(LogService.allCases, selection: $selection) { service in
                    ServiceRow(cfg: uploader.config(service)).tag(service)
                }
                .frame(width: 300)
                if let selection {
                    ServiceDetail(service: selection, cfg: uploader.config(selection), uploader: uploader, store: store)
                        .id(selection)
                } else {
                    Text(L("Wybierz usługę z listy.")).foregroundStyle(.secondary)
                }
            }
            Text(L("Dane stacji z QRZ (callbook) ustawia się w oknie dziennika."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 900, height: 600)
    }
}

/// Opis stanu usługi do listy.
@MainActor
func serviceStatusText(_ cfg: LogServiceSettings) -> String {
    if !cfg.isConfigured { return L("brak danych logowania") }
    if cfg.busy { return L("wysyłanie…") }
    if cfg.lastError != nil { return L("błąd - szczegóły po wybraniu") }
    var parts = [cfg.autoUpload ? L("wysyłka automatyczna") : L("wysyłka automatyczna wył.")]
    if let last = cfg.lastUpload { parts.append(L("ostatnia wysyłka {1}", relativeTime(last))) }
    return parts.joined(separator: " · ")
}

/// „27 godz. temu” / „27 hours ago” w języku interfejsu.
func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: AppLanguage.current == .en ? "en" : "pl")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private struct ServiceRow: View {
    @ObservedObject var cfg: LogServiceSettings

    private var color: Color {
        if !cfg.isConfigured { return .gray }
        if cfg.lastError != nil { return .red }
        return cfg.autoUpload ? Theme.ok : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(cfg.service.name).bold()
                    Text(cfg.accountSummary.isEmpty ? "—" : cfg.accountSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(serviceStatusText(cfg)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ServiceDetail: View {
    let service: LogService
    @ObservedObject var cfg: LogServiceSettings
    @ObservedObject var uploader: LogUploader
    @ObservedObject var store: LogbookStore

    @State private var secret = ""
    @State private var secondSecret = ""
    @State private var confirmMarkAll = false

    private var pendingCount: Int { store.qsos.filter { !service.isSent($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.name).font(.title3.bold())
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form { fields }
                .formStyle(.grouped)

            HStack(spacing: 8) {
                Button(L("Zapisz dane logowania")) { saveSecrets() }
                    .disabled(secret.isEmpty && secondSecret.isEmpty)
                Toggle(L("Wysyłaj automatycznie po zapisaniu QSO"), isOn: $cfg.autoUpload)
                    .disabled(!cfg.isConfigured)
                Spacer()
                if cfg.busy { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 8) {
                Button(L("Test")) { Task { await uploader.test(service) } }
                    .help(L("Sprawdza połączenie i dane logowania do serwisu (bez wysyłania łączności)"))
                    .disabled(!service.hasTest || cfg.busy || !cfg.isConfigured)
                Button(L("Wyślij zaległe ({1})", pendingCount)) { uploader.uploadPending(service) }
                    .disabled(!cfg.isConfigured || cfg.busy || pendingCount == 0)
                    .help(L("Wysyła łączności, które nie zostały jeszcze wysłane do tej usługi"))
                Button(L("Oznacz wszystkie jako wysłane…")) { confirmMarkAll = true }
                    .disabled(pendingCount == 0)
                    .help(L("Gdy dziennik był już wysłany innym programem - żeby nie wysyłać go ponownie"))
                Spacer()
                if cfg.hasSecret || cfg.hasSecondSecret {
                    Button(L("Usuń dane logowania")) { cfg.forgetCredentials() }
                }
            }

            if !cfg.lastMessage.isEmpty {
                Text(Lr(cfg.lastMessage))
                    .font(.callout)
                    .foregroundStyle(cfg.lastError != nil ? .red : Theme.ok)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = cfg.lastUpload {
                Text(L("Ostatnia udana wysyłka: {1}", relativeTime(last)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog(Text(L("Oznaczyć {1} łączności jako wysłane do {2}?", pendingCount, service.name)),
                            isPresented: $confirmMarkAll) {
            Button(L("Oznacz jako wysłane")) { uploader.markAllSent(service) }
        } message: {
            Text(L("Nie zostaną wysłane - tylko oznaczone, że już są w tej usłudze."))
        }
    }

    // MARK: - Pola zależne od usługi

    @ViewBuilder
    private var fields: some View {
        switch service {
        case .lotw:
            HStack {
                TextField(L("Program TQSL"), text: $cfg.path)
                Button(L("Wybierz…")) { chooseTQSL() }
            }
            TextField(L("Lokalizacja stacji w TQSL"), text: $cfg.location)
            Toggle(L("Przekazuj hasło certyfikatu do TQSL automatycznie"), isOn: $cfg.passPasswordToTQSL)
            Text(cfg.passPasswordToTQSL
                 ? L("Hasło trafia do TQSL w linii poleceń - na czas podpisywania widzą je inne programy na tym Macu (np. polecenie ps). Wygodne przy automatycznej wysyłce, ale mniej bezpieczne.")
                 : L("Zalecane: jeśli certyfikat ma hasło, TQSL sam o nie zapyta w swoim okienku przy podpisywaniu - hasło nie przechodzi przez program. Certyfikat bez hasła - bez pytania."))
                .font(.caption2).foregroundStyle(cfg.passPasswordToTQSL ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if cfg.passPasswordToTQSL {
                secretField(L("Hasło certyfikatu (jeśli ustawione)"), $secret, saved: cfg.hasSecret)
            }
            Divider()
            Text(L("Pobieranie potwierdzeń (logowanie na stronie lotw.arrl.org):")).font(.caption).foregroundStyle(.secondary)
            TextField(L("Login LoTW (zwykle znak)"), text: $cfg.account)
            secretField(L("Hasło do strony LoTW"), $secondSecret, saved: cfg.hasSecondSecret)
        case .qrzLogbook:
            secretField(L("Klucz API dziennika QRZ"), $secret, saved: cfg.hasSecret)
        case .eqsl:
            TextField(L("Użytkownik eQSL (znak)"), text: $cfg.account)
            secretField(L("Hasło"), $secret, saved: cfg.hasSecret)
            TextField(L("QTH Nickname (opcjonalnie)"), text: $cfg.location)
        case .clublog:
            TextField(L("E-mail konta Club Log"), text: $cfg.account)
            TextField(L("Znak (dziennik w Club Log)"), text: $cfg.callsign)
            secretField(L("Hasło aplikacji Club Log"), $secret, saved: cfg.hasSecret)
            secretField(L("Klucz API Club Log"), $secondSecret, saved: cfg.hasSecondSecret)
        case .hrdlog:
            TextField(L("Znak"), text: $cfg.callsign)
            secretField(L("Kod wysyłania (Upload Code)"), $secret, saved: cfg.hasSecret)
        case .wrl:
            secretField(L("Klucz API (wrl_live_…)"), $secret, saved: cfg.hasSecret)
            TextField(L("ID dziennika (puste = dziennik domyślny)"), text: $cfg.path)
        case .cloudlog:
            TextField(L("Adres serwera (np. https://log.example.com)"), text: $cfg.location)
            TextField(L("ID profilu stacji"), text: $cfg.path)
            secretField(L("Klucz API (odczyt i zapis)"), $secret, saved: cfg.hasSecret)
        }
    }

    private func secretField(_ title: String, _ value: Binding<String>, saved: Bool) -> some View {
        SecureField(saved ? title + " – " + L("zapisane") : title, text: value)
    }

    private var description: String {
        switch service {
        case .lotw:
            return L("Podpis i wysyłka przez program TQSL (ARRL). Wymaga zainstalowanego TQSL z certyfikatem i skonfigurowaną lokalizacją stacji; łączności spoza zakresu certyfikatu zostaną odrzucone.") + " "
                + L("Do pobierania potwierdzeń potrzebne są login i hasło do strony LoTW (nie hasło certyfikatu) - okno dziennika → „Potwierdzenia QSL…”.")
        case .qrzLogbook:
            return L("Klucz API jest w QRZ: Logbook → Settings → API. Wysyłka (INSERT) wymaga subskrypcji QRZ.")
        case .eqsl:
            return L("Logowanie jak na eqsl.cc. Jeśli masz kilka QTH w eQSL, podaj QTH Nickname.")
        case .clublog:
            return L("Klucz API identyfikuje program - wniosek po zalogowaniu: clublog.org/requestapikey.php. Hasło: najlepiej hasło aplikacji z ustawień konta Club Log. Pojedyncze QSO idą od razu (realtime.php), zaległe - jednym plikiem ADIF (putlogs.php). Po błędzie automatyczna wysyłka jest wstrzymana do ręcznego „Wyślij zaległe”.")
        case .hrdlog:
            return L("Kod wysyłania znajdziesz na hrdlog.net w ustawieniach profilu (Upload Code). Znak bez dodatków typu /P.")
        case .wrl:
            return L("Klucz API wygenerujesz w World Radio League: Integrations → Developer API (pokazywany jest tylko raz). Bez ID dziennika łączności trafiają do dziennika domyślnego - Test pokaże, czy jest ustawiony, a jeśli nie, poda listę dzienników z ich ID. Poprawione łączności są w WRL aktualizowane.")
        case .cloudlog:
            return L("Własny serwer Cloudlog lub Wavelog. Klucz API z uprawnieniem zapisu i ID profilu stacji znajdziesz w ustawieniach konta na serwerze.")
        }
    }

    private func saveSecrets() {
        if !secret.isEmpty { cfg.setSecret(secret) }
        if !secondSecret.isEmpty { cfg.setSecondSecret(secondSecret) }
        secret = ""
        secondSecret = ""
    }

    private func chooseTQSL() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true    // pozwala wejść do tqsl.app/Contents/MacOS
        panel.directoryURL = URL(fileURLWithPath: "/Applications/TrustedQSL")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Wybrano tqsl.app - użyj pliku wykonywalnego w środku pakietu.
        if url.pathExtension == "app" { url = url.appendingPathComponent("Contents/MacOS/tqsl") }
        cfg.path = url.path
    }
}
