//
//  TableTextRenderer.swift
//  FSNotesCore
//
//  Renders a Block.table into an NSAttributedString using plain text
//  with tab-separated columns and a box-drawing separator under the
//  header row.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: header cells, data rows.
//  - Output: NSAttributedString with one line per row, cells padded
//    to equal column widths, and a box-drawing separator after the
//    header. The raw markdown pipe syntax is CONSUMED by the parser
//    and NEVER reaches the rendered output.
//  - Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum TableTextRenderer {

    public static func render(
        header: [String],
        rows: [[String]],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let colCount = header.count

        // Compute max width per column across header + all rows.
        var widths = header.map { $0.count }
        for row in rows {
            for (c, cell) in row.enumerated() where c < colCount {
                widths[c] = max(widths[c], cell.count)
            }
        }
        // Minimum width of 3 for readability.
        widths = widths.map { max($0, 3) }

        // Build the text table.
        var lines: [String] = []

        // Header row
        let headerLine = header.enumerated().map { (c, cell) in
            cell.padding(toLength: widths[c], withPad: " ", startingAt: 0)
        }.joined(separator: "   ")
        lines.append(headerLine)

        // Separator row using box-drawing characters
        let separatorLine = widths.map { w in
            String(repeating: "\u{2500}", count: w)
        }.joined(separator: "   ")
        lines.append(separatorLine)

        // Data rows
        for row in rows {
            let dataLine = (0..<colCount).map { c in
                let cell = c < row.count ? row[c] : ""
                return cell.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }.joined(separator: "   ")
            lines.append(dataLine)
        }

        let text = lines.joined(separator: "\n")

        // Use a monospace font derived from the body font size for alignment.
        let monoFont: PlatformFont
        #if os(OSX)
        monoFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        #else
        monoFont = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        #endif

        let attrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: PlatformColor.label
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }
}
