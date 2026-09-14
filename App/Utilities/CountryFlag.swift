import Foundation

// MARK: - CountryFlag (#454)
//
// ISO-3166-1 alpha-2 country code → the flag emoji built from the two Regional
// Indicator Symbols (U+1F1E6…U+1F1FF). Used by the Connection-health card to put
// a flag next to the tunnel exit's location. Pure and unit-tested.

enum CountryFlag {

    /// "RU" → "🇷🇺". Case-insensitive and whitespace-trimmed; returns nil unless
    /// the input is EXACTLY two ASCII letters (A–Z), so "R", "R1", "", "RUS" and
    /// any non-letter input yield nil rather than a broken glyph.
    static func emoji(iso2: String) -> String? {
        let code = iso2.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let scalars = Array(code.unicodeScalars)
        guard scalars.count == 2 else { return nil }
        var flag = ""
        for scalar in scalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }   // A–Z only
            guard let ri = Unicode.Scalar(0x1F1E6 + (scalar.value - 65)) else { return nil }
            flag.unicodeScalars.append(ri)
        }
        return flag
    }
}
