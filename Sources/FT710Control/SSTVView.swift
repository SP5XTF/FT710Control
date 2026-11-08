import SwiftUI
import AppKit

/// Zakładka SSTV: odbiór (obraz na żywo), strojenie (widmo audio ze znacznikami tonów SSTV), nadawanie.
struct SSTVView: View {
    @ObservedObject var sstv: SSTVManager
    @ObservedObject var audio: AudioManager
    @ObservedObject var cat: CATClient
    let txArmed: Bool

    var body: some View {
        // panele boczne przewijane, gdy nie mieszczą się w pionie; zakładka nie wychodzi pod pasek stanu okna
        HStack(alignment: .top, spacing: 14) {
            receivePanel.frame(width: 400)
            Divider()
            ScrollView { tuningPanel.padding(.trailing, 8) }.frame(width: 310)
            Divider()
            ScrollView { transmitPanel.padding(.trailing, 8) }
            Divider()
            ScrollView { ModeLogPanel(presetLabel: "SSTV", cat: cat, autoComment: sstv.rxMode.map { "SSTV " + $0.name })
                    .padding(.trailing, 8) }
                .frame(width: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: txArmed) { armed in
            if !armed, sstv.transmitting { sstv.stopTX() }      // cofnięcie zgody zawsze kończy nadawanie
        }
        .onAppear { audio.setSpectrumNeeded("sstv", true) }     // widmo strojenia tylko przy otwartej zakładce
        .onDisappear { audio.setSpectrumNeeded("sstv", false) }
    }

    // MARK: - Odbiór

    private var receivePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("ODBIÓR")).font(.caption.bold()).foregroundStyle(Theme.header)
                Toggle(L("Włączony"), isOn: $sstv.rxEnabled).controlSize(.small)
                Spacer()
                Text(Lr(sstv.rxStatus))
                    .font(.caption)
                    .foregroundStyle(sstv.receiving ? Theme.ok : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black)
                if let image = sstv.rxImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(L("Odebrane obrazy pojawią się tutaj"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 200)
            if sstv.receiving {
                ProgressView(value: sstv.rxProgress)
            }
            HStack(spacing: 6) {
                Button(L("Zapisz")) { sstv.saveCurrent() }
                    .disabled(sstv.rxImage == nil)
                if sstv.receiving {
                    Button(L("Przerwij")) { sstv.stopReception() }
                }
                Menu(L("Galeria ({1})", sstv.gallery.count)) {
                    ForEach(sstv.gallery, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button(L("Otwórz folder")) { sstv.openGalleryFolder() }
                }
                .fixedSize()
                Button(L("Odeślij")) { sstv.useReceivedAsSource() }
                    .disabled(sstv.rxImage == nil)
                    .help(L("Użyj odebranego obrazu jako obrazu do nadania"))
                Toggle(L("Zapisuj automatycznie"), isOn: $sstv.autoSave)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Strojenie

    /// Tony SSTV: synchronizacja, czerń, nagłówek VIS, biel.
    private static let markers: [(hz: Double, label: String)] = [(1200, "SYNC"), (1500, "1500"), (1900, "VIS"), (2300, "2300")]

    private var tuningPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("PASMA SSTV")).font(.caption.bold()).foregroundStyle(Theme.header)
                .help(L("Typowe częstotliwości wywoławcze SSTV; poniżej 10 MHz DATA-L, powyżej DATA-U (jak fonia)"))
            ModeBandButtons(plan: .sstv, cat: cat, beforeTune: { if sstv.transmitting { sstv.stopTX() } })
            Text(L("STROJENIE")).font(.caption.bold()).foregroundStyle(Theme.header)
            if !audio.listening {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Dekoder potrzebuje dźwięku z radia."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("Włącz odsłuch")) { audio.toggleListening() }
                        .controlSize(.small)
                }
            }
            GeometryReader { geo in
                let maxHz = Double(audio.spectrum.maxHz)
                ZStack(alignment: .topLeading) {
                    ScopeRenderView(frames: audio.spectrum.frames, traceHeight: 70, color: NSColor.systemTeal)
                    ForEach(Self.markers.indices, id: \.self) { index in
                        let marker = Self.markers[index]
                        let x = geo.size.width * CGFloat(marker.hz / maxHz)
                        Rectangle()
                            .fill(marker.hz == 1200 ? Color.orange : Theme.header.opacity(0.8))
                            .frame(width: 1, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                        Text(marker.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 2)
                            .background(Theme.header.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                            .position(x: min(max(x, 16), geo.size.width - 16), y: 8)
                    }
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            toneIndicator
            Text(L("Ustaw radio na USB (albo DATA-U) i tak dostrój, żeby nagłówek VIS wypadał na 1900 Hz. Dekoder sam koryguje rozstrojenie do ok. ±200 Hz."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bieżący ton na skali 1000–2500 Hz ze znacznikami.
    private var toneIndicator: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let lo = 1000.0, hi = 2500.0
                let pos = { (hz: Double) in geo.size.width * CGFloat((min(max(hz, lo), hi) - lo) / (hi - lo)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    ForEach(Self.markers.indices, id: \.self) { index in
                        let marker = Self.markers[index]
                        Rectangle().fill(Theme.header.opacity(0.7)).frame(width: 1, height: 10).offset(x: pos(marker.hz))
                    }
                    Circle()
                        .fill(audio.listening ? Theme.accent : Color.gray)
                        .frame(width: 10, height: 10)
                        .offset(x: pos(Double(sstv.tone)) - 5)
                }
            }
            .frame(height: 12)
            Text(audio.listening ? L("Ton: {1} Hz", Int(sstv.tone)) : L("Ton: –"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Nadawanie

    private var transmitPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("NADAWANIE")).font(.caption.bold()).foregroundStyle(Theme.header)
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black)
                    if let preview = sstv.txPreview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 240, height: 190)

                VStack(alignment: .leading, spacing: 6) {
                    Picker(L("Tryb"), selection: $sstv.txVIS) {
                        ForEach(SSTVMode.all) { mode in
                            Text("\(mode.name) – \(Int(mode.duration.rounded())) s").tag(mode.vis)
                        }
                    }
                    .frame(width: 230)
                    HStack(spacing: 6) {
                        Button(L("Obraz…")) { sstv.chooseImage() }
                            .help(L("Wybierz obraz z dysku do nadania"))
                        Button(L("Plansza testowa")) { sstv.useTestPattern() }
                    }
                    Toggle(L("Znak na obrazie"), isOn: $sstv.overlayCall)
                    TextField(L("Tekst na obrazie, np. UR 595 TNX"), text: $sstv.overlayText)
                        .frame(width: 230)
                    HStack {
                        Text(L("Poziom")).font(.caption)
                        Slider(value: $sstv.txLevel, in: 0.1...1).frame(width: 140)
                        Text("\(Int(sstv.txLevel * 100))%").font(.caption.monospacedDigit())
                    }
                    if sstv.transmitting {
                        HStack {
                            Button(role: .destructive) { sstv.stopTX() } label: {
                                Text("STOP").bold().frame(width: 80)
                            }
                            ProgressView(value: sstv.txProgress).frame(width: 130)
                        }
                    } else {
                        Button { sstv.transmit(armed: txArmed) } label: {
                            Text(L("NADAJ ({1} s)", Int(sstv.txMode.duration.rounded()))).bold()
                        }
                        .disabled(!txArmed || sstv.txPreview == nil)
                        .help(txArmed ? L("Nadaje obraz - PTT włącza się automatycznie") : L("Zaznacz „Odblokuj TX” w bloku nadawania"))
                    }
                }
                .controlSize(.small)
            }
            if let message = sstv.txMessage.map(Lr) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(sstv.txOK ? Theme.ok : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("SSTV to ciągła nośna przez 1–3 minuty - zmniejsz moc (np. 25–50 W) i obserwuj ALC: poziom audio ustaw tak, żeby ALC ledwie się ruszało."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
