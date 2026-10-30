import SwiftUI
import AppKit

/// Zaznaczona cyfra wyświetlacza częstotliwości (VFO "A" lub "B", waga cyfry w Hz).
struct DigitSelection: Equatable {
    let vfo: String
    var weight: Int
}

/// Wpisywana częstotliwość: „7.074” (MHz), „7074” (kHz), „7074000” (Hz), „7.074.000”, z jednostką lub bez.
enum FrequencyParser {
    static let validRange = 30_000...75_000_000

    static func parse(_ input: String) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        var unit: String?
        for candidate in ["mhz", "khz", "hz"] where text.hasSuffix(candidate) {
            unit = candidate
            text = String(text.dropLast(candidate.count))
            break
        }
        // Więcej niż jedna kropka (7.074.000) - kropki to separatory tysięcy, wartość w Hz.
        if text.filter({ $0 == "." }).count > 1 {
            text = text.replacingOccurrences(of: ".", with: "")
            if unit == nil { unit = "hz" }
        }
        guard let value = Double(text), value > 0 else { return nil }

        let hz: Double
        switch unit {
        case "mhz": hz = value * 1_000_000
        case "khz": hz = value * 1_000
        case "hz": hz = value
        default:
            if value < 100 { hz = value * 1_000_000 }          // 7.074 -> MHz
            else if value < 100_000 { hz = value * 1_000 }     // 7074 -> kHz
            else { hz = value }                                // 7074000 -> Hz
        }
        let result = Int(hz.rounded())
        return validRange.contains(result) ? result : nil
    }
}

/// Częstotliwość cyfra po cyfrze: kółko myszy nad cyfrą zmienia ją, kliknięcie zaznacza (do strzałek).
struct FrequencyDigits: View {
    let hz: Int
    let vfo: String
    let maxFontSize: CGFloat
    let color: Color
    let enabled: Bool
    @Binding var selection: DigitSelection?
    let onStep: (_ weight: Int, _ steps: Int) -> Void

    @State private var hovered: Int?

    var body: some View {
        let characters = Array(hz > 0 ? formatFrequency(hz) : "–.–––.–––")
        let weights = Self.weights(for: characters)
        GeometryReader { geo in
            // Czcionka o stałej szerokości znaku (~0,62 wysokości) - dopasowana do dostępnego miejsca.
            let size = min(maxFontSize, geo.size.width / (CGFloat(characters.count) * 0.62))
            HStack(spacing: 0) {
                ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                    if hz > 0, let weight = weights[index] {
                        digit(character, weight: weight, size: size)
                    } else {
                        Text(String(character))
                            .font(font(size))
                            .foregroundStyle(color)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: maxFontSize * 1.2)
    }

    private func font(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light, design: .monospaced).italic()
    }

    private func digit(_ character: Character, weight: Int, size: CGFloat) -> some View {
        let isSelected = selection == DigitSelection(vfo: vfo, weight: weight)
        return Text(String(character))
            .font(font(size))
            .foregroundStyle(isSelected ? Theme.accent : color)
            .background(hovered == weight && enabled ? Color.white.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = weight } else if hovered == weight { hovered = nil }
            }
            .onTapGesture {
                guard enabled else { return }
                selection = isSelected ? nil : DigitSelection(vfo: vfo, weight: weight)
            }
            .overlay(
                ScrollWheelCatcher(enabled: enabled) { steps in onStep(weight, steps) }
                    .allowsHitTesting(false)
            )
            .help(L("Kółko myszy: zmiana tej cyfry · kliknięcie: zaznacz i zmieniaj strzałkami ↑↓ (←→ inna cyfra, Esc koniec)"))
    }

    /// Waga każdej cyfry (1, 10, 100…) liczona od prawej; kropki nie mają wagi.
    private static func weights(for characters: [Character]) -> [Int?] {
        var result = [Int?](repeating: nil, count: characters.count)
        var weight = 1
        for index in characters.indices.reversed() where characters[index].isNumber {
            result[index] = weight
            weight *= 10
        }
        return result
    }
}

/// Pole ręcznego wpisania częstotliwości pod wyświetlaczem VFO.
struct FrequencyEntryField: View {
    let enabled: Bool
    let onSet: (Int) -> Void

    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        HStack(spacing: 6) {
            TextField("7.074 · 7074 · 7074000", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Theme.tx : Color.clear))
                .onSubmit(apply)
                .onChange(of: text) { _ in invalid = false }
            Button(L("Ustaw"), action: apply)
                .buttonStyle(RigButtonStyle(height: 22, fontSize: 11))
                .frame(width: 56)
        }
        .disabled(!enabled)
        .help(L("Częstotliwość w MHz (7.074), kHz (7074) lub Hz (7074000); można dopisać jednostkę."))
    }

    private func apply() {
        guard let hz = FrequencyParser.parse(text) else {
            invalid = !text.isEmpty
            return
        }
        onSet(hz)
        text = ""
        invalid = false
    }
}

/// Przechwytuje kółko myszy nad swoim obszarem (lokalny monitor zdarzeń - nie blokuje kliknięć).
/// Kółko w górę zawsze zwiększa częstotliwość, niezależnie od „naturalnego przewijania”.
struct ScrollWheelCatcher: NSViewRepresentable {
    var enabled: Bool
    let onSteps: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onSteps = onSteps
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onSteps = onSteps
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onSteps: ((Int) -> Void)?
        var enabled = true
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // kliknięcia przechodzą dalej

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.handle(event)
                return nil      // zdarzenie obsłużone - okno pod spodem się nie przewija
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }


        private func handle(_ event: NSEvent) {
            // Bezwładność gładzika po oderwaniu palców pomijamy - strojenie tylko „pod palcem”.
            guard event.momentumPhase == [] else { return }
            var delta = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { delta = -delta }
            if event.hasPreciseScrollingDeltas {
                // Gładzik / Magic Mouse: płynne wartości - krok co 12 punktów przesunięcia.
                accumulated += delta
                let steps = Int(accumulated / 12)
                if steps != 0 {
                    accumulated -= CGFloat(steps) * 12
                    onSteps?(steps)
                }
                if event.phase == .ended || event.phase == .cancelled { accumulated = 0 }
            } else {
                // Zwykłe kółko: każdy „ząbek” to co najmniej jeden krok.
                if delta > 0 { onSteps?(max(1, Int(delta.rounded()))) }
                if delta < 0 { onSteps?(min(-1, Int(delta.rounded()))) }
            }
        }
    }
}

/// Strzałki dla zaznaczonej cyfry (lokalny monitor klawiatury; nie działa, gdy aktywne jest pole tekstowe).
struct ArrowKeyMonitor: NSViewRepresentable {
    var active: Bool
    /// Kod klawisza; zwraca true, jeśli obsłużony.
    let onKey: (UInt16) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.active = active
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        var active = false
        var onKey: ((UInt16) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, let window = self.window, event.window === window,
                      !(window.firstResponder is NSText),                 // pisanie w polu tekstowym
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      self.onKey?(event.keyCode) == true else { return event }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

    }
}
