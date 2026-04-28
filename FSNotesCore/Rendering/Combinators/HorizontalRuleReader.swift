//
//  HorizontalRuleReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: thematic break (horizontal rule).
//
//  CommonMark §4.1 — a line of 3+ of the same character (`-`, `*`, or
//  `_`), with up to 3 leading spaces, optional spaces/tabs between
//  the chars, and nothing else on the line.
//
//  Spec bucket: Thematic breaks 19/19 (100%).
//

import Foundation

public enum HorizontalRuleReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
    }

    /// Detect whether `line` is a thematic break. Returns the marker
    /// character and the count of marker chars (not spaces) — the
    /// length is preserved on the resulting Block for byte-equal
    /// round-trip serialization.
    public static func detect(_ line: String) -> (character: Character, length: Int)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        let hrChar = chars[i]
        guard hrChar == "-" || hrChar == "*" || hrChar == "_" else { return nil }
        var count = 0
        while i < chars.count {
            if chars[i] == hrChar {
                count += 1
            } else if chars[i] == " " || chars[i] == "\t" {
                // spaces/tabs allowed between marker characters
            } else {
                return nil
            }
            i += 1
        }
        guard count >= 3 else { return nil }
        return (hrChar, count)
    }

    /// Read a single-line thematic break starting at `lines[start]`.
    public static func read(lines: [String], from start: Int) -> ReadResult? {
        guard start < lines.count,
              let hr = detect(lines[start]) else { return nil }
        return ReadResult(
            block: .horizontalRule(character: hr.character, length: hr.length),
            nextIndex: start + 1
        )
    }
}
