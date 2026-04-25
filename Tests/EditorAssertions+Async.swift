//
//  EditorAssertions+Async.swift
//  FSNotesTests
//
//  Phase 11 Slice D — async-hydration `Then.*` readbacks.
//
//  Production hydration paths that finish AFTER the synchronous fill /
//  edit cycle:
//    - Mermaid / math / display-math fragments call `BlockRenderer.render`
//      (offscreen WKWebView snapshot) and store the resulting NSImage on
//      the fragment when the JS callback fires on the main queue.
//    - `ImageAttachmentHydrator.hydrate` reads the file off
//      `editor.imagesLoaderQueue` and installs the loaded image (and its
//      bounds) on the placeholder NSTextAttachment when the load
//      completes back on main.
//    - Inline-math `renderInlineMathViaBlockModel` replaces the
//      `.inlineMathSource`-tagged source characters with a rendered
//      attachment whose `bounds.y == -|font.descender|`
//      (`InlineMathBaseline.bounds(imageSize:font:)`).
//
//  Synchronous tests miss these paths entirely. Slice D adds the
//  `eventually(within:)` polling primitive plus three readbacks that
//  use it:
//
//      Given.note(markdown: "...mermaid...")
//          .Then.mermaidBlock(at: 0).hasRendered
//              .eventually(within: 2.0)
//
//      Given.note(markdown: "![](x.png)")
//          .Then.image(at: 0).attachmentBounds.isNonZero
//              .eventually(within: 2.0)
//
//      Given.note(markdown: "Text $x$ here")
//          .Then.inlineMath(at: 4).baselineAlignedWith(textBaseline: ...)
//              .eventually(within: 2.0)
//
//  The polling loop drives `RunLoop.current.run(mode: .default,
//  before:)` so async dispatches and WKWebView callbacks have a chance
//  to fire between predicate evaluations. A single read-only
//  instrumentation hook (`MermaidLayoutFragment.hasRenderedImage` /
//  `MathLayoutFragment.hasRenderedImage`) is exposed in production
//  code per the Slice D spec — no behavioural change.
//

import XCTest
import AppKit
@testable import FSNotes

// MARK: - Polling primitive

/// Wrapper produced by an async-shaped readback. Holds a predicate
/// (returns true once the async work has completed) and a failure
/// message builder (called only on timeout). `eventually(within:)`
/// is the load-bearing call: it polls the predicate every ~50ms,
/// driving the run loop between attempts so async work can fire,
/// and fails XCTest if the timeout expires before the predicate
/// passes.
struct EventuallyAssertion {
    let parent: EditorAssertions
    let predicate: () -> Bool
    let failureMessage: () -> String

    /// Poll `predicate` until it returns true OR `timeout` seconds
    /// have elapsed. On timeout, fail with `failureMessage()`
    /// suffixed with the actual elapsed time. Returns the parent
    /// `EditorAssertions` so chains keep composing.
    @discardableResult
    func eventually(
        within timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorAssertions {
        let start = Date()
        // Fast path — predicate already true (cache hit, sync render).
        if predicate() { return parent }

        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            // Drive the run loop so DispatchQueue.main async blocks,
            // WKWebView snapshot callbacks, and URLSession completions
            // get a chance to run. `run(mode:before:)` returns when
            // the date passes OR a source fires — either is fine.
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(pollInterval)
            )
            if predicate() { return parent }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTFail(
            "\(failureMessage()) (polled for \(String(format: "%.2f", elapsed))s, " +
            "timeout=\(String(format: "%.2f", timeout))s).",
            file: file, line: line
        )
        return parent
    }
}

// MARK: - Then.mermaidBlock(at:) / Then.math / Then.image / Then.inlineMath

extension EditorAssertions {

    /// Locator for a mermaid block at a given block index in the
    /// document. Pairs with `.hasRendered.eventually(within:)` to
    /// poll until the WKWebView snapshot completes and the fragment
    /// stores the rendered NSImage.
    func mermaidBlock(at idx: Int) -> MermaidBlockAssertion {
        return MermaidBlockAssertion(parent: self, blockIdx: idx)
    }

    /// Locator for a math (display) block at a given block index in
    /// the document. Pairs with `.hasRendered.eventually(within:)`.
    func mathBlock(at idx: Int) -> MathBlockAssertion {
        return MathBlockAssertion(parent: self, blockIdx: idx)
    }

    /// Locator for an image attachment by storage offset. Pairs with
    /// `.attachmentBounds.isNonZero.eventually(within:)`.
    func image(at storageOffset: Int) -> ImageAttachmentAssertion {
        return ImageAttachmentAssertion(parent: self, location: storageOffset)
    }

    /// Locator for an inline-math attachment that has hydrated at the
    /// given storage offset. The hydration replaces source characters
    /// with an NSTextAttachment whose bounds are baseline-aligned via
    /// `InlineMathBaseline.bounds(imageSize:font:)`.
    func inlineMath(at storageOffset: Int) -> InlineMathAssertion {
        return InlineMathAssertion(parent: self, location: storageOffset)
    }
}

// MARK: - Mermaid block readback

struct MermaidBlockAssertion {
    let parent: EditorAssertions
    let blockIdx: Int

    /// True once the `MermaidLayoutFragment` for `blockIdx` has its
    /// `renderedImage` populated AND the fragment frame is non-zero.
    /// Production fragments call `ensureRenderRequested()` from
    /// `draw(at:in:)`; this readback drives that draw via the harness's
    /// `renderFragmentToBitmap` helper before returning the predicate.
    /// Cache-hit renders fire synchronously; cache-miss renders fire
    /// asynchronously on the main queue.
    var hasRendered: EventuallyAssertion {
        let editor = parent.scenario.editor
        let blockIdx = self.blockIdx
        let scenario = parent.scenario

        // Trigger one draw pass so `ensureRenderRequested` fires. The
        // first call kicks off `BlockRenderer.render`; cache hits
        // populate `renderedImage` on the same call, cache misses
        // schedule the main-queue completion that the polling loop
        // will then observe.
        _ = scenario.harness.renderFragmentToBitmap(
            blockIndex: blockIdx,
            fragmentClass: "MermaidLayoutFragment"
        )

        return EventuallyAssertion(
            parent: parent,
            predicate: {
                guard let frag = AsyncReadbackHelpers.fragment(
                    forBlockIndex: blockIdx,
                    in: editor
                ) as? MermaidLayoutFragment else { return false }
                return frag.hasRenderedImage
                    && frag.layoutFragmentFrame.height > 0
            },
            failureMessage: {
                "Then.mermaidBlock(at: \(blockIdx)).hasRendered: " +
                "fragment renderedImage still nil after polling."
            }
        )
    }
}

// MARK: - Math block readback (display math via fragment)

struct MathBlockAssertion {
    let parent: EditorAssertions
    let blockIdx: Int

    /// True once the `MathLayoutFragment` for `blockIdx` has its
    /// `renderedImage` populated. Same shape as the mermaid readback.
    var hasRendered: EventuallyAssertion {
        let editor = parent.scenario.editor
        let blockIdx = self.blockIdx
        let scenario = parent.scenario

        _ = scenario.harness.renderFragmentToBitmap(
            blockIndex: blockIdx,
            fragmentClass: "MathLayoutFragment"
        )

        return EventuallyAssertion(
            parent: parent,
            predicate: {
                guard let frag = AsyncReadbackHelpers.fragment(
                    forBlockIndex: blockIdx,
                    in: editor
                ) as? MathLayoutFragment else { return false }
                return frag.hasRenderedImage
                    && frag.layoutFragmentFrame.height > 0
            },
            failureMessage: {
                "Then.mathBlock(at: \(blockIdx)).hasRendered: " +
                "fragment renderedImage still nil after polling."
            }
        )
    }
}

// MARK: - Image attachment readback

struct ImageAttachmentAssertion {
    let parent: EditorAssertions
    let location: Int

    /// Wraps an attachment-bounds predicate. Currently exposes
    /// `isNonZero` — pairs with `.eventually(within:)` to poll until
    /// `ImageAttachmentHydrator` has assigned a non-zero bounds rect.
    var attachmentBounds: ImageAttachmentBoundsAssertion {
        return ImageAttachmentBoundsAssertion(parent: parent, location: location)
    }
}

struct ImageAttachmentBoundsAssertion {
    let parent: EditorAssertions
    let location: Int

    /// True once the `NSTextAttachment` at `location` has bounds
    /// strictly larger than the 1×1 placeholder
    /// (`InlineRenderer.imageAttachmentPlaceholderSize`).
    /// `ImageAttachmentHydrator.hydrate` resizes the placeholder to the
    /// loaded image's natural size (clamped to container width).
    /// Pre-hydration the bounds are 1×1; post-hydration they're the
    /// real image dimensions.
    var isNonZero: EventuallyAssertion {
        let editor = parent.scenario.editor
        let location = self.location
        return EventuallyAssertion(
            parent: parent,
            predicate: {
                guard let storage = editor.textStorage,
                      location < storage.length,
                      let attachment = storage.attribute(
                        .attachment, at: location, effectiveRange: nil
                      ) as? NSTextAttachment
                else { return false }
                let b = attachment.bounds
                // Strictly larger than the 1×1 placeholder.
                return b.size.width > 1.5 || b.size.height > 1.5
            },
            failureMessage: {
                let probe: NSTextAttachment? = {
                    guard let storage = editor.textStorage,
                          location < storage.length else { return nil }
                    return storage.attribute(
                        .attachment, at: location, effectiveRange: nil
                    ) as? NSTextAttachment
                }()
                let b = probe?.bounds ?? .zero
                return "Then.image(at: \(location)).attachmentBounds.isNonZero: " +
                    "attachment bounds=\(b) (still placeholder-sized) after polling."
            }
        )
    }
}

// MARK: - Inline math baseline readback

struct InlineMathAssertion {
    let parent: EditorAssertions
    let location: Int

    /// Hydration is complete when an NSTextAttachment exists at this
    /// location whose `.renderedBlockType == "math"` AND whose
    /// `bounds.origin.y == -|font.descender|` for the surrounding text
    /// font. Catches the math-baseline regression (commit `1095395` is
    /// the pure-fn fix; this is the live verification that the
    /// post-hydration attachment matches `InlineMathBaseline.bounds`).
    func baselineAlignedWith(textBaseline font: NSFont) -> EventuallyAssertion {
        let editor = parent.scenario.editor
        let location = self.location
        let expectedY = -abs(font.descender)
        return EventuallyAssertion(
            parent: parent,
            predicate: {
                guard let storage = editor.textStorage,
                      location < storage.length,
                      let attachment = storage.attribute(
                        .attachment, at: location, effectiveRange: nil
                      ) as? NSTextAttachment
                else { return false }
                let kind = storage.attribute(
                    .renderedBlockType, at: location, effectiveRange: nil
                ) as? String
                guard kind == RenderedBlockType.math.rawValue else { return false }
                let b = attachment.bounds
                guard b.size.width > 0 && b.size.height > 0 else { return false }
                return abs(b.origin.y - expectedY) < 0.5
            },
            failureMessage: {
                let probeAttachment: NSTextAttachment? = {
                    guard let storage = editor.textStorage,
                          location < storage.length else { return nil }
                    return storage.attribute(
                        .attachment, at: location, effectiveRange: nil
                    ) as? NSTextAttachment
                }()
                let bounds = probeAttachment?.bounds ?? .zero
                return "Then.inlineMath(at: \(location)).baselineAlignedWith: " +
                    "expected bounds.y=\(expectedY) (-|descender|), " +
                    "got bounds=\(bounds)."
            }
        )
    }
}

// MARK: - Shared helpers

fileprivate enum AsyncReadbackHelpers {
    /// Locate a layout fragment by block index. Mirrors the helper in
    /// `EditorAssertions.swift` (kept fileprivate there) so the async
    /// readbacks don't depend on its internal accessibility.
    static func fragment(
        forBlockIndex blockIdx: Int, in editor: EditTextView
    ) -> NSTextLayoutFragment? {
        guard let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage,
              let projection = editor.documentProjection,
              blockIdx >= 0,
              blockIdx < projection.blockSpans.count
        else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        let target = projection.blockSpans[blockIdx].location
        let docStart = cs.documentRange.location
        var found: NSTextLayoutFragment? = nil
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let er = fragment.textElement?.elementRange else {
                return true
            }
            let charIndex = cs.offset(from: docStart, to: er.location)
            if charIndex == target {
                found = fragment
                return false
            }
            return true
        }
        return found
    }
}
