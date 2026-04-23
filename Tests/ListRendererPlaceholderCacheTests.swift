//
//  ListRendererPlaceholderCacheTests.swift
//  FSNotesTests
//
//  Phase 7.5.a P1c — memoize `ListRenderer.transparentPlaceholder`.
//
//  The helper creates a sized blank `NSImage` used as a placeholder on
//  `NSTextAttachment` during the window between TK2's first layout
//  pass and the attachment view provider's `loadView` completing. A
//  500-bullet note triggers 500 allocations + `lockFocus`/`unlockFocus`
//  pairs per render — wasteful given there are typically only a
//  handful of distinct sizes in play.
//
//  Contract under test:
//    - Same size → same `===` image instance (cache hit).
//    - Different sizes → different instances (cache keys independent).
//    - Both images are the requested size.
//

import XCTest
import Cocoa
@testable import FSNotes

final class ListRendererPlaceholderCacheTests: XCTestCase {

    // MARK: - Cache hit on identical size

    /// Two calls with the same `CGSize` must return the same instance
    /// (`===`). That's the whole point of the memoization.
    func test_P1c_sameSizeReturnsIdenticalInstance() {
        let size = CGSize(width: 12, height: 16)
        let first = ListRenderer.transparentPlaceholder(size: size)
        let second = ListRenderer.transparentPlaceholder(size: size)

        XCTAssertTrue(
            first === second,
            "Placeholder must be memoized by size — same CGSize should return the same NSImage instance"
        )
        XCTAssertEqual(first.size, size)
    }

    // MARK: - Different sizes → different instances

    /// Distinct sizes must not collide in the cache.
    func test_P1c_differentSizesReturnDifferentInstances() {
        let bulletSize = CGSize(width: 12, height: 16)
        let checkboxSize = CGSize(width: 18, height: 18)
        let tableSize = CGSize(width: 200, height: 40)

        let bullet = ListRenderer.transparentPlaceholder(size: bulletSize)
        let checkbox = ListRenderer.transparentPlaceholder(size: checkboxSize)
        let table = ListRenderer.transparentPlaceholder(size: tableSize)

        XCTAssertFalse(
            bullet === checkbox,
            "Bullet placeholder must not collide with checkbox placeholder"
        )
        XCTAssertFalse(
            bullet === table,
            "Bullet placeholder must not collide with table placeholder"
        )
        XCTAssertFalse(
            checkbox === table,
            "Checkbox placeholder must not collide with table placeholder"
        )

        XCTAssertEqual(bullet.size, bulletSize)
        XCTAssertEqual(checkbox.size, checkboxSize)
        XCTAssertEqual(table.size, tableSize)
    }

    // MARK: - Burst at one size amortizes to a single allocation

    /// A note with many bullets at one body font size hits the cache on
    /// every call after the first. Sanity check: 50 calls at one size
    /// all return the same instance.
    func test_P1c_manyCallsAtOneSizeHitCache() {
        let size = CGSize(width: 14, height: 18)
        let first = ListRenderer.transparentPlaceholder(size: size)
        for _ in 0..<50 {
            let next = ListRenderer.transparentPlaceholder(size: size)
            XCTAssertTrue(
                next === first,
                "Every subsequent call at the same size must return the cached instance"
            )
        }
    }
}
