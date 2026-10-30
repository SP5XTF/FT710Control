import SwiftUI

/// Ciemny motyw panelu radiowego.
enum Theme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.055)
    static let panel = Color(red: 0.075, green: 0.085, blue: 0.10)
    static let panelInner = Color(red: 0.05, green: 0.058, blue: 0.07)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
    static let header = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.52)
    static let tx = Color(red: 0.93, green: 0.27, blue: 0.24)
    static let ok = Color(red: 0.30, green: 0.80, blue: 0.45)
}

/// Panel z nagłówkiem w kolorze akcentu.
struct RigPanel<Content: View>: View {
    let title: String?
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.header)
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                }
            }
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// Przycisk panelu: zaznaczony = podświetlona ramka i tło w kolorze akcentu.
struct RigButtonStyle: ButtonStyle {
    var selected = false
    var tint: Color = Theme.accent
    var height: CGFloat = 24
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        RigButtonBody(configuration: configuration, selected: selected, tint: tint, height: height, fontSize: fontSize)
    }

    private struct RigButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        let tint: Color
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 4)
                .background(background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? tint : Color.white.opacity(0.12)))
                .foregroundStyle(selected ? Color.white : Theme.text)
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }

        private var background: Color {
            if selected { return tint.opacity(configuration.isPressed ? 0.5 : 0.32) }
            return Color.white.opacity(configuration.isPressed ? 0.16 : 0.06)
        }
    }
}

/// Suwak z nazwą i wartością, jak na panelu radia.
struct RigSlider: View {
    let title: String
    let value: Int?
    let range: ClosedRange<Int>
    var display: ((Int) -> String)? = nil
    let onChange: (Int) -> Void

    @State private var dragging: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.header)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(
                get: { dragging ?? Double(value ?? range.lowerBound) },
                set: { newValue in
                    dragging = newValue
                    onChange(Int(newValue.rounded()))
                }),
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   onEditingChanged: { editing in if !editing { dragging = nil } })
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }

    private var valueText: String {
        guard let v = dragging.map({ Int($0.rounded()) }) ?? value else { return "–" }
        return display?(v) ?? "\(v)"
    }
}

/// Wyświetlacz VFO z trybem i znacznikami.
struct VFODisplay: View {
    let label: String
    let vfo: String                 // "A" lub "B"
    let hz: Int
    let mode: String
    let isMain: Bool
    /// Rola VFO: „RX / TX”, „RX” (przy SPLIT na VFO-A), „TX” (przy SPLIT na VFO-B) albo nil.
    let role: String?
    /// Ten VFO właśnie nadaje (czerwone oznaczenie).
    let transmitting: Bool
    let enabled: Bool
    @Binding var selection: DigitSelection?
    /// Zmiana o `steps` kroków cyfry o wadze `weight` (kółko myszy).
    let onStep: (_ weight: Int, _ steps: Int) -> Void
    /// Ustawienie częstotliwości wpisanej ręcznie.
    let onSet: (Int) -> Void
    /// Informacje pod częstotliwością (RX BW, AGC, STEP, aktywne funkcje DSP…).
    var info: [VFOTag] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.header)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.header.opacity(0.5)))
                Spacer()
                if let role {
                    Text(transmitting ? "TX" : role)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(transmitting ? .white : Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(transmitting ? Theme.tx : .clear, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(transmitting ? Theme.tx : Theme.accent.opacity(0.6)))
                }
            }
            FrequencyDigits(hz: hz, vfo: vfo, maxFontSize: isMain ? 52 : 40,
                            color: isMain ? Theme.text : Theme.dim, enabled: enabled,
                            selection: $selection, onStep: onStep)
            HStack(spacing: 6) {
                tag(mode.isEmpty ? "–" : mode)
                Spacer(minLength: 8)
                FrequencyEntryField(enabled: enabled, onSet: onSet)
                    .frame(minWidth: 70, maxWidth: 230)
            }
            if !info.isEmpty {
                // etykiety zawijają się do kolejnej linii zamiast wychodzić poza wyświetlacz
                FlowLayout(spacing: 5) {
                    ForEach(info) { item in infoTag(item) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    /// Etykieta jak w 710 Console: nazwa (bursztynowa) + wartość; funkcje włączone - wyróżnione.
    private func infoTag(_ item: VFOTag) -> some View {
        HStack(spacing: 3) {
            if !item.label.isEmpty {
                Text(item.label).foregroundStyle(Theme.header.opacity(0.85))
            }
            Text(item.value).foregroundStyle(item.highlighted ? Theme.accent : Theme.text)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(item.highlighted ? Theme.accent.opacity(0.7) : Color.white.opacity(0.12)))
        .fixedSize()
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.15)))
    }
}

/// Informacja pod częstotliwością VFO, np. „RX BW 3.00 kHz”, „AGC AUTO”, „DNR”.
struct VFOTag: Identifiable {
    let label: String
    let value: String
    var highlighted = false
    var id: String { label + "|" + value }
}

/// Układ „płynący”: elementy w wierszu, a gdy brakuje miejsca - w kolejnym (jak tekst).
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {                     // nowy wiersz
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
