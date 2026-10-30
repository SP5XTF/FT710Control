import Foundation
import Darwin
import AppKit

enum SerialError: LocalizedError {
    case openFailed(String)
    case configFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return L("Nie można otworzyć portu: {1}", message)
        case .configFailed: return L("Nie udało się skonfigurować portu")
        }
    }
}

/// Prosty, nieblokujący port szeregowy (termios) z odczytem przez DispatchSource.
final class SerialPort {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "ft710.serial")
    private var terminateObserver: NSObjectProtocol?
    var onData: (@Sendable (Data) -> Void)?

    /// Komenda wysyłana synchronicznie, gdy aplikacja jest zamykana z otwartym portem
    /// (np. "TX0;" - radio nie może zostać na nadawaniu po wyjściu z programu).
    var sendOnTerminate: String?

    init() {
        // queue: nil -> blok wykonuje się synchronicznie na wątku, który wysłał powiadomienie (główny).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if let command = self.sendOnTerminate { self.writeNow(command) }
            self.close()
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        close()
    }

    /// Porty USB-szeregowe widoczne w systemie (CP210x w FT-710 tworzy zwykle dwa).
    static func availablePorts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items
            .filter { $0.hasPrefix("cu.") && ($0.contains("usbserial") || $0.contains("SLAB") || $0.contains("usbmodem")) }
            .sorted()
            .map { "/dev/" + $0 }
    }

    var isOpen: Bool { queue.sync { fd >= 0 } }

    func open(path: String, baud: Int) throws {
        close()

        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(String(cString: strerror(errno)))
        }

        var options = termios()
        guard tcgetattr(handle, &options) == 0 else {
            Darwin.close(handle)
            throw SerialError.configFailed
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS) // 8N1, bez sprzętowego handshake
        cfsetspeed(&options, speed_t(baud))

        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            Darwin.close(handle)
            throw SerialError.configFailed
        }
        tcflush(handle, TCIOFLUSH)

        queue.sync { fd = handle }

        let src = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(handle) }
        src.resume()
        source = src
    }

    /// Zakolejkowane zapisy są wykonywane przed zamknięciem (ta sama kolejka szeregowa).
    func close() {
        queue.sync {
            source?.cancel()
            source = nil
            fd = -1
        }
    }

    /// Zapis asynchroniczny - normalna praca.
    func write(_ string: String) {
        let bytes = Array(string.utf8)
        queue.async { [weak self] in self?.writeAll(bytes) }
    }

    /// Zapis synchroniczny z czekaniem na fizyczne wysłanie (tcdrain).
    /// Do sytuacji awaryjnych, np. TX0 przy zamykaniu aplikacji. Nie wołać z kolejki portu.
    func writeNow(_ string: String) {
        let bytes = Array(string.utf8)
        queue.sync {
            writeAll(bytes)
            if fd >= 0 { tcdrain(fd) }
        }
    }

    // MARK: - Kolejka portu

    private func writeAll(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var offset = 0
        var retries = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
                retries = 0
            } else if n < 0 && errno == EAGAIN && retries < 500 {
                retries += 1
                usleep(1000)
            } else {
                break
            }
        }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 {
            onData?(Data(buffer[0..<n]))
        }
    }
}
