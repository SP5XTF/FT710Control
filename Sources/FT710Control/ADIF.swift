import Foundation

/// Format ADIF (plik .adi): zapis i odczyt.
/// Pole: <NAZWA:długość>wartość, rekord kończy <EOR>, nagłówek kończy <EOH>.
enum ADIF {
    static let programVersion = "0.9.5-beta"

    /// Pola mapowane na właściwości QSO - reszta trafia do `extra`.
    static let knownFields: Set<String> = [
        "CALL", "QSO_DATE", "TIME_ON", "QSO_DATE_OFF", "TIME_OFF", "BAND", "FREQ", "MODE", "SUBMODE",
        "RST_SENT", "RST_RCVD", "NAME", "QTH", "GRIDSQUARE", "COMMENT", "STATION_CALLSIGN", "MY_GRIDSQUARE"
    ]

    // MARK: - Daty (zawsze UTC)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let dateFormatter = formatter("yyyyMMdd")
    private static let timeFormatter = formatter("HHmmss")
    private static let dateTimeParser = formatter("yyyyMMddHHmmss")

    static func parseDate(_ date: String, _ time: String) -> Date? {
        let d = date.trimmingCharacters(in: .whitespaces)
        var t = time.trimmingCharacters(in: .whitespaces)
        if t.count == 4 { t += "00" }
        guard d.count == 8, t.count == 6 else { return nil }
        return dateTimeParser.date(from: d + t)
    }

    // MARK: - Zapis

    /// Pliki .adi muszą być w ASCII: polskie znaki są zamieniane na łacińskie odpowiedniki.
    static func ascii(_ text: String) -> String {
        var replaced = text.replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "L")
        // typografia (półpauza, cudzysłowy, apostrofy, wielokropek) - odpowiedniki ASCII zamiast „?”
        for (from, to) in [("–", "-"), ("—", "-"), ("„", "\""), ("”", "\""), ("“", "\""), ("‘", "'"), ("’", "'"), ("…", "...")] {
            replaced = replaced.replacingOccurrences(of: from, with: to)
        }
        let stripped = replaced.applyingTransform(.stripDiacritics, reverse: false) ?? replaced
        var scalars = String.UnicodeScalarView()
        for scalar in stripped.unicodeScalars {
            scalars.append(scalar.isASCII ? scalar : Unicode.Scalar(UInt8(63)))   // '?'
        }
        return String(scalars)
    }

    /// Cały tekst pliku w ASCII - zabezpieczenie przed zapisem z kodowaniem ASCII (każdy znak spoza
    /// ASCII w nagłówku albo polu wysypałby zapis: „couldn't be saved using the specified text encoding”).
    static func asciiFile(_ text: String) -> String { ascii(text) }

    static func field(_ name: String, _ value: String) -> String {
        let v = ascii(value)
        guard !v.isEmpty else { return "" }
        return "<\(name):\(v.utf8.count)>\(v) "
    }

    static func header() -> String {
        var out = "FT-710 Control - ADIF export\n"                  // zwykły myślnik: plik .adi musi być w ASCII
        out += field("ADIF_VER", "3.1.4") + "\n"
        out += field("PROGRAMID", "FT-710 Control") + "\n"
        out += field("PROGRAMVERSION", programVersion) + "\n"
        out += field("CREATED_TIMESTAMP", dateFormatter.string(from: Date()) + " " + timeFormatter.string(from: Date())) + "\n"
        return out + "<EOH>\n"
    }

    /// Pola stanu wysyłki do serwisów - zostają w dzienniku i eksporcie, ale nie są wysyłane do serwisów.
    static let uploadStatusFields: Set<String> = [
        "LOTW_QSL_SENT", "LOTW_QSLSDATE", "QRZCOM_QSO_UPLOAD_STATUS", "QRZCOM_QSO_UPLOAD_DATE",
        "EQSL_QSL_SENT", "EQSL_QSLSDATE", "CLUBLOG_QSO_UPLOAD_STATUS", "CLUBLOG_QSO_UPLOAD_DATE",
        "HRDLOG_QSO_UPLOAD_STATUS", "HRDLOG_QSO_UPLOAD_DATE", "APP_FT710CONTROL_CLOUDLOG", "APP_FT710CONTROL_CLOUDLOG_DATE",
        "APP_FT710CONTROL_WRL", "APP_FT710CONTROL_WRL_DATE", "APP_FT710CONTROL_WRL_ID"
    ]

    /// Jeden rekord ADIF zakończony <EOR>. `forUpload`: bez pól stanu wysyłki; `extra`: pola dodatkowe
    /// (np. APP_EQSL_QTH_NICKNAME dla eQSL).
    static func record(_ q: QSO, forUpload: Bool = false, extra: [String: String] = [:]) -> String {
        var line = field("CALL", q.call)
        line += field("QSO_DATE", dateFormatter.string(from: q.start))
        line += field("TIME_ON", timeFormatter.string(from: q.start))
        if let end = q.end {
            line += field("QSO_DATE_OFF", dateFormatter.string(from: end))
            line += field("TIME_OFF", timeFormatter.string(from: end))
        }
        line += field("BAND", q.band)
        if q.freqHz > 0 {
            line += field("FREQ", String(format: "%.6f", Double(q.freqHz) / 1_000_000))
        }
        line += field("MODE", q.mode)
        line += field("SUBMODE", q.submode ?? "")
        line += field("RST_SENT", q.rstSent)
        line += field("RST_RCVD", q.rstRcvd)
        line += field("NAME", q.name)
        line += field("QTH", q.qth)
        line += field("GRIDSQUARE", q.grid)
        line += field("COMMENT", q.comment)
        line += field("STATION_CALLSIGN", q.stationCall)
        line += field("MY_GRIDSQUARE", q.myGrid)
        for (key, value) in q.extra.sorted(by: { $0.key < $1.key }) where !knownFields.contains(key) {
            if forUpload && uploadStatusFields.contains(key) { continue }
            line += field(key, value)
        }
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { line += field(key, value) }
        return line + "<EOR>"
    }

    static func export(_ qsos: [QSO]) -> String {
        var out = header() + "\n"
        for q in qsos.sorted(by: { $0.start < $1.start }) {
            out += record(q) + "\n"
        }
        return out
    }

    /// Data w formacie ADIF (RRRRMMDD, UTC).
    static func adifDate(_ date: Date) -> String { dateFormatter.string(from: date) }

    // MARK: - Odczyt

    /// Rekordy jako słowniki NAZWA -> wartość. Długości pól liczone w bajtach (UTF-8);
    /// po każdej wartości szukamy kolejnego '<', więc drobne rozjazdy długości nie psują reszty pliku.
    static func parse(_ text: String) -> [[String: String]] {
        let bytes = Array(text.utf8)
        let open = UInt8(ascii: "<")
        let close = UInt8(ascii: ">")

        // Nagłówek istnieje tylko wtedy, gdy plik nie zaczyna się od '<'.
        let firstNonSpace = bytes.first(where: { $0 != 32 && $0 != 9 && $0 != 10 && $0 != 13 })
        var inHeader = firstNonSpace != open

        var records: [[String: String]] = []
        var current: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            guard bytes[i] == open else { i += 1; continue }
            guard let end = bytes[i...].firstIndex(of: close) else { break }
            let tag = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
            i = end + 1

            let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            if name == "EOH" {
                inHeader = false
                current = [:]
                continue
            }
            if name == "EOR" {
                if !inHeader && !current.isEmpty { records.append(current) }
                current = [:]
                continue
            }
            guard parts.count >= 2,
                  let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), length >= 0 else { continue }
            let valueEnd = min(i + length, bytes.count)
            let value = String(decoding: bytes[i..<valueEnd], as: UTF8.self)
            i = valueEnd
            if !inHeader { current[name] = value }
        }
        return records
    }

    static func qso(from record: [String: String]) -> QSO? {
        func value(_ key: String) -> String {
            (record[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let call = value("CALL").uppercased()
        let date = value("QSO_DATE")
        guard !call.isEmpty, let start = parseDate(date, record["TIME_ON"] ?? "0000") else { return nil }

        let freqHz = Double(value("FREQ")).map { Int(($0 * 1_000_000).rounded()) } ?? 0
        let bandField = value("BAND").lowercased()
        let band = bandField.isEmpty ? (LogFrequency.band(for: freqHz) ?? "") : bandField

        var end: Date?
        if !value("TIME_OFF").isEmpty {
            let dateOff = value("QSO_DATE_OFF").isEmpty ? date : value("QSO_DATE_OFF")
            end = parseDate(dateOff, value("TIME_OFF"))
        }
        let submode = value("SUBMODE").uppercased()

        var qso = QSO(call: call, start: start, end: end, freqHz: freqHz, band: band,
                      mode: value("MODE").uppercased(), submode: submode.isEmpty ? nil : submode)
        qso.rstSent = value("RST_SENT")
        qso.rstRcvd = value("RST_RCVD")
        qso.name = value("NAME")
        qso.qth = value("QTH")
        qso.grid = value("GRIDSQUARE").uppercased()
        qso.comment = value("COMMENT")
        qso.stationCall = value("STATION_CALLSIGN").uppercased()
        qso.myGrid = value("MY_GRIDSQUARE").uppercased()
        qso.extra = record.filter { !knownFields.contains($0.key) }
        return qso
    }
}
