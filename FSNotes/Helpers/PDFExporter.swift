//
//  PDFExporter.swift
//  FSNotes
//
//  Created for FSNotes share feature.
//

import AppKit

/// Generates a PDF from an EditTextView's current attributed content using
/// NSView.dataWithPDF(inside:). This is the production PDF path used for
/// both export and sharing.
class PDFExporter: NSObject {

    /// Export the contents of `textView` to `outputURL` as a PDF.
    /// Returns the output URL on success, nil on failure.
    @discardableResult
    static func export(textView: EditTextView, to outputURL: URL) -> URL? {
        // Phase 2a/2f.6: PDF export needs to know the true used rect of
        // the document so `dataWithPDF(inside:)` captures the full
        // content (not just what's on-screen). TK1 exposes this via
        // `NSLayoutManager.usedRect(for:)`; TK2 exposes the same via
        // `NSTextLayoutManager.usageBoundsForTextContainer` (after
        // ensuring layout by enumerating fragments).
        guard let textContainer = textView.textContainer else { return nil }

        let usedRect = measureUsedRect(textView: textView, textContainer: textContainer)

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

    /// Measures the used rect of the editor's content, branching between
    /// TK1 (`NSLayoutManager.usedRect(for:)`) and TK2
    /// (`NSTextLayoutManager.usageBoundsForTextContainer`).
    ///
    /// Returns `.zero` if neither path can measure (e.g. no layout
    /// manager wired up at all).
    static func measureUsedRect(
        textView: EditTextView,
        textContainer: NSTextContainer
    ) -> NSRect {
        if let layoutManager = textView.layoutManagerIfTK1 {
            layoutManager.ensureLayout(for: textContainer)
            return layoutManager.usedRect(for: textContainer)
        }

        if let tlm = textView.textLayoutManager {
            return measureUsedRectTK2(tlm: tlm)
        }

        return .zero
    }

    /// TK2 used-rect: ensures every layout fragment is resolved (so
    /// `usageBoundsForTextContainer` is populated), then returns the
    /// manager's reported usage bounds. Falls back to summing fragment
    /// frames if the usage bounds come back empty — this handles views
    /// that haven't had a full layout pass yet.
    static func measureUsedRectTK2(tlm: NSTextLayoutManager) -> NSRect {
        // Walk every fragment first to force layout. This is what makes
        // `usageBoundsForTextContainer` return accurate dimensions —
        // without `.ensuresLayout` it only reflects the currently-visible
        // viewport.
        var unionFrame: NSRect = .zero
        let docStart = tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(
            from: docStart,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if unionFrame == .zero {
                unionFrame = frame
            } else {
                unionFrame = unionFrame.union(frame)
            }
            return true
        }

        let usage = tlm.usageBoundsForTextContainer
        // Prefer the manager's own bounds when non-empty — it accounts
        // for container inset/padding. Otherwise fall back to the
        // fragment union (empty doc: both are zero, which is expected).
        if !usage.isEmpty {
            return usage
        }
        return unionFrame
    }
}
