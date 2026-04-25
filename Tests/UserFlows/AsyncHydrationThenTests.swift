//
//  AsyncHydrationThenTests.swift
//  FSNotesTests
//
//  Phase 11 Slice D — demonstration tests for the async-hydration
//  `Then.*` readbacks. One test per readback; each uses
//  `eventually(within:)` to poll past the corresponding async work.
//
//  These tests don't depend on a live WKWebView snapshot — they
//  pre-warm `BlockRenderer`'s disk cache (mermaid, math) or stage a
//  real PNG on disk (image) so the hydration completes synchronously
//  on the first `eventually` poll. The point of the demo is to
//  validate the polling primitive and the readback predicates, not
//  to exercise WKWebView itself.
//

import XCTest
import AppKit
@testable import FSNotes

final class AsyncHydrationThenTests: XCTestCase {

    // MARK: - Helpers

    /// Build a small RGBA `NSImage` of the given size with a known
    /// non-empty bitmap representation. Used to pre-warm
    /// `BlockRenderer` disk cache so subsequent `BlockRenderer.render`
    /// calls hit the disk cache and return synchronously.
    private func makeFakeImage(
        width: Int = 80, height: Int = 40, color: NSColor = .systemBlue
    ) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Could not construct NSBitmapImageRep")
            return NSImage()
        }
        rep.size = NSSize(width: width, height: height)

        let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Encode a freshly-built RGBA bitmap as PNG bytes. Used to stage
    /// a real image file on disk so `ImageAttachmentHydrator.hydrate`
    /// has something whose natural size is much larger than the 1×1
    /// `imageAttachmentPlaceholderSize` — that's what the
    /// `attachmentBounds.isNonZero` predicate is verifying.
    private func makePNGData(width: Int, height: Int, color: NSColor) -> Data {
        let image = makeFakeImage(width: width, height: height, color: color)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode PNG")
            return Data()
        }
        return png
    }

    // MARK: - Demo 1: mermaid block hasRendered

    /// `Then.mermaidBlock(at:).hasRendered.eventually(within:)` polls
    /// the `MermaidLayoutFragment` for the rendered NSImage.
    /// Pre-warming `BlockRenderer`'s on-disk cache for the source
    /// guarantees the render completes synchronously the first time
    /// the fragment's draw triggers `ensureRenderRequested()`.
    func test_mermaidBlock_hasRendered_eventually() {
        let mermaidSource = "graph TD\nA-->B"
        // Force a unique cache key so cross-test pollution can't
        // pre-populate this entry. We use the disk cache because the
        // in-memory `cache` static is private; `_testOnly_writeToDisk`
        // is the available hook.
        BlockRenderer.clearCache()
        let cacheKey = "mermaid:\(mermaidSource)"
        let fakeImage = makeFakeImage(width: 120, height: 60)
        BlockRenderer._testOnly_writeToDisk(image: fakeImage, key: cacheKey)
        defer {
            try? FileManager.default.removeItem(
                at: BlockRenderer._testOnly_diskCacheFile(forKey: cacheKey)
            )
            BlockRenderer.clearCache()
        }

        let markdown = """
        ```mermaid
        \(mermaidSource)
        ```

        """

        Given.keyWindowNote(markdown: markdown)
            .Then.mermaidBlock(at: 0).hasRendered
                .eventually(within: 2.0)
    }

    // MARK: - Demo 2: image attachment bounds non-zero

    /// `Then.image(at:).attachmentBounds.isNonZero.eventually(within:)`
    /// polls the placeholder NSTextAttachment until
    /// `ImageAttachmentHydrator.hydrate` enlarges it past the 1×1
    /// placeholder. The hydrator runs on `editor.imagesLoaderQueue`
    /// (background) and dispatches the install back to main.
    func test_imageAttachment_bounds_isNonZero_eventually() {
        // Stage a real PNG in the harness's project tmp directory so
        // the renderer's path resolution succeeds. EditorHarness uses
        // NSTemporaryDirectory() as the project URL; bare filenames
        // resolve via getAttachmentFileUrl(name:). Use a 64×48 image
        // so post-hydration bounds are definitively non-placeholder
        // (the placeholder is 1×1).
        let fileName = "asynchyd_\(UUID().uuidString).png"
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(fileName)
        let pngData = makePNGData(width: 64, height: 48, color: .systemRed)
        FileManager.default.createFile(
            atPath: pngURL.path,
            contents: pngData
        )
        defer { try? FileManager.default.removeItem(at: pngURL) }

        // Build the scenario via the standard Given.note path; then
        // re-seed the projection with the harness's note attached so
        // the inline image resolves to the on-disk file. Mirrors the
        // pattern in TextKit2FragmentDispatchTests
        // (`test_phase2d_imageInlineMarkdown_becomesImageNSTextAttachment`).
        let markdown = "![alt](\(fileName))\n"
        let scenario = Given.note(markdown: markdown)
        guard let note = scenario.editor.note,
              let storage = scenario.editor.textStorage else {
            XCTFail("Harness must produce note + storage")
            return
        }
        let doc = MarkdownParser.parse(markdown)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            note: note
        )
        scenario.editor.textStorageProcessor?.isRendering = true
        StorageWriteGuard.performingFill {
            storage.setAttributedString(proj.attributed)
        }
        scenario.editor.textStorageProcessor?.isRendering = false
        scenario.editor.documentProjection = proj

        // Find the U+FFFC attachment offset (it's the only attachment
        // character in the seeded storage).
        var attachmentOffset: Int? = nil
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value is NSTextAttachment {
                attachmentOffset = range.location
                stop.pointee = true
            }
        }
        guard let offset = attachmentOffset else {
            XCTFail("Expected one image attachment in seeded storage")
            return
        }

        // Kick off the hydrator — production runs this from the splice
        // post-processing path; the harness's seed shortcut bypasses
        // that, so the test invokes it explicitly.
        ImageAttachmentHydrator.hydrate(
            textStorage: storage, editor: scenario.editor
        )

        scenario.Then.image(at: offset).attachmentBounds.isNonZero
            .eventually(within: 2.0)
    }

    // MARK: - Demo 3: inline math baseline alignment

    /// `Then.inlineMath(at:).baselineAlignedWith(textBaseline:)
    ///   .eventually(within:)` polls until
    /// `renderInlineMathViaBlockModel` replaces the source characters
    /// with an attachment whose `bounds.y == -|font.descender|`
    /// (`InlineMathBaseline.bounds(imageSize:font:)`). Validates the
    /// math-baseline fix end-to-end at the live-edit layer.
    func test_inlineMath_baselineAligned_eventually() {
        // Pre-warm BlockRenderer disk cache so the inline-math render
        // completes synchronously on first call. The cache key is
        // "inlineMath:<source>" — see BlockRenderer.render.
        let mathSource = "x"
        BlockRenderer.clearCache()
        let cacheKey = "inlineMath:\(mathSource)"
        let fakeImage = makeFakeImage(width: 14, height: 18, color: .systemPurple)
        BlockRenderer._testOnly_writeToDisk(image: fakeImage, key: cacheKey)
        defer {
            try? FileManager.default.removeItem(
                at: BlockRenderer._testOnly_diskCacheFile(forKey: cacheKey)
            )
            BlockRenderer.clearCache()
        }

        // Seed with text containing inline math. After parse +
        // InlineRenderer, the storage has "Text x end" with the "x"
        // run carrying `.inlineMathSource = "x"`. The hydration
        // replaces that "x" with an NSTextAttachment.
        let markdown = "Text $x$ end"
        let scenario = Given.note(markdown: markdown)
        guard let storage = scenario.editor.textStorage else {
            XCTFail("Harness must produce storage")
            return
        }

        // Locate the `.inlineMathSource` run BEFORE hydration so we
        // know what offset to poll. The hydration replaces the run
        // with a single attachment character at the same start.
        var mathOffset: Int? = nil
        storage.enumerateAttribute(
            .inlineMathSource,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value is String {
                mathOffset = range.location
                stop.pointee = true
            }
        }
        guard let offset = mathOffset else {
            XCTFail("Seeded storage missing .inlineMathSource attribute. " +
                    "Storage='\(storage.string)' length=\(storage.length)")
            return
        }

        // Read the body font at the math run's start so we can pass
        // it to baselineAlignedWith(textBaseline:). The hydration uses
        // the font at `range.location - 1` (or the run itself for
        // `location == 0`) — keep parity here.
        let probeOffset = max(0, offset - 1)
        let probeFont = (storage.attribute(
            .font, at: probeOffset, effectiveRange: nil
        ) as? NSFont) ?? NSFont.systemFont(ofSize: 14)

        // Kick off inline-math rendering (production calls this via
        // `renderSpecialBlocksViaBlockModel` after fill).
        scenario.editor.renderSpecialBlocksViaBlockModel()

        scenario.Then.inlineMath(at: offset)
            .baselineAlignedWith(textBaseline: probeFont)
            .eventually(within: 2.0)
    }
}
