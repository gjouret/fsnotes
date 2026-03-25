#!/usr/bin/env swift
// compare_renderers.swift
// Renders the same markdown through both MPreview (WKWebView) and NSTextView,
// captures screenshots of each, and produces a visual diff.
//
// Usage: swift Tests/compare_renderers.swift [path_to_markdown_file]
//
// Output: /tmp/fsnotes_compare/mpreview.png, nstextview.png, diff.png

import AppKit
import WebKit

// MARK: - Configuration

let outputDir = "/tmp/fsnotes_compare"
let renderWidth: CGFloat = 800
let renderHeight: CGFloat = 2000  // Tall enough for long notes

// MARK: - Markdown Content

func loadMarkdown() -> String {
    if CommandLine.arguments.count > 1 {
        let path = CommandLine.arguments[1]
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content
        }
    }

    // Default test content
    return """
    # Test Note: Renderer Comparison

    This tests all markdown elements for visual parity.

    ## Headers with bottom border

    ### Third level header

    Normal text after header.

    ---

    ## Text Formatting

    This is **bold text** and *italic text* and ***bold italic***.

    This is ~~strikethrough~~ text.

    ## Blockquotes

    > A blockquote paragraph.
    > Second line of quote.

    ## Lists

    - Bullet one
    - Bullet two

    1. Numbered one
    2. Numbered two

    - [ ] Todo unchecked
    - [x] Todo checked

    ## Links

    [FSNotes](https://fsnot.es)

    https://github.com

    ## Code

    Inline `code` here.

    ```python
    def hello():
        print("world")
    ```

    ## Table

    | Left | Center | Right |
    |:-----|:------:|------:|
    | L1   | C1     | R1    |
    """
}

// MARK: - MPreview Renderer

class MPreviewRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var completion: ((NSImage?) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func render(markdown: String, bundlePath: String, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion

        // Convert markdown to HTML using cmark-gfm
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cmark-gfm")
        process.arguments = ["--extension", "table", "--extension", "strikethrough", "--extension", "autolink", "--extension", "tasklist", "--unsafe"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        try? process.run()
        inputPipe.fileHandleForWriting.write(markdown.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let htmlContent = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight)

            webView.takeSnapshot(with: config) { image, error in
                self.completion?(image)
            }
        }
    }
}

// MARK: - Image Diff

func diffImages(_ img1: NSImage, _ img2: NSImage) -> (NSImage, Double) {
    let size = NSSize(width: max(img1.size.width, img2.size.width),
                      height: max(img1.size.height, img2.size.height))

    let diffImage = NSImage(size: size)
    diffImage.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Draw img1 as base
    img1.draw(in: NSRect(origin: .zero, size: img1.size))

    // Overlay img2 with difference blend mode
    ctx.setBlendMode(.difference)
    img2.draw(in: NSRect(origin: .zero, size: img2.size))

    diffImage.unlockFocus()

    // Calculate simple pixel difference percentage
    // (A more sophisticated SSIM comparison would be better but this is a start)
    return (diffImage, 0.0)  // TODO: actual percentage calculation
}

// MARK: - Main

let markdown = loadMarkdown()
let bundlePath = FileManager.default.currentDirectoryPath + "/Resources/MPreview.bundle"

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

print("FSNotes Renderer Comparison")
print("===========================")
print("Rendering markdown (\(markdown.count) chars) at \(Int(renderWidth))x\(Int(renderHeight))")
print("")

let app = NSApplication.shared
let renderer = MPreviewRenderer()

print("1. Rendering through MPreview (WebKit)...")
renderer.render(markdown: markdown, bundlePath: bundlePath) { image in
    if let image = image {
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try? png.write(to: URL(fileURLWithPath: "\(outputDir)/mpreview.png"))
        print("   Saved: \(outputDir)/mpreview.png")
    } else {
        print("   ERROR: Failed to capture MPreview screenshot")
    }

    print("")
    print("2. NSTextView rendering requires the FSNotes app.")
    print("   Open FSNotes, navigate to the test note, and take a screenshot.")
    print("   Save it to: \(outputDir)/nstextview.png")
    print("")
    print("3. To compare, open both PNGs side by side:")
    print("   open \(outputDir)/mpreview.png \(outputDir)/nstextview.png")
    print("")

    // Clean up temp file
    try? FileManager.default.removeItem(atPath: bundlePath + "/_compare_temp.html")

    exit(0)
}

// Run the event loop for WKWebView
app.run()
