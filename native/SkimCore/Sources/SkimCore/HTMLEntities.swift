import Foundation

/// The one HTML entity decoder in the app. Feeds, extracted article bodies and
/// scraped titles all arrive with entities in them, and every surface that
/// renders that text as plain text (the iOS reader above all) has to decode the
/// same set — before this existed each call site carried its own copy that knew
/// about eight entities, so ordinary punctuation like `&rsquo;` reached the
/// reader raw ("Let&rsquo;s").
///
/// One left-to-right pass, so a decoded value is never decoded again:
/// `&amp;rsquo;` is literal text "&rsquo;", not "’".
public enum HTMLEntities {
    /// Named entities worth knowing: the XML five, spaces, and the punctuation
    /// publishers actually emit (curly quotes, dashes, ellipsis, symbols).
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "laquo": "«", "raquo": "»",
        "ndash": "–", "mdash": "—", "minus": "−", "hellip": "…",
        "bull": "•", "middot": "·", "dagger": "†", "Dagger": "‡",
        "prime": "′", "Prime": "″", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å",
        "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "oslash": "ø",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü",
        "ntilde": "ñ", "ccedil": "ç", "szlig": "ß", "aelig": "æ",
        "Eacute": "É", "Aacute": "Á", "Oacute": "Ó", "Uacute": "Ú", "Ntilde": "Ñ",
    ]

    /// Decodes named and numeric (`&#8217;`, `&#x2019;`) entities. Anything that
    /// is not an entity is left exactly as it was, including a bare `&`.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            out += text[index..<ampersand]
            // An entity name is short; a ";" further out belongs to other text.
            let searchEnd = text.index(ampersand, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text[text.index(after: ampersand)..<searchEnd].firstIndex(of: ";"),
                  let replacement = value(of: String(text[text.index(after: ampersand)..<semicolon]))
            else {
                out.append("&")
                index = text.index(after: ampersand)
                continue
            }
            out += replacement
            index = text.index(after: semicolon)
        }
        out += text[index...]
        return out
    }

    /// The character an entity body ("amp", "#8217", "#x2019") stands for, or
    /// nil when it is not an entity we decode.
    private static func value(of body: String) -> String? {
        if body.isEmpty { return nil }
        if let replacement = named[body] { return replacement }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let hex = digits.lowercased().hasPrefix("x")
        guard let codepoint = UInt32(hex ? digits.dropFirst() : digits, radix: hex ? 16 : 10),
              let scalar = UnicodeScalar(codepoint)
        else { return nil }
        return String(Character(scalar))
    }
}

public extension String {
    /// Named and numeric HTML entities decoded; see `HTMLEntities`.
    var decodingHTMLEntities: String { HTMLEntities.decode(self) }
}
