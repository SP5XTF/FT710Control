import Foundation
import Combine
import Network
import AppKit
import AVFoundation

/// Rozbiór komunikatu FT8/FT4: kto nadaje, do kogo, lokator, CQ.
struct FTMessageInfo: Equatable {
    var isCQ = false
    var cqModifier: String?          // CQ DX, CQ EU, CQ POTA…
    var to: String?                  // adresat (bez nawiasów <>)
    var from: String?                // nadawca
    var grid: String?                // lokator 4-znakowy
    var report: String?              // -12, R-07, RRR, RR73, 73
    /// Komunikat DXpedycji „K1ABC RR73; W9XYZ <FOX> -12”: stacja, która dostaje RR73 (to = W9XYZ z raportem).
    var rr73To: String?

    static func parse(_ text: String) -> FTMessageInfo {
        var info = FTMessageInfo()
        func clean(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
        let upper = text.uppercased()
        if upper.contains(" RR73; ") {
            // Fox (DXpedycja): RR73 dla pierwszej stacji i raport dla drugiej w jednym komunikacie
            let parts = upper.components(separatedBy: "; ")
            let first = parts[0].split(separator: " ").map(String.init)
            let second = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            if first.count == 2, second.count >= 3 {
                info.rr73To = clean(first[0])
                info.to = clean(second[0])
                info.from = clean(second[1])
                info.report = second[2]
                return info
            }
        }
        var words = upper.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return info }
        if words[0] == "CQ" || words[0] == "QRZ" {
            info.isCQ = true
            words.removeFirst()
            // modyfikator: DX, EU, POTA, 3 cyfry (CQ 290)… - nie jest znakiem (znak ma cyfrę i literę)
            if words.count >= 2, !isCallsign(clean(words[0])) {
                info.cqModifier = words.removeFirst()
            }
            if let first = words.first { info.from = clean(first) }
            if words.count >= 2, isGrid(words[1]) { info.grid = words[1] }
            return info
        }
        guard words.count >= 2 else { return info }
        let a = clean(words[0]), b = clean(words[1])
        guard isCallsign(a) || words[0].hasPrefix("<"), isCallsign(b) || words[1].hasPrefix("<") else { return info }
        info.to = a
        info.from = b
        if words.count >= 3 {
            if isGrid(words[2]) { info.grid = words[2] } else { info.report = words[2] }
        }
        return info
    }

    static func isCallsign(_ s: String) -> Bool {
        guard (3...11).contains(s.count), s != "..." else { return false }
        let hasDigit = s.contains { $0.isNumber }, hasLetter = s.contains { $0.isLetter }
        return hasDigit && hasLetter && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
    }

    static func isGrid(_ s: String) -> Bool {
        guard s.count == 4, s != "RR73" else { return false }
        let c = Array(s), letters = "ABCDEFGHIJKLMNOPQR"
        return letters.contains(c[0]) && letters.contains(c[1]) && c[2].isNumber && c[3].isNumber
    }
}

/// Komunikat na liście aktywności pasma - z opisem kraju i statusem w dzienniku.
struct FTDecode: Identifiable, Equatable {
    let id = UUID()
    let slot: Date
    let mode: FTMode
    let snr: Int
    let dt: Double
    let freq: Int
    let text: String
    let info: FTMessageInfo
    let country: String
    /// Pasujące kategorie wyróżniania (jak w WSJT-X), w kolejności pierwszeństwa.
    /// Zmienne - przeliczane po zapisaniu QSO, żeby widoczne wiersze od razu zmieniły kolor.
    var highlights: [FTHighlight]
    let toMe: Bool
    /// Komunikat nadany przez nas (żółte tło, jak w WSJT-X).
    var isTX = false
    /// Nadawca jest już w dzienniku na tym paśmie (szary tekst, bez zielonego CQ).
    var workedOnBand = false
    var isSeparator: Bool { text.isEmpty }

    static func == (a: FTDecode, b: FTDecode) -> Bool { a.id == b.id }

    var timeText: String { Self.timeFormatter.string(from: slot) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HHmmss"
        return f
    }()
}

/// Moduł FT8/FT4 (etap 1: odbiór). Dekodowanie po każdym cyklu, lista aktywności pasma, wodospad.
@MainActor
final class FT8Manager: ObservableObject {
    // MARK: Ustawienia
    @Published var enabled: Bool { didSet { save("enabled", enabled); pushSettings() } }
    @Published var mode: FTMode {
        didSet {
            save("mode", mode.rawValue)
            clearActivity()
            pushSettings()
            modeChangedForTX()
            if mode != oldValue { retuneForMode() }
        }
    }
    @Published var depth: Int { didSet { save("depth", depth); pushSettings() } }
    @Published var rxFreq: Int { didSet { save("rxFreq", rxFreq) } }
    @Published var txFreq: Int { didSet { save("txFreq", txFreq) } }
    @Published var brightness: Double { didSet { save("brightness", brightness); pushLevels() } }
    @Published var contrast: Double { didSet { save("contrast", contrast); pushLevels() } }
    @Published var onlyCQ: Bool { didSet { save("onlyCQ", onlyCQ) } }
    /// Włączone kategorie wyróżniania (lista z polami wyboru jak „Decode Highlighting” w WSJT-X).
    @Published var highlightEnabled: Set<FTHighlight> {
        didSet { save("highlights", highlightEnabled.map(\.rawValue).sorted()) }
    }

    // MARK: Nadawanie (logika w FT8Transmit.swift)
    @Published var dxCall = "" { didSet { if dxCall != oldValue { generateMessages(); prefetchQRZ(dxCall) } } }
    /// Dane z QRZ/HamQTH pobrane w tle zaraz po wyborze stacji (QSO trwa ok. minuty) - zapis QSO od razu z imieniem,
    /// QTH itd. (wcześniej łączności FT8 trafiały do dziennika bez danych z QRZ).
    var qrzPrefetch: [String: QRZRecord] = [:]
    @Published var dxGrid = "" { didSet { if dxGrid != oldValue { generateMessages() } } }
    @Published var reportSent = -10 { didSet { if reportSent != oldValue { generateMessages() } } }
    /// Tx1…Tx6 - edytowalne; po każdej zmianie sprawdzane koderem (echo).
    @Published var txMessages = ["", "", "", "", "", ""] { didSet { if txMessages != oldValue { checkMessages() } } }
    @Published var txEchoes = ["", "", "", "", "", ""]
    @Published var txValid = [false, false, false, false, false, false]
    /// Komunikat nadawany w następnym cyklu (0 = Tx1 … 5 = Tx6).
    @Published var nextTx = 5 { didSet { touch() } }
    @Published var txEnabled = false { didSet { if txEnabled != oldValue { txEnabledChanged() } } }
    /// Nadawanie w cyklach parzystych (FT8: :00 i :30) - „Tx even/1st” w WSJT-X.
    @Published var txFirst: Bool { didSet { save("txFirst", txFirst); touch() } }
    @Published var autoSequence: Bool { didSet { save("autoSequence", autoSequence) } }
    @Published var holdTxFreq: Bool { didSet { save("holdTxFreq", holdTxFreq) } }
    @Published var txLevel: Double { didSet { save("txLevel", txLevel) } }
    @Published var watchdogMinutes: Int { didSet { save("watchdog", watchdogMinutes) } }
    @Published var disableAfter73: Bool { didSet { save("disableAfter73", disableAfter73) } }
    /// Limit kolejnych wywołań stacji, która nie odpowiada (Tx1-Tx3 bez odpowiedzi); 0 = bez limitu.
    @Published var callLimit: Int { didSet { save("callLimit", callLimit) } }
    /// Po QSO zaczętym od naszego CQ: odpowiedz następnemu wołającemu (albo wróć do CQ) zamiast wyłączać TX.
    @Published var answerNextCaller: Bool { didSet { save("answerNext", answerNextCaller) } }
    /// Licznik kolejnych nadań tego samego komunikatu bez odpowiedzi i jego tekst.
    var unansweredCount = 0
    var unansweredText = ""
    /// Bieżące QSO zaczęło się od naszego CQ (wtedy „następny wołający” ma sens).
    var qsoFromCQ = false
    /// Tryb Hound (DXpedycja Fox/Hound, WSJT-X): wołanie powyżej 1000 Hz w 2. cyklu, R+raport na częstotliwości Foxa.
    @Published var houndMode: Bool {
        didSet {
            save("hound", houndMode)
            guard houndMode, !oldValue else { return }
            if txFreq < 1000 { txFreq = 1000 + Int.random(in: 0...150) * 10 }   // Fox odbiera wołania od 1000 Hz
            txFirst = false                                       // 1. cykl należy do Foxa
            txStatus = L("Hound: wołanie powyżej 1000 Hz w 2. cyklu. Dwuklik na komunikacie Foxa - Tx1; odpowiedź Foxa obsługuje program.")
            txStatusIsInfo = true
        }
    }
    /// Hound: częstotliwość wołania (powrót po QSO), częstotliwość Foxa i liczba wysłanych R+raport.
    var houndCallFreq = 0
    var houndFoxFreq = 0
    var houndR3Sent = 0
    /// Kogo wybrać, gdy na CQ odpowiada kilka stacji naraz.
    @Published var callerPreference: FTCallerPreference { didSet { save("callerPref", callerPreference.rawValue) } }
    /// Lokatory stacji odebrane w tej sesji (znak podstawowy → lokator) - do odległości wołających bez lokatora.
    var knownGrids: [String: String] = [:]
    /// Wołanie stacji od razu raportem (Tx2) zamiast lokatora (Tx1) - „Skip Tx1” w WSJT-X.
    @Published var skipTx1: Bool { didSet { save("skipTx1", skipTx1) } }
    @Published var transmitting = false
    @Published var txProgress = 0.0
    /// Komunikat pod panelem nadawania; domyślnie ostrzeżenie (pomarańczowy), informacja po zapisie QSO.
    @Published var txStatus: String? { didSet { txStatusIsInfo = false } }
    @Published var txStatusIsInfo = false
    @Published var txText = ""
    @Published var reportReceived: String?

    // stan wewnętrzny nadawania
    var txArmed = false
    var qsoStart: Date?
    var loggedCall = ""
    var lastActivity = Date()
    var preparingSlot: Double?
    var activeSlot: Double?
    var txEngine: AVAudioEngine?
    var txPlayer: AVAudioPlayerNode?
    var txStartedAt = 0.0
    var txDuration = 1.0
    var txGeneration = 0
    var schedulerTimer: Timer?
    var checkGeneration = 0

    // MARK: Wyniki
    @Published var activity: [FTDecode] = []
    @Published private(set) var lastCount = 0
    @Published private(set) var lastDecodeSeconds = 0.0
    @Published private(set) var audioReceiving = false
    @Published private(set) var medianDT: Double?
    @Published private(set) var clockOffset: Double?
    @Published private(set) var clockStatus = ""

    // MARK: PSKReporter (zgłaszanie odebranych stacji - jak „Enable PSK Reporter Spotting” w WSJT-X)
    @Published var pskEnabled: Bool { didSet { save("pskEnabled", pskEnabled); if !pskEnabled { psk.stop() } } }
    @Published var pskAntenna: String { didSet { save("pskAntenna", pskAntenna) } }
    let psk = PSKReporterClient()

    /// Wodospad w osobnym obiekcie - jego odświeżanie (7 razy na sekundę) nie przerysowuje list.
    let waterfall = FT8WaterfallModel()

    let receiver = FT8Receiver()
    weak var audio: AudioManager?
    weak var cat: CATClient?
    weak var logbook: LogbookStore?
    private let cty = CTYDatabase.shared
    private var observers: [AnyCancellable] = []
    private static let maxActivity = 1500

    // indeks dziennika: kraje i znaki zaliczone (ogólnie i na paśmie)
    private var worked = FTWorkedIndex()
    private var refreshPending = false
    /// Źródła potwierdzeń użyte w indeksie (zmiana „licz też eQSL / QRZ” przelicza kolory).
    private var confirmFlags = (eqsl: false, qrz: false)
    private var indexDirty = true

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "ft8.enabled") as? Bool ?? true
        mode = FTMode(rawValue: d.string(forKey: "ft8.mode") ?? "") ?? .ft8
        depth = d.object(forKey: "ft8.depth") as? Int ?? 2
        rxFreq = d.object(forKey: "ft8.rxFreq") as? Int ?? 1500
        txFreq = d.object(forKey: "ft8.txFreq") as? Int ?? 1500
        brightness = d.object(forKey: "ft8.brightness") as? Double ?? 0
        contrast = d.object(forKey: "ft8.contrast") as? Double ?? 35
        onlyCQ = d.object(forKey: "ft8.onlyCQ") as? Bool ?? false
        let highlights = (d.stringArray(forKey: "ft8.highlights"))
            .map { Set($0.compactMap(FTHighlight.init(rawValue:))) } ?? FTHighlight.defaultEnabled
        highlightEnabled = highlights
        txFirst = d.object(forKey: "ft8.txFirst") as? Bool ?? false
        autoSequence = d.object(forKey: "ft8.autoSequence") as? Bool ?? true
        holdTxFreq = d.object(forKey: "ft8.holdTxFreq") as? Bool ?? false
        txLevel = d.object(forKey: "ft8.txLevel") as? Double ?? 0.5
        watchdogMinutes = d.object(forKey: "ft8.watchdog") as? Int ?? 6
        disableAfter73 = d.object(forKey: "ft8.disableAfter73") as? Bool ?? true
        skipTx1 = d.object(forKey: "ft8.skipTx1") as? Bool ?? false
        callerPreference = FTCallerPreference(rawValue: d.string(forKey: "ft8.callerPref") ?? "") ?? .strongest
        houndMode = d.object(forKey: "ft8.hound") as? Bool ?? false
        callLimit = d.object(forKey: "ft8.callLimit") as? Int ?? 5
        answerNextCaller = d.object(forKey: "ft8.answerNext") as? Bool ?? true
        pskEnabled = d.object(forKey: "ft8.pskEnabled") as? Bool ?? true
        pskAntenna = d.string(forKey: "ft8.pskAntenna") ?? ""
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "ft8." + key) }

    func attach(audio: AudioManager, cat: CATClient, logbook: LogbookStore) {
        guard self.audio == nil else { return }
        self.audio = audio
        self.cat = cat
        self.logbook = logbook
        receiver.onDecodes = { [weak self] slot, decodes, seconds in
            Task { @MainActor in self?.handle(slot: slot, decodes: decodes, seconds: seconds) }
        }
        receiver.onWaterfall = { [weak waterfall] frame in
            Task { @MainActor in waterfall?.frame = frame }
        }
        receiver.onAudioState = { [weak self] receiving in
            Task { @MainActor in self?.audioReceiving = receiving }
        }
        audio.sampleTap.set("ft8") { [receiver] samples, rate in receiver.append(samples, sampleRate: rate) }
        observers.append(logbook.$qsos.sink { [weak self] _ in
            Task { @MainActor in self?.indexDirty = true; self?.scheduleHighlightRefresh() }
        })
        observers.append(cty.$table.sink { [weak self] _ in
            Task { @MainActor in self?.indexDirty = true; self?.scheduleHighlightRefresh() }
        })
        observers.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let d = UserDefaults.standard
                let now = (eqsl: d.bool(forKey: "qsl.countEQSL"), qrz: d.bool(forKey: "qsl.countQRZ"))
                if now != self.confirmFlags { self.indexDirty = true; self.scheduleHighlightRefresh() }
            }
        })
        observers.append(logbook.$myCall.sink { [weak self] _ in
            Task { @MainActor in self?.pushSettings(); self?.generateMessages() }
        })
        observers.append(logbook.$myGrid.sink { [weak self] _ in Task { @MainActor in self?.generateMessages() } })
        pushSettings()
        pushLevels()
        checkClock()
        generateMessages()
        startScheduler()
    }

    private func pushSettings() {
        receiver.configure(mode: mode, depth: depth, enabled: enabled,
                           myCall: logbook?.myCall.uppercased().trimmingCharacters(in: .whitespaces) ?? "")
    }

    private func pushLevels() { receiver.setWaterfallLevels(brightness: brightness, contrast: contrast) }

    /// Wodospad liczony, gdy ogląda go okno FT8 na Macu albo panel zdalny (niezależnie - wyłączenie w jednym
    /// miejscu nie wyłącza w drugim).
    private var macWaterfallVisible = false
    private var remoteWaterfallWanted = false
    func setWaterfallVisible(_ visible: Bool) { macWaterfallVisible = visible; applyWaterfallWanted() }
    func setRemoteWaterfall(_ wanted: Bool) { remoteWaterfallWanted = wanted; applyWaterfallWanted() }
    private func applyWaterfallWanted() {
        receiver.setWaterfallWanted((macWaterfallVisible || remoteWaterfallWanted) && enabled)
    }

    func clearActivity() {
        activity = []
        medianDT = nil
    }

    // MARK: Radio

    var dialFrequency: Int { cat?.activeFreq ?? 0 }
    var currentBand: String { LogFrequency.band(for: dialFrequency) ?? "" }

    /// Strojenie na standardową częstotliwość FT8/FT4 i tryb DATA-U (dźwięk przez USB).
    func tune(to hz: Int) {
        guard let cat, cat.isConnected else { return }
        if transmitting || txEnabled { haltTX(L("Zmiana pasma - nadawanie zatrzymane.")) }
        cat.setActiveFrequency(hz)
        if cat.modeCode != "C" { cat.setMode("C") }
        clearActivity()
    }

    func setRadioDataU() { cat?.setMode("C") }

    /// Zmiana FT8 ↔ FT4: radio na częstotliwość nowego trybu na tym samym paśmie (40 m: 7,074 ↔ 7,0475 MHz).
    private func retuneForMode() {
        guard let cat, cat.isConnected, cat.activeFreq > 0 else { return }
        guard let target = mode.dialFrequency(sameBandAs: cat.activeFreq) else {
            txStatus = L("{1} nie ma standardowej częstotliwości na paśmie {2} - częstotliwość bez zmian.",
                         mode.rawValue, LogFrequency.band(for: cat.activeFreq) ?? "?")
            txStatusIsInfo = true
            return
        }
        if target != cat.activeFreq { tune(to: target) }
    }

    // MARK: Wyniki dekodowania

    private func handle(slot: Date, decodes: [FTRawDecode], seconds: Double) {
        lastCount = decodes.count
        lastDecodeSeconds = seconds
        guard !decodes.isEmpty else { return }
        rebuildIndexIfNeeded()
        let myCall = logbook?.myCall.uppercased().trimmingCharacters(in: .whitespaces) ?? ""
        let myBase = myCall.isEmpty ? "" : QRZClient.baseCall(myCall)
        let band = currentBand
        let table = cty.table
        var items: [FTDecode] = []
        for d in decodes {
            let info = FTMessageInfo.parse(d.text)
            let toMe = !myBase.isEmpty && ((info.to.map { QRZClient.baseCall($0) == myBase } ?? false)
                || (info.rr73To.map { QRZClient.baseCall($0) == myBase } ?? false))
            let c = classify(info, toMe: toMe, band: band, table: table)
            var item = FTDecode(slot: slot, mode: d.mode, snr: d.snr, dt: d.dt, freq: Int(d.freq.rounded()),
                                text: d.text, info: info, country: c.country, highlights: c.highlights, toMe: toMe)
            item.workedOnBand = c.workedOnBand
            items.append(item)
        }
        // separator cyklu (pusta linia z czasem), potem komunikaty od najniższej częstotliwości
        activity.append(FTDecode(slot: slot, mode: mode, snr: 0, dt: 0, freq: 0, text: "", info: FTMessageInfo(),
                                 country: "", highlights: [], toMe: false))
        activity.append(contentsOf: items)
        if activity.count > Self.maxActivity { activity.removeFirst(activity.count - Self.maxActivity) }
        // DT większości stacji: stałe przesunięcie = zegar Maca albo opóźnienie dźwięku
        let recent = activity.suffix(80).filter { !$0.isSeparator && !$0.isTX }.map(\.dt).sorted()
        medianDT = recent.count >= 5 ? recent[recent.count / 2] : nil
        for item in items {                                   // lokatory z CQ / Tx1 - do odległości wołających
            if let call = item.info.from, let grid = item.info.grid { knownGrids[QRZClient.baseCall(call)] = grid }
        }
        if knownGrids.count > 5000 { knownGrids.removeAll() }
        sequence(after: items)
        reportToPSK(items)
        AlertCenter.shared.ft8(items, band: band, dial: cat?.activeFreq ?? 0)
    }

    /// Zgłoszenie nadawców z cyklu do PSKReporter: tylko znaki odczytane wprost (bez rozwinięć skrótów <…>),
    /// bez własnych komunikatów; częstotliwość = dial + ton.
    private func reportToPSK(_ items: [FTDecode]) {
        guard pskEnabled, let cat, cat.isConnected, cat.activeFreq > 0, let logbook else { return }
        let myCall = logbook.myCall.uppercased().trimmingCharacters(in: .whitespaces)
        guard !myCall.isEmpty else { return }
        let myBase = QRZClient.baseCall(myCall)
        let dial = cat.activeFreq
        let spots: [PSKSpot] = items.compactMap { d in
            guard !d.isTX, let call = d.info.from, FTMessageInfo.isCallsign(call),
                  !d.text.contains("<" + call + ">"), QRZClient.baseCall(call) != myBase else { return nil }
            return PSKSpot(call: call, freqHz: dial + d.freq, snr: d.snr, mode: d.mode.rawValue,
                           grid: d.info.grid ?? "", time: d.slot)
        }
        guard !spots.isEmpty else { return }
        psk.receiverCall = myCall
        psk.receiverGrid = logbook.myGrid.uppercased().trimmingCharacters(in: .whitespaces)
        psk.antenna = pskAntenna
        psk.add(spots)
    }

    /// Kategorie wyróżniania, kraj i „już w dzienniku na tym paśmie” dla komunikatu.
    /// Stacja zrobiona na tym paśmie (w dowolnym trybie) nie dostaje zielonego „CQ w komunikacie” - zostaje
    /// szara (jak w JTDX); kategorie „nowy …” działają nadal, gdyby któraś pasowała.
    private func classify(_ info: FTMessageInfo, toMe: Bool, band: String, table: CTYTable?)
        -> (highlights: [FTHighlight], country: String, workedOnBand: Bool) {
        var highlights: [FTHighlight] = []
        var country = ""
        var workedOnBand = false
        if toMe { highlights.append(.myCall) }
        if let call = info.from, FTMessageInfo.isCallsign(call) {
            let match = table?.lookup(call)
            country = match?.entity.name ?? ""
            workedOnBand = !band.isEmpty && worked.callsBand.contains(QRZClient.baseCall(call) + "|" + band)
            if info.isCQ {                                     // „nowy …” tylko dla CQ - jak w WSJT-X
                var categories = worked.evaluate(call: call, grid: info.grid, match: match, band: band)
                // stacja zrobiona na tym paśmie - szara także z niepotwierdzonego kraju
                if workedOnBand { categories.removeAll { FTWorkedIndex.unconfirmedKinds.contains($0) } }
                highlights += categories
                if !workedOnBand { highlights.append(.cq) }
            }
        }
        return (highlights, country, workedOnBand)
    }

    /// Po zmianie dziennika (zapisane QSO): nowy indeks i ponowne kolory całej listy - widoczne wiersze
    /// zalogowanej stacji od razu szarzeją. Zwłoka 0,5 s: wysyłka do serwisów zmienia dziennik wiele razy z rzędu.
    private func scheduleHighlightRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.refreshPending = false
            self.rebuildIndexIfNeeded()
            let band = self.currentBand
            let table = self.cty.table
            var list = self.activity
            for i in list.indices where !list[i].isSeparator && !list[i].isTX {
                let c = self.classify(list[i].info, toMe: list[i].toMe, band: band, table: table)
                list[i].highlights = c.highlights
                list[i].workedOnBand = c.workedOnBand
            }
            self.activity = list
        }
    }

    /// Indeks dziennika (znaki, kwadraty, kraje, strefy, kontynenty) - przebudowa po zmianie dziennika albo bazy krajów.
    private func rebuildIndexIfNeeded() {
        guard indexDirty, let logbook else { return }
        let d = UserDefaults.standard
        confirmFlags = (d.bool(forKey: "qsl.countEQSL"), d.bool(forKey: "qsl.countQRZ"))
        worked = FTWorkedIndex(qsos: logbook.qsos, cty: cty.table,
                               includeEQSL: confirmFlags.eqsl, includeQRZ: confirmFlags.qrz)
        indexDirty = false
    }

    /// Okno „RX Frequency”: komunikaty blisko częstotliwości odbioru oraz wszystkie skierowane do mnie.
    var rxWindow: [FTDecode] {
        let tolerance = Int(mode.bandwidth) + 10
        return activity.filter { !$0.isSeparator && (abs($0.freq - rxFreq) <= tolerance || $0.toMe || $0.isTX) }
    }

    /// Kliknięcie komunikatu: odbiór na jego częstotliwości i znak do dziennika.
    func select(_ decode: FTDecode) {
        guard !decode.isSeparator else { return }
        rxFreq = decode.freq
        if let call = decode.info.from, FTMessageInfo.isCallsign(call) { logbook?.prefill(call) }
    }

    func copyActivity() {
        let lines = activity.map { d in
            d.isSeparator ? "------ \(d.timeText) ------"
                          : String(format: "%@ %+3ld %+4.1f %4ld ~  %@", d.timeText, d.snr, d.dt, d.freq, d.text)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Zegar (FT8 wymaga zgodności z UTC do ok. ±1 s, FT4 jeszcze dokładniej)

    func checkClock() {
        clockStatus = L("Sprawdzanie zegara…")
        Task {
            do {
                let offset = try await SNTPClient.offset(host: "time.apple.com")
                clockOffset = offset
                // poniżej 5 ms - „0.00”, a nie „-0.00” (ujemne zero po zaokrągleniu)
                let shown = String(format: "%+.2f", abs(offset) < 0.005 ? 0 : offset)
                clockStatus = abs(offset) < 0.2 ? L("Zegar Maca zgodny z UTC ({1} s).", shown)
                    : L("Zegar Maca różni się od UTC o {1} s - włącz w Ustawieniach systemowych automatyczne ustawianie czasu.",
                        shown)
            } catch {
                clockOffset = nil
                clockStatus = L("Nie udało się sprawdzić zegara (brak internetu?).")
            }
        }
    }
}

/// Wodospad - osobny obiekt obserwowany tylko przez widok wodospadu.
@MainActor
final class FT8WaterfallModel: ObservableObject {
    @Published var frame: FTWaterfallFrame?
}

@MainActor
final class FT8Holder: ObservableObject {
    let manager = FT8Manager()
}

/// Jednorazowe zapytanie SNTP (RFC 4330): różnica między zegarem Maca a serwerem czasu.
enum SNTPClient {
    enum Failure: Error { case timeout, badReply }

    static func offset(host: String, timeout: Double = 3) async throws -> Double {
        let request = SNTPRequest(host: host)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            request.start(timeout: timeout) { result in continuation.resume(with: result) }
        }
    }
}

/// Jedno zapytanie: wynik oddawany dokładnie raz (odpowiedź, błąd albo limit czasu - co pierwsze).
final class SNTPRequest: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Double, Error>) -> Void)?
    private var sentAt = 0.0

    init(host: String) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: 123, using: .udp)
    }

    func start(timeout: Double, completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        lock.lock()
        self.completion = completion
        sentAt = Date().timeIntervalSince1970
        lock.unlock()
        connection.stateUpdateHandler = { [self] state in
            if case .failed(let error) = state { finish(.failure(error)) }
        }
        connection.start(queue: .global(qos: .utility))
        var packet = Data(count: 48)
        packet[0] = 0x1B                                           // LI = 0, wersja 3, tryb klienta
        connection.send(content: packet, completion: .contentProcessed { [self] error in
            if let error { finish(.failure(error)) }
        })
        connection.receiveMessage { [self] data, _, _, error in
            let t4 = Date().timeIntervalSince1970
            if let error { finish(.failure(error)); return }
            guard let data, data.count >= 48 else { finish(.failure(SNTPClient.Failure.badReply)); return }
            let t2 = Self.timestamp(data, at: 32), t3 = Self.timestamp(data, at: 40)   // odbiór i nadanie u serwera
            guard t3 > 0 else { finish(.failure(SNTPClient.Failure.badReply)); return }
            lock.lock(); let t1 = sentAt; lock.unlock()
            finish(.success(((t2 - t1) + (t3 - t4)) / 2))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(SNTPClient.Failure.timeout))
        }
    }

    private func finish(_ result: Result<Double, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        guard let callback else { return }                         // wynik już oddany
        connection.cancel()
        callback(result)
    }

    /// Znacznik czasu NTP (sekundy od 1900 + ułamek 2^-32) jako czas UNIX.
    private static func timestamp(_ data: Data, at offset: Int) -> Double {
        let bytes = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + 8])
        var seconds: UInt32 = 0, fraction: UInt32 = 0
        for i in 0..<4 { seconds = seconds << 8 | UInt32(bytes[i]) }
        for i in 4..<8 { fraction = fraction << 8 | UInt32(bytes[i]) }
        return Double(seconds) - 2_208_988_800 + Double(fraction) / 4_294_967_296
    }
}


/// Wybór wołającego, gdy na CQ odpowiada kilka stacji naraz.
enum FTCallerPreference: String, CaseIterable, Identifiable {
    case strongest, weakest, farthest, nearest

    var id: String { rawValue }

    var name: String {
        switch self {
        case .strongest: return L("najsilniejszy (najwyższy SNR)")
        case .weakest: return L("najsłabszy (najniższy SNR)")
        case .farthest: return L("najdalej")
        case .nearest: return L("najbliżej")
        }
    }

    /// Indeks wybranego kandydata. Odległość nieznana - na końcu; przy równej odległości albo SNR
    /// rozstrzyga wyższy SNR.
    func choose(_ candidates: [(snr: Int, km: Double?)]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let indices = Array(candidates.indices)
        func better(_ a: Int, _ b: Int) -> Bool {             // czy a przed b
            let x = candidates[a], y = candidates[b]
            switch self {
            case .strongest: return x.snr > y.snr
            case .weakest: return x.snr < y.snr
            case .farthest, .nearest:
                switch (x.km, y.km) {
                case let (dx?, dy?):
                    if abs(dx - dy) < 1 { return x.snr > y.snr }
                    return self == .farthest ? dx > dy : dx < dy
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return x.snr > y.snr
                }
            }
        }
        return indices.min { better($0, $1) }
    }
}
