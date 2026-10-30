import Foundation
import IOKit
import SwiftUI
import AppKit

struct USBDeviceInfo: Hashable {
    let vendorID: Int
    let productID: Int
    let name: String

    var idText: String { String(format: "%04X:%04X", vendorID, productID) }
}

/// Sprawdza, które interfejsy USB radia widzi macOS.
/// FT-710 ma w środku: mostek USB-szeregowy Silicon Labs (CAT, dwa porty),
/// kodek audio USB oraz mostek FTDI FT4222 (dane skopu).
enum USBDiagnostics {
    static let siliconLabsVID = 0x10C4
    static let ftdiVID = 0x0403

    static func devices() -> [USBDeviceInfo] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBDeviceInfo] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let vid = intProperty(service, "idVendor"), let pid = intProperty(service, "idProduct") {
                let name = stringProperty(service, "USB Product Name")
                    ?? stringProperty(service, "kUSBProductString")
                    ?? L("(bez nazwy)")
                result.append(USBDeviceInfo(vendorID: vid, productID: pid, name: name))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }

    /// FT4222H (mostek SPI/I2C) - tym interfejsem FT-710 wysyła dane skopu.
    static let ft4222PIDs: Set<Int> = [0x601C]

    /// Znane PID-y FTDI, żeby inne urządzenia nie były mylone z interfejsem skopu.
    static func ftdiDescription(_ pid: Int) -> String {
        switch pid {
        case 0x6001: return L("FT232R (pojedynczy UART)")
        case 0x6010: return L("FT2232 (dwukanałowy UART/JTAG)")
        case 0x6011: return L("FT4232 (czterokanałowy UART)")
        case 0x6014: return L("FT232H (pojedynczy UART/MPSSE)")
        case 0x6015: return L("FT-X (pojedynczy UART)")
        default: return L("inne urządzenie FTDI")
        }
    }

    /// Raport tekstowy (do pokazania i skopiowania do zgłoszenia błędu).
    static func report(current: DiagnosticsSnapshot,
                       baseline: DiagnosticsSnapshot?,
                       catStatus: String) -> String {
        let usb = current.usb
        let catBridges = usb.filter { $0.vendorID == siliconLabsVID }
        let ft4222 = usb.filter { $0.vendorID == ftdiVID && ft4222PIDs.contains($0.productID) }
        let otherFTDI = usb.filter { $0.vendorID == ftdiVID && !ft4222PIDs.contains($0.productID) }

        var lines: [String] = []
        lines.append(L("FT-710 Control – diagnostyka USB"))
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(L("Data: {1}", ISO8601DateFormatter().string(from: current.date)))
        lines.append("")

        if let baseline {
            lines.append(contentsOf: diff(from: baseline, to: current))
            lines.append("")
        }

        lines.append(L("[CAT] Mostki Silicon Labs ({1}):", String(format: "%04X", siliconLabsVID)))
        if catBridges.isEmpty {
            lines.append(L("  NIE ZNALEZIONO – sprawdź kabel USB (port USB z tyłu radia) i czy radio jest włączone."))
        } else {
            catBridges.forEach { lines.append("  \($0.idText)  \($0.name)") }
        }
        lines.append(L("  Porty szeregowe: ") + (current.serialPorts.isEmpty ? L("brak") : current.serialPorts.joined(separator: ", ")))
        lines.append(L("  Status CAT: {1}", catStatus))
        lines.append("")

        lines.append(L("[SKOP] Mostek FTDI FT4222 (0403:601C):"))
        if ft4222.isEmpty {
            lines.append(L("  NIE WIDAĆ – w radiu ustaw MENU → OPERATION SETTING → GENERAL → SCU-LAN10 = ON,"))
            lines.append(L("  potem odłącz kabel USB na ~10 s i podłącz ponownie."))
        } else {
            ft4222.forEach { lines.append("  OK  \($0.idText)  \($0.name)") }
            lines.append(L("  Interfejs jest widoczny - włącz panel „Skop RF radia”."))
            lines.append(L("  Potrzebna biblioteka FTDI LibFT4222 w /usr/local/lib (patrz README)."))
        }
        otherFTDI.forEach {
            lines.append(L("  (inne: {1} {2} – {3}, to nie jest interfejs skopu)", $0.idText, $0.name, ftdiDescription($0.productID)))
        }
        lines.append("")

        lines.append(L("[AUDIO] Urządzenia wejściowe:"))
        current.audioIn.forEach { lines.append("  \($0)") }
        lines.append(L("[AUDIO] Urządzenia wyjściowe:"))
        current.audioOut.forEach { lines.append("  \($0)") }
        lines.append("")

        lines.append(L("Wszystkie urządzenia USB:"))
        usb.sorted { $0.idText < $1.idText }.forEach { lines.append("  \($0.idText)  \($0.name)") }
        return lines.joined(separator: "\n")
    }

    /// Co zniknęło / pojawiło się względem zapamiętanego stanu (z uwzględnieniem duplikatów, np. hubów).
    private static func diff(from old: DiagnosticsSnapshot, to new: DiagnosticsSnapshot) -> [String] {
        func changes(_ a: [String], _ b: [String]) -> (gone: [String], added: [String]) {
            var counts: [String: Int] = [:]
            a.forEach { counts[$0, default: 0] += 1 }
            b.forEach { counts[$0, default: 0] -= 1 }
            let gone = counts.filter { $0.value > 0 }.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
            let added = counts.filter { $0.value < 0 }.flatMap { Array(repeating: $0.key, count: -$0.value) }.sorted()
            return (gone, added)
        }

        let time = DateFormatter.localizedString(from: old.date, dateStyle: .none, timeStyle: .medium)
        var lines = [L("[PORÓWNANIE] względem stanu zapamiętanego o {1}:", time)]
        let groups: [(String, [String], [String])] = [
            ("USB", old.usb.map { "\($0.idText)  \($0.name)" }, new.usb.map { "\($0.idText)  \($0.name)" }),
            ("port", old.serialPorts, new.serialPorts),
            (L("audio wejście"), old.audioIn, new.audioIn),
            (L("audio wyjście"), old.audioOut, new.audioOut)
        ]
        var any = false
        for (label, a, b) in groups {
            let c = changes(a, b)
            c.gone.forEach { lines.append(L("  − zniknęło ({1}): {2}", label, $0)); any = true }
            c.added.forEach { lines.append(L("  + pojawiło się ({1}): {2}", label, $0)); any = true }
        }
        if !any { lines.append(L("  bez zmian")) }
        lines.append(L("  Elementy, które zniknęły po odłączeniu kabla radia, należą do FT-710."))
        return lines
    }
}

/// Stan urządzeń w jednej chwili - do raportu i do porównania „przed/po odłączeniu radia".
struct DiagnosticsSnapshot {
    let date: Date
    let usb: [USBDeviceInfo]
    let serialPorts: [String]
    let audioIn: [String]
    let audioOut: [String]

    static func capture(serialPorts: [String], audioInputs: [AudioDevice], audioOutputs: [AudioDevice]) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(date: Date(),
                            usb: USBDiagnostics.devices(),
                            serialPorts: serialPorts,
                            audioIn: audioInputs.map(\.name),
                            audioOut: audioOutputs.map(\.name))
    }
}

struct DiagnosticsView: View {
    @ObservedObject var cat: CATClient
    @ObservedObject var audio: AudioManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var current: DiagnosticsSnapshot?
    @State private var baseline: DiagnosticsSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Diagnostyka USB")).font(.title2.bold())
            Text(L("Żeby ustalić, co należy do radia: Rozłącz w aplikacji → „Zapamiętaj stan” → odłącz kabel USB radia → odczekaj 10 s → „Odśwież”."))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(L("Odśwież")) { refresh() }
                Button(L("Zapamiętaj stan")) {
                    baseline = current
                    refresh()
                }
                .disabled(current == nil)
                if baseline != nil {
                    Button(L("Usuń porównanie")) {
                        baseline = nil
                        refresh()
                    }
                }
                Button(L("Kopiuj raport")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button(L("Zamknij")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 600)
        .onAppear { refresh() }
    }

    private func refresh() {
        cat.refreshPortsIfIdle()
        audio.refreshDevices()
        let snapshot = DiagnosticsSnapshot.capture(serialPorts: cat.ports,
                                                   audioInputs: audio.inputs,
                                                   audioOutputs: audio.outputs)
        current = snapshot
        text = USBDiagnostics.report(current: snapshot, baseline: baseline, catStatus: cat.status)
    }
}
