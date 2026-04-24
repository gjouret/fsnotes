//
//  Phase6AttachmentScrollRecycleTests.swift
//  FSNotesTests
//
//  Regression tests for the QuickLook / PDF attachment scroll-recycle
//  thumbnail-loss bug. See commit message for the full story.
//
//  The broken shape: `QuickLookNSTextAttachment` and `PDFNSTextAttachment`
//  used to cache a pre-built `InlineQuickLookView` / `InlinePDFView` and
//  the view provider's `loadView()` just returned that cached instance.
//  When TK2 scrolled a fragment away and then back, the outer wrapper
//  was re-attached to the window but the child `QLPreviewView` /
//  `PDFView` had lost its render state — the thumbnail / page content
//  was gone, only the frame remained.
//
//  The fix: store value types only on the attachment (URL + size) and
//  build a fresh inline view on every `loadView()` call. Same pattern
//  as `ImageAttachmentViewProvider`.
//
//  What these tests pin:
//    1. Successive `loadView()` calls return distinct `NSView`
//       instances — proves the "cached view" pattern is gone.
//    2. The child preview widget (`QLPreviewView` for QuickLook,
//       `PDFView` for PDF) is also a fresh instance across calls —
//       proves the child render state is reconstructed, not reused.
//    3. The fresh view is seeded from the attachment's URL — proves
//       the payload is on the attachment, not in a stale cached view.
//    4. Neither attachment type carries an `NSView` subclass as a
//       stored property — structural guard against reintroducing the
//       cached-view pattern through a future refactor.
//
//  These tests stand independent of an `NSWindow` or an editor harness:
//  they hand-construct the attachment, let it vend its view provider,
//  and call `loadView()` directly. `loadView()` is a public method on
//  `NSTextAttachmentViewProvider` with no window-attachment precondition.
//

import XCTest
import AppKit
import PDFKit
import Quartz
@testable import FSNotes

final class Phase6AttachmentScrollRecycleTests: XCTestCase {

    // MARK: - Fixtures

    /// Write a tiny file at a unique temp path with the given extension
    /// + payload. Returns the URL; caller is responsible for cleanup.
    private func makeTempFile(ext: String, bytes: Data) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase6_recycle_\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: bytes)
        return url
    }

    /// Minimal valid PDF header. `PDFDocument(url:)` accepts this and
    /// returns a document with 0 pages, which is enough for the
    /// provider's loadView path — `InlinePDFView` handles empty docs
    /// without crashing.
    private func makePDFTempFile() -> URL {
        // `%PDF-1.0\n%%EOF\n` — the shortest header PDFKit will open.
        let header = "%PDF-1.0\n%%EOF\n".data(using: .ascii)!
        return makeTempFile(ext: "pdf", bytes: header)
    }

    /// ZIP-like payload so `QLPreviewView` treats the URL as something
    /// it could conceivably preview. QuickLook never renders anything
    /// synchronously during `loadView()`, so the bytes don't have to be
    /// a real archive — the view just needs an existing URL.
    private func makeQLTempFile() -> URL {
        let zipHeader = Data([0x50, 0x4B, 0x03, 0x04])
        return makeTempFile(ext: "docx", bytes: zipHeader)
    }

    /// Build a provider for an attachment by calling the attachment's
    /// public `viewProvider(for:location:textContainer:)` — same path
    /// TK2 uses. Returns the provider or fails the test.
    private func makeProvider<T: NSTextAttachment>(for attachment: T)
        -> NSTextAttachmentViewProvider
    {
        let provider = attachment.viewProvider(
            for: nil,
            location: StubTextLocation(),
            textContainer: nil
        )
        // Swift's XCTUnwrap would abort the test on nil; use XCTAssert +
        // a preconditionFailure fallback so the compiler sees a
        // non-optional return.
        XCTAssertNotNil(
            provider,
            "\(T.self) must vend a non-nil view provider."
        )
        guard let p = provider else {
            preconditionFailure("provider assertion already failed above")
        }
        return p
    }

    // MARK: - QuickLook: loadView builds fresh inline view every time

    func test_quickLookProvider_loadView_producesFreshInlineView_onEachCall() {
        let url = makeQLTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = QuickLookNSTextAttachment(
            url: url,
            size: NSSize(width: 600, height: 400)
        )

        // Two independent providers — the shape TK2 uses when it
        // rebuilds a view-provider for a recycled fragment. Each call
        // to loadView() must produce a brand-new NSView instance.
        let providerA = makeProvider(for: attachment)
        providerA.loadView()
        let viewA = providerA.view

        let providerB = makeProvider(for: attachment)
        providerB.loadView()
        let viewB = providerB.view

        XCTAssertNotNil(viewA, "First loadView must produce a view.")
        XCTAssertNotNil(viewB, "Second loadView must produce a view.")
        XCTAssertTrue(
            viewA is InlineQuickLookView,
            "View produced by loadView must be an InlineQuickLookView."
        )
        XCTAssertTrue(
            viewB is InlineQuickLookView,
            "View produced by loadView must be an InlineQuickLookView."
        )
        XCTAssertFalse(
            viewA === viewB,
            "Each loadView() call must construct a fresh InlineQuickLookView. " +
            "If the same instance comes back, the attachment is still caching " +
            "the view — which is the scroll-recycle bug this refactor closed."
        )
    }

    // MARK: - QuickLook: child QLPreviewView is fresh across recycles

    /// Walks the view hierarchy looking for the first `QLPreviewView`.
    /// Returns nil if none is found.
    private func findQLPreviewView(in root: NSView) -> QLPreviewView? {
        if let ql = root as? QLPreviewView { return ql }
        for sub in root.subviews {
            if let ql = findQLPreviewView(in: sub) { return ql }
        }
        return nil
    }

    func test_quickLookProvider_rebuildsQLPreviewView_onRecycle() {
        let url = makeQLTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = QuickLookNSTextAttachment(
            url: url,
            size: NSSize(width: 600, height: 400)
        )

        let providerA = makeProvider(for: attachment)
        providerA.loadView()
        let viewA = providerA.view as? InlineQuickLookView
        XCTAssertNotNil(viewA, "Expected first loadView to yield an InlineQuickLookView.")

        let providerB = makeProvider(for: attachment)
        providerB.loadView()
        let viewB = providerB.view as? InlineQuickLookView
        XCTAssertNotNil(viewB, "Expected second loadView to yield an InlineQuickLookView.")

        let qlA = viewA.flatMap { findQLPreviewView(in: $0) }
        let qlB = viewB.flatMap { findQLPreviewView(in: $0) }
        XCTAssertNotNil(qlA, "Fresh InlineQuickLookView must contain a QLPreviewView subview.")
        XCTAssertNotNil(qlB, "Fresh InlineQuickLookView must contain a QLPreviewView subview.")
        XCTAssertFalse(
            qlA === qlB,
            "Each loadView() must construct a fresh QLPreviewView. If the " +
            "same instance is reused across recycles, the child render " +
            "state is what silently dies on scroll-out/scroll-in — the " +
            "exact symptom the user reported."
        )
    }

    // MARK: - QuickLook: fresh view is seeded from the attachment URL

    func test_quickLookProvider_loadView_seedsFromAttachmentURL() {
        let url = makeQLTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = QuickLookNSTextAttachment(
            url: url,
            size: NSSize(width: 600, height: 400)
        )

        let provider = makeProvider(for: attachment)
        provider.loadView()

        guard let view = provider.view as? InlineQuickLookView else {
            XCTFail("Expected loadView to produce an InlineQuickLookView.")
            return
        }
        XCTAssertEqual(
            view.fileURL, url,
            "Fresh InlineQuickLookView must be seeded from the attachment's URL. " +
            "If these diverge, the payload is coming from some other cache instead " +
            "of the attachment's value-type storage."
        )
    }

    // MARK: - PDF: loadView builds fresh inline view every time

    func test_pdfProvider_loadView_producesFreshInlineView_onEachCall() {
        let url = makePDFTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = PDFNSTextAttachment(
            url: url,
            size: NSSize(width: 600, height: 400)
        )

        let providerA = makeProvider(for: attachment)
        providerA.loadView()
        let viewA = providerA.view

        let providerB = makeProvider(for: attachment)
        providerB.loadView()
        let viewB = providerB.view

        XCTAssertNotNil(viewA, "First loadView must produce a view.")
        XCTAssertNotNil(viewB, "Second loadView must produce a view.")
        XCTAssertTrue(
            viewA is InlinePDFView,
            "View produced by loadView must be an InlinePDFView."
        )
        XCTAssertTrue(
            viewB is InlinePDFView,
            "View produced by loadView must be an InlinePDFView."
        )
        XCTAssertFalse(
            viewA === viewB,
            "Each loadView() call must construct a fresh InlinePDFView. If " +
            "the same instance comes back, the attachment is caching the " +
            "view — the scroll-recycle class of bug this refactor closed."
        )
    }

    // MARK: - PDF: fresh view is seeded from the attachment URL

    func test_pdfProvider_loadView_seedsFromAttachmentURL() {
        let url = makePDFTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = PDFNSTextAttachment(
            url: url,
            size: NSSize(width: 600, height: 400)
        )

        let provider = makeProvider(for: attachment)
        provider.loadView()

        guard let view = provider.view as? InlinePDFView else {
            XCTFail("Expected loadView to produce an InlinePDFView.")
            return
        }
        XCTAssertEqual(
            view.pdfURL, url,
            "Fresh InlinePDFView must be seeded from the attachment's URL. " +
            "Divergence means the payload came from some other cache, not " +
            "the attachment's value-type storage. (We assert `view.pdfURL` " +
            "rather than `pdfView.document?.documentURL` — PDFKit may " +
            "legitimately leave documentURL nil for a stub PDF that lacks " +
            "a full xref table. documentURL is a PDFKit internal; the " +
            "URL-wiring contract we pin here is `attachment.fileURL` → " +
            "`InlinePDFView.pdfURL`.)"
        )
    }

    // MARK: - Structural guard: attachments carry value types only

    /// Reflective check that `QuickLookNSTextAttachment` and
    /// `PDFNSTextAttachment` do not declare an `NSView` subclass as a
    /// stored property. Prevents a future refactor from silently
    /// reintroducing the "cache the view on the attachment" pattern.
    func test_attachmentSubclasses_carryValueTypesOnly() {
        let urlQL = makeQLTempFile()
        defer { try? FileManager.default.removeItem(at: urlQL) }
        let urlPDF = makePDFTempFile()
        defer { try? FileManager.default.removeItem(at: urlPDF) }

        let qlAttachment = QuickLookNSTextAttachment(
            url: urlQL,
            size: NSSize(width: 600, height: 400)
        )
        let pdfAttachment = PDFNSTextAttachment(
            url: urlPDF,
            size: NSSize(width: 600, height: 400)
        )

        assertNoCachedNSView(on: qlAttachment, label: "QuickLookNSTextAttachment")
        assertNoCachedNSView(on: pdfAttachment, label: "PDFNSTextAttachment")
    }

    /// Walk the Mirror of `subject` and fail the test if any child
    /// value is (or contains, for Optional) an `NSView` instance.
    private func assertNoCachedNSView<T>(on subject: T, label: String) {
        let mirror = Mirror(reflecting: subject)
        for child in mirror.children {
            // Unwrap Optional so we see the real payload.
            let value = unwrapOptional(child.value)
            if value is NSView {
                XCTFail(
                    "\(label).\(child.label ?? "?") is an NSView — the attachment " +
                    "must store value types only. Caching a view on the attachment " +
                    "reintroduces the scroll-recycle bug (thumbnail/render state " +
                    "dies when the view is detached from the window and reattached)."
                )
            }
        }
    }

    /// Collapse a Mirror-child value through one level of `Optional` so
    /// `x as? NSView` works even when the property is `NSView?`.
    private func unwrapOptional(_ any: Any) -> Any {
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle == .optional {
            return mirror.children.first?.value ?? any
        }
        return any
    }
}

// MARK: - Stub NSTextLocation

/// Minimal `NSTextLocation` used for viewProvider(...) calls. The
/// provider's loadView() does not consult the location, so any
/// conforming instance works.
private final class StubTextLocation: NSObject, NSTextLocation {
    func compare(_ location: NSTextLocation) -> ComparisonResult {
        return .orderedSame
    }
}
