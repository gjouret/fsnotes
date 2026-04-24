//
//  Phase6ImageResizeSpliceTests.swift
//  FSNotesTests
//
//  Regression tests for the image-resize splice-corruption bug (2026-04-24).
//
//  Live symptom: user resized an image in "Refactor 4 — Testing"; the
//  resize landed a splice at storage offset 488, replacing the `N` of the
//  `Numbers` heading with an attachment character. The logged splice range
//  was `{488, 1}` even though the image being resized sat at a different
//  storage offset. Net: the Numbers heading started with `￼umbers` and
//  the original image attachment was left in place, so the live view had
//  two 0_0.png attachments at adjacent storage offsets.
//
//  These tests exercise the pure primitives that back
//  `commitImageResize`:
//    • `EditingOps.setImageSize` — builds the new Document / EditResult.
//    • `DocumentEditApplier.applyDocumentEdit` — the TK2 splice that
//      actually mutates `NSTextContentStorage`.
//
//  Each test constructs a multi-block document where an image block is
//  flanked by text blocks (paragraph + heading + paragraph, mirroring
//  the live shape), renders it into a seeded content storage, calls
//  setImageSize at a deliberately non-zero block index, applies via
//  `applyDocumentEdit`, and verifies:
//    1. Storage length delta is zero (one attachment char replaced by
//       one attachment char).
//    2. The storage character at the ORIGINAL image-attachment offset
//       is still `\u{FFFC}` AND carries an `.attachment` attribute.
//    3. The neighbouring text (the bytes before and after the image's
//       rendered span) is byte-identical to the pre-edit string.
//    4. The number of `.attachment` characters in storage is unchanged
//       — no phantom duplicate attachment was introduced.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase6ImageResizeSpliceTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Build a transient `Note` backed by a tmp URL so
    /// `InlineRenderer.makeImageAttachment` reaches its remote-URL
    /// placeholder path instead of the `note==nil` short-circuit.
    private func makeTmpNote() -> Note {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase6_img_\(UUID().uuidString).md")
        let project = Project(
            storage: Storage.shared(),
            url: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown
        note.content = NSMutableAttributedString(string: "")
        return note
    }

    /// Build an `NSTextContentStorage` seeded with the rendered form of
    /// `document`. Wired with the `BlockModelContentStorageDelegate`
    /// that the live app installs so element-level dispatch matches
    /// production.
    private func makeSeededContentStorage(
        for document: Document, note: Note
    ) -> (storage: NSTextContentStorage, rendered: RenderedDocument) {
        let rendered = DocumentRenderer.render(
            document, bodyFont: bodyFont(), codeFont: codeFont(), note: note
        )
        // Sanity: the attributed form should already carry one or more
        // `.attachment` attributes for image inlines. If it does not,
        // the rendered output routed to alt text (e.g. note==nil and a
        // local path couldn't resolve). The fixture assumes a remote
        // URL (which renders to a placeholder attachment even with
        // note==nil).
        let renderedAttachments = rendered.attributed.string
            .filter { $0 == "\u{FFFC}" }
            .count
        precondition(
            renderedAttachments >= 1,
            "rendered attributed string must contain at least one attachment character — fixture bug?"
        )

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let delegate = BlockModelContentStorageDelegate()
        contentStorage.delegate = delegate
        // NSTextContentStorage holds delegate weakly; pin via associated
        // object so it survives until the test tears down.
        objc_setAssociatedObject(
            contentStorage, Unmanaged.passUnretained(self).toOpaque(),
            delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(rendered.attributed)
        }
        return (contentStorage, rendered)
    }

    /// Locate every `.attachment`-bearing character in `storage` and
    /// return the set of offsets.
    private func attachmentOffsets(
        in storage: NSTextStorage
    ) -> [Int] {
        var offsets: [Int] = []
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            if value is NSTextAttachment {
                // One attachment character per attribute run in the
                // block-model renderer — guard in case the attribute
                // spans more than one character by accident.
                for i in 0..<range.length {
                    offsets.append(range.location + i)
                }
            }
        }
        return offsets
    }

    // MARK: - Tests

    /// Locate the first paragraph-block whose sole inline is an image.
    /// Returns the block index or nil.
    private func firstImageBlockIndex(_ doc: Document) -> Int? {
        for (i, block) in doc.blocks.enumerated() {
            if case let .paragraph(inline) = block,
               inline.count == 1,
               case .image = inline[0] {
                return i
            }
        }
        return nil
    }

    /// Document shape mirroring the live reproduction: a paragraph of
    /// text, a heading, an IMAGE paragraph, a heading, a final
    /// paragraph. The image sits at a deliberately non-zero block index
    /// so any off-by-one in offset math surfaces.
    func test_setImageSize_flankedByHeadingsAndParagraphs_preservesNeighbours() throws {
        let md = """
        Intro paragraph.

        ## Before heading

        ![alt](https://example.com/img.png)

        ## After heading

        Closing paragraph.
        """

        let doc = MarkdownParser.parse(md)
        guard let imageBlockIdx = firstImageBlockIndex(doc) else {
            return XCTFail("Fixture must contain one image paragraph; got blocks=\(doc.blocks)")
        }
        XCTAssertGreaterThan(imageBlockIdx, 0,
                             "Image block must not be at index 0 so offset math is exercised")

        let note = makeTmpNote()
        let projection = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont(), note: note
        )

        // Seed the content storage with the rendered prior doc.
        let (contentStorage, prior) = makeSeededContentStorage(for: doc, note: note)
        guard let textStorage = contentStorage.textStorage else {
            return XCTFail("contentStorage.textStorage must exist")
        }

        // Find the image attachment's rendered offset BEFORE the edit.
        let preAttachments = attachmentOffsets(in: textStorage)
        XCTAssertEqual(preAttachments.count, 1,
                       "Fixture has exactly one image attachment")
        let imageOffset = preAttachments[0]

        // Capture the bytes before the image and after the image so we
        // can assert byte-equal neighbours post-edit.
        let preString = textStorage.string as NSString
        let prefixRange = NSRange(location: 0, length: imageOffset)
        let suffixStart = imageOffset + 1
        let suffixRange = NSRange(
            location: suffixStart, length: preString.length - suffixStart
        )
        let preLen = textStorage.length
        let prePrefix = preString.substring(with: prefixRange)
        let preSuffix = preString.substring(with: suffixRange)

        // Also verify our rendered-projection view matches storage.
        XCTAssertEqual(prior.attributed.length, preLen)

        // Now call the primitive that `commitImageResize` invokes.
        let result = try EditingOps.setImageSize(
            blockIndex: imageBlockIdx, inlinePath: [0], newWidth: 500, in: projection
        )

        // Apply via the TK2 path — same code commitImageResize reaches
        // via `applyEditResultWithUndo`.
        _ = DocumentEditApplier.applyDocumentEdit(
            priorDoc: projection.document,
            newDoc: result.newProjection.document,
            contentStorage: contentStorage,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: note
        )

        // 1. Length preserved (attachment → attachment, same char count).
        XCTAssertEqual(textStorage.length, preLen,
                       "Resizing an image must not change storage length")

        // 2. The attachment must still live at the SAME offset. This is
        //    the direct shape of the bug: before the fix the splice
        //    landed at a neighbouring block's offset instead.
        let postAttachments = attachmentOffsets(in: textStorage)
        XCTAssertEqual(postAttachments.count, 1,
                       "Resizing an image must not create a duplicate attachment")
        XCTAssertEqual(postAttachments.first, imageOffset,
                       "Image attachment must remain at its original offset")

        // 3. Neighbours byte-identical.
        let postString = textStorage.string as NSString
        XCTAssertEqual(
            postString.substring(with: prefixRange), prePrefix,
            "Bytes preceding the image must be byte-identical after resize"
        )
        XCTAssertEqual(
            postString.substring(with: suffixRange), preSuffix,
            "Bytes following the image must be byte-identical after resize"
        )
    }

    /// Tight reproduction of the live shape: image paragraph IMMEDIATELY
    /// followed by a heading (no blank line between them in terms of
    /// rendered separators). The original bug manifested as the splice
    /// overwriting the first character of the heading.
    func test_setImageSize_followedByHeading_preservesHeadingFirstChar() throws {
        let md = """
        Leading paragraph.

        ![alt](https://example.com/img.png)

        ## Numbers

        Trailing.
        """

        let doc = MarkdownParser.parse(md)
        guard let imageBlockIdx = firstImageBlockIndex(doc) else {
            return XCTFail("Fixture must contain one image paragraph; got blocks=\(doc.blocks)")
        }
        // Verify there's a heading block AFTER the image (for the
        // "first char of heading" check below).
        var headingAfter: Int? = nil
        for j in (imageBlockIdx + 1)..<doc.blocks.count {
            if case .heading = doc.blocks[j] { headingAfter = j; break }
            if case .blankLine = doc.blocks[j] { continue }
            break
        }
        XCTAssertNotNil(headingAfter,
                        "Fixture must place a heading immediately after the image block")

        let note = makeTmpNote()
        let projection = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont(), note: note
        )
        let (contentStorage, _) = makeSeededContentStorage(for: doc, note: note)
        guard let textStorage = contentStorage.textStorage else {
            return XCTFail("contentStorage.textStorage must exist")
        }

        let preAttachments = attachmentOffsets(in: textStorage)
        XCTAssertEqual(preAttachments.count, 1)
        let imageOffset = preAttachments[0]

        let preString = textStorage.string as NSString
        let preLen = textStorage.length
        // Locate the `N` of "Numbers" in the pre-edit rendered string.
        // The heading renders as its plain text (no markers in WYSIWYG
        // storage). We search AFTER the image offset so we pick up the
        // heading's first character and not something earlier.
        let searchRange = NSRange(
            location: imageOffset + 1, length: preLen - (imageOffset + 1)
        )
        let headingFirstCharOffset = preString.range(
            of: "Numbers", options: [], range: searchRange
        ).location
        XCTAssertNotEqual(headingFirstCharOffset, NSNotFound,
                          "Fixture must render `Numbers` after the image")

        let result = try EditingOps.setImageSize(
            blockIndex: imageBlockIdx, inlinePath: [0], newWidth: 642, in: projection
        )

        _ = DocumentEditApplier.applyDocumentEdit(
            priorDoc: projection.document,
            newDoc: result.newProjection.document,
            contentStorage: contentStorage,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: note
        )

        XCTAssertEqual(textStorage.length, preLen)

        // Regression check: `Numbers` must still be intact in the
        // post-edit string at the same offset. Before the fix, the
        // splice overwrote the first `N` with `\u{FFFC}`.
        let postString = textStorage.string as NSString
        let headingSliceRange = NSRange(
            location: headingFirstCharOffset,
            length: min(7, postString.length - headingFirstCharOffset)
        )
        let headingSlicePost = postString.substring(with: headingSliceRange)
        XCTAssertEqual(
            headingSlicePost, "Numbers",
            "Heading text must not be overwritten by the image splice"
        )

        // Attachment count unchanged — no phantom duplicate.
        let postAttachments = attachmentOffsets(in: textStorage)
        XCTAssertEqual(postAttachments.count, 1,
                       "No duplicate attachment after resize")
        XCTAssertEqual(postAttachments.first, imageOffset,
                       "Image attachment must remain at its original offset")
    }

    // MARK: - Drift-between-projection-and-storage reproduction

    /// This test reproduces the live bug: `self.documentProjection`
    /// drifts out of sync with actual storage after the inline-math
    /// async renderer performs its `storage.replaceCharacters` swap
    /// (N source chars → 1 attachment char). The resize then feeds
    /// the STALE `priorDoc` into `DocumentEditApplier.applyDocumentEdit`,
    /// which re-renders priorDoc fresh (producing N-char math source
    /// again) and computes a splice offset that is wrong by exactly
    /// the cumulative length delta of the prior swaps. The splice
    /// lands on a neighbouring block, corrupting its text.
    ///
    /// The test intentionally mutates `textStorage` directly to
    /// simulate what the live math-render callback does, without
    /// updating `projection.document`. It then invokes
    /// `commitImageResize`'s core logic and asserts the splice lands
    /// at the image's ACTUAL storage offset, not where the stale
    /// projection thinks it is.
    func test_resize_withStaleProjection_afterInlineMathSwap_doesNotCorruptNeighbours() throws {
        // Inline math ($a/b=c$) before the image; heading after. Shape
        // mirrors the live note.
        let md = """
        Intro $a/b=c$ tail.

        ![alt](https://example.com/img.png)

        ## Numbers

        Closing.
        """

        let doc = MarkdownParser.parse(md)
        guard let imageBlockIdx = firstImageBlockIndex(doc) else {
            return XCTFail("Fixture must contain one image paragraph")
        }

        let note = makeTmpNote()
        var projection = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont(), note: note
        )
        let (contentStorage, _) = makeSeededContentStorage(for: doc, note: note)
        guard let textStorage = contentStorage.textStorage else {
            return XCTFail("contentStorage.textStorage must exist")
        }

        // Locate the `$a/b=c$` math range in storage. DocumentRenderer
        // emits the math source as literal text with a
        // `.inlineMathSource` attribute for the async renderer to find.
        var mathRange: NSRange? = nil
        textStorage.enumerateAttribute(
            .inlineMathSource,
            in: NSRange(location: 0, length: textStorage.length),
            options: []
        ) { value, range, stop in
            if value is String {
                mathRange = range
                stop.pointee = true
            }
        }
        guard let foundMathRange = mathRange else {
            return XCTFail("Fixture must emit an `.inlineMathSource` attribute")
        }

        // Simulate the async math-renderer: replace the N-char math
        // source run with a single attachment character. Storage length
        // shrinks by (N - 1). Also patch `projection.rendered` to
        // match — the live renderer at
        // `EditTextView+BlockModel.swift:2683-2713` does exactly this:
        // patches `proj.rendered.{attributed,blockSpans}` to reflect
        // the new storage layout while leaving `proj.document` stale.
        // That's the invariant break the bug exploits.
        let dummyAttachment = NSTextAttachment()
        let replacement = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: dummyAttachment)
        )
        let lengthDelta = replacement.length - foundMathRange.length
        XCTAssertLessThan(lengthDelta, 0, "Math swap should shrink storage")

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: foundMathRange, with: replacement)
        textStorage.endEditing()

        // Mirror the span-patching that EditTextView+BlockModel.swift
        // performs on `documentProjection` after the async swap.
        let patchedAttr = NSMutableAttributedString(
            attributedString: projection.attributed
        )
        patchedAttr.replaceCharacters(in: foundMathRange, with: replacement)
        var patchedSpans = projection.blockSpans
        for idx in 0..<patchedSpans.count {
            let span = patchedSpans[idx]
            if foundMathRange.location >= span.location
                && NSMaxRange(foundMathRange) <= NSMaxRange(span) {
                patchedSpans[idx] = NSRange(
                    location: span.location,
                    length: span.length + lengthDelta
                )
                for j in (idx + 1)..<patchedSpans.count {
                    patchedSpans[j] = NSRange(
                        location: patchedSpans[j].location + lengthDelta,
                        length: patchedSpans[j].length
                    )
                }
                break
            }
        }
        let patchedRendered = RenderedDocument(
            document: projection.document,
            attributed: patchedAttr,
            blockSpans: patchedSpans
        )
        projection = DocumentProjection(
            rendered: patchedRendered,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // Capture post-swap ground truth.
        let preLen = textStorage.length
        let preAttachments = attachmentOffsets(in: textStorage)
        // There should be two attachments now: the math swap and the
        // image placeholder.
        XCTAssertEqual(preAttachments.count, 2)
        // The image is the LAST attachment; the math swap is at the
        // earlier offset.
        let actualImageOffset = preAttachments[1]

        // The drift scenario: `projection.document` still has the
        // N-char math source, so `DocumentRenderer.render(doc)` would
        // produce a layout where the image sits at (actualOffset +
        // |lengthDelta|). This is the "stale view" that the OLD
        // applier path would use to compute the splice position.
        //
        // Compute the stale-view image offset by re-rendering the
        // document, to demonstrate the drift and capture the
        // neighbouring byte that the buggy path overwrites.
        let staleRendered = DocumentRenderer.render(
            projection.document, bodyFont: projection.bodyFont,
            codeFont: projection.codeFont, note: note
        )
        var staleImageOffsets: [Int] = []
        staleRendered.attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: staleRendered.attributed.length),
            options: []
        ) { value, range, _ in
            if value is NSTextAttachment { staleImageOffsets.append(range.location) }
        }
        XCTAssertEqual(staleImageOffsets.count, 1,
                       "Stale render has only the image attachment (no math swap yet)")
        let staleImageOffset = staleImageOffsets[0]
        XCTAssertNotEqual(actualImageOffset, staleImageOffset,
                          "Drift must exist for this regression test to be meaningful")

        // The "collateral offset" is the storage position the BUGGY
        // applier would write to: the stale-view image offset. In the
        // post-swap storage, that offset holds a text character —
        // typically the character that sat at the image position
        // BEFORE the math swap shifted everything left.
        let preString = textStorage.string as NSString
        let collateralOffset = staleImageOffset
        XCTAssertLessThan(collateralOffset, preLen)
        let collateralPre = preString.substring(
            with: NSRange(location: collateralOffset, length: 1)
        )
        XCTAssertNotEqual(collateralPre, "\u{FFFC}",
                          "Collateral offset must currently hold a text character, not an attachment")

        // Build the setImageSize result using the STALE projection
        // (mirrors what commitImageResize does: reads
        // `self.documentProjection`, which the async math render
        // didn't update).
        let result = try EditingOps.setImageSize(
            blockIndex: imageBlockIdx, inlinePath: [0], newWidth: 500, in: projection
        )

        // Apply via the same TK2 path commitImageResize takes. We pass
        // `projection.rendered` as the prior-render override — mirrors
        // what `applyEditResultWithUndo` does after the fix.
        _ = DocumentEditApplier.applyDocumentEdit(
            priorDoc: projection.document,
            newDoc: result.newProjection.document,
            contentStorage: contentStorage,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: note,
            priorRenderedOverride: projection.rendered
        )

        // ASSERTIONS: the splice must not corrupt the collateral byte
        // and must not produce duplicate image attachments in storage.
        let postString = textStorage.string as NSString
        let collateralPost = postString.substring(
            with: NSRange(location: collateralOffset, length: 1)
        )
        XCTAssertEqual(collateralPost, collateralPre,
                       "Neighbouring text byte at the stale-projection offset must be preserved")

        let postAttachments = attachmentOffsets(in: textStorage)
        // Expect 2 attachments post-splice: the dummy math-swap and
        // the image (possibly replaced with a new attachment). Critically
        // NOT 3 — a third attachment implies a phantom duplicate.
        XCTAssertEqual(postAttachments.count, 2,
                       "Resize must not create a phantom duplicate attachment")
    }
}
