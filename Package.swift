// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FT710Control",
    platforms: [.macOS(.v13)],
    targets: [
        // RNNoise v0.1.1 (Xiph, licencja BSD) - sieć neuronowa do redukcji szumu w odsłuchu (poziom „AI”).
        .target(
            name: "RNNoise",
            path: "Sources/RNNoise",
            exclude: ["COPYING", "README.txt"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                // sieć neuronowa bez optymalizacji jest kilkanaście razy wolniejsza - także w Debug
                .unsafeFlags(["-O2"], .when(configuration: .debug))
            ]
        ),
        // ft8_lib (Kārlis Goba YL3JG, licencja MIT) + warstwa ftxw.c - kodowanie i dekodowanie FT8/FT4.
        .target(
            name: "FTX",
            path: "Sources/FTX",
            exclude: ["LICENSE", "README.txt"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                // ft8_lib przypisuje strlen() do int (napisy po kilkanaście znaków) - bez zmiany kodu biblioteki
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
                // dekodowanie cyklu bez optymalizacji trwałoby kilka razy dłużej - także w Debug
                .unsafeFlags(["-O2"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "FT710Control",
            dependencies: ["RNNoise", "FTX"],
            path: "Sources/FT710Control",
            resources: [.process("Resources")],                 // ikona aplikacji (AppIcon.png)
            swiftSettings: [
                // DSP (FFT, waterfall, dekodery SSTV/CW, filtry audio) bez optymalizacji jest 10-50× wolniejsze;
                // uruchamianie z Xcode (Debug) ma działać płynnie - kosztem dokładności debugera.
                .unsafeFlags(["-O"], .when(configuration: .debug))
            ]
        ),
        // Testy logiki (ADIF, FT8, potwierdzenia QSL, PSKReporter, DXCC, lokalizacja, POTA): `swift test`
        .testTarget(
            name: "FT710ControlTests",
            dependencies: ["FT710Control", "FTX"],
            path: "Tests/FT710ControlTests"
        )
    ]
)
