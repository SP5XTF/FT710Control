import Foundation
import Darwin

/// Kluczowanie CW linią DTR albo RTS portu Standard COM (CAT-2) radia.
/// W radiu: PC KEYING = DTR (lub RTS), BK-IN włączony, tryb CW.
/// Znaki generowane w osobnym wątku o najwyższym priorytecie z oczekiwaniem do bezwzględnych chwil
/// (mach_wait_until) - błędy czasu się nie kumulują.
final class CWKeyer: @unchecked Sendable {
    enum Line: String, CaseIterable, Identifiable {
        case dtr = "DTR", rts = "RTS"
        var id: String { rawValue }
        fileprivate var bit: Int32 { self == .dtr ? 0x002 : 0x004 }     // TIOCM_DTR, TIOCM_RTS
    }

    enum KeyerError: LocalizedError {
        case open(String)
        var errorDescription: String? {
            switch self { case .open(let m): return m }
        }
    }

    // _IOW('t', 108, int), _IOW('t', 107, int), _IOR('t', 106, int) - makra niedostępne w Swift
    private static let setBits: UInt = 0x8004_746C       // TIOCMBIS
    private static let clearBits: UInt = 0x8004_746B     // TIOCMBIC
    private static let getBits: UInt = 0x4004_746A       // TIOCMGET

    /// Wynik nadawania.
    enum Outcome: Sendable {
        case completed
        case stopped
        case failed(String)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var path = ""
    private var line = Line.dtr
    private var cancelled = false
    private(set) var busy = false

    deinit { close() }

    func open(path newPath: String, line newLine: Line) throws {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0, newPath == path { line = newLine; return }
        closeLocked()
        let descriptor = Darwin.open(newPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw KeyerError.open(L("Nie można otworzyć portu klucza {1}: {2}", newPath, String(cString: strerror(errno))))
        }
        fd = descriptor
        path = newPath
        line = newLine
        apply(Line.dtr, on: false)
        apply(Line.rts, on: false)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard fd >= 0 else { return }
        apply(.dtr, on: false)
        apply(.rts, on: false)
        Darwin.close(fd)
        fd = -1
        path = ""
    }

    /// Ustawia linię; nil = OK, w przeciwnym razie opis błędu systemu.
    @discardableResult
    private func apply(_ which: Line, on: Bool) -> String? {
        guard fd >= 0 else { return L("Port klucza nie jest otwarty.") }
        var bits = which.bit
        let result = withUnsafeMutablePointer(to: &bits) { ioctl(fd, on ? Self.setBits : Self.clearBits, $0) }
        return result == 0 ? nil : String(cString: strerror(errno))
    }

    /// Faktyczny stan linii odczytany z portu (nil = nie da się odczytać).
    private func lineState(_ which: Line) -> Bool? {
        guard fd >= 0 else { return nil }
        var bits: Int32 = 0
        let result = withUnsafeMutablePointer(to: &bits) { ioctl(fd, Self.getBits, $0) }
        return result == 0 ? (bits & which.bit) != 0 : nil
    }

    /// Plan nadawania: (stan klucza, czas w sekundach) dla tekstu przy danym tempie (PARIS: kropka 1,2/WPM s).
    static func schedule(for text: String, wpm: Double) -> [(Bool, Double)] {
        let dot = 1.2 / max(wpm, 5)
        var out: [(Bool, Double)] = []
        let words = text.uppercased().split(separator: " ", omittingEmptySubsequences: true)
        for (wi, word) in words.enumerated() {
            let chars = word.compactMap { Morse.table[$0] }
            for (ci, code) in chars.enumerated() {
                for (ei, element) in code.enumerated() {
                    out.append((true, element == "." ? dot : 3 * dot))
                    if ei < code.count - 1 { out.append((false, dot)) }
                }
                if ci < chars.count - 1 { out.append((false, 3 * dot)) }
            }
            if wi < words.count - 1 { out.append((false, 7 * dot)) }
        }
        return out
    }

    static func duration(of text: String, wpm: Double) -> Double {
        schedule(for: text, wpm: wpm).reduce(0) { $0 + $1.1 }
    }

    /// Nadaje tekst. `progress`: ułamek 0…1 (wątek klucza). `done`: wynik (całość / zatrzymane / błąd).
    func send(_ text: String, wpm: Double,
              progress: @escaping @Sendable (Double) -> Void,
              done: @escaping @Sendable (Outcome) -> Void) {
        let plan = Self.schedule(for: text, wpm: wpm)
        let total = max(plan.reduce(0) { $0 + $1.1 }, 0.001)
        lock.lock()
        guard fd >= 0, !busy else { lock.unlock(); done(.failed(L("Port klucza nie jest otwarty."))); return }
        busy = true
        cancelled = false
        let keyLine = line
        lock.unlock()

        let thread = Thread { [weak self] in
            guard let self else { return }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            func ticks(_ seconds: Double) -> UInt64 {
                UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
            }
            var deadline = mach_absolute_time() + ticks(0.02)
            var elapsed = 0.0
            var outcome = Outcome.completed
            var verified = false
            for (state, length) in plan {
                self.lock.lock()
                let stop = self.cancelled
                var failure: String?
                if !stop {
                    if let error = self.apply(keyLine, on: state) {
                        failure = L("System nie zmienił linii {1}: {2}", keyLine.rawValue, error)
                    } else if state, !verified {
                        // pierwsze wciśnięcie: czy linia naprawdę jest ustawiona?
                        verified = true
                        if self.lineState(keyLine) == false {
                            failure = L("Linia {1} nie zmienia stanu na tym porcie - sprawdź, czy wybrany jest port Standard COM (CAT-2) radia.", keyLine.rawValue)
                        }
                    }
                }
                self.lock.unlock()
                if stop { outcome = .stopped; break }
                if let failure { outcome = .failed(failure); break }
                deadline += ticks(length)
                mach_wait_until(deadline)
                elapsed += length
                progress(elapsed / total)
            }
            self.lock.lock()
            self.apply(keyLine, on: false)                         // zawsze klucz zwolniony na końcu
            self.busy = false
            self.lock.unlock()
            done(outcome)
        }
        thread.qualityOfService = .userInteractive
        thread.name = "ft710.cw.keyer"
        thread.start()
    }

    /// Natychmiastowe zatrzymanie: klucz zwolniony od razu, wątek kończy przy najbliższym elemencie.
    func stop() {
        lock.lock()
        cancelled = true
        apply(line, on: false)
        lock.unlock()
    }
}
