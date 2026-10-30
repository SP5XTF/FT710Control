import SwiftUI

/// Edycja zapisanej łączności. Pola niewidoczne w formularzu (np. potwierdzenia QSL z importu ADIF)
/// zostają nietknięte.
struct QSOEditView: View {
    let original: QSO
    @ObservedObject var qrz: QRZClient
    let fallbackMyGrid: String
    let onSave: (QSO) -> Void
    /// Usunięcie łączności z okna edycji (nil - bez przycisku); potwierdzenie (także serwisy) pokazuje wywołujący.
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var call: String
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var frequency: String
    @State private var band: String
    @State private var modeLabel: String
    @State private var rstSent: String
    @State private var rstRcvd: String
    @State private var name: String
    @State private var qth: String
    @State private var grid: String
    @State private var country: String
    @State private var comment: String
    /// Referencje dyplomów (pola ADIF): gmina PGA (CNTY), IOTA, SOTA_REF, WWFF_REF, POTA_REF.
    @State private var refs: [String: String]
    static let refFields: [(field: String, label: String)] = [("CNTY", "Gmina / CNTY"), ("IOTA", "IOTA"), ("SOTA_REF", "SOTA"),
                                                               ("WWFF_REF", "WWFF"), ("POTA_REF", "POTA")]
    @State private var error: String?
    @State private var lookingUp = false

    init(qso: QSO, qrz: QRZClient, fallbackMyGrid: String, onDelete: (() -> Void)? = nil,
         onSave: @escaping (QSO) -> Void) {
        self.onDelete = onDelete
        original = qso
        _qrz = ObservedObject(wrappedValue: qrz)
        self.fallbackMyGrid = fallbackMyGrid
        self.onSave = onSave
        _call = State(initialValue: qso.call)
        _start = State(initialValue: qso.start)
        _hasEnd = State(initialValue: qso.end != nil)
        _end = State(initialValue: qso.end ?? qso.start)
        _frequency = State(initialValue: qso.freqHz > 0 ? String(format: "%.6f", Double(qso.freqHz) / 1_000_000) : "")
        _band = State(initialValue: qso.band)
        _modeLabel = State(initialValue: qso.modeLabel)
        _rstSent = State(initialValue: qso.rstSent)
        _rstRcvd = State(initialValue: qso.rstRcvd)
        _name = State(initialValue: qso.name)
        _qth = State(initialValue: qso.qth)
        _grid = State(initialValue: qso.grid)
        _country = State(initialValue: qso.country)
        _comment = State(initialValue: qso.comment)
        _refs = State(initialValue: Dictionary(uniqueKeysWithValues: Self.refFields.map { ($0.field, qso.extra[$0.field] ?? "") }))
    }

    /// Tryby do wyboru; tryb spoza listy (np. z importu) zostaje jako dodatkowa pozycja.
    private var modeOptions: [String] {
        var labels = LogModePreset.all.map(\.label)
        if !labels.contains(original.modeLabel), !original.modeLabel.isEmpty { labels.append(original.modeLabel) }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edycja łączności")).font(.title2.bold())

            Form {
                Section {
                    TextField(L("Znak"), text: $call)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: call) { value in
                            let cleaned = value.uppercased().filter { !$0.isWhitespace }
                            if cleaned != value { call = cleaned }
                        }
                    DatePicker(L("Początek (UTC)"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Toggle(L("Zapisz koniec QSO"), isOn: $hasEnd)
                    if hasEnd {
                        DatePicker(L("Koniec (UTC)"), selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section {
                    TextField(L("Częstotliwość (MHz)"), text: $frequency)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: frequency) { value in
                            if let hz = LogFrequency.parseMHz(value), let name = LogFrequency.band(for: hz) { band = name }
                        }
                    TextField(L("Pasmo"), text: $band)
                    Picker(L("Tryb"), selection: $modeLabel) {
                        ForEach(modeOptions, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField(L("RST nad."), text: $rstSent)
                        TextField(L("RST odb."), text: $rstRcvd)
                    }
                }
                Section(L("Wysyłka do usług")) {
                    ForEach(LogService.allCases) { service in
                        HStack {
                            Text(service.name)
                            Spacer()
                            if service.isSent(original) {
                                Text(L("wysłano {1}", original.extra[service.dateField] ?? ""))
                                    .foregroundStyle(Theme.ok)
                            } else {
                                Text(L("nie wysłano")).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                Section {
                    TextField(L("Imię"), text: $name)
                    TextField("QTH", text: $qth)
                    TextField(L("Lokator"), text: $grid)
                    TextField(L("Kraj"), text: $country)
                    TextField(L("Uwagi"), text: $comment)
                }
                Section(L("Referencje dyplomów")) {
                    ForEach(Self.refFields, id: \.field) { item in
                        TextField(L(item.label), text: Binding(get: { refs[item.field] ?? "" },
                                                               set: { refs[item.field] = $0.uppercased() }))
                    }
                }
            }
            .formStyle(.grouped)
            .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)   // daty i godziny w UTC

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button(L("Uzupełnij z QRZ")) { fillFromQRZ() }
                    .disabled(!qrz.canLookup || call.count < 3 || lookingUp)
                    .help(L("Wypełnia tylko puste pola: imię, QTH, lokator, kraj"))
                if lookingUp { ProgressView().controlSize(.small) }
                if onDelete != nil {
                    Button(role: .destructive) {
                        dismiss()
                        onDelete?()
                    } label: {
                        Text(L("Usuń łączność…")).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(L("Anuluj"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Zapisz")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func fillFromQRZ() {
        lookingUp = true
        let callsign = call
        Task { @MainActor in
            let outcome = await qrz.lookup(callsign)
            lookingUp = false
            switch outcome {
            case .found(let record):
                if name.isEmpty { name = record.firstName.isEmpty ? record.displayName : record.firstName }
                if OperatingLocation.isAwayFromHome(callsign) {
                    // spoza swojego kraju (P4/WE9V): kraj z prefiksu, bez QTH i lokatora domu stacji
                    if country.isEmpty { country = OperatingLocation.ctyFields(callsign)["COUNTRY"] ?? "" }
                } else {
                    if qth.isEmpty { qth = record.city }
                    if grid.isEmpty { grid = record.grid.isEmpty ? (record.coordinate.map { Geo.grid(for: $0) } ?? "") : record.grid }
                    if country.isEmpty { country = record.country }
                }
                error = nil
            case .notFound:
                error = L("Znaku nie ma w QRZ.")
            case .failed(let message):
                error = L("QRZ: {1}", message)
            }
        }
    }

    private func save() {
        let callsign = call.trimmingCharacters(in: .whitespaces)
        guard callsign.count >= 3, callsign.range(of: "^[A-Z0-9/]+$", options: .regularExpression) != nil else {
            error = L("Nieprawidłowy znak")
            return
        }
        var freqHz = 0
        let freqText = frequency.trimmingCharacters(in: .whitespaces)
        if !freqText.isEmpty {
            guard let hz = LogFrequency.parseMHz(freqText) else {             // zawsze MHz, wszystkie pasma
                error = L("Nieprawidłowa częstotliwość")
                return
            }
            freqHz = hz
        }
        let gridText = grid.trimmingCharacters(in: .whitespaces).uppercased()
        guard gridText.isEmpty || Geo.isValidGrid(gridText) else {
            error = L("Nieprawidłowy lokator (np. KO02 albo KO02ME)")
            return
        }

        var qso = original
        qso.call = callsign
        qso.start = start
        qso.end = hasEnd ? max(end, start) : nil
        qso.freqHz = freqHz
        qso.band = band.trimmingCharacters(in: .whitespaces).lowercased()
        if let preset = LogModePreset.all.first(where: { $0.label == modeLabel }) {
            qso.mode = preset.mode
            qso.submode = preset.submode
        }                                                   // tryb spoza listy - bez zmian
        qso.rstSent = rstSent.trimmingCharacters(in: .whitespaces)
        qso.rstRcvd = rstRcvd.trimmingCharacters(in: .whitespaces)
        qso.name = name.trimmingCharacters(in: .whitespaces)
        qso.qth = qth.trimmingCharacters(in: .whitespaces)
        qso.grid = gridText
        qso.comment = comment.trimmingCharacters(in: .whitespaces)
        let countryText = country.trimmingCharacters(in: .whitespaces)
        if countryText.isEmpty { qso.extra.removeValue(forKey: "COUNTRY") } else { qso.extra["COUNTRY"] = countryText }
        for (field, value) in refs {
            let text = value.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { qso.extra.removeValue(forKey: field) } else { qso.extra[field] = text }
        }

        // Odległość od nowa: lokator mógł się zmienić.
        qso.extra.removeValue(forKey: "DISTANCE")
        let home = qso.myGrid.isEmpty ? fallbackMyGrid : qso.myGrid
        if let a = Geo.coordinate(fromGrid: home), let b = Geo.coordinate(fromGrid: qso.grid) {
            qso.extra["DISTANCE"] = String(Int(Geo.distanceKm(a, b).rounded()))
        }

        onSave(qso)
        dismiss()
    }
}
