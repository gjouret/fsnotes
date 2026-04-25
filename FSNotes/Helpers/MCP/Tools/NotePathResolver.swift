//
//  NotePathResolver.swift
//  FSNotes
//
//  Filesystem-based note resolution shared by every MCP tool that
//  takes a `title` / `folder` / `path` argument trio. Walks the
//  on-disk tree below `storageRoot` rather than going through
//  `Storage` — see docs/AI.md "Direct Filesystem Access" for the
//  rationale (works on closed notes, no app-state branching, simple
//  enough to test in isolation).
//
//  Title disambiguation: when `title` alone matches multiple notes
//  across folders, the resolver returns the full match list and
//  lets the caller surface a `ToolOutput.error` listing each
//  `(folder, title)` pair so the LLM can retry with `folder`.
//

import Foundation

/// A note discovered on disk, expressed in storage-relative terms.
public struct ResolvedNote {
    /// Absolute filesystem URL of the note. For TextBundles this
    /// points at the `.textbundle` directory itself, NOT at the
    /// inner `text.md` — callers route through `markdownURL` to read
    /// content while preserving bundle structure.
    public let url: URL

    /// Title without extension. For `Foo.textbundle` this is `Foo`;
    /// for `Foo.md` this is `Foo`; for `Foo.markdown` this is `Foo`.
    public let title: String

    /// Folder path relative to `storageRoot`, with `/` separators
    /// and no leading slash. The empty string means the storage
    /// root itself.
    public let folder: String

    /// True when the note is a TextBundle directory.
    public let isTextBundle: Bool

    /// URL of the markdown content. For plain notes this equals
    /// `url`; for TextBundles this is `url/text.md`.
    public var markdownURL: URL {
        if isTextBundle {
            return url.appendingPathComponent("text.md")
        }
        return url
    }

    /// Storage-relative path with extension preserved. Used as the
    /// canonical wire identifier in tool input/output.
    public var relativePath: String {
        if folder.isEmpty {
            return url.lastPathComponent
        }
        return folder + "/" + url.lastPathComponent
    }
}

/// Outcome of resolving a `title` / `folder` / `path` argument trio.
public enum NoteResolution {
    /// Exactly one note matched; caller proceeds.
    case found(ResolvedNote)
    /// Title matched multiple notes; caller surfaces a
    /// disambiguation error listing every candidate.
    case ambiguous([ResolvedNote])
    /// No note matched the supplied arguments.
    case notFound
    /// Caller-supplied arguments were malformed (e.g. neither path
    /// nor title was provided). The string is a user-facing reason.
    case invalidArguments(String)
}

/// Shared resolver. Stateless — every method takes the storage root
/// as input. This keeps the type trivially testable.
public enum NotePathResolver {

    /// File extensions that count as "plain markdown" notes.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "txt"]

    /// File extensions that count as TextBundle wrappers.
    public static let textBundleExtensions: Set<String> = ["textbundle"]

    /// Encrypted-note extension — see docs/AI.md "Security" / Q2.
    public static let encryptedExtensions: Set<String> = ["etp"]

    /// Resolve a `title` / `folder` / `path` argument trio against
    /// the storage tree rooted at `storageRoot`.
    public static func resolve(
        title: String?,
        folder: String?,
        path: String?,
        storageRoot: URL
    ) -> NoteResolution {
        // 1. `path` takes precedence: it's the unambiguous wire form.
        if let path = path, !path.isEmpty {
            if let note = resolveExactPath(path, storageRoot: storageRoot) {
                return .found(note)
            }
            return .notFound
        }

        guard let title = title, !title.isEmpty else {
            return .invalidArguments("Provide either 'path', 'title', or 'folder' + 'title'.")
        }

        // 2. `folder` + `title`: scoped lookup, single match expected.
        if let folder = folder, !folder.isEmpty {
            let folderURL = storageRoot.appendingPathComponent(folder)
            let matches = listNotes(in: folderURL, storageRoot: storageRoot, recursive: false)
                .filter { $0.title == title }
            if let only = matches.first, matches.count == 1 {
                return .found(only)
            }
            if matches.count > 1 {
                return .ambiguous(matches)
            }
            return .notFound
        }

        // 3. `title` alone: full-tree search, disambiguate on collision.
        let matches = listNotes(in: storageRoot, storageRoot: storageRoot, recursive: true)
            .filter { $0.title == title }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// Walk one folder and return every note inside. `recursive`
    /// descends into subfolders (skipping TextBundle interiors).
    public static func listNotes(
        in folderURL: URL,
        storageRoot: URL,
        recursive: Bool
    ) -> [ResolvedNote] {
        var results: [ResolvedNote] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let url as URL in enumerator {
            // TextBundles are directories that act as files for our
            // purposes. Don't descend into them.
            let isBundle = textBundleExtensions.contains(url.pathExtension.lowercased())
            if isBundle {
                enumerator.skipDescendants()
                if !recursive && !isDirectChild(url: url, of: folderURL) {
                    continue
                }
                if let note = resolved(at: url, storageRoot: storageRoot) {
                    results.append(note)
                }
                continue
            }

            // Plain directories: descend if recursive, skip if not.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if !recursive {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Plain markdown files.
            if markdownExtensions.contains(url.pathExtension.lowercased()) {
                if !recursive && !isDirectChild(url: url, of: folderURL) {
                    continue
                }
                if let note = resolved(at: url, storageRoot: storageRoot) {
                    results.append(note)
                }
            }
        }

        return results.sorted { $0.relativePath < $1.relativePath }
    }

    /// List subfolders of `folderURL`. TextBundle directories are
    /// excluded — they are notes, not folders.
    public static func listFolders(
        in folderURL: URL,
        storageRoot: URL,
        recursive: Bool
    ) -> [String] {
        var results: [String] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let url as URL in enumerator {
            let isBundle = textBundleExtensions.contains(url.pathExtension.lowercased())
            if isBundle {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { continue }
            if !recursive && !isDirectChild(url: url, of: folderURL) {
                continue
            }
            if let rel = relativePath(of: url, under: storageRoot) {
                results.append(rel)
            }
        }

        return results.sorted()
    }

    // MARK: - Helpers

    /// True for an `.etp` file or a TextBundle whose `info.json`
    /// declares an encrypted variant. Conservative: if we can't tell
    /// for sure, treat as not encrypted.
    public static func isEncrypted(at url: URL) -> Bool {
        if encryptedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // TextBundle: look for an "encrypted" hint in info.json.
        if textBundleExtensions.contains(url.pathExtension.lowercased()) {
            let info = url.appendingPathComponent("info.json")
            if let data = try? Data(contentsOf: info),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let flag = json["encrypted"] as? Bool, flag { return true }
                if let type = json["type"] as? String,
                   type.lowercased().contains("encrypted") {
                    return true
                }
            }
        }
        return false
    }

    /// Build a `ResolvedNote` from an absolute URL, or nil if the
    /// URL can't be expressed under `storageRoot`.
    private static func resolved(at url: URL, storageRoot: URL) -> ResolvedNote? {
        guard let rel = relativePath(of: url, under: storageRoot) else { return nil }
        let folder: String
        let last: String
        if let slash = rel.lastIndex(of: "/") {
            folder = String(rel[..<slash])
            last = String(rel[rel.index(after: slash)...])
        } else {
            folder = ""
            last = rel
        }
        let isBundle = textBundleExtensions.contains(url.pathExtension.lowercased())
        let title: String
        if isBundle {
            title = (last as NSString).deletingPathExtension
        } else {
            title = (last as NSString).deletingPathExtension
        }
        return ResolvedNote(url: url, title: title, folder: folder, isTextBundle: isBundle)
    }

    /// Resolve a storage-relative path string. Path may include
    /// extension or omit it (in which case `.md` and `.textbundle`
    /// are tried in turn).
    private static func resolveExactPath(_ path: String, storageRoot: URL) -> ResolvedNote? {
        let direct = storageRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: direct.path) {
            return resolved(at: direct, storageRoot: storageRoot)
        }
        // Try common extensions.
        for ext in ["md", "markdown", "txt", "textbundle"] {
            let withExt = storageRoot.appendingPathComponent(path + "." + ext)
            if FileManager.default.fileExists(atPath: withExt.path) {
                return resolved(at: withExt, storageRoot: storageRoot)
            }
        }
        return nil
    }

    /// Compute `child.path` relative to `root.path`, or nil if
    /// `child` is not below `root`.
    private static func relativePath(of child: URL, under root: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        var prefix = rootPath
        if !prefix.hasSuffix("/") { prefix += "/" }
        guard childPath.hasPrefix(prefix) else { return nil }
        return String(childPath.dropFirst(prefix.count))
    }

    /// True iff `url` is an immediate child of `parent` (no
    /// intermediate directories).
    private static func isDirectChild(url: URL, of parent: URL) -> Bool {
        let parentDir = url.deletingLastPathComponent().standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return parentDir == parentPath
    }
}
