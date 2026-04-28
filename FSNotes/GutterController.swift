//
//  GutterController.swift
//  FSNotes
//
//  Manages the left-hand gutter (pipe) in the editor: fold/unfold carets,
//  header level badges, mouse hover tracking, and click handling.
//  Extracted from EditTextView to reduce god object size.
//

import Cocoa
import STTextKitPlus

class GutterController {

    weak var textView: EditTextView?
    var isMouseInGutter = false

    /// Tracks which code block just had its content copied (for "Copied" feedback).
    private var copiedCodeBlockLocation: Int?
    /// Tracks which table just had its content copied (for "Copied" feedback).
    private var copiedTableLocation: Int?
    private var copiedFeedbackTimer: Timer?

    init(textView: EditTextView) {
        self.textView = textView
    }

    // MARK: - Click Handling

    func handleClick(_ event: NSEvent) -> Bool {
        guard let textView = textView else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let gutterWidth = EditTextView.gutterWidth

        let gutterRight = textView.textContainerInset.width
        let gutterLeft = gutterRight - gutterWidth
        guard point.x >= gutterLeft, point.x < gutterRight else { return false }

        guard let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return false }

        // Phase 4.5: TK1 gutter hit-test (via
        // `NSLayoutManager.characterIndex`) removed with the custom
        // layout-manager subclass. The app is TK2-only: iterate visible
        // `HeadingLayoutFragment`s to locate the heading whose y-range
        // contains the click.
        if let blockIdx = headerBlockIndexForClickYTK2(clickY: point.y) {
            processor.toggleFold(headerBlockIndex: blockIdx, textStorage: storage)
            textView.needsDisplay = true
            return true
        }
        // Code-block copy hit-testing under TK2: scan visible code
        // block fragments for a vertical hit on the first-line band.
        if handleCodeBlockCopyTK2(clickY: point.y) { return true }
        // Table copy hit-testing under TK2.
        if handleTableCopyTK2(clickY: point.y) { return true }
        return false
    }

    // MARK: - Fold Actions

    func toggleFoldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.toggleFold(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    /// Fold the header on the cursor line (no-op if not on a header or already folded).
    func foldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.foldHeader(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    /// Unfold the header on the cursor line (no-op if not on a header or already unfolded).
    func unfoldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.unfoldHeader(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    func foldAllHeaders() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        processor.foldAll(textStorage: storage)
        textView.needsDisplay = true
    }

    func unfoldAllHeaders() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        processor.unfoldAll(textStorage: storage)
        textView.needsDisplay = true
    }

    // MARK: - Hover Tracking

    func updateMouseTracking(at point: NSPoint) {
        guard let textView = textView else { return }
        let inGutter = point.x < textView.textContainerInset.width &&
                       point.x >= textView.textContainerInset.width - EditTextView.gutterWidth
        if inGutter != isMouseInGutter {
            isMouseInGutter = inGutter
            textView.needsDisplay = true
        }
    }

    // MARK: - Drawing

    func drawIcons(in dirtyRect: NSRect) {
        // Phase 4.5: TK1 gutter draw path (glyphRange, lineFragmentRect,
        // boundingRect) removed with the custom layout-manager subclass.
        // The app is TK2-only: iterate `HeadingLayoutFragment`s via
        // `enumerateTextLayoutFragments`.
        drawIconsTK2(in: dirtyRect)
    }

    // MARK: - TextKit 2 Gutter Support (Phase 2f.2)

    /// Per-heading visible-fragment record computed under TK2. `midY` is
    /// in the `textView`'s coordinate space (already has
    /// `textContainerOrigin.y` added), so draw code and hit-testing can
    /// use it directly without extra conversion.
    struct VisibleHeadingTK2 {
        /// Heading fragment's top in view coords.
        let minY: CGFloat
        /// Heading fragment's bottom in view coords.
        let maxY: CGFloat
        /// Heading fragment's vertical midpoint in view coords.
        let midY: CGFloat
        /// Character index into `NSTextStorage` at the start of the
        /// heading element. This is the index we feed to
        /// `TextStorageProcessor.headerBlockIndex(at:)` to map from a
        /// visible fragment back to a `processor.blocks` index.
        let charIndex: Int
    }

    /// Enumerate `HeadingLayoutFragment`s and return a record per
    /// heading, in document order. Used by both `drawIconsTK2` and
    /// `headerBlockIndexForClickYTK2`. Returns an empty array if the
    /// view is TK1 or if content storage / layout manager aren't wired.
    func visibleHeadingsTK2() -> [VisibleHeadingTK2] {
        guard let textView = textView,
              let tlm = textView.textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            return []
        }
        let originY = textView.textContainerOrigin.y
        var result: [VisibleHeadingTK2] = []

        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard fragment is HeadingLayoutFragment else { return true }
            guard let element = fragment.textElement,
                  let elementRange = element.elementRange else { return true }

            // Map TK2 NSTextLocation -> NSTextStorage character offset.
            let charIndex = NSRange(elementRange.location, in: tcs).location
            guard charIndex >= 0 else { return true }

            let frame = fragment.layoutFragmentFrame
            let minY = frame.minY + originY
            let maxY = frame.maxY + originY
            // Center on the first text-line's typographicBounds, not
            // the fragment frame: per-heading paragraphSpacing biases
            // push the geometric midY off the glyph row.
            let textCenterLocalY = fragment.textLineFragments.first?
                .typographicBounds.midY ?? frame.height / 2
            let midY = frame.minY + originY + textCenterLocalY

            result.append(VisibleHeadingTK2(
                minY: minY, maxY: maxY, midY: midY,
                charIndex: charIndex
            ))
            return true
        }
        return result
    }

    /// Draw fold carets, H-level badges, code-block copy icons and
    /// table copy icons under TK2. Fold carets show when the mouse is
    /// in the gutter OR the heading is collapsed. H-badges show on
    /// gutter hover (or when the cursor is parked on that heading and
    /// the editor is first responder). Code-block and table copy icons
    /// show on gutter hover.
    private func drawIconsTK2(in dirtyRect: NSRect) {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }

        let origin = textView.textContainerOrigin
        let gutterWidth = EditTextView.gutterWidth
        let gutterRight = origin.x
        let gutterLeft = gutterRight - gutterWidth

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: textView.bounds).setClip()

        // Gutter accent matches TK1 (tertiary label for appearance
        // adaptation — see bug #47 notes in TK1 draw path above).
        let gutterAccent = NSColor.tertiaryLabelColor

        // --- Headings: fold carets + H-level badges ---

        let cursorParagraphRange: NSRange? = {
            let idx = textView.selectedRange().location
            guard idx >= 0, idx < storage.length else { return nil }
            return (storage.string as NSString).paragraphRange(
                for: NSRange(location: idx, length: 0)
            )
        }()
        let isEditing = textView.window?.firstResponder === textView

        for heading in visibleHeadingsTK2() {
            // Find the matching block so we can read `collapsed`. The
            // processor's block array is source-of-truth for fold state
            // regardless of TK version.
            guard heading.charIndex < storage.length else { continue }

            // Skip if this heading is itself inside a folded range.
            if storage.attribute(.foldedContent,
                                 at: heading.charIndex,
                                 effectiveRange: nil) != nil {
                continue
            }

            guard let blockIdx = processor.headerBlockIndex(at: heading.charIndex) else {
                continue
            }
            let block = processor.blocks[blockIdx]
            // Phase 6 Tier B′ Sub-slice 2: route fold-state read
            // through the public side-table query instead of the
            // dual-written per-block legacy cache. The cache stays
            // in sync for now but will be retired once all readers
            // (incl. tests) have migrated.
            let isCollapsed = processor.isCollapsed(blockIndex: blockIdx)

            // Fold caret
            if isMouseInGutter || isCollapsed {
                let caretStr = isCollapsed ? "▶" : "▼"
                let caretFont = NSFont.systemFont(ofSize: 16, weight: .regular)
                let caretAttrs: [NSAttributedString.Key: Any] = [
                    .font: caretFont,
                    .foregroundColor: gutterAccent
                ]
                let caretSize = (caretStr as NSString).size(withAttributes: caretAttrs)
                let caretX = gutterRight - caretSize.width - 4
                let caretY = heading.midY - caretSize.height / 2
                (caretStr as NSString).draw(
                    at: NSPoint(x: caretX, y: caretY),
                    withAttributes: caretAttrs
                )
            }

            // H-level badge on hover or when the cursor is parked on
            // this heading. Level read off the `.headingLevel`
            // attribute stamped by `DocumentRenderer` (same attribute
            // `HeadingLayoutFragment` reads for its hairline decision),
            // with fallback to `processor.blocks[blockIdx].type` —
            // the block array always carries the level.
            let level: Int = {
                if let v = storage.attribute(
                    .headingLevel, at: heading.charIndex, effectiveRange: nil
                ) as? Int, v >= 1, v <= 6 {
                    return v
                }
                switch block.type {
                case .heading(let l): return l
                case .headingSetext(let l): return l
                default: return 0
                }
            }()
            let cursorOnThisLine = cursorParagraphRange.map {
                heading.charIndex >= $0.location &&
                heading.charIndex <= NSMaxRange($0)
            } ?? false
            if level >= 1, level <= 6,
               isMouseInGutter || (cursorOnThisLine && isEditing) {
                let badge = "H\(level)"
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.gray
                ]
                let badgeSize = (badge as NSString).size(
                    withAttributes: badgeAttrs
                )
                (badge as NSString).draw(
                    at: NSPoint(
                        x: gutterLeft + 2,
                        y: heading.midY - badgeSize.height / 2
                    ),
                    withAttributes: badgeAttrs
                )
            }
        }

        // --- Code-block copy icons ---

        if isMouseInGutter {
            for codeBlock in visibleCodeBlocksTK2() {
                let isCopied = (copiedCodeBlockLocation == codeBlock.range.location)
                let iconStr = isCopied ? "\u{2713}" : "\u{2398}" // ✓ or ⎘
                let iconAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let iconSize = (iconStr as NSString).size(withAttributes: iconAttrs)
                let iconX = gutterRight - iconSize.width - 4
                let iconY = codeBlock.firstLineMidY - iconSize.height / 2
                (iconStr as NSString).draw(
                    at: NSPoint(x: iconX, y: iconY),
                    withAttributes: iconAttrs
                )
            }
        }

        // --- Table copy icons ---

        if isMouseInGutter {
            for table in visibleTablesTK2() {
                let isCopied = (copiedTableLocation == table.range.location)
                let iconStr = isCopied ? "\u{2713}" : "\u{2398}" // ✓ or ⎘
                let iconAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let iconSize = (iconStr as NSString).size(withAttributes: iconAttrs)
                let iconX = gutterRight - iconSize.width - 4
                let iconY = table.topY + 4
                (iconStr as NSString).draw(
                    at: NSPoint(x: iconX, y: iconY),
                    withAttributes: iconAttrs
                )
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: - Code Block Fragment Discovery (TK2)

    /// Record of a visible code block under TK2. Multi-line code blocks
    /// arrive as multiple adjacent `CodeBlockLayoutFragment`s (TK2
    /// paragraph-splits on `\n`) — callers want ONE icon per logical
    /// block, so `visibleCodeBlocksTK2()` collapses adjacent runs and
    /// anchors the record at the FIRST fragment (matching TK1's
    /// "icon on the first line" placement).
    struct VisibleCodeBlockTK2 {
        /// First fragment's y-midpoint in view coords.
        let firstLineMidY: CGFloat
        /// First fragment's minimum y in view coords.
        let firstLineMinY: CGFloat
        /// First fragment's maximum y in view coords.
        let firstLineMaxY: CGFloat
        /// `processor.blocks`-style `range` (covers the entire block,
        /// fences included). Used as the stable identity for "copied"
        /// feedback.
        let range: NSRange
        /// `processor.blocks`-style `contentRange` — the text between
        /// the fences. This is what the copy button puts on the
        /// pasteboard.
        let contentRange: NSRange
    }

    /// Enumerate `CodeBlockLayoutFragment`s and return one record per
    /// logical code block. Adjacent fragments belonging to the same
    /// `processor.blocks` entry collapse into a single record — that
    /// record's y values anchor at the first fragment.
    func visibleCodeBlocksTK2() -> [VisibleCodeBlockTK2] {
        guard let textView = textView,
              let tlm = textView.textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else {
            return []
        }
        let originY = textView.textContainerOrigin.y
        var result: [VisibleCodeBlockTK2] = []
        var lastSeenBlockStart: Int = -1

        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            // Phase 8 Slice 5: the gutter "copy code" icon should also
            // appear next to mermaid / display-math / LaTeX-math blocks
            // — they're all `Block.codeBlock` underneath; the user
            // wants to copy the source. Mirrors the same filter
            // broadening in `CodeBlockEditToggleOverlay`.
            guard fragment is CodeBlockLayoutFragment
               || fragment is MermaidLayoutFragment
               || fragment is MathLayoutFragment
               || fragment is DisplayMathLayoutFragment
            else { return true }
            guard let element = fragment.textElement,
                  let elementRange = element.elementRange else { return true }

            let charIndex = NSRange(elementRange.location, in: tcs).location
            guard charIndex >= 0, charIndex < storage.length else { return true }

            // Bug #28: skip code blocks inside a folded heading range.
            // The block's content is hidden (`FoldedLayoutFragment`
            // dispatch + clear-foreground), so the gutter copy icon must
            // also disappear. The `.foldedContent` attribute is added
            // by `TextStorageProcessor.toggleFold` over the entire fold
            // range — checking the fragment's first character is enough.
            if storage.attribute(.foldedContent,
                                 at: charIndex,
                                 effectiveRange: nil) != nil {
                return true
            }

            // Look up the processor block whose range contains this
            // fragment's first character. Multi-paragraph code blocks
            // produce multiple fragments that all map to the SAME
            // `processor.blocks` entry — dedupe on `block.range.location`.
            guard let block = processor.blocks.first(where: {
                if case .codeBlock = $0.type {
                    return NSLocationInRange(charIndex, $0.range)
                }
                return false
            }) else { return true }

            if block.range.location == lastSeenBlockStart {
                // Already recorded this block from its first fragment.
                return true
            }
            lastSeenBlockStart = block.range.location

            let frame = fragment.layoutFragmentFrame
            result.append(VisibleCodeBlockTK2(
                firstLineMidY: frame.midY + originY,
                firstLineMinY: frame.minY + originY,
                firstLineMaxY: frame.maxY + originY,
                range: block.range,
                contentRange: block.contentRange
            ))
            return true
        }
        return result
    }

    // MARK: - Table Fragment Discovery (TK2)

    /// Record of a visible table under TK2. Tables are rendered as a
    /// single-character `NSTextAttachment` tagged with
    /// `.renderedBlockType == "table"` and
    /// `.renderedBlockOriginalMarkdown = <markdown>`. Under TK2 each
    /// attachment lives in its own paragraph/fragment; enumerating
    /// fragments and peeking at the attribute on the fragment's first
    /// character is the TK2 equivalent of TK1's `storage.enumerateAttribute`.
    struct VisibleTableTK2 {
        /// Top of the attachment's fragment in view coords. Matches
        /// TK1's `iconTopY = lineFragRect.minY + origin.y` baseline
        /// (`+ 4` padding is applied at the draw site to match TK1).
        let topY: CGFloat
        /// Character range covered by the attachment attribute run
        /// (typically length 1). Used as the stable identity for
        /// "copied" feedback AND as the key off which the raw
        /// markdown attribute is read during click handling.
        let range: NSRange
    }

    /// Enumerate text layout fragments and return one record per table
    /// attachment found in the document. Handlers re-read the original
    /// markdown from storage at `range.location`, so the record stays
    /// small.
    func visibleTablesTK2() -> [VisibleTableTK2] {
        guard let textView = textView,
              let tlm = textView.textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage else {
            return []
        }
        let originY = textView.textContainerOrigin.y
        let tableTypeValue = RenderedBlockType.table.rawValue
        var result: [VisibleTableTK2] = []

        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let element = fragment.textElement,
                  let elementRange = element.elementRange else { return true }

            let charIndex = NSRange(elementRange.location, in: tcs).location
            guard charIndex >= 0, charIndex < storage.length else { return true }

            // Non-table fragments skip in one attribute lookup.
            guard let type = storage.attribute(
                .renderedBlockType, at: charIndex, effectiveRange: nil
            ) as? String, type == tableTypeValue else {
                return true
            }

            // Bug #28: skip tables inside a folded heading range. The
            // table content is hidden (`FoldedLayoutFragment` dispatch),
            // so the gutter copy icon must also disappear. Check the
            // attachment's first character — `.foldedContent` is added
            // over the entire fold range by `toggleFold`.
            if storage.attribute(.foldedContent,
                                 at: charIndex,
                                 effectiveRange: nil) != nil {
                return true
            }

            // Expand to the attribute's effective range so
            // `range.location` matches TK1's `effective.location`.
            var effective = NSRange(location: 0, length: 0)
            _ = storage.attribute(
                .renderedBlockType, at: charIndex, effectiveRange: &effective
            )

            let frame = fragment.layoutFragmentFrame
            result.append(VisibleTableTK2(
                topY: frame.minY + originY,
                range: effective
            ))
            return true
        }
        return result
    }

    // MARK: - TK2 Click Handlers (code block + table copy)

    /// TK2 code-block copy hit test: iterate visible code blocks, find
    /// one whose first-line band contains `clickY`, copy its content
    /// to the pasteboard, and set "copied" feedback.
    func handleCodeBlockCopyTK2(clickY: CGFloat) -> Bool {
        guard let textView = textView,
              let storage = textView.textStorage else { return false }

        for codeBlock in visibleCodeBlocksTK2() {
            guard clickY >= codeBlock.firstLineMinY,
                  clickY <= codeBlock.firstLineMaxY else { continue }

            let maxLen = storage.length
            let loc = min(codeBlock.contentRange.location, maxLen)
            let len = min(codeBlock.contentRange.length, maxLen - loc)
            let safeRange = NSRange(location: loc, length: len)
            let codeText = (storage.string as NSString).substring(with: safeRange)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeText, forType: .string)

            copiedCodeBlockLocation = codeBlock.range.location
            textView.needsDisplay = true
            copiedFeedbackTimer?.invalidate()
            copiedFeedbackTimer = Timer.scheduledTimer(
                withTimeInterval: 1.5, repeats: false
            ) { [weak self] _ in
                self?.copiedCodeBlockLocation = nil
                self?.textView?.needsDisplay = true
            }
            return true
        }
        return false
    }

    /// TK2 table copy hit test: iterate visible tables, find one whose
    /// top-anchor band contains `clickY`, copy its markdown to the
    /// pasteboard as TSV + HTML, and set "copied" feedback.
    func handleTableCopyTK2(clickY: CGFloat) -> Bool {
        guard let textView = textView,
              let storage = textView.textStorage else { return false }

        for table in visibleTablesTK2() {
            // ~30-pixel tall hitbox around the icon, matching the TK1
            // contract in `handleTableCopy`.
            guard clickY >= table.topY - 4,
                  clickY <= table.topY + 30 else { continue }

            guard table.range.location < storage.length,
                  let markdown = storage.attribute(
                    .renderedBlockOriginalMarkdown,
                    at: table.range.location,
                    effectiveRange: nil
                  ) as? String,
                  let data = TableUtility.parse(markdown: markdown) else {
                continue
            }

            // Build TSV
            var tsvLines: [String] = [data.headers.joined(separator: "\t")]
            for row in data.rows { tsvLines.append(row.joined(separator: "\t")) }
            let tsv = tsvLines.joined(separator: "\n")

            // Build HTML
            func escape(_ s: String) -> String {
                return s.replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
            }
            var html = "<table>"
            html += "<thead><tr>" + data.headers.map {
                "<th>" + escape($0) + "</th>"
            }.joined() + "</tr></thead>"
            html += "<tbody>"
            for row in data.rows {
                html += "<tr>" + row.map {
                    "<td>" + escape($0) + "</td>"
                }.joined() + "</tr>"
            }
            html += "</tbody></table>"

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tsv, forType: .string)
            NSPasteboard.general.setString(
                tsv,
                forType: NSPasteboard.PasteboardType(
                    rawValue: "public.utf8-tab-separated-values-text"
                )
            )
            NSPasteboard.general.setString(html, forType: .html)

            copiedTableLocation = table.range.location
            textView.needsDisplay = true
            copiedFeedbackTimer?.invalidate()
            copiedFeedbackTimer = Timer.scheduledTimer(
                withTimeInterval: 1.5, repeats: false
            ) { [weak self] _ in
                self?.copiedTableLocation = nil
                self?.textView?.needsDisplay = true
            }
            return true
        }
        return false
    }

    /// Given a y-coordinate in the text view's coordinate space (i.e.
    /// `textView.convert(event.locationInWindow, from: nil).y`), return
    /// the `processor.blocks` index of the heading whose vertical band
    /// contains that y, or `nil` if no heading matches. Used by the TK2
    /// `handleClick` path since TK2 has no equivalent to TK1's
    /// `characterIndex(for:in:)` for points outside the text container.
    func headerBlockIndexForClickYTK2(clickY: CGFloat) -> Int? {
        guard let textView = textView,
              let processor = textView.textStorageProcessor else { return nil }

        for heading in visibleHeadingsTK2() {
            if clickY >= heading.minY && clickY <= heading.maxY {
                if let idx = processor.headerBlockIndex(at: heading.charIndex) {
                    return idx
                }
            }
        }
        return nil
    }

    // Phase 4.5: TK1 `handleCodeBlockCopy` / `handleTableCopy` deleted —
    // both relied on `NSLayoutManager.characterIndex(for:in:)`. The TK2
    // siblings (`handleCodeBlockCopyTK2`, `handleTableCopyTK2`) cover
    // the same UX and are dispatched from `handleClick`.
}
