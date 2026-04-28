//
//  FoldSnapshotTests.swift
//  FSNotesTests
//
//  Pixel-level snapshot tests for fold/unfold rendering.
//  Renders markdown into an off-screen NSTextView, captures a bitmap,
//  and verifies folded content is NOT visible in the image.
//

import XCTest
@testable import FSNotes

/// Phase 4.5: TK1 `LayoutManager` subclass deleted. These pixel-level
/// snapshot tests exercised the TK1 `LayoutManager.drawBackground`
/// fold-gate + custom drawing helpers, none of which exist anymore —
/// TK2 folding rides `SourceLayoutFragment` / `FoldedElement`. The
/// class is retained as a skipped placeholder so the test bundle
/// keeps compiling; a TK2 snapshot suite is a later slice.
class FoldSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        throw XCTSkip("Phase 4.5: TK1 LayoutManager drawing deleted; TK2 snapshot suite pending.")
    }

    private let renderSize = NSSize(width: 600, height: 400)

    private func describeType(_ type: MarkdownBlockType) -> String {
        switch type {
        case .heading(let l): return "h\(l)"
        case .headingSetext(let l): return "setext\(l)"
        case .paragraph: return "p"
        case .codeBlock: return "code"
        case .blockquote: return "bq"
        case .unorderedList: return "ul"
        case .orderedList: return "ol"
        case .todoItem: return "todo"
        case .horizontalRule: return "hr"
        case .table: return "table"
        case .yamlFrontmatter: return "yaml"
        case .empty: return "empty"
        }
    }

    /// Phase 4.5 stub — the real harness wired a TK1 LayoutManager
    /// subclass that no longer exists. Every test in this file is
    /// skipped via `setUpWithError`, so this stub just returns a bare
    /// EditTextView to keep the file compiling.
    private func makeEditor(markdown: String) -> EditTextView {
        _ = markdown
        return EditTextView(frame: NSRect(origin: .zero, size: renderSize))
    }

    /// Capture the editor's rendered content as a bitmap.
    private func captureSnapshot(_ textView: EditTextView) -> NSBitmapImageRep? {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.needsDisplay = true
        textView.display()
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return nil }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        return rep
    }

    /// Check if a specific region of the bitmap contains any non-background pixels.
    /// Returns true if the region has visible content (not all white/transparent).
    private func regionHasVisibleContent(_ rep: NSBitmapImageRep, inRect rect: NSRect) -> Bool {
        let minX = max(0, Int(rect.minX))
        let maxX = min(rep.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(rep.pixelsHigh, Int(rect.maxY))

        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Check if pixel is not background (white or very light)
                let brightness = color.brightnessComponent
                let alpha = color.alphaComponent
                if alpha > 0.1 && brightness < 0.95 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Tests

    func test_foldH2_nothingVisibleBelowFoldedHeader() {
        let md = "# Title\nIntro text\n## Section\nThis should be hidden\n### Sub\nAlso hidden\n- bullet\n- another"
        let editor = makeEditor(markdown: md)
        guard let processor = editor.textStorageProcessor,
              let storage = editor.textStorage,
              let lm = editor.layoutManager else {
            XCTFail("Setup failed"); return
        }

        // Find H2 position for fold
        guard let h2Idx = processor.headerBlockIndex(at: (md as NSString).range(of: "## Section").location) else {
            XCTFail("No H2 found"); return
        }

        // Get H2 line's visual Y position BEFORE folding
        let h2GlyphRange = lm.glyphRange(forCharacterRange: processor.blocks[h2Idx].range, actualCharacterRange: nil)
        let h2Rect = lm.lineFragmentRect(forGlyphAt: h2GlyphRange.location, effectiveRange: nil)
        let h2Bottom = h2Rect.maxY + editor.textContainerOrigin.y + 60 // Well below the H2 header + ellipsis

        // Fold H2
        processor.toggleFold(headerBlockIndex: h2Idx, textStorage: storage)
        lm.ensureLayout(for: editor.textContainer!)

        // Capture snapshot
        guard let snapshot = captureSnapshot(editor) else {
            XCTFail("Failed to capture snapshot"); return
        }

        // Save snapshot for debugging
        let outputPath = "/tmp/fsnotes_fold_test.png"
        if let data = snapshot.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }

        // Check: the area below the folded H2 header should have NO visible content.
        // If there's a ghost table, ghost text, or any other artifact, this fails.
        let belowFoldRect = NSRect(x: 50, y: h2Bottom, width: renderSize.width - 100, height: renderSize.height - h2Bottom)
        let hasGhostContent = regionHasVisibleContent(snapshot, inRect: belowFoldRect)

        // Verify fold attribute is actually set
        var foldedCharCount = 0
        var foldedRanges: [NSRange] = []
        storage.enumerateAttribute(.foldedContent, in: NSRange(location: 0, length: storage.length)) { val, range, _ in
            if val != nil { foldedCharCount += range.length; foldedRanges.append(range) }
        }

        // Count dark pixels for diagnostic
        var darkPixelCount = 0
        var firstDarkPixel: (Int, Int)? = nil
        let checkRect = NSRect(x: 50, y: h2Bottom, width: renderSize.width - 100, height: renderSize.height - h2Bottom)
        let minX = max(0, Int(checkRect.minX))
        let maxX = min(snapshot.pixelsWide, Int(checkRect.maxX))
        let minY = max(0, Int(checkRect.minY))
        let maxY = min(snapshot.pixelsHigh, Int(checkRect.maxY))
        for y in minY..<maxY {
            for x in minX..<maxX {
                if let color = snapshot.colorAt(x: x, y: y) {
                    if color.alphaComponent > 0.1 && color.brightnessComponent < 0.95 {
                        darkPixelCount += 1
                        if firstDarkPixel == nil { firstDarkPixel = (x, y) }
                    }
                }
            }
        }

        XCTAssertFalse(hasGhostContent,
            "GHOST BUG: \(darkPixelCount) dark pixels found below folded H2 header. " +
            "First at (\(firstDarkPixel?.0 ?? -1), \(firstDarkPixel?.1 ?? -1)). " +
            "Snapshot saved to \(outputPath). " +
            "Check area from y=\(h2Bottom) to y=\(renderSize.height). " +
            "blocks=\(processor.blocks.count), collapsed=\(processor.isCollapsed(blockIndex: h2Idx)), " +
            "foldedChars=\(foldedCharCount)/\(storage.length) ranges=\(foldedRanges), " +
            "h2block=\(processor.blocks[h2Idx].range), " +
            "allBlocks=\(processor.blocks.map { "\(describeType($0.type))@\($0.range.location)" }.joined(separator: ","))")
    }

    func test_unfoldH2_contentReappears() {
        let md = "## Header\nVisible text here\n"
        let editor = makeEditor(markdown: md)
        guard let processor = editor.textStorageProcessor,
              let storage = editor.textStorage,
              let lm = editor.layoutManager else {
            XCTFail("Setup failed"); return
        }

        guard let idx = processor.headerBlockIndex(at: 0) else {
            XCTFail("No header"); return
        }

        // Fold
        processor.toggleFold(headerBlockIndex: idx, textStorage: storage)
        lm.ensureLayout(for: editor.textContainer!)

        // Unfold
        processor.toggleFold(headerBlockIndex: idx, textStorage: storage)
        lm.ensureLayout(for: editor.textContainer!)

        guard let snapshot = captureSnapshot(editor) else {
            XCTFail("Failed to capture snapshot"); return
        }

        let outputPath = "/tmp/fsnotes_unfold_test.png"
        if let data = snapshot.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }

        // After unfolding, the content below the header should be visible
        let belowHeaderRect = NSRect(x: 50, y: 40, width: renderSize.width - 100, height: 100)
        let hasContent = regionHasVisibleContent(snapshot, inRect: belowHeaderRect)

        XCTAssertTrue(hasContent,
            "After unfolding, content should be visible below the header. " +
            "Snapshot saved to \(outputPath)")
    }
}
