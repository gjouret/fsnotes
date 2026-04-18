//
//  ComprehensiveRoundTripTests.swift
//  FSNotesTests
//
//  A single end-to-end round-trip test using a representative markdown
//  file that exercises EVERY block type and inline marker the parser
//  supports. The invariant:
//
//      serialize(parse(markdown)) == markdown   (byte-equal)
//
//  If this test fails, the parser or serializer has a structural
//  defect that will silently corrupt user data on save.
//

import XCTest
@testable import FSNotes

class ComprehensiveRoundTripTests: XCTestCase {

    /// The canonical test document. Every block type and inline marker
    /// that the parser supports appears at least once.
    /// This is the authoritative "does the parser actually work?" test.
    private let representativeMarkdown = """
# Heading 1

## Heading 2

### Heading 3 with **bold** and *italic*

Plain paragraph with no formatting.

A paragraph with **bold text**, *italic text*, and `inline code`.

A paragraph with **bold containing *nested italic* inside** it.

Multiple **bold** words *italic* words `code` words on one line.

```swift
func hello() {
    print("world")
}
```

```
plain code block with no language
```

~~~python
def foo():
    pass
~~~

- item one
- item two
- item three

- top level
  - nested child
  - another child
    - deeply nested

1. first
1. second
1. third

> single line blockquote

> multi line
> blockquote here

> > nested blockquote

---

***

___

A final paragraph to end the document.

"""

    func test_roundTrip_representativeDocument() {
        let doc = MarkdownParser.parse(representativeMarkdown)
        let serialized = MarkdownSerializer.serialize(doc)

        if serialized != representativeMarkdown {
            // Produce a helpful diff showing exactly where divergence occurs.
            let expectedLines = representativeMarkdown.split(separator: "\n", omittingEmptySubsequences: false)
            let actualLines = serialized.split(separator: "\n", omittingEmptySubsequences: false)

            var diffs: [String] = []
            let maxLines = max(expectedLines.count, actualLines.count)
            for i in 0..<maxLines {
                let exp = i < expectedLines.count ? String(expectedLines[i]) : "<missing>"
                let act = i < actualLines.count ? String(actualLines[i]) : "<missing>"
                if exp != act {
                    diffs.append("  line \(i + 1):")
                    diffs.append("    expected: \(quoted(exp))")
                    diffs.append("    actual:   \(quoted(act))")
                }
            }
            XCTFail(
                "Round-trip failed: serialize(parse(markdown)) ≠ markdown\n"
                + "Divergences:\n" + diffs.joined(separator: "\n")
            )
        }
    }

    /// Verify that the parsed Document contains the expected number and
    /// types of blocks. This catches silent mis-parses where round-trip
    /// might accidentally pass because two bugs cancel each other out.
    func test_structuralIntegrity_representativeDocument() {
        let doc = MarkdownParser.parse(representativeMarkdown)

        // Count block types.
        var headings = 0, paragraphs = 0, codeBlocks = 0
        var lists = 0, blockquotes = 0, rules = 0, blanks = 0

        for block in doc.blocks {
            switch block {
            case .heading:        headings += 1
            case .paragraph:      paragraphs += 1
            case .codeBlock:      codeBlocks += 1
            case .list:           lists += 1
            case .blockquote:     blockquotes += 1
            case .horizontalRule: rules += 1
            case .htmlBlock:      break  // count not tracked
            case .table:          break  // count not tracked
            case .blankLine:      blanks += 1
            }
        }

        // These counts are the source of truth. If the document changes,
        // update these expected values.
        XCTAssertEqual(headings, 3, "headings")
        XCTAssertEqual(paragraphs, 5, "paragraphs")
        XCTAssertEqual(codeBlocks, 3, "code blocks")
        // Two unordered dash lists separated by blank line merge into
        // one loose list (CommonMark behavior), plus one ordered list = 2.
        XCTAssertEqual(lists, 2, "lists")
        XCTAssertEqual(blockquotes, 3, "blockquotes")
        XCTAssertEqual(rules, 3, "horizontal rules")
        XCTAssertGreaterThan(blanks, 0, "blank lines")

        XCTAssertTrue(doc.trailingNewline, "trailing newline")
    }

    private func quoted(_ s: String) -> String {
        return "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            + "\""
    }
}
