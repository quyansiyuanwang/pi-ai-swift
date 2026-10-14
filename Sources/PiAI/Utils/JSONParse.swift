import Foundation

/// Best-effort JSON parsing helpers.
///
/// Mirrors the repair pass of upstream `utils/json-parse.ts` (`repairJson` /
/// `parseJsonWithRepair`). The upstream file additionally depends on the
/// `partial-json` npm package to parse *incomplete* tool arguments. The Swift
/// port's simplified event contract only needs finalized argument strings (the
/// raw fragments are forwarded verbatim to consumers), so partial parsing is
/// intentionally omitted; callers parse the concatenated string once at the
/// end and fall back to `{}` when it is still malformed.
public enum JSONParse {
    private static let validEscapes: Set<Unicode.Scalar> = ["\"", "\\", "/", "b", "f", "n", "r", "t"]

    /// Repairs malformed JSON string literals by escaping raw control
    /// characters and doubling backslashes before invalid escapes.
    public static func repair(_ json: String) -> String {
        let scalars = Array(json.unicodeScalars)
        var repaired = String()
        repaired.reserveCapacity(json.count)

        var inString = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            if !inString {
                repaired.unicodeScalars.append(scalar)
                if scalar == "\"" { inString = true }
                index += 1
                continue
            }

            if scalar == "\"" {
                repaired.unicodeScalars.append(scalar)
                inString = false
                index += 1
                continue
            }

            if scalar == "\\" {
                guard index + 1 < scalars.count else {
                    repaired += "\\\\"
                    index += 1
                    continue
                }
                let next = scalars[index + 1]

                if next == "u", index + 5 < scalars.count,
                   scalars[(index + 2)...(index + 5)].allSatisfy({ isHexDigit($0) }) {
                    repaired += "\\u"
                    for offset in 2...5 { repaired.unicodeScalars.append(scalars[index + offset]) }
                    index += 6
                    continue
                }

                if validEscapes.contains(next) {
                    repaired.unicodeScalars.append("\\")
                    repaired.unicodeScalars.append(next)
                    index += 2
                    continue
                }

                repaired += "\\\\"
                index += 1
                continue
            }

            if isControl(scalar) {
                repaired += escaped(scalar)
            } else {
                repaired.unicodeScalars.append(scalar)
            }
            index += 1
        }

        return repaired
    }

    /// Parses `json`, retrying once after ``repair(_:)`` when the first attempt
    /// fails. Returns `nil` when the (repaired) text is still invalid.
    public static func parse(_ json: String) -> JSONValue? {
        if let value = try? decode(json) { return value }
        let repaired = repair(json)
        guard repaired != json else { return nil }
        return try? decode(repaired)
    }

    private static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x00 && scalar.value <= 0x1F
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "\u{08}": return "\\b"
        case "\u{0C}": return "\\f"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default: return String(format: "\\u%04x", scalar.value)
        }
    }
}
