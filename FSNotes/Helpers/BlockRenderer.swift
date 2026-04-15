//
//  BlockRenderer.swift
//  FSNotes
//
//  Renders mermaid diagrams and LaTeX math to NSImage using a hidden WKWebView.
//

import WebKit

class BlockRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    enum BlockType {
        case mermaid
        case math
        case inlineMath
    }

    private var webView: WKWebView?
    private var completion: ((NSImage?) -> Void)?
    private var blockType: BlockType = .mermaid
    private var tempFile: URL?
    private var offscreenWindow: NSWindow?

    // Cache rendered images by source hash
    private static var cache = NSCache<NSString, NSImage>()

    /// Disk cache directory for rendered mermaid/math images (Perf #2).
    /// Persists across app restarts so the second time you open a note
    /// with a mermaid diagram it's instant — not just the second time
    /// in the same session. Keyed by fnv1a hash of "<type>:<source>".
    private static let diskCacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("co.fluder.FSNotes/blockrenderer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Clear all cached rendered images (e.g., when rendering templates change).
    static func clearCache() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    private static func diskCacheFile(forKey key: String) -> URL {
        // fnv1a gives a stable 64-bit hash independent of NSString's
        // per-process hash randomization. Filename is hex.
        let hash = key.fnv1a
        return diskCacheURL.appendingPathComponent(String(format: "%016x.png", hash))
    }

    private static func loadFromDisk(key: String) -> NSImage? {
        let url = diskCacheFile(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    private static func writeToDisk(image: NSImage, key: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = diskCacheFile(forKey: key)
        try? png.write(to: url, options: .atomic)
    }

    // Keep strong references to active renderers so they aren't deallocated
    // while the WKWebView is still loading (navigationDelegate is weak)
    private static var activeRenderers = Set<BlockRenderer>()

    static func render(source: String, type: BlockType, maxWidth: CGFloat = 480, completion: @escaping (NSImage?) -> Void) {
        let cacheKeyString = "\(type):\(source)"
        let cacheKey = cacheKeyString as NSString

        // In-memory cache — same-session hit.
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        // Disk cache (Perf #2): cross-session hit. Lets a note with a
        // mermaid diagram appear instantly on the SECOND-ever open, not
        // just the second open in the same session.
        if let diskCached = loadFromDisk(key: cacheKeyString) {
            cache.setObject(diskCached, forKey: cacheKey)
            completion(diskCached)
            return
        }

        let renderer = BlockRenderer()
        renderer.blockType = type
        renderer.completion = { [weak renderer] image in
            if let image = image {
                cache.setObject(image, forKey: cacheKey)
                writeToDisk(image: image, key: cacheKeyString)
            }
            completion(image)
            if let renderer = renderer {
                activeRenderers.remove(renderer)
            }
        }
        activeRenderers.insert(renderer)
        renderer.startRender(source: source, type: type, maxWidth: maxWidth)
    }

    private func startRender(source: String, type: BlockType, maxWidth: CGFloat) {
        let contentController = WKUserContentController()
        contentController.add(self, name: "renderComplete")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        // Use a generous initial height so mermaid/math diagrams fit
        // inside the viewport and the snapshot crop rect never extends
        // beyond the view bounds. Avoids a post-render frame resize +
        // wait-for-propagation race that the old code covered with a
        // hardcoded 300ms delay. 4000pt handles every reasonable
        // diagram; tall diagrams just mean taller empty space below.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: maxWidth, height: 4000), configuration: config)
        webView?.navigationDelegate = self
        // Use opaque background matching the editor theme (dark/light).
        // Transparent backgrounds caused invisible text in snapshots on
        // some macOS versions and when fonts load asynchronously.

        // WKWebView requires being in a window hierarchy to render content on recent macOS.
        // Add it to a hidden offscreen window.
        if let wv = webView {
            let offscreenWindow = NSWindow.makeOffscreen(width: maxWidth, height: 4000)
            offscreenWindow.contentView?.addSubview(wv)
            self.offscreenWindow = offscreenWindow
        }

        guard let bundleURL = Bundle.main.url(forResource: "MPreview", withExtension: "bundle") else {
            completion?(nil)
            cleanup()
            return
        }

        let html = generateHTML(source: source, type: type, maxWidth: maxWidth)

        // ⚠️ CRITICAL: Temp file MUST be inside MPreview.bundle (same directory as mermaid.min.js).
        // WKWebView in sandboxed macOS apps can only access files within the allowingReadAccessTo
        // directory tree. Moving this to NSTemporaryDirectory() or any path outside the bundle
        // WILL break mermaid/math rendering because the JS files become inaccessible.
        // This has been broken and fixed TWICE — do not move this file path.
        let tempFile = bundleURL.appendingPathComponent("_render_\(UUID().uuidString).html")
        do {
            try html.write(to: tempFile, atomically: true, encoding: .utf8)
            self.tempFile = tempFile
            webView?.loadFileURL(tempFile, allowingReadAccessTo: bundleURL)
        } catch {
            completion?(nil)
            cleanup()
        }
    }

    private func generateHTML(source: String, type: BlockType, maxWidth: CGFloat) -> String {
        let escapedSource = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDark ? "#d4d4d4" : "#333333"
        let bgColor = isDark ? "#1e1e1e" : "#ffffff"
        let mermaidTheme = isDark ? "dark" : "default"

        switch type {
        case .mermaid:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <style>
                    * { margin: 0; padding: 0; }
                    body { background: \(bgColor); color: \(textColor); }
                    .mermaid { max-width: \(Int(maxWidth))px; }
                    svg { max-width: 100%; }
                </style>
                <script src="js/mermaid.min.js"></script>
            </head>
            <body>
                <pre class="mermaid">\(escapedSource)</pre>
                <script>
                    // htmlLabels:false → text renders as native SVG <text> (crisp at any
                    // rasterization scale). htmlLabels:true wraps text in <foreignObject>
                    // which WebKit rasterizes at a different scale than the parent SVG,
                    // producing visibly fuzzy text in snapshots.
                    mermaid.initialize({ startOnLoad: false, theme: '\(mermaidTheme)', flowchart: { useMaxWidth: true, htmlLabels: false } });
                    mermaid.run().then(function() {
                        // After mermaid.run() resolves, the SVG is in the
                        // DOM but SVG <text> metrics are only accurate once
                        // the browser has fully loaded the fonts those
                        // <text> elements reference. WebKit reports system
                        // fonts as "not loaded" until the first glyph is
                        // actually rendered — which is the race the old
                        // hardcoded 200ms setTimeout was masking.
                        //
                        // `document.fonts.ready` resolves when all active
                        // font loads complete (standard Web API, supported
                        // in WebKit). For the system-font case it's nearly
                        // instant; for any future web-font usage in the
                        // mermaid template it waits exactly as long as the
                        // fonts need. This is the actual signal we want —
                        // not a blind timeout, not requestAnimationFrame
                        // (which WebKit throttles on offscreen views).
                        return document.fonts.ready;
                    }).then(function() {
                        // CSS layout is forced synchronously the instant
                        // we call getBoundingClientRect, so no explicit
                        // wait is needed for layout completion.
                        var el = document.querySelector('.mermaid svg') || document.querySelector('.mermaid');
                        var rect = el.getBoundingClientRect();
                        // Add 2px stroke clearance on right/bottom: getBoundingClientRect
                        // gives a tight geometric box, but stroked paths are centered on
                        // their geometry so half the stroke width extends outside the box.
                        // Without padding, the right-edge strokes get clipped.
                        window.webkit.messageHandlers.renderComplete.postMessage({
                            width: Math.ceil(rect.right) + 2,
                            height: Math.ceil(rect.bottom) + 2
                        });
                    }).catch(function(e) {
                        var errMsg = (e && e.message) ? e.message : (e && e.toString ? e.toString() : 'unknown');
                        if (errMsg === '[object Object]') {
                            try { errMsg = JSON.stringify(e); } catch(_) {}
                        }
                        window.webkit.messageHandlers.renderComplete.postMessage({ error: errMsg });
                    });
                </script>
            </body>
            </html>
            """

        case .math:
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <style>
                    body { margin: 0; padding: 4px 8px; background: \(bgColor); color: \(textColor); }
                    #math { display: inline-block; }
                    /* Force MathJax text color to match the theme */
                    mjx-container, mjx-math, mjx-mi, mjx-mo, mjx-mn, mjx-mrow {
                        color: \(textColor) !important;
                    }
                </style>
                <!-- MathJax v3 config MUST be set before the script loads.
                     Without this, $$ delimiters are not recognized and the
                     formula renders as plain text (18px tall). -->
                <script>
                    MathJax = {
                        tex: {
                            displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                            inlineMath: [['$', '$'], ['\\\\(', '\\\\)']]
                        },
                        startup: {
                            typeset: false
                        }
                    };
                </script>
                <script src="js/tex-mml-chtml.js"></script>
            </head>
            <body>
                <div id="math">\\[\(escapedSource)\\]</div>
                <script>
                    MathJax.startup.promise.then(function() {
                        return MathJax.typesetPromise();
                    }).then(function() {
                        return document.fonts.ready;
                    }).then(function() {
                        setTimeout(function() {
                            var el = document.getElementById('math');
                            var rect = el.getBoundingClientRect();
                            // Use rect.right/bottom (not width/height) to include
                            // body padding in the snapshot dimensions.
                            window.webkit.messageHandlers.renderComplete.postMessage({
                                width: Math.ceil(rect.right) + 2,
                                height: Math.ceil(rect.bottom) + 2
                            });
                        }, 200);
                    }).catch(function(e) {
                        window.webkit.messageHandlers.renderComplete.postMessage({
                            error: (e && e.message) ? e.message : 'MathJax error'
                        });
                    });
                </script>
            </body>
            </html>
            """

        case .inlineMath:
            // Inline math: rendered at text size, no display-mode centering.
            // Uses \(...\) delimiters for inline rendering.
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <style>
                    body { margin: 0; padding: 0 2px; background: \(bgColor); color: \(textColor);
                           font-size: 14px; line-height: 1.2; }
                    mjx-container, mjx-math, mjx-mi, mjx-mo, mjx-mn, mjx-mrow {
                        color: \(textColor) !important;
                    }
                </style>
                <script>
                    MathJax = {
                        tex: {
                            displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                            inlineMath: [['\\\\(', '\\\\)']]
                        },
                        startup: { typeset: false }
                    };
                </script>
                <script src="js/tex-mml-chtml.js"></script>
            </head>
            <body>
                <span id="math">\\(\(escapedSource)\\)</span>
                <script>
                    MathJax.startup.promise.then(function() {
                        return MathJax.typesetPromise();
                    }).then(function() {
                        return document.fonts.ready;
                    }).then(function() {
                        setTimeout(function() {
                            var el = document.getElementById('math');
                            var rect = el.getBoundingClientRect();
                            window.webkit.messageHandlers.renderComplete.postMessage({
                                width: Math.ceil(rect.right) + 2,
                                height: Math.ceil(rect.bottom)
                            });
                        }, 200);
                    }).catch(function(e) {
                        window.webkit.messageHandlers.renderComplete.postMessage({
                            error: (e && e.message) ? e.message : 'MathJax inline error'
                        });
                    });
                </script>
            </body>
            </html>
            """
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bmLog("🎭 BlockRenderer didReceive: name=\(message.name) body=\(message.body)")
        guard message.name == "renderComplete",
              let body = message.body as? [String: Any] else {
            bmLog("🎭 BlockRenderer guard failed: name=\(message.name) bodyType=\(type(of: message.body))")
            completion?(nil)
            cleanup()
            return
        }

        if let error = body["error"] {
            bmLog("🎭 BlockRenderer JS error: \(error)")
            completion?(nil)
            cleanup()
            return
        }

        guard let width = body["width"] as? CGFloat,
              let height = body["height"] as? CGFloat,
              width > 0, height > 0 else {
            bmLog("🎭 BlockRenderer bad dimensions: \(body)")
            completion?(nil)
            cleanup()
            return
        }

        bmLog("🎭 BlockRenderer got dimensions: \(width)x\(height), taking snapshot")

        // The webview was created at (maxWidth, 4000) — generous enough
        // to contain the rendered SVG without a post-render resize. The
        // snapshot crop rect specifies the exact content area; anything
        // beyond the crop is discarded. This avoids the
        // frame-resize-then-wait-for-propagation race that the old code
        // papered over with a hardcoded 300ms delay. (Perf #2.)
        guard let webView = self.webView else {
            completion?(nil)
            cleanup()
            return
        }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = NSRect(x: 0, y: 0, width: width, height: height)
        snapshotConfig.afterScreenUpdates = true

        bmLog("🎭 BlockRenderer taking snapshot...")
        webView.takeSnapshot(with: snapshotConfig) { [weak self] image, error in
            bmLog("🎭 BlockRenderer snapshot result: image=\(image != nil ? "\(image!.size)" : "nil"), error=\(error?.localizedDescription ?? "none")")
            DispatchQueue.main.async {
                self?.completion?(image)
                self?.cleanup()
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Navigation succeeded — waiting for JS renderComplete callback
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        bmLog("🎭 BlockRenderer navigation failed: \(error)")
        completion?(nil)
        cleanup()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        bmLog("🎭 BlockRenderer provisional navigation failed: \(error)")
        completion?(nil)
        cleanup()
    }

    private func cleanup() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "renderComplete")
        webView?.navigationDelegate = nil
        webView = nil
        if let tempFile = tempFile {
            try? FileManager.default.removeItem(at: tempFile)
        }
        tempFile = nil
        BlockRenderer.activeRenderers.remove(self)
    }
}
