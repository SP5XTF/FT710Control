import Foundation
import Darwin

/// Odbiera komunikaty UDP WSJT-X / JTDX (Settings → Reporting → UDP Server).
/// Interesuje nas tylko komunikat 12 „Logged ADIF", wysyłany po kliknięciu „OK" w oknie
/// „Log QSO" - zawiera gotowy rekord ADIF łączności.
///
/// Format (QDataStream, big-endian): quint32 magic 0xADBCCBDA, quint32 schemat, quint32 typ,
/// potem QByteArray (quint32 długość + bajty UTF-8): identyfikator klienta i tekst ADIF.
final class WSJTXListener: @unchecked Sendable {
    enum ListenError: LocalizedError {
        case socket(String)
        case bind(UInt16, String)

        var errorDescription: String? {
            switch self {
            case .socket(let reason):
                return L("Nie można utworzyć gniazda UDP: {1}", reason)
            case .bind(let port, let reason):
                return L("Port UDP {1} jest niedostępny ({2}) - czy inny program (JTAlert, GridTracker) już go nie używa?", port, reason)
            }
        }
    }

    var onADIF: (@Sendable (String) -> Void)?

    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "ft710.wsjtx")

    func start(port: UInt16) throws {
        stop()

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ListenError.socket(String(cString: strerror(errno))) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")   // tylko ten Mac

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                bind(fd, addr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ListenError.bind(port, reason)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable(fd) }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }

    private func readAvailable(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return }   // EAGAIN - nic więcej w kolejce
            if let adif = Self.loggedADIF(from: Array(buffer[0..<n])) {
                onADIF?(adif)
            }
        }
    }

    /// Zwraca tekst ADIF z komunikatu typu 12, dla innych komunikatów nil.
    static func loggedADIF(from bytes: [UInt8]) -> String? {
        var offset = 0

        func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            offset += 4
            return value
        }

        func byteArray() -> [UInt8]? {
            guard let length = uint32() else { return nil }
            if length == 0xFFFF_FFFF { return [] }        // pusty (null) QByteArray
            let count = Int(length)
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        guard uint32() == 0xADBC_CBDA,
              uint32() != nil,              // numer schematu
              uint32() == 12,               // Logged ADIF
              byteArray() != nil,           // identyfikator klienta, np. "WSJT-X"
              let adif = byteArray() else { return nil }
        return String(decoding: adif, as: UTF8.self)
    }
}
