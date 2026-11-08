import SwiftUI

/// Pamięć komunikatów radia (MESSAGE MEMORY): 5 kanałów fonii i 5 kanałów CW nagranych w radiu.
/// Odtworzenie zaklucza nadajnik, dlatego przyciski działają tylko przy odblokowanym nadawaniu;
/// STOP jest zawsze dostępny i kończy nadawanie (PB00 + TX0).
struct MessagePanel: View {
    @ObservedObject var cat: CATClient
    let txArmed: Bool
    /// Sam rząd przycisków 1–5 i STOP (do bloku TX w prawej kolumnie), bez ramki i opisu.
    var compact = false

    // Opisy przycisków (osobno dla fonii i CW), rozdzielone znakiem „|”.
    @AppStorage("messageLabelsVoice") private var voiceLabels = L("CQ|Znak|Raport|QRZ?|73")
    @AppStorage("messageLabelsCW") private var cwLabels = L("CQ|Znak|5NN|TU|73")

    @State private var editing: Int?
    @State private var draft = ""

    private enum Kind { case voice, cw, unavailable }

    private var kind: Kind {
        switch cat.modeCode {
        case "1", "2", "4", "5", "B", "D": return .voice     // LSB, USB, FM, AM, FM-N, AM-N
        case "3", "7": return .cw                            // CW-U, CW-L
        default: return .unavailable                         // DATA, RTTY
        }
    }

    var body: some View {
        content
        .alert(L("Opis komunikatu {1}", editing ?? 0), isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } })) {
            TextField(L("Opis"), text: $draft)
            Button(L("Zapisz")) { saveLabel() }
            Button(L("Anuluj"), role: .cancel) { editing = nil }
        } message: {
            Text(L("Krótki opis widoczny na przycisku (np. CQ, 73). Treść komunikatu nagrywa się w radiu."))
        }
    }

    @ViewBuilder
    private var content: some View {
        if compact {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { channel in
                    messageButton(channel)
                }
                Button("STOP") { cat.stopMessage() }
                    .buttonStyle(RigButtonStyle(tint: Theme.tx, height: 26, fontSize: 10))
                    .frame(width: 40)
                    .disabled(!cat.isConnected)
                    .help(L("Zatrzymaj komunikat i zakończ nadawanie"))
            }
            .help(hint)
        } else {
            RigPanel(title: L("Komunikaty"), trailing: kindText) {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { channel in
                        messageButton(channel)
                    }
                }
                Button("STOP") { cat.stopMessage() }
                    .buttonStyle(RigButtonStyle(tint: Theme.tx, height: 22))
                    .help(L("Przerywa odtwarzanie komunikatu z pamięci radia"))
                    .disabled(!cat.isConnected)
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var kindText: String {
        switch kind {
        case .voice: return L("fonia")
        case .cw: return "CW"
        case .unavailable: return "—"
        }
    }

    private var hint: String {
        if kind == .unavailable { return L("Dostępne w SSB, AM, FM (fonia) i CW.") }
        if !txArmed { return L("Zaznacz „Odblokuj nadawanie”, aby odtwarzać. Prawy przycisk: opis.") }
        return L("Kliknięcie nadaje komunikat z pamięci radia. Prawy przycisk: opis.")
    }

    private var labels: [String] {
        let source = kind == .cw ? cwLabels : voiceLabels
        var parts = source.components(separatedBy: "|")
        while parts.count < 5 { parts.append("") }
        return Array(parts.prefix(5))
    }

    private func messageButton(_ channel: Int) -> some View {
        Button {
            cat.playMessage(channel, cw: kind == .cw)
        } label: {
            if compact {
                // Jedna linia: własny opis (np. CQ) albo numer kanału.
                Text(labels[channel - 1].isEmpty ? "\(channel)" : labels[channel - 1])
            } else {
                VStack(spacing: 1) {
                    Text("\(channel)").font(.system(size: 13, weight: .semibold))
                    Text(labels[channel - 1].isEmpty ? " " : labels[channel - 1])
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text.opacity(0.8))
                }
                .padding(.vertical, 2)
            }
        }
        .buttonStyle(RigButtonStyle(height: compact ? 26 : 30, fontSize: compact ? 10 : 12))
        .disabled(!(txArmed && cat.isConnected && kind != .unavailable))
        .contextMenu {
            Button(L("Zmień opis…")) {
                draft = labels[channel - 1]
                editing = channel
            }
            .disabled(kind == .unavailable)
        }
    }

    private func saveLabel() {
        guard let channel = editing else { return }
        var parts = labels
        parts[channel - 1] = draft
            .replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespaces)
        let joined = parts.joined(separator: "|")
        if kind == .cw { cwLabels = joined } else { voiceLabels = joined }
        editing = nil
    }
}
