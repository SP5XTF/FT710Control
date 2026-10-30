import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Praca zdalna przez internet bez Tailscale: szybki tunel Cloudflare (cloudflared, bez konta i domeny).
/// Adres https://….trycloudflare.com zmienia się przy każdym uruchomieniu. cloudflared łączy się z serwerem
/// lokalnie (jak tailscale serve), więc połączenie jest szyfrowane i ma te same uprawnienia - także nadawanie.
@MainActor
final class CloudflareTunnel: ObservableObject {
    static let shared = CloudflareTunnel()
    /// Hasło do pracy zdalnej przy tunelu (adres publiczny) - dłuższe niż w sieci domowej i przez Tailscale.
    static let minimumPassword = 12

    @Published private(set) var url: String?
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published var autoStart: Bool { didSet { UserDefaults.standard.set(autoStart, forKey: "tunnel.autoStart") } }

    private var process: Process?
    private var output = ""
    private var stopping = false

    private init() {
        autoStart = UserDefaults.standard.bool(forKey: "tunnel.autoStart")
    }

    /// Przy zamykaniu programu (AppDelegate) - tunel nie może działać dalej bez programu.
    func terminateForQuit() {
        process?.terminate()
        process?.waitUntilExit()
    }

    /// cloudflared z Homebrew (Apple Silicon albo Intel).
    var binaryPath: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(port: Int) {
        guard !running else { return }
        guard let binary = binaryPath else {
            status = L("Brak programu cloudflared - zainstaluj: brew install cloudflared")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        output = ""
        stopping = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in CloudflareTunnel.shared.received(text) }
        }
        task.terminationHandler = { _ in
            Task { @MainActor in CloudflareTunnel.shared.finished() }
        }
        do {
            try task.run()
            process = task
            running = true
            url = nil
            status = L("Uruchamianie tunelu…")
        } catch {
            status = L("Nie udało się uruchomić cloudflared: {1}", error.localizedDescription)
        }
    }

    func stop() {
        guard let process else { return }
        stopping = true
        process.terminate()
    }

    /// Adres tunelu z komunikatów cloudflared („https://abc-def.trycloudflare.com”).
    static func tunnelURL(in text: String) -> String? {
        guard let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private func received(_ text: String) {
        output += text
        if output.count > 20_000 { output = String(output.suffix(5_000)) }
        if url == nil, let found = Self.tunnelURL(in: output) {
            url = found
            status = L("Tunel działa")
        }
    }

    private func finished() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        running = false
        url = nil
        status = stopping ? L("Tunel zatrzymany") : L("Tunel zakończył się - sprawdź połączenie z internetem")
    }

    /// Kod QR adresu (do zeskanowania iPhonem).
    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Zakładka ZDALNIE: dostęp przez internet tunelem Cloudflare - druga droga obok Tailscale.
struct CloudflareTunnelBox: View {
    @ObservedObject var remote: RemoteStation
    @ObservedObject var tunnel = CloudflareTunnel.shared

    private var passwordOK: Bool { remote.password.count >= CloudflareTunnel.minimumPassword }

    var body: some View {
        GroupBox(L("Przez internet – tunel Cloudflare (bez Tailscale)")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Telefon potrzebuje tylko przeglądarki (Safari) – bez aplikacji i konta. Adres https://….trycloudflare.com zmienia się przy każdym uruchomieniu tunelu; dostęp chroni hasło pracy zdalnej. Do stałej, codziennej pracy wygodniejszy jest Tailscale."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if tunnel.binaryPath == nil {
                    HStack {
                        Text(L("Wymaga bezpłatnego programu cloudflared. W Terminalu:")).font(.callout)
                        Text("brew install cloudflared").font(.callout.monospaced()).textSelection(.enabled)
                        Button(L("Kopiuj")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if tunnel.running {
                            Button(L("Zatrzymaj tunel")) { tunnel.stop() }
                        } else {
                            Button(L("Uruchom tunel")) { tunnel.start(port: remote.port) }
                                .disabled(!remote.enabled || !passwordOK)
                        }
                        Toggle(L("Uruchamiaj razem z pracą zdalną"), isOn: $tunnel.autoStart)
                        Text(Lr(tunnel.status)).font(.caption).foregroundStyle(tunnel.url != nil ? Theme.ok : .secondary)
                    }
                    if !remote.enabled {
                        Text(L("Najpierw włącz pracę zdalną (przełącznik wyżej).")).font(.caption).foregroundStyle(.secondary)
                    } else if !passwordOK {
                        Text(L("Przy tunelu (adres publiczny) hasło pracy zdalnej musi mieć co najmniej {1} znaków.", CloudflareTunnel.minimumPassword))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let url = tunnel.url {
                        HStack(alignment: .top, spacing: 14) {
                            if let qr = CloudflareTunnel.qrImage(url) {
                                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 110, height: 110)
                                    .help(L("Zeskanuj aparatem iPhone'a"))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(url).font(.callout.monospaced()).textSelection(.enabled)
                                HStack {
                                    Button(L("Kopiuj")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                    }
                                    Button(L("Otwórz")) { if let link = URL(string: url) { NSWorkspace.shared.open(link) } }
                                }
                                Text(L("Połączenie szyfrowane (HTTPS) – działa mikrofon i nadawanie (jeśli dozwolone wyżej). Ruch przechodzi przez serwery Cloudflare; tunel testowy Cloudflare nie ma gwarancji dostępności."))
                                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
