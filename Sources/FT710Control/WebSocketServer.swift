import Foundation
import Network
import CryptoKit

/// Minimalny serwer HTTP/1.1 + WebSocket (RFC 6455).
/// Domyślnie tylko interfejs lokalny (dostęp z zewnątrz przez `tailscale serve` z HTTPS).
/// Opcjonalnie także sieć domowa - wtedy przyjmowane są wyłącznie adresy prywatne.
///
/// Wszystkie wywołania zwrotne przychodzą na prywatnej kolejce serwera.
final class WebSocketServer: @unchecked Sendable {
    struct StaticFile {
        let contentType: String
        let body: Data
    }

    final class Client: @unchecked Sendable {
        let id = UUID()
        let remoteDescription: String
        /// Połączenie z tego Maca - lokalna przeglądarka albo `tailscale serve` (HTTPS).
        let isLoopback: Bool
        /// Adres z sieci prywatnej (domowa, link-local, Tailscale 100.64/10).
        let isPrivateNetwork: Bool
        fileprivate let connection: NWConnection
        fileprivate var buffer: [UInt8] = []
        fileprivate var isWebSocket = false
        fileprivate var fragments: [UInt8] = []
        fileprivate var fragmentOpcode: UInt8 = 0

        private let lock = NSLock()
        private var pendingDroppable = 0

        fileprivate init(connection: NWConnection) {
            self.connection = connection
            remoteDescription = "\(connection.endpoint)"
            let origin = Client.classify(connection.endpoint)
            isLoopback = origin.loopback
            isPrivateNetwork = origin.privateNetwork
        }

        static func classify(_ endpoint: NWEndpoint) -> (loopback: Bool, privateNetwork: Bool) {
            guard case .hostPort(let host, _) = endpoint else { return (false, false) }
            switch host {
            case .ipv4(let address):
                return classify(address)
            case .ipv6(let address):
                if address.isLoopback { return (true, true) }
                if let v4 = address.asIPv4 { return classify(v4) }
                let b = [UInt8](address.rawValue)
                let unique = b.count == 16 && (b[0] & 0xFE) == 0xFC          // fc00::/7
                return (false, address.isLinkLocal || unique)
            default:
                return (false, false)
            }
        }

        private static func classify(_ address: IPv4Address) -> (loopback: Bool, privateNetwork: Bool) {
            if address.isLoopback { return (true, true) }
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return (false, false) }
            let isPrivate = b[0] == 10
                || (b[0] == 172 && (b[1] & 0xF0) == 16)          // 172.16/12
                || (b[0] == 192 && b[1] == 168)                  // 192.168/16
                || (b[0] == 169 && b[1] == 254)                  // link-local
                || (b[0] == 100 && (b[1] & 0xC0) == 64)          // 100.64/10 (Tailscale)
            return (false, isPrivate)
        }

        func send(text: String) {
            sendFrame(opcode: 0x1, payload: Data(text.utf8), droppable: false)
        }

        /// `droppable`: dane strumieniowe (audio, skop) - gdy sieć nie nadąża, gubimy je zamiast budować opóźnienie.
        func send(binary: Data, droppable: Bool) {
            sendFrame(opcode: 0x2, payload: binary, droppable: droppable)
        }

        func close() {
            connection.send(content: WebSocketServer.frame(opcode: 0x8, payload: Data()),
                            completion: .contentProcessed { [connection] _ in connection.cancel() })
        }

        fileprivate func sendFrame(opcode: UInt8, payload: Data, droppable: Bool) {
            if droppable {
                lock.lock()
                if pendingDroppable > 8 { lock.unlock(); return }
                pendingDroppable += 1
                lock.unlock()
            }
            connection.send(content: WebSocketServer.frame(opcode: opcode, payload: payload),
                            completion: .contentProcessed { [weak self] _ in
                guard droppable, let self else { return }
                self.lock.lock(); self.pendingDroppable -= 1; self.lock.unlock()
            })
        }
    }

    var files: [String: StaticFile] = [:]
    var onOpen: ((Client) -> Void)?
    var onText: ((Client, String) -> Void)?
    var onBinary: ((Client, Data) -> Void)?
    var onClose: ((Client) -> Void)?
    var onListenerState: ((String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ft710.remote.server")
    private var clients: [UUID: Client] = [:]      // tylko na `queue`
    private var lanAllowed = false

    private static let maxMessage = 1 << 20
    private static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    // MARK: - Start / stop

    func start(port: UInt16, lan: Bool) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !lan {
            params.requiredInterfaceType = .loopback      // tylko ten Mac; dostęp z zewnątrz przez tailscale serve
        }
        queue.sync { lanAllowed = lan }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let l = try NWListener(using: params, on: nwPort)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onListenerState?("ready")
            case .failed(let error): self?.onListenerState?(L("Błąd: {1}", error.localizedDescription))
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
        }
    }

    func disconnect(_ client: Client) {
        client.close()
    }

    // MARK: - Połączenia

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        // Nawet przy dostępie z sieci domowej: nic spoza adresów prywatnych (np. przez przekierowany port).
        guard client.isLoopback || (lanAllowed && client.isPrivateNetwork) else {
            connection.cancel()
            return
        }
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        if client.isWebSocket { onClose?(client) }
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(contentsOf: data)
                self.process(client)
            }
            if complete || error != nil {
                self.drop(client)
            } else if self.clients[client.id] != nil {
                self.receive(client)
            }
        }
    }

    private func process(_ client: Client) {
        if !client.isWebSocket {
            handleHTTP(client)
            if !client.isWebSocket { return }
        }
        parseFrames(client)
    }

    // MARK: - HTTP

    private func handleHTTP(_ client: Client) {
        let terminator: [UInt8] = [13, 10, 13, 10]
        guard let end = firstIndex(of: terminator, in: client.buffer) else {
            if client.buffer.count > 16_384 { drop(client) }
            return
        }
        let head = String(decoding: client.buffer[0..<end], as: UTF8.self)
        client.buffer.removeFirst(end + 4)

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2, requestLine[0] == "GET" else {
            respond(client, status: "405 Method Not Allowed", type: "text/plain", body: Data("Method not allowed".utf8))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(requestLine[1].split(separator: "?").first ?? "/")

        if path == "/ws" {
            guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
                respond(client, status: "400 Bad Request", type: "text/plain", body: Data("WebSocket upgrade required".utf8))
                return
            }
            let digest = Insecure.SHA1.hash(data: Data((key + Self.websocketGUID).utf8))
            let accept = Data(digest).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                           "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            client.isWebSocket = true
            onOpen?(client)
            return
        }

        if let file = files[path] {
            respond(client, status: "200 OK", type: file.contentType, body: file.body)
        } else {
            respond(client, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func respond(_ client: Client, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
                   "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        let connection = client.connection
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where bytes[i] == pattern[0] {
            if Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
        }
        return nil
    }

    // MARK: - Ramki WebSocket

    private func parseFrames(_ client: Client) {
        while client.buffer.count >= 2 {
            let b0 = client.buffer[0]
            let b1 = client.buffer[1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0

            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard client.buffer.count >= 4 else { return }
                length = Int(client.buffer[2]) << 8 | Int(client.buffer[3])
                offset = 4
            } else if length == 127 {
                guard client.buffer.count >= 10 else { return }
                length = 0
                for i in 2..<10 { length = length << 8 | Int(client.buffer[i]) }
                offset = 10
            }
            // Ramki od przeglądarki muszą być maskowane (RFC 6455); zbyt duże odrzucamy.
            guard masked, length >= 0, length <= Self.maxMessage else {
                drop(client)
                return
            }
            guard client.buffer.count >= offset + 4 + length else { return }

            let mask = Array(client.buffer[offset..<(offset + 4)])
            offset += 4
            var payload = Array(client.buffer[offset..<(offset + length)])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            client.buffer.removeFirst(offset + length)

            switch opcode {
            case 0x8:   // close
                client.connection.send(content: Self.frame(opcode: 0x8, payload: Data()),
                                       completion: .contentProcessed { [connection = client.connection] _ in connection.cancel() })
                return
            case 0x9:   // ping
                client.connection.send(content: Self.frame(opcode: 0xA, payload: Data(payload)), completion: .contentProcessed { _ in })
            case 0xA:   // pong
                break
            case 0x1, 0x2:
                if fin {
                    deliver(client, opcode: opcode, payload: payload)
                } else {
                    client.fragmentOpcode = opcode
                    client.fragments = payload
                }
            case 0x0:   // kontynuacja
                client.fragments.append(contentsOf: payload)
                if client.fragments.count > Self.maxMessage { drop(client); return }
                if fin {
                    deliver(client, opcode: client.fragmentOpcode, payload: client.fragments)
                    client.fragments = []
                }
            default:
                drop(client)
                return
            }
        }
    }

    private func deliver(_ client: Client, opcode: UInt8, payload: [UInt8]) {
        if opcode == 0x1 {
            onText?(client, String(decoding: payload, as: UTF8.self))
        } else {
            onBinary?(client, Data(payload))
        }
    }

    fileprivate static func frame(opcode: UInt8, payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            data.append(UInt8(n))
        } else if n <= 0xFFFF {
            data.append(126)
            data.append(UInt8(n >> 8))
            data.append(UInt8(n & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((n >> shift) & 0xFF)) }
        }
        data.append(payload)
        return data
    }
}
