//
//  EditorSnapshot.swift
//  FSNotesTests
//
//  Live-state structural snapshot of an EditTextView, emitted as a
//  canonical S-expression. Designed for widget-layer regression tests
//  where the bug lives in the overlay / fragment / subview mounting
//  glue — the layer the ~1,640 pure-function tests do not cover.
//
//  The snapshot captures facts a pure Document cannot express:
//
//    - TK2 fragment class + count per block (walks the layout manager)
//    - Storage span per block (from DocumentProjection.blockSpans)
//    - Selection (editor.selectedRange)
//    - Overlay subview tree — NSViews whose class name matches a known
//      overlay marker (CodeBlockEditToggleView, etc.)
//    - Attachment-host subview tree — BulletGlyphView / CheckboxGlyphView
//      / InlineImageView / InlinePDFView / InlineQuickLookView
//    - Attachment geometry for inline-math placeholders (bounds.y
//      rounded to 0.5pt)
//
//  Explicitly out of scope: exact pixel coordinates (frames are rounded
//  to ints and marked with `≈`), colors, font weights, typing
//  attributes, pointer identity.
//
//  Equivalence rules for matching:
//
//    - `frame=x,y,w,h` means exact; `frame≈x,y,w,h` allows ±1pt per
//      coord
//    - `*` in the expected fragment is a wildcard
//    - whitespace is normalised (runs of spaces collapsed, trailing
//      whitespace stripped per line)
//
//  Selector language (path from root):
//
//    - `block[i]`                       → i-th block's form
//    - `block[i]/cell[r,c]`             → cell r,c of i-th table block
//                                         (row=-1 means header)
//    - `block[i]/overlay[Class]`        → first overlay matching Class
//    - `block[i]/fragment`              → fragment dump
//    - `block[i]/attachment-host[Cls]`  → first host subview for Cls
//

import AppKit
import XCTest
@testable import FSNotes

// MARK: - Public API

/// Immutable structural snapshot of an `EditTextView`.
///
/// See file header for emission format, equivalence rules, and
/// selector language. Typical call cost: ~50–100ms — reserve for
/// widget-layer tests, not every pipeline primitive.
public struct EditorSnapshot: CustomStringConvertible {

    /// The full S-expression.
    public let raw: String

    public var description: String { raw }

    /// Emit a snapshot from the given editor. Reads the document
    /// projection, text layout manager, selection, and subview tree
    /// in one pass. Safe to call on offscreen editors — when a view
    /// is not yet laid out the frame fields report `0,0,0,0`.
    public static func emit(from editor: EditTextView) -> EditorSnapshot {
        let builder = EditorSnapshotBuilder(editor: editor)
        return EditorSnapshot(raw: builder.build())
    }

    /// Returns true if `fragment` (a sub-string of an expected
    /// S-expression) appears in `raw` under the equivalence rules
    /// (whitespace, `frame≈`, `*` wildcards).
    public func contains(_ fragment: String) -> Bool {
        return SnapshotMatcher.contains(
            raw: raw, fragment: fragment
        )
    }

    /// XCTest-style matcher. Emits a readable failure message
    /// including the full snapshot when the fragment is not found.
    public func assertContains(
        _ fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if !contains(fragment) {
            XCTFail(
                "EditorSnapshot did not contain expected fragment.\n" +
                "expected:\n\(fragment)\n\n" +
                "actual snapshot:\n\(raw)",
                file: file, line: line
            )
        }
    }

    /// Asserts that the editor's selection falls inside the storage
    /// span of the block (or table cell) identified by `path`.
    /// Supports `block[i]` and `block[i]/cell[r,c]`.
    public func assertSelectionInside(
        _ path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let (selLoc, selLen) = SnapshotMatcher.parseSelection(raw: raw) else {
            XCTFail(
                "EditorSnapshot has no selection field.\n\(raw)",
                file: file, line: line
            )
            return
        }
        guard let span = SnapshotMatcher.spanForPath(raw: raw, path: path) else {
            XCTFail(
                "EditorSnapshot path not found: \(path)\n\(raw)",
                file: file, line: line
            )
            return
        }
        let selEnd = selLoc + selLen
        let spanEnd = span.location + span.length
        if selLoc < span.location || selEnd > spanEnd {
            XCTFail(
                "Selection \(selLoc)..\(selEnd) is not inside " +
                "\(path) span \(span.location)..\(spanEnd).\n\(raw)",
                file: file, line: line
            )
        }
    }

    /// Returns the form (S-expr sub-string) that matches `path`, or
    /// nil if the path does not resolve. Intended for tests that
    /// want to assert on a specific field of the located form.
    public func select(path: String) -> String? {
        return SnapshotMatcher.formForPath(raw: raw, path: path)
    }
}

// MARK: - Harness extension
//
// Opt-in live-state dump. This method lives here (not in
// EditorHarness.swift) because the harness file is being edited
// by a sibling agent; adding a method from a different file avoids
// a merge conflict while giving tests the ergonomic call site.

extension EditorHarness {

    /// Emit an `EditorSnapshot` from the harness's current editor
    /// state. Opt-in — call only in widget-layer tests. Typical
    /// cost: ~50–100ms.
    public func snapshot() -> EditorSnapshot {
        return EditorSnapshot.emit(from: editor)
    }

    /// Render a single layout fragment into an RGBA8 bitmap by
    /// calling `fragment.draw(at:in:)` directly on a CGContext.
    /// Returns the pixel buffer + row-stride so tests can inspect
    /// specific pixel values.
    ///
    /// This bypasses `cacheDisplay`'s limitation (per CLAUDE.md it
    /// doesn't capture fragment-level draws), letting tests detect
    /// draw-layer bugs like:
    ///   - `<kbd>` missing rounded rectangle (kbd fragment)
    ///   - `[...]` folded indicator missing (heading fragment)
    ///   - HR line not drawn (hr fragment)
    ///   - Dark-mode checkbox invisible (bullet fragment)
    ///
    /// Returns nil if no fragment of the given class exists.
    public func renderFragmentToBitmap(
        blockIndex: Int,
        fragmentClass: String,
        padding: CGFloat = 4.0
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let tlm = editor.textLayoutManager,
              let contentStorage = tlm.textContentManager
                as? NSTextContentStorage
        else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        var targetFragment: NSTextLayoutFragment? = nil
        let docStart = contentStorage.documentRange.location
        let spans: [NSRange] = editor.documentProjection?.blockSpans
            ?? []
        guard blockIndex >= 0, blockIndex < spans.count else {
            return nil
        }
        let targetSpan = spans[blockIndex]
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let elementRange = fragment.textElement?.elementRange else {
                return true
            }
            let charIndex = contentStorage.offset(
                from: docStart, to: elementRange.location
            )
            let cls = String(describing: Swift.type(of: fragment))
            if cls == fragmentClass &&
                NSLocationInRange(charIndex, targetSpan) {
                targetFragment = fragment
                return false
            }
            return true
        }
        guard let fragment = targetFragment else { return nil }

        let frame = fragment.layoutFragmentFrame
        let w = Int(frame.width.rounded() + 2 * padding)
        let h = Int(frame.height.rounded() + 2 * padding)
        guard w > 0, h > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = pixels.withUnsafeMutableBytes({ buf -> CGContext? in
            guard let base = buf.baseAddress else { return nil }
            return CGContext(
                data: base, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }

        // Fill with a distinctive background so "nothing drawn"
        // stays recognisable (white with alpha=255).
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Push the NSGraphicsContext so AppKit draws (NSColor.set,
        // textLineFragment.locationForCharacter) resolve properly.
        let nsCtx = NSGraphicsContext(
            cgContext: ctx, flipped: false
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        fragment.draw(
            at: CGPoint(x: padding, y: padding),
            in: ctx
        )
        return (pixels, w, h)
    }
}

// MARK: - Builder

/// Internal builder that walks the editor + projection + layout
/// manager + subview tree and emits the canonical S-expression.
private struct EditorSnapshotBuilder {

    let editor: EditTextView

    /// Class names recognised as overlay subviews. Matched against
    /// `String(describing: type(of: view))` — no instanceof check
    /// (would require making these classes internal-visible to the
    /// test target).
    private static let overlayClassNames: Set<String> = [
        "CodeBlockEditToggleView",
    ]

    /// Class names recognised as attachment-host subviews. These
    /// are the view-provider-backed NSViews TK2 mounts under the
    /// text view when attachments hydrate.
    private static let attachmentHostClassNames: Set<String> = [
        "BulletGlyphView",
        "CheckboxGlyphView",
        "InlineImageView",
        "InlinePDFView",
        "InlineQuickLookView",
    ]

    func build() -> String {
        var out = ""
        let storage = editor.textStorage
        let length = storage?.length ?? 0
        let sel = editor.selectedRange()

        out += "(editor len=\(length) selection=\(sel.location)..\(sel.location + sel.length)"

        guard let projection = editor.documentProjection else {
            out += ")\n"
            return out
        }

        // Group overlay + attachment-host subviews by containing
        // block. "Containing" == the subview's frame.minY falls
        // inside the block's fragment y-range. We compute per-block
        // fragment-y bounds from the TK2 layout manager.
        let spans = projection.blockSpans
        let blocks = projection.document.blocks
        let fragmentMap = collectFragmentDispatch(spans: spans)
        let blockYRanges = collectBlockYRanges(spans: spans)
        let (overlayBuckets, attachmentBuckets) = bucketSubviews(
            blockYRanges: blockYRanges,
            blockCount: blocks.count
        )

        for (idx, block) in blocks.enumerated() {
            guard idx < spans.count else { break }
            let span = spans[idx]
            out += "\n  (block \(idx) kind=\(kindString(block)) span=\(span.location)..\(span.location + span.length)"

            // Optional per-kind metadata.
            if case let .codeBlock(language, _, _) = block,
               let lang = language, !lang.isEmpty {
                out += " language=\(lang)"
            }
            if case let .heading(level, _) = block {
                out += " level=\(level)"
            }

            // Inline tree (for paragraphs + headings).
            if let inlines = inlines(for: block) {
                out += "\n    (inline "
                out += inlineForm(inlines)
                out += ")"
            }

            // Fragment dispatch + geometry.
            if let frag = fragmentMap[idx] {
                let h = Int(frag.height.rounded())
                out += "\n    (fragment class=\(frag.className)" +
                    " count=\(frag.count)" +
                    " h=\(h)" +
                    " lines=\(frag.lineCount))"
            }

            // Table structure.
            if case let .table(header, _, rows, _) = block {
                out += "\n    (table cols=\(header.count) rows=\(rows.count)"
                for (c, cell) in header.enumerated() {
                    out += "\n      (cell r=-1 c=\(c) (text \(cellText(cell))))"
                }
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        out += "\n      (cell r=\(r) c=\(c) (text \(cellText(cell))))"
                    }
                }
                out += ")"
            }

            // Attachment geometry for inline-math placeholders.
            let mathAttachments = collectInlineMathAttachments(blockIndex: idx, span: span)
            for m in mathAttachments {
                out += "\n    (attachment kind=inlineMath bounds.y=\(formatHalfPoint(m.y)))"
            }

            // Overlay subviews assigned to this block.
            for overlay in overlayBuckets[idx] ?? [] {
                out += "\n    (overlay class=\(overlay.className) visible=\(overlay.visible) frame≈\(intFrame(overlay.frame)))"
            }

            // Attachment-host subviews assigned to this block.
            for host in attachmentBuckets[idx] ?? [] {
                out += "\n    (attachment-host class=\(host.className) visible=\(host.visible) frame≈\(intFrame(host.frame)))"
            }

            out += ")"
        }

        out += ")\n"
        return out
    }

    // MARK: Block metadata

    private func kindString(_ block: Block) -> String {
        switch block {
        case .paragraph:       return "paragraph"
        case .heading:         return "heading"
        case .codeBlock:       return "codeBlock"
        case .list:            return "list"
        case .blockquote:      return "blockquote"
        case .horizontalRule:  return "horizontalRule"
        case .htmlBlock:       return "htmlBlock"
        case .table:           return "table"
        case .blankLine:       return "blankLine"
        }
    }

    private func inlines(for block: Block) -> [Inline]? {
        switch block {
        case .paragraph(let inl):                 return inl
        case .heading:                            return nil
        default:                                  return nil
        }
    }

    private func inlineForm(_ inlines: [Inline]) -> String {
        return inlines.map(oneInlineForm).joined(separator: " ")
    }

    private func oneInlineForm(_ inline: Inline) -> String {
        switch inline {
        case .text(let s):                           return "(text \(quote(s)))"
        case .bold(let c, _):                        return "(bold \(inlineForm(c)))"
        case .italic(let c, _):                      return "(italic \(inlineForm(c)))"
        case .strikethrough(let c):                  return "(strike \(inlineForm(c)))"
        case .code(let s):                           return "(code \(quote(s)))"
        case .link(let t, let url):                  return "(link \(quote(url)) \(inlineForm(t)))"
        case .image(_, let url, _):                  return "(image \(quote(url)))"
        case .autolink(let t, _):                    return "(autolink \(quote(t)))"
        case .escapedChar(let ch):                   return "(escape \(quote(String(ch))))"
        case .lineBreak:                             return "(hardbreak)"
        case .rawHTML(let s):                        return "(html \(quote(s)))"
        case .entity(let s):                         return "(entity \(quote(s)))"
        case .underline(let c):                      return "(underline \(inlineForm(c)))"
        case .highlight(let c):                      return "(highlight \(inlineForm(c)))"
        case .superscript(let c):                    return "(sup \(inlineForm(c)))"
        case .subscript(let c):                      return "(sub \(inlineForm(c)))"
        case .kbd(let c):                            return "(kbd \(inlineForm(c)))"
        case .math(let s):                           return "(math \(quote(s)))"
        case .displayMath(let s):                    return "(displayMath \(quote(s)))"
        case .wikilink(let target, let display):
            if let d = display {
                return "(wikilink \(quote(target)) \(quote(d)))"
            }
            return "(wikilink \(quote(target)))"
        }
    }

    private func cellText(_ cell: TableCell) -> String {
        let plain = cell.inline.map { inl -> String in
            if case let .text(s) = inl { return s }
            return ""
        }.joined()
        return quote(plain)
    }

    private func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\":  out += "\\\\"
            case "\"":  out += "\\\""
            case "\n":  out += "\\n"
            case "\t":  out += "\\t"
            default:    out.append(ch)
            }
        }
        out += "\""
        return out
    }

    // MARK: Fragment dispatch

    private struct FragmentSummary {
        let className: String
        let count: Int
        /// Bounding-box height of the fragment (first fragment for
        /// the block). Zero-height fragments mean the fragment
        /// isn't drawing anything, which is a common class of bug
        /// (HR without a line, kbd box not painted, folded indicator
        /// missing).
        let height: CGFloat
        /// Number of text line fragments in the fragment. Most
        /// block fragments have 1; wrapped paragraphs / code blocks
        /// have N. A kbd run that straddles a line break needs >1.
        let lineCount: Int
    }

    /// Walk the layout manager's fragments and bucket them by
    /// containing block. Returns the dominant fragment class per
    /// block and the count of fragments in that block.
    private func collectFragmentDispatch(spans: [NSRange]) -> [Int: FragmentSummary] {
        guard let tlm = editor.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else {
            return [:]
        }
        let docStart = contentStorage.documentRange.location

        // Ensure the whole document is laid out so we see every
        // fragment — offscreen editors often leave tails unlaid.
        tlm.ensureLayout(for: tlm.documentRange)

        // (blockIndex -> [(className, height, lineCount)]).
        var buckets: [Int: [(cls: String, h: CGFloat, lines: Int)]] = [:]
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let elementRange = fragment.textElement?.elementRange else {
                return true
            }
            let charIndex = contentStorage.offset(
                from: docStart, to: elementRange.location
            )
            let blockIdx = spans.firstIndex { span in
                NSLocationInRange(charIndex, span) ||
                    span.location == charIndex
            } ?? -1
            guard blockIdx >= 0 else { return true }
            let cls = String(describing: Swift.type(of: fragment))
            let h = fragment.layoutFragmentFrame.height
            let lines = fragment.textLineFragments.count
            buckets[blockIdx, default: []].append((cls, h, lines))
            return true
        }

        var out: [Int: FragmentSummary] = [:]
        for (idx, entries) in buckets {
            // Pick the class that appears most often. Table /
            // CodeBlock / Heading fragments are one-per-block, so
            // this degenerates to "the only class present".
            var counts: [String: Int] = [:]
            for e in entries { counts[e.cls, default: 0] += 1 }
            if let dominant = counts.max(by: { $0.value < $1.value }) {
                // Geometry: use the first entry matching the dominant
                // class.
                let firstMatch = entries.first { $0.cls == dominant.key }
                out[idx] = FragmentSummary(
                    className: dominant.key,
                    count: entries.count,
                    height: firstMatch?.h ?? 0,
                    lineCount: firstMatch?.lines ?? 0
                )
            }
        }
        return out
    }

    /// Per-block y-range in the text view's coordinate space.
    /// Used to bucket overlay + attachment-host subviews under the
    /// block whose vertical range contains the subview's minY.
    private func collectBlockYRanges(spans: [NSRange]) -> [Int: ClosedRange<CGFloat>] {
        guard let tlm = editor.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else {
            return [:]
        }
        let docStart = contentStorage.documentRange.location
        let origin = editor.textContainerOrigin

        tlm.ensureLayout(for: tlm.documentRange)

        var mins: [Int: CGFloat] = [:]
        var maxs: [Int: CGFloat] = [:]
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let elementRange = fragment.textElement?.elementRange else {
                return true
            }
            let charIndex = contentStorage.offset(
                from: docStart, to: elementRange.location
            )
            let blockIdx = spans.firstIndex { span in
                NSLocationInRange(charIndex, span) ||
                    span.location == charIndex
            } ?? -1
            guard blockIdx >= 0 else { return true }
            let frame = fragment.layoutFragmentFrame
            let minY = frame.origin.y + origin.y
            let maxY = minY + frame.height
            mins[blockIdx] = min(mins[blockIdx] ?? .infinity, minY)
            maxs[blockIdx] = max(maxs[blockIdx] ?? -.infinity, maxY)
            return true
        }

        var out: [Int: ClosedRange<CGFloat>] = [:]
        for (idx, lo) in mins {
            if let hi = maxs[idx], hi >= lo {
                out[idx] = lo...hi
            }
        }
        return out
    }

    // MARK: Subview collection

    private struct ObservedSubview {
        let className: String
        let visible: Bool
        let frame: CGRect
    }

    private func bucketSubviews(
        blockYRanges: [Int: ClosedRange<CGFloat>],
        blockCount: Int
    ) -> (
        overlays: [Int: [ObservedSubview]],
        attachments: [Int: [ObservedSubview]]
    ) {
        var overlays: [Int: [ObservedSubview]] = [:]
        var attachments: [Int: [ObservedSubview]] = [:]

        // Recurse through the full editor view hierarchy. Overlay
        // controllers such as `CodeBlockEditToggleOverlay` add their
        // subviews directly to `editor.subviews`, so those sit at
        // depth 1. TK2's view-provider-hosted views (BulletGlyphView,
        // CheckboxGlyphView, InlineImageView, InlinePDFView,
        // InlineQuickLookView) are mounted by `NSTextViewportLayoutController`
        // as subviews of `_NSTextContentView` → `_NSTextViewportElementView`
        // — a depth of 3 or 4 under the text view. A shallow one-level
        // walk misses them entirely, which is the walker bug behind
        // Bug #6 in UIBugRegressionTests.
        var visited = Set<ObjectIdentifier>()
        var queue: [NSView] = editor.subviews
        while let v = queue.first {
            queue.removeFirst()
            let key = ObjectIdentifier(v)
            if visited.contains(key) { continue }
            visited.insert(key)
            queue.append(contentsOf: v.subviews)

            let cls = String(describing: type(of: v))
            let isOverlay = Self.overlayClassNames.contains(cls)
            let isAttachmentHost = Self.attachmentHostClassNames.contains(cls)
            guard isOverlay || isAttachmentHost else { continue }

            // Convert frame to the editor's coordinate space so
            // `blockIndex(forY:)` compares against fragment y-ranges
            // emitted in editor coords.
            let frameInEditor = v.superview?.convert(v.frame, to: editor)
                ?? v.frame

            let observation = ObservedSubview(
                className: cls,
                visible: !v.isHidden,
                frame: frameInEditor
            )
            let blockIdx = blockIndex(
                forY: frameInEditor.minY,
                blockYRanges: blockYRanges,
                blockCount: blockCount
            )
            if isOverlay {
                overlays[blockIdx, default: []].append(observation)
            } else {
                attachments[blockIdx, default: []].append(observation)
            }
        }

        // Sort each bucket so emission order is deterministic.
        let sortFn: (ObservedSubview, ObservedSubview) -> Bool = { a, b in
            if a.className != b.className { return a.className < b.className }
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
        for k in overlays.keys { overlays[k]?.sort(by: sortFn) }
        for k in attachments.keys { attachments[k]?.sort(by: sortFn) }

        return (overlays, attachments)
    }

    private func blockIndex(
        forY y: CGFloat,
        blockYRanges: [Int: ClosedRange<CGFloat>],
        blockCount: Int
    ) -> Int {
        // Try direct containment first.
        for idx in 0..<blockCount {
            if let range = blockYRanges[idx], range.contains(y) {
                return idx
            }
        }
        // Fallback: nearest block by midpoint distance. Prevents
        // "nothing resolved because layout rounded the frame by
        // 0.01pt" silent failures.
        var best: (idx: Int, d: CGFloat) = (0, .infinity)
        for idx in 0..<blockCount {
            guard let range = blockYRanges[idx] else { continue }
            let mid = (range.lowerBound + range.upperBound) / 2
            let d = abs(mid - y)
            if d < best.d { best = (idx, d) }
        }
        return best.idx
    }

    // MARK: Attachment geometry (inline math)

    private struct ObservedMathAttachment {
        let y: CGFloat
    }

    private func collectInlineMathAttachments(
        blockIndex: Int, span: NSRange
    ) -> [ObservedMathAttachment] {
        guard let storage = editor.textStorage else { return [] }
        let clampedLen = min(span.length, storage.length - span.location)
        guard clampedLen > 0 else { return [] }
        let fullRange = NSRange(location: span.location, length: clampedLen)
        var out: [ObservedMathAttachment] = []
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, attrRange, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            // Heuristic: the .inlineMathSource attribute marks inline
            // math runs. If the attribute's range contains an
            // attachment, attribute it to "inline math".
            let mathSource = storage.attribute(
                .inlineMathSource, at: attrRange.location, effectiveRange: nil
            )
            if mathSource == nil {
                // Secondary heuristic: .renderedBlockType == math.
                let blockType = storage.attribute(
                    .renderedBlockType, at: attrRange.location, effectiveRange: nil
                )
                guard let raw = blockType as? String,
                      raw == RenderedBlockType.math.rawValue else {
                    return
                }
            }
            out.append(ObservedMathAttachment(y: attachment.bounds.origin.y))
        }
        return out
    }

    // MARK: Formatters

    private func intFrame(_ r: CGRect) -> String {
        return "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.size.width.rounded())),\(Int(r.size.height.rounded()))"
    }

    private func formatHalfPoint(_ v: CGFloat) -> String {
        // Round to nearest 0.5pt; emit with one decimal when non-zero.
        let rounded = (v * 2).rounded() / 2
        if rounded == rounded.rounded() {
            return String(format: "%.1f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - Matcher

/// Static matching helpers shared by `EditorSnapshot.contains` and
/// `EditorSnapshot.assertContains`.
enum SnapshotMatcher {

    /// Whitespace-normalise: collapse runs of spaces/tabs, strip
    /// trailing whitespace per line. Line breaks are preserved.
    static func normalise(_ s: String) -> String {
        var out = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var squished = ""
            var lastWasSpace = false
            for ch in line {
                if ch == " " || ch == "\t" {
                    if !lastWasSpace { squished.append(" ") }
                    lastWasSpace = true
                } else {
                    squished.append(ch)
                    lastWasSpace = false
                }
            }
            // Strip trailing whitespace.
            while squished.last == " " { squished.removeLast() }
            // Strip leading whitespace (so indentation in expected
            // fragments is irrelevant — what matters is tokens).
            while squished.first == " " { squished.removeFirst() }
            if !out.isEmpty { out.append("\n") }
            out.append(squished)
        }
        return out
    }

    /// Equivalence-aware contains. `fragment` may contain `*`
    /// wildcards; `frame≈x,y,w,h` tolerates ±1pt per coord against
    /// a matching `frame≈` in `raw`.
    static func contains(raw: String, fragment: String) -> Bool {
        let normRaw = normalise(raw)
        let normFrag = normalise(fragment)

        // Cheap fast-path: literal substring match after
        // normalisation. Works when the fragment has no `*` or
        // `frame≈` tolerance.
        if !normFrag.contains("*") &&
           !containsFrameApprox(normFrag) &&
           normRaw.contains(normFrag) {
            return true
        }

        // Slow-path: regex match with wildcards + frame tolerance.
        let pattern = buildRegexPattern(fragment: normFrag)
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(location: 0, length: (normRaw as NSString).length)
        return regex.firstMatch(in: normRaw, options: [], range: range) != nil
    }

    private static func containsFrameApprox(_ s: String) -> Bool {
        return s.contains("frame≈")
    }

    /// Build a regex from the normalised fragment:
    ///   - `*`           → `[^ \n)]*`  (whole token)
    ///   - `frame≈x,y,w,h` → `frame≈(x±1),(y±1),(w±1),(h±1)`
    ///   - all other characters escaped
    private static func buildRegexPattern(fragment: String) -> String {
        var out = ""
        var i = fragment.startIndex
        while i < fragment.endIndex {
            let remainder = fragment[i...]
            if remainder.hasPrefix("frame≈"), let end = matchFrameApprox(remainder) {
                let expr = String(remainder[remainder.startIndex..<end])
                out.append(framePatternFor(expr))
                i = end
                continue
            }
            let ch = fragment[i]
            if ch == "*" {
                out.append("[^ )\\n]*")
            } else {
                out.append(NSRegularExpression.escapedPattern(for: String(ch)))
            }
            i = fragment.index(after: i)
        }
        return out
    }

    /// Find the end of a `frame≈x,y,w,h` token starting at the
    /// beginning of `s`. Returns nil if the token is malformed.
    private static func matchFrameApprox(_ s: Substring) -> String.Index? {
        let pattern = #"^frame≈[^ \n\)]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(
                in: String(s), options: [],
                range: NSRange(location: 0, length: (String(s) as NSString).length)
              )
        else {
            return nil
        }
        let ns = String(s) as NSString
        let matched = ns.substring(with: m.range)
        return s.index(s.startIndex, offsetBy: matched.count)
    }

    /// Expand `frame≈x,y,w,h` into a regex with ±1 tolerance per
    /// coordinate. `*` in any slot becomes the wildcard `-?\d+`.
    private static func framePatternFor(_ token: String) -> String {
        // Strip the "frame≈" prefix.
        let prefix = "frame≈"
        guard token.hasPrefix(prefix) else { return NSRegularExpression.escapedPattern(for: token) }
        let body = String(token.dropFirst(prefix.count))
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return NSRegularExpression.escapedPattern(for: token)
        }

        func slot(_ p: Substring) -> String {
            let raw = String(p)
            if raw == "*" {
                return "-?\\d+"
            }
            guard let n = Int(raw) else {
                return NSRegularExpression.escapedPattern(for: raw)
            }
            // Exact-match set {n-1, n, n+1}.
            return "(?:\(n - 1)|\(n)|\(n + 1))"
        }

        return "frame≈" + parts.map(slot).joined(separator: ",")
    }

    // MARK: Selection + path resolution

    /// Extract `(loc, len)` from `selection=L..L+N` at the top of
    /// the form. Returns nil if the selection field is missing.
    static func parseSelection(raw: String) -> (Int, Int)? {
        let pattern = #"selection=(\d+)\.\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(
                in: raw, options: [],
                range: NSRange(location: 0, length: (raw as NSString).length)
              ),
              m.numberOfRanges >= 3
        else {
            return nil
        }
        let ns = raw as NSString
        let lo = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let hi = Int(ns.substring(with: m.range(at: 2))) ?? 0
        return (lo, max(0, hi - lo))
    }

    /// Find the span for a given `path`. Supports `block[i]` and
    /// `block[i]/cell[r,c]`. Returns nil if unresolved.
    static func spanForPath(raw: String, path: String) -> NSRange? {
        if let (blockIdx, cellLocator) = parsePath(path) {
            return spanForBlock(raw: raw, blockIdx: blockIdx, cellLocator: cellLocator)
        }
        return nil
    }

    /// Returns the S-expression form for a `path` — the full
    /// `(block i ...)` or `(cell r=... c=... ...)` sub-string — or
    /// nil if unresolved. Intended for tests that want to match
    /// specific field values off the located form.
    static func formForPath(raw: String, path: String) -> String? {
        guard let (blockIdx, cellLocator) = parsePath(path) else {
            return nil
        }
        guard let blockRange = blockFormRange(raw: raw, blockIdx: blockIdx) else {
            return nil
        }
        let blockSegment = (raw as NSString).substring(with: blockRange)
        guard let (row, col) = cellLocator else { return blockSegment }
        let cellPattern = #"\(cell r=\#(row) c=\#(col)[^\(\)]*(?:\([^\(\)]*\)[^\(\)]*)*\)"#
        guard let regex = try? NSRegularExpression(pattern: cellPattern),
              let m = regex.firstMatch(
                in: blockSegment, options: [],
                range: NSRange(location: 0, length: (blockSegment as NSString).length)
              )
        else {
            return nil
        }
        return (blockSegment as NSString).substring(with: m.range)
    }

    /// Parse `block[i]` or `block[i]/cell[r,c]`. Returns nil on
    /// malformed input.
    private static func parsePath(_ path: String) -> (Int, (Int, Int)?)? {
        let blockPattern = #"^block\[(\d+)\](?:/cell\[(-?\d+),(\d+)\])?$"#
        guard let regex = try? NSRegularExpression(pattern: blockPattern),
              let m = regex.firstMatch(
                in: path, options: [],
                range: NSRange(location: 0, length: (path as NSString).length)
              )
        else {
            return nil
        }
        let ns = path as NSString
        guard let blockIdx = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        let cellLocator: (Int, Int)?
        if m.numberOfRanges >= 4, m.range(at: 2).location != NSNotFound {
            let r = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let c = Int(ns.substring(with: m.range(at: 3))) ?? 0
            cellLocator = (r, c)
        } else {
            cellLocator = nil
        }
        return (blockIdx, cellLocator)
    }

    /// Locate the `(block I ...)` form for a given index in `raw`.
    /// Returns the NSRange spanning the entire form (parens-balanced).
    private static func blockFormRange(raw: String, blockIdx: Int) -> NSRange? {
        let header = "(block \(blockIdx) "
        let ns = raw as NSString
        let start = ns.range(of: header)
        guard start.location != NSNotFound else { return nil }
        // Walk forward from `start.location + 1` counting parens
        // until we return to depth 0.
        var depth = 0
        var i = start.location
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 0x28 { depth += 1 }         // '('
            else if ch == 0x29 {                  // ')'
                depth -= 1
                if depth == 0 {
                    return NSRange(location: start.location, length: i - start.location + 1)
                }
            }
            i += 1
        }
        return nil
    }

    private static func spanForBlock(
        raw: String, blockIdx: Int, cellLocator: (Int, Int)?
    ) -> NSRange? {
        guard let blockRange = blockFormRange(raw: raw, blockIdx: blockIdx) else {
            return nil
        }
        let segment = (raw as NSString).substring(with: blockRange)
        let pattern = #"span=(\d+)\.\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(
                in: segment, options: [],
                range: NSRange(location: 0, length: (segment as NSString).length)
              ),
              m.numberOfRanges >= 3
        else {
            return nil
        }
        let ns = segment as NSString
        let lo = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let hi = Int(ns.substring(with: m.range(at: 2))) ?? lo
        // Cell-level path not supported for span resolution here —
        // tables carry cell text inside storage as flat separator-
        // encoded runs, which is not exposed as a per-cell NSRange
        // on the snapshot. Callers that pass `.../cell[r,c]` get
        // back the containing block's span (the selection must
        // still fall inside the block).
        _ = cellLocator
        return NSRange(location: lo, length: max(0, hi - lo))
    }
}
