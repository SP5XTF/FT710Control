import SwiftUI
import AppKit

/// Łączy czytnik FT4222 z modelem waterfalla i udostępnia stan dla widoku.
@MainActor
final class RFScopeController: ObservableObject {
    let model: SpectrumModel

    /// Skop włączony domyślnie; wybór użytkownika jest zapamiętywany (wyłączenie po błędzie - nie).
    @Published var enabled = UserDefaults.standard.object(forKey: "scopeEnabled") as? Bool ?? true {
        didSet {
            if persistChoice { UserDefaults.standard.set(enabled, forKey: "scopeEnabled") }
            if enabled != oldValue { enabled ? start() : stop() }
        }
    }
    private var persistChoice = true
    private var running = false

    /// Start przy uruchomieniu programu, jeśli skop ma być włączony.
    func startIfEnabled() {
        if enabled, !running { start() }
    }
    @Published private(set) var status = L("Wyłączony")
    @Published private(set) var receiving = false
    @Published private(set) var lowHz = 0
    @Published private(set) var highHz = 0
    @Published private(set) var spanHz = 0
    @Published private(set) var fixedMode = false
    @Published private(set) var fps = 0
    @Published private(set) var log: [String] = []

    private let reader = FT4222ScopeReader()
    /// Odbiorca ramek poza widokiem (np. praca zdalna).
    var frameSink: ((FT4222ScopeReader.Frame) -> Void)?
    private var recentRaw: [[UInt8]] = []
    private var lastLoggedMeta = ""
    private var lastCenterHz = 0
    private var framesThisSecond = 0
    private var secondStart = Date()
    private var failed = false
    private var terminateObserver: NSObjectProtocol?

    init() {
        model = SpectrumModel()
        model.rangeDB = 60
        reader.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Przy wyjściu z aplikacji zamknij FT4222 porządnie (UnInitialize + Close).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [reader = self.reader] _ in
            reader.stopAndWait()
        }
    }

    private func start() {
        running = true
        failed = false
        status = L("Otwieranie FT4222…")
        model.clear()
        reader.start()
    }

    private func stop() {
        running = false
        reader.stop()
        receiving = false
        fps = 0
        if !failed { status = L("Wyłączony") }
    }

    private func handle(_ event: FT4222ScopeReader.Event) {
        switch event {
        case .opened(let path):
            status = L("Połączono z FT4222, czekam na ramki…")
            appendLog(L("Biblioteka: {1}", path))
        case .frame(let frame):
            if frame.spanHz != spanHz { model.clear() }   // stare wiersze nie pasowałyby do nowej osi
            recentRaw.append(frame.raw)
            if recentRaw.count > 8 { recentRaw.removeFirst(recentRaw.count - 8) }
            // Do logu tylko zmiany spanu i trybu - zmiana częstotliwości przy kręceniu gałką byłaby szumem.
            let meta = "span \(frame.spanHz) Hz, \(frame.fixedMode ? "FIX" : "CENTER")"
            if meta != lastLoggedMeta {
                lastLoggedMeta = meta
                appendLog(L("Skop: {1}, środek {2} Hz", meta, frame.centerHz))
            }
            lastCenterHz = frame.centerHz
            // Przypisanie do @Published odświeża obserwujące widoki nawet bez zmiany wartości -
            // przy 28 ramkach/s przerysowywało to całe okno. Przypisujemy tylko faktyczne zmiany.
            if lowHz != frame.lowHz, lowHz != 0 { model.rangeShifted() }      // strojenie - peak hold od nowa
            if lowHz != frame.lowHz { lowHz = frame.lowHz }
            if highHz != frame.highHz { highHz = frame.highHz }
            if spanHz != frame.spanHz { spanHz = frame.spanHz }
            if fixedMode != frame.fixedMode { fixedMode = frame.fixedMode }
            if !receiving { receiving = true }
            // 0...255 -> ok. -130...-20 dB (ta sama skala co w RigControl Web; względna, nie kalibrowana)
            model.ingest(line: frame.amplitudes.map { -130 + Float($0) * (110 / 255) })
            countFrame()
            frameSink?(frame)
        case .log(let message):
            appendLog(message)
        case .recovering(let message):
            // odzyskiwanie połączenia - widoczne w nagłówku skopu, nie tylko w dzienniku „Log”
            appendLog(message)
            status = message
            if receiving { receiving = false }
        case .recovered(let message):
            appendLog(message)
            status = L("Połączono z FT4222, czekam na ramki…")
        case .error(let message):
            failed = true
            status = L("Błąd: {1}", message)
            appendLog(message)
        case .stopped:
            receiving = false
            fps = 0
            if enabled {
                persistChoice = false                   // błąd (np. brak biblioteki) nie zmienia zapisanego wyboru
                enabled = false
                persistChoice = true
            }
        }
    }

    /// Zapisuje ostatnie ramki (surowe, po 4096 bajtów) i zrzut hex na Biurko - do analizy układu ramki.
    func saveFrames(vfoHz: Int, modeName: String) {
        guard !recentRaw.isEmpty else {
            appendLog(L("Brak ramek do zapisania - włącz skop"))
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let binURL = desktop.appendingPathComponent("FT710-ramki-\(stamp).bin")
        let txtURL = desktop.appendingPathComponent("FT710-ramki-\(stamp).txt")

        var text = L("FT-710 Control – zrzut ramek skopu\n")
        text += L("VFO A wg CAT: {1} Hz, tryb: {2}\n", vfoHz, modeName)
        text += L("Odczytane: środek {1} Hz, {2}\n", lastCenterHz, lastLoggedMeta)
        text += L("Liczba ramek: {1} x 4096 bajtów (plik .bin)\n\n", recentRaw.count)
        if let last = recentRaw.last {
            text += L("Ostatnia ramka - bajty 0..63 (początek linii widma):\n") + hexDump(last, from: 0, to: 64)
            text += L("\nBajty 2900..3071 (obszar metadanych):\n") + hexDump(last, from: 2900, to: 3072)
            text += L("\nBajty 4064..4095 (koniec ramki):\n") + hexDump(last, from: 4064, to: 4096)
        }
        do {
            try Data(recentRaw.joined()).write(to: binURL)
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            appendLog(L("Zapisano: {1} i .txt na Biurku", binURL.lastPathComponent))
        } catch {
            appendLog(L("Nie udało się zapisać: {1}", error.localizedDescription))
        }
    }

    private func hexDump(_ bytes: [UInt8], from: Int, to: Int) -> String {
        var out = ""
        var offset = from
        while offset < min(to, bytes.count) {
            let end = min(offset + 16, to, bytes.count)
            let hex = bytes[offset..<end].map { String(format: "%02X", $0) }.joined(separator: " ")
            out += String(format: "%04d: ", offset) + hex + "\n"
            offset = end
        }
        return out
    }

    private func countFrame() {
        framesThisSecond += 1
        let elapsed = Date().timeIntervalSince(secondStart)
        if elapsed >= 1 {
            let measured = Int((Double(framesThisSecond) / elapsed).rounded())
            if measured != fps { fps = measured }
            framesThisSecond = 0
            secondStart = Date()
            let text = L("Odbiór: {1} kl./s", fps)
            if text != status { status = text }
        }
    }

    private func appendLog(_ line: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(time)  \(line)")
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }
}

/// Skop RF radia: linia widma, waterfall, oś w MHz, znacznik VFO, strojenie kliknięciem.
struct RFScopeView: View {
    @ObservedObject var scope: RFScopeController
    @ObservedObject var model: SpectrumModel
    let vfoHz: Int
    let modeName: String
    let canTune: Bool
    let onTune: (Int) -> Void
    /// Wersja osadzona w głównym panelu: bez ramki, wyższy obraz, linia widma większa.
    var embedded = false
    /// Klaster DX - znaki spotów nad linią widma (kliknięcie stroi radio).
    var cluster: DXClusterClient? = nil
    /// Krok strojenia kółkiem myszy nad skopem (jak gałka VFO).
    var stepHz = 500
    var onSpot: ((DXSpot) -> Void)? = nil
    /// Aktywacje POTA na skopie (kliknięcie - jak w zakładce POTA).
    var pota: POTAManager? = nil
    var onPOTA: ((POTASpot) -> Void)? = nil
    /// Zawody (stacje zrobione - czerwone albo ukryte) i czy zakładka ZAWODY jest otwarta.
    var contest: ContestManager? = nil
    var contestActive = false

    @State private var hoverX: CGFloat?
    // przewijanie skopu (przeciąganie, gładzik, Shift + kółko)
    @State private var dragLastX: CGFloat = 0
    @State private var panTarget: Int?
    @State private var lastPanSend = Date.distantPast
    @State private var lastPanInput = Date.distantPast
    @State private var wheelAccumulator: CGFloat = 0
    @State private var showLog = false
    /// Wygląd skopu z zakładki EKRAN (zmiany rzadkie - panel przerysowuje się tylko wtedy).
    @ObservedObject private var look = DisplaySettings.shared

    /// Wysokość obszaru linii widma - udział wysokości z ustawień ekranu.
    private func traceHeight(_ total: CGFloat) -> CGFloat { total * CGFloat(look.spectrumFraction) }
    private var totalHeight: CGFloat { 290 }        // wersja w ramce; osadzona wypełnia dostępne miejsce

    var body: some View {
        let _ = RenderStats.tick("skop")
        if embedded {
            VStack(alignment: .leading, spacing: 4) {
                controls
                display
                bandStrip
                axis
                if showLog || !scope.receiving { footer }
            }
            .padding(8)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    controls
                    display
                    bandStrip
                    axis
                    footer
                }
                .padding(4)
            } label: {
                Text(L("Skop RF radia (FT4222)"))
            }
        }
    }

    // MARK: - Sterowanie

    private var controls: some View {
        // Krótkie podpisy, przełączniki i przyciski mają stałą szerokość (fixedSize), żeby przy braku
        // miejsca nie były łamane litera po literze; skracać się może tylko tekst statusu.
        HStack(spacing: 12) {
            if embedded {
                Text("SCOPE").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.header)
                    .fixedSize()
            }
            Toggle(L("Włączony"), isOn: $scope.enabled)
                .fixedSize()
            // „Odbiór: N kl./s” zmienia się co sekundę - w osobnym kontenerze (bez układania całego okna)
            IsolatedHost { ScopeStatusText(scope: scope) }
                .frame(minWidth: 120, maxWidth: 260, minHeight: 14, maxHeight: 14)
                .layoutPriority(-1)
            if scope.spanHz > 0 {
                Text(verbatim: "span \(spanText(scope.spanHz)) · \(scope.fixedMode ? "FIX" : "CENTER")")
                    .font(.caption.monospacedDigit())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Toggle("Auto", isOn: $model.autoFloor).font(.caption)
                    .fixedSize()
                Text(L("Tło")).font(.caption)
                    .fixedSize()
                Slider(value: $model.floorDB, in: -150 ... -20).frame(width: 80)
                    .disabled(model.autoFloor)
            }
            HStack(spacing: 4) {
                Text(L("Kontrast")).font(.caption)
                    .fixedSize()
                Slider(value: Binding(get: { 120 - model.rangeDB },
                                      set: { model.rangeDB = 120 - $0 }),
                       in: 20...100).frame(width: 80)
            }
            // Prędkość wspólna z zakładką EKRAN (waterfall 2D i widok 3D), zapamiętywana.
            Picker("Waterfall", selection: $look.speed) {
                ForEach(DisplaySettings.speeds.indices, id: \.self) { index in
                    let option = DisplaySettings.speeds[index]
                    Text(L(option.name)).tag(option.value)
                }
            }
            .fixedSize()
            Button(L("Zapisz ramki")) { scope.saveFrames(vfoHz: vfoHz, modeName: modeName) }
                .help(L("Zapisuje ostatnie ramki skopu na Biurko (do analizy układu danych radia)"))
                .fixedSize()
            Button(showLog ? L("Ukryj log") : "Log") { showLog.toggle() }
                .fixedSize()
        }
        .controlSize(.small)
    }

    // MARK: - Obraz

    private var display: some View {
        GeometryReader { geo in
            let size = geo.size
            ScopeRenderView(frames: model.frames, traceHeight: traceHeight(size.height),
                            color: look.traceNSColor, display: look)
                .frame(width: size.width, height: size.height)
            .overlay(gridCanvas)
            .overlay(alignment: .top) {
                if let cluster {
                    ScopeSpotOverlay(cluster: cluster, pota: pota ?? POTAManager.idle,
                                     contest: contest ?? ContestManager.placeholder, contestActive: contestActive,
                                     lowHz: lowHz, highHz: highHz, canTune: canTune,
                                     onTune: { spot in onSpot?(spot) }, onPOTA: { spot in onPOTA?(spot) })
                        .frame(height: look.mode == .threeD ? max(60, size.height * 0.25) : traceHeight(size.height))
                }
            }
            .overlay(alignment: .topLeading) { cursor(in: size) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                guard canTune, let hz = frequency(atX: location.x, width: size.width) else { return }
                onTune(rounded(hz))
            }
            // przeciąganie myszą: „chwyć” widmo i przesuń (zwykłe kliknięcie dalej stroi na punkt)
            .gesture(DragGesture(minimumDistance: 5).onChanged { drag in
                pan(points: drag.translation.width - dragLastX, width: size.width)
                dragLastX = drag.translation.width
            }.onEnded { _ in
                dragLastX = 0
                finishPan()
            })
            // gładzik w bok / Shift + kółko: przesuwanie; zwykłe kółko: strojenie krokiem STEP
            .background(ScopeScrollCatcher { dx, dy, precise in
                scroll(dx: dx, dy: dy, precise: precise, width: size.width)
            })
        }
        .frame(minHeight: embedded ? 220 : totalHeight, maxHeight: embedded ? .infinity : totalHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Przewijanie

    /// Przesunięcie widma o `points` punktów (w prawo = niższe częstotliwości wjeżdżają z lewej).
    /// W trybie CENTER radio trzyma VFO w środku skopu, więc przewinięcie = przestrojenie VFO.
    private func pan(points: CGFloat, width: CGFloat) {
        guard canTune, width > 0, highHz > lowHz else { return }
        let hzPerPoint = Double(highHz - lowHz) / Double(width)
        // w trakcie ciągłego ruchu liczymy od ostatniego celu (odczyt z radia przychodzi z opóźnieniem)
        let continuing = panTarget != nil && Date().timeIntervalSince(lastPanInput) < 0.4
        let base = continuing ? (panTarget ?? vfoHz) : vfoHz
        let target = base - Int((Double(points) * hzPerPoint).rounded())
        panTarget = target
        lastPanInput = Date()
        if Date().timeIntervalSince(lastPanSend) > 0.05 {             // najwyżej 20 komend CAT na sekundę
            lastPanSend = Date()
            onTune((target / 10) * 10)
        } else {
            // ostatnia pozycja zawsze trafia do radia - chwilę po zakończeniu ruchu
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard let pending = panTarget, Date().timeIntervalSince(lastPanSend) >= 0.05 else { return }
                lastPanSend = Date()
                onTune((pending / 10) * 10)
            }
        }
    }

    private func finishPan() {
        if let target = panTarget { onTune((target / 10) * 10) }
        panTarget = nil
    }

    private func scroll(dx: CGFloat, dy: CGFloat, precise: Bool, width: CGFloat) {
        guard canTune else { return }
        if abs(dx) > abs(dy) {
            // gładzik: przesunięcie o tyle, o ile przesunęły się palce; Shift + kółko: 1/20 zakresu na „ząbek”
            pan(points: precise ? dx : (dx > 0 ? width / 20 : -width / 20), width: width)
            return
        }
        guard dy != 0 else { return }
        // kółko: jeden „ząbek” = jeden krok; gładzik w pionie - co ~12 punktów
        var steps = 0
        if precise {
            wheelAccumulator += dy
            steps = Int(wheelAccumulator / 12)
            wheelAccumulator -= CGFloat(steps) * 12
        } else {
            steps = dy > 0 ? 1 : -1
        }
        guard steps != 0 else { return }
        let base = (vfoHz / stepHz) * stepHz
        onTune(base + steps * stepHz)
    }

    private var gridCanvas: some View {
        Canvas { context, size in
            for hz in ticks {
                guard let x = xPosition(of: hz, width: size.width) else { continue }
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(p, with: .color(.white.opacity(0.15)), lineWidth: 1)
            }
            if look.mode == .flat {                     // w 3D nie ma podziału na widmo i waterfall
                let y = traceHeight(size.height)
                var separator = Path()
                separator.move(to: CGPoint(x: 0, y: y))
                separator.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(separator, with: .color(.white.opacity(0.25)), lineWidth: 1)
            }

            // Znacznik częstotliwości VFO A
            if let x = xPosition(of: vfoHz, width: size.width) {
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(.red.opacity(0.85)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cursor(in size: CGSize) -> some View {
        if let x = hoverX, let hz = frequency(atX: x, width: size.width) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 1, height: size.height)
                    .offset(x: x)
                Text(verbatim: formatFrequency(rounded(hz)) + (canTune ? L("  (kliknij, aby dostroić)") : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .offset(x: x + 260 > size.width ? x - 260 : x + 6, y: 4)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Oś i opis

    /// Pasek planu pasma (IARU R1) pod obrazem - przerysowywany tylko przy zmianie zakresu.
    @ViewBuilder
    private var bandStrip: some View {
        if look.bandPlan, highHz > lowHz {
            BandPlanStrip(lowHz: lowHz, highHz: highHz)
        }
    }

    private var axis: some View {
        GeometryReader { geo in
            ForEach(ticks, id: \.self) { hz in
                if let x = xPosition(of: hz, width: geo.size.width) {
                    Text(verbatim: tickLabel(hz))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(x, 24), geo.size.width - 24), y: 6)
                }
            }
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private var footer: some View {
        if showLog {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(scope.log.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 11, design: .monospaced))
                }
            }
            .textSelection(.enabled)
        } else if !scope.receiving {
            Text(L("Wymaga LibFT4222 (FTDI) w /usr/local/lib i SCU-LAN10 = ON w radiu. Span i tryb ustawia się w radiu."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(L("Czerwona linia: VFO A. Najedź, żeby zobaczyć częstotliwość; kliknij, żeby dostroić VFO A."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Przeliczenia

    private func xPosition(of hz: Int, width: CGFloat) -> CGFloat? {
        guard highHz > lowHz, hz >= lowHz, hz <= highHz else { return nil }
        return width * CGFloat(Double(hz - lowHz) / Double(highHz - lowHz))
    }

    private func frequency(atX x: CGFloat, width: CGFloat) -> Int? {
        guard highHz > lowHz, width > 0 else { return nil }
        let t = Double(min(max(x / width, 0), 1))
        return lowHz + Int((t * Double(highHz - lowHz)).rounded())
    }

    /// Szersze spany: krok 100 Hz, węższe: 10 Hz.
    private func rounded(_ hz: Int) -> Int {
        let step = scope.spanHz >= 20_000 ? 100 : 10
        return (hz + step / 2) / step * step
    }

    private var lowHz: Int { scope.lowHz }
    private var highHz: Int { scope.highHz }

    private var tickStep: Int {
        switch scope.spanHz {
        case ..<1_500: return 200
        case ..<3_000: return 500
        case ..<7_000: return 1_000
        case ..<15_000: return 2_000
        case ..<30_000: return 5_000
        case ..<70_000: return 10_000
        case ..<150_000: return 20_000
        case ..<300_000: return 50_000
        case ..<700_000: return 100_000
        default: return 200_000
        }
    }

    private var ticks: [Int] {
        guard highHz > lowHz else { return [] }
        let step = tickStep
        let first = (lowHz + step - 1) / step * step
        return Array(stride(from: first, through: highHz, by: step))
    }

    private func tickLabel(_ hz: Int) -> String {
        tickStep < 1_000 ? String(format: "%.4f", Double(hz) / 1e6) : String(format: "%.3f", Double(hz) / 1e6)
    }

    private func spanText(_ hz: Int) -> String {
        hz >= 1_000_000 ? "\(hz / 1_000_000) MHz" : "\(hz / 1_000) kHz"
    }
}

/// Panel skopu przerysowuje się z powodu okna tylko przy zmianie własnych danych - nie przy każdej
/// zmianie S-metra czy innych pól okna (domknięcie `onTune` uniemożliwiało SwiftUI porównanie).
/// Zmiany skopu i ramek przychodzą osobno, przez obserwowane obiekty.
extension RFScopeView: Equatable {
    static func == (lhs: RFScopeView, rhs: RFScopeView) -> Bool {
        lhs.vfoHz == rhs.vfoHz && lhs.modeName == rhs.modeName && lhs.canTune == rhs.canTune
            && lhs.embedded == rhs.embedded && lhs.scope === rhs.scope && lhs.model === rhs.model
            && lhs.cluster === rhs.cluster && lhs.pota === rhs.pota && lhs.stepHz == rhs.stepHz
            && lhs.contest === rhs.contest && lhs.contestActive == rhs.contestActive
    }
}

/// Kółko myszy i gładzik nad skopem: (dx, dy, czy precyzyjne - gładzik). Kliknięcia przechodzą dalej.
struct ScopeScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return nil                                              // zdarzenie obsłużone przez skop
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}


/// Stan skopu w nagłówku (obserwuje tylko skop; wyświetlany w IsolatedHost).
struct ScopeStatusText: View {
    @ObservedObject var scope: RFScopeController

    var body: some View {
        Text(Lr(scope.status))
            .font(.caption)
            .foregroundStyle(isErrorStatus(scope.status) ? .red : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
