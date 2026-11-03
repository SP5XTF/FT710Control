import SwiftUI
import AppKit
import Darwin
import AVFoundation
import Combine

/// Praca zdalna przez przeglądarkę. Stacja (ten Mac) pozostaje jedynym właścicielem radia:
/// przeglądarka tylko prosi o zmiany, a stacja je sprawdza i wykonuje.
///
/// Bezpieczeństwo nadawania:
/// - zdalne PTT wymaga zgody na stacji („Pozwól na nadawanie zdalne”),
/// - PTT to „dzierżawa”: przeglądarka wysyła sygnał co 100 ms; brak sygnału przez 0,5 s => TX0,
/// - rozłączenie operatora, wyłączenie zgody lub serwera => TX0,
/// - limit czasu nadawania z CATClient obowiązuje także tutaj,
/// - mikrofon z przeglądarki trafia do radia tylko podczas zdalnego PTT.
@MainActor
final class RemoteStation: ObservableObject {
    @Published var enabled = false { didSet { if enabled != oldValue { enabled ? start() : stop() } } }
    @Published var port: Int { didSet { UserDefaults.standard.set(port, forKey: "remotePort") } }
    @Published var password: String { didSet { UserDefaults.standard.set(password, forKey: "remotePassword") } }
    @Published var allowTX = UserDefaults.standard.bool(forKey: "remoteAllowTX") {
        didSet {
            UserDefaults.standard.set(allowTX, forKey: "remoteAllowTX")
            if allowTX != oldValue { allowTXChanged() }
        }
    }

    /// Przełącznik w oknie: zapamiętuje wybór użytkownika (stop() przy zamykaniu programu go nie nadpisuje);
    /// po ponownym uruchomieniu serwer włącza się sam w attach().
    var enabledByUser: Bool {
        get { enabled }
        set {
            UserDefaults.standard.set(newValue, forKey: "remoteEnabled")
            enabled = newValue
        }
    }
    /// Dostęp także z sieci domowej przez http (bez szyfrowania): sterowanie, skop, odsłuch - bez nadawania.
    @Published var lanAccess: Bool {
        didSet {
            guard lanAccess != oldValue else { return }
            UserDefaults.standard.set(lanAccess, forKey: "remoteLAN")
            if enabled { restartServer() }
        }
    }
    @Published private(set) var status = L("Wyłączony")
    @Published private(set) var operatorInfo: String?
    @Published private(set) var remoteKeyed = false
    @Published private(set) var log: [String] = []
    @Published private(set) var rxAudioInfo: String?

    private weak var cat: CATClient?
    private weak var audio: AudioManager?
    private weak var scope: RFScopeController?
    /// Spoty na skopie w przeglądarce (DX Cluster i POTA) i zakres ostatniej ramki skopu.
    private weak var cluster: DXClusterClient?
    private weak var pota: POTAManager?
    /// Praca przy radiu z przeglądarki: dziennik (wpis, ostatnie QSO), QRZ, nadawanie CW.
    private weak var logbook: LogbookStore?
    private weak var qrz: QRZClient?
    private weak var cw: CWManager?
    /// FT8/FT4 z przeglądarki: lista komunikatów, wołanie, CQ, nadawanie (dekodowanie i sygnał - na Macu).
    private weak var ft8: FT8Manager?
    private var lastFT8ListSignature = 0
    private var lastFT8StateSignature = 0
    /// Nadawanie FT8 włączone z przeglądarki - wyłączane po rozłączeniu operatora.
    private var remoteFT8TX = false
    /// Skop w przeglądarce: „rf” - skop radia, „ft8” - wodospad audio FT8 (jak zakładka FT8 na Macu).
    private var scopeMode = "rf"
    private var ft8WaterfallSubscription: AnyCancellable?
    private var lastFT8WaterfallSent = Date.distantPast
    private var lookupRecord: QRZRecord?
    private var lastClusterSignature = 0
    private var lastAlertsSignature = 0
    /// Nadawanie uruchomione zdalnie (CW, komunikat z pamięci) - przerywane po rozłączeniu operatora.
    private var remoteKeying = false
    private var scopeRange: (lo: Int, hi: Int) = (0, 0)

    private let server = WebSocketServer()
    private let remoteAudio = RemoteAudioStation()
    private var operatorClient: WebSocketServer.Client?
    private var failedAttempts = 0
    private var lockedUntil = Date.distantPast
    /// Narastająca blokada po kolejnych seriach 5 błędnych haseł: 1 min, 5 min, 15 min, 1 h (adres publiczny tunelu).
    private var lockoutLevel = 0
    private static let lockoutSeconds: [TimeInterval] = [60, 300, 900, 3600]
    private var lastHeartbeat = Date.distantPast
    private var keyedSince = Date.distantPast
    private var lastTimeoutCount = 0
    private var lastScopeSent = Date.distantPast
    private var loopTask: Task<Void, Never>?
    private var tick = 0

    private static let leaseTimeout: TimeInterval = 0.5

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: "remotePort")
        port = (1024...65535).contains(savedPort) ? savedPort : 8710
        password = UserDefaults.standard.string(forKey: "remotePassword") ?? ""
        lanAccess = UserDefaults.standard.bool(forKey: "remoteLAN")

        remoteAudio.onRXChunk = { [weak self] pcm in
            let packet = Data([1, 0, 0, 0]) + pcm
            Task { @MainActor in self?.operatorClient?.send(binary: packet, droppable: true) }
        }
        remoteAudio.onError = { [weak self] message in
            Task { @MainActor in self?.appendLog(L("Audio RX: {1}", message)) }
        }
        server.files = RemoteWebPage.files
        server.onOpen = { _ in }
        server.onText = { [weak self] client, text in
            Task { @MainActor in self?.handleText(client, text) }
        }
        server.onBinary = { [weak self] client, data in
            Task { @MainActor in self?.handleBinary(client, data) }
        }
        server.onClose = { [weak self] client in
            Task { @MainActor in self?.clientClosed(client) }
        }
        server.onListenerState = { [weak self] state in
            Task { @MainActor in self?.listenerState(state) }
        }
    }

    func attach(cat: CATClient, audio: AudioManager, scope: RFScopeController) {
        self.cat = cat
        self.audio = audio
        self.scope = scope
        lastTimeoutCount = cat.txTimeoutCount
        scope.frameSink = { [weak self] frame in self?.forwardScope(frame) }
        // przywrócenie stanu z poprzedniego uruchomienia (start sprawdza hasło jak przy ręcznym włączeniu)
        if UserDefaults.standard.bool(forKey: "remoteEnabled"), !enabled { enabled = true }
    }

    // MARK: - Serwer

    private func start() {
        guard password.count >= 8 else {
            enabled = false
            status = L("Ustaw hasło (min. 8 znaków)")
            return
        }
        do {
            try server.start(port: UInt16(port), lan: lanAccess)
            status = L("Uruchamianie…")
            // tunel Cloudflare razem z pracą zdalną (opcja) - tylko z hasłem dość długim dla adresu publicznego
            if CloudflareTunnel.shared.autoStart, password.count >= CloudflareTunnel.minimumPassword {
                CloudflareTunnel.shared.start(port: port)
            }
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.onTick()
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch {
            enabled = false
            status = L("Błąd: {1}", error.localizedDescription)
        }
    }

    func stop() {
        CloudflareTunnel.shared.stop()                         // bez serwera tunel nie ma sensu
        unkey(reason: L("serwer zdalny wyłączony"))
        operatorClient?.close()
        dropOperator()
        loopTask?.cancel()
        loopTask = nil
        server.stop()
        if enabled { enabled = false }
        status = L("Wyłączony")
    }

    private func restartServer() {
        unkey(reason: L("zmiana ustawień serwera"))
        operatorClient?.close()
        dropOperator()
        loopTask?.cancel()
        loopTask = nil
        server.stop()
        start()
    }

    /// Adresy IPv4 tego Maca w sieciach lokalnych (do wyświetlenia jako adresy dla przeglądarki).
    var lanURLs: [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let flags = Int32(item.pointee.ifa_flags)
            if let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.append("http://\(String(cString: host)):\(port)")
                }
            }
            cursor = item.pointee.ifa_next
        }
        return result
    }

    private func listenerState(_ state: String) {
        if state == "ready" {
            status = lanAccess ? L("Nasłuch: ten Mac + sieć domowa, port {1}", port) : L("Nasłuch 127.0.0.1:{1}", port)
        } else {
            enabled = false
            status = state
        }
    }

    func disconnectOperator() {
        unkey(reason: L("operator rozłączony na stacji"))
        operatorClient?.close()
        dropOperator()
    }

    // MARK: - Pętla: dzierżawa PTT i stan

    private func onTick() {
        guard let cat else { return }
        tick += 1

        if remoteKeyed {
            if Date().timeIntervalSince(lastHeartbeat) > Self.leaseTimeout {
                unkey(reason: L("brak sygnału od operatora przez 0,5 s"))
            } else if !cat.isConnected {
                unkey(reason: L("radio rozłączone"))
            }
        }
        if cat.txTimeoutCount != lastTimeoutCount {
            lastTimeoutCount = cat.txTimeoutCount
            if remoteKeyed {
                // CATClient już wysłał TX0 - tylko zamknij tor audio i poinformuj operatora.
                remoteKeyed = false
                remoteAudio.setGate(false)
                appendLog(L("Limit czasu nadawania - TX0"))
                send(["t": "ptt_off", "reason": L("limit czasu nadawania")])
            }
        }
        if tick % 2 == 0 { sendState() }     // 10 razy na sekundę
        if tick % 20 == 0 { updateRXAudioInfo() }   // co sekundę
        if tick % 60 == 0 { sendSpots() }           // co 3 s - znaki na skopie w przeglądarce
        if tick % 40 == 0 { sendLists() }           // co 2 s, tylko po zmianie - lista klastra i alerty
        if tick % 10 == 0 { sendFT8() }             // co 0,5 s, tylko po zmianie - FT8: lista i stan
    }

    private func updateRXAudioInfo() {
        guard operatorClient != nil, remoteAudio.rxRunning else {
            rxAudioInfo = nil
            return
        }
        let stats = remoteAudio.takeRXStats()
        let level = stats.peakDB.map { "\($0) dBFS" } ?? "CISZA"
        rxAudioInfo = L("Audio RX do operatora: {1} paczek/s, szczyt {2}", stats.chunks, level)
    }

    private func sendState() {
        guard let client = operatorClient, let cat else { return }
        var state: [String: Any] = [
            "t": "state",
            "conn": cat.isConnected,
            "f": cat.activeFreq,
            "fb": cat.freqB,
            "m": cat.modeName,
            "mc": cat.modeCode,
            "tx": cat.transmitting,
            "rk": remoteKeyed,
            "allowTX": allowTX,
            "txHere": client.isLoopback,
            "audioRX": remoteAudio.rxRunning,
            "audioTX": remoteAudio.txRunning,
            "s": cat.sMeter,
            "sTxt": MeterCalibration.sMeterText(raw: cat.sMeter),
            "po": cat.rawPO,
            "poTxt": MeterCalibration.powerText(raw: cat.rawPO),
            "swr": cat.rawSWR,
            "swrTxt": MeterCalibration.swrText(raw: cat.rawSWR),
            "comp": cat.rawCOMP,
            "compTxt": MeterCalibration.percentText(raw: cat.rawCOMP),
            "alc": cat.rawALC,
            "alcTxt": MeterCalibration.percentText(raw: cat.rawALC)
        ]
        if let scope, scope.receiving {
            state["span"] = scope.spanHz
        }
        // przełączniki radia (wartości jak w panelu programu): ATT 0-3, IPO 0-2, AGC 0-6, moc W, klucz WPM
        var controls: [String: Int] = [:]
        for (name, control) in Self.remoteControls { if let v = cat.controls[control] { controls[name] = v } }
        state["ctl"] = controls
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let text = String(data: data, encoding: .utf8) {
            client.send(text: text)
        }
    }

    /// Przełączniki radia dostępne z przeglądarki (nazwa w protokole → ustawienie CAT).
    static let remoteControls: [String: RadioControl] = [
        "att": .attenuator, "ipo": .preamp, "agc": .agc, "pwr": .power, "ks": .keySpeed,
        "af": .afGain, "rf": .rfGain, "sql": .squelch,
        "nb": .noiseBlanker, "nbl": .nbLevel, "nr": .noiseReduction, "nrl": .nrLevel, "dnf": .notchAuto, "nar": .narrow,
        "width": .width, "shift": .ifShift, "notch": .notch, "notchf": .notchFreq, "cont": .contour, "contf": .contourFreq,
        "mic": .micGain, "proc": .processor, "procl": .procLevel, "amc": .amc, "tuner": .tuner, "split": .split
    ]

    /// Podpięcie dziennika, QRZ i CW (wpis do dziennika, wyszukiwanie, nadawanie CW z przeglądarki).
    func attachFT8(_ ft8: FT8Manager) {
        self.ft8 = ft8
        ft8WaterfallSubscription = ft8.waterfall.$frame.sink { [weak self] frame in
            guard let frame else { return }
            self?.forwardFT8Waterfall(frame)
        }
    }

    /// Najnowsza linia wodospadu FT8 (kolory jak na Macu), do ok. 600 punktów, najwyżej 10 razy/s.
    /// Pakiet: [3,0,0,0] + maxHz (UInt32 LE) + RGB.
    private func forwardFT8Waterfall(_ frame: FTWaterfallFrame) {
        guard scopeMode == "ft8", let client = operatorClient,
              Date().timeIntervalSince(lastFT8WaterfallSent) >= 0.1 else { return }
        let image = frame.image
        let width = min(image.width, 600)
        guard width > 0, image.height > 0,
              let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        lastFT8WaterfallSent = Date()
        context.interpolationQuality = .medium
        // górny (najnowszy) wiersz obrazu trafia w jedyny wiersz kontekstu
        context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(width), height: CGFloat(image.height)))
        guard let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * 4)
        var packet = Data([3, 0, 0, 0])
        withUnsafeBytes(of: UInt32(clamping: Int(frame.maxHz)).littleEndian) { packet.append(contentsOf: $0) }
        packet.reserveCapacity(8 + width * 3)
        for x in 0..<width {
            packet.append(pixels[x * 4]); packet.append(pixels[x * 4 + 1]); packet.append(pixels[x * 4 + 2])
        }
        client.send(binary: packet, droppable: true)
    }

    func attachOperating(logbook: LogbookStore, qrz: QRZClient, cw: CWManager) {
        self.logbook = logbook
        self.qrz = qrz
        self.cw = cw
    }

    /// Nadawanie z przeglądarki (CW, komunikaty, strojenie tunera) - te same warunki co PTT.
    private func remoteTXRefusal() -> String? {
        guard allowTX else { return L("nadawanie zdalne nie jest dozwolone na stacji") }
        guard cat?.isConnected == true else { return L("radio nie jest połączone") }
        guard operatorClient?.isLoopback == true else {
            return L("nadawanie tylko przez adres Tailscale (HTTPS) - połączenie z sieci domowej jest nieszyfrowane")
        }
        return nil
    }

    // MARK: - FT8/FT4 w przeglądarce

    /// Polecenia FT8: call (dotknięcie komunikatu = dwuklik), cq, tx, stop, mode, band, decode, hound.
    private func handleFT8(_ message: [String: Any]) {
        guard let ft8, let op = message["op"] as? String else { return }
        // nadawanie - te same warunki co PTT; zgoda zdalna zastępuje „Odblokuj TX” na Macu
        func armForTX() -> Bool {
            if let refusal = remoteTXRefusal() {
                send(["t": "notice", "msg": refusal])
                return false
            }
            ft8.setTXArmed(true)
            remoteFT8TX = true
            return true
        }
        switch op {
        case "call":
            guard let id = (message["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let decode = ft8.activity.first(where: { $0.id == id }) else { return }
            ft8.call(decode)
            if (message["tx"] as? Bool) == true, armForTX() { ft8.txEnabled = true }
        case "cq":
            guard armForTX() else { return }
            ft8.callCQ()
        case "tx":
            let on = (message["on"] as? Bool) ?? false
            if on {
                guard armForTX() else { return }
                ft8.txEnabled = true
            } else {
                ft8.txEnabled = false
            }
        case "stop":
            ft8.txEnabled = false
            if ft8.transmitting { ft8.haltTX(L("zatrzymane z przeglądarki")) }
        case "mode":
            if let raw = message["m"] as? String, let mode = FTMode(rawValue: raw) { ft8.mode = mode }
        case "band":
            if let hz = (message["hz"] as? NSNumber)?.intValue, hz > 0 { ft8.tune(to: hz) }
        case "decode":
            ft8.enabled = (message["on"] as? Bool) ?? true
            ft8.setRemoteWaterfall(scopeMode == "ft8")         // wodospad liczony tylko przy włączonym dekodowaniu
        case "hound":
            ft8.houndMode = (message["on"] as? Bool) ?? false
        case "rxf", "txf":
            // dotknięcie wodospadu FT8: RX (jak kliknięcie na Macu) albo TX (jak Shift+kliknięcie)
            guard let hz = (message["hz"] as? NSNumber)?.intValue else { return }
            let value = min(max(hz, 100), 3000)
            if op == "rxf" { ft8.rxFreq = value } else { ft8.txFreq = value }
        default:
            break
        }
        lastFT8StateSignature = 0                              // odpowiedź od razu
        sendFT8()
    }

    /// Lista komunikatów (ostatnie 40, najnowsze pierwsze) i stan nadawania - wysyłane tylko po zmianie.
    private func sendFT8() {
        guard operatorClient != nil, let ft8 else { return }
        let recent = Array(ft8.activity.suffix(40).reversed())
        var hasher = Hasher()
        for d in recent { hasher.combine(d.id) }
        let listSignature = hasher.finalize()
        if listSignature != lastFT8ListSignature {
            lastFT8ListSignature = listSignature
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "HHmmss"
            let list = recent.map { d -> [String: Any] in
                let color = d.toMe ? FTHighlight.myCall.hex : (d.highlights.first?.hex ?? "")
                return ["id": d.id.uuidString, "t": f.string(from: d.slot), "snr": d.snr, "dt": d.dt, "f": d.freq,
                        "txt": d.text, "col": color, "me": d.toMe, "dx": d.country]
            }
            send(["t": "ft8", "list": list])
        }
        let state: [String: Any] = [
            "t": "ft8s", "on": ft8.enabled, "m": ft8.mode.rawValue, "tx": ft8.txEnabled, "txing": ft8.transmitting,
            "dxc": ft8.dxCall, "next": ft8.txMessages.indices.contains(ft8.nextTx) ? ft8.txMessages[ft8.nextTx] : "",
            "txf": ft8.txFreq, "rxf": ft8.rxFreq, "st": ft8.txStatus ?? "", "hound": ft8.houndMode,
            "bands": ft8.mode.dialFrequencies, "dial": ft8.dialFrequency
        ]
        var stateHasher = Hasher()
        for key in state.keys.sorted() { stateHasher.combine(key); stateHasher.combine(String(describing: state[key]!)) }
        let stateSignature = stateHasher.finalize()
        if stateSignature != lastFT8StateSignature {
            lastFT8StateSignature = stateSignature
            send(state)
        }
    }

    // MARK: - Dziennik, klaster i alerty w przeglądarce

    /// QRZ (imię, QTH, lokator, kraj) i „było już”: liczba łączności i pasma z dziennika.
    private func lookup(_ call: String) {
        guard call.count >= 3 else { return }
        let base = QRZClient.baseCall(call)
        let before = logbook?.qsos.filter { QRZClient.baseCall($0.call) == base } ?? []
        let bands = AwardCalculator.orderedBands(Set(before.map { $0.band.lowercased() }))
        var info: [String: Any] = ["t": "lookup", "call": call, "worked": before.count, "bands": bands.joined(separator: " ")]
        if let match = CTYDatabase.shared.table?.lookup(call) {
            info["country"] = CTYDatabase.shared.table?.dxccName(CTYTable.dxccKey(match)) ?? match.entity.name
        }
        send(info)
        guard let qrz else { return }
        Task { @MainActor in
            guard case .found(let record) = await qrz.lookup(call) else { return }
            lookupRecord = record
            let away = OperatingLocation.isAwayFromHome(call)
            var full = info
            full["name"] = record.firstName.isEmpty ? record.displayName : record.firstName
            if !away {
                full["qth"] = record.city
                full["grid"] = record.grid
            }
            send(full)
        }
    }

    /// Wpis do dziennika z przeglądarki - ta sama funkcja co formularz w programie (makeQSO), potem zwykłe
    /// dodanie do dziennika (automatyczna wysyłka do serwisów jak przy wpisie w programie).
    private func logRemote(_ message: [String: Any]) {
        guard let cat, let logbook else { return }
        func text(_ key: String) -> String { (message[key] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        let call = text("call").uppercased()
        guard call.count >= 3, call.range(of: "^[A-Z0-9/]+$", options: .regularExpression) != nil else {
            send(["t": "notice", "msg": L("Nieprawidłowy znak")])
            return
        }
        guard cat.activeFreq > 0 else {
            send(["t": "notice", "msg": L("Brak częstotliwości z radia - połącz CAT")])
            return
        }
        let now = Date()
        let qso = logbook.makeQSO(call: call, start: now, end: now, freqHz: cat.activeFreq,
                                  preset: LogModePreset.forRadio(cat.modeCode), rstSent: text("rsts"), rstRcvd: text("rstr"),
                                  name: text("name"), qth: text("qth"), grid: text("grid"), comment: text("comment"),
                                  record: lookupRecord?.call == QRZClient.baseCall(call) ? lookupRecord : nil)
        logbook.add(qso)
        lookupRecord = nil
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        send(["t": "logged", "call": call, "time": f.string(from: now)])
        appendLog(L("Zapisano zdalnie: {1}", call))
        sendRecent()
    }

    /// Ostatnie łączności z dziennika (najnowsze pierwsze).
    private func sendRecent() {
        guard let logbook, operatorClient != nil else { return }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd.MM HH:mm"
        let list = logbook.qsos.sorted { $0.start > $1.start }.prefix(10).map { q -> [String: Any] in
            ["call": q.call, "time": f.string(from: q.start), "band": q.band, "mode": q.modeLabel,
             "rst": [q.rstSent, q.rstRcvd].filter { !$0.isEmpty }.joined(separator: "/")]
        }
        send(["t": "recent", "list": Array(list)])
    }

    /// Lista spotów DX Cluster (z kolorem stanu kraju) i alerty - wysyłane tylko po zmianie.
    private func sendLists() {
        guard operatorClient != nil else { return }
        if let cluster {
            let spots = Array(cluster.spots.prefix(30))
            var hasher = Hasher()
            for s in spots { hasher.combine(s.id) }
            hasher.combine(WorkedIndexStore.shared.index.dxcc.count)
            let signature = hasher.finalize()
            if signature != lastClusterSignature {
                lastClusterSignature = signature
                let list = spots.map { s -> [String: Any] in
                    let country = CTYDatabase.shared.table?.lookup(s.call)
                        .map { CTYDatabase.shared.table?.dxccName(CTYTable.dxccKey($0)) ?? $0.entity.name } ?? ""
                    return ["c": s.call, "hz": s.frequencyHz, "khz": s.kHzText, "m": s.digiMode ?? s.mode.rawValue,
                            "time": s.timeUTC, "cm": s.comment, "dx": country,
                            "col": ScopeMarkStyle.highlight(call: s.call, band: s.band)?.hex ?? ""]
                }
                send(["t": "cluster", "conn": cluster.state == .connected, "list": list])
            }
        }
        let items = Array(AlertCenter.shared.items.prefix(15))
        var hasher = Hasher()
        for a in items { hasher.combine(a.id) }
        let signature = hasher.finalize()
        if signature != lastAlertsSignature {
            lastAlertsSignature = signature
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "HH:mm"
            let list = items.map { a -> [String: Any] in
                ["time": f.string(from: a.time), "kind": a.kind.name, "col": a.kind.hex, "c": a.call, "hz": a.frequencyHz,
                 "band": a.band, "m": a.mode, "d": a.detail]
            }
            send(["t": "alerts", "list": list])
        }
    }

    /// Podpięcie źródeł spotów dla skopu w przeglądarce.
    func attachSpots(cluster: DXClusterClient, pota: POTAManager) {
        self.cluster = cluster
        self.pota = pota
    }

    /// Spoty w zakresie skopu: znak, częstotliwość, kolor (ta sama funkcja co skop w programie), POTA.
    private func sendSpots() {
        guard operatorClient != nil, scopeRange.hi > scopeRange.lo else { return }
        let (lo, hi) = scopeRange
        var byCall: [String: [String: Any]] = [:]
        if UserDefaults.standard.object(forKey: "scope.showCluster") as? Bool ?? true, let cluster {
            for spot in cluster.scopeSpots(lowHz: lo, highHz: hi) {
                let style = ScopeMarkStyle.highlight(call: spot.call, band: spot.band)
                byCall[spot.call] = ["c": spot.call, "hz": spot.frequencyHz, "col": style?.hex ?? "", "p": false,
                                     "tip": "\(spot.kHzText) kHz \(spot.digiMode ?? spot.mode.rawValue) \(spot.comment)"]
            }
        }
        if UserDefaults.standard.object(forKey: "scope.showPOTA") as? Bool ?? true, let pota {
            for spot in pota.spots where spot.frequencyHz >= lo && spot.frequencyHz <= hi {
                let style = ScopeMarkStyle.highlight(call: spot.activator, band: spot.band)
                byCall[spot.activator] = ["c": spot.activator, "hz": spot.frequencyHz, "col": style?.hex ?? "", "p": true,
                                          "tip": "POTA \(spot.reference) \(spot.parkName) \(spot.mode)"]
            }
        }
        send(["t": "spots", "list": Array(byCall.values)])
    }

    private func forwardScope(_ frame: FT4222ScopeReader.Frame) {
        guard scopeMode == "rf", let client = operatorClient, Date().timeIntervalSince(lastScopeSent) >= 1.0 / 15 else { return }
        lastScopeSent = Date()
        scopeRange = (frame.lowHz, frame.highHz)
        var packet = Data([2, 0, 0, 0])
        for value in [UInt32(clamping: frame.lowHz), UInt32(clamping: frame.highHz)] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(contentsOf: frame.amplitudes)
        client.send(binary: packet, droppable: true)
    }

    // MARK: - Wiadomości od przeglądarki

    private func handleText(_ client: WebSocketServer.Client, _ text: String) {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["t"] as? String else { return }

        guard client.id == operatorClient?.id else {
            if type == "auth" { authenticate(client, password: message["pw"] as? String ?? "") }
            return
        }
        guard let cat else { return }

        switch type {
        case "ping":
            send(["t": "pong", "ts": message["ts"] ?? 0])
        case "hb":
            if remoteKeyed { lastHeartbeat = Date() }
        case "ptt":
            if (message["on"] as? Bool) == true { keyRemote() } else { unkey(reason: nil) }
        case "freq":
            guard cat.isConnected, let hz = (message["hz"] as? NSNumber)?.intValue, hz > 0 else { return }
            cat.setActiveFrequency(hz)
        case "tune":
            guard cat.isConnected, let delta = (message["d"] as? NSNumber)?.intValue, abs(delta) <= 1_000_000 else { return }
            cat.tune(by: delta)
        case "mode":
            guard cat.isConnected, let code = message["code"] as? String, RadioMode.names[code] != nil else { return }
            cat.setMode(code)
        case "band":
            // przycisk pasma: częstotliwość i (opcjonalnie) tryb z pamięci pasma w przeglądarce
            guard cat.isConnected, let hz = (message["hz"] as? NSNumber)?.intValue, hz > 0 else { return }
            cat.setActiveFrequency(hz)
            if let code = message["mc"] as? String, RadioMode.names[code] != nil, cat.modeCode != code { cat.setMode(code) }
        case "vfo":
            guard cat.isConnected, let op = message["op"] as? String else { return }
            if op == "ab" { cat.copyAtoB() } else if op == "swap" { cat.swapVFO() }
        case "atu":
            // strojenie tunera nadaje nośną - te same warunki co PTT
            if let refusal = remoteTXRefusal() { send(["t": "notice", "msg": refusal]); return }
            cat.startTuning()
        case "msg":
            if let refusal = remoteTXRefusal() { send(["t": "notice", "msg": refusal]); return }
            guard let channel = (message["ch"] as? NSNumber)?.intValue, (1...5).contains(channel) else { return }
            remoteKeying = true
            cat.playMessage(channel, cw: cat.modeCode == "3" || cat.modeCode == "7")
        case "msgstop":
            cat.stopMessage()
            remoteKeying = false
        case "cw":
            if let refusal = remoteTXRefusal() { send(["t": "notice", "msg": refusal]); return }
            guard let cw, let text = message["text"] as? String, !text.isEmpty, text.count <= 200 else { return }
            remoteKeying = true
            cw.send(text, armed: true)
            if let problem = cw.txMessage { send(["t": "notice", "msg": problem]) }
        case "cwstop":
            cw?.stop()
            remoteKeying = false
        case "ft8":
            handleFT8(message)
        case "scopemode":
            scopeMode = (message["m"] as? String) == "ft8" ? "ft8" : "rf"
            ft8?.setRemoteWaterfall(scopeMode == "ft8")
        case "lookup":
            guard let raw = message["call"] as? String else { return }
            lookup(raw.uppercased().trimmingCharacters(in: .whitespaces))
        case "log":
            logRemote(message)
        case "ctl":
            // przełącznik radia - tylko z listy dozwolonych; zakres pilnuje RadioControl.setCommand
            guard cat.isConnected, let name = message["c"] as? String, let control = Self.remoteControls[name],
                  let value = (message["v"] as? NSNumber)?.intValue else { return }
            cat.set(control, value)
        default:
            break
        }
    }

    private func handleBinary(_ client: WebSocketServer.Client, _ data: Data) {
        guard client.id == operatorClient?.id, data.count > 4, data.first == 3, remoteKeyed else { return }
        remoteAudio.playTX(data.subdata(in: 4..<data.count))
    }

    private func authenticate(_ client: WebSocketServer.Client, password candidate: String) {
        func reject(_ reason: String) {
            if let data = try? JSONSerialization.data(withJSONObject: ["t": "auth_fail", "msg": reason]),
               let text = String(data: data, encoding: .utf8) {
                client.send(text: text)
            }
            client.close()
        }
        guard Date() >= lockedUntil else {
            reject(L("Zbyt wiele błędnych prób - spróbuj za {1} min", max(1, Int((lockedUntil.timeIntervalSinceNow / 60).rounded(.up)))))
            return
        }
        guard Self.constantTimeEquals(candidate, password) else {
            failedAttempts += 1
            appendLog(L("Błędne hasło ({1})", failedAttempts))
            if failedAttempts >= 5 {
                let seconds = Self.lockoutSeconds[min(lockoutLevel, Self.lockoutSeconds.count - 1)]
                lockedUntil = Date().addingTimeInterval(seconds)
                lockoutLevel += 1
                failedAttempts = 0
                appendLog(L("Logowanie zablokowane na {1} min", Int(seconds / 60)))
            }
            reject(L("Błędne hasło"))
            return
        }
        guard operatorClient == nil else {
            reject(L("Stacja jest zajęta przez innego operatora"))
            return
        }

        failedAttempts = 0
        lockoutLevel = 0                                        // skuteczne logowanie zeruje blokadę
        operatorClient = client
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        operatorInfo = L("Operator połączony od {1}", time) + (client.isLoopback ? "" : L(" (sieć domowa, bez nadawania)"))
        appendLog(L("Operator zalogowany"))

        startRXAudio()
        if allowTX { startTXAudio() }
        var ranges: [String: [Int]] = [:]
        for (name, control) in Self.remoteControls { ranges[name] = [control.range.lowerBound, control.range.upperBound] }
        // podziałki wskaźników łukowych (układ komputerowy w przeglądarce) - z tej samej kalibracji co na Macu
        func ticks(_ list: [(Double, String)]) -> [[Any]] { list.map { [$0.0, $0.1] } }
        let gauges: [String: Any] = [
            "s": ticks(ContentView.sTicks), "po": ticks(ContentView.poTicks), "swr": ticks(ContentView.swrTicks),
            "pct": ticks(ContentView.percentTicks), "swrRed": ContentView.position(3.0, MeterCalibration.swr)
        ]
        send(["t": "auth_ok", "station": "FT-710", "lang": AppLanguage.current == .en ? "en" : "pl",
              "ranges": ranges, "mycall": logbook?.myCall.uppercased() ?? "", "gauges": gauges])
        lastClusterSignature = 0
        lastAlertsSignature = 0
        lastFT8ListSignature = 0
        lastFT8StateSignature = 0
        sendSpots()
        sendRecent()
        sendLists()
    }

    /// Wejście USB radia jest dla macOS mikrofonem: bez zgody system podaje ciszę zamiast błędu.
    private func startRXAudio() {
        guard let audio else { return }
        let begin = { [weak self] in
            guard let self, self.operatorClient != nil else { return }
            do {
                try self.remoteAudio.startRX(inputID: audio.radioIn)
                self.appendLog(L("Audio RX: start ({1})", audio.inputs.first(where: { $0.id == audio.radioIn })?.name ?? L("brak urządzenia")))
            } catch {
                self.appendLog(L("Audio RX: {1}", error.localizedDescription))
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted { begin() } else { self.appendLog(L("Brak zgody na wejście audio - operator nie usłyszy odbioru")) }
            }
        default:
            appendLog(L("Brak zgody na wejście audio: Ustawienia systemowe → Prywatność i ochrona → Mikrofon"))
        }
    }

    private func clientClosed(_ client: WebSocketServer.Client) {
        guard client.id == operatorClient?.id else { return }
        unkey(reason: L("rozłączenie operatora"))
        scopeMode = "rf"
        ft8?.setRemoteWaterfall(false)
        if remoteFT8TX, let ft8 {                              // FT8 włączone z przeglądarki - wyłącz
            ft8.txEnabled = false
            if ft8.transmitting { ft8.haltTX(L("rozłączenie operatora zdalnego")) }
            remoteFT8TX = false
        }
        if remoteKeying {                                       // CW / komunikat z pamięci - przerwij
            cw?.stop()
            cat?.stopMessage()
            remoteKeying = false
        }
        dropOperator()
        appendLog(L("Operator rozłączony"))
    }

    private func dropOperator() {
        operatorClient = nil
        operatorInfo = nil
        remoteAudio.stopRX()
        remoteAudio.stopTX()
    }

    // MARK: - PTT

    private func keyRemote() {
        guard let cat, operatorClient != nil, !remoteKeyed else { return }
        guard allowTX else {
            send(["t": "ptt_off", "reason": L("nadawanie zdalne nie jest dozwolone na stacji")])
            return
        }
        guard cat.isConnected else {
            send(["t": "ptt_off", "reason": L("radio nie jest połączone")])
            return
        }
        guard operatorClient?.isLoopback == true else {
            send(["t": "ptt_off", "reason": L("nadawanie tylko przez adres Tailscale (HTTPS) - połączenie z sieci domowej jest nieszyfrowane")])
            return
        }
        guard remoteAudio.txRunning else {
            send(["t": "ptt_off", "reason": L("brak toru audio do radia (sprawdź „Do radia (TX)”)")])
            return
        }
        remoteKeyed = true
        lastHeartbeat = Date()
        keyedSince = Date()
        remoteAudio.setGate(true)
        cat.ptt(true)
        appendLog(L("Zdalne PTT: nadawanie"))
    }

    /// `reason` == nil: zwykłe puszczenie przycisku przez operatora (bez komunikatu).
    private func unkey(reason: String?) {
        guard remoteKeyed else { return }
        remoteKeyed = false
        remoteAudio.setGate(false)
        cat?.ptt(false)
        let seconds = Date().timeIntervalSince(keyedSince)
        appendLog(String(format: L("Zdalne PTT: koniec (%.1f s)"), seconds) + (reason.map { " - \($0)" } ?? ""))
        if let reason { send(["t": "ptt_off", "reason": reason]) }
    }

    private func allowTXChanged() {
        if allowTX {
            if operatorClient != nil { startTXAudio() }
        } else {
            unkey(reason: L("nadawanie zdalne wyłączone na stacji"))
            remoteAudio.stopTX()
        }
    }

    private func startTXAudio() {
        guard let audio else { return }
        do {
            try remoteAudio.startTX(outputID: audio.radioOut)
        } catch {
            appendLog(L("Audio TX: {1}", error.localizedDescription))
        }
    }

    // MARK: - Pomocnicze

    private func send(_ object: [String: Any]) {
        guard let client = operatorClient,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        client.send(text: text)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            diff |= Int(p ^ q)
        }
        return diff == 0
    }

    private func appendLog(_ line: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(time)  \(line)")
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }
}

/// Sekcja w głównym oknie.
struct RemoteSectionView: View {
    @ObservedObject var remote: RemoteStation

    var body: some View {
        GroupBox(L("Praca zdalna (przeglądarka przez Tailscale)")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Toggle(isOn: $remote.enabledByUser) {
                        Text(verbatim: L("Serwer 127.0.0.1:{1}", remote.port))
                    }
                    SecureField(L("Hasło stacji (min. 8 znaków)"), text: $remote.password)
                        .frame(width: 220)
                        .disabled(remote.enabled)
                    Toggle(L("Pozwól na nadawanie zdalne"), isOn: $remote.allowTX)
                    Toggle(L("Dostęp z sieci domowej"), isOn: $remote.lanAccess)
                        .help(L("Przez http, bez szyfrowania: sterowanie, skop i odsłuch. Nadawanie tylko przez Tailscale (HTTPS)."))
                    Spacer()
                    Text(Lr(remote.status))
                        .font(.callout)
                        .foregroundStyle(isErrorStatus(remote.status) || remote.status == L("Ustaw hasło (min. 8 znaków)") ? .red : .secondary)
                }
                HStack(spacing: 12) {
                    if let info = remote.operatorInfo {
                        Text(info).font(.callout).foregroundStyle(.green)
                        if remote.remoteKeyed {
                            Text(L("NADAWANIE ZDALNE"))
                                .font(.callout.bold())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.red, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(.white)
                        }
                        Button(L("Rozłącz operatora")) { remote.disconnectOperator() }
                    } else {
                        Text(L("Brak połączonego operatora")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let info = remote.rxAudioInfo {
                    Text(verbatim: info)
                        .font(.caption.monospaced())
                        .foregroundStyle(info.hasSuffix("CISZA") ? .orange : .secondary)
                }
                Text(verbatim: L("Jednorazowo w Terminalu: tailscale serve --bg {1}  →  potem na telefonie: https://<nazwa-tego-maca>.<twój-tailnet>.ts.net", remote.port))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                CloudflareTunnelBox(remote: remote)
                if remote.lanAccess {
                    Text(verbatim: L("W sieci domowej (sterowanie, skop, odsłuch; bez nadawania): ") +
                         (remote.lanURLs.isEmpty ? L("brak aktywnej sieci") : remote.lanURLs.joined(separator: "   ")))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(L("Audio: RX z „Z radia (RX)”, mikrofon z przeglądarki do „Do radia (TX)”. W radiu źródło modulacji SSB musi być ustawione na USB."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !remote.log.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(remote.log.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
