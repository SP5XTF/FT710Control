import SwiftUI

/// Korektor (EQ) odsłuchu w zakładce AUDIO: gotowe ustawienia, wykres charakterystyki, 8 suwaków.
struct EqualizerView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("Korektor (EQ)"), isOn: $audio.eqEnabled)
                    .font(.callout.bold())
                Picker("", selection: $audio.eqPreset) {
                    ForEach(EQPreset.allCases.filter { $0 != .custom || audio.eqPreset == .custom }) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                responseCurve
                    .frame(width: 190, height: 70)
                Text(L("Całość ściszana o największe podbicie - korektor nie przesterowuje."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 190, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(AudioEqualizer.bands.indices, id: \.self) { index in
                    bandSlider(index)
                }
            }
            .disabled(!audio.eqEnabled)
            .opacity(audio.eqEnabled ? 1 : 0.5)
        }
    }

    private func bandSlider(_ index: Int) -> some View {
        let hz = AudioEqualizer.bands[index].hz
        return VStack(spacing: 2) {
            Text(String(format: "%+.1f", audio.eqGains[index]))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            // własny suwak pionowy - obrócony systemowy Slider macOS nie jest rysowany
            VerticalSlider(value: Binding(get: { audio.eqGains[index] },
                                          set: { audio.eqGains[index] = ($0 * 2).rounded() / 2 }),   // krok 0,5 dB
                           range: -12...12, enabled: audio.eqEnabled)
                .frame(width: 22, height: 110)
            Text(hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz))")
                .font(.system(size: 9).monospacedDigit())
        }
    }

    /// Charakterystyka całego korektora 80 Hz … 5 kHz (skala logarytmiczna), ±12 dB.
    private var responseCurve: some View {
        Canvas { context, size in
            let grid = AudioEqualizer.responseGrid
            let values = AudioEqualizer.response(audio.eqGains, at: grid)
            let y = { (db: Double) in size.height / 2 - CGFloat(max(min(db, 12), -12) / 12) * (size.height / 2 - 2) }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2))
            zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(zero, with: .color(.white.opacity(0.2)), lineWidth: 1)
            var curve = Path()
            for (i, db) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(grid.count - 1), y: y(db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(audio.eqEnabled ? Theme.accent : .gray), lineWidth: 1.5)
        }
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Suwak pionowy: ścieżka z wypełnieniem od zera, gałka przeciągana myszą,
/// podwójne kliknięcie = 0, kółko myszy = ±0,5 dB.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var enabled = true

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, knob: CGFloat = 12
            let usable = h - knob
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let zeroFraction = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = knob / 2 + usable * CGFloat(1 - fraction)
            let zeroY = knob / 2 + usable * CGFloat(1 - zeroFraction)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                Rectangle()                                         // wypełnienie od zera do wartości
                    .fill(enabled ? Theme.accent : Color.gray)
                    .frame(width: 4, height: abs(y - zeroY))
                    .offset(y: min(y, zeroY))
                    .frame(maxWidth: .infinity, alignment: .center)
                Rectangle()                                         // znacznik zera
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 12, height: 1)
                    .offset(y: zeroY)
                Circle()
                    .fill(enabled ? Color.white : Color.gray)
                    .frame(width: knob, height: knob)
                    .shadow(radius: 1)
                    .offset(y: y - knob / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard enabled else { return }
                let f = 1 - Double((drag.location.y - knob / 2) / usable)
                value = min(max(range.lowerBound + f * (range.upperBound - range.lowerBound), range.lowerBound), range.upperBound)
            })
            .onTapGesture(count: 2) { if enabled { value = 0 } }
            .background(ScrollWheelCatcher(enabled: enabled) { steps in
                value = min(max(value + 0.5 * Double(steps), range.lowerBound), range.upperBound)
            })
        }
        .help(L("Przeciągnij; podwójne kliknięcie = 0 dB; kółko myszy = ±0,5 dB"))
    }
}

/// Korektor nadawania (zakładka AUDIO): 12 pasm 60…3300 Hz, gotowe ustawienia, wykres. Mikrofon Maca
/// i mikrofon panelu zdalnego → radio (USB). Kolor TX (czerwony), żeby nie mylić z korektorem odsłuchu.
struct TXEqualizerView: View {
    @ObservedObject var audio: AudioManager

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("Korektor nadawania (TX)"), isOn: $audio.txEQEnabled)
                    .font(.callout.bold())
                Picker("", selection: $audio.txEQPreset) {
                    ForEach(TXEQPreset.allCases.filter { $0 != .custom || audio.txEQPreset == .custom }) { preset in
                        Text(preset.name).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                responseCurve
                    .frame(width: 190, height: 70)
                Text(L("Mikrofon Maca i mikrofon panelu zdalnego → radio (USB). Zmienia barwę, nie głośność - poziom ustaw MIC GAIN w radiu; w radiu zacznij od płaskiego korektora mikrofonu."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 190, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(TXEqualizer.bands.indices, id: \.self) { index in
                    bandSlider(index)
                }
            }
            .disabled(!audio.txEQEnabled)
            .opacity(audio.txEQEnabled ? 1 : 0.5)
        }
    }

    private func bandSlider(_ index: Int) -> some View {
        let hz = TXEqualizer.bands[index].hz
        return VStack(spacing: 2) {
            Text(String(format: "%+.1f", audio.txEQGains[index]))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            VerticalSlider(value: Binding(get: { audio.txEQGains[index] },
                                          set: { audio.txEQGains[index] = ($0 * 2).rounded() / 2 }),   // krok 0,5 dB
                           range: -12...12, enabled: audio.txEQEnabled)
                .frame(width: 22, height: 110)
            Text(hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz))")
                .font(.system(size: 9).monospacedDigit())
        }
    }

    /// Charakterystyka 40 Hz … 4,5 kHz (skala logarytmiczna), ±12 dB.
    private var responseCurve: some View {
        Canvas { context, size in
            let grid = TXEqualizer.responseGrid
            let values = TXEqualizer.response(audio.txEQGains, at: grid)
            let y = { (db: Double) in size.height / 2 - CGFloat(max(min(db, 12), -12) / 12) * (size.height / 2 - 2) }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2))
            zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(zero, with: .color(.white.opacity(0.2)), lineWidth: 1)
            var curve = Path()
            for (i, db) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(grid.count - 1), y: y(db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(audio.txEQEnabled ? Theme.tx : .gray), lineWidth: 1.5)
        }
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }
}
