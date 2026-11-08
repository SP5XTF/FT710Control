import SwiftUI
import AppKit

/// Zakładka PSK: dekoder PSK31/PSK63, widmo z częstotliwością odbioru (kliknięcie wskazuje stację),
/// nadawanie BPSK z makrami i dziennik - układ jak RTTY.
struct PSKView: View {
    @ObservedObject var psk: PSKManager
    @ObservedObject var audio: AudioManager
    @ObservedObject var cat: CATClient
    let txArmed: Bool
    @State private var editMacros = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            decoderPanel
            Divider()
            ScrollView { tuningPanel.padding(.trailing, 8) }.frame(width: 290)
            Divider()
            ScrollView { transmitPanel.padding(.trailing, 8) }.frame(width: 390)
            Divider()
            ScrollView { ModeLogPanel(presetLabel: psk.modeName, cat: cat).padding(.trailing, 8) }.frame(width: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: txArmed) { armed in
            if !armed, psk.transmitting { psk.stopTX() }            // cofnięcie zgody kończy nadawanie
        }
        .onAppear { audio.setSpectrumNeeded("psk", true) }
        .onDisappear { audio.setSpectrumNeeded("psk", false) }
    }

    // MARK: - Dekoder

    private var decoderPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L("DEKODER")).font(.caption.bold()).foregroundStyle(Theme.header)
                Toggle(L("Włączony"), isOn: $psk.decoderEnabled)
                Toggle("AFC", isOn: $psk.afc)
                    .help(L("Automatyczne dostrajanie do sygnału PSK (zakres kilkudziesięciu Hz od kliknięcia)"))
                Spacer()
                qualityBar
            }
            .controlSize(.small)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(String(psk.text.suffix(2500)))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .id("end")
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: psk.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 8) {
                Button(L("Wyczyść")) { psk.clearText() }
                Button(L("Kopiuj")) { psk.copyText() }
                Spacer()
                if !audio.listening {
                    Text(L("Dekoder potrzebuje dźwięku z radia.")).font(.caption).foregroundStyle(.orange)
                    Button(L("Włącz odsłuch")) { audio.toggleListening() }
                }
            }
            .controlSize(.small)
        }
    }

    /// Jakość sygnału (zgodność fazy) i próg blokady szumu.
    private var qualityBar: some View {
        HStack(spacing: 6) {
            Text(L("Jakość")).font(.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(psk.quality >= psk.squelch ? Theme.ok : Color.orange)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, psk.quality))))
                    Rectangle().fill(Color.white.opacity(0.7))
                        .frame(width: 1.5).offset(x: geo.size.width * CGFloat(psk.squelch))
                }
            }
            .frame(width: 90, height: 8)
            .help(L("Zgodność fazy sygnału PSK; kreska - próg blokady szumu (poniżej tekst nie jest wypisywany)"))
        }
    }

    // MARK: - Strojenie

    private var tuningPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("PASMA PSK")).font(.caption.bold()).foregroundStyle(Theme.header)
                .help(L("Częstotliwość wybierania w DATA-U - aktywność PSK31 w pasie kilku kHz powyżej"))
            ModeBandButtons(plan: .psk, cat: cat, beforeTune: { if psk.transmitting { psk.stopTX() } })
            Text(L("STROJENIE")).font(.caption.bold()).foregroundStyle(Theme.header)
            GeometryReader { geo in
                let maxHz = Double(audio.spectrum.maxHz)
                ZStack(alignment: .topLeading) {
                    ScopeRenderView(frames: audio.spectrum.frames, traceHeight: 60, color: NSColor.systemTeal)
                    marker(psk.carrier, width: geo.size.width, height: geo.size.height, maxHz: maxHz)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    psk.setCarrier(Double(location.x / geo.size.width) * maxHz)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(L("Odbiór {1} Hz", Int(psk.carrier.rounded()))).font(.caption.monospacedDigit())
            Picker(L("Emisja"), selection: $psk.baud) {
                ForEach(PSKManager.speeds, id: \.baud) { Text($0.name).tag($0.baud) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            HStack(spacing: 6) {
                Text(L("Blokada szumu")).font(.caption)
                Slider(value: $psk.squelch, in: 0...0.9)
                Text("\(Int(psk.squelch * 100))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            }
            .help(L("Próg jakości, poniżej którego tekst nie jest wypisywany (sam szum daje do ok. 30%). Niżej - słabsze sygnały, ale więcej przypadkowych znaków."))
            Text(L("Kliknij w widmo na sygnał stacji; AFC dostroi się dokładnie. Nadajesz na tej samej częstotliwości."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func marker(_ hz: Double, width: CGFloat, height: CGFloat, maxHz: Double) -> some View {
        let x = width * CGFloat(hz / max(maxHz, 1))
        return Rectangle().fill(Theme.tx).frame(width: 2, height: height).position(x: x, y: height / 2)
    }

    // MARK: - Nadawanie

    private var transmitPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("NADAWANIE ({1})", psk.modeName)).font(.caption.bold()).foregroundStyle(Theme.header)
                Spacer()
                Text(L("Poziom")).font(.caption)
                Slider(value: $psk.txLevel, in: 0.1...1).frame(width: 110)
                Text("\(Int(psk.txLevel * 100))%").font(.caption.monospacedDigit())
            }
            HStack(spacing: 4) {
                ForEach(psk.macros.indices, id: \.self) { index in
                    Button(macroLabel(psk.macros[index])) { psk.transmit(psk.macros[index], armed: txArmed) }
                        .help(psk.expand(psk.macros[index]))
                        .disabled(!txArmed || psk.transmitting)
                }
                Button { editMacros.toggle() } label: { Image(systemName: "pencil") }
                    .help(L("Edytuj makra ({CALL} = Twój znak)"))
            }
            .controlSize(.small)
            if editMacros {
                ForEach(psk.macros.indices, id: \.self) { index in
                    TextField("", text: $psk.macros[index]).controlSize(.small)
                }
            }
            HStack {
                TextField(L("Tekst do nadania"), text: $psk.outgoing)
                    .onSubmit { send() }
                if psk.transmitting {
                    Button(role: .destructive) { psk.stopTX() } label: { Text("STOP").bold() }
                } else {
                    Button(L("Nadaj")) { send() }.disabled(!txArmed || psk.outgoing.isEmpty)
                }
            }
            if psk.transmitting { ProgressView(value: psk.txProgress) }
            if let message = psk.txMessage.map(Lr) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Ustaw radio: DATA-U")) { psk.setRadioDataU() }
                    .disabled(!cat.isConnected)
                Text(L("tryb radia: {1}", cat.modeName)).font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Text(L("Radio w DATA-U, dźwięk przez USB (urządzenie „Do radia” w zakładce AUDIO). PSK wymaga czystego sygnału: poziom tak, żeby ALC się nie ruszało, i umiarkowana moc - przesterowanie poszerza sygnał."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macroLabel(_ template: String) -> String {
        let text = psk.expand(template).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 10 ? String(text.prefix(9)) + "…" : text
    }

    private func send() {
        guard !psk.outgoing.isEmpty, txArmed else { return }
        psk.transmit(psk.outgoing + " ", armed: txArmed)
        psk.outgoing = ""
    }
}
