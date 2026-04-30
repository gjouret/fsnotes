//
//  BugFsnotesCgtTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-cgt:
//  block-model diagnostic logging must be inert unless explicitly enabled.
//

import XCTest
import Foundation
@testable import FSNotes

final class BugFsnotesCgtTests: XCTestCase {

    func test_bmLogIsNoopUnlessExplicitlyEnabled() throws {
        UserDefaults.standard.removeObject(forKey: "FSNotesBlockModelLogEnabled")
        guard ProcessInfo.processInfo.environment["FSNOTES_BLOCK_MODEL_LOG"] != "1" else {
            throw XCTSkip("Block-model logging is enabled for this test process")
        }

        let before = try? Data(contentsOf: blockModelLogURL)
        bmLog("cgt-regression-\(UUID().uuidString)")
        let after = try? Data(contentsOf: blockModelLogURL)

        XCTAssertEqual(after, before)
    }
}
