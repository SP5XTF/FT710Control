import SwiftUI

/// Ręczne dodanie łączności (dziennik → „Dodaj QSO…”): np. z drugiego radia na 2 m, 70 cm, 23 cm - pasmo, data UTC,
/// emisja, propagacja (przemiennik, satelita…), radio i moc. Pasmo z pełnej tabeli ADIF (makeQSO zna tylko pasma
/// FT-710, więc łączność na 145,5 MHz dostałaby puste pasmo - nie liczyłaby się do VUCC ani statystyk).
struct ManualQSOView: View {
    @ObservedObject var store: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookup = CallLookup()

    // zapamiętywane - przy dopisywaniu łączności z drugiego radia wpisuje się je raz
    @AppStorage("manual.band") private var band = "2m"
    @AppStorage("manual.mode") private var modeLabel = "FM"
    @AppStorage("manual.rig") private var rig = ""
    @AppStorage("manual.power") private var power = ""
    @AppStorage("manual.prop") private var propMode = ""
    @AppStorage("manual.sat") private var satName = ""

    @State private var call = ""
    @State private var date = Date()
    @State private var frequency = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var name = ""
    @State private var qth = ""
    @State private var grid = ""
    @State private var comment = ""
    @State private var message: String?
    @State private var savedCount = 0
    @State private var autoFill = QRZAutoFill()

    static let bands = ["160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m",
                        "6m", "4m", "2m", "70cm", "23cm", "13cm", "3cm"]

    /// Emisje dziennika i dodatkowe VHF/UHF (ADIF: MSK144 - tryb; Q65 - MFSK/Q65).
    static let modes: [LogModePreset] = LogModePreset.all + [
        LogModePreset(label: "MSK144", mode: "MSK144", submode: nil, defaultRST: ""),
        LogModePreset(label: "Q65", mode: "MFSK", submode: "Q65", defaultRST: "")
    ]

    /// ADIF PROP_MODE (puste - bezpośrednio, bez określania).
    static let propagation: [(code: String, name: String)] = [
        ("", "—"), ("RPT", "Przemiennik"), ("SAT", "Satelita"), ("TR", "Tropo"), ("ES", "Sporadyczne E"),
        ("MS", "Meteor scatter"), ("EME", "EME (odbicie od Księżyca)"), ("AUR", "Zorza"), ("F2", "F2 (jonosfera)")
    ]

    private var preset: LogModePreset { Self.modes.first { $0.label == modeLabel } ?? Self.modes[0] }
    private var frequencyHz: Int? { LogFrequency.parseMHz(frequency) }
    private var frequencyBand: String? { frequencyHz.flatMap(LogFrequency.band(for:)) }
    private var canSave: Bool {
        QRZClient.baseCall(call).count >= 3 && frequencyHz != nil && frequencyBand == band
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Dodaj QSO ręcznie")).font(.title3.bold())
            Text(L("Np. łączności z drugiego radia (2 m, 70 cm, 23 cm). Zapis jak w dzienniku programu: kraj, strefy, odległość, wysyłka do serwisów; z lokatorem liczy się do VUCC."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form {
                Section {
                    TextField(L("Znak"), text: Binding(get: { call }, set: { callChanged($0) }))
                        .font(.system(.title3, design: .monospaced))
                    if let info = lookupInfo { Text(info).font(.caption).foregroundStyle(.secondary) }
                    DatePicker(L("Data i godzina (UTC)"), selection: $date)
                        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                }
                Section {
                    Picker(L("Pasmo"), selection: $band) {
                        ForEach(Self.bands, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: band) { _ in frequency = Self.defaultFrequency(band: band, mode: modeLabel) }
                    Picker(L("Emisja"), selection: $modeLabel) {
                        ForEach(Self.modes) { Text($0.label).tag($0.label) }
                    }
                    .onChange(of: modeLabel) { _ in
                        // typowa częstotliwość emisji, chyba że wpisano już własną w tym paśmie
                        if frequencyBand != band || frequency == Self.defaultFrequency(band: band, mode: lastMode) {
                            frequency = Self.defaultFrequency(band: band, mode: modeLabel)
                        }
                        lastMode = modeLabel
                    }
                    HStack {
                        TextField(L("Częstotliwość (MHz)"), text: $frequency)
                        if !frequency.isEmpty, frequencyBand != band {
                            Text(L("poza pasmem {1}", band)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        TextField(L("RST wysłany"), text: $rstSent, prompt: Text(preset.defaultRST))
                        TextField(L("RST odebrany"), text: $rstRcvd, prompt: Text(preset.defaultRST))
                    }
                }
                Section {
                    TextField(L("Imię"), text: $name)
                    TextField("QTH", text: $qth)
                    TextField(L("Lokator"), text: $grid)
                    TextField(L("Uwagi"), text: $comment)
                }
                Section {
                    Picker(L("Propagacja"), selection: $propMode) {
                        ForEach(Self.propagation, id: \.code) { Text(L($0.name)).tag($0.code) }
                    }
                    if propMode == "SAT" {
                        TextField(L("Satelita (np. QO-100, SO-50)"), text: $satName)
                    }
                    HStack {
                        TextField(L("Moje radio (np. IC-9700)"), text: $rig)
                        TextField(L("Moc (W)"), text: $power).frame(width: 110)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(Theme.ok) }
                Spacer()
                Button(L("Zamknij")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Zapisz i następne")) { save(next: true) }
                    .disabled(!canSave)
                    .help(L("Zapisuje i czyści znak oraz dane stacji - data, pasmo, emisja i radio zostają"))
                Button(L("Zapisz")) { save(next: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 560, height: 720)
        .onAppear {
            lastMode = modeLabel
            if frequency.isEmpty { frequency = Self.defaultFrequency(band: band, mode: modeLabel) }
        }
        .onChange(of: lookup.record) { record in
            guard let record, record.call == QRZClient.baseCall(call) else { return }
            let away = OperatingLocation.isAwayFromHome(call)
            if name.isEmpty { name = record.firstName.isEmpty ? record.displayName : record.firstName; autoFill.filled("name", name) }
            if !away, qth.isEmpty { qth = record.city; autoFill.filled("qth", qth) }
            if !away, grid.isEmpty { grid = record.grid.uppercased(); autoFill.filled("grid", grid) }
        }
    }

    @State private var lastMode = ""

    private var lookupInfo: String? {
        let base = QRZClient.baseCall(call)
        guard base.count >= 3 else { return nil }
        let before = store.qsos.filter { QRZClient.baseCall($0.call) == base }
        let onBand = before.filter { $0.band == band }.count
        let country = CTYDatabase.shared.table?.lookup(call).map { $0.entity.name } ?? ""
        let worked = before.isEmpty ? L("nowa stacja") : L("było: {1} QSO (na {2}: {3})", before.count, band, onBand)
        return [country, worked].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func callChanged(_ value: String) {
        let cleaned = value.uppercased().filter { !$0.isWhitespace }
        if cleaned != call { autoFill.clear([("name", $name), ("qth", $qth), ("grid", $grid)]) }
        call = cleaned
        message = nil
        if QRZClient.baseCall(call).count >= 3, AppServices.shared.qrz.canLookup {
            lookup.request(call, using: AppServices.shared.qrz, debounce: true)
        }
    }

    private func save(next: Bool) {
        guard canSave, let hz = frequencyHz else { return }
        let callsign = call.uppercased()
        var qso = store.makeQSO(call: callsign, start: date, end: date, freqHz: hz, preset: preset,
                                rstSent: rstSent.isEmpty ? preset.defaultRST : rstSent,
                                rstRcvd: rstRcvd.isEmpty ? preset.defaultRST : rstRcvd,
                                name: name, qth: qth, grid: grid.uppercased(), comment: comment, record: lookup.record)
        qso.band = band                                          // pełna tabela ADIF (2m, 70cm, 23cm…)
        if !propMode.isEmpty { qso.extra["PROP_MODE"] = propMode }
        if propMode == "SAT", !satName.trimmingCharacters(in: .whitespaces).isEmpty {
            qso.extra["SAT_NAME"] = satName.trimmingCharacters(in: .whitespaces).uppercased()
        }
        if !rig.trimmingCharacters(in: .whitespaces).isEmpty { qso.extra["MY_RIG"] = rig.trimmingCharacters(in: .whitespaces) }
        let watts = power.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let value = Double(watts), value > 0 { qso.extra["TX_PWR"] = watts }
        store.add(qso)
        savedCount += 1
        message = L("Zapisano {1} ({2}, {3}) - razem w tym oknie: {4}", callsign, band, modeLabel, savedCount)
        if next {
            call = ""; name = ""; qth = ""; grid = ""; comment = ""; rstSent = ""; rstRcvd = ""
            lookup.clear()
        } else {
            dismiss()
        }
    }

    /// Typowa częstotliwość pasma dla emisji (MHz) - podpowiedź, do zmiany.
    static func defaultFrequency(band: String, mode: String) -> String {
        let fm = mode == "FM", cw = mode == "CW", ft8 = mode == "FT8", ft4 = mode == "FT4"
        let digital = ["MSK144", "Q65", "JS8", "PSK31", "RTTY"].contains(mode)
        switch band {
        case "2m": return fm ? "145.500" : ft8 ? "144.174" : ft4 ? "144.170" : cw ? "144.050" : mode == "MSK144" ? "144.360" : digital ? "144.180" : "144.300"
        case "70cm": return fm ? "433.500" : ft8 ? "432.174" : cw ? "432.050" : digital ? "432.180" : "432.200"
        case "23cm": return fm ? "1297.500" : ft8 ? "1296.174" : cw ? "1296.050" : digital ? "1296.180" : "1296.200"
        case "13cm": return "2320.200"
        case "3cm": return "10368.200"
        case "4m": return fm ? "70.450" : ft8 ? "70.154" : cw ? "70.050" : "70.200"
        case "6m": return fm ? "51.510" : ft8 ? "50.313" : ft4 ? "50.318" : cw ? "50.090" : "50.150"
        default:
            if ft8 || ft4, let hz = (ft8 ? FTMode.ft8 : FTMode.ft4).dialFrequencies.first(where: { LogFrequency.band(for: $0) == band }) {
                // do 4 miejsc (FT4 na 40 m: 7,0475 MHz), bez zbędnych zer na końcu, min. 3 miejsca
                var text = String(format: "%.4f", Double(hz) / 1_000_000)
                if text.hasSuffix("0") { text.removeLast() }
                return text
            }
            let phone: [String: String] = ["160m": "1.850", "80m": "3.700", "60m": "5.360", "40m": "7.100", "30m": "10.120",
                                           "20m": "14.200", "17m": "18.130", "15m": "21.250", "12m": "24.950", "10m": fm ? "29.600" : "28.500"]
            let cwFreq: [String: String] = ["160m": "1.830", "80m": "3.530", "60m": "5.352", "40m": "7.020", "30m": "10.110",
                                            "20m": "14.030", "17m": "18.080", "15m": "21.030", "12m": "24.900", "10m": "28.030"]
            return (cw || digital ? cwFreq[band] : phone[band]) ?? ""
        }
    }
}
