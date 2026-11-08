import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ikona w Docku przy uruchamianiu z Xcode / swift run. W aplikacji .app ikonę daje Info.plist
        // (AppIcon.icns), a pakietu zasobów SwiftPM tam nie ma - Bundle.module zakończyłby program awarią.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        // Ctrl+C w Terminalu (swift run) lub kill: zamiast natychmiastowego wyjścia przejdź przez
        // normalne zamknięcie aplikacji, żeby port szeregowy zdążył wysłać TX0.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Jedno okno = jedna sesja z radiem. Zamknięcie okna kończy aplikację (i rozłącza radio).
    /// Zamykanie programu: zmiany dziennika czekające na zapis w tle zapisujemy od razu.
    func applicationWillTerminate(_ notification: Notification) {
        LogbookStore.active?.flushSave()
        CloudflareTunnel.shared.terminateForQuit()             // tunel nie może działać dalej bez programu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Obiekty współdzielone przez okna, tworzone raz przy starcie (bez obserwacji przez App).
@MainActor
final class AppServices {
    static let shared = AppServices()
    let logbook = LogbookStore()
    let qrz = QRZClient()
    let uploader = LogUploader()
}

@main
struct FT710ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Dziennik (wspólny dla okien), konto QRZ.com i wysyłka do serwisów - tworzone raz, ale NIE obserwowane
    // przez App. Jako @StateObject każda ich publikacja przebudowywała scenę, czyli korzeń całego okna głównego
    // (pomiar Instruments: ~11 razy/s po ~13,6 ms - blokady głównego wątku i szarpanie wodospadu).
    // Widoki korzystające z tych obiektów obserwują je same (@EnvironmentObject / @ObservedObject).
    private var logbook: LogbookStore { AppServices.shared.logbook }
    private var qrz: QRZClient { AppServices.shared.qrz }
    private var uploader: LogUploader { AppServices.shared.uploader }

    init() {
        Self.migrateLegacySettings()
        // Potrzebne, gdy aplikacja jest uruchamiana przez `swift run` (bez bundla .app).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("FT-710 Control") {
            ContentView()
                .environmentObject(logbook)
                .environmentObject(qrz)
                .environmentObject(uploader)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            HelpCommands()                             // menu Pomoc: „Pomoc FT-710 Control” (⌘?)
            UpdateCommands()                           // menu programu: „Sprawdź aktualizacje…”
            SettingsCommands()                         // Plik: kopia ustawień; Pomoc: raport diagnostyczny
            LayoutCommands()                           // Widok: zwiń / rozwiń dolny panel (⌥⌘B)
            ToolsCommands()                            // Okno: pomiar SWR anteny (⌥⌘S)
            ProfileCommands()                          // menu aplikacji: „Profil stacji…” (⇧⌘,)
        }

        Window(L("Dziennik łączności"), id: "logbook") {
            LogbookWindowView()
                .environmentObject(logbook)
                .environmentObject(qrz)
                .environmentObject(uploader)
        }

        Window(L("Pomoc FT-710 Control"), id: "help") {
            HelpView()
        }

        Window(L("Kto mnie słyszy"), id: "heard") {
            HeardMeView()
        }
        .defaultSize(width: 1200, height: 720)

        Window(L("Pomiar SWR anteny"), id: "swr") {
            SWRSweepView()
        }
        .defaultSize(width: 1000, height: 600)

        Window(L("Dziennik CAT"), id: "catlog") {
            CATLogWindow()
        }
        .defaultSize(width: 760, height: 520)

        Window(L("Profil stacji"), id: "profile") {
            StationProfileView()
                .environmentObject(logbook)
                .environmentObject(qrz)
                .environmentObject(uploader)
        }
        .windowResizability(.contentSize)
    }

    /// Ustawienia (pamięci M1–M6, hasło stacji, znak, opisy komunikatów…) zapisane pod starą nazwą
    /// programu (FT710Console) przenosimy jednorazowo do nowej domeny ustawień.
    private static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        let marker = "migratedFromFT710Console"
        guard !defaults.bool(forKey: marker) else { return }
        if let legacy = defaults.persistentDomain(forName: "FT710Console") {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
