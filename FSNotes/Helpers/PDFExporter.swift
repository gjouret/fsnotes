//
//  PDFExporter.swift
//  FSNotes
//
//  Created for FSNotes share feature.
//

import AppKit

/// Generates a PDF from an EditTextView's current attributed content using
/// NSView.dataWithPDF(inside:). This is the production PDF path used for
/// both export and sharing. It does NOT use WKWebView/MPreview.
class PDFExporter: NSObject {

    /// Export the contents of `textView` to `outputURL` as a PDF.
    /// Returns the output URL on success, nil on failure.
    @discardableResult
    static func export(textView: EditTextView, to outputURL: URL) -> URL? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        // Ensure the full document is laid out before measuring
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // usedRect may be empty if the note is blank
        let pdfRect = usedRect.isEmpty
            ? NSRect(x: 0, y: 0, width: 595, height: 842)
            : NSRect(origin: .zero, size: usedRect.size)

        let pdfData = textView.dataWithPDF(inside: pdfRect)
        do {
            try pdfData.write(to: outputURL)
            return outputURL
        } catch {
            return nil
        }
    }
}
