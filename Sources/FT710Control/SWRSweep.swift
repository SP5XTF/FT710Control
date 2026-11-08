import SwiftUI
import Charts
import AVFoundation
import UniformTypeIdentifiers

/// Wynik pomiaru SWR anteny (zapisywany, do porównań).
struct SWRMeasurement: Codable, Identifiable, Equatable {
    struct Point: Codable, Equatable {
        let hz: Int
        let swr: Double
    }
    var id = UUID()
    let date: Date
    let band: String
    let watts: Int
    let points: [Point]

    var best: Point? { points.min { $0.swr < $1.swr } }
    var title: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(band) · \(f.string(from: date))"
    }
}

/// Pomiar SWR anteny w paśmie: na każdej częstotliwości krótka nośna (ton 1500 Hz w DATA-U przez dźwięk USB,
/// jak „Tune” w WSJT-X) na małej mocy i odczyt SWR z radia. Częstotliwość zmieniana tylko na odbiorze.
/// Zabezpieczenia: „Odblokuj TX”, moc 5–10 W, tylko pasma amatorskie, przerwanie przy SWR > 5, brak mocy,
/// STOP, rozłączenie radia; po pomiarze przywrócenie częstotliwości, trybu, mocy i tunera.
@MainActor
final class SWRSweep: ObservableObject {
    static let shared = SWRSweep()

    /// Pasma amatorskie (IARU R1, Polska) - pomiar tylko w tych granicach.
    static let bands: [(name: String, low: Int, high: Int)] = [
        ("160m", 1_810_000, 2_000_000), ("80m", 3_500_000, 3_800_000), ("60m", 5_351_500, 5_366_500),
        ("40m", 7_000_000, 7_200_000), ("30m", 10_100_000, 10_150_000), ("20m", 14_000_000, 14_350_000),
        ("17m", 18_068_000, 18_168_000), ("15m", 21_000_000, 21_450_000), ("12m", 24_890_000, 24_990_000),
        ("10m", 28_000_000, 29_700_000), ("6m", 50_000_000, 52_000_000)
    ]
    static let toneHz = 1500.0
    static let abortSWR = 5.0

    @Published var band: String { didSet { UserDefaults.standard.set(band, forKey: "swr.band") } }
    @Published var pointCount: Int { didSet { UserDefaults.standard.set(pointCount, forKey: "swr.points") } }
    @Published var watts: Int { didSet { UserDefaults.standard.set(watts, forKey: "swr.watts") } }
    @Published var tunerOff: Bool { didSet { UserDefaults.standard.set(tunerOff, forKey: "swr.tunerOff") } }
    /// Poziom tonu do radia (jak „Poziom TX” w FT8) - zbyt cichy ton daje zerową moc.
    @Published var toneLevel: Double { didSet { UserDefaults.standard.set(toneLevel, forKey: "swr.toneLevel") } }
    /// Odczyt na żywo w trakcie pomiaru / testu nośnej.
    @Published private(set) var live: String?
    @Published private(set) var running = false
    @Published private(set) var progress = 0.0
    @Published private(set) var current: [SWRMeasurement.Point] = []
    @Published private(set) var message: String?
    @Published private(set) var saved: [SWRMeasurement] = []
    @Published var compareID: UUID?

    private var stopRequested = false
    private var toneEngine: AVAudioEngine?

    private init() {
        let d = UserDefaults.standard
        band = d.string(forKey: "swr.band") ?? "40m"
        let points = d.integer(forKey: "swr.points")
        pointCount = (5...51).contains(points) ? points : 21
        let w = d.integer(forKey: "swr.watts")
        watts = (5...10).contains(w) ? w : 5
        tunerOff = d.object(forKey: "swr.tunerOff") as? Bool ?? true
        toneLevel = d.object(forKey: "swr.toneLevel") as? Double ?? 0.5
        saved = Self.load()
    }

    /// Częstotliwości nośnej w paśmie, równomiernie. Radio sprawdza granice pasma po częstotliwości WYBIERANIA
    /// (nośna = wybieranie + 1500 Hz) - wybieranie musi być co najmniej 1 kHz wewnątrz pasma, inaczej radio blokuje
    /// nadawanie (pomiar zaczynał od 3,4995 MHz i kończył się na pierwszym punkcie).
    static func frequencies(band: String, count: Int) -> [Int] {
        guard let range = bands.first(where: { $0.name == band }), count >= 2 else { return [] }
        let low = range.low + 1_000 + Int(toneHz), high = range.high - 1_000
        return (0..<count).map { low + Int((Double(high - low) * Double($0) / Double(count - 1)).rounded() / 100) * 100 }
    }

    func stop() { stopRequested = true }

    func run() { start(testOnly: false) }

    /// Test nośnej: 3 s na środku pasma z odczytem mocy i SWR na żywo - sprawdzenie, czy radio daje moc z tonu.
    func testCarrier() { start(testOnly: true) }

    private func start(testOnly: Bool) {
        guard !running else { return }
        let hub = DiagnosticsHub.shared
        guard let cat = hub.cat, cat.isConnected else { message = L("Połącz najpierw radio."); return }
        guard hub.txArmed else { message = L("Pomiar nadaje - zaznacz „Odblokuj TX” w oknie głównym."); return }
        guard let audio = hub.audio, audio.radioOut != 0 else {
            message = L("Wybierz w zakładce AUDIO urządzenie „Do radia (TX)”.")
            return
        }
        let all = Self.frequencies(band: band, count: max(pointCount, 3))
        let freqs = testOnly ? [all[all.count / 2]] : Self.frequencies(band: band, count: pointCount)
        guard !freqs.isEmpty else { return }
        running = true
        stopRequested = false
        current = []
        progress = 0
        message = nil
        Task { @MainActor in await sweep(cat: cat, output: audio.radioOut, frequencies: freqs, testOnly: testOnly) }
    }

    private func sweep(cat: CATClient, output: AudioDeviceID, frequencies: [Int], testOnly: Bool) async {
        // stan radia do przywrócenia
        let vfo = cat.activeVFO == "B" ? "B" : "A"
        let savedFreq = vfo == "A" ? cat.freqA : cat.freqB
        let savedMode = cat.modeCode
        let savedPower = cat.value(.power)
        let savedTuner = cat.value(.tuner)
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        defer {
            cat.ptt(false)
            stopTone()
            if !savedMode.isEmpty { cat.setMode(savedMode) }
            if savedFreq > 0 { cat.setFrequency(vfo: vfo, hz: savedFreq) }
            if let savedPower { cat.set(.power, savedPower) }
            if let savedTuner, tunerOff { cat.set(.tuner, savedTuner) }
            running = false
            live = nil
        }
        cat.setMode("C")                                                // DATA-U - ton z USB
        cat.set(.power, watts)
        if tunerOff { cat.set(.tuner, 0) }                             // mierzymy samą antenę
        guard startTone(output: output) else {
            message = L("Nie udało się uruchomić dźwięku do radia.")
            return
        }
        await pause(0.6)
        let band = self.band
        for (index, hz) in frequencies.enumerated() {
            if let reason = abortReason(cat) { message = reason; break }
            cat.setFrequency(vfo: vfo, hz: hz - Int(Self.toneHz))     // nośna = wybieranie + 1500 Hz
            await pause(0.25)
            cat.ptt(true)
            // czekaj, aż radio zgłosi nadawanie (do 1 s), potem na ustalenie mocy
            var waited = 0.0
            while !cat.transmitting, waited < 1.0 { await pause(0.05); waited += 0.05 }
            let sawTX = cat.transmitting
            await pause(0.5)
            if testOnly {
                // test nośnej: 3 s z odczytem na żywo
                for _ in 0..<12 {
                    if abortReason(cat) != nil { break }
                    let w = MeterCalibration.interpolate(cat.rawPO, MeterCalibration.powerWatts)
                    live = L("Nośna {1} MHz: moc {2} W, SWR {3} (odczyt PO {4}, SWR {5})",
                             String(format: "%.3f", Double(hz) / 1_000_000), String(format: "%.1f", w),
                             MeterCalibration.swrText(raw: cat.rawSWR), cat.rawPO, cat.rawSWR)
                    await pause(0.25)
                }
            }
            var swrReadings: [Int] = [], powerReadings: [Int] = []
            for attempt in 0..<2 {                                      // druga próba, gdy moc narasta powoli
                swrReadings = []; powerReadings = []
                for _ in 0..<5 {
                    swrReadings.append(cat.rawSWR)
                    powerReadings.append(cat.rawPO)
                    await pause(0.07)
                }
                if (powerReadings.max() ?? 0) >= 5 || attempt == 1 { break }
                await pause(0.4)
            }
            cat.ptt(false)
            await pause(0.15)
            let swrRaw = swrReadings.sorted()[swrReadings.count / 2]
            let powerRaw = powerReadings.sorted()[powerReadings.count / 2]
            let power = MeterCalibration.interpolate(powerRaw, MeterCalibration.powerWatts)
            if testOnly {
                message = L("Test nośnej: radio nadawało: {1}, moc {2} W (odczyt PO {3}), SWR {4} (odczyt {5}).",
                            sawTX ? L("tak") : L("nie"), String(format: "%.1f", power), powerRaw,
                            MeterCalibration.swrText(raw: swrRaw), swrRaw)
                break
            }
            if power < 1 {
                // szczegóły - od razu widać, czy winne PTT, dźwięk, czy ustawienie radia
                message = sawTX
                    ? L("Brak mocy wyjściowej (radio nadawało, odczyt PO {1}). Sprawdź w menu radia źródło modulacji DATA = USB (REAR), poziom wejścia USB, oraz suwak „Poziom tonu” i głośność urządzenia „Do radia (TX)” w macOS. Użyj „Testu nośnej”.", powerRaw)
                    : L("Radio nie przeszło na nadawanie po komendzie PTT (CAT). Sprawdź połączenie CAT i czy radio nie jest zablokowane (TX LOCK).")
                break
            }
            live = L("Punkt {1}/{2}: {3} MHz – moc {4} W, SWR {5}", index + 1, frequencies.count,
                     String(format: "%.3f", Double(hz) / 1_000_000), String(format: "%.1f", power),
                     String(format: "%.1f", MeterCalibration.interpolate(swrRaw, MeterCalibration.swr)))
            let swr = MeterCalibration.interpolate(swrRaw, MeterCalibration.swr)
            current.append(SWRMeasurement.Point(hz: hz, swr: swr))
            progress = Double(index + 1) / Double(frequencies.count)
            if swr > Self.abortSWR {
                message = L("SWR powyżej {1} na {2} MHz - pomiar przerwany (ochrona radia).", Int(Self.abortSWR),
                            String(format: "%.3f", Double(hz) / 1_000_000))
                break
            }
        }
        if current.count >= 2, !testOnly {
            let measurement = SWRMeasurement(date: Date(), band: band, watts: watts, points: current)
            saved.insert(measurement, at: 0)
            if saved.count > 100 { saved.removeLast(saved.count - 100) }
            save()
            if message == nil, let best = measurement.best {
                message = L("Gotowe: najniższe SWR {1} na {2} MHz.", String(format: "%.1f", best.swr),
                            String(format: "%.3f", Double(best.hz) / 1_000_000))
            }
        }
    }

    private func abortReason(_ cat: CATClient) -> String? {
        if stopRequested { return L("Pomiar zatrzymany.") }
        if !cat.isConnected { return L("Radio rozłączone - pomiar przerwany.") }
        if !DiagnosticsHub.shared.txArmed { return L("Cofnięto „Odblokuj TX” - pomiar przerwany.") }
        return nil
    }

    // MARK: - Ton 1500 Hz do radia (USB)

    private func startTone(output: AudioDeviceID) -> Bool {
        let engine = AVAudioEngine()
        do { try engine.outputNode.auAudioUnit.setDeviceID(output) } catch { return false }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        var phase = 0.0
        let level = min(max(toneLevel, 0.05), 1.0)
        let step = 2 * Double.pi * Self.toneHz / rate
        let source = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = Float(level * sin(phase))
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
            }
            return noErr
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        do { try engine.start() } catch { return false }
        toneEngine = engine
        return true
    }

    private func stopTone() {
        toneEngine?.stop()
        toneEngine = nil
    }

    // MARK: - Zapis pomiarów

    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("FT710Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("swr-measurements.json")
    }

    private static func load() -> [SWRMeasurement] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SWRMeasurement].self, from: data)) ?? []
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func delete(_ measurement: SWRMeasurement) {
        saved.removeAll { $0.id == measurement.id }
        if compareID == measurement.id { compareID = nil }
        save()
    }

    /// CSV pomiaru (MHz;SWR).
    static func csv(_ measurement: SWRMeasurement) -> String {
        "MHz;SWR\n" + measurement.points.map { String(format: "%.4f;%.2f", Double($0.hz) / 1_000_000, $0.swr) }
            .joined(separator: "\n") + "\n"
    }
}

/// Okno „Pomiar SWR anteny” (menu Okno).
struct SWRSweepView: View {
    @ObservedObject var sweep = SWRSweep.shared
    @State private var confirm = false
    @State private var testConfirm = false
    /// Punkt pod myszą (częstotliwość i SWR).
    @State private var hovered: SWRMeasurement.Point?
    @State private var selectedID: UUID?

    private var shown: SWRMeasurement? {
        if sweep.running || selectedID == nil {
            return sweep.current.count >= 2 ? SWRMeasurement(date: Date(), band: sweep.band, watts: sweep.watts, points: sweep.current)
                                            : sweep.saved.first
        }
        return sweep.saved.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                controls
                chart
                if let live = sweep.live {
                    Text(live).font(.callout.monospacedDigit()).foregroundStyle(Theme.accent)
                }
                if let message = sweep.message.map(Lr) {
                    Text(message).font(.callout).foregroundStyle(sweep.running ? Color.primary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            history.frame(width: 230)
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 520)
        .alert(L("Test nośnej nadaje"), isPresented: $testConfirm) {
            Button(L("Nadaj 3 s")) { sweep.testCarrier() }
            Button(L("Anuluj"), role: .cancel) {}
        } message: {
            Text(L("Program nada nośną ({1} W) przez 3 s na środku pasma {2}. Upewnij się, że antena jest podłączona, a częstotliwość wolna.", sweep.watts, sweep.band))
        }
        .alert(L("Pomiar SWR nadaje"), isPresented: $confirm) {
            Button(L("Mierz")) { selectedID = nil; sweep.run() }
            Button(L("Anuluj"), role: .cancel) {}
        } message: {
            Text(L("Program nada krótkie nośne ({1} W) na {2} częstotliwościach w paśmie {3}. Upewnij się, że antena jest podłączona, a częstotliwości wolne (posłuchaj). Po pomiarze radio wróci do poprzedniej częstotliwości, trybu i mocy.",
                   sweep.watts, sweep.pointCount, sweep.band))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
            Group {
                Picker(L("Pasmo"), selection: $sweep.band) {
                    ForEach(SWRSweep.bands, id: \.name) { Text($0.name).tag($0.name) }
                }
                .frame(width: 140)
                Stepper(L("Punkty: {1}", sweep.pointCount), value: $sweep.pointCount, in: 5...51, step: 2)
                Stepper(L("Moc: {1} W", sweep.watts), value: $sweep.watts, in: 5...10)
                Toggle(L("Tuner wyłączony"), isOn: $sweep.tunerOff)
                    .help(L("Na czas pomiaru tuner radia jest wyłączany - mierzysz samą antenę; potem wraca poprzedni stan"))
            }
            .fixedSize()
            .disabled(sweep.running)                                    // w trakcie pomiaru - tylko STOP
            Spacer()
        }
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(L("Poziom tonu"))
                Slider(value: $sweep.toneLevel, in: 0.05...1).frame(width: 120)
                Text("\(Int(sweep.toneLevel * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            .help(L("Głośność tonu wysyłanego do radia (jak „Poziom TX” w FT8) - za cicho: brak mocy; za głośno: ALC"))
            .disabled(sweep.running)
            Spacer()
            if sweep.running {
                ProgressView(value: sweep.progress).frame(width: 120)
                Button(role: .destructive) { sweep.stop() } label: { Text("STOP").bold() }
            } else {
                Button(L("Test nośnej")) { testConfirm = true }
                    .fixedSize()
                    .help(L("Jedna nośna na środku pasma przez 3 s z odczytem mocy i SWR - sprawdzenie ustawień przed pomiarem"))
                Button(L("Mierz")) { confirm = true }
                    .keyboardShortcut(.defaultAction)
            }
        }
        }
    }

    private var chart: some View {
        let measurement = shown
        let compare = sweep.saved.first { $0.id == sweep.compareID && $0.id != measurement?.id }
        let maxSWR = min(max((measurement?.points.map(\.swr).max() ?? 2) + 0.3, 2.5), 5.5)
        // oś częstotliwości: tylko mierzone pasmo (domyślnie wykres zaczynał od 0 MHz - krzywa była wąskim paskiem)
        let bandRange = SWRSweep.bands.first { $0.name == (measurement?.band ?? sweep.band) }
        let lowMHz = Double(measurement?.points.first?.hz ?? bandRange?.low ?? 0) / 1_000_000
        let highMHz = Double(measurement?.points.last?.hz ?? bandRange?.high ?? 1) / 1_000_000
        let padding = max((highMHz - lowMHz) * 0.02, 0.0005)
        return Chart {
            RuleMark(y: .value("SWR", 1.5)).foregroundStyle(.green.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 3]))
            RuleMark(y: .value("SWR", 2.0)).foregroundStyle(.orange.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 3]))
            if let compare {
                ForEach(compare.points, id: \.hz) { point in
                    LineMark(x: .value("MHz", Double(point.hz) / 1_000_000), y: .value("SWR", point.swr),
                             series: .value("pomiar", "compare"))
                        .foregroundStyle(.gray)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            if let measurement {
                ForEach(measurement.points, id: \.hz) { point in
                    LineMark(x: .value("MHz", Double(point.hz) / 1_000_000), y: .value("SWR", point.swr),
                             series: .value("pomiar", "current"))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("MHz", Double(point.hz) / 1_000_000), y: .value("SWR", point.swr))
                        .foregroundStyle(point.swr >= 2 ? Color.orange : Theme.accent)
                        .symbolSize(18)
                }
                if let hovered {
                    RuleMark(x: .value("MHz", Double(hovered.hz) / 1_000_000))
                        .foregroundStyle(.white.opacity(0.35))
                    PointMark(x: .value("MHz", Double(hovered.hz) / 1_000_000), y: .value("SWR", hovered.swr))
                        .foregroundStyle(.white).symbolSize(70)
                        .annotation(position: .top, alignment: .center) {
                            Text(String(format: "%.3f MHz · SWR %.2f", Double(hovered.hz) / 1_000_000, hovered.swr))
                                .font(.caption.bold().monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        }
                }
                if let best = measurement.best {
                    PointMark(x: .value("MHz", Double(best.hz) / 1_000_000), y: .value("SWR", best.swr))
                        .foregroundStyle(.green).symbolSize(90)
                        .annotation(position: .top) {
                            Text(String(format: "%.1f · %.3f", best.swr, Double(best.hz) / 1_000_000))
                                .font(.caption.bold()).foregroundStyle(.green)
                        }
                }
            }
        }
        .chartYScale(domain: 1...maxSWR)
        .chartXScale(domain: (lowMHz - padding)...(highMHz + padding))
        .chartOverlay { proxy in
            // najechanie myszą: najbliższy punkt pomiaru - częstotliwość i SWR (plotAreaFrame - macOS 13)
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geometry[proxy.plotAreaFrame]
                            guard let points = measurement?.points, !points.isEmpty,
                                  let mhz: Double = proxy.value(atX: location.x - plot.origin.x) else { hovered = nil; return }
                            hovered = points.min { abs(Double($0.hz) / 1_000_000 - mhz) < abs(Double($1.hz) / 1_000_000 - mhz) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .chartXAxisLabel("MHz")
        .chartYAxisLabel("SWR")
        .frame(minHeight: 340)
        .overlay {
            if measurement == nil {
                Text(L("Wybierz pasmo i kliknij „Mierz”. Wynik pojawi się tutaj."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Zapisane pomiary")).font(.headline)
            List(sweep.saved, selection: $selectedID) { measurement in
                VStack(alignment: .leading, spacing: 2) {
                    Text(measurement.title).font(.callout)
                    if let best = measurement.best {
                        Text(L("min. {1} na {2} MHz · {3} W", String(format: "%.1f", best.swr),
                               String(format: "%.3f", Double(best.hz) / 1_000_000), measurement.watts))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(measurement.id)
                .contextMenu {
                    Button(L("Porównaj z wybranym")) { sweep.compareID = measurement.id }
                    Button(L("Zapisz CSV…")) { exportCSV(measurement) }
                    Button(L("Usuń"), role: .destructive) { sweep.delete(measurement) }
                }
            }
            if sweep.compareID != nil {
                Button(L("Bez porównania")) { sweep.compareID = nil }.controlSize(.small)
            }
            Text(L("Prawy przycisk na pomiarze: porównanie (szara linia), CSV, usunięcie."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exportCSV(_ measurement: SWRMeasurement) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SWR-\(measurement.band).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? SWRSweep.csv(measurement).write(to: url, atomically: true, encoding: .utf8)
    }
}
