import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreAudio

/// Kopia ustawień programu (menu Plik) - wszystkie ustawienia użytkownika z UserDefaults, BEZ haseł (te są w pęku
/// kluczy macOS albo pomijane) i bez dziennika łączności (ma własne kopie). Plik .ft710settings (plist XML).
enum SettingsBackup {
    static let fileExtension = "ft710settings"
    static let marker = "FT710Control.settingsBackup"

    /// Ustawienia do kopii i raportu: bez haseł/tokenów i bez wewnętrznych ustawień macOS (pozycje okien itp.).
    static func isExportable(_ key: String) -> Bool {
        let lower = key.lowercased()
        if ["password", "passwd", "token", "secret", "apikey", "api_key"].contains(where: { lower.contains($0) }) { return false }
        if ["NS", "Apple", "com.apple", "WebKit", "_", "MSApp", "SU"].contains(where: { key.hasPrefix($0) }) { return false }
        return !["update.lastCheck"].contains(key)
    }

    /// Bieżące ustawienia programu (tylko domena programu, bez ustawień globalnych macOS).
    static func currentSettings() -> [String: Any] {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let all = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        return all.filter { isExportable($0.key) }
    }

    static func write(_ settings: [String: Any], to url: URL) throws {
        let file: [String: Any] = ["marker": marker, "programVersion": ADIF.programVersion, "date": Date(),
                                   "settings": settings.filter { isExportable($0.key) }]      // hasła nigdy do pliku
        let data = try PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    struct Backup {
        let settings: [String: Any]
        let programVersion: String
        let date: Date?
    }

    static func read(_ url: URL) throws -> Backup {
        let data = try Data(contentsOf: url)
        guard let file = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              file["marker"] as? String == marker, let settings = file["settings"] as? [String: Any] else {
            throw NSError(domain: "FT710Control", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("To nie jest plik ustawień FT-710 Control.")])
        }
        return Backup(settings: settings.filter { isExportable($0.key) },
                      programVersion: file["programVersion"] as? String ?? "?", date: file["date"] as? Date)
    }

    // MARK: - Menu Plik

    @MainActor
    static func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .propertyList]
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "FT710Control-\(L("ustawienia"))-\(day).\(fileExtension)"
        panel.message = L("Wszystkie ustawienia programu - bez haseł i bez dziennika łączności")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let settings = currentSettings()
        do {
            try write(settings, to: url)
            info(L("Zapisano ustawienia"),
                 L("Zapisano {1} ustawień do pliku „{2}”. Hasła (QRZ, HamQTH, Club Log, LoTW, praca zdalna) nie są w kopii - po przywróceniu na innym Macu trzeba je wpisać ponownie.",
                   settings.count, url.lastPathComponent))
        } catch {
            info(L("Nie udało się zapisać ustawień"), error.localizedDescription)
        }
    }

    @MainActor
    static func restoreWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .propertyList]
        panel.message = L("Wybierz plik ustawień FT-710 Control (.ft710settings)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup: Backup
        do { backup = try read(url) } catch {
            info(L("Nie udało się wczytać ustawień"), error.localizedDescription)
            return
        }
        let when = backup.date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "?"
        let alert = NSAlert()
        alert.messageText = L("Przywrócić ustawienia programu?")
        alert.informativeText = L("Kopia z {1} (wersja {2}), {3} ustawień. Bieżące ustawienia zostaną zastąpione - ich kopia zapisze się automatycznie w folderze programu. Hasła trzeba będzie wpisać ponownie. Program uruchomi się ponownie.",
                                  when, backup.programVersion, backup.settings.count)
        alert.addButton(withTitle: L("Przywróć i uruchom ponownie"))
        alert.addButton(withTitle: L("Anuluj"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // kopia bieżących ustawień - przywrócenie da się cofnąć
        if let folder = try? safetyFolder() {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? write(currentSettings(), to: folder.appendingPathComponent("przed-przywroceniem-\(stamp).\(fileExtension)"))
        }
        for (key, value) in backup.settings { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.synchronize()
        relaunch()
    }

    /// ~/Library/Application Support/FT710Control/Settings backups
    static func safetyFolder() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("FT710Control/Settings backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Ponowne uruchomienie (ustawienia wczytywane przy starcie); uruchomiony z Xcode - tylko zamknięcie.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
            try? task.run()
        } else {
            info(L("Ustawienia przywrócone"), L("Uruchom program ponownie, żeby wczytać przywrócone ustawienia."))
        }
        NSApp.terminate(nil)
    }

    @MainActor
    static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Obiekty stanu do raportu diagnostycznego - rejestrowane przez okno główne przy starcie (menu nie ma do nich dostępu).
@MainActor
final class DiagnosticsHub {
    static let shared = DiagnosticsHub()
    weak var cat: CATClient?
    weak var scope: RFScopeController?
    weak var audio: AudioManager?
    weak var ft8: FT8Manager?
    weak var remote: RemoteStation?
    weak var catShare: CATShareServer?
    /// „Odblokuj TX” z okna głównego - dla okien nadających poza nim (pomiar SWR).
    var txArmed = false
    /// Start programu (rejestracja okna głównego) - czas działania w raporcie.
    private(set) var startedAt = Date()

    /// Raport tekstowy: wersja, system, stan radia, skopu, dźwięku, FT8, pracy zdalnej, dzienniki i ustawienia bez haseł.
    func report() -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append("== \(title) ==") }
        func add(_ key: String, _ value: Any?) { lines.append("\(key): \(value.map { "\($0)" } ?? "–")") }
        let utc = ISO8601DateFormatter().string(from: Date())
        lines.append("FT-710 Control – \(L("raport diagnostyczny"))")
        add(L("Data (UTC)"), utc)
        add(L("Wersja programu"), ADIF.programVersion)
        add("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add(L("Model Maca"), Self.sysctl("hw.model"))
        #if arch(arm64)
        add(L("Architektura"), "arm64 (Apple Silicon)")
        #else
        add(L("Architektura"), "x86_64 (Intel)")
        #endif
        add(L("Język / region"), "\(Locale.current.identifier), \(TimeZone.current.identifier)")
        add(L("Czas działania programu"), "\(Int(Date().timeIntervalSince(startedAt) / 60)) min")

        section(L("Radio (CAT)"))
        if let cat {
            add(L("Port"), cat.selectedPort); add(L("Prędkość"), cat.baud); add(L("Połączone"), cat.isConnected)
            add(L("Status"), cat.status); add(L("Częstotliwość"), cat.activeFreq); add(L("Tryb"), cat.modeCode)
            add(L("Nadawanie"), cat.transmitting)
            section(L("Dziennik CAT (ostatnie wpisy)"))
            lines.append(contentsOf: cat.log.suffix(60))
        } else { lines.append("–") }

        section(L("Skop RF"))
        if let scope {
            add(L("Status"), scope.status); add(L("Odbiór"), scope.receiving); add(L("Ramki/s"), scope.fps)
            section(L("Dziennik skopu (ostatnie wpisy)"))
            lines.append(contentsOf: scope.log.suffix(60))
        } else { lines.append("–") }

        section(L("Dźwięk"))
        if let audio {
            func name(_ id: AudioDeviceID, _ list: [AudioDevice]) -> String { list.first { $0.id == id }?.name ?? "\(id)" }
            add(L("Odsłuch"), audio.listening); add(L("Komunikat"), audio.message)
            add(L("Z radia (RX)"), name(audio.radioIn, audio.inputs)); add(L("Głośniki"), name(audio.speakerOut, audio.outputs))
            add(L("Mikrofon"), name(audio.micIn, audio.inputs)); add(L("Do radia (TX)"), name(audio.radioOut, audio.outputs))
            add(L("Urządzenia wejściowe"), audio.inputs.map(\.name).joined(separator: ", "))
            add(L("Urządzenia wyjściowe"), audio.outputs.map(\.name).joined(separator: ", "))
        } else { lines.append("–") }

        section("FT8/FT4")
        if let ft8 {
            add(L("Dekodowanie"), ft8.enabled); add(L("Tryb"), ft8.mode.rawValue); add("TX", ft8.txEnabled)
            add(L("Nadaje"), ft8.transmitting); add("Hound", ft8.houndMode); add(L("Status"), ft8.txStatus)
        } else { lines.append("–") }

        section(L("Praca zdalna"))
        if let remote {
            add(L("Włączona"), remote.enabled); add(L("Status"), remote.status)
            add(L("Tunel Cloudflare"), CloudflareTunnel.shared.running)
            lines.append(contentsOf: remote.log.suffix(40))
        } else { lines.append("–") }

        section("CAT Share")
        if let catShare {
            add(L("Włączony"), catShare.enabled); add(L("Status"), catShare.status)
            lines.append(contentsOf: catShare.log.suffix(30))
        } else { lines.append("–") }

        section(L("Ustawienia (bez haseł)"))
        for (key, value) in SettingsBackup.currentSettings().sorted(by: { $0.key < $1.key }) {
            var text = "\(value)".replacingOccurrences(of: "\n", with: " ")
            if text.count > 300 { text = String(text.prefix(300)) + "…" }
            lines.append("\(key) = \(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "FT710Control-\(L("raport"))-\(stamp).txt"
        panel.message = L("Dołącz ten plik do zgłoszenia na GitHubie (Issues) - nie zawiera haseł")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try shared.report().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            SettingsBackup.info(L("Nie udało się zapisać raportu"), error.localizedDescription)
        }
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}

/// Menu Plik: kopia ustawień; menu Pomoc: raport diagnostyczny.
struct SettingsCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("Zapisz ustawienia programu…")) { SettingsBackup.saveWithPanel() }
            Button(L("Przywróć ustawienia programu…")) { SettingsBackup.restoreWithPanel() }
        }
        CommandGroup(after: .help) {
            Button(L("Zapisz raport diagnostyczny…")) { DiagnosticsHub.saveWithPanel() }
        }
    }
}
