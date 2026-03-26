//
//  TableEditorViewController.swift
//  FSNotes
//
//  Table data structures and markdown parsing/generation utilities.
//  The old modal dialog UI has been removed — table editing is now
//  handled inline by InlineTableView.
//

import Cocoa

enum TableUtility {

    struct TableData {
        var headers: [String]
        var rows: [[String]]
        var alignments: [NSTextAlignment]
    }

    // MARK: - Parse Markdown Table

    static func parse(markdown: String) -> TableData? {
        let lines = markdown.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard lines.count >= 2 else { return nil }

        let headers = parseCells(lines[0])
        var aligns = [NSTextAlignment](repeating: .left, count: headers.count)

        var dataStart = 1
        if lines.count > 1 {
            let sep = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if sep.range(of: #"^[\|\-\:\s]+$"#, options: .regularExpression) != nil {
                // Parse alignments from separator row
                let sepCells = parseCells(lines[1])
                for (i, cell) in sepCells.enumerated() where i < aligns.count {
                    let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") {
                        aligns[i] = .center
                    } else if trimmed.hasSuffix(":") {
                        aligns[i] = .right
                    } else {
                        aligns[i] = .left
                    }
                }
                dataStart = 2
            }
        }

        let rows = lines[dataStart...].map { parseCells($0) }
        return TableData(headers: headers, rows: Array(rows), alignments: aligns)
    }

    private static func parseCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Generate Markdown Table

    /// Generates a GFM markdown table string from the given headers, rows, and alignments.
    static func generate(headers: [String], rows: [[String]], alignments: [NSTextAlignment]) -> String {
        let colCount = headers.count
        let hdrs = headers.map { $0.isEmpty ? " " : $0 }
        let dataRows = rows.map { row in
            (0..<colCount).map { col in
                col < row.count ? (row[col].isEmpty ? " " : row[col]) : " "
            }
        }

        var widths = hdrs.map { $0.count }
        for row in dataRows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        widths = widths.map { max($0, 3) }

        let headerLine = "| " + hdrs.enumerated().map { i, h in
            h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: " | ") + " |"

        let sepLine = "| " + (0..<colCount).map { i in
            let w = widths[i]
            switch (i < alignments.count ? alignments[i] : .left) {
            case .center: return ":" + String(repeating: "-", count: max(w - 2, 1)) + ":"
            case .right: return String(repeating: "-", count: max(w - 1, 1)) + ":"
            default: return String(repeating: "-", count: w)
            }
        }.joined(separator: " | ") + " |"

        let rowLines = dataRows.map { row -> String in
            "| " + row.enumerated().map { i, cell in
                let w = i < widths.count ? widths[i] : cell.count
                return cell.padding(toLength: w, withPad: " ", startingAt: 0)
            }.joined(separator: " | ") + " |"
        }

        return ([headerLine, sepLine] + rowLines).joined(separator: "\n")
    }

    // MARK: - Detect Table at Cursor

    static func tableRange(in storage: NSTextStorage, at location: Int) -> NSRange? {
        let string = storage.string as NSString
        guard location < string.length else { return nil }

        let lineRange = string.paragraphRange(for: NSRange(location: location, length: 0))
        let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)

        guard line.hasPrefix("|") && line.hasSuffix("|") else { return nil }

        // Expand upward
        var start = lineRange.location
        while start > 0 {
            let prevRange = string.paragraphRange(for: NSRange(location: start - 1, length: 0))
            let prevLine = string.substring(with: prevRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if prevLine.hasPrefix("|") && prevLine.hasSuffix("|") {
                start = prevRange.location
            } else {
                break
            }
        }

        // Expand downward
        var end = NSMaxRange(lineRange)
        while end < string.length {
            let nextRange = string.paragraphRange(for: NSRange(location: end, length: 0))
            let nextLine = string.substring(with: nextRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if nextLine.hasPrefix("|") && nextLine.hasSuffix("|") {
                end = NSMaxRange(nextRange)
            } else {
                break
            }
        }

        return NSRange(location: start, length: end - start)
    }

    // MARK: - Find All Tables

    static func findAllTableRanges(in storage: NSTextStorage) -> [NSRange] {
        let string = storage.string as NSString
        var ranges: [NSRange] = []
        var pos = 0

        while pos < string.length {
            let lineRange = string.paragraphRange(for: NSRange(location: pos, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("|") && line.hasSuffix("|") {
                if let tableRange = tableRange(in: storage, at: lineRange.location) {
                    // Verify it has a separator line (at least 3 lines total)
                    let tableStr = string.substring(with: tableRange)
                    let tableLines = tableStr.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if tableLines.count >= 3 {
                        let sep = tableLines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if sep.range(of: #"^[\|\-\:\s]+$"#, options: .regularExpression) != nil {
                            ranges.append(tableRange)
                        }
                    }
                    // Skip past this table range to avoid re-scanning its lines
                    pos = NSMaxRange(tableRange)
                    continue
                }
            }

            pos = NSMaxRange(lineRange)
        }

        return ranges
    }
}
