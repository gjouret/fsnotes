//
//  Phase5aSingleWritePathTests.swift
//  FSNotesTests
//
//  Phase 5a — unit tests for `StorageWriteGuard` flag lifecycle.
//
//  These tests do not mutate storage. They exercise only the scope-flag
//  machinery that the production debug assertion consumes. The live
//  assertion inside `TextStorageProcessor.didProcessEditing` is
//  exercised by existing pipeline/editor tests under debug builds — any
//  unauthorized character mutation there would trap.
//

import XCTest
@testable import FSNotes

final class Phase5aSingleWritePathTests: XCTestCase {

    func test_phase5a_default_noFlagsSet() {
        XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
        XCTAssertFalse(StorageWriteGuard.fillInFlight)
        XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_performingApplyDocumentEdit_setsAndClears() {
        XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
        StorageWriteGuard.performingApplyDocumentEdit {
            XCTAssertTrue(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
            XCTAssertFalse(StorageWriteGuard.fillInFlight)
            XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        }
        XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_performingFill_setsAndClears() {
        XCTAssertFalse(StorageWriteGuard.fillInFlight)
        StorageWriteGuard.performingFill {
            XCTAssertTrue(StorageWriteGuard.fillInFlight)
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
            XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        }
        XCTAssertFalse(StorageWriteGuard.fillInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_performingLegacyStorageWrite_setsAndClears() {
        XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        StorageWriteGuard.performingLegacyStorageWrite {
            XCTAssertTrue(StorageWriteGuard.legacyStorageWriteInFlight)
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
            XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.fillInFlight)
        }
        XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_nestedScopes_isolate() {
        // Outer applyDocumentEdit + inner fill: both true inside the
        // inner body, outer remains true when inner returns, and both
        // are false after the outer closes. Flag restore is
        // stack-oriented via `defer` — nested prior values are honored.
        StorageWriteGuard.performingApplyDocumentEdit {
            XCTAssertTrue(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.fillInFlight)
            StorageWriteGuard.performingFill {
                XCTAssertTrue(StorageWriteGuard.applyDocumentEditInFlight)
                XCTAssertTrue(StorageWriteGuard.fillInFlight)
                XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
            }
            XCTAssertTrue(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.fillInFlight)
        }
        XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
        XCTAssertFalse(StorageWriteGuard.fillInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_thrown_error_clearsFlag() {
        struct SampleError: Error {}
        XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
        do {
            try StorageWriteGuard.performingApplyDocumentEdit {
                XCTAssertTrue(StorageWriteGuard.applyDocumentEditInFlight)
                throw SampleError()
            }
            XCTFail("expected throw")
        } catch {
            // Flag must be cleared by the `defer` even on throw.
            XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
        }
    }

    func test_phase5a_isAnyAuthorized_tracksAnyFlag() {
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
        StorageWriteGuard.performingApplyDocumentEdit {
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
        }
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
        StorageWriteGuard.performingFill {
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
        }
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
        StorageWriteGuard.performingAttachmentHydration {
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
        }
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
        StorageWriteGuard.performingLegacyStorageWrite {
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
        }
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }

    func test_phase5a_performingAttachmentHydration_setsAndClears() {
        XCTAssertFalse(StorageWriteGuard.attachmentHydrationInFlight)
        StorageWriteGuard.performingAttachmentHydration {
            XCTAssertTrue(StorageWriteGuard.attachmentHydrationInFlight)
            XCTAssertTrue(StorageWriteGuard.isAnyAuthorized)
            // Other scope flags remain off.
            XCTAssertFalse(StorageWriteGuard.applyDocumentEditInFlight)
            XCTAssertFalse(StorageWriteGuard.fillInFlight)
            XCTAssertFalse(StorageWriteGuard.legacyStorageWriteInFlight)
        }
        XCTAssertFalse(StorageWriteGuard.attachmentHydrationInFlight)
        XCTAssertFalse(StorageWriteGuard.isAnyAuthorized)
    }
}
