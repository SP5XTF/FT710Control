import Foundation

/// Odczyt skopu RF FT-710 przez wbudowany mostek FTDI FT4222 (VID 0403, PID 601C).
///
/// Protokół i parametry przeniesione z ft4222-scope-reader.c projektu RigControl Web
/// (https://github.com/jbdubbs/Rig-Control-Web), Copyright 2026 Jason Weisberger NT0Y,
/// licencja Apache 2.0 - patrz THIRD_PARTY_NOTICES.md.
///
/// - FT4222 pracuje jako SPI master: pojedyncza linia, 24 MHz / 64 = 375 kHz,
///   zegar w spoczynku wysoki, próbkowanie na zboczu wiodącym, CS0.
/// - Radio wysyła ramki po 4096 bajtów, zakończone wzorcem FF 01 EE 01 powtórzonym 4 razy
///   (bajty 4080-4095; sprawdzone na zrzutach z FT-710 użytkownika). Początek ramki to bajt
///   po OSTATNIM powtórzeniu - przy pierwszym ramka byłaby przesunięta o 12 bajtów, a pojedynczy
///   test wzorca na końcu i tak by przeszedł.
/// - Bajty 0..849: linia widma (wartości zanegowane bitowo; po negacji większa = silniejszy sygnał).
/// - Od bajtu 2900: metadane - span (indeks 0-9), tryb (2 = FIXED), częstotliwość środka i początku.
///
/// Czytnik działa na własnym wątku, bo odczyty z biblioteki FTDI są blokujące.
final class FT4222ScopeReader: @unchecked Sendable {
    struct Frame: Sendable {
        let amplitudes: [UInt8]   // 850 punktów, od lowHz do highHz
        let spanHz: Int
        let centerHz: Int
        let lowHz: Int
        let highHz: Int
        let fixedMode: Bool
        let raw: [UInt8]          // cała ramka 4096 bajtów (do analizy układu danych)
    }

    enum Event: Sendable {
        case opened(libraryPath: String)
        case frame(Frame)
        case log(String)
        /// Odzyskiwanie połączenia (komunikat do nagłówka skopu) i jego powodzenie.
        case recovering(String)
        case recovered(String)
        case error(String)
        case stopped
    }

    var onEvent: (@Sendable (Event) -> Void)?

    // MARK: - Stałe protokołu

    private static let frameSize = 4096
    private static let spectrumLength = 850
    private static let dataOffset = 2900     // po wf1(850) + wf2(850) + audio FFT/scope (200+400+200+400)
    private static let syncOffset = 4092
    private static let spanTable = [1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000]

    private static let openByDescription: UInt32 = 2
    private static let spiIOSingle: Int32 = 1
    private static let clockDiv64: Int32 = 6         // 24 MHz / 64 = 375 kHz
    private static let clockIdleHigh: Int32 = 1
    private static let clockLeading: Int32 = 0
    private static let systemClock24MHz: Int32 = 0
    private static let purgeRxTx: UInt32 = 1 | 2

    // MARK: - Stan

    private var lib: FT4222Library?
    private var device: FT4222Library.Handle?
    private var frame = [UInt8](repeating: 0, count: 4096)

    private let lock = NSLock()
    private var running = false
    private var finished: DispatchSemaphore?

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let done = DispatchSemaphore(value: 0)
        finished = done
        lock.unlock()

        let thread = Thread { [self] in
            run()
            done.signal()
        }
        thread.name = "ft710.ft4222"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Prosi wątek o zakończenie (nie czeka).
    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    /// Kończy i czeka na zamknięcie urządzenia (np. przy wychodzeniu z aplikacji).
    func stopAndWait(timeout: TimeInterval = 1.5) {
        lock.lock()
        running = false
        let done = finished
        lock.unlock()
        _ = done?.wait(timeout: .now() + timeout)
    }

    // MARK: - Wątek czytnika

    private func run() {
        defer {
            closeDevice()
            lock.lock(); running = false; finished = nil; lock.unlock()
            emit(.stopped)
        }

        do {
            lib = try FT4222Library.load()
        } catch {
            emit(.error(error.localizedDescription))
            return
        }

        if let message = openDevice() {
            emit(.error(message))
            return
        }
        emit(.opened(libraryPath: lib?.path ?? "?"))

        var syncFails = 0
        var frameReady = false   // true: `frame` zawiera już zweryfikowaną ramkę z resync()

        while isRunning {
            if !frameReady {
                guard readFully(into: 0, count: Self.frameSize) else {
                    syncFails += 1
                    if syncFails >= 5 {
                        syncFails = 0
                        emit(.recovering(L("Powtarzające się błędy odczytu - odzyskiwanie połączenia")))
                        frameReady = recover()
                    }
                    continue
                }
            }
            frameReady = false

            guard frameIsAligned() else {
                syncFails += 1
                if syncFails >= 5 {
                    syncFails = 0
                    emit(.log(L("Utracona synchronizacja ramek - szukam początku ramki")))
                    switch resync() {
                    case .found: frameReady = true
                    case .readError, .notFound: frameReady = recover()
                    }
                }
                continue
            }
            syncFails = 0
            if let parsed = parseFrame() { emit(.frame(parsed)) }
        }
    }

    /// Odzyskiwanie połączenia ze skopem - bez limitu prób, dopóki skop jest włączony (wcześniej po 20 problemach
    /// w ciągu całej sesji albo po jednym błędzie odczytu przy synchronizacji czytnik kończył pracę na stałe
    /// i pomagał tylko restart radia). Odstępy rosnące: 1, 2, 5, 10, potem co 30 s; co trzecia próba -
    /// sprzętowy reset układu FT4222 (jeśli biblioteka go ma). true - w `frame` jest zsynchronizowana ramka.
    private func recover() -> Bool {
        let delays: [Double] = [1, 2, 5, 10, 30]
        var attempt = 0
        while isRunning {
            attempt += 1
            if attempt % 3 == 0, let reset = lib?.chipReset, openDevice() == nil, let handle = device {
                emit(.recovering(L("Reset układu FT4222 (próba {1})", attempt)))
                _ = reset(handle)
                closeDevice()
                guard pause(2) else { return false }        // układ zgłasza się na USB od nowa
            }
            if openDevice() == nil {
                switch resync() {
                case .found:
                    if attempt > 1 { emit(.recovered(L("Połączenie ze skopem odzyskane (próba {1})", attempt))) }
                    return true
                case .notFound:
                    return false                             // urządzenie działa - dalej zwykły odczyt
                case .readError:
                    break
                }
            }
            emit(.recovering(L("Odzyskiwanie połączenia ze skopem - próba {1} nieudana", attempt)))
            guard pause(delays[min(attempt - 1, delays.count - 1)]) else { return false }
        }
        return false
    }

    /// Czekanie w krótkich odcinkach - wyłączenie skopu przerywa od razu. false - skop wyłączony.
    private func pause(_ seconds: Double) -> Bool {
        var left = seconds
        while left > 0 {
            guard isRunning else { return false }
            usleep(100_000)
            left -= 0.1
        }
        return isRunning
    }

    // MARK: - Urządzenie

    /// Zwraca opis błędu albo nil, gdy urządzenie jest gotowe.
    private func openDevice() -> String? {
        guard let lib else { return L("Biblioteka FT4222 nie jest załadowana") }

        if device != nil {
            closeDevice()
            // CS nieaktywne dłużej niż jedna ramka (~87 ms), żeby DSP radia wyzerował licznik bajtów ramki.
            usleep(250_000)
        }

        var handle: FT4222Library.Handle?
        let status = "FT4222 A".withCString { name in
            lib.openEx(UnsafeMutableRawPointer(mutating: name), Self.openByDescription, &handle)
        }
        guard status == 0, let handle else {
            return L("Nie można otworzyć FT4222 (status {1}). Sprawdź, czy radio jest włączone, SCU-LAN10 = ON i czy żaden inny program (np. RigControl Web) nie używa skopu.", status)
        }
        device = handle

        func fail(_ what: String, _ code: UInt32) -> String {
            closeDevice()
            return L("{1} nie powiodło się (status {2})", what, code)
        }
        var st = lib.setTimeouts(handle, 100, 100)
        if st != 0 { return fail("FT_SetTimeouts", st) }
        st = lib.setLatencyTimer(handle, 2)
        if st != 0 { return fail("FT_SetLatencyTimer", st) }
        st = lib.spiMasterInit(handle, Self.spiIOSingle, Self.clockDiv64, Self.clockIdleHigh, Self.clockLeading, 0x01)
        if st != 0 { return fail("FT4222_SPIMaster_Init", st) }
        st = lib.setClock(handle, Self.systemClock24MHz)
        if st != 0 { return fail("FT4222_SetClock", st) }
        _ = lib.purge(handle, Self.purgeRxTx)   // stare dane z buforów USB
        return nil
    }

    private func closeDevice() {
        guard let lib, let handle = device else { return }
        _ = lib.unInitialize(handle)
        _ = lib.close(handle)
        device = nil
    }

    /// Czyta dokładnie `count` bajtów do `frame` od pozycji `offset`.
    private func readFully(into offset: Int, count: Int) -> Bool {
        guard let lib, let handle = device, count > 0, offset + count <= frame.count else { return false }
        var got: UInt16 = 0
        let st = frame.withUnsafeMutableBufferPointer { buffer in
            lib.spiMasterSingleRead(handle, buffer.baseAddress! + offset, UInt16(count), &got, 0)
        }
        return st == 0 && Int(got) == count
    }

    private func hasSync(at offset: Int) -> Bool {
        frame[offset] == 0xFF && frame[offset + 1] == 0x01 && frame[offset + 2] == 0xEE && frame[offset + 3] == 0x01
    }

    /// Ramka jest wyrównana, gdy wszystkie 4 powtórzenia wzorca są na końcu,
    /// a sama ramka NIE zaczyna się od wzorca (to byłby znak przesunięcia).
    private func frameIsAligned() -> Bool {
        hasSync(at: 4080) && hasSync(at: 4084) && hasSync(at: 4088) && hasSync(at: Self.syncOffset)
            && !hasSync(at: 0)
    }

    // MARK: - Synchronizacja

    private enum ResyncResult { case found, notFound, readError }

    /// Szuka wzorca FF 01 EE 01 w strumieniu (czytając blokami po 4096 bajtów),
    /// dociąga pełną ramkę i sprawdza wzorzec na jej końcu oraz sensowność metadanych.
    private func resync() -> ResyncResult {
        guard let lib, let handle = device else { return .readError }
        var buffer = [UInt8](repeating: 0, count: Self.frameSize + 3)   // +3 na wzorzec przecinający granicę bloków
        var carry = 0
        var scanned = 0
        let maxScan = Self.frameSize * 40

        while scanned < maxScan && isRunning {
            var got: UInt16 = 0
            let st = buffer.withUnsafeMutableBufferPointer { b in
                lib.spiMasterSingleRead(handle, b.baseAddress! + carry, UInt16(Self.frameSize), &got, 0)
            }
            if st != 0 || got == 0 { return .readError }
            scanned += Int(got)
            let total = carry + Int(got)

            var restartScan = false
            var i = 0
            while i <= total - 4 {
                guard buffer[i] == 0xFF, buffer[i + 1] == 0x01, buffer[i + 2] == 0xEE, buffer[i + 3] == 0x01 else {
                    i += 1
                    continue
                }
                // Wzorzec jest powtórzony - przejdź do ostatniego powtórzenia w buforze.
                while i + 8 <= total,
                      buffer[i + 4] == 0xFF, buffer[i + 5] == 0x01, buffer[i + 6] == 0xEE, buffer[i + 7] == 0x01 {
                    i += 4
                }
                // Bajty po wzorcu to początek ramki.
                let have = min(total - (i + 4), Self.frameSize)
                if have > 0 {
                    for k in 0..<have { frame[k] = buffer[i + 4 + k] }
                }
                let need = Self.frameSize - have
                if need > 0 {
                    guard readFully(into: have, count: need) else { return .readError }
                    scanned += need
                }
                if frameIsAligned(), metadataLooksValid() {
                    emit(.log(L("Synchronizacja ramek odzyskana po {1} bajtach", scanned)))
                    return .found
                }
                restartScan = true   // fałszywe trafienie - czytamy dalej od nowa
                carry = 0
                break
            }

            if !restartScan {
                if total >= 3 {
                    buffer[0] = buffer[total - 3]
                    buffer[1] = buffer[total - 2]
                    buffer[2] = buffer[total - 1]
                    carry = 3
                } else {
                    carry = 0
                }
            }
        }
        return .notFound
    }

    // MARK: - Ramka

    private func uint32(at offset: Int) -> Int {
        Int(frame[offset]) << 24 | Int(frame[offset + 1]) << 16 | Int(frame[offset + 2]) << 8 | Int(frame[offset + 3])
    }

    private func metadataLooksValid() -> Bool {
        let spanIndex = Int(frame[Self.dataOffset + 32])
        let center = uint32(at: Self.dataOffset + 132)
        return spanIndex <= 9 && center >= 1_000_000 && center <= 60_000_000
    }

    private func parseFrame() -> Frame? {
        var spanIndex = Int(frame[Self.dataOffset + 32])
        if spanIndex > 9 { spanIndex = 5 }
        let fixedMode = frame[Self.dataOffset + 52] == 2
        let center = uint32(at: Self.dataOffset + 132)
        let fixedStart = uint32(at: Self.dataOffset + 144)
        let span = Self.spanTable[spanIndex]

        let low = fixedMode ? fixedStart : max(center - span / 2, 0)
        let high = fixedMode ? fixedStart + span : center + span / 2

        // Bajty są zanegowane przez sprzęt radia. Punkt 0 to składowa stała
        // (przeciek LO) - radio go nie pokazuje, więc zastępujemy go sąsiednim.
        var amplitudes = [UInt8](repeating: 0, count: Self.spectrumLength)
        for i in 0..<Self.spectrumLength {
            amplitudes[i] = ~frame[i == 0 ? 1 : i]
        }
        return Frame(amplitudes: amplitudes, spanHz: span, centerHz: center,
                     lowHz: low, highHz: high, fixedMode: fixedMode, raw: frame)
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
