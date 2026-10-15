/// Guesses a country code from a server name: flag emoji first,
/// then country names in Russian and English, then two-letter codes like "NL-1".
public enum CountryDetector {
    public static func detect(in name: String) -> String? {
        if let flag = flagCode(in: name) { return flag }

        // Single words must start a word ("дания" must not match "задание");
        // phrases with a space or hyphen are searched as substrings.
        let lower = name.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        for (code, keys) in keywords {
            for key in keys {
                let isPhrase = key.contains(" ") || key.contains("-")
                if isPhrase ? lower.contains(key) : words.contains(where: { $0.hasPrefix(key) }) {
                    return code
                }
            }
        }

        for token in name.split(whereSeparator: { !$0.isLetter }) where token.count == 2 {
            let code = String(token)
            if code == code.uppercased(), knownCodes.contains(code) { return code == "UK" ? "GB" : code }
        }
        return nil
    }

    /// Code of the first flag emoji (a pair of regional indicator symbols).
    static func flagCode(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        for index in 0..<(scalars.count - 1) {
            let first = scalars[index].value
            let second = scalars[index + 1].value
            if isRegionalIndicator(first), isRegionalIndicator(second),
               let a = Unicode.Scalar(first - 0x1F1E6 + 65), let b = Unicode.Scalar(second - 0x1F1E6 + 65) {
                return String([Character(a), Character(b)])
            }
        }
        return nil
    }

    /// The name without flag emoji, with spaces tidied up.
    public static func stripFlags(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { !isRegionalIndicator($0.value) && $0.value != 0xFE0F }
        var result = String(String.UnicodeScalarView(kept))
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isRegionalIndicator(_ value: UInt32) -> Bool {
        (0x1F1E6...0x1F1FF).contains(value)
    }

    // Word stems in Russian match the start of a word: "германи" → "Германия", "Германии".
    private static let keywords: [(String, [String])] = [
        ("NL", ["нидерланд", "голланд", "netherlands", "holland", "amsterdam", "амстердам"]),
        ("DE", ["германи", "germany", "deutschland", "frankfurt", "франкфурт", "берлин", "berlin"]),
        ("FI", ["финлянд", "finland", "helsinki", "хельсинки"]),
        ("SE", ["швеци", "sweden", "stockholm", "стокгольм"]),
        ("NO", ["норвеги", "norway"]),
        ("DK", ["дания", "дании", "denmark"]),
        ("PL", ["польш", "poland", "warsaw", "варшав"]),
        ("CZ", ["чехи", "czech"]),
        ("AT", ["австри", "austria", "vienna", "вена"]),
        ("CH", ["швейцари", "switzerland", "zurich", "цюрих"]),
        ("FR", ["франци", "france", "paris", "париж"]),
        ("GB", ["великобритани", "англи", "united kingdom", "britain", "england", "london", "лондон"]),
        ("IE", ["ирланди", "ireland"]),
        ("ES", ["испани", "spain", "madrid"]),
        ("PT", ["португали", "portugal"]),
        ("IT", ["итали", "italy", "milan", "милан"]),
        ("EE", ["эстони", "estonia", "tallinn", "таллин"]),
        ("LV", ["латви", "latvia", "riga", "рига"]),
        ("LT", ["литв", "lithuania", "vilnius", "вильнюс"]),
        ("RO", ["румыни", "romania"]),
        ("BG", ["болгари", "bulgaria"]),
        ("RS", ["серби", "serbia"]),
        ("MD", ["молдов", "moldova"]),
        ("UA", ["украин", "ukraine"]),
        ("BY", ["беларус", "belarus"]),
        ("RU", ["росси", "russia", "москв", "moscow"]),
        ("KZ", ["казахстан", "kazakhstan", "алмат", "almaty"]),
        ("AM", ["армени", "armenia"]),
        ("GE", ["грузия", "грузии", "georgia", "тбилиси"]),
        ("TR", ["турци", "turkey", "türkiye", "istanbul", "стамбул"]),
        ("AE", ["оаэ", "эмират", "emirates", "dubai", "дубай"]),
        ("IL", ["израил", "israel"]),
        ("IN", ["индия", "индии", "india"]),
        ("SG", ["сингапур", "singapore"]),
        ("HK", ["гонконг", "hong kong", "hongkong"]),
        ("JP", ["япони", "japan", "tokyo", "токио"]),
        ("KR", ["корея", "кореи", "korea", "seoul", "сеул"]),
        ("AU", ["австрали", "australia", "sydney"]),
        ("CA", ["канад", "canada", "toronto"]),
        ("US", ["сша", "америк", "united states", "usa", "new york", "нью-йорк", "los angeles"]),
        ("BR", ["бразили", "brazil"]),
        ("AR", ["аргентин", "argentina"]),
        ("MX", ["мексик", "mexico"]),
    ]

    private static let knownCodes: Set<String> = [
        "NL", "DE", "FI", "SE", "NO", "DK", "PL", "CZ", "AT", "CH", "FR", "GB", "UK", "IE", "ES", "PT", "IT",
        "EE", "LV", "LT", "RO", "BG", "RS", "MD", "UA", "BY", "RU", "KZ", "AM", "GE", "TR", "AE", "IL", "IN",
        "SG", "HK", "JP", "KR", "AU", "CA", "US", "BR", "AR", "MX",
    ]
}
