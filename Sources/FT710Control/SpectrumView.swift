import SwiftUI
import AppKit

/// Format częstotliwości jak na wyświetlaczu radia: 14.200.000
func formatFrequency(_ hz: Int) -> String {
    String(format: "%d.%03d.%03d", hz / 1_000_000, (hz / 1_000) % 1_000, hz % 1_000)
}

/// Linia widma + waterfall dźwięku odbiornika.
struct SpectrumView: View {
    @ObservedObject var model: SpectrumModel
    let dialHz: Int
    let modeCode: String
    let receiving: Bool

    @State private var hoverX: CGFloat?

    private let traceHeight: CGFloat = 80
    private let totalHeight: CGFloat = 250

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                controls
                display
                axis
                footer
            }
            .padding(4)
        } label: {
            Text(L("Widmo audio odbiornika"))
        }
    }

    // MARK: - Sterowanie

    private var controls: some View {
        HStack(spacing: 14) {
            Picker(L("Zakres"), selection: $model.maxHz) {
                Text("3 kHz").tag(3000.0)
                Text("4 kHz").tag(4000.0)
                Text("6 kHz").tag(6000.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            HStack(spacing: 4) {
                Toggle("Auto", isOn: $model.autoFloor).font(.caption)
                    .fixedSize()
                    .help(L("Poziom tła (szumu) dobierany automatycznie - wyłącz, żeby ustawić suwakiem „Tło”"))
                Text(L("Tło")).font(.caption)
                    .fixedSize()
                Slider(value: $model.floorDB, in: -150 ... -20).frame(width: 90)
                    .disabled(model.autoFloor)
            }
            HStack(spacing: 4) {
                Text(L("Kontrast")).font(.caption)
                    .fixedSize()
                // większy zakres dB = mniejszy kontrast, więc suwak jest odwrócony
                Slider(value: Binding(get: { 120 - model.rangeDB },
                                      set: { model.rangeDB = 120 - $0 }),
                       in: 20...100).frame(width: 90)
            }
            HStack(spacing: 4) {
                Text(L("Uśrednianie")).font(.caption)
                    .fixedSize()
                Slider(value: $model.smoothing, in: 0...0.9).frame(width: 70)
            }
            Picker("Waterfall", selection: $model.rowEvery) {
                Text(L("szybko")).tag(1)
                Text(L("średnio")).tag(2)
                Text(L("wolno")).tag(4)
            }
            .fixedSize()

            Spacer(minLength: 8)
            Toggle(L("Pauza"), isOn: $model.paused)
                .fixedSize()
                .help(L("Zatrzymuje przesuwanie widma i waterfalla (do obejrzenia sygnału)"))
            Button(L("Wyczyść")) { model.clear() }
                .fixedSize()
        }
        .controlSize(.small)
    }

    // MARK: - Obraz

    private var display: some View {
        GeometryReader { geo in
            let size = geo.size
            ScopeRenderView(frames: model.frames, traceHeight: traceHeight, color: NSColor.systemTeal)
                .frame(width: size.width, height: size.height)
            .overlay(gridCanvas)
            .overlay(alignment: .topLeading) { cursor(in: size) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: totalHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var gridCanvas: some View {
        Canvas { context, size in
            for hz in ticks {
                let x = size.width * CGFloat(hz / model.maxHz)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(p, with: .color(.white.opacity(hz.truncatingRemainder(dividingBy: 1000) == 0 ? 0.22 : 0.1)),
                               lineWidth: 1)
            }
            var separator = Path()
            separator.move(to: CGPoint(x: 0, y: traceHeight))
            separator.addLine(to: CGPoint(x: size.width, y: traceHeight))
            context.stroke(separator, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cursor(in size: CGSize) -> some View {
        if let x = hoverX, size.width > 0 {
            let audioHz = Double(min(max(x / size.width, 0), 1)) * model.maxHz
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 1, height: size.height)
                    .offset(x: x)
                Text(cursorLabel(audioHz: audioHz))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .offset(x: x + 150 > size.width ? x - 150 : x + 6, y: 4)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Oś i opis

    private var axis: some View {
        GeometryReader { geo in
            ForEach(ticks.filter { $0.truncatingRemainder(dividingBy: 1000) == 0 || model.maxHz <= 3000 },
                    id: \.self) { hz in
                Text(hz == 0 ? "0" : String(format: "%.1f", hz / 1000))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(geo.size.width * CGFloat(hz / model.maxHz), 10), geo.size.width - 12),
                              y: 6)
            }
        }
        .frame(height: 12)
    }

    private var footer: some View {
        Group {
            if receiving {
                Text(L("Oś: kHz audio. Najedź na widmo, żeby zobaczyć częstotliwość RF (SSB/DATA/RTTY)."))
            } else {
                Text(L("Włącz odsłuch w sekcji Audio USB, żeby widzieć widmo (głośność można skręcić do zera)."))
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Pomocnicze

    private var ticks: [Double] {
        let step = model.maxHz <= 3000 ? 500.0 : 1000.0
        return Array(stride(from: 0.0, through: model.maxHz, by: step))
    }

    /// Dźwięk o częstotliwości f odpowiada w USB sygnałowi dial + f, w LSB dial − f.
    /// W CW zależy to od tonu (pitch), więc RF nie jest pokazywane.
    private func cursorLabel(audioHz: Double) -> String {
        let audio = String(format: "%.0f Hz", audioHz)
        guard dialHz > 0 else { return audio }
        let sign: Int
        switch modeCode {
        case "2", "C", "9": sign = 1      // USB, DATA-U, RTTY-U
        case "1", "8", "6": sign = -1     // LSB, DATA-L, RTTY-L
        default: return audio
        }
        return "\(audio) → \(formatFrequency(dialHz + sign * Int(audioHz.rounded())))"
    }
}
