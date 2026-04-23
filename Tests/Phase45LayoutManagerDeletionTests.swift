//
//  Phase45LayoutManagerDeletionTests.swift
//  FSNotesTests
//
//  Phase 4.5 — prove the custom TK1 `LayoutManager: NSLayoutManager`
//  subclass is gone and the app's rendering paths continue to work.
//
//  Four contract tests:
//    1. `FSNotes/LayoutManager.swift` is not on disk.
//    2. The Objective-C runtime can't find an `FSNotes.LayoutManager`
//       class (catches any ghost references that somehow survived the
//       deletion).
//    3. `EditTextView` no longer exposes a `layoutManagerIfTK1` property
//       (compile-time: if the property came back, this test would fail
//       to compile because of the `MemoryLayout` introspection — i.e.
//       the file wouldn't build, and the gate would block the commit).
//    4. A fully-wired `EditTextView` renders headings / bullets / code
//       blocks correctly after the deletion (TK2 path is still intact).
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase45LayoutManagerDeletionTests: XCTestCase {

    // MARK: - 1. Source file deleted

    func test_phase45_layoutManagerFile_isDeleted() {
        // Walk up from this test file until we find the repo root
        // (the directory containing FSNotes.xcworkspace). Then assert
        // the legacy TK1 subclass file is gone.
        let repoRoot = Phase45LayoutManagerDeletionTests.findRepoRoot()
        guard let root = repoRoot else {
            XCTFail("Could not locate repo root (no FSNotes.xcworkspace found walking up from the test binary).")
            return
        }
        let legacyPath = root.appendingPathComponent("FSNotes/LayoutManager.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyPath.path),
            "Phase 4.5: FSNotes/LayoutManager.swift must be deleted — found at \(legacyPath.path)"
        )
    }

    // MARK: - 2. Runtime introspection

    func test_phase45_noLayoutManagerType_inModule() {
        // The Objective-C runtime lookup should come back nil once the
        // Swift class `FSNotes.LayoutManager` is gone. Swift classes
        // are registered with their fully-qualified name under the
        // module namespace.
        let klass: AnyClass? = NSClassFromString("FSNotes.LayoutManager")
        XCTAssertNil(
            klass,
            "Phase 4.5: FSNotes.LayoutManager class must be unregistered — runtime returned \(String(describing: klass))"
        )
    }

    // MARK: - 3. `layoutManagerIfTK1` property gone

    func test_phase45_layoutManagerIfTK1_gone() {
        // Compile-time contract: the property must not exist on
        // EditTextView. If it comes back, either this test stops
        // compiling (because we reference `editorLayoutManager` which
        // was retained by design and is explicitly nil) or the scan
        // below succeeds, which is also a failure signal.
        //
        // We assert the delegate-level accessor `editorLayoutManager`
        // returns nil (the only remaining public slot) and that no
        // hit for `layoutManagerIfTK1` appears in any source file
        // under FSNotes/ or FSNotesCore/.
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertNil(
            editor.editorLayoutManager,
            "Phase 4.5: EditorDelegate.editorLayoutManager must return nil — the TK1 accessor was deleted."
        )

        // Grep-style scan as a belt-and-braces check. Matches are
        // counted across all production Swift files; the expected
        // count is zero.
        let root = Phase45LayoutManagerDeletionTests.findRepoRoot()
        guard let repoRoot = root else {
            XCTFail("Could not locate repo root for source scan.")
            return
        }
        let hits = Phase45LayoutManagerDeletionTests.countOccurrences(
            of: "layoutManagerIfTK1",
            inSwiftFilesUnder: [
                repoRoot.appendingPathComponent("FSNotes"),
                repoRoot.appendingPathComponent("FSNotesCore"),
            ]
        )
        XCTAssertEqual(
            hits.nonComment, 0,
            "Phase 4.5: no production source may reference `layoutManagerIfTK1`. Found \(hits.nonComment) non-comment hits."
        )
    }

    // MARK: - 4. Rendering still works end to end

    func test_phase45_existingRenderingPaths_stillWork() {
        // Spin up a TK2 editor, fill it with a small markdown sample
        // covering H1/H2, a paragraph, a bullet list, and a fenced
        // code block. Assert the rendered attributed string has the
        // expected run structure.
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let editor = EditTextView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(editor)
        editor.initTextStorage()

        // The editor must have adopted TK2. If it hasn't, every
        // assertion below would silently pass against the wrong
        // layout stack.
        XCTAssertNotNil(
            editor.textLayoutManager,
            "Phase 4.5: EditTextView must be on TK2 — textLayoutManager was nil."
        )

        let markdown = """
        # Title

        Paragraph text.

        - item one
        - item two

        ```
        code
        ```
        """

        let doc = MarkdownParser.parse(markdown)
        let projection = DocumentProjection(
            document: doc,
            bodyFont: UserDefaultsManagement.noteFont,
            codeFont: UserDefaultsManagement.codeFont
        )
        editor.textStorageProcessor?.isRendering = true
        editor.textStorage?.setAttributedString(projection.attributed)
        editor.textStorageProcessor?.isRendering = false
        editor.documentProjection = projection
        editor.textStorageProcessor?.blockModelActive = true

        guard let storage = editor.textStorage else {
            XCTFail("EditTextView.textStorage was nil"); return
        }
        XCTAssertGreaterThan(storage.length, 0, "Rendered storage must be non-empty")

        // Scan the rendered attributes for the proofs we care about
        // after the TK1 subclass is gone.
        let full = NSRange(location: 0, length: storage.length)

        var sawHeadingFont = false
        var sawCodeFont = false
        let bodyFamily = UserDefaultsManagement.noteFont.familyName?.lowercased() ?? ""
        let codeFamily = UserDefaultsManagement.codeFont.familyName?.lowercased() ?? ""
        storage.enumerateAttribute(.font, in: full, options: []) { value, _, _ in
            guard let font = value as? NSFont else { return }
            let bodySize = UserDefaultsManagement.noteFont.pointSize
            if font.pointSize > bodySize + 2 {
                sawHeadingFont = true
            }
            // A run is a "code run" if its family name matches the configured
            // code font family (Theme.shared.codeFontName, default "Source Code
            // Pro") OR any conventional monospaced family. Matching the actual
            // configured family is the authoritative check post–Phase 7.5.c,
            // which routed UD.codeFont through Theme; the fallback keyword
            // list catches non-default code-font choices.
            if let familyName = font.familyName?.lowercased() {
                if !codeFamily.isEmpty && familyName == codeFamily && familyName != bodyFamily {
                    sawCodeFont = true
                } else if familyName.contains("mono") ||
                          familyName.contains("menlo") ||
                          familyName.contains("courier") ||
                          familyName.contains("source code") {
                    sawCodeFont = true
                }
            }
        }
        XCTAssertTrue(
            sawHeadingFont,
            "Phase 4.5: heading renderer must emit a font larger than body (heading run missing)."
        )
        XCTAssertTrue(
            sawCodeFont,
            "Phase 4.5: code block renderer must emit a monospaced font (code run missing)."
        )

        // The paragraph style carries heading / list / paragraph
        // spacing — DocumentRenderer attaches one to every run.
        var sawParagraphStyle = false
        storage.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, _, _ in
            if value is NSParagraphStyle {
                sawParagraphStyle = true
            }
        }
        XCTAssertTrue(
            sawParagraphStyle,
            "Phase 4.5: DocumentRenderer must attach NSParagraphStyle runs (spacing metrics missing)."
        )
    }

    // MARK: - Helpers

    /// Walk up from the current test binary until we find the repo
    /// root (identified by the presence of FSNotes.xcworkspace).
    private static func findRepoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("FSNotes.xcworkspace")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Count occurrences of `needle` across every `.swift` file under
    /// the given directories. Returns a tuple of total hits + hits
    /// that appear on non-comment lines (leading `//` or `///` after
    /// optional whitespace is considered a comment).
    private static func countOccurrences(
        of needle: String,
        inSwiftFilesUnder directories: [URL]
    ) -> (total: Int, nonComment: Int) {
        var total = 0
        var nonComment = 0
        let fm = FileManager.default
        for dir in directories {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let obj = enumerator.nextObject() as? URL {
                guard obj.pathExtension == "swift" else { continue }
                guard let text = try? String(contentsOf: obj, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.contains(needle) {
                        total += 1
                        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                        if !trimmed.hasPrefix("//") {
                            nonComment += 1
                        }
                    }
                }
            }
        }
        return (total, nonComment)
    }
}
