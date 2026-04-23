//
//  Bugs3NoteColorTests.swift
//  FSNotesTests
//
//  Feeds the exact bytes of the iCloud note "FSNotes++ Bugs 3" through the
//  pipeline (parse → project → fill storage) and checks foreground colors
//  on every todo-list line.
//
//  The live app paints this note's todo text invisibly on first load; the
//  working note "FSNote++ Bugs" (in the same folder) renders correctly.
//  The user's hypothesis is a content-specific trigger. This test asserts
//  storage colors for every todo line — if the test fails, the pipeline
//  really does carry a bad color for some range specific to Bugs 3 and we
//  can bisect by content. If the test passes, the pipeline is clean and
//  the bug lives at draw time (TK2 layout fragment / LayoutManager).
//

import XCTest
import AppKit
@testable import FSNotes

final class Bugs3NoteColorTests: XCTestCase {

    /// Loads the exact iCloud file content for each bug-repro note.
    /// Returns nil if the file isn't on disk (e.g. CI sandbox) — skip.
    private func readNote(named name: String) -> String? {
        let path = "/Users/guido/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents/\(name).textbundle/text.md"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Walks the storage and asserts: every line that begins with a todo
    /// marker `- [ ]` or `- [x]` has `.foregroundColor` equal to
    /// `labelColor` (unchecked) or `secondaryLabelColor` (checked) at the
    /// character just after the marker (where the inline text starts).
    private func assertTodoColors(
        in storage: NSTextStorage,
        sourceMarkdown md: String
    ) {
        // Walk the original markdown source to find where each todo line
        // is, then find that line's inline text in storage by searching
        // for the first 12 characters after the marker.
        let lines = md.components(separatedBy: "\n")
        let s = storage.string as NSString

        var checkedCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isUnchecked = trimmed.hasPrefix("- [ ] ")
            let isChecked = trimmed.hasPrefix("- [x] ")
            guard isUnchecked || isChecked else { continue }

            let prefixLen = 6 // "- [ ] " or "- [x] "
            let textStart = String(trimmed.dropFirst(prefixLen))
            // Use a short needle — just enough to be unique per line.
            let needleLen = min(30, textStart.count)
            guard needleLen > 0 else { continue }
            let needle = String(textStart.prefix(needleLen))

            let r = s.range(of: needle)
            guard r.length > 0 else {
                // Some lines will have special chars (backticks, bold);
                // skip if we can't find the prefix verbatim.
                continue
            }

            let color = storage.attribute(
                .foregroundColor,
                at: r.location,
                effectiveRange: nil
            ) as? NSColor

            let expected: NSColor = isUnchecked ? .labelColor : .secondaryLabelColor
            XCTAssertEqual(
                color,
                expected,
                "todo line (\(isChecked ? "checked" : "unchecked")) has \(String(describing: color)) — expected \(expected). Needle='\(needle)'"
            )
            checkedCount += 1
        }
        XCTAssertGreaterThan(checkedCount, 5,
            "did not actually check any todo lines — markdown parse off"
        )
    }

    func test_bugs3_everyTodoLineHasCorrectColorAfterFill() throws {
        guard let md = readNote(named: "FSNotes++ Bugs 3") else {
            throw XCTSkip("FSNotes++ Bugs 3 not on disk at expected iCloud path")
        }
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage after seed")
        }
        assertTodoColors(in: storage, sourceMarkdown: md)
    }

    func test_workingNote_everyTodoLineHasCorrectColorAfterFill() throws {
        guard let md = readNote(named: "FSNote++ Bugs") else {
            throw XCTSkip("FSNote++ Bugs not on disk at expected iCloud path")
        }
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage after seed")
        }
        assertTodoColors(in: storage, sourceMarkdown: md)
    }
}
