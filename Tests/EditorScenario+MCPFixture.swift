//
//  EditorScenario+MCPFixture.swift
//  FSNotesTests
//
//  Phase 11 Slice F.6 — MCP-tool happy-path scenario builder.
//
//  The MCP tool tests (and the integration-level AI tool-call suite)
//  exercise a wired `AppBridgeImpl` whose editor is a live
//  `EditorHarness`. For `NotePathResolver` to find the note and for
//  `AppBridgeImpl.isOpen(_:)` to agree with the tool's resolved path,
//  the harness's `note.url` must be repointed at the fixture's seeded
//  file. This factory bundles that two-line setup into a Given/When/
//  Then entry point sibling to `Given.note(...)`.
//

import Foundation
import XCTest
@testable import FSNotes

extension Given {

    /// MCP-flavoured scenario: builds an `EditorScenario` whose
    /// underlying `note.url` matches `url`. Use when the test wires a
    /// real `AppBridgeImpl` over the harness and needs the bridge's
    /// open-note check + the tool's path resolution to agree on the
    /// fixture file's identity.
    ///
    /// The seeded markdown is typically the same string that was
    /// written to disk at `url` so the in-memory projection matches
    /// the file. Pass `markdown` explicitly rather than re-reading
    /// the file — the test author already has the literal in hand.
    static func mcpNote(
        at url: URL,
        markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        let scenario = EditorScenario(
            markdown: markdown,
            activation: .offscreen,
            file: file,
            line: line
        )
        // Repoint the harness's note at the fixture URL so
        // `NotePathResolver` finds it and `AppBridgeImpl.isOpen(_:)`
        // agrees with the tool's resolved path.
        scenario.harness.note.url = url.standardized
        return scenario
    }
}
