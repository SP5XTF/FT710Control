import SwiftUI
import AppKit

/// Zakładka RTTY: dekoder, widmo z tonami mark/space (kliknięcie wskazuje stację), nadawanie AFSK z makrami.
struct RTTYView: View {
    @ObservedObject var rtty: RTTYManager
    @ObservedObject var audio: AudioManager
    @ObservedObject var cat: CATClient
    let txArmed: Bool
    @State private var editMacros = false

    var body: some View {
        // panele boczne przewijane, gdy nie mieszczą się w pionie; zakładka nie wychodzi pod pasek stanu okna
        HStack(alignment: .top, spacing: 14) {
            decoderPanel
            Divider()
            ScrollView { tuningPanel.padding(.trailing, 8) }.frame(width: 290)
            Divider()
            ScrollView { transmitPanel.padding(.trailing, 8) }.frame(width: 390)
            Divider()
            ScrollView { ModeLogPanel(presetLabel: "RTTY", cat: cat).padding(.trailing, 8) }.frame(width: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: txArmed) { armed in
            if !armed, rtty.transmitting { rtty.stopTX() }          // cofnięcie zgody kończy nadawanie
        }
        .onAppear { audio.setSpectrumNeeded("rtty", true) }
        .onDisappear { audio.setSpectrumNeeded("rtty", false) }
    }

    // MARK: - Dekoder

    private var decoderPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L("DEKODER")).font(.caption.bold()).foregroundStyle(Theme.header)
                Toggle(L("Włączony"), isOn: $rtty.decoderEnabled)
                Toggle("AFC", isOn: $rtty.afc)
                    .help(L("Automatyczne dostrajanie do pary tonów RTTY"))
                Toggle("USOS", isOn: $rtty.usos)
                    .help(L("Po spacji powrót do liter (standard w krótkofalarskim RTTY)"))
                Spacer()
                Text(rtty.locked ? L("RTTY ✓") : L("brak sygnału RTTY"))
                    .font(.caption.bold())
                    .foregroundStyle(rtty.locked ? Theme.ok : Color.secondary)
            }
            .controlSize(.small)
            ScrollViewReader { proxy in
                ScrollView {
                    // na ekranie ostatnie 2500 znaków (kilka ekranów) - układanie całych 8000 znaków przy każdym
                    // nowym znaku trwało ok. 12 ms (pomiar Instruments); pełny tekst zostaje dla „Kopiuj”
                    Text(String(rtty.text.suffix(2500)))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.text)
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
                .onChange(of: rtty.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 8) {
                Button(L("Wyczyść")) { rtty.clearText() }
                Button(L("Kopiuj")) { rtty.copyText() }
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
            Text(L("PASMA RTTY")).font(.caption.bold()).foregroundStyle(Theme.header)
                .help(L("Radio o 2,125 kHz powyżej aktywności RTTY, w DATA-L - sygnały wypadają na tonie mark 2125 Hz"))
            ModeBandButtons(plan: .rtty, cat: cat, beforeTune: { if rtty.transmitting { rtty.stopTX() } })
            Text(L("STROJENIE")).font(.caption.bold()).foregroundStyle(Theme.header)
            GeometryReader { geo in
                let maxHz = Double(audio.spectrum.maxHz)
                ZStack(alignment: .topLeading) {
                    ScopeRenderView(frames: audio.spectrum.frames, traceHeight: 60, color: NSColor.systemTeal)
                    marker(rtty.markHz, label: "M", width: geo.size.width, height: geo.size.height, maxHz: maxHz)
                    marker(rtty.spaceHz, label: "S", width: geo.size.width, height: geo.size.height, maxHz: maxHz)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    rtty.setMark(Double(location.x / geo.size.width) * maxHz)   // wskazany ton = mark
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(L("Mark {1} Hz · Space {2} Hz", Int(rtty.markHz.rounded()), Int(rtty.spaceHz.rounded())))
                .font(.caption.monospacedDigit())
            HStack {
                Picker(L("Przesuw"), selection: $rtty.shift) {
                    ForEach(RTTYManager.shifts, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                }
                Picker(L("Prędkość"), selection: $rtty.baud) {
                    ForEach(RTTYManager.bauds, id: \.self) { Text(String(format: "%g Bd", $0)).tag($0) }
                }
            }
            .controlSize(.small)
            HStack {
                Toggle(L("Odwrócenie wg trybu radia"), isOn: $rtty.autoReverse)
                if !rtty.autoReverse { Toggle("REV", isOn: $rtty.reverse) }
            }
            .controlSize(.small)
            .help(L("W DATA-L / RTTY-L mark to niższy ton, w DATA-U / USB - wyższy (w obu przypadkach mark jest wyżej w częstotliwości radiowej)"))
            Text(L("Kliknij w widmo na ton mark stacji; z włączonym AFC dekoder sam znajduje parę tonów."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func marker(_ hz: Double, label: String, width: CGFloat, height: CGFloat, maxHz: Double) -> some View {
        let x = width * CGFloat(hz / max(maxHz, 1))
        return ZStack(alignment: .top) {
            Rectangle().fill(label == "M" ? Theme.accent : Color.orange).frame(width: 2, height: height)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 3)
                .background(label == "M" ? Theme.accent : Color.orange, in: RoundedRectangle(cornerRadius: 2))
        }
        .position(x: x, y: height / 2)
    }

    // MARK: - Nadawanie

    private var transmitPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("NADAWANIE (AFSK)")).font(.caption.bold()).foregroundStyle(Theme.header)
                Spacer()
                Text(L("Poziom")).font(.caption)
                Slider(value: $rtty.txLevel, in: 0.1...1).frame(width: 110)
                Text("\(Int(rtty.txLevel * 100))%").font(.caption.monospacedDigit())
            }
            HStack(spacing: 4) {
                ForEach(rtty.macros.indices, id: \.self) { index in
                    Button(macroLabel(rtty.macros[index])) { rtty.transmit(rtty.macros[index], armed: txArmed) }
                        .help(rtty.expand(rtty.macros[index]))
                        .disabled(!txArmed || rtty.transmitting)
                }
                Button { editMacros.toggle() } label: { Image(systemName: "pencil") }
                    .help(L("Edytuj makra ({CALL} = Twój znak)"))
            }
            .controlSize(.small)
            if editMacros {
                ForEach(rtty.macros.indices, id: \.self) { index in
                    TextField("", text: $rtty.macros[index]).controlSize(.small)
                }
            }
            HStack {
                TextField(L("Tekst do nadania"), text: $rtty.outgoing)
                    .onSubmit { send() }
                if rtty.transmitting {
                    Button(role: .destructive) { rtty.stopTX() } label: { Text("STOP").bold() }
                } else {
                    Button(L("Nadaj")) { send() }.disabled(!txArmed || rtty.outgoing.isEmpty)
                }
            }
            if rtty.transmitting { ProgressView(value: rtty.txProgress) }
            if let message = rtty.txMessage.map(Lr) {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Ustaw radio: DATA-L")) { rtty.setRadioDataL() }
                    .disabled(!cat.isConnected)
                Text(L("tryb radia: {1}", cat.modeName)).font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Text(L("Nadawanie AFSK: radio w DATA-L, dźwięk przez USB (urządzenie „Do radia” w zakładce AUDIO). Poziom ustaw tak, żeby ALC ledwie się ruszało; RTTY to ciągła nośna - zmniejsz moc."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macroLabel(_ template: String) -> String {
        let text = rtty.expand(template)
        return text.count > 10 ? String(text.prefix(9)) + "…" : text
    }

    private func send() {
        guard !rtty.outgoing.isEmpty, txArmed else { return }
        rtty.transmit(rtty.outgoing, armed: txArmed)
        rtty.outgoing = ""
    }
}
