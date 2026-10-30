import SwiftUI
import AppKit

/// Profil stacji: okno powitalne przy pierwszym uruchomieniu i później z menu „Profil stacji…”.
/// Dane trafiają do dziennika (Mój znak, Mój lokator, pola ADIF MY_*), DX Cluster i usług online.
struct StationProfileView: View {
    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var qrz: QRZClient
    @EnvironmentObject private var uploader: LogUploader
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.current.rawValue
    @Environment(\.dismiss) private var dismiss

    static let completedKey = "stationProfileCompleted"

    @State private var call = ""
    @State private var name = ""
    @State private var qth = ""
    @State private var grid = ""
    @State private var country = ""
    @State private var dxcc = ""
    @State private var cqZone = ""
    @State private var ituZone = ""
    @State private var qrzUser = ""
    @State private var qrzPassword = ""
    @State private var hamqthUser = ""
    @State private var hamqthPassword = ""
    @State private var lookingUp = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var loaded = false

    private var firstRun: Bool { !UserDefaults.standard.bool(forKey: Self.completedKey) }
    private var callValid: Bool {
        call.count >= 3 && call.range(of: "^[A-Z0-9/]+$", options: .regularExpression) != nil
    }
    private var gridValid: Bool { grid.isEmpty || Geo.isValidGrid(grid) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker(L("Język"), selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        stationForm
                        qrzBox
                        hamqthBox
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        StationMap(home: Geo.coordinate(fromGrid: grid), homeLabel: call.isEmpty ? grid : call,
                                   remote: nil, remoteLabel: "")
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(Geo.coordinate(fromGrid: grid) == nil
                             ? L("Wpisz lokator, żeby zobaczyć położenie stacji.")
                             : L("Położenie według lokatora {1}.", grid))
                            .font(.caption).foregroundStyle(.secondary)
                        usageBox
                    }
                    .frame(width: 330)
                }

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(messageIsError ? .red : Theme.ok)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if firstRun {
                        Button(L("Pomiń na razie")) { finish(save: false) }
                            .help(L("Profil można uzupełnić później: menu FT710Control → Profil stacji…"))
                    }
                    Spacer()
                    if !firstRun {
                        Button(L("Anuluj"), role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    Button(firstRun ? L("Zapisz i zacznij") : L("Zapisz")) { finish(save: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!callValid || !gridValid)
                }
            }
            .padding(24)
        }
        .frame(width: 820, height: 680)
        .id(languageCode)
        .navigationTitle(L("Profil stacji"))
        .onAppear(perform: loadOnce)
    }

    // MARK: - Części

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 38))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(firstRun ? L("Witaj w FT-710 Control") : L("Profil stacji"))
                    .font(.title.bold())
                Text(L("Podaj dane swojej stacji. Program użyje ich w dzienniku (odległości, azymuty, pola ADIF), w DX Cluster i w usługach online. Po wpisaniu znaku resztę można pobrać z QRZ.com."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stationForm: some View {
        GroupBox(L("Twoja stacja")) {
            Form {
                HStack {
                    TextField(L("Znak"), text: $call)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: call) { value in
                            let cleaned = value.uppercased().filter { !$0.isWhitespace }
                            if cleaned != value { call = cleaned }
                        }
                    Button(L("Pobierz z QRZ")) { fetchFromQRZ() }
                        .disabled(!callValid || lookingUp || (!qrz.isConfigured && (qrzUser.isEmpty || qrzPassword.isEmpty)))
                    if lookingUp { ProgressView().controlSize(.small) }
                }
                TextField(L("Imię i nazwisko"), text: $name)
                TextField(L("QTH (miejscowość)"), text: $qth)
                TextField(L("Lokator (np. KO02ME)"), text: $grid)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: grid) { value in
                        let cleaned = value.uppercased().filter { !$0.isWhitespace }
                        if cleaned != value { grid = cleaned }
                    }
                if !gridValid {
                    Text(L("Nieprawidłowy lokator (np. KO02 albo KO02ME)")).font(.caption).foregroundStyle(.red)
                }
                TextField(L("Kraj"), text: $country)
                HStack {
                    TextField("DXCC", text: $dxcc)
                    TextField("CQ", text: $cqZone)
                    TextField("ITU", text: $ituZone)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var qrzBox: some View {
        GroupBox(L("QRZ.com (opcjonalnie)")) {
            VStack(alignment: .leading, spacing: 6) {
                if qrz.isConfigured {
                    Text(L("Konto QRZ: {1} · {2}", qrz.username, qrz.status))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Konto QRZ pozwala pobrać dane po znaku - tu i przy każdej łączności w dzienniku. Hasło trafi do pęku kluczy macOS."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(L("Użytkownik QRZ"), text: $qrzUser)
                        SecureField(L("Hasło"), text: $qrzPassword)
                    }
                }
            }
            .padding(6)
        }
    }

    /// HamQTH - darmowa baza znaków: samodzielnie albo jako uzupełnienie QRZ (braki danych bez subskrypcji XML).
    private var hamqthBox: some View {
        GroupBox(L("HamQTH.com (opcjonalnie, bezpłatnie)")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Darmowa baza znaków: imię, QTH, lokator, kraj i strefy. Działa sama albo razem z QRZ - gdy QRZ nie zna znaku albo bez subskrypcji XML nie podaje lokatora i adresu, braki uzupełnia HamQTH. Konto zakłada się na hamqth.com; hasło trafi do pęku kluczy."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if qrz.hasHamQTH {
                    HStack {
                        Text(L("Konto HamQTH: {1}", qrz.hamqthUser)).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Usuń konto")) { qrz.clearHamQTH() }
                    }
                } else {
                    HStack {
                        TextField(L("Użytkownik HamQTH (znak)"), text: $hamqthUser)
                        SecureField(L("Hasło"), text: $hamqthPassword)
                        Button(L("Zapisz")) {
                            qrz.setHamQTH(user: hamqthUser, password: hamqthPassword)
                            hamqthPassword = ""
                        }
                        .disabled(hamqthUser.trimmingCharacters(in: .whitespaces).isEmpty || hamqthPassword.isEmpty)
                    }
                }
            }
            .padding(6)
        }
    }

    private var usageBox: some View {
        GroupBox(L("Gdzie program użyje tych danych")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("• Dziennik: Mój znak i Mój lokator - odległości, azymuty, mapa"))
                Text(L("• Każda łączność: pola ADIF MY_NAME, MY_CITY, MY_COUNTRY, MY_DXCC, MY_CQ_ZONE, MY_ITU_ZONE"))
                Text(L("• DX Cluster: logowanie Twoim znakiem"))
                Text(L("• Usługi online: znak dla eQSL, HRDLog.net i Club Log (jeśli jeszcze nie ustawiony)"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
        }
    }

    // MARK: - Działania

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        call = logbook.myCall
        grid = logbook.myGrid.uppercased()
        name = logbook.myName
        qth = logbook.myQTH
        country = logbook.myCountry
        dxcc = logbook.myDXCC
        cqZone = logbook.myCQZone
        ituZone = logbook.myITUZone
        qrzUser = qrz.username
    }

    private func fetchFromQRZ() {
        if !qrz.isConfigured {
            qrz.saveCredentials(username: qrzUser, password: qrzPassword)
            qrzPassword = ""
        }
        lookingUp = true
        message = nil
        let callsign = call
        Task { @MainActor in
            let outcome = await qrz.lookup(callsign)
            lookingUp = false
            switch outcome {
            case .found(let record):
                // Pobrane dane zastępują wpisane - użytkownik prosił o pobranie.
                if !record.displayName.isEmpty { name = record.displayName }
                if !record.city.isEmpty { qth = record.city }
                let fetchedGrid = record.grid.isEmpty ? (record.coordinate.map { Geo.grid(for: $0) } ?? "") : record.grid
                if !fetchedGrid.isEmpty { grid = fetchedGrid.uppercased() }
                if !record.country.isEmpty { country = record.country }
                if !record.dxcc.isEmpty { dxcc = record.dxcc }
                if !record.cqZone.isEmpty { cqZone = record.cqZone }
                if !record.ituZone.isEmpty { ituZone = record.ituZone }
                messageIsError = false
                message = qrz.limitedData
                    ? L("Pobrano dane z QRZ (konto bez subskrypcji XML - część pól może być pusta).")
                    : L("Pobrano dane z QRZ. Sprawdź je przed zapisaniem.")
            case .notFound:
                messageIsError = true
                message = L("Znaku nie ma w QRZ.")
            case .failed(let error):
                messageIsError = true
                message = L("QRZ: {1}", error)
            }
        }
    }

    private func finish(save: Bool) {
        if save {
            let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
            logbook.myCall = call
            logbook.myGrid = grid
            logbook.myName = trimmed(name)
            logbook.myQTH = trimmed(qth)
            logbook.myCountry = trimmed(country)
            logbook.myDXCC = trimmed(dxcc)
            logbook.myCQZone = trimmed(cqZone)
            logbook.myITUZone = trimmed(ituZone)
            // Znak domyślny dla usług, w których nie jest jeszcze ustawiony.
            let eqsl = uploader.config(.eqsl)
            if eqsl.account.isEmpty { eqsl.account = call }
            let hrdlog = uploader.config(.hrdlog)
            if hrdlog.callsign.isEmpty { hrdlog.callsign = QRZClient.baseCall(call) }
            let clublog = uploader.config(.clublog)
            if clublog.callsign.isEmpty { clublog.callsign = call }
        }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }
}

/// Menu aplikacji: „Profil stacji…” (⇧⌘,).
struct ProfileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Profil stacji…")) { openWindow(id: "profile") }
                .keyboardShortcut(",", modifiers: [.command, .shift])
        }
    }
}
