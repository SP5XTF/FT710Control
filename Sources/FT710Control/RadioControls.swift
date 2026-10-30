import Foundation

/// Ustawienia radia sterowane z panelu (komendy CAT Yaesu, rodzina FTDX10/FT-710).
///
/// Każde ustawienie jest po połączeniu odpytywane. Odpowiedź radia oznacza je jako obsługiwane;
/// jeśli radio nie odpowie (np. odrzuci komendę „?;”), kontrolka zostaje wyłączona,
/// zamiast udawać, że działa. Dzięki temu ewentualna różnica w składni CAT jest od razu widoczna.
enum RadioControl: String, CaseIterable, Hashable {
    case afGain, rfGain, squelch, power, micGain, procLevel, nbLevel, nrLevel
    case preamp, attenuator, agc, noiseBlanker, noiseReduction, notchAuto, processor, tuner
    /// Filtr odbiornika: szerokość (indeks), przesunięcie IF, ręczny notch, contour.
    case width, ifShift, notch, notchFreq, contour, contourFreq
    /// Praca z rozstawem: odbiór na VFO-A, nadawanie na VFO-B.
    case split
    /// Poziom AMC (automatyczna kontrola mocy wyjściowej/ALC).
    case amc
    /// Prędkość klucza elektronicznego radia (KS, 4-60 WPM).
    case keySpeed

    /// Prefiks odpowiedzi (i komendy) - po nim następuje wartość liczbowa.
    var prefix: String {
        switch self {
        case .afGain: return "AG0"
        case .rfGain: return "RG0"
        case .squelch: return "SQ0"
        case .power: return "PC"
        case .micGain: return "MG"
        case .procLevel: return "PL"
        case .nbLevel: return "NL0"
        case .nrLevel: return "RL0"
        case .preamp: return "PA0"
        case .attenuator: return "RA0"
        case .agc: return "GT0"
        case .noiseBlanker: return "NB0"
        case .noiseReduction: return "NR0"
        case .notchAuto: return "BC0"
        case .processor: return "PR0"
        case .tuner: return "AC"
        case .width: return "SH00"
        case .ifShift: return "IS00"
        case .notch: return "BP00"
        case .notchFreq: return "BP01"
        case .contour: return "CO00"
        case .contourFreq: return "CO01"
        case .split: return "ST"
        case .amc: return "AO"
        case .keySpeed: return "KS"
        }
    }

    /// Wartość ze znakiem (+/-), np. przesunięcie IF.
    var signed: Bool { self == .ifShift }

    /// Liczba cyfr wartości w komendzie ustawiającej.
    var digits: Int {
        switch self {
        case .afGain, .rfGain, .squelch, .power, .micGain, .procLevel, .nbLevel, .tuner: return 3
        case .nrLevel: return 2
        case .preamp, .attenuator, .agc, .noiseBlanker, .noiseReduction, .notchAuto, .processor: return 1
        case .width: return 2
        case .notch, .notchFreq: return 3
        case .contour, .contourFreq, .ifShift: return 4
        case .split: return 1
        case .amc: return 3
        case .keySpeed: return 3
        }
    }

    /// Dopuszczalny zakres ustawianej wartości.
    var range: ClosedRange<Int> {
        switch self {
        case .afGain, .rfGain: return 0...255
        case .squelch, .micGain, .procLevel: return 0...100
        case .power: return 5...100
        case .nbLevel: return 0...10
        case .nrLevel: return 1...15
        case .preamp: return 0...2
        case .attenuator: return 0...3
        case .agc: return 0...4
        case .noiseBlanker, .noiseReduction, .notchAuto, .processor: return 0...1
        case .tuner: return 0...2
        case .width: return 0...23
        case .ifShift: return -1200...1200
        case .notch, .contour: return 0...1
        case .notchFreq: return 1...320            // ×10 Hz
        case .contourFreq: return 10...3200        // Hz
        case .split: return 0...1
        case .amc: return 1...100
        case .keySpeed: return 4...60
        }
    }

    /// Komenda odczytu. Dla filtra odczyt jest krótszy niż prefiks odpowiedzi (np. „SH0;” -> „SH00nn”).
    var query: String {
        switch self {
        case .width: return "SH0;"
        case .ifShift: return "IS0;"
        default: return prefix + ";"
        }
    }

    func setCommand(_ value: Int) -> String {
        let v = min(max(value, range.lowerBound), range.upperBound)
        if signed {
            return prefix + String(format: "%+0\(digits + 1)d", v) + ";"     // np. IS00+0100;
        }
        return prefix + String(format: "%0\(digits)d", v) + ";"
    }

    /// Dopasowanie odpowiedzi radia (bez średnika) do ustawienia. Najdłuższe prefiksy najpierw,
    /// żeby np. „PA0” nie pomylić z innymi komendami zaczynającymi się od „P”.
    static func match(_ token: String) -> (RadioControl, Int)? {
        for control in byPrefixLength where token.hasPrefix(control.prefix) {
            let rest = token.dropFirst(control.prefix.count)
            let digits = control.signed && (rest.first == "+" || rest.first == "-") ? rest.dropFirst() : rest
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(rest) else { return nil }
            return (control, value)
        }
        return nil
    }

    private static let byPrefixLength = allCases.sorted { $0.prefix.count > $1.prefix.count }
}
