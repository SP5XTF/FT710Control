import Foundation
import Network

/// Odebrana stacja do zgłoszenia w PSKReporter.
struct PSKSpot: Equatable {
    let call: String
    let freqHz: Int          // częstotliwość radiowa sygnału (dial + ton)
    let snr: Int
    let mode: String         // "FT8", "FT4"
    let grid: String         // lokator nadawcy, jeśli był w komunikacie (CQ, Tx1)
    let time: Date
}

/// Pakiet IPFIX (RFC 5101) w formacie PSKReporter (pskreporter.info/pskdev.html), enterprise 30351.
/// Szablon odbiornika 0x50E2: znak, lokator, program, antena. Szablon nadawcy 0x50E3: znak, częstotliwość (5 B),
/// SNR (1 B), tryb, lokator, źródło informacji (1 B, 1 = automatyczne), czas (4 B, pole 150).
/// Napisy: 1 bajt długości + UTF-8 (do 254 B); każdy zestaw wyrównany zerami do wielokrotności 4 bajtów.
enum PSKReporterPacket {
    static let enterprise: UInt32 = 30351
    static let receiverTemplate: UInt16 = 0x50E2
    static let senderTemplate: UInt16 = 0x50E3

    static func build(sequence: UInt32, observationID: UInt32, exportTime: UInt32, includeTemplates: Bool,
                      receiverCall: String, receiverGrid: String, software: String, antenna: String,
                      spots: [PSKSpot]) -> Data {
        var packet = Data()
        packet.u16(10)                                         // wersja IPFIX
        packet.u16(0)                                          // długość - uzupełniana na końcu
        packet.u32(exportTime)
        packet.u32(sequence)
        packet.u32(observationID)

        if includeTemplates {
            // szablon nadawców (Template Set, ID 2)
            var sender = Data()
            sender.u16(2); sender.u16(0)
            sender.u16(senderTemplate); sender.u16(7)
            sender.field(0x8000 + 1, 0xFFFF)                   // senderCallsign
            sender.field(0x8000 + 5, 5)                        // frequency
            sender.field(0x8000 + 6, 1)                        // sNR
            sender.field(0x8000 + 10, 0xFFFF)                  // mode
            sender.field(0x8000 + 3, 0xFFFF)                   // senderLocator
            sender.field(0x8000 + 11, 1)                       // informationSource
            sender.u16(150); sender.u16(4)                     // flowStartSeconds (IANA)
            packet.append(sender.paddedSet())
            // szablon odbiornika (Options Template Set, ID 3, bez pól zakresu - jak w spec. PSKReporter)
            var receiver = Data()
            receiver.u16(3); receiver.u16(0)
            receiver.u16(receiverTemplate); receiver.u16(4); receiver.u16(0)
            receiver.field(0x8000 + 2, 0xFFFF)                 // receiverCallsign
            receiver.field(0x8000 + 4, 0xFFFF)                 // receiverLocator
            receiver.field(0x8000 + 8, 0xFFFF)                 // decodingSoftware
            receiver.field(0x8000 + 9, 0xFFFF)                 // antennaInformation
            packet.append(receiver.paddedSet())
        }

        var info = Data()
        info.u16(receiverTemplate); info.u16(0)
        info.text(receiverCall); info.text(receiverGrid); info.text(software); info.text(antenna)
        packet.append(info.paddedSet())

        if !spots.isEmpty {
            var set = Data()
            set.u16(senderTemplate); set.u16(0)
            for spot in spots {
                set.text(spot.call)
                let f = UInt64(max(0, spot.freqHz))
                for shift in stride(from: 32, through: 0, by: -8) { set.append(UInt8((f >> UInt64(shift)) & 0xFF)) }
                set.append(UInt8(bitPattern: Int8(max(-128, min(127, spot.snr)))))
                set.text(spot.mode)
                set.text(spot.grid)
                set.append(1)                                  // REPORTER_SOURCE_AUTOMATIC
                set.u32(UInt32(max(0, spot.time.timeIntervalSince1970)))
            }
            packet.append(set.paddedSet())
        }
        let length = UInt16(packet.count)
        packet[packet.startIndex + 2] = UInt8(length >> 8)
        packet[packet.startIndex + 3] = UInt8(length & 0xFF)
        return packet
    }

    /// Rozmiar rekordu nadawcy w bajtach (do pilnowania wielkości pakietu).
    static func recordSize(_ spot: PSKSpot) -> Int {
        (1 + min(spot.call.utf8.count, 254)) + 5 + 1 + (1 + min(spot.mode.utf8.count, 254))
            + (1 + min(spot.grid.utf8.count, 254)) + 1 + 4
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
    mutating func field(_ id: UInt16, _ length: UInt16) {
        u16(id); u16(length)
        if id & 0x8000 != 0 { u32(PSKReporterPacket.enterprise) }
    }
    mutating func text(_ s: String) {
        let bytes = Array(s.utf8.prefix(254))
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
    }
    /// Zestaw z uzupełnioną długością (bajty 2-3) po wyrównaniu do 4 bajtów.
    func paddedSet() -> Data {
        var d = self
        while d.count % 4 != 0 { d.append(0) }
        let length = UInt16(d.count)
        d[d.startIndex + 2] = UInt8(length >> 8)
        d[d.startIndex + 3] = UInt8(length & 0xFF)
        return d
    }
}

/// Klient PSKReporter: zbiera odebrane stacje i wysyła je najwyżej co 5 minut (z losowym przesunięciem,
/// liczonym od startu programu - nie od zegara), jednym gniazdem UDP o stałym porcie źródłowym.
/// Każdy znak zgłaszany najwyżej raz na godzinę na danym paśmie i w danym trybie (zgodnie z zaleceniem
/// „raz na godzinę, chyba że się zmienił”); szablony w pierwszych trzech pakietach i potem co godzinę.
@MainActor
final class PSKReporterClient: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var sentSpots = 0

    private var pending: [PSKSpot] = []
    private var lastReported: [String: Date] = [:]        // znak|pasmo|tryb → czas ostatniego zgłoszenia
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ft710.pskreporter", qos: .utility)
    private var sequence: UInt32 = 0
    private let observationID = UInt32.random(in: 1...UInt32.max)
    private var templatesLeft = 3
    private var lastTemplates = Date.distantPast
    private var timer: Timer?
    private static let host = "report.pskreporter.info"
    private static let port: NWEndpoint.Port = 4739
    private static let maxPacket = 1400                    // poniżej typowego MTU - bez fragmentacji UDP

    var receiverCall = ""
    var receiverGrid = ""
    var antenna = ""
    let software = "FT-710 Control " + ADIF.programVersion

    /// Nowe stacje z cyklu; duplikaty z ostatniej godziny pomijane.
    func add(_ spots: [PSKSpot]) {
        let now = Date()
        lastReported = lastReported.filter { now.timeIntervalSince($0.value) < 3600 }
        for spot in spots {
            if lastReported[Self.key(spot)] != nil { continue }
            if let index = pending.firstIndex(where: { $0.call == spot.call && $0.mode == spot.mode }) {
                if pending[index].grid.isEmpty, !spot.grid.isEmpty { pending[index] = spot }   // lepszy rekord
                continue
            }
            pending.append(spot)
        }
        scheduleIfNeeded()
        if estimatedSize() > Self.maxPacket { flush() }
    }

    private static func key(_ spot: PSKSpot) -> String {
        spot.call + "|" + (LogFrequency.band(for: spot.freqHz) ?? "") + "|" + spot.mode
    }

    /// Rozmiar pakietu: nagłówek 16 B, szablony 60 + 44 B, rekord odbiornika, rekordy stacji, wyrównania.
    private func estimatedSize() -> Int {
        let receiver = 4 + 4 + receiverCall.utf8.count + receiverGrid.utf8.count + software.utf8.count
            + antenna.utf8.count + 3
        return 16 + 104 + receiver + pending.reduce(4 + 3) { $0 + PSKReporterPacket.recordSize($1) }
    }

    private func scheduleIfNeeded() {
        guard timer == nil else { return }
        // 5 minut + 0-30 s losowo; odliczanie od chwili pierwszej stacji, nie od pełnych minut zegara
        let interval = 300 + Double.random(in: 0...30)
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timer = nil
                self?.flush()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Wysłanie oczekujących stacji (w kilku pakietach, jeśli trzeba).
    func flush() {
        guard !pending.isEmpty else { return }
        guard !receiverCall.isEmpty else {
            status = L("PSKReporter: uzupełnij znak w profilu stacji.")
            pending.removeAll()
            return
        }
        ensureConnection()
        let now = Date()
        if now.timeIntervalSince(lastTemplates) > 3600 { templatesLeft = max(templatesLeft, 1) }
        var batch: [PSKSpot] = []
        var size = 0
        func send() {
            guard !batch.isEmpty else { return }
            sequence &+= 1
            let withTemplates = templatesLeft > 0
            let packet = PSKReporterPacket.build(
                sequence: sequence, observationID: observationID, exportTime: UInt32(Date().timeIntervalSince1970),
                includeTemplates: withTemplates, receiverCall: receiverCall, receiverGrid: receiverGrid,
                software: software, antenna: antenna, spots: batch)
            if withTemplates { templatesLeft -= 1; lastTemplates = Date() }
            connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.status = L("PSKReporter: błąd wysyłania ({1}).", error.localizedDescription) }
            })
            for spot in batch { lastReported[Self.key(spot)] = now }
            sentSpots += batch.count
            batch = []
            size = 0
        }
        for spot in pending {
            let record = PSKReporterPacket.recordSize(spot)
            if size + record > Self.maxPacket - 300 { send() }
            batch.append(spot)
            size += record
        }
        send()
        pending.removeAll()
        timer?.invalidate()
        timer = nil
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        status = L("PSKReporter: zgłoszono {1} stacji (ostatnio {2} UTC).", sentSpots, f.string(from: now))
    }

    /// Jedno długo żyjące połączenie UDP = stały port źródłowy (wymóg PSKReporter).
    private func ensureConnection() {
        if let connection {
            switch connection.state {
            case .failed, .cancelled: break                    // trzeba nowego gniazda
            default: return
            }
        }
        connection?.cancel()
        let c = NWConnection(host: NWEndpoint.Host(Self.host), port: Self.port, using: .udp)
        c.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.status = L("PSKReporter: brak połączenia ({1}).", error.localizedDescription) }
            }
        }
        c.start(queue: queue)
        connection = c
        templatesLeft = max(templatesLeft, 3)                  // nowe gniazdo = nowy port: szablony od nowa
    }

    /// Wyłączenie: wysłanie tego, co czeka, i zamknięcie gniazda.
    func stop() {
        flush()
        timer?.invalidate()
        timer = nil
        connection?.cancel()
        connection = nil
    }
}
