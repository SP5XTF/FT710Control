import Foundation
import Darwin

/// Dynamicznie ładowana biblioteka FTDI LibFT4222 (z wbudowanym D2XX).
/// Ładowanie w czasie działania sprawia, że aplikacja buduje się i działa bez niej -
/// brakuje wtedy tylko skopu RF.
///
/// Instalacja (macOS): pakiet „LibFT4222 for Mac" ze strony FTDI (FT4222H Software Examples), potem:
///   sudo cp libft4222.1.dylib /usr/local/lib/
///   sudo ln -sf /usr/local/lib/libft4222.1.dylib /usr/local/lib/libft4222.dylib
///   sudo xattr -d com.apple.quarantine /usr/local/lib/libft4222.1.dylib
final class FT4222Library {
    typealias Handle = UnsafeMutableRawPointer

    typealias FT_OpenEx = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<Handle?>?) -> UInt32
    typealias FT_Close = @convention(c) (Handle?) -> UInt32
    typealias FT_SetTimeouts = @convention(c) (Handle?, UInt32, UInt32) -> UInt32
    typealias FT_SetLatencyTimer = @convention(c) (Handle?, UInt8) -> UInt32
    typealias FT_Purge = @convention(c) (Handle?, UInt32) -> UInt32
    typealias FT4222_UnInitialize = @convention(c) (Handle?) -> UInt32
    typealias FT4222_SPIMaster_Init = @convention(c) (Handle?, Int32, Int32, Int32, Int32, UInt8) -> UInt32
    typealias FT4222_SPIMaster_SingleRead = @convention(c) (Handle?, UnsafeMutablePointer<UInt8>?, UInt16, UnsafeMutablePointer<UInt16>?, Int32) -> UInt32
    typealias FT4222_SetClock = @convention(c) (Handle?, Int32) -> UInt32
    typealias FT4222_ChipReset = @convention(c) (Handle?) -> UInt32

    let path: String
    let openEx: FT_OpenEx
    let close: FT_Close
    let setTimeouts: FT_SetTimeouts
    let setLatencyTimer: FT_SetLatencyTimer
    let purge: FT_Purge
    let unInitialize: FT4222_UnInitialize
    let spiMasterInit: FT4222_SPIMaster_Init
    let spiMasterSingleRead: FT4222_SPIMaster_SingleRead
    let setClock: FT4222_SetClock
    /// Sprzętowy reset układu FT4222 (opcjonalny - starsze wersje biblioteki mogą go nie mieć).
    let chipReset: FT4222_ChipReset?

    enum LoadError: LocalizedError {
        case notFound([String])
        case missingSymbol(String, String)

        var errorDescription: String? {
            switch self {
            case .notFound(let reasons):
                return L("Nie znaleziono libft4222.dylib. Zainstaluj LibFT4222 for Mac ze strony FTDI do /usr/local/lib i zdejmij kwarantannę (xattr). Szczegóły: {1}",
                         reasons.joined(separator: " | "))
            case .missingSymbol(let symbol, let path):
                return L("Biblioteka {1} nie zawiera funkcji {2} (potrzebna też libftd2xx.dylib?)", path, symbol)
            }
        }
    }

    private static var cached: FT4222Library?
    private static let cacheLock = NSLock()

    static func load() throws -> FT4222Library {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return cached }

        var reasons: [String] = []
        guard let opened = openFirst(candidates(prefix: "libft4222"), reasons: &reasons) else {
            throw LoadError.notFound(reasons)
        }
        let main = opened.handle
        let mainPath = opened.path
        // Starsze pakiety FTDI dla macOS trzymały funkcje FT_* w osobnej libftd2xx.dylib.
        var ignored: [String] = []
        let d2xx = openFirst(candidates(prefix: "libftd2xx"), reasons: &ignored)?.handle

        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            if let p = dlsym(main, name) ?? d2xx.flatMap({ dlsym($0, name) }) {
                return unsafeBitCast(p, to: type)
            }
            throw LoadError.missingSymbol(name, mainPath)
        }

        let lib = FT4222Library(
            path: mainPath,
            openEx: try symbol("FT_OpenEx", FT_OpenEx.self),
            close: try symbol("FT_Close", FT_Close.self),
            setTimeouts: try symbol("FT_SetTimeouts", FT_SetTimeouts.self),
            setLatencyTimer: try symbol("FT_SetLatencyTimer", FT_SetLatencyTimer.self),
            purge: try symbol("FT_Purge", FT_Purge.self),
            unInitialize: try symbol("FT4222_UnInitialize", FT4222_UnInitialize.self),
            spiMasterInit: try symbol("FT4222_SPIMaster_Init", FT4222_SPIMaster_Init.self),
            spiMasterSingleRead: try symbol("FT4222_SPIMaster_SingleRead", FT4222_SPIMaster_SingleRead.self),
            setClock: try symbol("FT4222_SetClock", FT4222_SetClock.self),
            chipReset: try? symbol("FT4222_ChipReset", FT4222_ChipReset.self))
        cached = lib
        return lib
    }

    private init(path: String, openEx: FT_OpenEx, close: FT_Close, setTimeouts: FT_SetTimeouts,
                 setLatencyTimer: FT_SetLatencyTimer, purge: FT_Purge, unInitialize: FT4222_UnInitialize,
                 spiMasterInit: FT4222_SPIMaster_Init, spiMasterSingleRead: FT4222_SPIMaster_SingleRead,
                 setClock: FT4222_SetClock, chipReset: FT4222_ChipReset?) {
        self.chipReset = chipReset
        self.path = path
        self.openEx = openEx
        self.close = close
        self.setTimeouts = setTimeouts
        self.setLatencyTimer = setLatencyTimer
        self.purge = purge
        self.unInitialize = unInitialize
        self.spiMasterInit = spiMasterInit
        self.spiMasterSingleRead = spiMasterSingleRead
        self.setClock = setClock
    }

    /// Kolejność: zmienna środowiskowa, typowe katalogi, potem dowolna wersja libft4222*.dylib z tych katalogów.
    private static func candidates(prefix: String) -> [String] {
        var result: [String] = []
        if prefix == "libft4222", let env = ProcessInfo.processInfo.environment["FT4222_LIB"] {
            result.append(env)
        }
        let dirs = ["/usr/local/lib", "/opt/homebrew/lib", NSHomeDirectory() + "/lib",
                    Bundle.main.bundlePath + "/Contents/Frameworks"]
        for dir in dirs {
            result.append("\(dir)/\(prefix).dylib")
            result.append("\(dir)/\(prefix).1.dylib")
        }
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files.sorted().reversed()
            where file.lowercased().hasPrefix(prefix) && file.hasSuffix(".dylib") {
                result.append("\(dir)/\(file)")
            }
        }
        return result
    }

    private static func openFirst(_ paths: [String], reasons: inout [String]) -> (handle: UnsafeMutableRawPointer, path: String)? {
        var tried = Set<String>()
        for path in paths where !tried.contains(path) {
            tried.insert(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                return (handle: handle, path: path)
            }
            // np. „incompatible architecture" albo blokada kwarantanny
            reasons.append(String(cString: dlerror()))
        }
        return nil
    }
}
