import SwiftUI
import AppKit

/// Zakładka CW: dekoder (z modelem językowym), widmo do wskazania tonu, nadawanie z makrami.
struct CWView: View {
    @ObservedObject var cw: CWManager
    @ObservedObject var audio: AudioManager
    @ObservedObject var cat: CATClient
    let txArmed: Bool
    @State private var editMacros = false

    var body: some View {
        // panele boczne przewijane, gdy nie mieszczą się w pionie; zakładka nie wychodzi pod pasek stanu okna
        HStack(alignment: .top, spacing: 14) {
            decoderPanel
            Divider()
            ScrollView { tuningPanel.padding(.trailing, 8) }.frame(width: 270)
            Divider()
            ScrollView { transmitPanel.padding(.trailing, 8) }.frame(width: 390)
            Divider()
            ScrollView { ModeLogPanel(presetLabel: "CW", cat: cat).padding(.trailing, 8) }.frame(width: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: txArmed) { armed in
            if !armed { cw.shutdownTX() }                         // cofnięcie zgody zawsze zwalnia klucz
        }
        .onAppear { audio.setSpectrumNeeded("cw", true) }       // widmo tonu tylko przy otwartej zakładce
        .onDisappear { audio.setSpectrumNeeded("cw", false) }
    }

    // MARK: - Dekoder

    private var decoderPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L("DEKODER")).font(.caption.bold()).foregroundStyle(Theme.header)
                Toggle(L("Włączony"), isOn: $cw.decoderEnabled)
                Toggle(L("AI – model językowy"), isOn: $cw.useModel)
                    .help(L("Niejednoznaczne znaki rozstrzyga model typowego języka QSO (z Twoimi znakami z dziennika). Najwięcej pomaga przy nierównej ręce."))
                Spacer()
                Text(cw.locked ? L("{1} WPM", Int(cw.wpm.rounded())) : "– WPM")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(Theme.accent)
            }
            .controlSize(.small)
            ScrollViewReader { proxy in
                ScrollView {
                    // na ekranie ostatnie 2500 znaków - krócej układany tekst; pełny tekst zostaje dla „Kopiuj”
                    (Text(String(cw.text.suffix(2500))).foregroundColor(Theme.text) + Text(cw.provisional).foregroundColor(Theme.header))
                        .font(.system(size: 15, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("end")
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                .onAppear {                                            // po powrocie na zakładkę - od razu na koniec
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: cw.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 8) {
                Button(L("Wyczyść")) { cw.clearText() }
                Button(L("Kopiuj")) { cw.copyText() }
                Spacer()
                if !audio.listening {
                    Text(L("Dekoder potrzebuje dźwięku z radia.")).font(.caption).foregroundStyle(.orange)
                    Button(L("Włącz odsłuch")) { audio.toggleListening() }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Strojenie

    private var tuningPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("PASMA CW")).font(.caption.bold()).foregroundStyle(Theme.header)
            ModeBandButtons(plan: .cw, cat: cat, beforeTune: { if cw.sending { cw.stop() } })
            Text(L("TON")).font(.caption.bold()).foregroundStyle(Theme.header)
            GeometryReader { geo in
                let maxHz = Double(audio.spectrum.maxHz)
                ZStack(alignment: .topLeading) {
                    ScopeRenderView(frames: audio.spectrum.frames, traceHeight: 60, color: NSColor.systemTeal)
                    let x = geo.size.width * CGFloat(cw.pitch / maxHz)
                    if audio.apfEnabled {                            // pasmo APF w słuchawkach
                        Rectangle()
                            .fill(Theme.accent.opacity(0.18))
                            .frame(width: max(3, geo.size.width * CGFloat(audio.apfBandwidth / maxHz)), height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                    }
                    Rectangle()
                        .fill(cw.manualPitch == nil ? Theme.accent : Color.orange)
                        .frame(width: 2, height: geo.size.height)
                        .position(x: x, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    cw.setPitch(Double(location.x / geo.size.width) * maxHz)    // ręczne wskazanie tonu
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text(L("Ton: {1} Hz", Int(cw.pitch.rounded()))).font(.caption.monospacedDigit())
                Text(cw.manualPitch == nil ? L("(auto)") : L("(ręcznie)"))
                    .font(.caption)
                    .foregroundStyle(cw.manualPitch == nil ? Color.secondary : Color.orange)
                Spacer()
                Button(L("Auto")) { cw.setPitch(nil) }
                    .controlSize(.small)
                    .help(L("Ton dekodera wykrywany automatycznie (zamiast ustawionego ręcznie)"))
                    .disabled(cw.manualPitch == nil)
            }
            snrBar
            HStack(spacing: 8) {
                Toggle(L("APF (słuchawki)"), isOn: $audio.apfEnabled)
                Picker("", selection: $audio.apfBandwidth) {
                    Text("50").tag(50.0)
                    Text("100").tag(100.0)
                    Text("200 Hz").tag(200.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!audio.apfEnabled)
            }
            .controlSize(.small)
            Toggle(L("APF dla dekodera (100 Hz)"), isOn: $cw.decoderAPF)
                .controlSize(.small)
                .help(L("Wąski filtr tylko na torze odczytu znaków - pomaga przy bardzo słabych sygnałach; wyszukiwanie stacji dalej widzi całe pasmo"))
            Text(L("Kliknij w widmo, żeby wskazać stację; „Auto” - dekoder sam znajduje najsilniejszy ton CW."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var snrBar: some View {
        HStack(spacing: 6) {
            Text("SNR").font(.caption)
            ProgressView(value: min(max(cw.snrDB / 30, 0), 1))
                .tint(cw.snrDB > 12 ? Theme.ok : (cw.snrDB > 8 ? Color.orange : Color.red))
            Text("\(Int(cw.snrDB.rounded())) dB").font(.caption.monospacedDigit())
        }
    }

    // MARK: - Nadawanie

    private var transmitPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("NADAWANIE")).font(.caption.bold()).foregroundStyle(Theme.header)
                Spacer()
                Text(L("{1} WPM", Int(cw.txWPM.rounded()))).font(.caption.monospacedDigit())
                Slider(value: $cw.txWPM, in: 5...40, step: 1).frame(width: 120)
            }
            HStack(spacing: 4) {
                ForEach(cw.macros.indices, id: \.self) { index in
                    Button(macroLabel(cw.macros[index])) { cw.send(cw.macros[index], armed: txArmed) }
                        .help(cw.expand(cw.macros[index]))
                        .disabled(!txArmed || cw.sending)
                }
                Button { editMacros.toggle() } label: { Image(systemName: "pencil") }
                    .help(L("Edytuj makra ({CALL} = Twój znak)"))
            }
            .controlSize(.small)
            if editMacros {
                ForEach(cw.macros.indices, id: \.self) { index in
                    TextField("", text: $cw.macros[index]).controlSize(.small)
                }
            }
            HStack {
                TextField(L("Tekst do nadania"), text: $cw.outgoing)
                    .onSubmit { sendOutgoing() }
                if cw.sending {
                    Button(role: .destructive) { cw.stop() } label: { Text("STOP").bold() }
                } else {
                    Button(L("Nadaj")) { sendOutgoing() }
                        .disabled(!txArmed || cw.outgoing.isEmpty)
                }
            }
            if cw.sending {
                ProgressView(value: cw.sendProgress)
                Text(cw.sendingText).font(.caption.monospaced()).lineLimit(1)
            }
            Picker(L("Nadawanie przez"), selection: $cw.method) {
                ForEach(CWManager.TXMethod.allCases) { Text($0.name).tag($0) }
            }
            .controlSize(.small)
            if cw.method == .line {
                HStack {
                    Picker(L("Port klucza"), selection: $cw.keyPort) {
                        Text(L("— wybierz —")).tag("")
                        ForEach(cat.ports, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("", selection: $cw.keyLine) {
                        ForEach(CWKeyer.Line.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
                .controlSize(.small)
            }
            if let message = cw.txMessage.map(Lr) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            radioCheckPanel
            Text(cw.method == .line
                 ? L("Linia: dokładne tempo z komputera. W radiu: tryb CW, BK-IN, PC KEYING = DTR/RTS (jak wyżej). Port klucza to drugi port radia (Standard COM / CAT-2).")
                 : L("Klucz radia: tekst trafia do pamięci 5 klucza FT-710 (po 50 znaków) i jest odtwarzany przez radio; zawartość pamięci 5 i prędkość klucza są potem przywracane. Nie wymaga drugiego portu ani PC KEYING."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sprawdzenie ustawień radia przez CAT (PC KEYING, BK-IN, tryb) i ich poprawienie jednym kliknięciem.
    private var radioCheckPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button(L("Sprawdź radio")) { cw.checkRadio() }
                    .disabled(!cat.isConnected || cw.checkingRadio)
                if cw.radioCheck.contains(where: { !$0.ok }) {
                    Button(L("Popraw ustawienia")) { cw.fixRadio() }
                        .help(L("Ustawia w radiu PC KEYING zgodnie z wybraną linią, włącza BK-IN i tryb CW"))
                }
                if cw.checkingRadio { ProgressView().controlSize(.mini) }
            }
            ForEach(cw.radioCheck) { item in
                HStack(spacing: 6) {
                    switch item.status {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    case .info: Image(systemName: "info.circle").foregroundStyle(Color.secondary)
                    }
                    Text(item.name).font(.caption.bold())
                    Text(item.value).font(.caption.monospaced())
                }
            }
        }
        .controlSize(.small)
    }

    private func macroLabel(_ template: String) -> String {
        let text = cw.expand(template)
        return text.count > 10 ? String(text.prefix(9)) + "…" : text
    }

    private func sendOutgoing() {
        guard !cw.outgoing.isEmpty, txArmed else { return }
        cw.send(cw.outgoing, armed: txArmed)
        cw.outgoing = ""
    }
}
