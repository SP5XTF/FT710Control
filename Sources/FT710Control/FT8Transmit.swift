import Foundation
import AVFoundation
import CoreLocation

/// Nadawanie FT8/FT4 (etap 2): komunikaty Tx1…Tx6 jak w WSJT-X, automatyczna sekwencja QSO,
/// nadawanie zsynchronizowane z cyklem UTC (PTT na początku cyklu, dźwięk 0,5 s później),
/// zapis QSO do dziennika po wysłaniu RR73 / 73.
extension FT8Manager {

    // MARK: - Komunikaty

    var myCallUpper: String { logbook?.myCall.uppercased().trimmingCharacters(in: .whitespaces) ?? "" }
    var myGrid4: String { String((logbook?.myGrid ?? "").uppercased().trimmingCharacters(in: .whitespaces).prefix(4)) }

    /// Raport w formacie FT8: −30…+30 dB, zawsze ze znakiem i dwiema cyframi („-05”, „+03”).
    /// Poza tym zakresem koder zamieniłby raport w inny komunikat (−31 → „73”).
    static func reportText(_ snr: Int) -> String {
        let v = max(-30, min(30, snr))
        return (v < 0 ? "-" : "+") + String(format: "%02d", abs(v))
    }

    /// Tx1…Tx6 z bieżącego znaku DX, lokatora i raportu (jak przycisk „Generate Std Msgs” w WSJT-X).
    func generateMessages() {
        let my = myCallUpper
        let dx = dxCall.uppercased().trimmingCharacters(in: .whitespaces)
        let grid = myGrid4
        let rpt = Self.reportText(reportSent)
        var list = ["", "", "", "", "", ""]
        if !my.isEmpty {
            if !dx.isEmpty {
                list[0] = grid.isEmpty ? "\(dx) \(my)" : "\(dx) \(my) \(grid)"
                list[1] = "\(dx) \(my) \(rpt)"
                list[2] = "\(dx) \(my) R\(rpt)"
                list[3] = "\(dx) \(my) RR73"
                list[4] = "\(dx) \(my) 73"
            }
            list[5] = grid.isEmpty ? "CQ \(my)" : "CQ \(my) \(grid)"
        }
        txMessages = list
    }

    /// Sprawdzenie koderem każdego komunikatu: echo = to, co zobaczy odbiorca.
    func checkMessages() {
        checkGeneration += 1
        let generation = checkGeneration
        let mode = self.mode
        for (index, raw) in txMessages.enumerated() {
            let text = raw.uppercased().trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if txEchoes.indices.contains(index) { txEchoes[index] = ""; txValid[index] = false }
                continue
            }
            receiver.prepare(text, mode: mode, f0: 0, sampleRate: 0) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.checkGeneration == generation, self.txEchoes.indices.contains(index) else { return }
                    self.txValid[index] = result.matches(text)
                    self.txEchoes[index] = result.code > 0 ? result.echo : L("nie da się zakodować")
                }
            }
        }
    }

    /// Ostatnia akcja operatora albo postęp QSO - do watchdoga.
    func touch() { lastActivity = Date() }

    // MARK: - Działania operatora

    /// Podwójne kliknięcie komunikatu: wywołanie tej stacji (jak w WSJT-X).
    func call(_ decode: FTDecode) {
        guard !decode.isSeparator, !decode.isTX, let from = decode.info.from, FTMessageInfo.isCallsign(from),
              !myCallUpper.isEmpty else { return }
        select(decode)
        // Hound: TX zostaje powyżej 1000 Hz (Fox nie odpowiada wołającym niżej); bez trybu Hound - jak w WSJT-X
        if !holdTxFreq, !houndMode { txFreq = decode.freq }
        if houndMode {
            if txFreq < 1000 { txFreq = 1000 + Int.random(in: 0...150) * 10 }
            houndCallFreq = txFreq
            houndR3Sent = 0
        }
        txFirst = !Self.isEvenSlot(decode.slot, period: decode.mode.period)   // nadajemy w drugim cyklu niż ona
        unansweredCount = 0
        qsoFromCQ = decode.toMe                                // ktoś wołał nas (np. na CQ) - albo nasze S&P
        if decode.toMe {
            respond(to: decode)                                // stacja woła nas - odpowiedź wg tego, co przysłała
        } else {
            startQSO(with: from, grid: decode.info.grid ?? "", snr: decode.snr)
            // Tx1: znak + lokator; „Pomiń Tx1” - od razu raport (Tx2); Hound zawsze od Tx1
            nextTx = skipTx1 && !houndMode ? 1 : 0
        }
        txStatus = nil
        txEnabled = true
        touch()
    }

    /// Wołanie CQ (Tx6).
    func callCQ() {
        guard !myCallUpper.isEmpty else { txStatus = L("Uzupełnij znak w profilu stacji."); return }
        nextTx = 5
        unansweredCount = 0
        txStatus = nil
        txEnabled = true
        touch()
    }

    private func startQSO(with call: String, grid: String, snr: Int) {
        dxCall = call
        dxGrid = grid
        reportSent = max(-30, min(30, snr))
        reportReceived = nil
        qsoStart = Date()
        generateMessages()
    }

    // MARK: - Sekwencer QSO (po każdym cyklu odbioru)

    func sequence(after items: [FTDecode]) {
        guard autoSequence, !myCallUpper.isEmpty else { return }
        if houndMode {
            houndSequence(items)
            return
        }
        let dxBase = dxCall.isEmpty ? "" : QRZClient.baseCall(dxCall.uppercased())
        let toMe = items.filter { $0.toMe && ($0.info.from.map(FTMessageInfo.isCallsign) ?? false) }
        guard !toMe.isEmpty else { return }
        // najpierw stacja, z którą prowadzimy QSO; przy wołaniu CQ - wybór według ustawienia (SNR / odległość)
        var fromDX = toMe.first { QRZClient.baseCall($0.info.from ?? "") == dxBase && !dxBase.isEmpty }
        // „73” od stacji z już zapisanego QSO - nic do zrobienia; nie może zasłonić następnego wołającego
        if let f = fromDX, f.info.report == "73", loggedCall == dxBase { fromDX = nil }
        let callingCQ = nextTx == 5 || dxCall.isEmpty
        var decode = fromDX
        if decode == nil, callingCQ {
            // wołający: komunikaty z lokatorem albo raportem (nie zakończenia 73 / RR73 / RRR innych QSO)
            let callers = toMe.filter { !["73", "RR73", "RRR"].contains($0.info.report ?? "") }
            let candidates = callers.map { (snr: $0.snr, km: distanceKm(to: $0)) }
            decode = callerPreference.choose(candidates).map { callers[$0] }
            if decode != nil { qsoFromCQ = true }
        }
        guard let decode else { return }
        respond(to: decode)
    }

    /// Hound (DXpedycja, zasady WSJT-X): raport od Foxa → Tx3 „R+raport” na częstotliwości Foxa (powtórzenia
    /// o 300 Hz wyżej); RR73 od Foxa → zapis QSO i koniec nadawania (Hound nie wysyła 73). Fox nadaje
    /// zwykłe komunikaty albo połączone „K1ABC RR73; MYCALL <FOX> -12”.
    private func houndSequence(_ items: [FTDecode]) {
        guard !dxCall.isEmpty else { return }
        let fox = QRZClient.baseCall(dxCall.uppercased())
        let me = QRZClient.baseCall(myCallUpper)
        func fromFox(_ d: FTDecode) -> Bool {
            if let from = d.info.from, FTMessageInfo.isCallsign(from) { return QRZClient.baseCall(from) == fox }
            // połączony komunikat z nieznanym jeszcze skrótem znaku (<...>) - Fox nadaje poniżej 1000 Hz
            return d.info.rr73To != nil && d.freq < 1000
        }
        let mine = items.filter { $0.toMe && fromFox($0) }
        // RR73 dla nas - QSO zaliczone
        if mine.contains(where: { ($0.info.rr73To.map { QRZClient.baseCall($0) == me } ?? false)
                                  || (($0.info.to.map { QRZClient.baseCall($0) == me } ?? false) && ["RR73", "RRR"].contains($0.info.report ?? "")) }) {
            logQSO()
            txEnabled = false
            nextTx = 0
            if houndCallFreq >= 1000 { txFreq = houndCallFreq }
            houndR3Sent = 0
            txStatus = L("Hound: QSO z {1} zaliczone (RR73) i zapisane w dzienniku.", dxCall.uppercased())
            txStatusIsInfo = true
            touch()
            return
        }
        // raport dla nas - R+raport (Tx3) na częstotliwości Foxa
        if let report = mine.first(where: { ($0.info.to.map { QRZClient.baseCall($0) == me } ?? false)
                                            && Self.isReport($0.info.report ?? "") }) {
            reportReceived = report.info.report
            reportSent = max(-30, min(30, report.snr))
            houndFoxFreq = report.freq
            txFreq = houndR3Sent == 0 ? report.freq : min(report.freq + 300, 2900)
            txFirst = !Self.isEvenSlot(report.slot, period: report.mode.period)
            nextTx = 2
            unansweredCount = 0
            if txArmed {
                txEnabled = true
            } else {
                txStatus = L("Hound: {1} odpowiada - włącz „Odblokuj TX”, żeby wysłać R+raport.", dxCall.uppercased())
            }
            touch()
        }
    }

    /// Odległość dla list FT8: km i czy przybliżona (bez lokatora - środek kraju z cty.dat).
    func distanceText(to decode: FTDecode) -> String {
        guard let home = Geo.coordinate(fromGrid: logbook?.myGrid ?? ""), let call = decode.info.from,
              FTMessageInfo.isCallsign(call) else { return "" }
        if let grid = decode.info.grid ?? knownGrids[QRZClient.baseCall(call)], let there = Geo.coordinate(fromGrid: grid) {
            return "\(Int(Geo.distanceKm(home, there).rounded()))"
        }
        guard let entity = CTYDatabase.shared.table?.lookup(call)?.entity else { return "" }
        let km = Geo.distanceKm(home, CLLocationCoordinate2D(latitude: entity.latitude, longitude: entity.longitude))
        return "~\(Int(km.rounded()))"
    }

    /// Odległość do stacji (km): lokator z komunikatu, z wcześniejszych komunikatów tej stacji w tej sesji,
    /// a bez lokatora - położenie kraju z cty.dat. nil - brak własnego lokatora albo nieznany kraj.
    func distanceKm(to decode: FTDecode) -> Double? {
        guard let home = Geo.coordinate(fromGrid: logbook?.myGrid ?? ""), let call = decode.info.from else { return nil }
        if let grid = decode.info.grid ?? knownGrids[QRZClient.baseCall(call)], let there = Geo.coordinate(fromGrid: grid) {
            return Geo.distanceKm(home, there)
        }
        guard let entity = CTYDatabase.shared.table?.lookup(call)?.entity else { return nil }
        return Geo.distanceKm(home, CLLocationCoordinate2D(latitude: entity.latitude, longitude: entity.longitude))
    }

    /// Odpowiedź na komunikat skierowany do nas - wybór następnego Tx wg standardowej sekwencji.
    func respond(to decode: FTDecode) {
        guard let from = decode.info.from else { return }
        unansweredCount = 0                                    // stacja odpowiada - liczymy od nowa
        let isCurrent = !dxCall.isEmpty && QRZClient.baseCall(from) == QRZClient.baseCall(dxCall.uppercased())
        if !isCurrent {
            startQSO(with: from, grid: decode.info.grid ?? "", snr: decode.snr)
        } else if let grid = decode.info.grid, dxGrid.isEmpty {
            dxGrid = grid
        }
        txFirst = !Self.isEvenSlot(decode.slot, period: decode.mode.period)
        let report = decode.info.report ?? ""
        switch report {
        case "":
            nextTx = 1                                         // przysłała lokator → nasz raport (Tx2)
        case "RRR", "RR73":
            nextTx = 4                                         // potwierdziła → 73 (Tx5), potem zapis
        case "73":
            if loggedCall == QRZClient.baseCall(from) { return } // QSO już zapisane - nic nie wysyłamy
            nextTx = 4
        default:
            if report.hasPrefix("R"), Self.isReport(String(report.dropFirst())) {
                reportReceived = String(report.dropFirst())
                nextTx = 3                                     // R-raport → RR73 (Tx4), potem zapis
            } else if Self.isReport(report) {
                reportReceived = report
                nextTx = 2                                     // raport → R + nasz raport (Tx3)
            } else {
                return
            }
        }
        touch()
    }

    static func isReport(_ s: String) -> Bool {
        s.count == 3 && (s.hasPrefix("+") || s.hasPrefix("-")) && s.dropFirst().allSatisfy(\.isNumber)
    }

    static func isEvenSlot(_ date: Date, period: Double) -> Bool {
        Int((date.timeIntervalSince1970 / period).rounded(.down)) % 2 == 0
    }

    // MARK: - Harmonogram nadawania

    func startScheduler() {
        guard schedulerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedulerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
    }

    /// Zgoda „Odblokuj TX” z okna głównego; jej cofnięcie przerywa nadawanie natychmiast.
    func setTXArmed(_ armed: Bool) {
        txArmed = armed
        if !armed, transmitting || txEnabled { haltTX(L("Cofnięto „Odblokuj TX” - nadawanie zatrzymane.")) }
    }

    func txEnabledChanged() {
        touch()
        if !txEnabled { preparingSlot = nil }              // bieżące nadawanie kończy się normalnie (jak w WSJT-X)
    }

    private func schedulerTick() {
        let now = Date().timeIntervalSince1970
        if transmitting {
            txProgress = min(1, max(0, (now - txStartedAt) / max(txDuration, 0.1)))
            // radio przestało nadawać (limit czasu CAT, rozłączenie) - kończymy
            if now - txStartedAt > 1.5, let cat, !cat.transmitting || !cat.isConnected {
                haltTX(L("Nadawanie przerwane - radio nie nadaje (limit czasu albo rozłączenie)."))
            }
            return
        }
        guard txEnabled else { return }
        if now - lastActivity.timeIntervalSince1970 > Double(watchdogMinutes) * 60 {
            haltTX(L("Watchdog: {1} min bez Twojej reakcji - nadawanie wyłączone.", watchdogMinutes))
            return
        }
        let period = mode.period
        let slotStart = (now / period).rounded(.down) * period
        let into = now - slotStart
        let next = slotStart + period
        let lateLimit = mode == .ft8 ? 2.0 : 0.8           // spóźniony start w bieżącym cyklu (początek obcięty)
        if isTXSlot(slotStart), into < lateLimit, activeSlot != slotStart, preparingSlot != slotStart {
            prepareTX(for: slotStart)
        } else if isTXSlot(next), next - now < 0.5, activeSlot != next, preparingSlot != next {
            prepareTX(for: next)
        }
    }

    private func isTXSlot(_ slotStart: Double) -> Bool {
        let even = Int((slotStart / mode.period).rounded()) % 2 == 0
        return even == txFirst
    }

    private func txBlockReason() -> String? {
        guard txArmed else { return L("Nadawanie wymaga zaznaczenia „Odblokuj TX”.") }
        guard let cat, cat.isConnected else { return L("Radio nie jest połączone.") }
        guard let audio, audio.radioOut != 0 else { return L("Wybierz w zakładce AUDIO urządzenie „Do radia (TX)”.") }
        guard cat.modeCode == "C" else { return L("Radio nie jest w DATA-U - kliknij „Ustaw radio: DATA-U”.") }
        return nil
    }

    private func prepareTX(for slot: Double) {
        if let reason = txBlockReason() {
            txEnabled = false
            txStatus = reason
            return
        }
        let text = txMessages[nextTx].uppercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            txEnabled = false
            txStatus = L("Komunikat Tx{1} jest pusty.", nextTx + 1)
            return
        }
        preparingSlot = slot
        txGeneration += 1
        let generation = txGeneration
        let index = nextTx
        receiver.prepare(text, mode: mode, f0: Double(txFreq), sampleRate: 48_000) { [weak self] result in
            Task { @MainActor in
                guard let self, self.txGeneration == generation, self.preparingSlot == slot, self.txEnabled else { return }
                self.preparingSlot = nil
                guard result.matches(text) else {
                    self.txEnabled = false
                    self.txStatus = result.code > 0
                        ? L("Nie nadaję: odbiorca zobaczyłby „{1}” zamiast „{2}”.", result.echo, text)
                        : L("Nie nadaję: komunikatu „{1}” nie da się zakodować.", text)
                    return
                }
                self.startTX(slot: slot, samples: result.samples, text: result.echo, index: index)
            }
        }
    }

    private func startTX(slot: Double, samples original: [Float], text: String, index: Int) {
        guard let cat, let audio, txBlockReason() == nil else { return }
        let rate = 48_000.0
        let audioStart = slot + 0.5                            // nominalny początek sygnału (DT = 0)
        var samples = original
        var startAt = audioStart
        let now = Date().timeIntervalSince1970
        if now + 0.15 > audioStart {
            // spóźniony start: obcinamy początek, żeby reszta była na właściwym miejscu w cyklu
            let skip = Int(((now + 0.15) - audioStart) * rate)
            guard skip < samples.count - Int(rate * 3) else { return }
            samples.removeFirst(skip)
            startAt = audioStart + Double(skip) / rate
        }
        let level = Float(txLevel)
        if level != 1 { for i in samples.indices { samples[i] *= level } }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(audio.radioOut)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            txEnabled = false
            txStatus = L("Audio TX: {1}", error.localizedDescription)
            return
        }
        txEngine = engine
        txPlayer = player
        activeSlot = slot
        transmitting = true
        txText = text
        txProgress = 0
        txStatus = nil
        txStartedAt = startAt
        txDuration = Double(samples.count) / rate
        receiver.suppress(slotStart: slot)                     // własnego sygnału nie dekodujemy
        let generation = txGeneration

        // PTT na początku cyklu (albo od razu przy spóźnionym starcie), dźwięk dokładnie o startAt
        let pttDelay = max(0, slot - Date().timeIntervalSince1970)
        DispatchQueue.main.asyncAfter(deadline: .now() + pttDelay) { [weak self] in
            guard let self, self.transmitting, self.txGeneration == generation else { return }
            cat.ptt(true)
        }
        let delay = max(0, startAt - Date().timeIntervalSince1970)
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.txGeneration == generation else { return }
                self.finishTX(sent: text, index: index, slot: slot)
            }
        }
        player.play(at: AVAudioTime(hostTime: hostTime))
    }

    /// Koniec nadawania komunikatu: PTT off, wpis na liście, zapis QSO po RR73 / 73.
    private func finishTX(sent text: String, index: Int, slot: Double) {
        guard transmitting else { return }
        stopAudioAndPTT()
        appendTX(text, slot: slot)
        if houndMode, index == 2 {
            // Hound: pierwsze R+raport na częstotliwości Foxa, powtórzenia o 300 Hz wyżej; Fox odsyła RR73 do 3 razy
            houndR3Sent += 1
            if houndR3Sent == 1, houndFoxFreq > 0 { txFreq = min(houndFoxFreq + 300, 2900) }
            if houndR3Sent >= 5 {
                houndR3Sent = 0
                nextTx = 0
                if houndCallFreq >= 1000 { txFreq = houndCallFreq }
                haltTX(L("Hound: brak RR73 od {1} po 5 × R+raport - nadawanie wyłączone (sprawdź w jego logu online).", dxCall.uppercased()))
                return
            }
        }
        if index <= 2, !(houndMode && index == 0) {            // Tx1-Tx3 bez odpowiedzi (Hound: wołanie Foxa bez limitu)
            unansweredCount = text == unansweredText ? unansweredCount + 1 : 1
            unansweredText = text
            if callLimit > 0, unansweredCount >= callLimit {
                let call = dxCall
                unansweredCount = 0
                haltTX(L("{1} nie odpowiada po {2} wywołaniach - nadawanie wyłączone.", call, callLimit))
                return
            }
        }
        if index == 3 || index == 4 {                          // RR73 albo 73 - QSO kompletne
            logQSO()
            // po QSO z naszego CQ: zostajemy w nadawaniu - następny wołający albo znowu CQ
            if disableAfter73, !(answerNextCaller && qsoFromCQ) { txEnabled = false }
            nextTx = 5
            unansweredCount = 0
        }
    }

    func modeChangedForTX() {
        if transmitting || txEnabled { haltTX(L("Zmiana trybu - nadawanie zatrzymane.")) }
        checkMessages()                                        // FT4 i FT8 kodują tak samo, ale echo odświeżamy
    }

    /// Natychmiastowe zatrzymanie („Zatrzymaj” / Halt Tx w WSJT-X) i wyłączenie TX.
    func haltTX(_ message: String? = nil) {
        txGeneration += 1                                      // unieważnia przygotowania i zaplanowane PTT
        preparingSlot = nil
        if transmitting { stopAudioAndPTT() }
        if txEnabled { txEnabled = false }
        if let message { txStatus = message }
    }

    private func stopAudioAndPTT() {
        transmitting = false
        txProgress = 0
        txPlayer?.stop()
        txEngine?.stop()
        txPlayer = nil
        txEngine = nil
        cat?.ptt(false)
    }

    private func appendTX(_ text: String, slot: Double) {
        var entry = FTDecode(slot: Date(timeIntervalSince1970: slot), mode: mode, snr: 0, dt: 0, freq: txFreq,
                             text: text, info: FTMessageInfo.parse(text), country: "", highlights: [.transmitted], toMe: false)
        entry.isTX = true
        activity.append(entry)
    }

    // MARK: - Dziennik

    /// Zapis QSO (raz na stację): FT8, albo MFSK + SUBMODE FT4; częstotliwość = dial + ton nadawania.
    func logQSO() {
        guard let logbook, let cat, !dxCall.isEmpty else { return }
        let call = dxCall.uppercased()
        guard loggedCall != QRZClient.baseCall(call) else { return }
        let now = Date()
        let dial = cat.activeFreq
        var qso = QSO(call: call, start: qsoStart ?? now, end: now, freqHz: dial + txFreq,
                      band: Bands.name(for: dial) ?? "", mode: mode == .ft8 ? "FT8" : "MFSK",
                      submode: mode == .ft8 ? nil : "FT4")
        qso.rstSent = Self.reportText(reportSent)
        qso.rstRcvd = reportReceived ?? ""
        qso.grid = dxGrid.uppercased()
        qso.stationCall = logbook.myCall.uppercased()
        qso.myGrid = logbook.myGrid.uppercased()
        for (key, value) in logbook.profileADIFFields { qso.extra[key] = value }
        if let match = CTYDatabase.shared.table?.lookup(call) {
            qso.extra["COUNTRY"] = match.entity.name
            qso.extra["CQZ"] = String(match.cqZone)
            qso.extra["ITUZ"] = String(match.ituZone)
            qso.extra["CONT"] = match.continent
        }
        if let home = Geo.coordinate(fromGrid: qso.myGrid), let remote = Geo.coordinate(fromGrid: qso.grid) {
            qso.extra["DISTANCE"] = String(Int(Geo.distanceKm(home, remote).rounded()))
        }
        logbook.add(qso)
        loggedCall = QRZClient.baseCall(call)
        txStatus = L("Zapisano QSO: {1} ({2} / {3}).", call, qso.rstSent, qso.rstRcvd.isEmpty ? "—" : qso.rstRcvd)
        txStatusIsInfo = true
    }
}
