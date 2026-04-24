//
//  BlockRendererDiskCacheScaleTests.swift
//  FSNotesTests
//
//  Regression guard for the "math/mermaid blur on second launch" bug
//  (user-reported 2026-04-23). `BlockRenderer`'s in-memory cache
//  preserves the 2× `NSImage` produced by `WKWebView.takeSnapshot` on
//  Retina, so the first render in a session paints crisp. On app
//  restart the disk cache (cross-session perf win, activity #3789) is
//  consulted before kicking off a fresh WebView render — but the old
//  `loadFromDisk` path called `NSImage(data:)`, which synthesizes a 1×
//  rep sized in *pixels*. The fragment's draw code then treated the
//  image as 1× and scaled it down to fit the container width, so a
//  2×-captured bitmap was resampled at 1× resolution. Visible blur.
//
//  The fix (`loadFromDisk` now constructs `NSBitmapImageRep`, sets
//  `rep.size = pixelSize / backingScaleFactor`, and wraps it in an
//  `NSImage` of the point-sized dimensions) preserves the 2× scale on
//  read-back.
//
//  These tests write a known 2× image to disk, read it back, and
//  assert (a) the in-memory `NSImage.size` is in points (100 pt, not
//  200 px) and (b) the underlying bitmap rep still reports
//  `pixelsWide == 200` so the original captured resolution is not
//  resampled away.
//

import XCTest
import AppKit
@testable import FSNotes

final class BlockRendererDiskCacheScaleTests: XCTestCase {

    // MARK: - Helpers

    /// Construct a known-2× `NSImage`: a 100 pt × 100 pt image backed
    /// by a 200 px × 200 px `NSBitmapImageRep`, painted solid red so a
    /// decoded round-trip is trivially verifiable.
    private func makeHiDPIImage() -> NSImage {
        let sizePt = NSSize(width: 100, height: 100)
        let pixelsWide = 200
        let pixelsHigh = 200

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
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
        rep.size = sizePt

        // Paint solid red so the round-tripped image is non-empty and
        // the PNG encode/decode path actually executes.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(origin: .zero, size: NSSize(width: pixelsWide, height: pixelsHigh)).fill()

        let image = NSImage(size: sizePt)
        image.addRepresentation(rep)
        return image
    }

    private func cleanupCacheFile(key: String) {
        #if DEBUG
        let url = BlockRenderer._testOnly_diskCacheFile(forKey: key)
        try? FileManager.default.removeItem(at: url)
        #endif
    }

    // MARK: - Tests

    /// Write a known 2× image to disk, read it back, and verify the
    /// reconstructed `NSImage` preserves BOTH (a) the point-sized
    /// `.size` and (b) the underlying 2× pixel count. This is the core
    /// fix: without it, `NSImage(data:)` produces a 1× image whose
    /// `size` reports the pixel count and fragments treat it as a
    /// smaller image that gets resampled up at draw time.
    func test_diskCache_roundTrip_preservesHiDPIScale() {
        #if !DEBUG
        throw XCTSkip("_testOnly_ helpers only available in DEBUG builds.")
        #else
        let key = "scale-test-\(UUID().uuidString)"
        defer { cleanupCacheFile(key: key) }

        let source = makeHiDPIImage()
        BlockRenderer._testOnly_writeToDisk(image: source, key: key)

        guard let loaded = BlockRenderer._testOnly_loadFromDisk(key: key) else {
            XCTFail("loadFromDisk must succeed after writeToDisk with a " +
                    "valid image")
            return
        }

        // Expected behavior after the fix: `.size` is in points, using
        // the current main-screen backing scale factor. We assert the
        // image's point size divides into the pixel count at the
        // current backing scale — the exact scale factor depends on the
        // test host (CI runners may be 1×, devs' Retina 2×, Studio
        // Display XDR 2×). What must hold: size × scale == pixelSize.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let rep = loaded.representations.first as? NSBitmapImageRep else {
            XCTFail(
                "Loaded image must expose an NSBitmapImageRep as its " +
                "first representation — got \(type(of: loaded.representations.first))"
            )
            return
        }

        // Pixel count must match the original 200×200 — the PNG
        // encode/decode round-trip preserves this regardless of the
        // scale handling.
        XCTAssertEqual(
            rep.pixelsWide, 200,
            "Bitmap rep must carry the original 200 px width after the " +
            "disk round-trip. pixelsWide=\(rep.pixelsWide) means the PNG " +
            "encode/decode resampled the image — which is the blur bug."
        )
        XCTAssertEqual(
            rep.pixelsHigh, 200,
            "Bitmap rep must carry the original 200 px height after the " +
            "disk round-trip. pixelsHigh=\(rep.pixelsHigh)."
        )

        // After the fix, `size` is in points. `size.width * scale` must
        // match the pixel count — the invariant that defines "2× image"
        // vs "1× image". Before the fix, `size.width` equalled
        // `pixelsWide`, so `size × scale` was 2× the pixel count and the
        // image was drawn twice as large, forcing the fragment to
        // down-scale (visible blur).
        XCTAssertEqual(
            loaded.size.width * scale, CGFloat(rep.pixelsWide), accuracy: 0.5,
            "NSImage.size.width × backingScaleFactor must equal pixelsWide. " +
            "size.width=\(loaded.size.width) scale=\(scale) " +
            "pixelsWide=\(rep.pixelsWide). If size.width equals pixelsWide " +
            "(not pixelsWide/scale), the image is 1×-scaled and fragments " +
            "will resample it down at draw time — the blur bug."
        )
        XCTAssertEqual(
            loaded.size.height * scale, CGFloat(rep.pixelsHigh), accuracy: 0.5,
            "NSImage.size.height × backingScaleFactor must equal pixelsHigh. " +
            "size.height=\(loaded.size.height) scale=\(scale) " +
            "pixelsHigh=\(rep.pixelsHigh)."
        )

        // And the rep's own `.size` must have been updated to match —
        // `NSBitmapImageRep.size` is what `image.draw(in:)` consults to
        // decide the target scale. If the rep's size is still in pixels,
        // the image will draw at pixel-size and bypass the scale
        // adjustment.
        XCTAssertEqual(
            rep.size.width, loaded.size.width, accuracy: 0.5,
            "The rep's size must match the image's size (both in points). " +
            "rep.size.width=\(rep.size.width) image.size.width=\(loaded.size.width)."
        )
        #endif
    }

    /// Negative-path guard: a non-existent disk key must return nil,
    /// not crash. Exercises the `Data(contentsOf:)` failure branch.
    func test_diskCache_missingFile_returnsNil() {
        #if !DEBUG
        throw XCTSkip("_testOnly_ helpers only available in DEBUG builds.")
        #else
        let missingKey = "definitely-not-present-\(UUID().uuidString)"
        let result = BlockRenderer._testOnly_loadFromDisk(key: missingKey)
        XCTAssertNil(
            result,
            "loadFromDisk must return nil for an absent key, not a zero-size " +
            "image."
        )
        #endif
    }

    // MARK: - HiDPI v3: takeSnapshot rebuild

    /// Construct a "raw" input that stands in for what `WKWebView.takeSnapshot`
    /// returns on a Retina host: an `NSImage` whose `.size` reports the point
    /// dimensions but whose backing is a bitmap at the physical pixel count.
    /// The helper must divide pixel dimensions by `backingScale` to produce
    /// a correctly-sized point image — i.e. the canonical HiDPI shape.
    ///
    /// We give the input image a deliberately-wrong `.size` (equal to the
    /// pixel count, which is the shape Cocoa would synthesize from a CI rep)
    /// so the test proves the rebuild path recomputes `.size` from
    /// `pixelsWide / backingScale` rather than trusting the input's size.
    private func makeRawSnapshotImage(pixelsWide: Int, pixelsHigh: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
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

        // Paint solid blue so the TIFF round-trip inside the helper has real
        // pixel data to encode/decode.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: NSSize(width: pixelsWide, height: pixelsHigh)).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Simulate the CI-rep shape: `.size` equals pixel count (i.e. 1×),
        // which is what Cocoa produces when it doesn't recognize an explicit
        // HiDPI scale. The rebuild helper must correct this.
        let image = NSImage(size: NSSize(width: pixelsWide, height: pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    /// Core HiDPI v3 regression: after the rebuild, the NSImage's `.size`
    /// is in points (pixels / backingScale), the sole representation is an
    /// `NSBitmapImageRep`, and the rep's `pixelsWide`/`pixelsHigh` still
    /// equal the physical pixel count. This is the shape the fragment
    /// draw code expects; if any of these fail, `image.draw(in:)` will
    /// upscale or downscale and the diagram renders blurry.
    func test_rebuildHiDPIImage_preservesPixelDensityAt2x() {
        #if !DEBUG
        throw XCTSkip("_testOnly_ helper only available in DEBUG builds.")
        #else
        let pixelsWide = 200
        let pixelsHigh = 100
        let scale: CGFloat = 2.0

        let input = makeRawSnapshotImage(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
        let output = BlockRenderer._testOnly_rebuildHiDPIImage(
            from: input, backingScale: scale
        )

        XCTAssertEqual(
            output.size.width, CGFloat(pixelsWide) / scale, accuracy: 0.5,
            "size.width in points must equal pixelsWide / backingScale. " +
            "size.width=\(output.size.width) expected=\(CGFloat(pixelsWide) / scale)."
        )
        XCTAssertEqual(
            output.size.height, CGFloat(pixelsHigh) / scale, accuracy: 0.5,
            "size.height in points must equal pixelsHigh / backingScale. " +
            "size.height=\(output.size.height) expected=\(CGFloat(pixelsHigh) / scale)."
        )

        guard let rep = output.representations.first as? NSBitmapImageRep else {
            XCTFail(
                "Rebuilt image must expose an NSBitmapImageRep as its first " +
                "representation — got \(type(of: output.representations.first)). " +
                "If this is an NSCIImageRep, the rebuild did not run and " +
                "downstream draws will upscale on the 2× backing (blur bug)."
            )
            return
        }

        XCTAssertEqual(
            rep.pixelsWide, pixelsWide,
            "Rebuilt rep must carry the original physical pixel width. " +
            "pixelsWide=\(rep.pixelsWide) expected=\(pixelsWide). If this is " +
            "halved, the rebuild resampled the bitmap — losing resolution."
        )
        XCTAssertEqual(
            rep.pixelsHigh, pixelsHigh,
            "Rebuilt rep must carry the original physical pixel height. " +
            "pixelsHigh=\(rep.pixelsHigh) expected=\(pixelsHigh)."
        )

        // The rep's own `.size` must match the image's size (both in points).
        // `image.draw(in:)` consults `rep.size` to decide the target scale;
        // if it's still in pixels, the image draws at pixel-size and bypasses
        // the scale adjustment.
        XCTAssertEqual(
            rep.size.width, output.size.width, accuracy: 0.5,
            "rep.size.width must match image.size.width (both points). " +
            "rep.size.width=\(rep.size.width) image.size.width=\(output.size.width)."
        )
        #endif
    }

    /// Scale-awareness guard: at `backingScale: 1.0` the rebuild must
    /// produce an image whose `.size` equals its pixel count (i.e. 1×,
    /// non-Retina host). Proves the helper reads the scale argument
    /// rather than being hard-coded to 2×.
    func test_rebuildHiDPIImage_at1x_sizeMatchesPixels() {
        #if !DEBUG
        throw XCTSkip("_testOnly_ helper only available in DEBUG builds.")
        #else
        let pixelsWide = 150
        let pixelsHigh = 75
        let scale: CGFloat = 1.0

        let input = makeRawSnapshotImage(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
        let output = BlockRenderer._testOnly_rebuildHiDPIImage(
            from: input, backingScale: scale
        )

        XCTAssertEqual(
            output.size.width, CGFloat(pixelsWide), accuracy: 0.5,
            "At 1× the rebuild must produce size.width == pixelsWide. " +
            "size.width=\(output.size.width) pixelsWide=\(pixelsWide). If this " +
            "reports half the pixel count, the helper is hard-coded to 2×."
        )
        XCTAssertEqual(
            output.size.height, CGFloat(pixelsHigh), accuracy: 0.5,
            "At 1× the rebuild must produce size.height == pixelsHigh. " +
            "size.height=\(output.size.height) pixelsHigh=\(pixelsHigh)."
        )

        guard let rep = output.representations.first as? NSBitmapImageRep else {
            XCTFail("Rebuilt image must expose an NSBitmapImageRep.")
            return
        }
        XCTAssertEqual(rep.pixelsWide, pixelsWide)
        XCTAssertEqual(rep.pixelsHigh, pixelsHigh)
        #endif
    }

    /// Already-correct input is idempotent: a well-formed HiDPI NSImage
    /// (size in points, rep in physical pixels) fed through the rebuild
    /// emerges with the same size and pixel dimensions. The helper's
    /// transform is a function of `pixelsWide / backingScale`, not of the
    /// input's current `.size`, so a round-trip is a fixed point when
    /// `rep.size == input.size`.
    func test_rebuildHiDPIImage_alreadyCorrectInput_isFixedPoint() {
        #if !DEBUG
        throw XCTSkip("_testOnly_ helper only available in DEBUG builds.")
        #else
        let pixelsWide = 200
        let pixelsHigh = 100
        let scale: CGFloat = 2.0
        let pointSize = NSSize(
            width: CGFloat(pixelsWide) / scale,
            height: CGFloat(pixelsHigh) / scale
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Could not construct NSBitmapImageRep")
            return
        }
        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.green.setFill()
        NSRect(origin: .zero, size: NSSize(width: pixelsWide, height: pixelsHigh)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let input = NSImage(size: pointSize)
        input.addRepresentation(rep)

        let output = BlockRenderer._testOnly_rebuildHiDPIImage(
            from: input, backingScale: scale
        )

        XCTAssertEqual(
            output.size.width, pointSize.width, accuracy: 0.5,
            "Rebuilding an already-correct HiDPI image must not change size."
        )
        XCTAssertEqual(
            output.size.height, pointSize.height, accuracy: 0.5,
            "Rebuilding an already-correct HiDPI image must not change size."
        )
        guard let outRep = output.representations.first as? NSBitmapImageRep else {
            XCTFail("Output must still be bitmap-backed.")
            return
        }
        XCTAssertEqual(outRep.pixelsWide, pixelsWide)
        XCTAssertEqual(outRep.pixelsHigh, pixelsHigh)
        #endif
    }
}
