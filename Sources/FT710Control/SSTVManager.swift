import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// SSTV: odbiór (dekoder na dźwięku z radia), galeria odebranych obrazów, przygotowanie i nadawanie obrazu.
@MainActor
final class SSTVManager: ObservableObject {
    // MARK: Odbiór
    @Published var rxEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rxEnabled, forKey: "sstvRX")
            decoder.setPaused(!rxEnabled)
            updateTap()
            if !rxEnabled { receiving = false; rxStatus = L("Odbiór SSTV wyłączony") }
            else { rxStatus = L("Czekam na nagłówek VIS…") }
        }
    }
    @Published var autoSave: Bool { didSet { UserDefaults.standard.set(autoSave, forKey: "sstvAutoSave") } }
    @Published private(set) var rxImage: CGImage?
    @Published private(set) var rxMode: SSTVMode?
    @Published private(set) var rxProgress = 0.0
    @Published private(set) var rxStatus = L("Czekam na nagłówek VIS…")
    @Published private(set) var receiving = false
    @Published private(set) var tone: Float = 0
    @Published private(set) var gallery: [URL] = []

    // MARK: Nadawanie
    @Published var txVIS: Int { didSet { UserDefaults.standard.set(txVIS, forKey: "sstvTXMode"); rebuildPreview() } }
    @Published var overlayText: String { didSet { UserDefaults.standard.set(overlayText, forKey: "sstvOverlay"); rebuildPreview() } }
    @Published var overlayCall: Bool { didSet { UserDefaults.standard.set(overlayCall, forKey: "sstvOverlayCall"); rebuildPreview() } }
    @Published var txLevel: Double { didSet { UserDefaults.standard.set(txLevel, forKey: "sstvLevel") } }
    @Published private(set) var txPreview: CGImage?
    @Published private(set) var transmitting = false
    @Published private(set) var txProgress = 0.0
    @Published private(set) var txMessage: String?
    @Published private(set) var txOK = false

    var txMode: SSTVMode { SSTVMode.byVIS(txVIS) ?? SSTVMode.all[0] }

    static let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("FT710Control SSTV", isDirectory: true)
    }()

    private let decoder = SSTVDecoder()
    private weak var cat: CATClient?
    private weak var audio: AudioManager?
    private var callsign: () -> String = { "" }
    private var txSource: CGImage?
    private var txFrame: [UInt8] = []
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var txStarted = Date()
    private var txDuration = 0.0
    private var progressTimer: Timer?

    init() {
        let d = UserDefaults.standard
        rxEnabled = d.object(forKey: "sstvRX") as? Bool ?? true
        autoSave = d.object(forKey: "sstvAutoSave") as? Bool ?? true
        txVIS = d.object(forKey: "sstvTXMode") as? Int ?? 44
        overlayText = d.string(forKey: "sstvOverlay") ?? ""
        overlayCall = d.object(forKey: "sstvOverlayCall") as? Bool ?? true
        txLevel = d.object(forKey: "sstvLevel") as? Double ?? 0.6
    }

    func attach(audio: AudioManager, cat: CATClient, callsign: @escaping () -> String) {
        guard self.audio == nil else { return }
        self.audio = audio
        self.cat = cat
        self.callsign = callsign
        decoder.setPaused(!rxEnabled)
        decoder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        updateTap()
        loadGallery()
        if txSource == nil { useTestPattern() }
    }

    // MARK: - Odbiór

    /// Wyłączony odbiór - dekoder w ogóle nie dostaje dźwięku.
    private func updateTap() {
        guard let audio else { return }
        if rxEnabled {
            audio.sampleTap.set("sstv") { [decoder] samples, rate in decoder.append(samples, sampleRate: rate) }
        } else {
            audio.sampleTap.set("sstv", nil)
        }
    }

    private func handle(_ event: SSTVDecoder.Event) {
        switch event {
        case .started(let mode):
            receiving = true
            rxMode = mode
            rxProgress = 0
            rxStatus = L("Odbiór: {1}", mode.name)
        case .progress(let image, let progress):
            rxImage = image
            rxProgress = progress
        case .finished(let image, let mode, let complete):
            rxImage = image
            receiving = false
            rxProgress = complete ? 1 : rxProgress
            rxStatus = complete ? L("Odebrano: {1}", mode.name) : L("Odebrano część obrazu: {1} (sygnał zanikł)", mode.name)
            if autoSave { save(image, mode: mode) }
        case .tone(let hz):
            if abs(hz - tone) > 5 { tone = hz }
        }
    }

    func stopReception() { decoder.stopReception() }

    func saveCurrent() {
        guard let rxImage, let rxMode else { return }
        save(rxImage, mode: rxMode)
    }

    private func save(_ image: CGImage, mode: SSTVMode) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        var name = formatter.string(from: Date()) + "UTC_" + mode.name.replacingOccurrences(of: " ", with: "")
        if let hz = cat?.freqA, hz > 0 { name += String(format: "_%.3fMHz", Double(hz) / 1_000_000) }
        let url = Self.folder.appendingPathComponent(name + ".png")
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            rxStatus += " · " + L("zapisano {1}", url.lastPathComponent)
            loadGallery()
        } catch {
            rxStatus += " · " + L("nie udało się zapisać: {1}", error.localizedDescription)
        }
    }

    func loadGallery() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        gallery = files
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // nazwy zaczynają się od daty
            .prefix(30)
            .map { $0 }
    }

    func openGalleryFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    // MARK: - Obraz do nadania

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        txSource = cg
        rebuildPreview()
    }

    /// Plansza testowa: pasy kolorów, gradient, znak.
    func useTestPattern() {
        let w = 640, h = 496
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * CGFloat(w) / 8, y: CGFloat(h) / 2, width: CGFloat(w) / 8 + 1, height: CGFloat(h) / 2))
        }
        let colors = [CGColor(red: 0, green: 0.2, blue: 0.6, alpha: 1), CGColor(red: 0.9, green: 0.4, blue: 0, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h) / 2))   // tylko dolna połowa
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: CGFloat(h) / 2 - 6, width: CGFloat(w), height: 6))
        txSource = ctx.makeImage()
        rebuildPreview()
    }

    /// Obraz w rozdzielczości trybu (wypełnienie z przycięciem) z nakładką: znak u góry, tekst u dołu.
    func rebuildPreview() {
        guard let source = txSource else { txPreview = nil; return }
        let mode = txMode
        let w = mode.width, h = mode.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = max(CGFloat(w) / CGFloat(source.width), CGFloat(h) / CGFloat(source.height))
        let drawW = CGFloat(source.width) * scale, drawH = CGFloat(source.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: (CGFloat(w) - drawW) / 2, y: (CGFloat(h) - drawH) / 2, width: drawW, height: drawH))

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        let call = callsign().uppercased()
        if overlayCall, !call.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(h) / 7), .foregroundColor: NSColor.white, .shadow: shadow]
            NSAttributedString(string: call, attributes: attrs)
                .draw(at: NSPoint(x: CGFloat(w) * 0.04, y: CGFloat(h) * 0.97 - CGFloat(h) / 7 * 1.2))
        }
        if !overlayText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(h) / 13), .foregroundColor: NSColor.yellow, .shadow: shadow]
            NSAttributedString(string: overlayText, attributes: attrs)
                .draw(at: NSPoint(x: CGFloat(w) * 0.04, y: CGFloat(h) * 0.04))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage(), let data = ctx.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = bytes[i * 4]; rgb[i * 3 + 1] = bytes[i * 4 + 1]; rgb[i * 3 + 2] = bytes[i * 4 + 2]
        }
        txFrame = rgb
        txPreview = image
    }

    /// Obraz odebrany - jako źródło do odesłania (np. z nakładką „Twój obraz, 595”).
    func useReceivedAsSource() {
        guard let rxImage else { return }
        txSource = rxImage
        rebuildPreview()
    }

    // MARK: - Nadawanie

    func transmit(armed: Bool) {
        guard let cat, let audio else { return }
        txMessage = nil
        txOK = false
        guard armed, cat.isConnected else {
            txMessage = L("Nadawanie wymaga połączenia z radiem i zaznaczenia „Odblokuj TX”.")
            return
        }
        guard audio.radioOut != 0 else {
            txMessage = L("Wybierz w zakładce AUDIO urządzenie „Do radia (TX)”.")
            return
        }
        let mode = txMode
        guard mode.duration + 2 <= cat.txTimeout else {
            txMessage = L("{1} trwa {2} s, a limit nadawania to {3} s - zwiększ limit w bloku TX.",
                          mode.name, Int(mode.duration.rounded()), Int(cat.txTimeout))
            return
        }
        if txFrame.count != mode.width * mode.height * 3 { rebuildPreview() }
        guard txFrame.count == mode.width * mode.height * 3 else { return }

        let rate = 48_000.0
        let samples = SSTVEncoder.encode(rgb: txFrame, mode: mode, sampleRate: rate, amplitude: Float(txLevel))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(audio.radioOut)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            txMessage = L("Audio TX: {1}", error.localizedDescription)
            return
        }
        self.engine = engine
        self.player = player
        decoder.setPaused(true)                       // nie dekodujemy własnego nadawania
        transmitting = true
        txProgress = 0
        txDuration = Double(samples.count) / rate
        cat.ptt(true)
        // chwila na przełączenie radia na nadawanie, potem obraz
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.transmitting, let player = self.player else { return }
            // koniec zgłaszany po faktycznym odtworzeniu - PTT nie utnie końcówki obrazu
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self?.finishTX(message: L("Wysłano obraz {1}", mode.name), ok: true)
                }
            }
            player.play()
            self.txStarted = Date()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickTX() }
            }
        }
    }

    private func tickTX() {
        guard transmitting else { return }
        let elapsed = Date().timeIntervalSince(txStarted)
        txProgress = min(elapsed / max(txDuration, 1), 1)
        // radio przestało nadawać (limit czasu, rozłączenie) - nie gramy dalej w próżnię
        if elapsed > 2, let cat, !cat.transmitting || !cat.isConnected {
            finishTX(message: L("Nadawanie przerwane - radio nie nadaje (limit czasu albo rozłączenie)."))
        }
    }

    func stopTX() {
        finishTX(message: L("Nadawanie zatrzymane."))
    }

    private func finishTX(message: String, ok: Bool = false) {
        guard transmitting else { return }
        txOK = ok
        transmitting = false
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        cat?.ptt(false)
        txMessage = message
        txProgress = 0
        decoder.setPaused(!rxEnabled)
    }
}

/// Trzyma moduł SSTV bez publikowania zmian - okno nie przerysowuje się przy każdej linii obrazu.
@MainActor
final class SSTVHolder: ObservableObject {
    let manager = SSTVManager()
}
