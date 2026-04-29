//
//  BugFsnotes5fbTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-5fb (P1):
//  "Test suite hangs on HeaderTests.test_headerFonts_areBold"
//
//  Verifiable property: the original test must complete within a
//  bounded time. The scaffold runs the same SourceRenderer-driven
//  pipeline that the original test exercises, on a background queue
//  with a watchdog timeout. Bug exists → watchdog fires → test fails.
//  Bug fixed → completes well under timeout → test passes.
//
//  The original test is the contract; we don't restate the H1-H6 bold
//  property here (HeaderTests.test_headerFonts_areBold:147 already
//  asserts it). What we add is the *liveness* assertion the original
//  lacked, which is exactly what the bead describes.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes5fbTests: XCTestCase {

    /// Watchdog timeout. The original test is a few hundred ms in the
    /// healthy case; 10 s gives us a 10–100x margin so we don't false-
    /// alarm on a slow CI runner while still catching a true hang.
    private let watchdogSeconds: TimeInterval = 10.0

    func test_headerFontPipeline_completesUnderWatchdog() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let markdown = "# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6\n"

        let done = expectation(description: "header-pipeline-completes")

        // The pipeline mutates AppKit objects and so must run on the
        // main thread. We schedule the work via the main queue and use
        // `wait(for:timeout:)` on the current (test) thread to provide
        // the watchdog. If the pipeline hangs, the run loop never
        // reaches `done.fulfill()` and the wait times out.
        DispatchQueue.main.async {
            let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            let container = NSTextContainer(size: frame.size)
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(container)
            let storage = NSTextStorage()
            storage.addLayoutManager(layoutManager)

            let editor = EditTextView(frame: frame, textContainer: container)
            editor.initTextStorage()

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(editor)

            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("BugFsnotes5fb_\(UUID().uuidString).md")
            try? "placeholder".write(to: tmp, atomically: true, encoding: .utf8)
            let project = Project(
                storage: Storage.shared(),
                url: tmp.deletingLastPathComponent()
            )
            let note = Note(url: tmp, with: project)
            editor.note = note

            editor.textStorage?.setAttributedString(
                NSMutableAttributedString(string: markdown)
            )
            note.content = NSMutableAttributedString(
                attributedString: editor.textStorage!
            )
            editor.textStorageProcessor?.sourceRendererActive = true
            editor.textStorage?.beginEditing()
            editor.textStorage?.edited(
                .editedCharacters,
                range: NSRange(location: 0, length: editor.textStorage!.length),
                changeInLength: 0
            )
            editor.textStorage?.endEditing()
            // Brief run-loop spin to let processor finish, identical to
            // the original test. If anything in this path hangs (the
            // bug), we never reach `done.fulfill()`.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            done.fulfill()
        }

        wait(for: [done], timeout: watchdogSeconds)
    }
}
