import Foundation
import SwiftUI

/// Język interfejsu. Wybór jest zapamiętywany; domyślnie język systemu (polski albo angielski).
enum AppLanguage: String, CaseIterable, Identifiable {
    case pl, en

    var id: String { rawValue }
    var displayName: String { self == .pl ? "Polski" : "English" }

    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: storageKey), let language = AppLanguage(rawValue: saved) {
            return language
        }
        let system = Locale.preferredLanguages.first ?? "en"
        return system.hasPrefix("pl") ? .pl : .en
    }
}

/// Tekst interfejsu. Kluczem jest tekst polski (tak jak w kodzie); dla angielskiego zwracany jest
/// odpowiednik ze słownika `englishStrings` (brak wpisu = tekst polski, więc nic nie znika).
func L(_ polish: String) -> String {
    guard AppLanguage.current == .en else { return polish }
    return englishStrings[polish] ?? polish
}

/// Tekst z wartościami: miejsca {1}, {2}… w szablonie zastępowane kolejnymi argumentami.
/// Numeracja pozwala zmienić kolejność wartości w tłumaczeniu.
func L(_ polish: String, _ values: Any...) -> String {
    var text = L(polish)
    for (index, value) in values.enumerated() {
        text = text.replacingOccurrences(of: "{\(index + 1)}", with: "\(value)")
    }
    return text
}

/// Czy tekst statusu oznacza błąd (w dowolnym języku).
func isErrorStatus(_ text: String) -> Bool {
    text.hasPrefix("Błąd") || text.hasPrefix("Error")
}

/// Tekst już przetłumaczony i zapamiętany w modelu (status, komunikat błędu…) - ponownie w bieżącym języku.
/// Modele tłumaczą komunikat w chwili jego powstania; po zmianie języka w trakcie pracy gotowy tekst zostałby
/// w poprzednim języku. Lr rozpoznaje szablon ze słownika (także z wartościami {1}, {2}…, które same mogą być
/// tłumaczone) i składa tekst w bieżącym języku. Tekst spoza słownika (znaki, komunikaty FT8, adresy) - bez zmian.
/// Sprawdzone na całym słowniku: PL→EN bez niezgodności; EN→PL - poprawne formy także tam, gdzie kilka polskich
/// tekstów ma to samo tłumaczenie.
func Lr(_ shown: String) -> String {
    Retranslator.shared.translate(shown, to: AppLanguage.current)
}

final class Retranslator: @unchecked Sendable {
    static let shared = Retranslator()

    private struct Template {
        let literal: Int
        let regex: NSRegularExpression
        let order: [Int]
        let target: String
    }
    private struct Side {
        var exact: [String: String] = [:]
        var templates: [Template] = []
    }

    private let lock = NSLock()
    private var sides: [AppLanguage: Side] = [:]
    private var cache: [AppLanguage: [String: String]] = [:]

    func translate(_ text: String, to language: AppLanguage) -> String {
        guard !text.isEmpty else { return text }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[language]?[text] { return hit }
        let side = sides[language] ?? build(for: language)
        sides[language] = side
        let result = translate(text, side: side, depth: 0)
        if (cache[language]?.count ?? 0) > 2000 { cache[language] = [:] }
        cache[language, default: [:]][text] = result
        return result
    }

    private func translate(_ text: String, side: Side, depth: Int) -> String {
        if let exact = side.exact[text] { return exact }
        let range = NSRange(text.startIndex..., in: text)
        for template in side.templates {
            guard let match = template.regex.firstMatch(in: text, range: range) else { continue }
            var result = template.target
            for (i, number) in template.order.enumerated() {
                guard let r = Range(match.range(at: i + 1), in: text) else { continue }
                let value = String(text[r])
                let translated = depth < 2 ? translate(value, side: side, depth: depth + 1) : value
                result = result.replacingOccurrences(of: "{\(number)}", with: translated)
            }
            return result
        }
        return text
    }

    /// Słownik w kierunku do `language`: z polskiego na angielski albo z angielskiego na polski.
    private func build(for language: AppLanguage) -> Side {
        var side = Side()
        let pairs: [(source: String, target: String)] = language == .en
            ? englishStrings.map { ($0.key, $0.value) }
            : englishStrings.map { ($0.value, $0.key) }
        let placeholder = try? NSRegularExpression(pattern: "\\{(\\d+)\\}")
        for (source, target) in pairs {
            let whole = NSRange(source.startIndex..., in: source)
            let marks = placeholder?.matches(in: source, range: whole) ?? []
            if marks.isEmpty {
                if side.exact[source] == nil { side.exact[source] = target }
                continue
            }
            // zbyt ogólne szablony (np. „{1} · {2}”) dopasowałyby się do wszystkiego - pomijamy
            var literal = source
            for mark in marks.reversed() { if let r = Range(mark.range, in: literal) { literal.removeSubrange(r) } }
            let letters = literal.filter(\.isLetter).count
            guard letters >= 3 else { continue }
            var pattern = "^"
            var order: [Int] = []
            var cursor = source.startIndex
            for mark in marks {
                guard let r = Range(mark.range, in: source), let n = Range(mark.range(at: 1), in: source),
                      let number = Int(source[n]) else { continue }
                pattern += NSRegularExpression.escapedPattern(for: String(source[cursor..<r.lowerBound])) + "(.+?)"
                order.append(number)
                cursor = r.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "$"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                side.templates.append(Template(literal: letters, regex: regex, order: order, target: target))
            }
        }
        side.templates.sort { $0.literal > $1.literal }          // najdłuższy tekst stały - najpierw
        return side
    }
}
