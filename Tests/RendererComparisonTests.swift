//
//  RendererComparisonTests.swift
//  FSNotesTests
//
//  Compares MPreview (WKWebView) rendering with NSTextView rendering
//  of the same markdown content and reports pixel-level differences.
//
//  Run via:
//    xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
//      -only-testing:FSNotesTests/RendererComparisonTests
//
//  Output images saved to /tmp/fsnotes_compare/

import XCTest
import AppKit
import WebKit
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

// MARK: - MPreview WKWebView Renderer

private class WebViewRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((NSImage?) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func render(markdown: String, bundlePath: String, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion

        // Convert markdown to HTML using cmark-gfm (same as MPreview)
        let htmlContent = convertMarkdownToHTML(markdown)

        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <link href="main.css?v=1.0.7" rel="stylesheet">
        <link href="styles/github-light.min.css" rel="stylesheet">
        <style>
            code { white-space: pre-wrap !important; }
            body { padding: 15px 20px; max-width: \(Int(renderWidth))px; font-size: 14px; }
        </style>
        </head><body>\(htmlContent)</body></html>
        """

        let bundleURL = URL(fileURLWithPath: bundlePath)
        let tempFile = bundleURL.appendingPathComponent("_compare_temp.html")
        try? html.write(to: tempFile, atomically: true, encoding: .utf8)

        webView.loadFileURL(tempFile, allowingReadAccessTo: bundleURL)
    }

    private func convertMarkdownToHTML(_ markdown: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cmark-gfm")
        process.arguments = [
            "--extension", "table",
            "--extension", "strikethrough",
            "--extension", "autolink",
            "--extension", "tasklist",
            "--unsafe"
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        do {
            try process.run()
        } catch {
            return "<p>Failed to run cmark-gfm: \(error)</p>"
        }

        inputPipe.fileHandleForWriting.write(markdown.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait for layout to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight)

            webView.takeSnapshot(with: config) { image, error in
                // Clean up temp file
                let bundlePath = self.webView.url?.deletingLastPathComponent().path ?? ""
                try? FileManager.default.removeItem(atPath: bundlePath + "/_compare_temp.html")
                self.completion?(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?(nil)
    }
}

// MARK: - NSTextView Renderer

private class TextViewRenderer {
    /// Render markdown through FSNotes' NotesTextProcessor and LayoutManager,
    /// capturing the result as an NSImage.
    func render(markdown: String) -> NSImage? {
        // Set up NSTextStorage with the markdown content
        let textStorage = NSTextStorage(string: markdown)

        // Create the custom LayoutManager (same as FSNotes uses)
        let layoutManager = LayoutManager()
        layoutManager.delegate = layoutManager
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

    // MARK: - Main Comparison Test

    /// Renders the sample markdown through both MPreview (WKWebView) and
    /// NSTextView (with NotesTextProcessor + LayoutManager), then compares
    /// the resulting images pixel by pixel.
    func testRendererComparison() throws {
        // --- Step 1: Locate MPreview.bundle ---
        let bundle = Bundle.main
        let bundlePath: String
        if let mpreviewPath = bundle.path(forResource: "MPreview", ofType: "bundle") {
            bundlePath = mpreviewPath
        } else {
            // Fallback: check relative to the source tree
            let srcRoot = (#filePath as NSString).deletingLastPathComponent
            let fallback = (srcRoot as NSString).appendingPathComponent("../Resources/MPreview.bundle")
            let resolved = (fallback as NSString).standardizingPath
            if fm.fileExists(atPath: resolved) {
                bundlePath = resolved
            } else {
                // Last resort: absolute path
                let absolute = "/Users/guido/Documents/Programming/Claude/fsnotes/Resources/MPreview.bundle"
                guard fm.fileExists(atPath: absolute) else {
                    XCTFail("MPreview.bundle not found")
                    return
                }
                bundlePath = absolute
            }
        }

        // --- Step 2: Render through MPreview (WKWebView) ---
        let mpreviewImage = try renderMPreview(markdown: sampleMarkdown, bundlePath: bundlePath)
        XCTAssertNotNil(mpreviewImage, "MPreview rendering should produce an image")

        guard let mpreviewImg = mpreviewImage else {
            XCTFail("MPreview rendering returned nil")
            return
        }
        let mpreviewSaved = saveImage(mpreviewImg, to: "\(outputDir)/mpreview.png")
        XCTAssertTrue(mpreviewSaved, "Should save MPreview image to \(outputDir)/mpreview.png")

        // --- Step 3: Render through NSTextView ---
        let textViewRenderer = TextViewRenderer()
        let nstextviewImage = textViewRenderer.render(markdown: sampleMarkdown)
        XCTAssertNotNil(nstextviewImage, "NSTextView rendering should produce an image")

        let nstextviewSaved = saveImage(nstextviewImage!, to: "\(outputDir)/nstextview.png")
        XCTAssertTrue(nstextviewSaved, "Should save NSTextView image to \(outputDir)/nstextview.png")

        // --- Step 4: Compare ---
        let (diffPercent, diffImage) = compareImages(mpreviewImage!, nstextviewImage!)

        let diffSaved = saveImage(diffImage, to: "\(outputDir)/diff.png")
        XCTAssertTrue(diffSaved, "Should save diff image to \(outputDir)/diff.png")

        // --- Step 5: Report ---
        print("")
        print("=== Renderer Comparison Results ===")
        print("MPreview image:   \(outputDir)/mpreview.png")
        print("NSTextView image: \(outputDir)/nstextview.png")
        print("Diff image:       \(outputDir)/diff.png")
        print("Pixel difference: \(String(format: "%.2f", diffPercent))%")
        print("Threshold:        \(String(format: "%.1f", maxDifferencePercent))%")
        print("Result:           \(diffPercent <= maxDifferencePercent ? "PASS" : "FAIL")")
        print("===================================")
        print("")

        XCTAssertLessThanOrEqual(
            diffPercent, maxDifferencePercent,
            "Pixel difference (\(String(format: "%.2f", diffPercent))%) exceeds threshold (\(String(format: "%.1f", maxDifferencePercent))%). " +
            "Inspect images at \(outputDir)/ for details."
        )
    }

    // MARK: - Individual Renderer Tests

    /// Verify that MPreview rendering produces a non-blank image.
    func testMPreviewRendersContent() throws {
        let bundle = Bundle.main
        let bundlePath: String
        if let mpreviewPath = bundle.path(forResource: "MPreview", ofType: "bundle") {
            bundlePath = mpreviewPath
        } else {
            bundlePath = "/Users/guido/Documents/Programming/Claude/fsnotes/Resources/MPreview.bundle"
            guard fm.fileExists(atPath: bundlePath) else {
                throw XCTSkip("MPreview.bundle not found")
            }
        }

        let image = try renderMPreview(markdown: "# Hello\n\nWorld", bundlePath: bundlePath)
        XCTAssertNotNil(image)

        // Check that the image isn't entirely white (i.e., content was rendered)
        if let image = image {
            let nonWhitePercent = measureNonWhitePercent(image)
            XCTAssertGreaterThan(nonWhitePercent, 0.1, "MPreview image should contain visible content")
        }
    }

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

    private func renderMPreview(markdown: String, bundlePath: String) throws -> NSImage? {
        let expectation = self.expectation(description: "WKWebView render")
        var result: NSImage?

        let renderer = WebViewRenderer()
        renderer.render(markdown: markdown, bundlePath: bundlePath) { image in
            result = image
            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)
        return result
    }

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
