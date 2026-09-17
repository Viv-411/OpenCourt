import Foundation

public enum OpenCourtJSON {
    /// PostgREST timestamps look like `2026-09-16T20:01:02.123456+00:00` (microseconds, and
    /// sometimes no fractional part at all).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseTimestamp(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad timestamp \(raw)")
            )
        }
        return d
    }

    public static func parseTimestamp(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // Normalise fractional seconds to milliseconds, which ISO8601DateFormatter accepts.
        if let dot = s.firstIndex(of: ".") {
            let fracStart = s.index(after: dot)
            let fracEnd = s[fracStart...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
            let digits = String(s[fracStart..<fracEnd].prefix(3)).padding(
                toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(fracStart..<fracEnd, with: digits)
        }
        if s.hasSuffix("+00") { s += ":00" }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
