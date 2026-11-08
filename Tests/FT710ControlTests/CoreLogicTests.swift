import XCTest
import SwiftUI
import CoreLocation
import FTX
@testable import FT710Control

/// Testy logiki, która wcześniej była sprawdzana prototypami: ADIF, FT8 (rozbiór, raporty, koder/dekoder),
/// dopasowanie potwierdzeń, odpowiedzi QRZ, pakiety PSKReporter, kodowanie formularzy, stan krajów DXCC,
/// statystyka DXCC, ponowne tłumaczenie tekstów, POTA. Uruchomienie: `swift test` w katalogu projektu.
final class CoreLogicTests: XCTestCase {

    // MARK: - Dane pomocnicze

    /// Mała baza krajów w formacie cty.dat (Sycylia - kraj tylko WAE, liczony jako Włochy).
    static let ctyText = """
    Germany:                  14:  28:  EU:   51.00:   -10.00:    -1.0:  DL:
        DA,DB,DC,DD,DE,DF,DG,DH,DI,DJ,DK,DL,DM,DN,DO,DP,DQ,DR;
    Italy:                    15:  28:  EU:   42.82:   -12.58:    -1.0:  I:
        I;
    Sicily:                   15:  28:  EU:   37.50:   -14.00:    -1.0:  *IT9:
        IT9;
    Japan:                    25:  45:  AS:   36.40:  -138.38:    -9.0:  JA:
        JA,JE,JF,JG,JH,JI,JJ,JK,JL,JM,JN,JO,JP,JQ,JR,JS;
    Malawi:                   37:  53:  AF:  -14.00:   -34.00:    -2.0:  7Q:
        7Q;
    France:                   14:  27:  EU:   46.00:    -2.00:    -1.0:  F:
        F;
    """

    static let base = Date(timeIntervalSince1970: 1_792_500_000)

    static func qso(_ call: String, _ band: String, _ mode: String, minutes: Double = 0,
                    lotw: Bool = false, eqsl: Bool = false) -> QSO {
        var q = QSO(call: call, start: base.addingTimeInterval(minutes * 60), end: nil, freqHz: 14_074_000,
                    band: band, mode: mode, submode: nil)
        if lotw { q.extra["LOTW_QSL_RCVD"] = "Y" }
        if eqsl { q.extra["EQSL_QSL_RCVD"] = "Y" }
        return q
    }

    // MARK: - ADIF

    func testADIFRoundTrip() throws {
        var q = Self.qso("SP5XTF/P", "20m", "FT8")
        q.rstSent = "-12"
        q.rstRcvd = "-08"
        q.grid = "KO02"
        q.extra["LOTW_QSL_RCVD"] = "Y"
        let text = ADIF.export([q])
        XCTAssertTrue(text.allSatisfy(\.isASCII), "ADIF musi być czystym ASCII")
        let records = ADIF.parse(text)
        XCTAssertEqual(records.count, 1)
        let back = try XCTUnwrap(ADIF.qso(from: records[0]))
        XCTAssertEqual(back.call, "SP5XTF/P")
        XCTAssertEqual(back.band.lowercased(), "20m")
        XCTAssertEqual(back.rstSent, "-12")
        XCTAssertEqual(back.rstRcvd, "-08")
        XCTAssertEqual(back.grid, "KO02")
        XCTAssertEqual(back.extra["LOTW_QSL_RCVD"], "Y")
        XCTAssertEqual(back.start.timeIntervalSince1970, q.start.timeIntervalSince1970, accuracy: 60)
    }

    // MARK: - FT8: rozbiór komunikatów

    func testFT8MessageParsing() {
        let cq = FTMessageInfo.parse("CQ DX R6WA LN32")
        XCTAssertTrue(cq.isCQ)
        XCTAssertEqual(cq.cqModifier, "DX")
        XCTAssertEqual(cq.from, "R6WA")
        XCTAssertEqual(cq.grid, "LN32")

        let report = FTMessageInfo.parse("SP5XTF DL1ABC R-07")
        XCTAssertEqual(report.to, "SP5XTF")
        XCTAssertEqual(report.from, "DL1ABC")
        XCTAssertEqual(report.report, "R-07")
        XCTAssertNil(report.grid)

        let rr73 = FTMessageInfo.parse("DL1ABC SP5XTF RR73")
        XCTAssertEqual(rr73.report, "RR73")
        XCTAssertNil(rr73.grid, "RR73 nie jest lokatorem")

        let hashed = FTMessageInfo.parse("<...> DB100FT")
        XCTAssertFalse(FTMessageInfo.isCallsign(hashed.to ?? "..."), "nierozwinięty skrót nie jest znakiem")
        XCTAssertNil(FTMessageInfo.parse("TNX BOB 73 GL").from, "tekst dowolny nie jest rozbierany")
    }

    /// Kilka stacji odpowiada na CQ - wybór według ustawienia (SNR albo odległość).
    func testCallerPreference() {
        let callers: [(snr: Int, km: Double?)] = [(-5, 800), (-18, 8_600), (-21, 15_700), (3, nil), (-10, 1_300)]
        XCTAssertEqual(FTCallerPreference.strongest.choose(callers), 3)
        XCTAssertEqual(FTCallerPreference.weakest.choose(callers), 2)
        XCTAssertEqual(FTCallerPreference.farthest.choose(callers), 2, "VK - 15 700 km")
        XCTAssertEqual(FTCallerPreference.nearest.choose(callers), 0, "DL - 800 km; nieznana odległość nie wygrywa")
        XCTAssertEqual(FTCallerPreference.farthest.choose([(-15, 5_000), (-3, 5_000.4)]), 1, "remis - wyższy SNR")
        XCTAssertEqual(FTCallerPreference.farthest.choose([(-15, nil), (-3, nil)]), 1, "bez odległości - wyższy SNR")
        XCTAssertNil(FTCallerPreference.farthest.choose([]))
    }

    @MainActor
    func testFT8ReportRange() {
        XCTAssertEqual(FT8Manager.reportText(-5), "-05")
        XCTAssertEqual(FT8Manager.reportText(3), "+03")
        XCTAssertEqual(FT8Manager.reportText(-31), "-30", "-31 zakodowałby się jako 73")
        XCTAssertEqual(FT8Manager.reportText(45), "+30")
    }

    // MARK: - FT8: koder i dekoder (moduł C)

    private func encode(_ text: String, protocolCode: Int32) -> (count: Int32, tones: [UInt8], echo: String) {
        var tones = [UInt8](repeating: 0, count: 105)
        var echo = [CChar](repeating: 0, count: 64)
        let n = tones.withUnsafeMutableBufferPointer { t in
            echo.withUnsafeMutableBufferPointer { e in ftxw_encode_echo(text, protocolCode, t.baseAddress, e.baseAddress, 64) }
        }
        let echoText = echo.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return (n, tones, echoText)
    }

    func testFT8EncoderEcho() {
        XCTAssertEqual(encode("CQ SP5XTF KO02", protocolCode: 0).count, 79)
        XCTAssertEqual(encode("CQ SP5XTF KO02", protocolCode: 1).count, 105)
        XCTAssertEqual(encode("DL1ABC SP5XTF -31", protocolCode: 0).echo, "DL1ABC SP5XTF 73",
                       "raport spoza zakresu - echo musi pokazać, co naprawdę pójdzie")
        XCTAssertFalse(FTTxAudio(code: 79, echo: "DL1ABC SP5XTF 73", samples: []).matches("DL1ABC SP5XTF -31"))
        XCTAssertTrue(FTTxAudio(code: 79, echo: "<DL/SP5XTF> DL1ABC 73", samples: []).matches("DL/SP5XTF DL1ABC 73"))
        XCTAssertEqual(encode("TNX BOB 73 GL", protocolCode: 0).echo, "TNX BOB 73 GL", "tekst dowolny do 13 znaków")
    }

    func testFT8RoundTripDecode() {
        for protocolCode: Int32 in [0, 1] {
            let message = "DL1ABC SP5XTF -12"
            let e = encode(message, protocolCode: protocolCode)
            XCTAssertGreaterThan(e.count, 0)
            let slot = protocolCode == 0 ? 12_000 * 15 : 12_000 * 15 / 2
            var signal = [Float](repeating: 0, count: slot)
            let length = Int(ftxw_synth_length(e.count, protocolCode, 12_000))
            var synth = [Float](repeating: 0, count: length)
            e.tones.withUnsafeBufferPointer { t in
                synth.withUnsafeMutableBufferPointer { s in ftxw_synth(t.baseAddress, e.count, protocolCode, 1200, 12_000, s.baseAddress) }
            }
            for i in 0..<length where 6_000 + i < slot { signal[6_000 + i] = 0.1 * synth[i] }
            var generator = SystemRandomNumberGenerator()
            for i in signal.indices { signal[i] += Float.random(in: -0.002...0.002, using: &generator) }
            var results = [ftxw_result_t](repeating: ftxw_result_t(), count: 20)
            let n = signal.withUnsafeBufferPointer { a in
                results.withUnsafeMutableBufferPointer { r in
                    ftxw_decode(a.baseAddress, Int32(a.count), protocolCode, 200, 3000, 2, r.baseAddress, 20)
                }
            }
            XCTAssertGreaterThan(n, 0, "protokół \(protocolCode): brak dekodu")
            var first = results[0].text
            let text = withUnsafeBytes(of: &first) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            XCTAssertEqual(text, message)
            XCTAssertEqual(Double(results[0].freq), 1200, accuracy: 5)
            XCTAssertEqual(Double(results[0].dt), 0, accuracy: 0.2)
        }
    }

    func testResamplerLength() {
        let resampler = Resampler12k()
        var total = 0
        for _ in 0..<100 { total += resampler.process([Float](repeating: 0, count: 4_800), rate: 48_000).count }
        XCTAssertEqual(total, 120_000, accuracy: 2, "48 kHz → 12 kHz: 4 razy mniej próbek")
    }

    // MARK: - Potwierdzenia QSL

    @MainActor
    func testQSLMatcher() {
        let log = [Self.qso("DL1ABC", "20m", "FT8", minutes: 0), Self.qso("DL1ABC", "20m", "SSB", minutes: 20),
                   Self.qso("DL1ABC/P", "40m", "CW", minutes: 60 * 20), Self.qso("F5PBG", "20m", "FT8", minutes: 400)]
        let index = QSLMatcher.index(log)
        func match(_ q: QSO) -> Int? { QSLMatcher.match(q, in: log, index: index) }
        XCTAssertEqual(match(Self.qso("DL1ABC", "20M", "FT8", minutes: 1)), 0)
        XCTAssertEqual(match(Self.qso("DL1ABC", "20m", "SSB", minutes: 18)), 1, "przy dwóch kandydatach rozstrzyga tryb")
        XCTAssertEqual(match(Self.qso("DL1ABC", "40m", "CW", minutes: 60 * 20 + 5)), 2, "/P w dzienniku")
        XCTAssertNil(match(Self.qso("F5PBG", "40m", "FT8", minutes: 400)), "inne pasmo")
        XCTAssertNil(match(Self.qso("F5PBG", "20m", "FT8", minutes: 448)), "ponad 30 minut różnicy")
    }

    @MainActor
    func testQRZResponseVariants() {
        let adif = "<call:6>F5PBG<comment:5>R&R ok<app_qrzlog_status:1>C<eor>"
        let plain = QSLDownloader.qrzFields("RESULT=OK&COUNT=1&LOGIDS=12&ADIF=" + adif)
        XCTAssertEqual(plain["ADIF"], adif)
        XCTAssertEqual(plain["LOGIDS"], "12")
        let entities = adif.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        XCTAssertEqual(QSLDownloader.qrzFields("RESULT=OK&ADIF=" + entities + "&LOGIDS=12")["ADIF"], adif)
        let encoded = adif.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        XCTAssertEqual(QSLDownloader.qrzFields("RESULT=OK&ADIF=" + encoded + "&LOGIDS=12")["ADIF"], adif)
    }

    @MainActor
    func testClubLogMatches() throws {
        // przykład z dokumentacji Club Log (getmatches.php): ukośnik escapowany w JSON, pasmo 70 = 70 cm
        let json = #"[["G0LGJ\/M","223","2005-07-16 08:00:00","20","CW"],["CO2IZ","70","2005-08-15 20:27:38","70","false"]]"#
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]])
        let matches = rows.compactMap(QSLDownloader.clubLogMatch)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].call, "G0LGJ/M")
        XCTAssertEqual(matches[0].band, "20m")
        XCTAssertEqual(matches[0].mode, "CW")
        XCTAssertEqual(matches[0].extra["DXCC"], "223")
        XCTAssertEqual(matches[1].band, "70cm")
        XCTAssertEqual(matches[1].mode, "", "„false” = tryb nieznany")
        var q = Self.qso("DL1ABC", "20m", "FT8", lotw: true)
        q.extra[QSLSource.clublog.receivedField] = "Y"
        XCTAssertEqual(q.qslMarks, "L C")
        let clubLogOnly = { () -> QSO in var x = Self.qso("F5PBG", "20m", "FT8"); x.extra[QSLSource.clublog.receivedField] = "Y"; return x }()
        XCTAssertFalse(clubLogOnly.isConfirmed(includeEQSL: true, includeQRZ: true), "Club Log nie liczy się do DXCC")
    }

    /// Strona eQSL zaczyna się od JavaScriptu - komunikat i odnośnik muszą być znalezione mimo to.
    @MainActor
    func testEQSLPageParsing() throws {
        let script = #"<html><head><title>Download InBox - eQSL.cc</title><script>function popupPrintPage(URL, WindowName, l, t, w, h) { var windowprops = "location=no"; }</script></head><body>"#
        let base = try XCTUnwrap(URL(string: "https://www.eqsl.cc/qslcard/DownloadInBox.cfm"))
        let empty = script + "<p>You have no log entries matching your request &amp; date range.</p></body></html>"
        XCTAssertNil(QSLDownloader.adifLink(in: empty, base: base))
        XCTAssertFalse(QSLDownloader.plainText(fromHTML: empty).contains("popupPrintPage"), "bez kodu JavaScript")
        XCTAssertFalse(QSLDownloader.plainText(fromHTML: empty).lowercased().contains("error"), "brak nowych to nie błąd")
        let error = script + "<p><b>Error: No such Username/Password found</b></p></body></html>"
        XCTAssertTrue(QSLDownloader.plainText(fromHTML: error).contains("Error: No such Username/Password found"))
        let single = script + "<a href='../downloadedfiles/ABC123.adi'>.ADI file</a>"
        XCTAssertEqual(QSLDownloader.adifLink(in: single, base: base)?.absoluteString, "https://www.eqsl.cc/downloadedfiles/ABC123.adi")
        let upper = script + #"<A HREF="../downloadedfiles/XYZ.ADI">.ADI file</A>"#
        XCTAssertEqual(QSLDownloader.adifLink(in: upper, base: base)?.absoluteString, "https://www.eqsl.cc/downloadedfiles/XYZ.ADI")
    }

    func testConfirmationMarks() {
        let q = Self.qso("DL1ABC", "20m", "FT8", lotw: true, eqsl: true)
        XCTAssertEqual(q.qslMarks, "L E")
        XCTAssertTrue(q.isConfirmed(includeEQSL: false, includeQRZ: false))
        let eqslOnly = Self.qso("F5PBG", "20m", "FT8", eqsl: true)
        XCTAssertFalse(eqslOnly.isConfirmed(includeEQSL: false, includeQRZ: false), "do DXCC liczy się tylko LoTW")
        XCTAssertTrue(eqslOnly.isConfirmed(includeEQSL: true, includeQRZ: false))
    }

    // MARK: - Sieć: formularze i PSKReporter

    /// Club Log delete.php: pasmo jako bandid i czas dokładnie „RRRR-MM-DD GG:MM:SS” (jak wysłany TIME_ON).
    @MainActor
    func testClubLogDeleteFields() {
        XCTAssertEqual(LogUploader.clubLogBandID("20m"), "20")
        XCTAssertEqual(LogUploader.clubLogBandID("160M"), "160")
        XCTAssertEqual(LogUploader.clubLogBandID("70cm"), "70")
        XCTAssertEqual(LogUploader.clubLogBandID("23cm"), "23")
        XCTAssertNil(LogUploader.clubLogBandID("630m"), "pasmo spoza listy Club Log")
        let date = Date(timeIntervalSince1970: 1_792_500_007)
        XCTAssertEqual(LogUploader.clubLogDateTime(date), "2026-10-20 12:40:07", "czas UTC co do sekundy")
        XCTAssertEqual(LogUploader.remoteDeletable, [.clublog, .qrzLogbook], "LoTW i eQSL - bez usuwania przez program")
    }

    @MainActor
    func testFormEncoding() {
        XCTAssertEqual(LogUploader.formEncode("a+b@x.pl"), "a%2Bb%40x.pl", "+ zawsze jako %2B")
        XCTAssertEqual(LogUploader.formEncode("ł"), "%C5%82", "litery spoza ASCII - %XX w UTF-8")
        XCTAssertEqual(LogUploader.formEncode("<CALL:5>"), "%3CCALL%3A5%3E")
    }

    func testPSKReporterPacket() throws {
        let spots = [PSKSpot(call: "F5PBG", freqHz: 14_075_550, snr: -3, mode: "FT8", grid: "IN78", time: Self.base),
                     PSKSpot(call: "W1AW", freqHz: 14_074_100, snr: -30, mode: "FT8", grid: "", time: Self.base)]
        let packet = [UInt8](PSKReporterPacket.build(sequence: 1, observationID: 0xA1B2C3D4, exportTime: 1_792_520_000,
                                                     includeTemplates: true, receiverCall: "SP5XTF", receiverGrid: "KO02ME",
                                                     software: "FT-710 Control", antenna: "", spots: spots))
        func u16(_ i: Int) -> Int { Int(packet[i]) << 8 | Int(packet[i + 1]) }
        XCTAssertEqual(u16(0), 10, "wersja IPFIX")
        XCTAssertEqual(u16(2), packet.count, "długość w nagłówku")
        // przejście po zestawach: każdy wyrównany do 4 bajtów, razem cały pakiet
        var position = 16
        var setIDs: [Int] = []
        var senderRecords: ArraySlice<UInt8> = []
        while position < packet.count {
            let id = u16(position), length = u16(position + 2)
            XCTAssertEqual(length % 4, 0)
            setIDs.append(id)
            if id == 0x50E3 { senderRecords = packet[(position + 4)..<(position + length)] }
            position += length
        }
        XCTAssertEqual(position, packet.count)
        XCTAssertEqual(setIDs, [2, 3, 0x50E2, 0x50E3])
        // pierwszy rekord nadawcy: znak, częstotliwość (5 B), SNR (1 B, ze znakiem), tryb, lokator
        var bytes = Array(senderRecords)
        func text() -> String {
            let n = Int(bytes.removeFirst())
            defer { bytes.removeFirst(n) }
            return String(decoding: bytes.prefix(n), as: UTF8.self)
        }
        XCTAssertEqual(text(), "F5PBG")
        let frequency = bytes.prefix(5).reduce(0) { $0 << 8 | Int($1) }
        bytes.removeFirst(5)
        XCTAssertEqual(frequency, 14_075_550)
        XCTAssertEqual(Int8(bitPattern: bytes.removeFirst()), -3)
        XCTAssertEqual(text(), "FT8")
        XCTAssertEqual(text(), "IN78")
        XCTAssertEqual(bytes.removeFirst(), 1, "źródło: automatyczne")
    }

    // MARK: - Kraje DXCC

    func testDXCCStatus() throws {
        let table = CTYTable(text: Self.ctyText)
        let log = [Self.qso("DL1ABC", "20m", "FT8", lotw: true), Self.qso("DL2XYZ", "40m", "SSB"),
                   Self.qso("IT9ABC", "20m", "SSB"), Self.qso("JA1AAA", "20m", "FT8")]
        let index = FTWorkedIndex(qsos: log, cty: table)
        func status(_ call: String, _ band: String) throws -> DXCCStatus {
            index.dxccStatus(match: try XCTUnwrap(table.lookup(call)), band: band)
        }
        XCTAssertEqual(try status("7Q5MLV", "20m"), .newDXCC)
        XCTAssertEqual(try status("DL5AAA", "20m"), .confirmed)
        XCTAssertEqual(try status("DL5AAA", "40m"), .unconfirmedBand)
        XCTAssertEqual(try status("DL5AAA", "15m"), .newBand)
        XCTAssertEqual(try status("I1XXX", "20m"), .unconfirmed, "Sycylia (IT9) liczy się jako Włochy")
        XCTAssertEqual(try status("I1XXX", "40m"), .unconfirmedNewBand)
        XCTAssertEqual(AlertKind.from(.unconfirmedNewBand), [.unconfirmedDXCC, .newDXCCBand])
        // stacja już zrobiona na paśmie (szara także z niepotwierdzonego kraju) - tylko ta stacja i to pasmo
        XCTAssertTrue(index.workedOnBand("JA1AAA", band: "20m"))
        XCTAssertTrue(index.workedOnBand("JA1AAA/P", band: "20m"), "znak podstawowy")
        XCTAssertFalse(index.workedOnBand("JA1AAA", band: "40m"))
        XCTAssertFalse(index.workedOnBand("JA2BBB", band: "20m"), "inna stacja z tego kraju - nadal fiolet")
    }

    @MainActor
    func testDXCCStatistics() {
        let table = CTYTable(text: Self.ctyText)
        let log = [Self.qso("DL1ABC", "20m", "FT8", lotw: true), Self.qso("DL2XYZ", "40m", "CW", lotw: true),
                   Self.qso("IT9ABC", "20m", "SSB", lotw: true), Self.qso("I1XXX", "15m", "CW"),
                   Self.qso("JA1AAA", "20m", "FT8"), Self.qso("ZZ9ZZ", "20m", "FT8")]
        let mixed = DXCCStatistics(qsos: log, table: table, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(mixed.worked, 3)
        XCTAssertEqual(mixed.confirmed, 2)
        XCTAssertEqual(mixed.unknownCalls, 1)
        XCTAssertEqual(mixed.rows.first { $0.id == "I" }?.name, "Italy", "nazwa jednostki DXCC, nie WAE")
        let cw = DXCCStatistics(qsos: log, table: table, category: .cw, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(cw.worked, 2)
        XCTAssertEqual(cw.confirmed, 1)
        let phone = DXCCStatistics(qsos: log, table: table, category: .phone, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(phone.worked, 1)
    }

    // MARK: - Stacje spoza swojego kraju (P4/WE9V)

    /// Kraj decyduje prefiks przed ukośnikiem, nie znak macierzysty (zgłoszenie Club Log: P4/WE9V, FM/VE3DZ).
    func testPortableCountryPrefix() throws {
        let table = CTYTable(text: """
        United States:            05:  08:  NA:   37.53:    91.67:     5.0:  K:
            AA,K,N,W;
        Aruba:                    09:  11:  SA:   12.53:    69.98:     4.0:  P4:
            P4;
        Canada:                   05:  09:  NA:   44.35:    78.75:     5.0:  VE:
            VA,VE;
        Martinique:               08:  11:  NA:   14.70:    61.03:     4.0:  FM:
            FM;
        Poland:                   15:  28:  EU:   52.28:   -18.67:    -1.0:  SP:
            SP;
        """)
        func entity(_ call: String) throws -> String { CTYTable.dxccKey(try XCTUnwrap(table.lookup(call), call)) }
        XCTAssertEqual(try entity("P4/WE9V"), "P4", "Aruba, nie USA")
        XCTAssertEqual(try entity(QRZClient.baseCall("P4/WE9V")), "K", "QRZ szuka znaku macierzystego - USA")
        XCTAssertEqual(try entity("FM/VE3DZ"), "FM", "Martynika, nie Kanada")
        XCTAssertEqual(try entity("W1AW/4"), "K", "zmiana okręgu - ten sam kraj")
        XCTAssertEqual(try entity("SP5XTF/P"), "SP", "/P - ten sam kraj")
    }

    // MARK: - Dyplomy

    func testWPXPrefix() {
        let cases = ["SP5XTF": "SP5", "SP5XTF/P": "SP5", "DL1ABC": "DL1", "3Z9X": "3Z9", "S50A": "S50", "4U1ITU": "4U1",
                     "K4SWL": "K4", "9A1AA": "9A1", "RAEM": "RA0", "DL/SP5XTF": "DL0", "SP5XTF/3": "SP3",
                     "VP2E/K1ABC": "VP2", "KH6/K1ABC": "KH6", "OH0X": "OH0", "T88A": "T88", "SP5XTF/MM": "SP5",
                     "W1AW/4": "W4", "N5J": "N5", "JA1ABC/QRP": "JA1"]
        for (call, prefix) in cases { XCTAssertEqual(AwardCalculator.wpxPrefix(call), prefix, call) }
    }

    @MainActor
    func testAwardsWAZVUCCPOTA() {
        let table = CTYTable(text: Self.ctyText)
        var withZone = Self.qso("ZZ1ZZ", "20m", "CW")
        withZone.extra["CQZ"] = "3"                                   // strefa z pola ADIF ma pierwszeństwo
        var vhf = Self.qso("DL1VHF", "2m", "SSB", lotw: true)
        vhf.grid = "JO62QM"
        var park = Self.qso("K4SWL", "20m", "CW")
        park.extra["POTA_REF"] = "US-0062"
        let log = [Self.qso("DL1ABC", "20m", "FT8", lotw: true), Self.qso("JA1AAA", "15m", "CW"), withZone, vhf, park]

        let waz = AwardCalculator.compute(.waz, qsos: log, table: table, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(Set(waz.rows.map(\.id)), ["03", "14", "25"], "strefy: 3 (ADIF), 14 (DL), 25 (JA)")
        XCTAssertEqual(waz.confirmed, 1, "tylko strefa 14 (LoTW na 20 m i 2 m); 3 i 25 bez potwierdzenia")
        XCTAssertEqual(waz.missing.count, 37)
        XCTAssertFalse(waz.missing.contains("14"))

        let vucc = AwardCalculator.compute(.vucc, qsos: log, table: table, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(vucc.rows.map(\.id), ["JO62"], "tylko pasma od 6 m, kwadrat 4-znakowy")
        XCTAssertEqual(vucc.confirmed(on: "2m"), 1)

        let pota = AwardCalculator.compute(.pota, qsos: log, table: table, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(pota.rows.map(\.id), ["US-0062"])
        XCTAssertEqual(pota.worked(on: "20m"), 1)
    }

    // MARK: - Przyciski pasm CW / RTTY / SSTV

    func testModeBandPlans() {
        for plan in [ModeBandPlan.cw, .rtty, .sstv] {
            let bands = plan.defaults.map { LogFrequency.band(for: $0) }
            XCTAssertFalse(bands.contains(nil), "\(plan.key): częstotliwość poza pasmem")
            XCTAssertEqual(Set(bands).count, bands.count, "\(plan.key): pasmo powtórzone")
        }
        XCTAssertEqual(ModeBandPlan.rtty.defaults.first { LogFrequency.band(for: $0) == "20m" }, 14_087_125,
                       "RTTY: 14,085 + 2,125 kHz (ton mark 2125 Hz w DATA-L)")
        XCTAssertEqual(ModeBandPlan.cw.modeCode(for: 14_030_000), "3", "CW-U")
        XCTAssertEqual(ModeBandPlan.rtty.modeCode(for: 14_087_125), "8", "DATA-L")
        XCTAssertEqual(ModeBandPlan.sstv.modeCode(for: 7_165_000), "8", "SSTV 40 m - DATA-L")
        XCTAssertEqual(ModeBandPlan.sstv.modeCode(for: 14_230_000), "C", "SSTV 20 m - DATA-U")
    }

    // MARK: - Mapa łączności

    @MainActor
    func testQSOMapModeGroups() {
        func q(_ mode: String, _ sub: String? = nil) -> QSO {
            QSO(call: "DL1ABC", start: Self.base, end: nil, freqHz: 14_074_000, band: "20m", mode: mode, submode: sub)
        }
        XCTAssertEqual(QSOMapView.modeGroup(q("FT8")), "FT8")
        XCTAssertEqual(QSOMapView.modeGroup(q("MFSK", "FT4")), "FT4", "FT4 w ADIF: MODE=MFSK, SUBMODE=FT4")
        XCTAssertEqual(QSOMapView.modeGroup(q("SSB", "USB")), "PHONE")
        XCTAssertEqual(QSOMapView.modeGroup(q("FM")), "PHONE")
        XCTAssertEqual(QSOMapView.modeGroup(q("CW")), "CW")
        XCTAssertEqual(QSOMapView.modeGroup(q("RTTY")), "RTTY")
        XCTAssertEqual(QSOMapView.modeGroup(q("PSK", "PSK31")), "DIGI")
    }

    @MainActor
    func testAwardsIOTASOTAWWFF() {
        var island = Self.qso("EA8ZZ", "20m", "CW", lotw: true)
        island.extra["IOTA"] = "af-004"
        var summit = Self.qso("SP9XYZ/P", "40m", "CW")
        summit.extra["SIG"] = "SOTA"
        summit.extra["SIG_INFO"] = "SP/BZ-057"
        var park = Self.qso("SP5ABC/P", "40m", "SSB")
        park.extra["WWFF_REF"] = "SPFF-0001"
        let log = [island, summit, park, Self.qso("DL1ABC", "20m", "FT8")]
        let iota = AwardCalculator.compute(.iota, qsos: log, table: nil, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(iota.rows.map(\.id), ["AF-004"], "numer wielkimi literami")
        XCTAssertEqual(iota.confirmed, 1, "IOTA liczone z potwierdzeniami (LoTW)")
        let sota = AwardCalculator.compute(.sota, qsos: log, table: nil, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(sota.rows.map(\.id), ["SP/BZ-057"], "SOTA z SIG/SIG_INFO")
        let wwff = AwardCalculator.compute(.wwff, qsos: log, table: nil, category: .mixed, includeEQSL: false, includeQRZ: false)
        XCTAssertEqual(wwff.rows.map(\.id), ["SPFF-0001"])
        XCTAssertFalse(AwardKind.sota.usesConfirmations)
        XCTAssertTrue(AwardKind.iota.usesConfirmations)
    }

    // MARK: - Skop: linia widma w bitmapie

    /// Linia widma rysowana do bitmapy o stałym rozmiarze (szybko także na pełnym ekranie):
    /// poziom 0,5 → linia w połowie wysokości, wypełnienie pod nią, nad nią przezroczystość.
    @MainActor
    func testScopeTraceBitmap() throws {
        let values = [Float](repeating: 0.5, count: 3000)          // więcej punktów niż szerokość bitmapy
        let image = try XCTUnwrap(ScopeRenderNSView.renderTrace(values, width: 400, height: 100, color: .systemYellow,
                                                                fill: true, lineWidth: 1.5))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 100)
        // kanał alfa w środkowej kolumnie (wiersz 0 = góra obrazu); kontekst z własną pamięcią
        func alphaColumn(_ image: CGImage) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 400 * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 100))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return (0..<100).map { row in bytes[(row * 400 + 200) * 4 + 3] }
        }
        let filled = try alphaColumn(image)
        XCTAssertEqual(filled[10], 0, "nad linią - przezroczyste")
        XCTAssertGreaterThan(filled[50], 100, "linia w połowie wysokości")
        XCTAssertGreaterThan(filled[75], 0, "pod linią - wypełnienie")
        let noFill = try XCTUnwrap(ScopeRenderNSView.renderTrace(values, width: 400, height: 100, color: .systemYellow,
                                                                 fill: false, lineWidth: 1.5))
        XCTAssertEqual(try alphaColumn(noFill)[75], 0, "bez wypełnienia - pod linią przezroczyste")
    }

    /// Nowoczesny skop: wypełnienie kolorami palety (ciemno nisko, jasno wysoko) i linia peak hold nad linią bieżącą.
    @MainActor
    func testScopePaletteFillAndPeakHold() throws {
        let values = [Float](repeating: 0.5, count: 400)
        let peaks = [Float](repeating: 0.8, count: 400)
        let image = try XCTUnwrap(ScopeRenderNSView.renderTrace(values, width: 400, height: 100, color: .systemGreen, fill: true,
                                                                lineWidth: 1.5, fillStops: WaterfallPalette.turbo.stops,
                                                                peaks: peaks))
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 400 * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 100))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(row: Int) -> (r: Int, g: Int, b: Int, a: Int) {     // wiersz 0 = góra obrazu, kolumna środkowa
            let i = (row * 400 + 200) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
        XCTAssertGreaterThan(pixel(row: 20).a, 60, "linia peak hold na poziomie 0,8 (wiersz ok. 20)")
        XCTAssertEqual(pixel(row: 35).a, 0, "między szczytem a linią - pusto")
        let low = pixel(row: 95), mid = pixel(row: 60)
        XCTAssertGreaterThan(low.a, 0, "wypełnienie przy dole")
        XCTAssertGreaterThan(mid.r + mid.g + mid.b, low.r + low.g + low.b, "wyżej jaśniejsze kolory palety")
    }

    /// Skop RF: natywne 850 punktów, czas każdego wiersza waterfalla, licznik zmian zakresu (peak hold od nowa).
    @MainActor
    func testRFModelRowsAndGeneration() {
        let model = SpectrumModel(role: .rf)
        XCTAssertEqual(model.columns, 850)
        XCTAssertEqual(model.frames.rowCount, model.rows)
        for _ in 0..<5 { model.ingest(line: [Float](repeating: -80, count: 850)) }
        XCTAssertEqual(model.frames.rowTimes.count, 5, "czas każdego nowego wiersza")
        XCTAssertGreaterThanOrEqual(model.frames.rowTimes[0], model.frames.rowTimes[4], "najnowszy pierwszy")
        let generation = model.frames.generation
        model.rangeShifted()
        XCTAssertEqual(model.frames.generation, generation + 1)
        model.clear()
        XCTAssertEqual(model.frames.generation, generation + 2)
        XCTAssertTrue(model.frames.rowTimes.isEmpty)
        XCTAssertEqual(SpectrumModel(role: .audio).columns, 640, "widmo audio bez zmian")
    }

    /// Plan pasma: 20 m - CW, cyfrowe, radiolatarnie, SSB i FT8; odcinki pasm amatorskich nie nachodzą na siebie.
    func testBandPlan() {
        let twenty = BandPlan.visible(low: 14_000_000, high: 14_350_000).map(\.kind)
        for kind in [BandPlan.Kind.cw, .digital, .beacon, .phone, .ft8] {
            XCTAssertTrue(twenty.contains(kind), "20 m: \(kind)")
        }
        let ham = BandPlan.segments.filter { $0.kind != .broadcast }.sorted { $0.low < $1.low }
        for (a, b) in zip(ham, ham.dropFirst()) {
            XCTAssertLessThanOrEqual(a.high, b.low, "odcinki \(a.low)-\(a.high) i \(b.low)-\(b.high) nachodzą")
            XCTAssertLessThan(a.low, a.high)
        }
        XCTAssertTrue(BandPlan.visible(low: 7_074_500, high: 7_076_000).contains { $0.kind == .ft8 }, "FT8 na 40 m")
    }

    /// Komunikat DXpedycji (Fox/Hound): RR73 dla jednej stacji i raport dla drugiej w jednym komunikacie.
    func testFoxCompositeMessage() {
        let info = FTMessageInfo.parse("K1ABC RR73; SP5XTF <KH1/KH7Z> -12")
        XCTAssertEqual(info.rr73To, "K1ABC")
        XCTAssertEqual(info.to, "SP5XTF")
        XCTAssertEqual(info.from, "KH1/KH7Z")
        XCTAssertEqual(info.report, "-12")
        let unknown = FTMessageInfo.parse("K1ABC RR73; SP5XTF <...> +04")
        XCTAssertEqual(unknown.from, "...", "nieznany skrót znaku Foxa")
        XCTAssertFalse(FTMessageInfo.isCallsign(unknown.from ?? ""))
        let normal = FTMessageInfo.parse("SP5XTF KH1/KH7Z -12")
        XCTAssertNil(normal.rr73To, "zwykły komunikat bez zmian")
        XCTAssertEqual(normal.to, "SP5XTF")
        XCTAssertEqual(normal.report, "-12")
    }

    /// Zmiana FT8 ↔ FT4: częstotliwość nowego trybu na tym samym paśmie.
    func testFTModeBandSwitch() {
        XCTAssertEqual(FTMode.ft4.dialFrequency(sameBandAs: 7_074_000), 7_047_500, "40 m: FT8 → FT4")
        XCTAssertEqual(FTMode.ft8.dialFrequency(sameBandAs: 7_047_500), 7_074_000, "40 m: FT4 → FT8")
        XCTAssertEqual(FTMode.ft8.dialFrequency(sameBandAs: 14_080_000), 14_074_000, "20 m")
        XCTAssertEqual(FTMode.ft4.dialFrequency(sameBandAs: 28_074_000), 28_180_000, "10 m")
        XCTAssertEqual(FTMode.ft4.dialFrequency(sameBandAs: 50_313_000), 50_318_000, "6 m")
        XCTAssertEqual(FTMode.ft4.dialFrequency(sameBandAs: 14_090_000), 14_080_000, "dowolne miejsce na paśmie")
        XCTAssertNil(FTMode.ft4.dialFrequency(sameBandAs: 1_840_000), "FT4 nie ma częstotliwości na 160 m")
        XCTAssertNil(FTMode.ft4.dialFrequency(sameBandAs: 5_357_000), "ani na 60 m")
        XCTAssertNil(FTMode.ft8.dialFrequency(sameBandAs: 9_500_000), "poza pasmami")
    }

    /// Tunel Cloudflare: adres z komunikatów cloudflared (w ramce, między innymi wierszami).
    @MainActor
    func testCloudflareTunnelURL() {
        let log = """
        2026-10-29T10:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-10-29T10:00:01Z INF +--------------------------------------------------------------------------------------------+
        2026-10-29T10:00:01Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
        2026-10-29T10:00:01Z INF |  https://plain-bird-easy-memo.trycloudflare.com                                            |
        2026-10-29T10:00:01Z INF +--------------------------------------------------------------------------------------------+
        """
        XCTAssertEqual(CloudflareTunnel.tunnelURL(in: log), "https://plain-bird-easy-memo.trycloudflare.com")
        XCTAssertNil(CloudflareTunnel.tunnelURL(in: "Requesting new quick Tunnel on trycloudflare.com..."),
                     "sama nazwa domeny bez adresu tunelu")
        XCTAssertEqual(CloudflareTunnel.minimumPassword, 12)
    }

    /// Korektor nadawania: „DX - przebicie” tłumi 60 Hz, przepuszcza 2300 Hz i nigdy nie podnosi poziomu
    /// ponad wejście (całość ściszana o największe podbicie - bez przesterowania toru).
    func testTXEqualizer() throws {
        for preset in TXEQPreset.allCases where preset != .custom {
            XCTAssertEqual(preset.gains?.count, TXEqualizer.bands.count, "\(preset): 12 wartości")
        }
        let dx = try XCTUnwrap(TXEQPreset.dx.gains)
        func peak(_ hz: Double) -> Float {
            var eq = TXEqualizer()
            var samples = (0..<9_600).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / 48_000)) }
            samples.withUnsafeMutableBufferPointer { eq.process($0.baseAddress!, count: $0.count, gains: dx, sampleRate: 48_000) }
            return samples.suffix(4_800).map(abs).max() ?? 0          // po ustaleniu się filtrów
        }
        let low = peak(60), voice = peak(2_300)
        XCTAssertLessThan(low, 0.5 * 0.15, "60 Hz mocno wytłumione")
        XCTAssertGreaterThan(voice, 0.5 * 0.6, "2300 Hz przechodzi")
        XCTAssertLessThanOrEqual(voice, 0.5 * 1.02, "bez podbicia ponad wejście")
        XCTAssertEqual(TXEqualizer.response(TXEqualizer.flat, at: [100, 1000, 3000]).map { abs($0) < 0.01 }, [true, true, true],
                       "płasko - bez zmian")
    }

    /// Aktualizacje z GitHub: porównanie wersji z dopiskiem beta.
    @MainActor
    func testUpdateVersionCompare() {
        let newer = UpdateChecker.isNewer
        XCTAssertTrue(newer("v0.9.1-beta", "0.9.0-beta"), "kolejna beta")
        XCTAssertTrue(newer("0.9.0", "0.9.0-beta"), "wydanie po becie tej samej wersji")
        XCTAssertFalse(newer("0.9.0-beta", "0.9.0"), "beta nie zastępuje wydania")
        XCTAssertTrue(newer("0.9.0-beta.2", "0.9.0-beta.1"), "beta.2 > beta.1")
        XCTAssertTrue(newer("0.10.0-beta", "0.9.5"), "0.10 > 0.9 (liczby, nie tekst)")
        XCTAssertTrue(newer("1.0", "0.9.9"))
        XCTAssertFalse(newer("0.9.0-beta", "0.9.0-beta"), "ta sama wersja")
        XCTAssertFalse(newer("0.8.5", "0.9.0-beta"))
        XCTAssertEqual(UpdateChecker.clean("v0.9.0-beta"), "0.9.0-beta")
    }

    /// NAR (wąski filtr): komenda NA0 i rozpoznanie odpowiedzi obok podobnych prefiksów (NB0, NL0, NR0).
    func testNarrowControl() {
        XCTAssertEqual(RadioControl.narrow.setCommand(1), "NA01;")
        XCTAssertEqual(RadioControl.narrow.setCommand(0), "NA00;")
        XCTAssertEqual(RadioControl.narrow.query, "NA0;")
        XCTAssertEqual(RadioControl.match("NA01")?.0, .narrow)
        XCTAssertEqual(RadioControl.match("NA01")?.1, 1)
        XCTAssertEqual(RadioControl.match("NR01")?.0, .noiseReduction, "DNR bez zmian")
        XCTAssertEqual(RadioControl.match("NB00")?.0, .noiseBlanker)
    }

    /// Ręczne dodawanie QSO: podpowiadana częstotliwość każdej emisji leży w wybranym paśmie (w tym 2 m, 70 cm, 23 cm).
    @MainActor
    func testManualQSODefaultFrequencies() {
        for band in ManualQSOView.bands {
            for mode in ManualQSOView.modes.map(\.label) {
                let text = ManualQSOView.defaultFrequency(band: band, mode: mode)
                let hz = LogFrequency.parseMHz(text)
                XCTAssertNotNil(hz, "\(band) \(mode): „\(text)”")
                XCTAssertEqual(hz.flatMap(LogFrequency.band(for:)), band, "\(band) \(mode): \(text) MHz poza pasmem")
            }
        }
        XCTAssertEqual(ManualQSOView.defaultFrequency(band: "2m", mode: "FM"), "145.500")
        XCTAssertEqual(ManualQSOView.defaultFrequency(band: "23cm", mode: "SSB"), "1296.200")
        XCTAssertNil(Bands.name(for: 145_500_000), "tabela FT-710 nie zna 2 m - dlatego okno bierze pasmo z tabeli ADIF")
        XCTAssertEqual(LogFrequency.band(for: 1_296_200_000), "23cm")
    }

    /// Dane z QRZ po zmianie znaku: pola wypełnione automatycznie są czyszczone, poprawione ręcznie zostają.
    func testQRZAutoFillClearsOnCallChange() {
        var name = "", qth = "", grid = ""
        let nameBinding = Binding(get: { name }, set: { name = $0 })
        let qthBinding = Binding(get: { qth }, set: { qth = $0 })
        let gridBinding = Binding(get: { grid }, set: { grid = $0 })
        var auto = QRZAutoFill()
        // „SP5X” - dane innej stacji
        name = "Jan"; auto.filled("name", name)
        qth = "Radom"; auto.filled("qth", qth)
        grid = "KO01"; auto.filled("grid", grid)
        name = "Janek"                                        // imię poprawione ręcznie
        auto.clear([("name", nameBinding), ("qth", qthBinding), ("grid", gridBinding)])
        XCTAssertEqual(name, "Janek", "poprawione ręcznie zostaje")
        XCTAssertEqual(qth, "", "z QRZ - wyczyszczone")
        XCTAssertEqual(grid, "", "z QRZ - wyczyszczone")
        qth = "Warszawa"                                      // wpisane ręcznie (bez filled) - nigdy nie czyścimy
        auto.clear([("qth", qthBinding)])
        XCTAssertEqual(qth, "Warszawa")
    }

    /// Kopia ustawień: bez haseł i ustawień macOS; typy wracają bez zmian; obcy plik odrzucony.
    func testSettingsBackupRoundTrip() throws {
        XCTAssertFalse(SettingsBackup.isExportable("remotePassword"))
        XCTAssertFalse(SettingsBackup.isExportable("clublog.apiKey"))
        XCTAssertFalse(SettingsBackup.isExportable("someToken"))
        XCTAssertFalse(SettingsBackup.isExportable("NSWindow Frame main"))
        XCTAssertFalse(SettingsBackup.isExportable("update.lastCheck"))
        XCTAssertTrue(SettingsBackup.isExportable("myCall"))
        XCTAssertTrue(SettingsBackup.isExportable("txEQ.gains"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let settings: [String: Any] = ["myCall": "SP5XTF", "remotePort": 8710, "txEQ.enabled": true,
                                       "txEQ.gains": [-12.0, 0.5, 3.0], "display": ["palette": "turbo"], "since": date]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).ft710settings")
        defer { try? FileManager.default.removeItem(at: url) }
        try SettingsBackup.write(settings.merging(["remotePassword": "tajne"]) { a, _ in a }, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("SP5XTF"))
        XCTAssertFalse(text.contains("tajne"), "hasło nie trafia do pliku")
        let backup = try SettingsBackup.read(url)
        XCTAssertNil(backup.settings["remotePassword"], "hasło pominięte przy odczycie (także z cudzego pliku)")
        XCTAssertEqual(backup.settings["myCall"] as? String, "SP5XTF")
        XCTAssertEqual(backup.settings["remotePort"] as? Int, 8710)
        XCTAssertEqual(backup.settings["txEQ.enabled"] as? Bool, true)
        XCTAssertEqual(backup.settings["txEQ.gains"] as? [Double], [-12.0, 0.5, 3.0])
        XCTAssertEqual((backup.settings["display"] as? [String: String])?["palette"], "turbo")
        XCTAssertEqual(backup.settings["since"] as? Date, date)
        XCTAssertEqual(backup.programVersion, ADIF.programVersion)
        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("obcy-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: foreign) }
        try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0).write(to: foreign)
        XCTAssertThrowsError(try SettingsBackup.read(foreign), "obcy plik odrzucony")
    }

    /// Deterministyczny szum gaussowski do testów modemu (SplitMix64 + Box-Muller).
    private struct TestNoise {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u1 = max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    /// PSK31/PSK63: nadanie → szum i odstrojenie 8 Hz → odbiór; sam szum nie daje tekstu (blokada); Varicode.
    func testPSKLoopback() {
        XCTAssertEqual(Varicode.codes.count, 128)
        XCTAssertEqual(Set(Varicode.codes).count, 128, "kody unikalne")
        XCTAssertTrue(Varicode.codes.allSatisfy { !$0.contains("00") && $0.hasPrefix("1") && $0.hasSuffix("1") })
        let message = "CQ CQ DE SP5XTF SP5XTF KO02 pse k 73!"
        let rate = 48_000.0
        for baud in [31.25, 62.5] {
            var signal = PSKModulator.modulate(message, sampleRate: rate, carrier: 1008, baud: baud, amplitude: 0.5)
            signal = [Float](repeating: 0, count: 9_000) + signal + [Float](repeating: 0, count: 24_000)
            // szum: SNR +3 dB w paśmie 2,5 kHz
            let power = signal.reduce(0) { $0 + Double($1 * $1) } / Double(signal.count)
            let sigma = (power / pow(10, 0.3) * (rate / 2) / 2_500).squareRoot()
            var noise = TestNoise(state: UInt64(baud * 1000))
            let noisy = signal.map { $0 + Float(sigma * noise.gaussian()) }
            let decoder = PSKDecoder()
            decoder.configure(baud: baud)
            decoder.setCarrier(1000)                            // odbiór ustawiony 8 Hz obok - AFC dostraja
            let text = decoder.decodeSynchronously(noisy, sampleRate: rate)
            XCTAssertTrue(text.contains(message), "PSK\(baud == 31.25 ? 31 : 63): odebrano „\(text)”")
            var quiet = TestNoise(state: 42)
            let onlyNoise = (0..<Int(rate * 6)).map { _ in Float(sigma * quiet.gaussian()) }
            let silence = PSKDecoder()
            silence.configure(baud: baud)
            XCTAssertEqual(silence.decodeSynchronously(onlyNoise, sampleRate: rate).count, 0,
                           "sam szum - blokada nie przepuszcza śmieci")
        }
        XCTAssertEqual(PSKModulator.duration(of: "TEST", baud: 31.25), Double(Varicode.bits(for: "TEST").count) / 31.25)
    }

    /// Pomiar SWR: częstotliwość wybierania i nośna wewnątrz pasm (margines 1 kHz), właściwa liczba punktów; CSV.
    @MainActor
    func testSWRSweepFrequencies() {
        for band in SWRSweep.bands {
            for count in [5, 21, 51] {
                let freqs = SWRSweep.frequencies(band: band.name, count: count)
                XCTAssertEqual(freqs.count, count, "\(band.name)")
                // radio sprawdza granice po częstotliwości wybierania (nośna - 1500 Hz) - musi być w paśmie z zapasem
                XCTAssertTrue(freqs.allSatisfy { $0 - 1_500 >= band.low + 1_000 && $0 <= band.high - 1_000 }, "\(band.name): poza pasmem")
                XCTAssertEqual(freqs, freqs.sorted(), "rosnąco")
                XCTAssertEqual(Set(freqs).count, count, "\(band.name): bez powtórzeń")
            }
        }
        XCTAssertTrue(SWRSweep.frequencies(band: "2m", count: 21).isEmpty, "tylko pasma FT-710")
        let m = SWRMeasurement(date: Date(), band: "40m", watts: 5,
                               points: [.init(hz: 7_001_000, swr: 1.8), .init(hz: 7_100_000, swr: 1.2), .init(hz: 7_199_000, swr: 2.1)])
        XCTAssertEqual(m.best?.hz, 7_100_000)
        XCTAssertEqual(SWRSweep.csv(m), "MHz;SWR\n7.0010;1.80\n7.1000;1.20\n7.1990;2.10\n")
    }

    /// Kto mnie słyszy: XML PSKReporter, najnowszy raport na odbiorcę i pasmo; położenie Słońca i noc.
    @MainActor
    func testHeardMeAndSolar() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <receptionReports currentSeconds="1793000000">
          <lastSequenceNumber value="1"/>
          <receptionReport receiverCallsign="dl1abc" receiverLocator="JO62qm" senderCallsign="SP5XTF" senderLocator="KO02me"
            frequency="14075123" flowStartSeconds="1792999000" mode="FT8" isSender="1" sNR="-12"/>
          <receptionReport receiverCallsign="DL1ABC" receiverLocator="JO62qm" senderCallsign="SP5XTF" frequency="14075200"
            flowStartSeconds="1792999600" mode="FT8" sNR="-5"/>
          <receptionReport receiverCallsign="K1ABC" receiverLocator="FN42" senderCallsign="SP5XTF" frequency="7075000"
            flowStartSeconds="1792999300" mode="FT8"/>
          <receptionReport receiverCallsign="BAD" senderCallsign="SP5XTF" frequency="7075000" flowStartSeconds="1"/>
        </receptionReports>
        """
        let parsed = HeardMeService.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.count, 3, "raport bez lokatora pominięty")
        let latest = HeardMeService.latestPerReceiver(parsed)
        XCTAssertEqual(latest.count, 2, "DL1ABC na 20 m - jeden, najnowszy")
        XCTAssertEqual(latest.first { $0.receiver == "DL1ABC" }?.snr, -5)
        XCTAssertEqual(latest.first { $0.receiver == "K1ABC" }?.band, "40m")
        XCTAssertNil(latest.first { $0.receiver == "K1ABC" }?.snr)
        let utc = TimeZone(identifier: "UTC")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
            var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.timeZone = utc
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        let equinox = SolarTerminator.subsolarPoint(at: date(2026, 3, 20, 12))
        XCTAssertEqual(equinox.latitude, 0, accuracy: 0.5)
        XCTAssertEqual(equinox.longitude, 1.9, accuracy: 1)
        XCTAssertEqual(SolarTerminator.subsolarPoint(at: date(2026, 6, 21, 12)).latitude, 23.44, accuracy: 0.2)
        XCTAssertEqual(SolarTerminator.subsolarPoint(at: date(2026, 12, 21, 12)).latitude, -23.44, accuracy: 0.2)
        let warsaw = CLLocationCoordinate2D(latitude: 52.2, longitude: 21.0)
        XCTAssertTrue(SolarTerminator.isNight(warsaw, at: date(2026, 11, 6, 22)), "Warszawa 22 UTC - noc")
        XCTAssertFalse(SolarTerminator.isNight(warsaw, at: date(2026, 6, 21, 10)), "Warszawa 10 UTC w czerwcu - dzień")
        XCTAssertEqual(SolarTerminator.terminator(at: date(2026, 11, 6, 12)).count, 181, "co 2° od -180 do 180")
    }

    // MARK: - HamQTH

    func testHamQTHParsing() throws {
        let xml = """
        <?xml version="1.0"?>
        <HamQTH version="2.7" xmlns="https://www.hamqth.com">
        <search><callsign>ok2cqr</callsign><nick>Petr</nick><qth>Neratovice</qth><country>Czech Republic</country>
        <adif>503</adif><itu>28</itu><cq>15</cq><grid>jo70gg</grid><adr_name>Petr Hlozek</adr_name>
        <latitude>50.07</latitude><longitude>14.42</longitude></search>
        </HamQTH>
        """
        let parser = QRZXMLParser()
        XCTAssertTrue(parser.parse(Data(xml.utf8)))
        let record = try XCTUnwrap(QRZRecord.fromHamQTH(parser.callsign))
        XCTAssertEqual(record.call, "OK2CQR")
        XCTAssertEqual(record.firstName, "Petr")
        XCTAssertEqual(record.city, "Neratovice")
        XCTAssertEqual(record.grid, "JO70GG")
        XCTAssertEqual(record.dxcc, "503")
        XCTAssertEqual(record.cqZone, "15")
        XCTAssertEqual(record.ituZone, "28")
        XCTAssertEqual(try XCTUnwrap(record.latitude), 50.07, accuracy: 0.001)

        let session = """
        <?xml version="1.0"?><HamQTH version="2.7" xmlns="https://www.hamqth.com"><session><session_id>09b0ae90</session_id></session></HamQTH>
        """
        let login = QRZXMLParser()
        XCTAssertTrue(login.parse(Data(session.utf8)))
        XCTAssertEqual(login.session["session_id"], "09b0ae90")

        // QRZ bez subskrypcji XML: brak lokatora i miasta - uzupełnia HamQTH, imię z QRZ zostaje
        let limited = try XCTUnwrap(QRZRecord(["call": "OK2CQR", "fname": "Peter", "country": "Czech Republic"]))
        let merged = limited.filled(from: record)
        XCTAssertEqual(merged.firstName, "Peter", "dane z QRZ mają pierwszeństwo")
        XCTAssertEqual(merged.grid, "JO70GG")
        XCTAssertEqual(merged.city, "Neratovice")
    }

    // MARK: - Lokalizacja

    func testRetranslation() {
        let translator = Retranslator.shared
        XCTAssertEqual(translator.translate("Zegar Maca zgodny z UTC (+0.01 s).", to: .en), "Mac clock matches UTC (+0.01 s).")
        XCTAssertEqual(translator.translate("Mac clock matches UTC (+0.01 s).", to: .pl), "Zegar Maca zgodny z UTC (+0.01 s).")
        XCTAssertEqual(translator.translate("SP5XTF DL1ABC -12", to: .en), "SP5XTF DL1ABC -12", "tekst spoza słownika - bez zmian")
        XCTAssertEqual(translator.translate("14.074 MHz · 20m", to: .en), "14.074 MHz · 20m", "zbyt ogólne szablony pomijane")
    }

    func testEveryTemplateHasSamePlaceholders() {
        let regex = try! NSRegularExpression(pattern: "\\{(\\d+)\\}")
        func placeholders(_ s: String) -> Set<String> {
            Set(regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
        }
        for (polish, english) in englishStrings {
            XCTAssertEqual(placeholders(polish), placeholders(english), "różne pola {n}: \(polish)")
        }
    }

    // MARK: - POTA

    @MainActor
    func testPOTASpotParsing() throws {
        let json: [String: Any] = ["spotId": 12345, "activator": "k4swl", "frequency": "14062.5", "mode": "CW",
                                   "reference": "US-0062", "parkName": NSNull(), "name": "Blue Ridge Parkway",
                                   "spotTime": "2026-03-04T20:08:51", "comments": "QRT thanks all", "count": 7]
        let spot = try XCTUnwrap(POTASpot(json: json))
        XCTAssertEqual(spot.activator, "K4SWL")
        XCTAssertEqual(spot.frequencyHz, 14_062_500)
        XCTAssertEqual(spot.band, "20m")
        XCTAssertEqual(spot.parkName, "Blue Ridge Parkway", "nazwa w „name”, gdy parkName jest null")
        XCTAssertTrue(spot.isQRT)
        XCTAssertEqual(spot.modeGroup, "CW")
        XCTAssertEqual(POTAManager.radioMode(for: spot), "3", "CW-U")

        var q = Self.qso("K4SWL", "20m", "CW")
        q.extra["SIG"] = "POTA"
        q.extra["SIG_INFO"] = "US-0062@US-NC, US-0099"
        XCTAssertEqual(POTAManager.parkRefs(of: q), ["US-0062", "US-0099"])
    }
}
