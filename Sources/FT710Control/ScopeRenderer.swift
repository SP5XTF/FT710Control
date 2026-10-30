import SwiftUI
import AppKit
import QuartzCore
import Combine

/// Obraz skopu (linia widma + waterfall albo widok 3D) rysowany poza SwiftUI - jeden natywny widok
/// z warstwami Core Animation, aktualizowany bezpośrednio z modelu. Nowa ramka nie wywołuje żadnego
/// przeliczania ani układu widoków SwiftUI. Widok 3D jest rysowany w tle (poza głównym wątkiem).
struct ScopeRenderView: NSViewRepresentable {
    let frames: SpectrumFrames
    let traceHeight: CGFloat
    let color: NSColor
    /// Ustawienia ekranu (skop RF): kolor i wypełnienie linii, proporcja widma, tryb 3D.
    /// Bez nich widok działa jak dotąd (widmo audio, strojenie SSTV).
    var display: DisplaySettings? = nil

    func makeNSView(context: Context) -> ScopeRenderNSView {
        ScopeRenderNSView(frames: frames, traceHeight: traceHeight, color: color, display: display)
    }

    func updateNSView(_ view: ScopeRenderNSView, context: Context) {
        view.traceHeight = traceHeight
    }
}

final class ScopeRenderNSView: NSView {
    var traceHeight: CGFloat {
        didSet { if traceHeight != oldValue { needsLayout = true } }
    }

    /// Linia widma z wypełnieniem jako bitmapa o ograniczonym rozmiarze, skalowana przez GPU - koszt rysowania
    /// nie zależy od wielkości okna (warstwy kształtu z maską rasteryzowane w pełnej rozdzielczości ekranu
    /// spowalniały skop i wodospad na pełnym ekranie).
    private let trace = CALayer()
    private var traceColor: NSColor = .systemYellow
    private var traceFillEnabled = true
    private static let maxTraceWidth = 1600
    private static let maxTraceHeight = 400
    private let waterfall = CALayer()
    private let threeD = CALayer()
    /// Skala dB (obraz w rozdzielczości ekranu, przerysowywany tylko przy zmianie zakresu albo rozmiaru).
    private let scaleLayer = CALayer()
    private var scaleKey = ""
    /// Znaczniki czasu na waterfallu: kilka warstw tekstowych przesuwanych razem z obrazem.
    private let stampLayer = CALayer()
    private var stampLabels: [CATextLayer] = []
    private var stampLines: [CALayer] = []
    private weak var frames: SpectrumFrames?
    private var fillWithPalette = false
    private var peakHoldEnabled = true
    private var dbScaleEnabled = true
    private var timeStampsEnabled = true
    /// Peak hold: szczyty opadające o `peakDecay` na ramkę (ok. 6 s od góry do dołu przy 28 kl./s).
    private var peaks: [Float] = []
    private var peakGeneration = -1
    private static let peakDecay: Float = 0.006
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private var lastTrace: [Float] = []
    private var subscriptions: Set<AnyCancellable> = []

    // Ustawienia (kopie - czytane także przy rysowaniu 3D w tle)
    private weak var settings: DisplaySettings?
    private var fraction: CGFloat?
    private var mode3D = false
    private var depth = 50
    private var height3D = 0.45
    private var tilt3D = 0.35
    private var palette: WaterfallPalette = .classic
    private var speed = 1
    private var pendingPeak: [Float] = []
    private var pendingFrames = 0

    // Widok 3D: historia linii widma (najstarsza pierwsza), rysowanie w tle
    private var history: [[Float]] = []
    private var rendering = false
    private var lastRender = Date.distantPast
    private let renderQueue = DispatchQueue(label: "ft710.scope.3d", qos: .userInitiated)

    init(frames: SpectrumFrames, traceHeight: CGFloat, color: NSColor, display: DisplaySettings?) {
        self.traceHeight = traceHeight
        self.settings = display
        self.frames = frames
        super.init(frame: .zero)
        if display == nil {
            // widmo audio i strojenie SSTV - bez nowych elementów skopu RF
            peakHoldEnabled = false
            dbScaleEnabled = false
            timeStampsEnabled = false
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        waterfall.contentsGravity = .resize               // obraz rozciągnięty na cały obszar
        waterfall.magnificationFilter = .linear
        waterfall.minificationFilter = .linear
        threeD.contentsGravity = .resize
        threeD.isHidden = true

        trace.contentsGravity = .resize
        trace.magnificationFilter = .linear
        trace.minificationFilter = .linear
        traceColor = color

        scaleLayer.contentsGravity = .resize
        scaleLayer.isHidden = true
        stampLayer.masksToBounds = true
        stampLayer.isHidden = true
        for sub in [waterfall, trace, scaleLayer, stampLayer, threeD] as [CALayer] {
            sub.actions = ["contents": NSNull(), "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(sub)
        }

        // Nowe dane prosto z modelu (wątek główny) - bez udziału SwiftUI.
        frames.$waterfall
            .sink { [weak self] image in self?.showWaterfall(image) }
            .store(in: &subscriptions)
        frames.$trace
            .sink { [weak self] values in self?.showTrace(values) }
            .store(in: &subscriptions)

        // Ustawienia ekranu: objectWillChange przychodzi przed zmianą - odczyt w następnym przebiegu pętli.
        if let display {
            applySettings(display)
            display.objectWillChange
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, let settings = self.settings else { return }
                        self.applySettings(settings)
                    }
                }
                .store(in: &subscriptions)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Kliknięcia (strojenie) i najechanie (kursor) obsługuje SwiftUI pod spodem.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func setTraceColor(_ color: NSColor) {
        traceColor = color
    }

    @MainActor
    private func applySettings(_ display: DisplaySettings) {
        setTraceColor(display.traceNSColor)
        traceFillEnabled = display.traceFill
        fraction = CGFloat(display.spectrumFraction)
        depth = Int(display.depth3D)
        height3D = display.height3D
        tilt3D = display.tilt3D
        palette = display.palette
        speed = max(1, display.speed)
        mode3D = display.mode == .threeD
        fillWithPalette = display.fillWithPalette
        peakHoldEnabled = display.peakHold
        if !peakHoldEnabled { peaks = [] }
        dbScaleEnabled = display.dbScale
        timeStampsEnabled = display.timeStamps
        scaleKey = ""                                       // skala dB - przerysuj przy najbliższej ramce
        // widoczność warstw zawsze w jednym miejscu, po ustaleniu trybu
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        threeD.isHidden = !mode3D
        waterfall.isHidden = mode3D
        trace.isHidden = mode3D
        scaleLayer.isHidden = mode3D || !dbScaleEnabled
        stampLayer.isHidden = mode3D || !timeStampsEnabled
        CATransaction.commit()
        needsLayout = true
        if mode3D { lastRender = .distantPast; render3D() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sub in [trace, waterfall, threeD, scaleLayer] as [CALayer] { sub.contentsScale = scale }
        for label in stampLabels { label.contentsScale = scale }
        scaleKey = ""
    }

    /// Wysokość obszaru linii widma: z ustawień (udział wysokości) albo stała.
    private var effectiveTraceHeight: CGFloat {
        if let fraction { return bounds.height * fraction }
        return traceHeight
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Współrzędne warstw: y w górę - linia widma na górze, waterfall pod nią.
        let traceH = min(effectiveTraceHeight, bounds.height)
        let traceRect = CGRect(x: 0, y: bounds.height - traceH, width: bounds.width, height: traceH)
        trace.frame = traceRect
        scaleLayer.frame = traceRect
        waterfall.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - traceH))
        stampLayer.frame = waterfall.frame
        threeD.frame = bounds
        CATransaction.commit()
        showTrace(lastTrace, record: false)             // przelicz linię do nowej szerokości
        if mode3D { lastRender = .distantPast; render3D() }
    }

    private func showWaterfall(_ image: CGImage?) {
        RenderStats.tick("wf")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waterfall.contents = image
        CATransaction.commit()
        updateStamps()
    }

    /// Znaczniki czasu: granice co 2…600 s (ok. 3-6 na wysokości waterfalla), przesuwane z obrazem.
    private func updateStamps() {
        guard timeStampsEnabled, !mode3D, let frames, frames.rowTimes.count > 1 else {
            if !stampLabels.isEmpty, !stampLabels.allSatisfy(\.isHidden) { hideStamps(from: 0) }
            return
        }
        let times = frames.rowTimes
        let rowH = stampLayer.bounds.height / CGFloat(max(frames.rowCount, 1))
        let visible = times[0].timeIntervalSince(times[times.count - 1]) * Double(frames.rowCount) / Double(times.count)
        let interval = [2.0, 5, 10, 15, 30, 60, 120, 300, 600].first { visible / $0 <= 6 } ?? 600
        var marks: [(y: CGFloat, time: Date)] = []
        for i in 1..<times.count {
            let newer = (times[i - 1].timeIntervalSince1970 / interval).rounded(.down)
            let older = (times[i].timeIntervalSince1970 / interval).rounded(.down)
            if newer != older {
                marks.append((stampLayer.bounds.height - CGFloat(i) * rowH, Date(timeIntervalSince1970: newer * interval)))
                if marks.count >= 8 { break }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        while stampLabels.count < marks.count {
            let line = CALayer()
            line.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
            let label = CATextLayer()
            label.font = SafeFont.make(["Menlo-Regular", "Monaco"], size: 10)
            label.fontSize = 10
            label.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            label.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            label.cornerRadius = 3
            label.alignmentMode = .center
            label.contentsScale = scale
            for sub in [line, label] as [CALayer] {
                sub.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                stampLayer.addSublayer(sub)
            }
            stampLines.append(line)
            stampLabels.append(label)
        }
        for (k, mark) in marks.enumerated() {
            stampLines[k].frame = CGRect(x: 0, y: mark.y, width: stampLayer.bounds.width, height: 1)
            stampLabels[k].string = Self.stampFormatter.string(from: mark.time)
            stampLabels[k].frame = CGRect(x: 4, y: mark.y - 7, width: 58, height: 14)
            stampLines[k].isHidden = false
            stampLabels[k].isHidden = false
        }
        CATransaction.commit()
        hideStamps(from: marks.count)
    }

    private func hideStamps(from index: Int) {
        guard index < stampLabels.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for k in index..<stampLabels.count {
            stampLabels[k].isHidden = true
            stampLines[k].isHidden = true
        }
        CATransaction.commit()
    }

    /// Skala dB z lewej strony widma: 0 dB = góra skali, kreski co 10 dB (względnie - radio nie podaje dBm).
    private func updateScale() {
        guard dbScaleEnabled, !mode3D, let frames else { return }
        let size = scaleLayer.bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(Int(size.width))x\(Int(size.height))@\(scale)-\(Int(frames.rangeDB))"
        guard key != scaleKey, size.width > 20, size.height > 20 else { return }
        scaleKey = key
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let range = CGFloat(frames.rangeDB)
        let attributes: [NSAttributedString.Key: Any] = [.font: SafeFont.make(["Menlo-Regular", "Monaco"], size: 9),
                                                         .foregroundColor: NSColor(white: 1, alpha: 0.55)]
        var level: CGFloat = 0
        while level < range {
            let y = (1 - level / range) * (size.height - 2) + 1
            if y > 10 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(level == 0 ? 0 : 0.08).cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [3, 4])
                context.move(to: CGPoint(x: 34, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                context.strokePath()
                let text = NSAttributedString(string: level == 0 ? "0 dB" : "-\(Int(level))", attributes: attributes)
                text.draw(at: CGPoint(x: 4, y: min(y - 5, size.height - 12)))
            }
            level += 10
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scaleLayer.contents = image
        CATransaction.commit()
    }

    private func showTrace(_ values: [Float], record: Bool = true) {
        lastTrace = values
        if record, settings != nil, values.count > 1 {
            // historia do widoku 3D (zbierana także w 2D - przełączenie pokazuje od razu pełny obraz)
            // nowa linia co `speed` ramek - jako maksimum z ramek pośrednich (krótkie sygnały nie giną)
            let reduced = Self.decimate(values, to: 320)
            if pendingPeak.count != reduced.count { pendingPeak = reduced } else {
                for k in 0..<reduced.count { pendingPeak[k] = max(pendingPeak[k], reduced[k]) }
            }
            pendingFrames += 1
            if pendingFrames >= speed {
                history.append(pendingPeak)
                if history.count > 100 { history.removeFirst(history.count - 100) }
                pendingPeak = []
                pendingFrames = 0
                if mode3D { render3D() }
            }
        }
        if mode3D { return }
        let size = trace.bounds.size
        guard values.count > 1, size.width > 0, size.height > 0 else {
            trace.contents = nil
            return
        }
        RenderStats.tick("linia")
        // peak hold: tylko przy nowej ramce (nie przy przeliczeniu po zmianie rozmiaru)
        if peakHoldEnabled, record, let frames {
            if frames.generation != peakGeneration || peaks.count != values.count {
                peaks = values
                peakGeneration = frames.generation
            } else {
                for i in values.indices { peaks[i] = max(values[i], peaks[i] - Self.peakDecay) }
            }
        }
        let scale = window?.backingScaleFactor ?? 2
        let width = max(2, min(Int(size.width * scale), Self.maxTraceWidth))
        let height = max(2, min(Int(size.height * scale), Self.maxTraceHeight))
        guard let image = Self.renderTrace(values, width: width, height: height, color: traceColor, fill: traceFillEnabled,
                                           // grubość linii na ekranie ok. 1,2 pt niezależnie od skalowania bitmapy
                                           lineWidth: 1.2 * scale * CGFloat(width) / (size.width * scale),
                                           fillStops: fillWithPalette ? palette.stops : nil,
                                           peaks: peakHoldEnabled && peaks.count == values.count ? peaks : nil) else { return }
        updateScale()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trace.contents = image
        CATransaction.commit()
    }

    /// Linia widma z wypełnieniem (gradient: jaśniej przy linii) w bitmapie width × height (y w górę).
    static func renderTrace(_ values: [Float], width: Int, height: Int, color: NSColor, fill: Bool,
                            lineWidth: CGFloat, fillStops: [(t: Double, r: Double, g: Double, b: Double)]? = nil,
                            peaks: [Float]? = nil) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let points = values.count > width ? decimate(values, to: width) : values
        let w = CGFloat(width), h = CGFloat(height)
        let step = w / CGFloat(max(points.count - 1, 1))
        let line = CGMutablePath()
        for (i, v) in points.enumerated() {
            let point = CGPoint(x: CGFloat(i) * step, y: CGFloat(max(0, min(1, v))) * (h - 2) + 1)
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        if fill {
            let area = CGMutablePath()
            area.addPath(line)
            area.addLine(to: CGPoint(x: w, y: 0))
            area.addLine(to: CGPoint(x: 0, y: 0))
            area.closeSubpath()
            context.saveGState()
            context.addPath(area)
            context.clip()
            if let fillStops {
                // kolory palety waterfalla według poziomu: dół = tło, góra = najsilniejsze sygnały
                let colors = fillStops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 0.9) }
                let locations = fillStops.map { CGFloat($0.t) }
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                             locations: locations) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
                }
            } else if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                colors: [color.withAlphaComponent(0.45).cgColor, color.withAlphaComponent(0.05).cgColor] as CFArray,
                                                locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
            }
            context.restoreGState()
        }
        if let peaks, peaks.count > 1 {
            // peak hold: cienka, jasna linia szczytów (pod linią bieżącą)
            let peakPoints = peaks.count > width ? decimate(peaks, to: width) : peaks
            let peakStep = w / CGFloat(max(peakPoints.count - 1, 1))
            let peakLine = CGMutablePath()
            for (i, v) in peakPoints.enumerated() {
                let point = CGPoint(x: CGFloat(i) * peakStep, y: CGFloat(max(0, min(1, v))) * (h - 2) + 1)
                if i == 0 { peakLine.move(to: point) } else { peakLine.addLine(to: point) }
            }
            context.addPath(peakLine)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(max(1, lineWidth * 0.8))
            context.strokePath()
        }
        context.addPath(line)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(1, lineWidth))
        context.setLineJoin(.round)
        context.strokePath()
        return context.makeImage()
    }

    /// Zmniejszenie liczby punktów z zachowaniem szczytów (maksimum w przedziale).
    private static func decimate(_ values: [Float], to count: Int) -> [Float] {
        guard values.count > count else { return values }
        let ratio = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let a = Int(Double(i) * ratio), b = max(Int(Double(i + 1) * ratio), a + 1)
            return values[a..<min(b, values.count)].max() ?? 0
        }
    }

    // MARK: - Widok 3D

    /// Najwyżej ~15 klatek/s; gdy poprzednia klatka jeszcze się rysuje, kolejna jest pomijana.
    private func render3D() {
        guard !rendering, Date().timeIntervalSince(lastRender) > 0.066, !history.isEmpty else { return }
        let size = bounds.size
        guard size.width > 10, size.height > 10 else { return }
        let scale = min(window?.backingScaleFactor ?? 1, 2)
        var width = Int(size.width * scale), height = Int(size.height * scale)
        if width > 1000 {                                  // ograniczenie kosztu rysowania
            height = height * 1000 / width
            width = 1000
        }
        let lines = Array(history.suffix(max(depth, 2)))
        let palette = self.palette, heightFrac = height3D, tilt = tilt3D
        rendering = true
        lastRender = Date()
        renderQueue.async { [weak self] in
            let image = Scope3D.render(lines: lines, width: width, height: height,
                                       palette: palette, heightFraction: heightFrac, tilt: tilt)
            DispatchQueue.main.async {
                guard let self else { return }
                RenderStats.tick("wf")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.threeD.contents = image
                CATransaction.commit()
                self.rendering = false
            }
        }
    }
}

/// Rysowanie widoku 3D: linie widma ułożone w głąb (najstarsza z tyłu), z perspektywą.
/// Każdy „grzbiet” jest wypełniony gradientem palety (kolor zależy od wysokości sygnału),
/// bliższe linie zasłaniają dalsze, dalsze są przyciemnione i zwężone.
enum Scope3D {
    static func render(lines: [[Float]], width: Int, height: Int,
                       palette: WaterfallPalette, heightFraction: Double, tilt: Double) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let n = lines.count
        guard n > 0 else { return ctx.makeImage() }

        // Gradient z palety od poziomu szumu (0,2) do szczytu (1,0) - tło szumu nie jest czarne.
        let samples = 9
        var colors: [CGColor] = [], locations: [CGFloat] = []
        for i in 0..<samples {
            let t = Double(i) / Double(samples - 1)
            let c = palette.color(at: 0.2 + 0.8 * t)
            colors.append(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
            locations.append(CGFloat(t))
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return nil }
        let edge = palette.color(at: 0.9)
        let w = Double(width), h = Double(height)
        let cx = w / 2
        let peak = h * heightFraction
        let frontBase = h * 0.04
        let depthSpan = max(h * 0.94 - peak - frontBase, h * 0.1)

        ctx.setLineJoin(.round)
        for (i, line) in lines.enumerated() {
            let m = line.count
            guard m > 1 else { continue }
            let d = n > 1 ? 1 - Double(i) / Double(n - 1) : 0      // 1 = najdalej, 0 = najbliżej
            let base = frontBase + d * depthSpan
            let widthScale = 1 - tilt * d
            let amp = peak * (1 - 0.4 * tilt * d)
            let left = cx - cx * widthScale, right = cx + cx * widthScale

            let ridge = CGMutablePath()
            for k in 0..<m {
                let x = cx + (Double(k) / Double(m - 1) * w - cx) * widthScale
                let y = base + Double(line[k]) * amp
                if k == 0 { ridge.move(to: CGPoint(x: x, y: y)) } else { ridge.addLine(to: CGPoint(x: x, y: y)) }
            }
            let area = CGMutablePath()
            area.move(to: CGPoint(x: left, y: base))
            area.addPath(ridge)
            area.addLine(to: CGPoint(x: right, y: base))
            area.closeSubpath()

            // zasłonięcie dalszych linii
            ctx.addPath(area)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            // wypełnienie gradientem palety, dalsze linie ciemniejsze
            ctx.saveGState()
            ctx.addPath(area)
            ctx.clip()
            ctx.setAlpha(CGFloat(1 - 0.6 * d))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: base), end: CGPoint(x: 0, y: base + amp), options: [])
            ctx.restoreGState()
            // krawędź grzbietu
            ctx.addPath(ridge)
            // krawędź delikatna - jaskrawa tworzyłaby „ziarno” na szumie
            ctx.setStrokeColor(CGColor(red: edge.r, green: edge.g, blue: edge.b, alpha: CGFloat(0.4 - 0.3 * d)))
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
