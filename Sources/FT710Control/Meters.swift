import SwiftUI

/// Przeliczanie surowych odczytów mierników radia (0–255) na jednostki fizyczne.
/// UWAGA: poniższe tabele to wartości startowe, typowe dla radiotelefonów Yaesu,
/// a nie kalibracja konkretnego FT-710. Surowa wartość jest zawsze widoczna obok
/// miernika, więc tabelę można poprawić po porównaniu z wyświetlaczem radia.
enum MeterCalibration {
    struct Point {
        let raw: Double
        let value: Double
    }

    /// S-metr: odczyt -> dB względem S9 (S9 = 0 dB).
    static let sMeterDB: [Point] = [
        Point(raw: 0, value: -54), Point(raw: 12, value: -48), Point(raw: 27, value: -42),
        Point(raw: 40, value: -36), Point(raw: 55, value: -30), Point(raw: 65, value: -24),
        Point(raw: 80, value: -18), Point(raw: 95, value: -12), Point(raw: 112, value: -6),
        Point(raw: 130, value: 0), Point(raw: 150, value: 10), Point(raw: 172, value: 20),
        Point(raw: 190, value: 30), Point(raw: 220, value: 40), Point(raw: 240, value: 50),
        Point(raw: 255, value: 60)
    ]

    /// Odczyt, przy którym S-metr pokazuje S9 (znacznik na pasku).

    /// Moc wyjściowa (PO): odczyt -> waty (radio 100 W).
    static let powerWatts: [Point] = [
        Point(raw: 0, value: 0), Point(raw: 10, value: 0.8), Point(raw: 50, value: 8),
        Point(raw: 100, value: 26), Point(raw: 150, value: 54), Point(raw: 200, value: 92),
        Point(raw: 250, value: 100)
    ]

    /// SWR: odczyt -> wartość SWR.
    static let swr: [Point] = [
        Point(raw: 0, value: 1.0), Point(raw: 26, value: 1.5), Point(raw: 52, value: 2.0),
        Point(raw: 89, value: 3.0), Point(raw: 126, value: 4.0), Point(raw: 228, value: 25.0),
        Point(raw: 255, value: 25.0)
    ]

    /// Interpolacja liniowa po tabeli punktów.
    static func interpolate(_ raw: Int, _ table: [Point]) -> Double {
        let x = Double(raw)
        guard let first = table.first, let last = table.last else { return 0 }
        if x <= first.raw { return first.value }
        if x >= last.raw { return last.value }
        for i in 1..<table.count {
            let a = table[i - 1], b = table[i]
            if x <= b.raw {
                let t = (x - a.raw) / (b.raw - a.raw)
                return a.value + t * (b.value - a.value)
            }
        }
        return last.value
    }

    static func sMeterText(raw: Int) -> String {
        let db = interpolate(raw, sMeterDB)
        if db >= 0 {
            let over = Int((db / 10).rounded()) * 10
            return over == 0 ? "S9" : "S9+\(over)"
        }
        return "S\(max(0, 9 + Int((db / 6).rounded())))"
    }

    static func powerText(raw: Int) -> String {
        String(format: "%.0f W", interpolate(raw, powerWatts))
    }

    static func swrText(raw: Int) -> String {
        let value = interpolate(raw, swr)
        return value >= 10 ? "10+" : String(format: "%.1f", value)
    }

    static func percentText(raw: Int) -> String {
        "\(Int((Double(raw) / 255 * 100).rounded()))%"
    }
}

