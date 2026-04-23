//
//  Phase47SaveConsolidationTests.swift
//  FSNotesTests
//
//  Phase 4.7 — `NoteSerializer.prepareForSave()` + `Note.save(content:)`
//  deleted. All save paths route through `Note.save(markdown:)`.
//
//  These tests pin the invariants of that consolidation:
//    1. Block-model saves produce canonical markdown that round-trips
//       back through `MarkdownParser` + `MarkdownSerializer` unchanged.
//    2. Source-mode saves are byte-preserving — the user's typed bytes
//       hit disk verbatim (no Document canonicalization).
//    3. `Note.save(markdown:)` uses atomic file writes.
//    4. `NoteSerializer` is gone at the type level; `Note.save(content:)`
//       is gone at the symbol level. Grep tests verify the file changes.
//
#if os(OSX)
import XCTest
import AppKit
@testable import FSNotes

final class Phase47SaveConsolidationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase47-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        tempDir = dir
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func makeNote(name: String = "test") -> Note {
        let project = Project(storage: Storage.shared(), url: tempDir)
        let url = tempDir.appendingPathComponent("\(name).md")
        let note = Note(url: url, with: project)
        note.type = .Markdown
        return note
    }

    // MARK: - (1) Block-model save: canonical round-trip

    func test_phase47_blockModelSave_writesCanonicalMarkdown() {
        let input = """
        # Title

        Paragraph with **bold** and *italic*.

        - item one
        - item two

        ```swift
        let x = 42
        ```

        """
        let doc = MarkdownParser.parse(input)
        let canonical = MarkdownSerializer.serialize(doc)

        let note = makeNote(name: "canonical")
        note.save(markdown: canonical)

        // Read back from disk.
        let readBack = try? String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(readBack, canonical)

        // Parse the written output — it should produce the same Document.
        let readDoc = MarkdownParser.parse(readBack ?? "")
        XCTAssertEqual(
            MarkdownSerializer.serialize(readDoc),
            canonical,
            "block-model saved markdown must round-trip through parse+serialize unchanged"
        )
    }

    // MARK: - (2) Source-mode save: byte-preserving

    func test_phase47_sourceModeSave_preservesUserBytes() {
        // Non-canonical formatting that a user might type:
        //  - trailing spaces on a line
        //  - tab indentation
        //  - non-canonical table pipe alignment
        //  - unicode (accents, CJK, emoji)
        let input = "# Title  \n\nHello\t世界 é 🌍\n\n" +
                    "|a|b|\n|-|-|\n|1|2|\n"
        let note = makeNote(name: "source")
        note.save(markdown: input)

        let readBack = try? String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(readBack, input, "source-mode save must preserve user bytes verbatim")
    }

    // MARK: - (3) Atomic file write

    func test_phase47_save_atomicFileWrite() {
        // The only way to verify atomic writes from the outside is to
        // confirm that a save of an existing file does not produce a
        // partial/corrupt file. The `Note.save(markdown:)` path flows
        // through `write(attributedString:)` which uses
        // `FileWrapper.write(to:options: .atomic, ...)`.
        //
        // Write-then-rewrite-then-read proves the final state is correct.
        let note = makeNote(name: "atomic")
        note.save(markdown: "version 1\n")
        XCTAssertEqual(try? String(contentsOf: note.url, encoding: .utf8), "version 1\n")

        note.save(markdown: "version 2 — replaced atomically\n")
        XCTAssertEqual(
            try? String(contentsOf: note.url, encoding: .utf8),
            "version 2 — replaced atomically\n"
        )

        // Sanity — the file still exists as a regular file (not a
        // directory, which atomic writes under some error conditions
        // can produce if the mechanics aren't right).
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.url.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue)
    }

    // MARK: - (4) Grep-level guarantee — NoteSerializer symbol gone

    func test_phase47_noNoteSerializerReference() {
        // This test deliberately does NOT reference `NoteSerializer` —
        // if it did, the compiler would flag the missing type.
        //
        // Instead we verify the file has been deleted on disk so the
        // repo state matches the symbol state.
        let fm = FileManager.default
        // Start from THIS file, walk up to repo root (find `.git`).
        let thisFile = URL(fileURLWithPath: #filePath)
        var cur = thisFile.deletingLastPathComponent()
        var foundRoot: URL?
        for _ in 0..<8 {
            let gitDir = cur.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                foundRoot = cur
                break
            }
            cur = cur.deletingLastPathComponent()
        }
        guard let repoRoot = foundRoot else {
            XCTFail("couldn't locate repo root from \(thisFile.path)")
            return
        }
        let noteSerializerPath = repoRoot
            .appendingPathComponent("FSNotesCore")
            .appendingPathComponent("Rendering")
            .appendingPathComponent("NoteSerializer.swift")
        XCTAssertFalse(
            fm.fileExists(atPath: noteSerializerPath.path),
            "Phase 4.7 deleted NoteSerializer.swift — it must not reappear on disk"
        )
    }

    // MARK: - Additional corpus round-trip guarantee

    func test_phase47_corpusRoundTrip_saveAndReload() {
        // Simulate a realistic note with attachments & rendered blocks
        // already unloaded (post-block-model serialization).
        let markdown = """
        # Heading

        Intro paragraph with a [link](https://example.com).

        ![diagram](assets/example.png)

        ```mermaid
        graph TD; A-->B;
        ```

        - [x] checked
        - [ ] unchecked

        End.
        """
        let note = makeNote(name: "corpus")
        note.save(markdown: markdown)

        let readBack = try? String(contentsOf: note.url, encoding: .utf8)
        XCTAssertEqual(readBack, markdown)

        // The Document parsed from the saved bytes must round-trip
        // through the serializer to the same canonical form.
        let doc = MarkdownParser.parse(readBack ?? "")
        let canonical = MarkdownSerializer.serialize(doc)
        let doc2 = MarkdownParser.parse(canonical)
        XCTAssertEqual(MarkdownSerializer.serialize(doc2), canonical)
    }

    // MARK: - Dogfood: full test corpus round-trips through save(markdown:)

    /// For every `Tests/Corpus/*.md` file:
    ///   (a) parse into a Document
    ///   (b) serialize to canonical markdown
    ///   (c) write via `Note.save(markdown:)`
    ///   (d) read back — bytes must match the canonical form
    ///   (e) re-parse the read-back and confirm stable round-trip
    /// This is the closest we get to a dogfood sweep without real-app
    /// keystrokes; the user will still validate on real notes.
    func test_phase47_dogfood_corpusFiles() {
        let thisFile = URL(fileURLWithPath: #filePath)
        let corpusDir = thisFile.deletingLastPathComponent()
            .appendingPathComponent("Corpus")
        let fm = FileManager.default
        guard fm.fileExists(atPath: corpusDir.path) else {
            XCTFail("corpus directory missing: \(corpusDir.path)")
            return
        }
        let mdFiles = (try? fm.contentsOfDirectory(atPath: corpusDir.path))?
            .filter { $0.hasSuffix(".md") && !$0.contains(" 2.md") }
            ?? []
        XCTAssertGreaterThan(mdFiles.count, 0, "expected corpus markdown files")

        for file in mdFiles.sorted() {
            let src = corpusDir.appendingPathComponent(file)
            guard let input = try? String(contentsOf: src, encoding: .utf8) else {
                XCTFail("couldn't read corpus file: \(file)")
                continue
            }
            let doc = MarkdownParser.parse(input)
            let canonical = MarkdownSerializer.serialize(doc)

            let note = makeNote(name: "dogfood-\(file)")
            note.save(markdown: canonical)

            guard let readBack = try? String(contentsOf: note.url, encoding: .utf8) else {
                XCTFail("[\(file)] save produced no readable file")
                continue
            }
            XCTAssertEqual(readBack, canonical,
                           "[\(file)] save(markdown:) must preserve canonical bytes exactly")

            let doc2 = MarkdownParser.parse(readBack)
            XCTAssertEqual(MarkdownSerializer.serialize(doc2), canonical,
                           "[\(file)] round-trip stable under parse+serialize")
        }
    }
}
#endif
