//
//  LinkHoverTests.swift
//  FSNotesTests
//
//  Phase 2f.3 — TK2 link-hover cursor.
//
//  Verifies the TK2 fallback in `EditTextView+Interaction.swift` (the
//  new `characterIndexTK2(at:)` helper). Under TK1 the hover path
//  resolves a point via `NSLayoutManager.characterIndex(for:in:...)`;
//  under TK2 the TK1 APIs return nil because `layoutManagerIfTK1` is
//  nil, so a new `NSTextLayoutManager`-based resolver is needed.
//
//  The test drives the pure resolver: point-in-text-container →
//  character index → `.link` attribute read. No synthetic mouse
//  events, no NSCursor assertions — that's cosmetic and implicit once
//  the attribute lookup is correct.
//

import XCTest
import AppKit
@testable import FSNotes

final class LinkHoverTests: XCTestCase {

    /// Given a harness containing an inline link, the TK2 character
    /// index resolver must map a point inside the link's visual
    /// rectangle to a character index that carries the `.link`
    /// attribute. This is the core correctness invariant — everything
    /// downstream (cursor style, click dispatch) reads `.link` off
    /// that index.
    func test_phase2f3_characterIndexTK2_resolvesPointToLinkAttribute() {
        let markdown = "Click [here](https://example.com) to go"
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        // Sanity-check: the harness wires the editor onto TK2.
        // If this fails the rest of the test is meaningless — the
        // TK1 branch would be exercised instead.
        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "LinkHoverTests expects TK2. If the harness regresses to" +
            " TK1, this test is no longer exercising the 2f.3 code."
        )

        guard let storage = harness.editor.textStorage else {
            return XCTFail("editor has no textStorage")
        }

        // Find the character range of the link in the rendered
        // storage. Under the WYSIWYG renderer the brackets and URL
        // are hidden, so the storage reads "Click here to go" with a
        // `.link` attribute on "here".
        let rendered = storage.string as NSString
        let hereRange = rendered.range(of: "here")
        XCTAssertNotEqual(
            hereRange.location, NSNotFound,
            "Link text 'here' must appear in the rendered storage." +
            " If this fails, the renderer changed and the test needs" +
            " to be rewritten against the new projection."
        )

        // Confirm at the source of truth that the link attribute is
        // actually attached to 'here' in storage. If this fails, the
        // bug is in the renderer, not in TK2 hit-testing.
        let midOfHere = hereRange.location + hereRange.length / 2
        XCTAssertNotNil(
            storage.attribute(.link, at: midOfHere, effectiveRange: nil),
            "Renderer did not apply .link to the link text."
        )

        // Drive the TK2 layout so textLayoutFragment(for:) has
        // something to return. Without an explicit ensureLayout the
        // fragment lookup returns nil for an offscreen test window.
        guard let tlm = harness.editor.textLayoutManager else {
            return XCTFail("expected TK2 text layout manager")
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Find the on-screen rect of the link text via TK2 layout.
        // We walk fragments looking for the line that contains the
        // link's character range, then pick a point inside the line's
        // typographic bounds. This matches what a real mouse hover
        // would resolve.
        var hitPoint: NSPoint?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let contentStorage = tlm.textContentManager as? NSTextContentStorage,
                  let elementRange = fragment.textElement?.elementRange else {
                return true
            }
            let docStart = contentStorage.documentRange.location
            let elementStart = contentStorage.offset(from: docStart, to: elementRange.location)
            let elementEnd = elementStart + contentStorage.offset(
                from: elementRange.location, to: elementRange.endLocation
            )

            // Link must fall inside this fragment's character span.
            guard midOfHere >= elementStart && midOfHere < elementEnd else {
                return true
            }

            // Pick the first line fragment — for a short one-line
            // paragraph this is the only one. Translate its local
            // typographic bounds back to view coordinates.
            guard let line = fragment.textLineFragments.first else {
                return true
            }
            let localBounds = line.typographicBounds
            let origin = fragment.layoutFragmentFrame.origin

            // Approximate the x-offset of "here" by proportion of
            // its character offset inside the element. This is
            // coarse but sufficient — the test only needs a point
            // that lands on the link text, not on exactly the
            // midpoint glyph. The line is short enough that the
            // proportional mapping lands inside the link.
            let elementLen = max(elementEnd - elementStart, 1)
            let linkOffsetFraction = CGFloat(midOfHere - elementStart) / CGFloat(elementLen)
            let x = origin.x + localBounds.minX + localBounds.width * linkOffsetFraction
            let y = origin.y + localBounds.midY
            hitPoint = NSPoint(x: x, y: y)
            return false
        }

        guard let point = hitPoint else {
            return XCTFail("Could not locate link layout fragment under TK2.")
        }

        // The actual assertion: TK2 resolver returns a character
        // index whose `.link` attribute is non-nil. If this fails,
        // the new TK2 hover path cannot distinguish link text from
        // plain text — link-hover cursor is broken.
        guard let resolvedIndex = harness.editor.characterIndexTK2(at: point) else {
            return XCTFail("characterIndexTK2 returned nil at \(point).")
        }
        XCTAssertGreaterThanOrEqual(resolvedIndex, 0)
        XCTAssertLessThan(resolvedIndex, storage.length)

        // Allow a 1-char tolerance — the proportional mapping may
        // land at the very start/end boundary of the link range.
        // What matters is that the resolved index sits on a run
        // that carries `.link`.
        let linkAtResolved = storage.attribute(.link, at: resolvedIndex, effectiveRange: nil)
        XCTAssertNotNil(
            linkAtResolved,
            "TK2 character index resolver landed on char \(resolvedIndex)" +
            " but storage reports no .link attribute there. The hover" +
            " cursor will stay iBeam instead of pointingHand — see" +
            " Phase 2f.3."
        )
    }
}
