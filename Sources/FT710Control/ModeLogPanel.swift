import SwiftUI

/// Dziennik w zakładkach SSTV, CW i RTTY: znak (QRZ/HamQTH), raport (RSV/RST), imię, QTH, lokator, uwagi.
/// Zapis tą samą funkcją co formularz dziennika (kraj, strefy, odległość, wysyłka do serwisów) w trybie zakładki.
struct ModeLogPanel: View {
    /// Tryb z listy trybów dziennika: „SSTV”, „CW”, „RTTY”.
    let presetLabel: String
    @ObservedObject var cat: CATClient
    /// Uwagi wpisywane automatycznie (SSTV: tryb odebranego obrazka); nil - bez.
    var autoComment: String? = nil
    @EnvironmentObject private var logbook: LogbookStore
    @EnvironmentObject private var qrz: QRZClient
    @StateObject private var lookup = CallLookup()
    @State private var call = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var name = ""
    @State private var qth = ""
    @State private var grid = ""
    @State private var comment = ""
    @State private var startedAt: Date?
    @State private var message: String?
    @State private var lastAutoComment = ""

    private var preset: LogModePreset {
        LogModePreset.all.first { $0.label == presetLabel } ?? LogModePreset.forRadio(cat.modeCode)
    }
    /// SSTV: RSV (czytelność, siła, jakość obrazu); pozostałe: RST.
    private var reportName: String { presetLabel == "SSTV" ? "RSV" : "RST" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("DZIENNIK")).font(.caption.bold()).foregroundStyle(Theme.header)
            TextField(L("Znak"), text: Binding(get: { call }, set: { callChanged($0) }))
                .font(.system(.title3, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            lookupLine
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("{1} wysłany", reportName)).font(.caption2).foregroundStyle(.secondary)
                    TextField(preset.defaultRST, text: $rstSent).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("{1} odebrany", reportName)).font(.caption2).foregroundStyle(.secondary)
                    TextField(preset.defaultRST, text: $rstRcvd).textFieldStyle(.roundedBorder)
                }
            }
            TextField(L("Imię"), text: $name).textFieldStyle(.roundedBorder)
            TextField("QTH", text: $qth).textFieldStyle(.roundedBorder)
            TextField(L("Lokator"), text: $grid).textFieldStyle(.roundedBorder)
            TextField(L("Uwagi"), text: $comment).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("Zapisz QSO")) { save() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(QRZClient.baseCall(call).count < 3 || cat.activeFreq <= 0)
                Button(L("Wyczyść")) { clear() }
            }
            Text(cat.activeFreq > 0 ? L("{1} · tryb {2}", formatFrequency(cat.activeFreq), presetLabel)
                                    : L("Brak częstotliwości z radia - połącz CAT"))
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true)
            }
            if presetLabel == "SSTV" {
                Text(L("RSV: czytelność (1-5), siła (1-9), jakość obrazu (1-5). Tryb odebranego obrazka trafia do uwag."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Puste pola raportu - domyślnie {1}.", preset.defaultRST))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: lookup.record) { record in
            guard let record, record.call == QRZClient.baseCall(call) else { return }
            let away = OperatingLocation.isAwayFromHome(call)
            if name.isEmpty { name = record.firstName.isEmpty ? record.displayName : record.firstName }
            if !away, qth.isEmpty { qth = record.city }
            if !away, grid.isEmpty { grid = record.grid.uppercased() }
        }
        .onChange(of: autoComment) { text in
            // np. tryb odebranego obrazka SSTV - do uwag, jeśli są puste albo zawierają poprzednią automatyczną treść
            guard let text, comment.isEmpty || comment == lastAutoComment else { return }
            comment = text
            lastAutoComment = text
        }
    }

    @ViewBuilder
    private var lookupLine: some View {
        let base = QRZClient.baseCall(call)
        if base.count >= 3 {
            let before = logbook.qsos.filter { QRZClient.baseCall($0.call) == base }
            let country = CTYDatabase.shared.table?.lookup(call)
                .map { CTYDatabase.shared.table?.dxccName(CTYTable.dxccKey($0)) ?? $0.entity.name } ?? ""
            let worked = before.isEmpty ? L("nowa stacja") : L("było: {1} QSO", before.count)
            Text([country, worked].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(before.isEmpty ? Theme.ok : .secondary)
        }
    }

    private func callChanged(_ value: String) {
        let cleaned = value.uppercased().filter { !$0.isWhitespace }
        call = cleaned
        message = nil
        if startedAt == nil, !cleaned.isEmpty { startedAt = Date() }
        if cleaned.isEmpty { startedAt = nil }
        if QRZClient.baseCall(cleaned).count >= 3, qrz.canLookup { lookup.request(cleaned, using: qrz, debounce: true) }
    }

    private func save() {
        let callsign = call.trimmingCharacters(in: .whitespaces).uppercased()
        guard QRZClient.baseCall(callsign).count >= 3, cat.activeFreq > 0 else { return }
        let now = Date()
        let report = preset.defaultRST
        let qso = logbook.makeQSO(call: callsign, start: startedAt ?? now, end: now, freqHz: cat.activeFreq,
                                  preset: preset, rstSent: rstSent.isEmpty ? report : rstSent,
                                  rstRcvd: rstRcvd.isEmpty ? report : rstRcvd, name: name, qth: qth,
                                  grid: grid, comment: comment, record: lookup.record)
        logbook.add(qso)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        let saved = L("Zapisano {1} ({2} UTC)", callsign, f.string(from: now))
        clear()
        message = saved
    }

    private func clear() {
        call = ""
        name = ""
        qth = ""
        grid = ""
        comment = autoComment ?? ""
        lastAutoComment = comment
        rstSent = ""
        rstRcvd = ""
        startedAt = nil
        message = nil
        lookup.clear()
    }
}
