import SwiftUI
import AppKit

/// Zakładka FT8/FT4 (etap 1 - odbiór): wodospad jak w WSJT-X, aktywność pasma, okno częstotliwości odbioru.
struct FT8View: View {
    @ObservedObject var ft8: FT8Manager
    @ObservedObject var audio: AudioManager
    @ObservedObject var cat: CATClient
    let txArmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            statusLine
            HStack(alignment: .top, spacing: 10) {
                FT8DecodeList(title: L("AKTYWNOŚĆ PASMA"), decodes: visibleActivity, ft8: ft8, showCountry: true)
                FT8DecodeList(title: L("CZĘSTOTLIWOŚĆ ODBIORU ({1} Hz)", ft8.rxFreq), decodes: ft8.rxWindow,
                              ft8: ft8, showCountry: false)
                    .frame(width: 540)
                // panel nadawania przewijany, gdy nie mieści się w pionie (nie wchodzi pod pasek stanu okna)
                ScrollView { FT8TransmitPanel(ft8: ft8, cat: cat, txArmed: txArmed).padding(.trailing, 8) }
                    .frame(width: 410)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var visibleActivity: [FTDecode] {
        guard ft8.onlyCQ else { return ft8.activity }
        return ft8.activity.filter { $0.isSeparator || $0.info.isCQ || $0.toMe || $0.isTX }
    }

    // MARK: - Górny pasek

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $ft8.mode) {
                ForEach(FTMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            Toggle(L("Dekodowanie"), isOn: $ft8.enabled)
            Picker(L("Głębokość"), selection: $ft8.depth) {
                Text(L("Szybka")).tag(1)
                Text(L("Normalna")).tag(2)
                Text(L("Głęboka")).tag(3)
            }
            .frame(width: 170)
            .help(L("Liczba przebiegów z odejmowaniem zdekodowanych sygnałów (więcej = słabsze stacje pod silnymi, dłużej)"))
            Divider().frame(height: 18)
            ForEach(ft8.mode.dialFrequencies, id: \.self) { hz in
                Button(LogFrequency.band(for: hz) ?? "") { ft8.tune(to: hz) }
                    .buttonStyle(RigButtonStyle(selected: abs(cat.activeFreq - hz) < 500, height: 20, fontSize: 10))
                    .fixedSize()
                    .disabled(!cat.isConnected)
                    .help(L("{1} MHz, DATA-U", String(format: "%.4f", Double(hz) / 1_000_000)))
            }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                Image(systemName: "sun.max").font(.caption)
                Slider(value: $ft8.brightness, in: -20...20).frame(width: 60)
                Image(systemName: "circle.lefthalf.filled").font(.caption)
                Slider(value: $ft8.contrast, in: 10...70).frame(width: 60)
            }
            .help(L("Jasność i kontrast wodospadu"))
            HStack(spacing: 4) {
                Text(L("Poziom TX")).font(.caption)
                Slider(value: $ft8.txLevel, in: 0.05...1).frame(width: 70)
                Text("\(Int(ft8.txLevel * 100))%").font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
            }
            .help(L("Poziom dźwięku nadawania FT8/FT4 (ustaw tak, żeby ALC prawie nie wychylało)"))
            Spacer()
            cycleClock
        }
        .controlSize(.small)
    }

    /// Czas UTC i postęp cyklu (jak pasek w WSJT-X).
    private var cycleClock: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = context.date.timeIntervalSince1970
            let period = ft8.mode.period
            let into = now - (now / period).rounded(.down) * period
            HStack(spacing: 6) {
                Text(Self.utc.string(from: context.date)).font(.system(size: 13, weight: .bold, design: .monospaced))
                ProgressView(value: into, total: period).frame(width: 70)
                Text(String(format: "%4.1f s", into)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss 'UTC'"
        return f
    }()

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 10) {
            Text(L("RX {1} Hz · TX {2} Hz", ft8.rxFreq, ft8.txFreq)).font(.caption.monospacedDigit())
            Text(L("Wodospad: lewy przycisk - odbiór, prawy (lub Shift) - nadawanie; można przeciągać"))
                .font(.caption2).foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Text(L("Ostatni cykl: {1} komunikatów, {2} s", ft8.lastCount, String(format: "%.2f", ft8.lastDecodeSeconds)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let dt = ft8.medianDT, abs(dt) > 0.5 {
                Text(L("DT większości stacji: {1} s - sprawdź zegar Maca", String(format: "%+.1f", dt)))
                    .font(.caption.bold()).foregroundStyle(.orange)
            }
            Spacer()
            if !audio.listening {
                Text(L("Dekoder potrzebuje dźwięku z radia.")).font(.caption).foregroundStyle(.orange)
                Button(L("Włącz odsłuch")) { audio.toggleListening() }
            } else if cat.isConnected, cat.modeCode != "C" {
                Text(L("Radio w trybie {1}", cat.modeName)).font(.caption).foregroundStyle(.orange)
                Button(L("Ustaw radio: DATA-U")) { ft8.setRadioDataU() }
            }
            PSKReporterControl(ft8: ft8, psk: ft8.psk)
            Text(Lr(ft8.clockStatus)).font(.caption2)
                .foregroundStyle((ft8.clockOffset.map { abs($0) >= 0.2 } ?? false) ? Color.orange : Color.secondary)
                .lineLimit(1)
            Button(L("Sprawdź zegar")) { ft8.checkClock() }
        }
        .controlSize(.small)
    }
}

// MARK: - Wodospad

/// Wodospad w stylu WSJT-X: najnowszy wiersz u góry, skala częstotliwości, znaczniki RX (zielony) i TX (czerwony,
/// przerywany), linia i czas UTC na początku każdego cyklu. Kliknięcie ustawia odbiór, prawy przycisk - nadawanie.
/// Wyświetlany w miejscu skopu RF, gdy otwarta jest zakładka FT8/FT4.
struct FT8WaterfallView: View {
    @ObservedObject var model: FT8WaterfallModel
    @ObservedObject var ft8: FT8Manager

    var body: some View {
        GeometryReader { geo in
            let maxHz = model.frame?.maxHz ?? FT8Receiver.waterfallMaxHz
            let scaleHeight: CGFloat = 20
            let width = geo.size.width
            let height = geo.size.height - scaleHeight
            VStack(spacing: 0) {
                scale(width: width, maxHz: maxHz).frame(height: scaleHeight)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let frame = model.frame {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: width, height: height)
                        ForEach(frame.boundaries, id: \.row) { mark in
                            Text(mark.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 2)
                                .background(Color.black.opacity(0.55))
                                .position(x: 30, y: height * CGFloat(mark.row) / CGFloat(frame.rows) + 6)
                        }
                    } else {
                        Text(ft8.enabled ? L("Oczekiwanie na dźwięk z radia…") : L("Dekodowanie wyłączone"))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: width, height: height)
                    }
                    marker(hz: ft8.txFreq, color: .red, dashed: true, width: width, height: height, maxHz: maxHz)
                    marker(hz: ft8.rxFreq, color: .green, dashed: false, width: width, height: height, maxHz: maxHz)
                }
                .frame(width: width, height: height)
                .clipped()
                .overlay(
                    // lewy przycisk: odbiór; prawy albo Shift+lewy: nadawanie; przeciąganie przesuwa znacznik
                    FT8ClickCatcher { x, viewWidth, transmit in
                        let hz = Int((Double(x / max(viewWidth, 1)) * maxHz).rounded())
                        let clamped = max(100, min(3000, hz))
                        if transmit { ft8.txFreq = clamped } else { ft8.rxFreq = clamped }
                    }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { ft8.setWaterfallVisible(true) }
        .onDisappear { ft8.setWaterfallVisible(false) }
        .onChange(of: ft8.enabled) { _ in ft8.setWaterfallVisible(true) }
    }

    /// Skala częstotliwości z podziałką co 100 Hz i opisem co 500 Hz; nad nią klamry RX i TX.
    private func scale(width: CGFloat, maxHz: Double) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
            var hz = 0.0
            while hz <= maxHz {
                let x = size.width * CGFloat(hz / maxHz)
                let major = Int(hz) % 500 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (major ? 7 : 3)))
                context.stroke(tick, with: .color(.gray), lineWidth: 1)
                if major, hz > 0, hz < maxHz {
                    context.draw(Text("\(Int(hz))").font(.system(size: 9)).foregroundColor(.gray),
                                 at: CGPoint(x: x, y: 6))
                }
                hz += 100
            }
            // TX wyżej, RX niżej - przy TX = RX widać obie klamry
            for (f, color, top) in [(ft8.txFreq, Color.red, CGFloat(16)), (ft8.rxFreq, Color.green, CGFloat(8))] {
                let x0 = size.width * CGFloat(Double(f) / maxHz)
                let x1 = size.width * CGFloat((Double(f) + ft8.mode.bandwidth) / maxHz)
                var bracket = Path()
                bracket.move(to: CGPoint(x: x0, y: size.height - top + 7))
                bracket.addLine(to: CGPoint(x: x0, y: size.height - top))
                bracket.addLine(to: CGPoint(x: x1, y: size.height - top))
                bracket.addLine(to: CGPoint(x: x1, y: size.height - top + 7))
                context.stroke(bracket, with: .color(color), lineWidth: 2)
            }
        }
    }

    private func marker(hz: Int, color: Color, dashed: Bool, width: CGFloat, height: CGFloat, maxHz: Double) -> some View {
        let x = width * CGFloat(Double(hz) / maxHz)
        let w = max(2, width * CGFloat(ft8.mode.bandwidth / maxHz))
        return Rectangle()
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [5, 4] : []))
            .frame(width: w, height: height)
            .position(x: x + w / 2, y: height / 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Lista komunikatów

/// Lista komunikatów w stylu WSJT-X: UTC, dB, DT, Freq, komunikat; kolory i kategorie jak „Decode Highlighting”
/// w WSJT-X (FT8Highlight.swift), wybór kategorii przyciskiem „Kolory…”.
struct FT8DecodeList: View {
    let title: String
    let decodes: [FTDecode]
    @ObservedObject var ft8: FT8Manager
    let showCountry: Bool
    @State private var showColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(Theme.header)
                Spacer()
                if showCountry {
                    Toggle(L("Tylko CQ i do mnie"), isOn: $ft8.onlyCQ).controlSize(.mini)
                    Button(L("Kolory…")) { showColors.toggle() }
                        .controlSize(.mini)
                        .popover(isPresented: $showColors, arrowEdge: .bottom) { FT8HighlightSettings(ft8: ft8) }
                        .help(L("Kategorie wyróżniania i kolory (jak Decode Highlighting w WSJT-X)"))
                    Button(L("Kopiuj")) { ft8.copyActivity() }.controlSize(.mini)
                    Button(L("Wyczyść")) { ft8.clearActivity() }.controlSize(.mini)
                }
            }
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(decodes) { decode in
                            row(decode).id(decode.id)
                        }
                    }
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                // po powrocie na zakładkę lista budowana jest od nowa (od góry) - od razu do najnowszych;
                // dwa razy, bo LazyVStack potrzebuje chwili na rozmieszczenie wierszy
                .onAppear {
                    guard let last = decodes.last?.id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: decodes.last?.id) { last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("UTC").frame(width: 56, alignment: .leading)
            Text("dB").frame(width: 32, alignment: .trailing)
            Text("DT").frame(width: 38, alignment: .trailing)
            Text("Freq").frame(width: 44, alignment: .trailing)
            Text("km").frame(width: 50, alignment: .trailing)
            Text(L("Komunikat")).padding(.leading, 10)
            Spacer()
            if showCountry { Text(L("Kraj")).padding(.trailing, 6) }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(_ d: FTDecode) -> some View {
        if d.isSeparator {
            HStack(spacing: 6) {
                Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1)
                Text("\(d.timeText) \(d.mode.rawValue)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1)
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 0) {
                Text(d.timeText).frame(width: 56, alignment: .leading)
                Text("\(d.snr)").frame(width: 32, alignment: .trailing)
                Text(String(format: "%.1f", d.dt)).frame(width: 38, alignment: .trailing)
                Text("\(d.freq)").frame(width: 44, alignment: .trailing)
                // odległość: z lokatora; „~” - bez lokatora, środek kraju (cty.dat)
                Text(ft8.distanceText(to: d)).frame(width: 50, alignment: .trailing).foregroundStyle(.secondary)
                Text(d.text).padding(.leading, 10).lineLimit(1)
                Spacer(minLength: 4)
                if showCountry, !d.country.isEmpty {
                    Text(d.country).lineLimit(1).foregroundStyle(.secondary).padding(.trailing, 6)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(textColor(d))
            .padding(.vertical, 1)
            .background(background(d))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ft8.call(d) }            // jak w WSJT-X: dwuklik = wołanie stacji
            .onTapGesture { ft8.select(d) }
            .help(help(d))
        }
    }

    /// Pierwsza pasująca i włączona kategoria (kolejność pierwszeństwa jak w WSJT-X).
    private func highlight(_ d: FTDecode) -> FTHighlight? {
        d.highlights.first { ft8.highlightEnabled.contains($0) }
    }

    private func background(_ d: FTDecode) -> Color {
        highlight(d)?.color ?? .clear
    }

    /// Na kolorowym tle czarny tekst (jak w WSJT-X); bez wyróżnienia - zwykły, a dla stacji już zrobionej
    /// na tym paśmie - szary.
    private func textColor(_ d: FTDecode) -> Color {
        if highlight(d) != nil { return .black }
        return d.workedOnBand ? Color.secondary : Theme.text
    }

    /// Podpowiedź: wszystkie pasujące kategorie (także wyłączone) i kraj.
    private func help(_ d: FTDecode) -> String {
        var parts = d.highlights.map(\.name)
        if d.workedOnBand { parts.append(L("Już w dzienniku na tym paśmie")) }
        if !d.country.isEmpty { parts.append(d.country) }
        return parts.joined(separator: " · ")
    }
}

/// Lista kategorii wyróżniania z polami wyboru i kolorami - jak „Decode Highlighting” w WSJT-X.
/// Kolejność listy = kolejność pierwszeństwa.
struct FT8HighlightSettings: View {
    @ObservedObject var ft8: FT8Manager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Wyróżnianie komunikatów")).font(.headline).padding(.bottom, 4)
            Text(L("Pierwsza zaznaczona kategoria z góry wyznacza kolor (jak w WSJT-X). „Nowy …” dotyczy CQ."))
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(FTHighlight.allCases) { item in
                Toggle(isOn: Binding(get: { ft8.highlightEnabled.contains(item) },
                                     set: { on in
                                         if on { ft8.highlightEnabled.insert(item) } else { ft8.highlightEnabled.remove(item) }
                                     })) {
                    Text(item.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.color)
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Button(L("Domyślne")) { ft8.highlightEnabled = FTHighlight.defaultEnabled }
                Button(L("Wszystkie")) { ft8.highlightEnabled = Set(FTHighlight.allCases) }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 320)
    }
}

// MARK: - Panel nadawania

/// Nadawanie jak w WSJT-X: znak i lokator stacji DX, raport, komunikaty Tx1…Tx6 (kropka = nadawany w następnym
/// cyklu, ✓/⚠ = echo kodera), Włącz TX / Zatrzymaj / CQ, cykl nadawania, automatyczna sekwencja.
struct FT8TransmitPanel: View {
    @ObservedObject var ft8: FT8Manager
    @ObservedObject var cat: CATClient
    let txArmed: Bool
    @State private var showSequenceOptions = false

    private static let names = ["Tx1", "Tx2", "Tx3", "Tx4", "Tx5", "Tx6"]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("NADAWANIE")).font(.caption.bold()).foregroundStyle(Theme.header)
                Spacer()
                Stepper(value: $ft8.txFreq, in: 100...3000, step: 10) {
                    Text(L("TX {1} Hz", ft8.txFreq)).font(.caption.monospacedDigit().bold()).foregroundStyle(.red)
                }
                .help(L("Częstotliwość nadawania (ton w paśmie audio). W wodospadzie: prawy przycisk albo Shift+kliknięcie, można przeciągać."))
                Text(L("RX {1} Hz", ft8.rxFreq)).font(.caption.monospacedDigit()).foregroundStyle(.green)
                Button(L("TX = RX")) { ft8.txFreq = ft8.rxFreq }
                    .help(L("Nadawanie na częstotliwości odbioru"))
                Button(L("RX = TX")) { ft8.rxFreq = ft8.txFreq }
                    .help(L("Odbiór na częstotliwości nadawania"))
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                TextField(L("Znak DX"), text: $ft8.dxCall).frame(width: 100)
                TextField(L("Lokator"), text: $ft8.dxGrid).frame(width: 56)
                Stepper(value: $ft8.reportSent, in: -30...30) {
                    Text(L("Raport {1}", FT8Manager.reportText(ft8.reportSent))).font(.caption.monospacedDigit())
                }
                Spacer()
                Button(L("Generuj")) { ft8.generateMessages() }
                    .help(L("Komunikaty standardowe dla znaku DX, Twojego znaku i lokatora"))
            }
            .controlSize(.small)
            ForEach(0..<6, id: \.self) { index in
                messageRow(index)
            }
            HStack(spacing: 6) {
                Button { ft8.txEnabled.toggle() } label: {
                    Text(ft8.txEnabled ? L("TX włączony") : L("Włącz TX")).bold().frame(minWidth: 80)
                }
                .buttonStyle(RigButtonStyle(selected: ft8.txEnabled, height: 22, fontSize: 11))
                .disabled(!txArmed && !ft8.txEnabled)
                .help(L("Nadawanie w kolejnych cyklach (Enable Tx). Wyłączenie pozwala dokończyć bieżący komunikat."))
                Button { ft8.haltTX(L("Nadawanie zatrzymane.")) } label: { Text(L("Zatrzymaj")).bold() }
                    .buttonStyle(RigButtonStyle(height: 22, fontSize: 11))
                    .help(L("Natychmiastowe przerwanie nadawania (Halt Tx)"))
                Button { ft8.callCQ() } label: { Text("CQ").bold() }
                    .buttonStyle(RigButtonStyle(height: 22, fontSize: 11))
                    .disabled(!txArmed)
                    .help(L("Wołanie CQ (Tx6)"))
                Spacer()
                Picker("", selection: $ft8.txFirst) {
                    Text(L("1. cykl")).tag(true)
                    Text(L("2. cykl")).tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .help(L("FT8: 1. cykl = :00 i :30, 2. cykl = :15 i :45. Dwuklik na stacji wybiera cykl sam."))
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Toggle(L("Auto-sekwencja"), isOn: $ft8.autoSequence)
                    .help(L("Automatyczny wybór następnego komunikatu po odpowiedzi stacji"))
                Toggle(L("Pomiń Tx1"), isOn: $ft8.skipTx1)
                    .help(L("Dwuklik na CQ: od razu raport (Tx2) zamiast lokatora (Tx1) - QSO krótsze o jeden cykl (Skip Tx1 w WSJT-X)"))
                    .disabled(ft8.houndMode)
                Toggle(L("Hound"), isOn: $ft8.houndMode)
                    .help(L("Tryb DXpedycji (Fox/Hound, jak w WSJT-X): wołanie Foxa powyżej 1000 Hz w 2. cyklu, R+raport na częstotliwości Foxa, po RR73 zapis QSO. Tylko gdy DXpedycja ogłasza tryb Fox/Hound - zwykłych stacji nie wołaj w tym trybie."))
                Spacer(minLength: 4)
                Button(L("Opcje…")) { showSequenceOptions = true }
                    .help(L("Limit wywołań, wybór wołającego, następny wołający po QSO, Trzymaj TX, Wyłącz TX po 73"))
                    .popover(isPresented: $showSequenceOptions, arrowEdge: .top) { sequenceOptions }
            }
            .controlSize(.small)
            // podsumowanie opcji (zmiana: „Opcje…”) - zawsze widać, co jest ustawione
            Text(sequenceSummary)
                .font(.caption2)
                .foregroundStyle(ft8.houndMode ? Color.orange : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            statusArea
            Spacer(minLength: 0)
        }
    }

    /// Opcje sekwencji w okienku „Opcje…” - ustawiane rzadko, panel mieści się bez przewijania.
    private var sequenceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Opcje sekwencji FT8/FT4")).font(.headline)
            HStack(spacing: 6) {
                Text(L("Limit wywołań:"))
                Picker("", selection: $ft8.callLimit) {
                    ForEach([3, 5, 9], id: \.self) { Text("\($0)").tag($0) }
                    Text(L("bez limitu")).tag(0)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .help(L("Ile razy z rzędu wołać stację, która nie odpowiada (wywołanie i R-raport); potem nadawanie się wyłącza. Każda odpowiedź tej stacji liczy od nowa. CQ - bez limitu (pilnuje watchdog)."))
            HStack(spacing: 6) {
                Text(L("Kilku wołających:"))
                Picker("", selection: $ft8.callerPreference) {
                    ForEach(FTCallerPreference.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            .help(L("Gdy na Twoje CQ odpowiada kilka stacji naraz - której odpowiedzieć najpierw. Odległość z lokatora stacji, a bez niego z położenia kraju (cty.dat)."))
            Toggle(L("Po QSO odpowiadaj następnemu wołającemu"), isOn: $ft8.answerNextCaller)
                .help(L("Po QSO zaczętym od Twojego CQ TX zostaje włączony: w następnym cyklu odpowiedź kolejnej wołającej stacji (wg „Kilku wołających”), a gdy nikt nie woła - znowu CQ. Po QSO z Twojego wołania (S&P) działa „Wyłącz TX po 73”."))
            Toggle(L("Trzymaj TX"), isOn: $ft8.holdTxFreq)
                .help(L("Dwuklik na stacji nie przenosi częstotliwości nadawania (praca split)"))
            Toggle(L("Wyłącz TX po 73"), isOn: $ft8.disableAfter73)
        }
        .padding(14)
        .frame(width: 380)
    }

    /// Jedna linijka: aktualne opcje sekwencji.
    private var sequenceSummary: String {
        if ft8.houndMode {
            var hound = [L("HOUND (DXpedycja)"), L("TX {1} Hz", ft8.txFreq)]
            if ft8.txFreq < 1000 { hound.append(L("uwaga: wołaj powyżej 1000 Hz")) }
            hound.append(L("2. cykl"))
            return hound.joined(separator: " · ")
        }
        var parts = [ft8.callLimit == 0 ? L("bez limitu wywołań") : L("limit {1}", ft8.callLimit),
                     L("wołający: {1}", ft8.callerPreference.name)]
        if ft8.answerNextCaller { parts.append(L("po QSO następny")) }
        if ft8.holdTxFreq { parts.append(L("trzymaj TX")) }
        if ft8.disableAfter73 { parts.append(L("wył. TX po 73")) }
        return parts.joined(separator: " · ")
    }

    private func messageRow(_ index: Int) -> some View {
        HStack(spacing: 5) {
            Button { ft8.nextTx = index } label: {
                Image(systemName: ft8.nextTx == index ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(ft8.nextTx == index ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Nadawany w następnym cyklu"))
            Text(Self.names[index]).font(.caption.monospacedDigit()).frame(width: 26, alignment: .leading)
            TextField("", text: $ft8.txMessages[index])
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            let text = ft8.txMessages[index].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                Image(systemName: ft8.txValid[index] ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ft8.txValid[index] ? Color.green : Color.orange)
                    .help(ft8.txValid[index] ? L("Odbiorca zobaczy: {1}", ft8.txEchoes[index])
                                             : L("Odbiorca zobaczyłby: {1} - ten komunikat nie zostanie nadany",
                                                 ft8.txEchoes[index]))
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if ft8.transmitting {
            HStack {
                Text(L("Nadaję: {1}", ft8.txText)).font(.caption.monospacedDigit().bold()).foregroundStyle(.yellow)
                Spacer()
            }
            ProgressView(value: ft8.txProgress)
        }
        if !ft8.dxCall.isEmpty {
            Text(L("QSO: {1} · wysłano {2} · odebrano {3}", ft8.dxCall.uppercased(),
                   FT8Manager.reportText(ft8.reportSent), ft8.reportReceived ?? "—"))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if let status = ft8.txStatus.map(Lr) {
            Text(status).font(.caption).foregroundStyle(ft8.txStatusIsInfo ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !txArmed {
            Text(L("Nadawanie wymaga zaznaczenia „Odblokuj TX” (prawa kolumna)."))
                .font(.caption2).foregroundStyle(.secondary)
        } else if cat.isConnected, cat.modeCode != "C" {
            Text(L("Radio nie jest w DATA-U - kliknij „Ustaw radio: DATA-U”."))
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}

// MARK: - Mysz w wodospadzie

/// Obsługa myszy w wodospadzie przez AppKit (pewniejsza niż gest SwiftUI z klawiszem Shift):
/// lewy przycisk - częstotliwość odbioru, prawy albo Shift+lewy - nadawania; przeciąganie przesuwa znacznik.
struct FT8ClickCatcher: NSViewRepresentable {
    let onClick: (_ x: CGFloat, _ width: CGFloat, _ transmit: Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onClick = onClick }

    final class CatcherView: NSView {
        var onClick: ((CGFloat, CGFloat, Bool) -> Void)?
        private var dragTransmit = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func report(_ event: NSEvent, transmit: Bool) {
            let point = convert(event.locationInWindow, from: nil)
            onClick?(min(max(point.x, 0), bounds.width), bounds.width, transmit)
        }

        override func mouseDown(with event: NSEvent) {
            dragTransmit = event.modifierFlags.contains(.shift)    // lewy: RX, Shift+lewy: TX
            report(event, transmit: dragTransmit)
        }
        override func mouseDragged(with event: NSEvent) { report(event, transmit: dragTransmit) }
        override func rightMouseDown(with event: NSEvent) { report(event, transmit: true) }       // prawy: TX
        override func rightMouseDragged(with event: NSEvent) { report(event, transmit: true) }
    }
}

// MARK: - PSKReporter

/// Przełącznik zgłaszania do PSKReporter, antena (opcjonalnie) i stan wysyłki.
struct PSKReporterControl: View {
    @ObservedObject var ft8: FT8Manager
    @ObservedObject var psk: PSKReporterClient

    var body: some View {
        HStack(spacing: 4) {
            Toggle("PSKReporter", isOn: $ft8.pskEnabled)
                .help(psk.status.isEmpty
                      ? L("Zgłaszanie odebranych stacji do pskreporter.info (co 5 min, każda stacja najwyżej raz na godzinę na paśmie)")
                      : Lr(psk.status))
            if ft8.pskEnabled {
                TextField(L("antena"), text: $ft8.pskAntenna)
                    .frame(width: 90)
                    .help(L("Opis anteny wysyłany do PSKReporter (opcjonalnie)"))
                Text("\(psk.sentSpots)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(psk.status.isEmpty ? L("Pierwsza wysyłka po ok. 5 minutach") : Lr(psk.status))
            }
        }
    }
}
