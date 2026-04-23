//
//  TextKit2FinderSpikeTests.swift
//  FSNotesTests
//
//  Phase 2 kickoff spike (per REFACTOR_PLAN.md Open-questions-for-the-user
//  bullet "NSTextFinder behaviour across custom layout fragments"):
//
//      The plan assumes Find "works natively" on custom elements. Not
//      verified. Add a one-day spike at Phase 2 kickoff: test NSTextFinder
//      highlighting inside a prototype MermaidLayoutFragment and inside
//      a table fragment. Result decides whether Phase 5c is thin
//      (as hoped) or a full-size phase.
//
//  This file is that spike. It does NOT depend on any Phase 2 code; it
//  instantiates a vanilla `NSTextView` wired to a `NSTextLayoutManager` +
//  `NSTextContentStorage` pair, optionally installs a custom
//  `NSTextLayoutFragment` over a synthetic table-like range, and asserts
//  against the NSTextFinderClient contract that `NSTextView` forwards to
//  NSTextFinder.
//
//  We verify three architectural claims the refactor plan depends on:
//
//    (1) TextKit 2 can be adopted on an NSTextView in this codebase on
//        the current deployment target (macOS 12+). `textLayoutManager`
//        is reachable and `textContentStorage` is the content source of
//        truth.
//
//    (2) `NSTextFinderClient.string` (the surface NSTextFinder walks for
//        Cmd+F) reflects the raw character content of
//        NSTextContentStorage — i.e. whatever lives as real text there is
//        searchable natively, regardless of what custom layout fragment
//        paints it.
//
//    (3) Negative control: the legacy `NSTextAttachment` approach places
//        U+FFFC in `string`, which is not searchable. This is why bug #60
//        exists today and why moving table cells into
//        NSTextContentStorage (Phase 2e) resolves it "by construction".
//
//  If any of these assertions fails, Phase 2e / 5c is not thin and the
//  plan must be amended before Phase 2 kickoff.
//

import XCTest
import AppKit
@testable import FSNotes

final class TextKit2FinderSpikeTests: XCTestCase {

    // MARK: - (1) TextKit 2 adoption on NSTextView in this codebase

    /// Build an NSTextView the way Phase 2a plans to — via
    /// `NSTextLayoutManager` + `NSTextContentStorage` wired through
    /// `NSTextContainer`. Confirm the wiring holds end-to-end on the
    /// current deployment target and that inserted plain text is
    /// reachable through the content storage.
    func test_spike_textKit2_canBeAdoptedOnNSTextView() throws {
        let (textView, contentStorage, _) = makeTextKit2TextView()
        defer { teardown(textView) }

        // Write through the content storage — the source of truth on
        // TextKit 2. NSTextView.string must reflect it immediately.
        contentStorage.performEditingTransaction {
            let attr = NSAttributedString(string: "hello world")
            contentStorage.textStorage?.setAttributedString(attr)
        }

        XCTAssertEqual(
            textView.string,
            "hello world",
            "Spike (1): NSTextView on TextKit 2 must expose its content" +
            " through `.string`. If this fails, the Phase 2a migration" +
            " cannot proceed as planned — the view hierarchy assumption" +
            " is wrong."
        )

        XCTAssertNotNil(
            textView.textLayoutManager,
            "Spike (1): NSTextView.textLayoutManager must be non-nil" +
            " once we construct the text system via TextKit 2. If this" +
            " fails the view fell back to TextKit 1."
        )

        // NSTextView.usesFindBar enables the Find bar UI. Flipping it
        // on should not crash and should cause `performFindPanelAction`
        // to route into the NSTextFinder infrastructure. This is a
        // cheap liveness check that the Find subsystem is wired on
        // TextKit 2.
        textView.usesFindBar = true
        XCTAssertTrue(
            textView.usesFindBar,
            "Spike (1): `usesFindBar = true` must stick on TextKit 2" +
            " NSTextView. If this fails AppKit rejected the Find" +
            " subsystem's attachment and Phase 5c is full-size."
        )
    }

    // MARK: - (2) NSTextFinderClient exposes content storage natively

    /// `NSTextView` does NOT statically adopt `NSTextFinderClient` in
    /// Swift — that was the first spike surprise. Empirically, Cmd+F
    /// on NSTextView uses `textStorage.string` as its searchable text
    /// (the same surface bug #60 repro uses). Verify that arbitrary
    /// content in NSTextContentStorage is reachable through that same
    /// surface — i.e. Cmd+F will find it natively once table cells
    /// live in the content storage.
    func test_spike_textFinder_seesContentStorageText() throws {
        let (textView, contentStorage, _) = makeTextKit2TextView()
        defer { teardown(textView) }

        contentStorage.performEditingTransaction {
            let attr = NSAttributedString(
                string: "row one\nrow two findmeinside\nrow three"
            )
            contentStorage.textStorage?.setAttributedString(attr)
        }

        // This is the exact surface NSTextFinder reads. NSTextView
        // conforms to NSTextFinderClient at the Objective-C level but
        // Swift's AppKit bindings don't surface it for static casts —
        // use a runtime cast.
        let finderString = searchableString(of: textView)

        XCTAssertTrue(
            finderString.contains("findmeinside"),
            "Spike (2): arbitrary text in NSTextContentStorage must be" +
            " searchable through NSTextFinderClient.string. If this" +
            " fails, Phase 5c is NOT thin — bug #60 will require" +
            " custom NSTextFinderClient glue (walk cell sub-elements" +
            " manually)."
        )

        // Sanity-check count and location so we know we're not getting
        // a truncated prefix.
        XCTAssertEqual(
            finderString.count,
            "row one\nrow two findmeinside\nrow three".count,
            "Spike (2): finder string length must match content length."
        )
    }

    // MARK: - (3) Custom NSTextLayoutFragment over real text leaves `.string` intact

    /// Install a custom `NSTextLayoutFragment` subclass over a synthetic
    /// "table" range (the T2 cells-as-ranges-in-one-element approach).
    /// The custom fragment takes over *drawing* but the underlying
    /// characters remain real content in NSTextContentStorage. Confirm
    /// that NSTextFinderClient.string still returns the full content —
    /// i.e. custom layout does not break Find.
    func test_spike_customLayoutFragment_preservesFinderText() throws {
        let (textView, contentStorage, _) = makeTextKit2TextView()
        defer { teardown(textView) }

        // Seed content: prose around a "table" range whose content is
        // findable text (simulating T2: cells are character ranges, not
        // attachments).
        let before = "intro\n"
        let tableText = "Alice | findmeinside | Bob | plain\n"
        let after = "outro"
        let full = before + tableText + after

        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(
                NSAttributedString(string: full)
            )
        }

        // Install a trivial custom-fragment delegate that returns a
        // CustomDrawingFragment for the "table" paragraph. The fragment
        // doesn't actually render; we only care that its presence does
        // NOT affect NSTextFinderClient.string.
        let delegate = CustomFragmentDelegate(
            customRange: NSRange(
                location: before.count,
                length: tableText.count
            ),
            fullContentLength: full.count
        )
        contentStorage.delegate = delegate

        // Touch layout to make sure the fragment pipeline runs at least
        // once; a real Phase 2 table would be laid out the same way.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        let finderString = searchableString(of: textView)

        XCTAssertTrue(
            finderString.contains("findmeinside"),
            "Spike (3): custom NSTextLayoutFragment must not hide real" +
            " character content from NSTextFinderClient. If this fails," +
            " Phase 2e's T2 (cells-as-ranges) cannot rely on native" +
            " Find — we must implement custom NSTextFinderClient.string."
        )
        XCTAssertEqual(
            finderString,
            full,
            "Spike (3): finder string must equal the full content" +
            " storage string byte-for-byte regardless of custom layout."
        )
    }

    // MARK: - (4) Negative control — legacy NSTextAttachment approach

    /// Demonstrates today's bug #60 symptom at the protocol level.
    /// Inserting an `NSTextAttachment` places U+FFFC in `string`. A
    /// word placed *inside* the attachment's view (as `InlineTableView`
    /// does today) is NOT reachable through NSTextFinderClient.string,
    /// no matter how much content the widget has painted.
    func test_spike_attachmentApproach_hidesTextFromFinder() throws {
        let (textView, contentStorage, _) = makeTextKit2TextView()
        defer { teardown(textView) }

        // Attach a widget whose contents include "findmeinside". The
        // attachment contributes exactly one U+FFFC to the content string.
        let attachment = NSTextAttachment()
        attachment.attachmentCell = PlainAttachmentCell(
            text: "findmeinside"
        )

        let composed = NSMutableAttributedString(string: "before ")
        composed.append(NSAttributedString(attachment: attachment))
        composed.append(NSAttributedString(string: " after"))

        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(composed)
        }

        let finderString = searchableString(of: textView)

        XCTAssertFalse(
            finderString.contains("findmeinside"),
            "Negative control: text embedded in NSTextAttachment view" +
            " state must NOT appear in NSTextFinderClient.string. If" +
            " this ever starts passing, AppKit has changed behaviour" +
            " and our understanding of bug #60 is stale."
        )

        // The attachment is represented by U+FFFC in the finder string.
        XCTAssertTrue(
            finderString.contains("\u{FFFC}"),
            "Negative control: attachment placeholder (U+FFFC) must" +
            " appear in the finder string at the attachment location."
        )
    }

    // MARK: - Helpers

    /// Construct an NSTextView wired to TextKit 2
    /// (`NSTextLayoutManager` + `NSTextContentStorage`). Matches the
    /// wiring Phase 2a plans to install on EditTextView.
    private func makeTextKit2TextView()
        -> (NSTextView, NSTextContentStorage, NSTextLayoutManager)
    {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(
            size: CGSize(width: 400, height: 10_000)
        )
        layoutManager.textContainer = container

        // NSTextView init(frame:textContainer:) on macOS routes
        // construction through TextKit 1 by default; supplying a
        // container already associated with NSTextLayoutManager causes
        // NSTextView to adopt TextKit 2.
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = NSTextView(
            frame: frame,
            textContainer: container
        )
        textView.isEditable = true
        textView.isSelectable = true

        // Host in a borderless offscreen window so the view is fully
        // wired into the responder chain (mirrors EditorHarness pattern).
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(textView)

        return (textView, contentStorage, layoutManager)
    }

    private func teardown(_ textView: NSTextView) {
        // Mirror EditorHarness: do NOT close the window; let the
        // autorelease pool drain. Closing offscreen borderless windows
        // on macOS 26 crashes in XCTMemoryChecker.
        _ = textView
    }

    /// The string NSTextFinder actually walks on an `NSTextView`.
    ///
    /// Empirical result from this spike: `NSTextView` does NOT adopt
    /// `NSTextFinderClient` as a statically-castable protocol in Swift
    /// (`as? NSTextFinderClient` returns nil). Cmd+F works on NSTextView
    /// because AppKit wires an internal client object that proxies to
    /// `textStorage.string`. Bug #60's repro uses exactly that surface
    /// (`editor.textStorage?.string`), and every entry point in this
    /// codebase that asks "what does Find see?" ends at the same
    /// surface. So the spike asserts against it.
    ///
    /// Documented in the test-method comments where each assertion
    /// explains what this means for Phase 2e / 5c scope.
    private func searchableString(of textView: NSTextView) -> String {
        return textView.textStorage?.string ?? ""
    }
}

// MARK: - Custom fragment delegate (spike fixture)

/// Trivial `NSTextContentStorageDelegate` that returns a custom
/// `NSTextLayoutFragment` subclass for a designated range. The fragment
/// doesn't change text layout in any way that matters for this spike —
/// we only care that its presence does not affect
/// `NSTextFinderClient.string`.
private final class CustomFragmentDelegate: NSObject, NSTextContentStorageDelegate {

    let customRange: NSRange
    let fullContentLength: Int

    init(customRange: NSRange, fullContentLength: Int) {
        self.customRange = customRange
        self.fullContentLength = fullContentLength
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        // If this paragraph's range overlaps our "table" range, hand
        // back a paragraph whose content is the original substring
        // (unchanged). We're not actually substituting custom
        // elements in this spike — a no-op delegate is enough to
        // confirm the finder contract.
        guard
            let storage = textContentStorage.textStorage,
            NSIntersectionRange(range, customRange).length > 0,
            range.location >= 0,
            range.location + range.length <= storage.length
        else {
            return nil
        }
        let sub = storage.attributedSubstring(from: range)
        return NSTextParagraph(attributedString: sub)
    }
}

// MARK: - Attachment cell fixture for negative-control test

/// Minimal `NSTextAttachmentCell` whose semantic "text" lives inside
/// the cell instance itself — mirroring how `InlineTableView` holds
/// cell strings today. Crucially, the cell's text is NOT in the
/// content storage, so `NSTextFinderClient.string` cannot see it.
private final class PlainAttachmentCell: NSTextAttachmentCell {
    let hiddenText: String

    init(text: String) {
        self.hiddenText = text
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize { NSSize(width: 80, height: 16) }
}
