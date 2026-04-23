//
//  ReferenceHTMLWriter.swift
//  FSNotesTests
//
//  Regenerates the committed HTML-proxy reference renditions for every
//  corpus file. The resulting `*.html` files live alongside the `*.md`
//  source files in `Tests/Corpus/` and are checked into git so diffs
//  surface unintended changes to either the block-model pipeline or
//  DocumentHTMLRenderer.
//
//  Gated on an environment variable so the test is not destructive by
//  default. To regenerate:
//
//      FSNOTES_WRITE_HTML_REFS=1 xcodebuild test \
//          -workspace FSNotes.xcworkspace -scheme FSNotes \
//          -only-testing:FSNotesTests/ReferenceHTMLWriterTests/test_writeCorpusReferences
//
//  Without the env var the test logs what it *would* write and skips.
//

import XCTest
@testable import FSNotes

final class ReferenceHTMLWriterTests: XCTestCase {

    /// Source-of-truth folder: the live corpus inside the repo. We do
    /// NOT write into the test bundle — those files are read-only and
    /// not committed under the .md sources anyway.
    private var corpusFolderOnDisk: URL? {
        // File lives at Tests/ReferenceHTMLWriter.swift; corpus lives at Tests/Corpus/.
        // #filePath resolves at compile time to the Tests folder.
        let thisFile = URL(fileURLWithPath: #filePath)
        let testsFolder = thisFile.deletingLastPathComponent()
        let corpusFolder = testsFolder.appendingPathComponent("Corpus", isDirectory: true)
        guard FileManager.default.fileExists(atPath: corpusFolder.path) else {
            return nil
        }
        return corpusFolder
    }

    func test_writeCorpusReferences() throws {
        // Two ways to enable the write:
        //   1. env var FSNOTES_WRITE_HTML_REFS=1 (works from Xcode scheme).
        //   2. sentinel file at /tmp/fsnotes_write_html_refs (works from
        //      `xcodebuild test-without-building`, which strips env vars).
        // Either one flips the gate. Both absent → skip.
        let env = ProcessInfo.processInfo.environment
        let sentinelExists = FileManager.default.fileExists(
            atPath: "/tmp/fsnotes_write_html_refs"
        )
        let writeEnabled = env["FSNOTES_WRITE_HTML_REFS"] == "1" || sentinelExists

        guard let corpus = corpusFolderOnDisk else {
            throw XCTSkip("Corpus folder not resolvable from #filePath")
        }

        let fm = FileManager.default
        let mdFiles = try fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(mdFiles.isEmpty, "Corpus folder is empty at \(corpus.path)")

        // TCC blocks the test process from writing into repo paths
        // under ~/Documents. Stage the regenerated HTML into /tmp and
        // let the human operator (or a follow-up Bash step) copy the
        // files into place. Writing to /tmp also means we can
        // regenerate on CI without special entitlements.
        // ~/unit-tests is the repo-standard writable directory for
        // test artifacts (debug builds are not sandboxed, per CLAUDE.md).
        // Writing here makes the regenerated files easy to find for
        // the human step of copying them into Tests/Corpus/.
        let stagingDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("unit-tests", isDirectory: true)
            .appendingPathComponent("fsnotes-corpus-refs", isDirectory: true)
        if writeEnabled {
            try FileManager.default.createDirectory(
                at: stagingDir,
                withIntermediateDirectories: true
            )
            print("[ReferenceHTMLWriter] Staging refs at: \(stagingDir.path)")
        }

        var wouldWrite: [(String, Int)] = []
        for mdURL in mdFiles {
            let markdown = try String(contentsOf: mdURL, encoding: .utf8)
            let document = MarkdownParser.parse(markdown)
            let html = DocumentHTMLRenderer.render(document)

            let htmlName = mdURL.deletingPathExtension()
                .appendingPathExtension("html")
                .lastPathComponent
            if writeEnabled {
                let stagingURL = stagingDir.appendingPathComponent(htmlName)
                try html.data(using: .utf8)?.write(to: stagingURL)
            } else {
                wouldWrite.append((htmlName, html.count))
            }
        }

        if !writeEnabled {
            let summary = wouldWrite
                .map { "\($0.0) (\($0.1) bytes)" }
                .joined(separator: ", ")
            throw XCTSkip(
                "FSNOTES_WRITE_HTML_REFS not set — would have written: \(summary)"
            )
        }
    }

    /// Non-gated guard: on every test run, diff each committed `.html`
    /// reference against what the current pipeline would produce. A
    /// mismatch means either the pipeline or DocumentHTMLRenderer
    /// changed semantics and the corpus references need regeneration.
    func test_committedReferencesMatchCurrentPipeline() throws {
        guard let corpus = corpusFolderOnDisk else {
            throw XCTSkip("Corpus folder not resolvable from #filePath")
        }

        let fm = FileManager.default
        let mdFiles = try fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var checked = 0
        for mdURL in mdFiles {
            let htmlURL = mdURL.deletingPathExtension().appendingPathExtension("html")
            guard fm.fileExists(atPath: htmlURL.path) else {
                // Reference hasn't been generated yet. Not a failure
                // until someone flips the switch. The writer test
                // above is the generator.
                continue
            }

            let markdown = try String(contentsOf: mdURL, encoding: .utf8)
            let committed = try String(contentsOf: htmlURL, encoding: .utf8)
            let actual = DocumentHTMLRenderer.render(MarkdownParser.parse(markdown))

            XCTAssertEqual(
                committed, actual,
                "HTML reference for \(mdURL.lastPathComponent) does not match current pipeline. " +
                "Re-generate with FSNOTES_WRITE_HTML_REFS=1 xcodebuild test ..."
            )
            checked += 1
        }

        // We don't assert `checked > 0` here because the initial check-in
        // goes in as a separate commit. Once the reference HTML files
        // land, every subsequent run validates against them.
    }
}
