import SwiftUI
import AppKit

/// Sprawdzanie nowej wersji w wydaniach GitHub (github.com/sp5xtf/FT710Control/releases, także beta).
/// Przy starcie (po chwili) i raz na dobę; ręcznie: menu programu → „Sprawdź aktualizacje…”.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "sp5xtf/FT710Control"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// Nowsza wersja niż uruchomiona (nil - brak albo jeszcze nie sprawdzono).
    @Published private(set) var available: Release?
    private var started = false

    func startAutomatic() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)          // po starcie programu, bez pośpiechu
            while !Task.isCancelled {
                let last = UserDefaults.standard.object(forKey: "update.lastCheck") as? Date ?? .distantPast
                if Date().timeIntervalSince(last) > 23 * 3600 { _ = await check() }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    /// Ręcznie z menu: wynik w oknie.
    func checkManually() {
        Task { @MainActor in
            let message = await check()
            let alert = NSAlert()
            alert.messageText = L("Aktualizacje")
            alert.informativeText = message
            if available != nil {
                alert.addButton(withTitle: L("Pobierz"))
                alert.addButton(withTitle: L("Później"))
                if alert.runModal() == .alertFirstButtonReturn, let url = available?.url { NSWorkspace.shared.open(url) }
            } else {
                alert.runModal()
            }
        }
    }

    /// Pobiera listę wydań (także beta) i zapamiętuje najnowsze, jeśli nowsze od uruchomionej wersji.
    @discardableResult
    func check() async -> String {
        UserDefaults.standard.set(Date(), forKey: "update.lastCheck")
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=20") else { return "" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FT710Control/" + ADIF.programVersion, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return L("Nie udało się sprawdzić aktualizacji (brak połączenia z GitHub).")
        }
        let releases = list.compactMap { item -> Release? in
            guard (item["draft"] as? Bool) != true, let tag = item["tag_name"] as? String,
                  let page = (item["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Release(version: Self.clean(tag), url: page)
        }
        let newest = releases.max { Self.isNewer($1.version, than: $0.version) }
        if let newest, Self.isNewer(newest.version, than: ADIF.programVersion) {
            available = newest
            return L("Dostępna jest nowa wersja {1} (uruchomiona: {2}).", newest.version, ADIF.programVersion)
        }
        available = nil
        return L("Masz najnowszą wersję ({1}).", ADIF.programVersion)
    }

    /// „v0.9.1-beta” → „0.9.1-beta”.
    static func clean(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Porównanie wersji: liczby kolejno (0.9.1 > 0.9.0), przy równych - wydanie bez dopisku nowsze niż
    /// beta (0.9.1 > 0.9.1-beta), dopiski porównywane z liczbami (beta.2 > beta.1).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func split(_ v: String) -> (numbers: [Int], suffix: String) {
            let parts = clean(v).split(separator: "-", maxSplits: 1).map(String.init)
            var numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            while numbers.count < 3 { numbers.append(0) }
            return (numbers, parts.count > 1 ? parts[1] : "")
        }
        let a = split(remote), b = split(local)
        for (x, y) in zip(a.numbers, b.numbers) where x != y { return x > y }
        if a.numbers.count != b.numbers.count { return a.numbers.count > b.numbers.count }
        switch (a.suffix.isEmpty, b.suffix.isEmpty) {
        case (true, false): return true                                // wydanie > beta tej samej wersji
        case (false, true): return false
        case (true, true): return false
        case (false, false): return a.suffix.compare(b.suffix, options: .numeric) == .orderedDescending
        }
    }
}

/// Pasek stanu: przycisk „Nowa wersja …”, gdy na GitHubie jest nowsze wydanie.
struct UpdateBadge: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        if let release = updates.available {
            Button { NSWorkspace.shared.open(release.url) } label: {
                Text(L("Nowa wersja {1}", release.version)).font(.caption.bold()).foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help(L("Otwiera stronę wydania na GitHub (pobranie DMG)"))
        }
    }
}

/// Menu programu: „Sprawdź aktualizacje…”.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Sprawdź aktualizacje…")) { UpdateChecker.shared.checkManually() }
        }
    }
}
