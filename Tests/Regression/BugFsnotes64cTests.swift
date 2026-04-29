//
//  BugFsnotes64cTests.swift
//  FSNotesTests
//
//  bd-fsnotes-64c — Mode-aware render cache for MathJax / Mermaid /
//  QuickLook (light <-> dark).
//
//  Companion bead fsnotes-237 already shipped the BlockRenderer side of
//  the fix: cache key is `"<type>:<dark|light>:<source>"`, body
//  background is transparent, and the offscreen WKWebView no longer
//  draws an opaque backing. A Light <-> Dark toggle therefore produces
//  a cache miss for mermaid / math diagrams and re-renders with the
//  correct text + diagram-line palette on first paint.
//
//  This bead closes the QuickLook half: thumbnails returned by
//  `QuickLookThumbnailCache` for the SAME url must be appearance-aware
//  too, otherwise after a mode switch the user sees a stale light-mode
//  Numbers / Excel / Pages thumbnail behind the (re-loading) live
//  QLPreviewView. Pinning the contract programmatically so a future
//  refactor can't silently regress it.
//

import XCTest
@testable import FSNotes

final class BugFsnotes64cTests: XCTestCase {

    // MARK: - QuickLookThumbnailCache: appearance-aware keying

    /// The same URL must address two distinct cache slots — one for
    /// light mode, one for dark. Reading back with a mismatched
    /// appearance must return nil (or the matching mode's image), never
    /// the other mode's image. Without the discriminator, after a
    /// Light -> Dark switch a recycled `InlineQuickLookView` sees a
    /// light-mode thumbnail behind the dark editor background — the
    /// regression fsnotes-64c is closing.
    func test_thumbnailCache_distinguishesLightAndDark() {
        let url = URL(fileURLWithPath: "/tmp/quicklook_64c_\(UUID().uuidString).bin")
        let lightImage = NSImage(size: NSSize(width: 16, height: 16))
        let darkImage = NSImage(size: NSSize(width: 32, height: 32))

        // Defensive cleanup in both slots.
        QuickLookThumbnailCache.removeObject(for: url, isDark: false)
        QuickLookThumbnailCache.removeObject(for: url, isDark: true)

        QuickLookThumbnailCache.setObject(lightImage, for: url, isDark: false)
        QuickLookThumbnailCache.setObject(darkImage, for: url, isDark: true)

        XCTAssertTrue(
            QuickLookThumbnailCache.cachedThumbnail(for: url, isDark: false) === lightImage,
            "Light-mode lookup must return the light-mode image."
        )
        XCTAssertTrue(
            QuickLookThumbnailCache.cachedThumbnail(for: url, isDark: true) === darkImage,
            "Dark-mode lookup must return the dark-mode image."
        )

        // Cleanup.
        QuickLookThumbnailCache.removeObject(for: url, isDark: false)
        QuickLookThumbnailCache.removeObject(for: url, isDark: true)
    }

    /// Storing only in one mode must NOT satisfy a lookup in the other.
    /// The pre-fix bug is exactly this — a single-mode cache returns the
    /// stored image to a query made under a different effectiveAppearance.
    func test_thumbnailCache_lightOnlyEntry_doesNotSatisfyDarkLookup() {
        let url = URL(fileURLWithPath: "/tmp/quicklook_64c_\(UUID().uuidString).bin")
        let image = NSImage(size: NSSize(width: 16, height: 16))

        QuickLookThumbnailCache.removeObject(for: url, isDark: false)
        QuickLookThumbnailCache.removeObject(for: url, isDark: true)

        QuickLookThumbnailCache.setObject(image, for: url, isDark: false)

        XCTAssertNotNil(
            QuickLookThumbnailCache.cachedThumbnail(for: url, isDark: false),
            "Stored light-mode image must be reachable under light lookup."
        )
        XCTAssertNil(
            QuickLookThumbnailCache.cachedThumbnail(for: url, isDark: true),
            "Storing only the light-mode entry must not satisfy a dark-mode lookup."
        )

        QuickLookThumbnailCache.removeObject(for: url, isDark: false)
    }

    /// Distinct URLs in the same mode must not collide — appearance keying
    /// must compose with URL identity, not replace it.
    func test_thumbnailCache_distinctURLs_doNotCollideWithinMode() {
        let urlA = URL(fileURLWithPath: "/tmp/quicklook_64c_A_\(UUID().uuidString).bin")
        let urlB = URL(fileURLWithPath: "/tmp/quicklook_64c_B_\(UUID().uuidString).bin")
        let imageA = NSImage(size: NSSize(width: 16, height: 16))
        let imageB = NSImage(size: NSSize(width: 32, height: 32))

        QuickLookThumbnailCache.setObject(imageA, for: urlA, isDark: true)
        QuickLookThumbnailCache.setObject(imageB, for: urlB, isDark: true)

        XCTAssertTrue(
            QuickLookThumbnailCache.cachedThumbnail(for: urlA, isDark: true) === imageA
        )
        XCTAssertTrue(
            QuickLookThumbnailCache.cachedThumbnail(for: urlB, isDark: true) === imageB
        )

        QuickLookThumbnailCache.removeObject(for: urlA, isDark: true)
        QuickLookThumbnailCache.removeObject(for: urlB, isDark: true)
    }

    // MARK: - BlockRenderer cache key sentinel

    /// fsnotes-237 wired the appearance discriminator into the
    /// BlockRenderer cache-key string. This is a sentinel test: if a
    /// future refactor removes the `<dark|light>` segment, the disk
    /// cache filename collapses back to a per-source hash and a Light
    /// <-> Dark toggle will return the stale-mode SVG. We pin the
    /// behaviour by hashing two keys that differ only in mode and
    /// asserting they map to different on-disk file URLs.
    func test_blockRenderer_diskCacheFile_isAppearanceSpecific() {
        let lightURL = BlockRenderer._testOnly_diskCacheFile(
            forKey: "mermaid:light:graph TD; A-->B"
        )
        let darkURL = BlockRenderer._testOnly_diskCacheFile(
            forKey: "mermaid:dark:graph TD; A-->B"
        )
        XCTAssertNotEqual(
            lightURL, darkURL,
            "Light and dark cache keys must hash to different on-disk files; " +
            "otherwise a mode toggle re-uses the prior mode's SVG."
        )
    }
}
