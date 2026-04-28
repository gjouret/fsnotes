//
//  EntityParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: HTML entity references.
//
//  CommonMark §6.5: three entity reference forms inside a paragraph:
//    1. Named:   `&name;` where `name` is a recognised HTML5 entity
//    2. Decimal: `&#nnnn;` where `nnnn` is 1–7 decimal digits ≤ 0x10FFFF
//    3. Hex:     `&#xnnnn;` where `nnnn` is 1–6 hex digits ≤ 0x10FFFF
//
//  All three return the raw source text (including `&` and `;`) so the
//  serializer can round-trip without decoding.
//
//  Ports `MarkdownParser.tryMatchEntity` + the `knownHTMLEntities`
//  data table (the latter is the FSNotes++ subset of HTML5 named
//  entities — see the table comment in MarkdownParser for the rationale).
//
//  Spec bucket: Entity and numeric character references 17/17 (100%).
//

import Foundation

public enum EntityParser {

    public struct Match {
        /// The complete source text including `&` and `;` (e.g.
        /// `&amp;`, `&#65;`, `&#x41;`). Stored on `Inline.entity(...)`.
        public let entity: String
        public let endIndex: Int
    }

    // MARK: - Numeric forms

    /// `&#xnnnn;` — hex digits up to 6, code point ≤ 0x10FFFF.
    private static let hexNumeric: Parser<String> = Parser { input in
        // Expects `#x` already validated by the dispatch in `parser`.
        var current = input
        guard let xCh = current.first, xCh == "x" || xCh == "X" else {
            return .failure(message: "expected x", remainder: input)
        }
        current = current.dropFirst()
        var digits = ""
        while let c = current.first, c.isHexDigit {
            digits.append(c)
            current = current.dropFirst()
            if digits.count > 6 {
                return .failure(message: "hex entity > 6 digits", remainder: input)
            }
        }
        guard !digits.isEmpty,
              let cp = UInt32(digits, radix: 16),
              cp <= 0x10FFFF,
              current.first == ";" else {
            return .failure(message: "invalid hex numeric reference", remainder: input)
        }
        return .success(value: digits, remainder: current.dropFirst())
    }

    /// `&#nnnn;` — decimal digits up to 7, code point ≤ 0x10FFFF.
    private static let decNumeric: Parser<String> = Parser { input in
        var current = input
        var digits = ""
        while let c = current.first, c.isNumber {
            digits.append(c)
            current = current.dropFirst()
            if digits.count > 7 {
                return .failure(message: "decimal entity > 7 digits", remainder: input)
            }
        }
        guard !digits.isEmpty,
              let cp = UInt32(digits),
              cp <= 0x10FFFF,
              current.first == ";" else {
            return .failure(message: "invalid decimal numeric reference", remainder: input)
        }
        return .success(value: digits, remainder: current.dropFirst())
    }

    // MARK: - Named form

    /// `&name;` — first char must be ASCII letter; subsequent chars
    /// ASCII letter or digit; name must appear in `knownHTMLEntities`.
    private static let named: Parser<String> = Parser { input in
        var current = input
        guard let first = current.first, first.isLetter else {
            return .failure(message: "named entity must start with letter", remainder: input)
        }
        var name = String(first)
        current = current.dropFirst()
        while let c = current.first, c.isLetter || c.isNumber {
            name.append(c)
            current = current.dropFirst()
        }
        guard current.first == ";", knownHTMLEntities.contains(name) else {
            return .failure(message: "unknown or unterminated named entity", remainder: input)
        }
        return .success(value: name, remainder: current.dropFirst())
    }

    /// Run the combinator. Returns nil if the cursor isn't at `&` or
    /// the body fails any of the three sub-grammars.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start < chars.count, chars[start] == "&" else { return nil }
        guard start + 1 < chars.count else { return nil }

        let slice = String(chars[start..<chars.count])
        let body = Substring(slice).dropFirst()  // drop `&`

        // Dispatch by lookahead: `#x` → hex, `#` → decimal, otherwise
        // try named.
        if body.first == "#" {
            let afterHash = body.dropFirst()
            if afterHash.first == "x" || afterHash.first == "X" {
                if case .success(_, let rem) = hexNumeric.parse(afterHash) {
                    let consumed = slice.count - rem.count
                    return Match(
                        entity: String(slice.prefix(consumed)),
                        endIndex: start + consumed
                    )
                }
                return nil
            }
            if case .success(_, let rem) = decNumeric.parse(afterHash) {
                let consumed = slice.count - rem.count
                return Match(
                    entity: String(slice.prefix(consumed)),
                    endIndex: start + consumed
                )
            }
            return nil
        }
        if case .success(_, let rem) = named.parse(body) {
            let consumed = slice.count - rem.count
            return Match(
                entity: String(slice.prefix(consumed)),
                endIndex: start + consumed
            )
        }
        return nil
    }

    // MARK: - Known HTML5 entity table

    /// FSNotes++ subset of HTML5 named entities. Pure data; ported
    /// verbatim from `MarkdownParser.knownHTMLEntities` to keep the
    /// validation surface where the parser is.
    private static let knownHTMLEntities: Set<String> = [
        // Core XML entities
        "amp", "lt", "gt", "quot", "apos",
        // Whitespace and special
        "nbsp", "ensp", "emsp", "thinsp", "shy", "lrm", "rlm", "zwj", "zwnj",
        // Typography
        "copy", "reg", "trade", "mdash", "ndash", "hellip", "bull", "middot",
        "lsquo", "rsquo", "ldquo", "rdquo", "sbquo", "bdquo",
        "laquo", "raquo", "lsaquo", "rsaquo",
        "dagger", "Dagger", "permil",
        // Arrows
        "larr", "rarr", "uarr", "darr", "harr", "lArr", "rArr", "uArr", "dArr", "hArr",
        // Math and symbols
        "sect", "para", "deg", "plusmn", "times", "divide", "micro",
        "cent", "pound", "euro", "yen", "curren",
        "iexcl", "iquest", "ordf", "ordm", "not", "macr", "acute",
        "cedil", "sup1", "sup2", "sup3",
        "frac14", "frac12", "frac34",
        "fnof", "minus", "lowast", "radic", "prop", "infin",
        "ang", "and", "or", "cap", "cup", "int",
        "there4", "sim", "cong", "asymp", "ne", "equiv", "le", "ge",
        "sub", "sup", "nsub", "sube", "supe",
        "oplus", "otimes", "perp", "sdot",
        "lceil", "rceil", "lfloor", "rfloor", "lang", "rang",
        "loz", "sum", "prod", "forall", "part", "exist", "empty",
        "nabla", "isin", "notin", "ni",
        // Card suits
        "hearts", "spades", "clubs", "diams",
        // Greek
        "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta",
        "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi",
        "Rho", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi",
        "rho", "sigmaf", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
        "thetasym", "upsih", "piv",
        // Latin extended
        "AElig", "Aacute", "Acirc", "Agrave", "Aring", "Atilde", "Auml",
        "Ccedil", "ETH", "Eacute", "Ecirc", "Egrave", "Euml",
        "Iacute", "Icirc", "Igrave", "Iuml",
        "Ntilde", "Oacute", "Ocirc", "Ograve", "Oslash", "Otilde", "Ouml",
        "THORN", "Uacute", "Ucirc", "Ugrave", "Uuml", "Yacute",
        "aacute", "acirc", "agrave", "aring", "atilde", "auml",
        "ccedil", "eacute", "ecirc", "egrave", "euml",
        "eth", "iacute", "icirc", "igrave", "iuml",
        "ntilde", "oacute", "ocirc", "ograve", "oslash", "otilde", "ouml",
        "szlig", "thorn", "uacute", "ucirc", "ugrave", "uuml", "yacute", "yuml",
        // Additional HTML5 entities from CommonMark spec examples
        "Dcaron", "HilbertSpace", "DifferentialD",
        "ClockwiseContourIntegral", "ngE",
    ]
}
