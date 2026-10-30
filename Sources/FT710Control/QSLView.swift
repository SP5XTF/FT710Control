import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Okno „Potwierdzenia QSL”: pobieranie z LoTW, eQSL i QRZ Logbook, import z pliku ADIF (np. HRDLog),
/// wybór źródeł liczonych do statystyk i lista potwierdzeń bez dopasowania w dzienniku.
struct QSLDownloadView: View {
    @ObservedObject var downloader: QSLDownloader
    @ObservedObject var store: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qsl.countEQSL") private var countEQSL = false
    @AppStorage("qsl.countQRZ") private var countQRZ = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Potwierdzenia QSL")).font(.title2.bold())
            Text(L("Pobierane są tylko potwierdzenia nowe od ostatniego razu; „Od początku” pobiera wszystkie (pierwszy raz albo po zmianach w dzienniku). Potwierdzenia trafiają do pól ADIF łączności, więc są też w eksporcie i kopiach dziennika."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L("Pobieraj automatycznie raz dziennie w tle i powiadamiaj o nowych potwierdzeniach"),
                   isOn: $downloader.autoDownload)
                .help(L("Sprawdzenie 2 minuty po starcie programu, potem co godzinę; pobierane są serwisy, z których ostatnie pobranie było ponad dobę temu. Alert: rodzaj „Nowe potwierdzenia QSL” w ustawieniach alertów."))
            ForEach(QSLSource.allCases) { source in sourceRow(source) }

            HStack {
                Button(L("Pobierz wszystkie")) { downloader.downloadAll() }
                    .disabled(downloader.busy != nil)
                Button(L("Importuj potwierdzenia z pliku ADIF…")) { chooseFile() }
                    .disabled(downloader.busy != nil || downloader.importing)
                    .help(L("Np. eksport z HRDLog.net (nie ma interfejsu pobierania), raport LoTW zapisany z przeglądarki albo plik z innego programu"))
                Spacer()
            }
            if !downloader.lastSummary.isEmpty {
                Text(Lr(downloader.lastSummary)).font(.caption).foregroundStyle(.secondary)
            }

            GroupBox(L("Do statystyk DXCC i kolorów „niepotwierdzony”")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("LoTW (zawsze - jedyne z tych źródeł uznawane w dyplomie DXCC ARRL)"), isOn: .constant(true))
                        .disabled(true)
                    Toggle(L("licz też eQSL"), isOn: $countEQSL)
                    Toggle(L("licz też QRZ Logbook"), isOn: $countQRZ)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            unmatchedList

            HStack {
                Text(L("Potwierdzone łączności: {1} z {2}", confirmedCount, store.qsos.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    private var confirmedCount: Int {
        store.qsos.filter { $0.isConfirmed(includeEQSL: countEQSL, includeQRZ: countQRZ) }.count
    }

    private func sourceRow(_ source: QSLSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(source.name).bold().frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let status = downloader.status[source] {
                    Text(Lr(status)).font(.caption)
                        .foregroundStyle(downloader.errors.contains(source) ? Color.orange : Color.secondary)
                } else if !downloader.isConfigured(source) {
                    Text(notConfigured(source)).font(.caption).foregroundStyle(.secondary)
                }
                if let last = downloader.lastDownload(source) {
                    Text(L("ostatnio: {1} UTC", Self.dateFormatter.string(from: last))
                         + (downloader.nextAuto(source).map { " · " + L("następne: {1} UTC", Self.dateFormatter.string(from: $0)) } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloader.busy == source { ProgressView().controlSize(.small) }
            Button(L("Pobierz")) { downloader.download(source, full: false) }
                .disabled(downloader.busy != nil || !downloader.isConfigured(source))
            Button(L("Od początku")) { downloader.download(source, full: true) }
                .disabled(downloader.busy != nil || !downloader.isConfigured(source))
                .help(L("Wszystkie potwierdzenia, nie tylko nowe - dłużej (LoTW przy dużym dzienniku nawet kilka minut)"))
        }
        .controlSize(.small)
    }

    private func notConfigured(_ source: QSLSource) -> String {
        switch source {
        case .lotw: return L("Podaj login i hasło do strony LoTW w „Usługi online…” → LoTW.")
        case .eqsl: return L("Podaj użytkownika i hasło eQSL w „Usługi online…”.")
        case .qrz: return L("Podaj klucz API dziennika QRZ w „Usługi online…” (pobieranie wymaga subskrypcji QRZ).")
        case .clublog: return L("Uzupełnij Club Log w „Usługi online…” (e-mail, znak, hasło aplikacji, klucz API).")
        }
    }

    @ViewBuilder
    private var unmatchedList: some View {
        if !downloader.unmatched.isEmpty {
            Text(L("Potwierdzenia bez łączności w dzienniku ({1})", downloader.unmatched.count)).font(.headline)
            Text(L("Zwykle: QSO zapisane innym programem, inny znak własny albo czas różniący się o ponad 30 minut."))
                .font(.caption).foregroundStyle(.secondary)
            Table(downloader.unmatched) {
                TableColumn(L("Źródło")) { u in Text(u.source.name) }.width(min: 70, ideal: 90)
                TableColumn(L("Znak")) { u in Text(u.call).bold() }.width(min: 80, ideal: 100)
                TableColumn(L("Data / czas UTC")) { u in
                    Text(Self.dateFormatter.string(from: u.start)).monospacedDigit()
                }
                TableColumn(L("Pasmo / tryb")) { u in Text(u.band + " " + u.mode) }
            }
            .frame(minHeight: 120)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "adi") ?? .data, UTType(filenameExtension: "adif") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloader.importFile(url)
    }
}
