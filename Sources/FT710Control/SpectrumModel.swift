import SwiftUI
import Combine
import CoreGraphics

/// Dane zmieniające się z każdą ramką (linia widma i obraz waterfalla) - w osobnym obiekcie,
/// żeby co ramkę odświeżały się tylko widoki, które je rysują, a nie cały panel z suwakami i siatką.
@MainActor
final class SpectrumFrames: ObservableObject {
    @Published fileprivate(set) var waterfall: CGImage?
    @Published fileprivate(set) var trace: [Float] = []        // 0...1 dla każdej kolumny
    /// Czas dodania każdego wiersza waterfalla (indeks 0 = najnowszy, na górze obrazu) - znaczniki czasu.
    fileprivate(set) var rowTimes: [Date] = []
    /// Liczba wierszy waterfalla (wysokość obrazu) - do położenia znaczników czasu.
    fileprivate(set) var rowCount = 240
    /// Zwiększany przy wyczyszczeniu albo przesunięciu zakresu - peak hold zaczyna od nowa.
    fileprivate(set) var generation = 0
    /// Zakres poziomów linii widma (dB od „tła” do góry) - do skali dB.
    fileprivate(set) var rangeDB: Float = 70
}

/// Linia widma i waterfall gotowe do narysowania.
/// Waterfall to bufor pierścieniowy pikseli; najnowszy wiersz jest zawsze na górze obrazu.
@MainActor
final class SpectrumModel: ObservableObject {
    /// Skop RF: natywne 850 punktów radia i dłuższa historia; widmo audio: 640 × 240.
    let columns: Int
    let rows: Int

    /// Dane ramek (obserwowane tylko przez linię widma i waterfall).
    let frames = SpectrumFrames()
    var waterfall: CGImage? { frames.waterfall }
    var trace: [Float] { frames.trace }

    @Published var maxHz: Double = 3000 { didSet { if oldValue != maxHz { clear() } } }
    @Published var floorDB: Float = -110                   // poziom „czarnego tła”
    @Published var autoFloor = true {                      // tło dopasowywane do poziomu szumu
        didSet { trackedFloor = floorDB }
    }
    /// Tło liczone przy każdej ramce w trybie Auto. Publikowane do suwaka „Tło” tylko przy zmianie
    /// o co najmniej 1 dB - inaczej cały panel odświeżałby się z każdą ramką.
    private var trackedFloor: Float = -110
    @Published var rangeDB: Float = 70                     // kontrast: ile dB od tła do bieli
    @Published var smoothing: Float = 0.6                  // uśrednianie linii widma (0 = brak)
    @Published var rowEvery: Int = 1                       // 1 = najszybszy waterfall
    @Published var paused = false

    /// Poziomy 0…255 (kolor nadaje paleta przy tworzeniu obrazu - zmiana palety działa na całą historię).
    private var levels: [UInt8]
    /// Kolory pikseli (z palety) - przeliczane tylko dla nowej linii; całość tylko przy zmianie palety.
    private var pixels: [UInt32]
    private var newestRow = 0
    private var frameCounter = 0
    /// Maksimum z linii pominiętych przy wolnym przesuwie - krótki sygnał nie znika z waterfalla.
    private var rowPeak: [Float] = []
    private var smoothed: [Float] = []
    private var lookup: [UInt32] = WaterfallPalette.classic.lookupTable()
    /// Paleta waterfalla (z zakładki EKRAN); zmiana przemalowuje od razu cały obraz.
    var palette: WaterfallPalette = .classic {
        didSet {
            guard palette != oldValue else { return }
            lookup = palette.lookupTable()
            for i in levels.indices { pixels[i] = lookup[Int(levels[i])] }   // raz, przy zmianie palety
            frames.waterfall = makeImage()
        }
    }
    enum PaletteRole { case rf, audio }
    private var paletteSubscription: AnyCancellable?
    private var speedSubscription: AnyCancellable?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(role: PaletteRole = .rf) {
        columns = role == .rf ? 850 : 640
        rows = role == .rf ? 320 : 240
        levels = [UInt8](repeating: 0, count: columns * rows)
        pixels = [UInt32](repeating: 0xFF00_0000, count: columns * rows)
        frames.rowCount = rows
        frames.waterfall = makeImage()
        // Paleta z ustawień ekranu: skop RF zawsze, widmo audio - gdy włączone „ta sama paleta”.
        let display = DisplaySettings.shared
        paletteSubscription = display.$palette.combineLatest(display.$audioSamePalette)
            .sink { [weak self] palette, same in
                let wanted = (role == .rf || same) ? palette : .classic
                // poza bieżącą aktualizacją widoku (zmiana palety publikuje nowy obraz waterfalla)
                DispatchQueue.main.async { if self?.palette != wanted { self?.palette = wanted } }
            }
        if role == .rf {
            // tylko faktyczna zmiana, i nie w trakcie budowania widoku (subskrypcja startuje przy tworzeniu skopu)
            speedSubscription = display.$speed.removeDuplicates().sink { [weak self] speed in
                DispatchQueue.main.async { if self?.rowEvery != speed { self?.rowEvery = speed } }
            }
        }
    }

    func clear() {
        for i in levels.indices { levels[i] = 0 }
        let black = lookup[0]
        for i in pixels.indices { pixels[i] = black }
        smoothed = []
        frames.trace = []
        frameCounter = 0
        rowPeak = []
        frames.rowTimes = []
        frames.generation += 1
        frames.waterfall = makeImage()
    }

    /// Przesunięcie zakresu (strojenie w trybie CENTER) - stare szczyty peak hold nie pasują do nowej osi.
    func rangeShifted() {
        frames.generation += 1
    }

    /// Nowa ramka FFT: dBFS dla binów 0..<N/2.
    func ingest(db: [Float], sampleRate: Double) {
        guard !paused, db.count > 1, sampleRate > 0 else { return }

        let binHz = sampleRate / Double(db.count * 2)
        let columnHz = maxHz / Double(columns)
        let lastBin = db.count - 1

        // Kolumna = maksimum z binów, które obejmuje (żeby wąskie sygnały CW nie znikały).
        var line = [Float](repeating: floorDB, count: columns)
        for c in 0..<columns {
            let lo = max(1, Int(Double(c) * columnHz / binHz))
            let hi = min(lastBin, max(lo, Int(Double(c + 1) * columnHz / binHz)))
            guard lo <= hi else { continue }
            var peak = db[lo]
            if hi > lo {
                for b in (lo + 1)...hi where db[b] > peak { peak = db[b] }
            }
            line[c] = peak
        }

        commit(line)
    }

    /// Linia widma już w dB na równej siatce częstotliwości (np. skop RF radia, 850 punktów).
    /// Przeskalowana do `columns` - kolumna bierze maksimum z punktów, które obejmuje.
    func ingest(line source: [Float]) {
        RenderStats.tick("ramki")
        guard !paused, !source.isEmpty else { return }
        var line = [Float](repeating: floorDB, count: columns)
        let ratio = Double(source.count) / Double(columns)
        for c in 0..<columns {
            let lo = min(Int(Double(c) * ratio), source.count - 1)
            let hi = min(max(lo, Int(Double(c + 1) * ratio) - 1), source.count - 1)
            var peak = source[lo]
            if hi > lo {
                for i in (lo + 1)...hi where source[i] > peak { peak = source[i] }
            }
            line[c] = peak
        }
        commit(line)
    }

    private func commit(_ line: [Float]) {
        if autoFloor { trackNoiseFloor(line) }

        if smoothed.count != columns { smoothed = line }
        let a = min(max(smoothing, 0), 0.95)
        for c in 0..<columns {
            smoothed[c] = a * smoothed[c] + (1 - a) * line[c]
        }
        frames.rangeDB = max(rangeDB, 1)
        frames.trace = smoothed.map(normalize)

        if rowPeak.count != columns { rowPeak = line } else {
            for c in 0..<columns { rowPeak[c] = max(rowPeak[c], line[c]) }
        }
        frameCounter += 1
        guard frameCounter % max(1, rowEvery) == 0 else { return }

        newestRow = (newestRow - 1 + rows) % rows
        let base = newestRow * columns
        for c in 0..<columns {
            let level = UInt8(normalize(rowPeak[c]) * 255)
            levels[base + c] = level
            pixels[base + c] = lookup[Int(level)]           // tylko nowa linia (640 pikseli)
        }
        rowPeak = []                                   // od nowa dla kolejnej linii waterfalla
        frames.rowTimes.insert(Date(), at: 0)          // czas wiersza - znaczniki czasu na waterfallu
        if frames.rowTimes.count > rows { frames.rowTimes.removeLast(frames.rowTimes.count - rows) }
        frames.waterfall = makeImage()
    }

    /// Szum pasma ma wypadać ciemnoniebiesko (ok. 25% skali), żeby sygnały miały zapas jasności.
    /// Poziom szumu = 40. percentyl kolumn: odporny na pojedyncze silne sygnały
    /// i na pasmo zaporowe filtra radia (część widma powyżej szerokości filtra).
    private func trackNoiseFloor(_ line: [Float]) {
        let sorted = line.sorted()
        let noise = sorted[Int(Double(sorted.count - 1) * 0.4)]
        let target = noise - 0.25 * max(rangeDB, 1)
        let error = target - trackedFloor
        // duży błąd (start, zmiana głośności w radiu) - skok; mały - powolne dociąganie
        trackedFloor = abs(error) > 15 ? target : trackedFloor + 0.05 * error
        if abs(trackedFloor - floorDB) >= 1 { floorDB = trackedFloor }
    }

    /// Tło użyte do rysowania: w trybie Auto liczone na bieżąco, w ręcznym - z suwaka.
    private var effectiveFloor: Float { autoFloor ? trackedFloor : floorDB }

    private func normalize(_ value: Float) -> Float {
        min(max((value - effectiveFloor) / max(rangeDB, 1), 0), 1)
    }

    private func makeImage() -> CGImage? {
        // Najnowszy wiersz na górze; kolory z tablicy palety.
        // Najnowszy wiersz na górze: dwa bloki pamięci, bez pętli po pikselach (główny wątek, 27 kl./s).
        let split = newestRow * columns
        var ordered = [UInt32]()
        ordered.reserveCapacity(pixels.count)
        ordered.append(contentsOf: pixels[split...])
        ordered.append(contentsOf: pixels[..<split])

        let data = ordered.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // Piksel = 0xAARRGGBB w słowie 32-bit little-endian.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: columns, height: rows,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: colorSpace, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

}
