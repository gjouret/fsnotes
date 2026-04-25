//
//  EditorAssertions+Bitmap.swift
//  FSNotesTests
//
//  Phase 11 Slice C — bitmap-based `Then.*` readbacks for drawn chrome.
//
//  Storage-level snapshots can prove a fragment dispatched correctly,
//  but they cannot prove the fragment actually painted pixels. The four
//  readbacks below render the relevant fragment to an offscreen bitmap
//  via `EditorHarness.renderFragmentToBitmap` (shipped in `f842473`)
//  and run tolerance-based pixel checks:
//
//    - Then.foldedHeader.indicatorRect.containsStrokePixels
//        Catches "no `[...]` rectangle after folded headers".
//
//    - Then.kbdSpan.boxRect.containsStrokePixels
//        Catches "<kbd> doesn't draw rounded rectangle".
//
//    - Then.hr.fragment(at:).contentDrawn
//        Catches "invisible HR line".
//
//    - Then.darkMode.contrast(of:).meetsWCAG_AA
//        Catches "table-header shading too light in dark mode" — the
//        bug class where a non-white background sits too close to the
//        body text color.
//
//  The contract per readback is "any non-background pixel exists in
//  this rect". Background = white (#FFFFFF) in light mode and a
//  theme-resolved fragment background in dark mode. We do NOT diff
//  against a reference image — that fails too easily across macOS
//  versions and font kerning.
//
//  Constraints (Slice C):
//    - Test-only changes; no production code touched.
//    - Must not modify `EditorScenario.swift` or `EditorAssertions.swift`.
//      All new readbacks are extensions on the existing `EditorAssertions`
//      struct + a few helper sub-namespaces declared here.
//    - The four `with(...)` builder helpers needed by the demo tests
//      are added as extensions on `EditorScenario` in this file too.
//

import XCTest
import AppKit
@testable import FSNotes

// MARK: - Builder extensions on EditorScenario
//
// The Slice C demo flows reference seed-shape verbs that don't yet
// exist in `EditorScenario.swift`. They live here as extensions so
// the existing scenario file stays unchanged.

/// Heading shape for `with(folded:)`. Names the level of the H? block
/// that gets seeded + folded. Only the level affects layout (font
/// size + bottom hairline) — body text is a fixed sample.
enum FoldedHeadingShape {
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6

    fileprivate var level: Int {
        switch self {
        case .heading1: return 1
        case .heading2: return 2
        case .heading3: return 3
        case .heading4: return 4
        case .heading5: return 5
        case .heading6: return 6
        }
    }

    fileprivate var hashes: String {
        return String(repeating: "#", count: level)
    }
}

extension EditorScenario {

    /// Re-seed the editor with arbitrary markdown. Equivalent to
    /// `Given.note(markdown: ...)` but expressed as a builder verb so
    /// flows that begin `Given.note().with(markdown: ...)` read left-
    /// to-right. Mirrors the private `seed(markdown:)` shape inside
    /// the harness using only public projection / storage APIs.
    ///
    /// Wraps the `setAttributedString` in `StorageWriteGuard.performingFill`
    /// so the Phase 5a debug assertion accepts the re-fill on an editor
    /// that already has `blockModelActive = true` (the harness sets the
    /// flag during its own initial seed, so any re-seed afterwards must
    /// declare itself as a fill).
    @discardableResult
    func with(markdown: String) -> EditorScenario {
        guard let storage = editor.textStorage else { return self }
        let doc = MarkdownParser.parse(markdown)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(
                ofSize: 14, weight: .regular
            )
        )
        StorageWriteGuard.performingFill {
            editor.textStorageProcessor?.isRendering = true
            storage.setAttributedString(proj.attributed)
            editor.textStorageProcessor?.isRendering = false
        }
        editor.documentProjection = proj
        editor.textStorageProcessor?.blockModelActive = true
        editor.note?.content = NSMutableAttributedString(string: markdown)
        editor.note?.cachedDocument = doc

        // Force a layout pass so subsequent fragment lookups see the
        // freshly seeded content.
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }
        return self
    }

    /// Seed the editor with a single heading of the requested level
    /// followed by a body paragraph, then mark the heading folded so
    /// `HeadingLayoutFragment` paints its `[...]` indicator chip.
    @discardableResult
    func with(folded shape: FoldedHeadingShape) -> EditorScenario {
        let md = "\(shape.hashes) Heading\n\nhidden body text\n"
        _ = self.with(markdown: md)
        // Mark block 0 (the heading) folded. The fragment reads
        // `.foldedContent` off the storage character immediately after
        // the heading element — `cachedFoldState` is the persisted
        // version, but the live attribute is what `isFolded` reads.
        if let storage = editor.textStorage,
           let projection = editor.documentProjection,
           projection.blockSpans.count >= 2 {
            // The body span starts immediately after the heading. Stamp
            // `.foldedContent` over its first character (and onward to
            // EOF) so the heading fragment sees the attribute via its
            // `endOffset` peek.
            let bodySpan = projection.blockSpans[1]
            let len = max(0, storage.length - bodySpan.location)
            if len > 0 {
                storage.addAttribute(
                    .foldedContent,
                    value: true,
                    range: NSRange(
                        location: bodySpan.location, length: len
                    )
                )
            }
        }
        editor.note?.cachedFoldState = [0]
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }
        return self
    }

    /// Seed the editor with a single horizontal-rule block. The `()`
    /// marker is purely a discriminator so the call site reads as
    /// `Given.note().with(horizontalRule: ())`.
    @discardableResult
    func with(horizontalRule: Void) -> EditorScenario {
        return self.with(markdown: "---\n")
    }
}

// MARK: - Then sub-namespaces

extension EditorAssertions {

    /// Folded-heading indicator (the `[...]` chip drawn at the trailing
    /// edge of a folded heading).
    var foldedHeader: FoldedHeaderAssertions {
        return FoldedHeaderAssertions(parent: self)
    }

    /// `<kbd>` rounded-rectangle box drawn behind kbd-tagged inline
    /// runs by `KbdBoxParagraphLayoutFragment`.
    var kbdSpan: KbdSpanAssertions {
        return KbdSpanAssertions(parent: self)
    }

    /// Horizontal-rule fragment (the gray bar drawn by
    /// `HorizontalRuleLayoutFragment`).
    var hr: HorizontalRuleAssertions {
        return HorizontalRuleAssertions(parent: self)
    }

    /// Dark-mode appearance simulation. Wraps the assertion body in a
    /// scope where `NSApp.appearance == .darkAqua` so theme-resolved
    /// colors return their dark-mode variants.
    var darkMode: DarkModeAssertions {
        return DarkModeAssertions(parent: self)
    }
}

// MARK: - Bitmap helpers

fileprivate enum BitmapHelpers {

    /// Background fill used by `renderFragmentToBitmap`: solid white
    /// (#FFFFFF, alpha=255). Pixels matching this within `tolerance`
    /// per channel are treated as untouched background.
    static let backgroundRGB: (UInt8, UInt8, UInt8) = (255, 255, 255)

    /// Per-channel tolerance for "is this pixel the background?".
    /// Antialiasing and subpixel rendering mean a fragment's text /
    /// chrome bleeds slightly into the white background; we accept
    /// 250..255 as "still background" so antialias halos don't
    /// accidentally count as drawn content.
    static let backgroundTolerance: UInt8 = 5

    /// Returns true if the `(r,g,b)` pixel is within `tolerance` per
    /// channel of `target`.
    static func isMatch(
        _ r: UInt8, _ g: UInt8, _ b: UInt8,
        target: (UInt8, UInt8, UInt8),
        tolerance: UInt8
    ) -> Bool {
        return abs(Int(r) - Int(target.0)) <= Int(tolerance)
            && abs(Int(g) - Int(target.1)) <= Int(tolerance)
            && abs(Int(b) - Int(target.2)) <= Int(tolerance)
    }

    /// Count non-background pixels in the entire bitmap.
    static func countNonBackground(
        pixels: [UInt8], width: Int, height: Int,
        tolerance: UInt8 = backgroundTolerance
    ) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
                if !isMatch(r, g, b,
                            target: backgroundRGB,
                            tolerance: tolerance) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Count non-background pixels inside `rect` (clamped to the
    /// bitmap). The rect is in bitmap-local coords (origin top-left).
    static func countNonBackground(
        pixels: [UInt8], width: Int, height: Int,
        in rect: CGRect,
        tolerance: UInt8 = backgroundTolerance
    ) -> Int {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
                if !isMatch(r, g, b,
                            target: backgroundRGB,
                            tolerance: tolerance) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Count pixels in the bitmap whose RGB matches `target` within
    /// `tolerance` per channel.
    static func countMatching(
        pixels: [UInt8], width: Int, height: Int,
        target: (UInt8, UInt8, UInt8),
        tolerance: UInt8
    ) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
                if isMatch(r, g, b,
                           target: target,
                           tolerance: tolerance) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Convert an `NSColor` to a calibrated 8-bit RGB triple. Returns
    /// nil if the color cannot be converted to `deviceRGB`.
    static func rgbTriple(for color: NSColor) -> (UInt8, UInt8, UInt8)? {
        guard let dev = color.usingColorSpace(.deviceRGB) else {
            return nil
        }
        let r = UInt8((dev.redComponent * 255).rounded()
            .clamped(to: 0...255))
        let g = UInt8((dev.greenComponent * 255).rounded()
            .clamped(to: 0...255))
        let b = UInt8((dev.blueComponent * 255).rounded()
            .clamped(to: 0...255))
        return (r, g, b)
    }

    /// WCAG 2.x relative luminance (sRGB → linear → weighted sum).
    /// Input components are 0...1.
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func chan(_ c: Double) -> Double {
            return c <= 0.03928
                ? c / 12.92
                : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
    }

    /// WCAG contrast ratio between two luminances. Returns ≥ 1.0.
    static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let lo = min(l1, l2)
        let hi = max(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
}

fileprivate extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Folded-header indicator

/// `Then.foldedHeader.indicatorRect.containsStrokePixels`
struct FoldedHeaderAssertions {
    let parent: EditorAssertions
    /// Locator: only the indicator-rect region is meaningful; expose
    /// directly so the chain stays readable.
    var indicatorRect: FoldedHeaderIndicatorAssertion {
        return FoldedHeaderIndicatorAssertion(parent: parent)
    }
}

struct FoldedHeaderIndicatorAssertion {
    let parent: EditorAssertions
    fileprivate var harness: EditorHarness { parent.scenario.harness }

    /// Property form of `containsStrokePixels(threshold:file:line:)`
    /// so chains read as `.Then.foldedHeader.indicatorRect.containsStrokePixels`
    /// without trailing parens. The result is implicitly discardable
    /// (property reads can always be ignored).
    var containsStrokePixels: EditorAssertions {
        return containsStrokePixels()
    }

    /// Render the heading fragment (block 0) to a bitmap, derive the
    /// indicator-rect region from
    /// `HeadingLayoutFragment.indicatorRect(folded:lastLineTypographicBounds:bodyFontSize:chrome:)`,
    /// and assert the rect contains > `threshold` non-background
    /// pixels. Catches the "folded header has no `[...]` chip"
    /// regression. Threshold is a generous lower bound (any chip that
    /// renders fill + text crosses 100 pixels easily).
    ///
    /// The chip is painted at the trailing edge of the heading's last
    /// line — past the right edge of `layoutFragmentFrame`. The default
    /// 4pt bitmap padding is not wide enough to capture it, so we
    /// compute the chip rect first and pass enough padding to the
    /// bitmap renderer that the chip lands inside the captured area.
    @discardableResult
    func containsStrokePixels(
        threshold: Int = 30,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        // Locate the live fragment FIRST so we can size the bitmap
        // wide enough to capture the chip area.
        guard let frag = AssertionHelpers.headingFragment(
            for: parent.scenario.editor
        ) else {
            XCTFail(
                "Then.foldedHeader.indicatorRect: live heading fragment " +
                "not located.",
                file: file, line: line
            )
            return parent
        }
        guard let lastLine = frag.textLineFragments.last else {
            XCTFail(
                "Then.foldedHeader.indicatorRect: heading fragment has " +
                "no line fragments.",
                file: file, line: line
            )
            return parent
        }
        guard let local = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: lastLine.typographicBounds,
            bodyFontSize: frag.headingBodyFont.pointSize,
            chrome: Theme.shared.chrome
        ) else {
            XCTFail(
                "Then.foldedHeader.indicatorRect: indicatorRect helper " +
                "returned nil despite folded=true.",
                file: file, line: line
            )
            return parent
        }

        // The bitmap renderer sizes the bitmap to
        // `layoutFragmentFrame.width + 2 * padding`. The chip lives at
        // `local.maxX` in fragment-local coords, which can extend past
        // the layout fragment's right edge. Pad to at least
        // `local.maxX - frame.width + 8` so the chip lands well inside
        // the captured area (8pt of slack on the right).
        let frameWidth = frag.layoutFragmentFrame.width
        let chipExtraRight = max(0, local.maxX - frameWidth)
        let padding = max(4.0, chipExtraRight + 8.0)

        guard let bitmap = harness.renderFragmentToBitmap(
            blockIndex: 0,
            fragmentClass: "HeadingLayoutFragment",
            padding: padding
        ) else {
            XCTFail(
                "Then.foldedHeader.indicatorRect: could not render " +
                "HeadingLayoutFragment for block 0. Fragment dispatch " +
                "may be wrong, or block 0 isn't a heading.",
                file: file, line: line
            )
            return parent
        }
        let (px, w, h) = bitmap

        // `local` is fragment-local with origin at (0, 0) ==
        // fragment.origin. The bitmap places fragment-origin at
        // (padding, padding), so add the padding to map to bitmap
        // coords.
        let bitmapRect = CGRect(
            x: local.origin.x + padding,
            y: local.origin.y + padding,
            width: local.size.width,
            height: local.size.height
        )
        let drawn = BitmapHelpers.countNonBackground(
            pixels: px, width: w, height: h, in: bitmapRect
        )
        if drawn <= threshold {
            XCTFail(
                "Then.foldedHeader.indicatorRect.containsStrokePixels: " +
                "expected > \(threshold) non-background pixels in chip " +
                "rect \(bitmapRect); got \(drawn). The `[...]` indicator " +
                "is NOT being painted. (bitmap=\(w)x\(h))",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: - Kbd box

/// `Then.kbdSpan.boxRect.containsStrokePixels`
struct KbdSpanAssertions {
    let parent: EditorAssertions
    var boxRect: KbdBoxRectAssertion {
        return KbdBoxRectAssertion(parent: parent)
    }
}

struct KbdBoxRectAssertion {
    let parent: EditorAssertions
    fileprivate var harness: EditorHarness { parent.scenario.harness }

    /// Property form of `containsStrokePixels(...)` so chains read as
    /// `.Then.kbdSpan.boxRect.containsStrokePixels` without trailing
    /// parens.
    var containsStrokePixels: EditorAssertions {
        return containsStrokePixels()
    }

    /// Render the kbd-paragraph fragment (block 0 by default) and
    /// assert that pixels matching the theme's `kbdStroke` color
    /// (±tolerance) appear above a small floor. Without the rounded
    /// rect the user sees only a font change — zero stroke pixels
    /// in the bitmap.
    @discardableResult
    func containsStrokePixels(
        blockIndex: Int = 0,
        threshold: Int = 5,
        tolerance: UInt8 = 8,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let bitmap = harness.renderFragmentToBitmap(
            blockIndex: blockIndex,
            fragmentClass: "KbdBoxParagraphLayoutFragment"
        ) else {
            XCTFail(
                "Then.kbdSpan.boxRect: could not render " +
                "KbdBoxParagraphLayoutFragment for block " +
                "\(blockIndex). Fragment dispatch may be wrong.",
                file: file, line: line
            )
            return parent
        }
        let (px, w, h) = bitmap
        let stroke = Theme.shared.colors.kbdStroke
            .resolvedForCurrentAppearance(
                fallback: NSColor(white: 0.8, alpha: 1.0)
            )
        guard let target = BitmapHelpers.rgbTriple(for: stroke) else {
            XCTFail(
                "Then.kbdSpan.boxRect: kbdStroke color failed to " +
                "resolve to deviceRGB.",
                file: file, line: line
            )
            return parent
        }
        let count = BitmapHelpers.countMatching(
            pixels: px, width: w, height: h,
            target: target, tolerance: tolerance
        )
        if count <= threshold {
            XCTFail(
                "Then.kbdSpan.boxRect.containsStrokePixels: expected " +
                "> \(threshold) pixels matching kbd stroke " +
                "rgb=\(target) (±\(tolerance)); got \(count). The " +
                "rounded rectangle is NOT being drawn. (bitmap=\(w)x\(h))",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: - HR line

/// `Then.hr.fragment(at:).contentDrawn`
struct HorizontalRuleAssertions {
    let parent: EditorAssertions
    func fragment(at blockIndex: Int) -> HRFragmentAssertion {
        return HRFragmentAssertion(parent: parent, blockIndex: blockIndex)
    }
}

struct HRFragmentAssertion {
    let parent: EditorAssertions
    let blockIndex: Int
    fileprivate var harness: EditorHarness { parent.scenario.harness }

    /// Assert that the HR fragment painted ANY non-background pixels.
    /// An invisible HR is an empty fragment — the user sees nothing
    /// where the rule should be.
    var contentDrawn: EditorAssertions {
        return contentDrawn()
    }

    /// Method form so callers can pass `file:line` when the property
    /// form's auto-captured location isn't precise enough.
    @discardableResult
    func contentDrawn(
        threshold: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let bitmap = harness.renderFragmentToBitmap(
            blockIndex: blockIndex,
            fragmentClass: "HorizontalRuleLayoutFragment"
        ) else {
            XCTFail(
                "Then.hr.fragment(at: \(blockIndex)).contentDrawn: " +
                "could not render HorizontalRuleLayoutFragment. " +
                "Fragment dispatch may be wrong, or block \(blockIndex) " +
                "isn't an HR.",
                file: file, line: line
            )
            return parent
        }
        let (px, w, h) = bitmap
        let count = BitmapHelpers.countNonBackground(
            pixels: px, width: w, height: h
        )
        if count < threshold {
            XCTFail(
                "Then.hr.fragment(at: \(blockIndex)).contentDrawn: " +
                "expected ≥ \(threshold) non-background pixels in " +
                "HR fragment; got \(count). The rule line is " +
                "invisible. (bitmap=\(w)x\(h))",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: - Dark mode contrast

/// Subject of the contrast check — names the chrome region whose
/// foreground / background pair gets compared against WCAG AA.
enum DarkModeContrastSubject {
    /// Table header background fill vs body text foreground.
    case tableHeader
}

/// `Then.darkMode.contrast(of:).meetsWCAG_AA`
struct DarkModeAssertions {
    let parent: EditorAssertions
    func contrast(
        of subject: DarkModeContrastSubject
    ) -> DarkModeContrastAssertion {
        return DarkModeContrastAssertion(
            parent: parent, subject: subject
        )
    }
}

struct DarkModeContrastAssertion {
    let parent: EditorAssertions
    let subject: DarkModeContrastSubject

    /// Temporarily set `NSApp.appearance` to `.darkAqua` for the
    /// duration of the assertion, resolve foreground + background
    /// colors for the named subject, and assert their WCAG contrast
    /// ratio is ≥ 4.5 (AA standard for body text). Restores the
    /// previous appearance via `defer` even on assertion failure.
    var meetsWCAG_AA: EditorAssertions {
        return meetsWCAG_AA()
    }

    @discardableResult
    func meetsWCAG_AA(
        minimumRatio: Double = 4.5,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let previous = NSApp.appearance
        let darkAqua = NSAppearance(named: .darkAqua)
        NSApp.appearance = darkAqua
        defer { NSApp.appearance = previous }

        let theme = Theme.shared
        // Resolve foreground + background under the dark-aqua drawing
        // appearance so dynamic system colors (`NSColor.textColor`)
        // return their dark variant. We MUST do the
        // `usingColorSpace(.deviceRGB)` flatten inside the
        // `performAsCurrentDrawingAppearance` block — it freezes the
        // dynamic color into a concrete RGB, which is what the
        // luminance math needs. Outside the block, the dynamic
        // `textColor` re-resolves to light-mode values.
        var fgRGB: NSColor? = nil
        var bgRGB: NSColor? = nil
        var fgDescr = ""
        var bgDescr = ""
        let resolveBlock = {
            let bg: NSColor
            let fg: NSColor
            switch self.subject {
            case .tableHeader:
                bg = theme.chrome.tableHeaderFill
                    .resolvedForCurrentAppearance(
                        fallback: NSColor(
                            calibratedWhite: 0.85, alpha: 1.0
                        )
                    )
                fg = NSColor.textColor
            }
            fgRGB = fg.usingColorSpace(.deviceRGB)
            bgRGB = bg.usingColorSpace(.deviceRGB)
            fgDescr = "\(fg)"
            bgDescr = "\(bg)"
        }
        if let dark = darkAqua {
            dark.performAsCurrentDrawingAppearance(resolveBlock)
        } else {
            resolveBlock()
        }

        guard let fg = fgRGB, let bg = bgRGB else {
            XCTFail(
                "Then.darkMode.contrast(of: \(subject)).meetsWCAG_AA: " +
                "color values failed to resolve to deviceRGB.",
                file: file, line: line
            )
            return parent
        }
        let lf = BitmapHelpers.luminance(
            r: Double(fg.redComponent),
            g: Double(fg.greenComponent),
            b: Double(fg.blueComponent)
        )
        let lb = BitmapHelpers.luminance(
            r: Double(bg.redComponent),
            g: Double(bg.greenComponent),
            b: Double(bg.blueComponent)
        )
        let ratio = BitmapHelpers.contrastRatio(lf, lb)
        if ratio < minimumRatio {
            XCTFail(
                "Then.darkMode.contrast(of: \(subject)).meetsWCAG_AA: " +
                "ratio \(String(format: "%.2f", ratio)) < " +
                "\(minimumRatio). fg=\(fgDescr) bg=\(bgDescr). The " +
                "dark-mode rendering of the \(subject) region is too " +
                "low-contrast for WCAG AA body text.",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: - Local fragment lookup

fileprivate enum AssertionHelpers {

    /// Locate the first `HeadingLayoutFragment` in the editor's
    /// layout. Returns nil if none is laid out (no heading block, or
    /// layout hasn't run).
    static func headingFragment(
        for editor: EditTextView
    ) -> HeadingLayoutFragment? {
        guard let tlm = editor.textLayoutManager else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        var found: HeadingLayoutFragment? = nil
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let h = fragment as? HeadingLayoutFragment {
                found = h
                return false
            }
            return true
        }
        return found
    }
}
