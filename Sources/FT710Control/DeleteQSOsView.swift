import SwiftUI

/// Łączności do usunięcia (okno potwierdzenia).
struct QSODeletion: Identifiable {
    let id = UUID()
    let qsos: [QSO]
}

/// Potwierdzenie usunięcia łączności z dziennika - z opcją usunięcia ich także w serwisach, do których były
/// wysłane (Club Log, QRZ Logbook). LoTW z zasady nie usuwa łączności; eQSL i pozostałe - ręcznie na stronie.
struct DeleteQSOsView: View {
    let qsos: [QSO]
    @ObservedObject var uploader: LogUploader
    /// Wywoływane po potwierdzeniu z serwisami, w których usunąć łączności.
    let onConfirm: (Set<LogService>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remote: Set<LogService> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Usunąć {1} QSO z dziennika?", qsos.count)).font(.headline)
            Text(callList).font(.callout.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let deletable = LogUploader.remoteDeletable.filter { sentCount($0) > 0 }
            if !deletable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Usuń także w serwisach:")).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(deletable) { service in
                        let count = sentCount(service)
                        let overLimit = service == .clublog && count > LogUploader.clubLogDeleteLimit
                        let configured = uploader.config(service).isConfigured
                        Toggle(L("{1} (wysłane: {2})", service.name, count), isOn: Binding(
                            get: { remote.contains(service) },
                            set: { on in if on { remote.insert(service) } else { remote.remove(service) } }))
                            .toggleStyle(.checkbox)
                            .disabled(overLimit || !configured)
                        if overLimit {
                            Text(L("Club Log pozwala usuwać najwyżej {1} łączności naraz - usuń je w Club Log ręcznie (Log Inspector) albo wyślij dziennik ponownie z opcją „clear”.",
                                   LogUploader.clubLogDeleteLimit))
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if !configured {
                            Text(L("Serwis nie jest skonfigurowany w „Usługach online”."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let manual = LogService.allCases.filter { !LogUploader.remoteDeletable.contains($0) && sentCount($0) > 0 }
            if !manual.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manual) { service in
                        Text(manualNote(service)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("Anuluj"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onConfirm(remote)
                    dismiss()
                } label: { Text(L("Usuń")) }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // domyślnie zaznaczone serwisy, w których usunięcie jest możliwe
            remote = Set(LogUploader.remoteDeletable.filter { service in
                let count = sentCount(service)
                return count > 0 && uploader.config(service).isConfigured
                    && !(service == .clublog && count > LogUploader.clubLogDeleteLimit)
            })
        }
    }

    private func sentCount(_ service: LogService) -> Int { qsos.filter { service.isSent($0) }.count }

    private var callList: String {
        let calls = qsos.prefix(8).map(\.call).joined(separator: ", ")
        return qsos.count > 8 ? calls + " " + L("i {1} innych", qsos.count - 8) : calls
    }

    private func manualNote(_ service: LogService) -> String {
        let count = sentCount(service)
        switch service {
        case .lotw: return L("LoTW (wysłane: {1}): LoTW nie pozwala usuwać wysłanych łączności.", count)
        case .eqsl: return L("eQSL (wysłane: {1}): usuń ręcznie na eqsl.cc (Outbox).", count)
        default: return L("{1} (wysłane: {2}): usuń ręcznie na stronie serwisu.", service.name, count)
        }
    }
}
