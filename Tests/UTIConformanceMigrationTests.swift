//
//  UTIConformanceMigrationTests.swift
//  FSNotesTests
//
//  Phase 9.b — Tier 2 UTType migration regression net.
//
//  The migration from `UTTypeConformsTo` / `UTTypeCopyPreferredTagWithClass`
//  (CoreServices C API on `CFString`) to `UTType.conforms(to:)` /
//  `UTType.preferredMIMEType` / `UTType.preferredFilenameExtension` is
//  semantic-preserving in theory, but tag-class lookups have subtle edge
//  cases. This file pins the resolutions used by `URL+.swift` and
//  `UTI.swift` against a corpus of extensions and MIME types so any future
//  platform shift in UTType behaviour fails here first rather than as a
//  file-dialog quirk or drag-drop regression.
//

import XCTest
import UniformTypeIdentifiers
@testable import FSNotes

final class UTIConformanceMigrationTests: XCTestCase {

    // MARK: - URL+.swift — fileUTType / isImage / isVideo / mimeType

    /// Every extension that feeds `URL.fileUTType` in the wild must resolve
    /// to a non-nil `UTType`. If the platform stops recognising one of
    /// these, the editor's drag-drop and media-embed code will start
    /// dropping content silently — this test surfaces it loudly.
    func test_common_extensions_resolve_to_UTType() throws {
        let extensions = [
            "md", "markdown", "txt", "textbundle",
            "png", "jpg", "jpeg", "gif", "tiff", "webp", "svg",
            "pdf",
            "mov", "mp4", "m4v", "avi",
            "rtf", "html"
        ]
        for ext in extensions {
            let uti = UTType(filenameExtension: ext)
            XCTAssertNotNil(uti, "extension .\(ext) should resolve to a UTType")
        }
    }

    /// `isImage` must return true for every raster/vector format the
    /// renderer needs to embed, and false for obvious non-images.
    func test_isImage_covers_known_image_types() {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "svg"]
        for ext in imageExtensions {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertTrue(url.isImage, ".\(ext) should be isImage == true")
            XCTAssertFalse(url.isVideo, ".\(ext) should not be isVideo")
        }

        let nonImage = URL(fileURLWithPath: "/tmp/sample.pdf")
        XCTAssertFalse(nonImage.isImage, ".pdf must not be isImage")
    }

    /// `isVideo` must return true for every movie format the editor
    /// accepts as a drop target, and false for images / documents.
    func test_isVideo_covers_known_video_types() {
        let videoExtensions = ["mov", "mp4", "m4v", "avi"]
        for ext in videoExtensions {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertTrue(url.isVideo, ".\(ext) should be isVideo == true")
            XCTAssertFalse(url.isImage, ".\(ext) should not be isImage")
        }

        let nonVideo = URL(fileURLWithPath: "/tmp/sample.png")
        XCTAssertFalse(nonVideo.isVideo, ".png must not be isVideo")
    }

    /// Resolved MIME types must match canonical IANA values for common
    /// web-safe formats. `preferredMIMEType` is documented as matching
    /// registered IANA types; if the platform ever returns a vendor-prefixed
    /// alternative for one of these, downstream network / export code
    /// would silently degrade.
    func test_mimeType_resolutions_match_iana() {
        let cases: [(ext: String, expected: String)] = [
            ("png",  "image/png"),
            ("jpg",  "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("gif",  "image/gif"),
            ("pdf",  "application/pdf"),
            ("svg",  "image/svg+xml"),
            ("html", "text/html")
        ]
        for c in cases {
            let url = URL(fileURLWithPath: "/tmp/sample.\(c.ext)")
            XCTAssertEqual(url.mimeType, c.expected,
                           "mimeType for .\(c.ext) should be \(c.expected)")
        }
    }

    /// Unknown extensions fall back to the generic octet-stream.
    func test_mimeType_falls_back_to_octet_stream() {
        let url = URL(fileURLWithPath: "/tmp/sample.zzzzz-no-such-ext")
        XCTAssertEqual(url.mimeType, "application/octet-stream")
    }

    // MARK: - UTI.swift — String extensions

    /// `String.utiMimeType` treats the receiver as a UTI and returns the
    /// preferred MIME. Post-migration this is `UTType(self)?.preferredMIMEType`.
    func test_String_utiMimeType_resolves_known_utis() {
        let cases: [(uti: String, expected: String)] = [
            ("public.png",        "image/png"),
            ("public.jpeg",       "image/jpeg"),
            ("com.adobe.pdf",     "application/pdf"),
            ("public.html",       "text/html")
        ]
        for c in cases {
            XCTAssertEqual(c.uti.utiMimeType, c.expected,
                           "utiMimeType for \(c.uti) should be \(c.expected)")
        }
    }

    /// `String.mimeTypeUTI` treats the receiver as a MIME type string and
    /// returns the canonical UTI identifier.
    func test_String_mimeTypeUTI_resolves_known_mime_types() {
        XCTAssertEqual("image/png".mimeTypeUTI, "public.png")
        XCTAssertEqual("application/pdf".mimeTypeUTI, "com.adobe.pdf")
    }

    /// `String.fileExtensionUTI` treats the receiver as a filename extension
    /// and returns the canonical UTI identifier.
    func test_String_fileExtensionUTI_resolves_known_extensions() {
        XCTAssertEqual("png".fileExtensionUTI, "public.png")
        XCTAssertEqual("pdf".fileExtensionUTI, "com.adobe.pdf")
    }

    // MARK: - Unknown-input asymmetry
    //
    // The three `UTType` initializers behave differently on inputs the
    // system does not recognize. The earlier single "nil for everything"
    // test conflated them; the tests below pin each leg of the asymmetry
    // so a future platform shift surfaces at the correct site.
    //
    // Empirically on current macOS:
    //
    //   - `UTType(filenameExtension:)` synthesises a dynamic `dyn.*`
    //     identifier for any syntactically valid extension it does not
    //     recognize. The synthesised type conforms to `.data`. Therefore
    //     `String.fileExtensionUTI` is NOT nil for unknown extensions.
    //
    //   - `UTType(mimeType:)` ALSO synthesises a dynamic UTI when the
    //     input is well-formed `type/subtype` shape (e.g.
    //     `application/x-foo`). It returns nil only when the input is
    //     not MIME-shaped at all (no slash, etc.). This contradicts the
    //     initial framing that MIME lookup "never synthesises"; the real
    //     dividing line is input well-formedness, not corpus membership.
    //
    //   - `UTType(_: String)` parses its argument as a UTI identifier
    //     (reverse-DNS or `dyn.*` shape). Freeform strings containing
    //     whitespace or other non-identifier characters return nil, so
    //     `String.utiMimeType` is nil for garbage input.

    /// Unknown filename extensions are synthesised into a dynamic UTI
    /// whose identifier starts with `dyn.` and whose type conforms to
    /// `.data`. This is Apple's documented fallback, not a migration bug.
    func test_unknown_extension_returns_dynamic_UTI() {
        let dynIdent = "zzzzz-no-such-ext".fileExtensionUTI
        XCTAssertNotNil(dynIdent,
                        "unknown extensions synthesise a dynamic UTI (not nil)")
        XCTAssertTrue(dynIdent?.hasPrefix("dyn.") ?? false,
                      "dynamic UTI identifier should start with 'dyn.' (got \(dynIdent ?? "nil"))")
        if let ident = dynIdent, let uti = UTType(ident) {
            XCTAssertTrue(uti.conforms(to: .data),
                          "synthesised dynamic UTI must conform to .data")
        } else {
            XCTFail("dynamic UTI failed to round-trip through UTType(_:)")
        }
    }

    /// Malformed MIME strings (no `type/subtype` shape) return nil.
    /// `UTType(mimeType:)` DOES synthesise dynamic UTIs for well-formed
    /// but unknown MIME types — see the block comment above — so the nil
    /// boundary is shape, not corpus membership.
    func test_malformed_mime_type_returns_nil() {
        XCTAssertNil("not-a-mime-type".mimeTypeUTI,
                     "MIME strings without a slash must return nil")
    }

    /// Garbage input to `UTType(_: String)` (freeform, non-UTI-shaped)
    /// returns nil — the initializer only accepts reverse-DNS or `dyn.*`
    /// identifiers.
    func test_unknown_uti_identifier_returns_nil() {
        XCTAssertNil("this is definitely not a UTI".utiMimeType,
                     "garbage UTI identifier must return nil")
    }

    // MARK: - Conformance relationships

    /// Sanity checks on `UTType.conforms(to:)` for the exact hierarchy used
    /// inside `URL.isVideo` / `URL.isImage`. This guards against a future
    /// change in UTI graph that would silently widen or narrow what counts.
    func test_conformance_relationships_used_by_URL_ext() {
        guard
            let png = UTType(filenameExtension: "png"),
            let mov = UTType(filenameExtension: "mov"),
            let pdf = UTType(filenameExtension: "pdf")
        else {
            XCTFail("required extensions failed to resolve")
            return
        }

        XCTAssertTrue(png.conforms(to: .image))
        XCTAssertFalse(png.conforms(to: .movie))

        XCTAssertTrue(mov.conforms(to: .movie))
        XCTAssertTrue(mov.conforms(to: .quickTimeMovie))
        XCTAssertFalse(mov.conforms(to: .image))

        XCTAssertFalse(pdf.conforms(to: .image))
        XCTAssertFalse(pdf.conforms(to: .movie))
    }
}
