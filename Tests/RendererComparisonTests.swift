//
//  RendererComparisonTests.swift
//  FSNotesTests
//
//  Tests NSTextView WYSIWYG rendering of markdown content.
//
//  Run via:
//    xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
//      -only-testing:FSNotesTests/RendererComparisonTests
//
//  Output images saved to /tmp/fsnotes_compare/

import XCTest
import AppKit
@testable import FSNotes

// MARK: - Configuration

private let outputDir = "/tmp/fsnotes_compare"
private let renderWidth: CGFloat = 800
private let renderHeight: CGFloat = 2000
private let maxDifferencePercent: Double = 5.0

// MARK: - Sample Markdown (mirrors "10. Markdown formatting" note)

private let sampleMarkdown = """
# Markdown Formatting

This document tests all common markdown elements for visual parity
between the WKWebView preview and the NSTextView editor.

## Headers with bottom border

### Third level header

#### Fourth level header

Normal text after header.

---

## Text Formatting

This is **bold text** and *italic text* and ***bold italic***.

This is ~~strikethrough~~ text.

## Blockquotes

> A blockquote paragraph.
> Second line of quote.

> Another quote block for testing multi-paragraph quotes.

## Lists

- Bullet one
- Bullet two
- Nested bullet

1. Numbered one
2. Numbered two
3. Numbered three

- [ ] Todo unchecked
- [x] Todo checked

## Links

[FSNotes](https://fsnot.es)

https://github.com

## Code

Inline `code` here and `another code span`.

```python
def hello():
    print("world")

for i in range(10):
    print(i)
```

```swift
let x = 42
print("Hello, \\(x)")
```

## Table

| Left | Center | Right |
|:-----|:------:|------:|
| L1   | C1     | R1    |
| L2   | C2     | R2    |

## Horizontal Rule

---

## Mixed Content

Here is a paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).

> A final blockquote with **bold inside**.
"""

// MARK: - NSTextView Renderer

private class TextViewRenderer {
    /// Render markdown through FSNotes' NotesTextProcessor and a base
    /// NSLayoutManager, capturing the result as an NSImage.
    ///
    /// Phase 4.5: previously used the custom `LayoutManager` subclass
    /// (bullets, HR lines, kbd boxes via `drawBackground`). Those
    /// visuals now live in TK2 layout fragments, so this comparison
    /// renderer falls back to the base `NSLayoutManager`; the image
    /// will lack those embellishments.
    func render(markdown: String) -> NSImage? {
        // Set up NSTextStorage with the markdown content
        let textStorage = NSTextStorage(string: markdown)

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        // Create a text container matching our render width
        let containerSize = NSSize(width: renderWidth - 40, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(containerSize: containerSize)
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 10
        layoutManager.addTextContainer(textContainer)

        // Apply FSNotes' markdown highlighting (full document pass)
        // This is the same call path as TextStorageProcessor.process() for a full load
        NotesTextProcessor.highlight(attributedString: textStorage)

        // Apply paragraph style (tab stops, indentation) like FSNotes does
        textStorage.updateParagraphStyle()

        // Force full layout
        layoutManager.ensureLayout(for: textContainer)

        // Determine actual used height
        let usedRect = layoutManager.usedRect(for: textContainer)
        let imageHeight = min(ceil(usedRect.height) + 40, renderHeight)
        let imageSize = NSSize(width: renderWidth, height: imageHeight)

        // Create the NSTextView for drawing (needed by LayoutManager's drawing methods)
        let textView = NSTextView(frame: NSRect(origin: .zero, size: imageSize), textContainer: textContainer)
        textView.backgroundColor = .white
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 20, height: 20)

        // Render to an image
        let image = NSImage(size: imageSize)
        image.lockFocusFlipped(true)

        guard let context = NSGraphicsContext.current else {
            image.unlockFocus()
            return nil
        }

        // Fill white background
        context.cgContext.setFillColor(NSColor.white.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: imageSize))

        // Draw the text content using the layout manager
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let drawOrigin = NSPoint(x: 20, y: 20)

        layoutManager.drawBackground(forGlyphRange: glyphRange, at: drawOrigin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: drawOrigin)

        image.unlockFocus()
        return image
    }
}

// MARK: - Image Comparison Utilities

private func saveImage(_ image: NSImage, to path: String) -> Bool {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

/// Pixel-by-pixel comparison of two images.
/// Returns the difference percentage (0.0 = identical, 100.0 = completely different)
/// and a diff image highlighting differences in red.
private func compareImages(_ img1: NSImage, _ img2: NSImage) -> (diffPercent: Double, diffImage: NSImage) {
    let width = Int(max(img1.size.width, img2.size.width))
    let height = Int(max(img1.size.height, img2.size.height))

    // Create bitmap representations
    guard let rep1 = bitmapRep(for: img1, width: width, height: height),
          let rep2 = bitmapRep(for: img2, width: width, height: height) else {
        let empty = NSImage(size: NSSize(width: width, height: height))
        return (100.0, empty)
    }

    // Create diff bitmap
    let diffRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    )!

    var differentPixels = 0
    let totalPixels = width * height
    let threshold: Int = 32 // Per-channel difference threshold to count as "different"

    for y in 0..<height {
        for x in 0..<width {
            let c1 = rep1.colorAt(x: x, y: y) ?? .white
            let c2 = rep2.colorAt(x: x, y: y) ?? .white

            let r1 = Int(c1.redComponent * 255)
            let g1 = Int(c1.greenComponent * 255)
            let b1 = Int(c1.blueComponent * 255)
            let r2 = Int(c2.redComponent * 255)
            let g2 = Int(c2.greenComponent * 255)
            let b2 = Int(c2.blueComponent * 255)

            let dr = abs(r1 - r2)
            let dg = abs(g1 - g2)
            let db = abs(b1 - b2)

            if dr > threshold || dg > threshold || db > threshold {
                differentPixels += 1
                // Mark difference in red on a dimmed version of img1
                let diffColor = NSColor(
                    red: CGFloat(min(dr * 3, 255)) / 255.0,
                    green: 0,
                    blue: 0,
                    alpha: 1.0
                )
                diffRep.setColor(diffColor, atX: x, y: y)
            } else {
                // Non-different area: show dimmed version of img1
                let dimmed = NSColor(
                    red: c1.redComponent * 0.3 + 0.7,
                    green: c1.greenComponent * 0.3 + 0.7,
                    blue: c1.blueComponent * 0.3 + 0.7,
                    alpha: 1.0
                )
                diffRep.setColor(dimmed, atX: x, y: y)
            }
        }
    }

    let diffPercent = totalPixels > 0 ? (Double(differentPixels) / Double(totalPixels)) * 100.0 : 0.0

    let diffImage = NSImage(size: NSSize(width: width, height: height))
    diffImage.addRepresentation(diffRep)

    return (diffPercent, diffImage)
}

/// Convert an NSImage to a bitmap representation at the specified pixel dimensions.
private func bitmapRep(for image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    )

    guard let rep = rep else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx

    // White background
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Draw the image scaled to fill
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
               from: NSRect(origin: .zero, size: image.size),
               operation: .sourceOver,
               fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Test Class

class RendererComparisonTests: XCTestCase {

    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Renderer Tests

    /// Verify that NSTextView rendering with NotesTextProcessor produces a non-blank image.
    func testNSTextViewRendersContent() {
        let renderer = TextViewRenderer()
        let image = renderer.render(markdown: "# Hello\n\nWorld")
        XCTAssertNotNil(image)

        if let image = image {
            let nonWhitePercent = measureNonWhitePercent(image)
            XCTAssertGreaterThan(nonWhitePercent, 0.1, "NSTextView image should contain visible content")
        }
    }

    /// Verify that NotesTextProcessor.highlight() applies header fonts.
    func testHighlighterAppliesHeaderFont() {
        let text = "# Big Header\n\nNormal text"
        let storage = NSMutableAttributedString(string: text)
        NotesTextProcessor.highlight(attributedString: storage)

        // The header text should have a larger font than normal text
        if storage.length > 2 {
            let headerFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            let normalFont = storage.attribute(.font, at: storage.length - 2, effectiveRange: nil) as? NSFont

            if let hf = headerFont, let nf = normalFont {
                XCTAssertGreaterThan(hf.pointSize, nf.pointSize,
                    "Header font (\(hf.pointSize)pt) should be larger than normal font (\(nf.pointSize)pt)")
            }
        }
    }

    // MARK: - Helpers

    /// Measure what percentage of pixels are non-white (i.e., have content).
    private func measureNonWhitePercent(_ image: NSImage) -> Double {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        guard let rep = bitmapRep(for: image, width: width, height: height) else { return 0 }

        var nonWhiteCount = 0
        let total = width * height
        let whiteThreshold: CGFloat = 0.95

        for y in 0..<height {
            for x in 0..<width {
                if let color = rep.colorAt(x: x, y: y) {
                    if color.redComponent < whiteThreshold ||
                       color.greenComponent < whiteThreshold ||
                       color.blueComponent < whiteThreshold {
                        nonWhiteCount += 1
                    }
                }
            }
        }

        return total > 0 ? (Double(nonWhiteCount) / Double(total)) * 100.0 : 0
    }
}
