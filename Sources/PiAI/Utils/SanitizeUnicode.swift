import Foundation

/// Removes unpaired Unicode surrogate code units from a string.
///
/// Port of upstream `utils/sanitize-unicode.ts`. Unpaired high surrogates
/// (`0xD800`–`0xDBFF` without a following low surrogate) and unpaired low
/// surrogates (`0xDC00`–`0xDFFF` without a preceding high surrogate) cause JSON
/// serialization errors in many API providers. Properly paired surrogates
/// (emoji and other astral characters) are preserved.
///
/// Swift `String`s are Unicode scalar sequences and normally cannot hold lone
/// surrogates, but a string built from raw UTF-16 code units can; this helper
/// normalizes such input when constructible.
public enum SanitizeUnicode {
    public static func sanitize(_ text: String) -> String {
        let units = Array(text.utf16)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(units.count)

        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit >= 0xD800 && unit <= 0xDBFF {
                if index + 1 < units.count, units[index + 1] >= 0xDC00, units[index + 1] <= 0xDFFF {
                    let high = UInt32(unit) - 0xD800
                    let low = UInt32(units[index + 1]) - 0xDC00
                    let value = 0x10000 + (high << 10) + low
                    if let scalar = Unicode.Scalar(value) {
                        scalars.append(scalar)
                    }
                    index += 2
                    continue
                }
                // Unpaired high surrogate: drop it.
                index += 1
                continue
            }
            if unit >= 0xDC00 && unit <= 0xDFFF {
                // Unpaired low surrogate: drop it.
                index += 1
                continue
            }
            if let scalar = Unicode.Scalar(UInt32(unit)) {
                scalars.append(scalar)
            }
            index += 1
        }

        return String(scalars)
    }
}
