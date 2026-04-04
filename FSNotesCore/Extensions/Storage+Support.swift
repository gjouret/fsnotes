//
//  Storage+Support.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation

enum DirectoryScanFilter {
    static func candidateDirectories(
        in rootURL: URL,
        allowedExtensions: [String],
        excludedPaths: [String] = [],
        excludedURLs: [URL] = []
    ) -> [URL]? {
        guard let fileEnumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: FileManager.DirectoryEnumerationOptions()
        ) else {
            return nil
        }

        return fileEnumerator.allObjects.compactMap { $0 as? URL }
            .filter { url in
                if allowedExtensions.contains(url.pathExtension) || allowedExtensions.contains(url.lastPathComponent) {
                    return false
                }

                if excludedURLs.contains(url) {
                    return false
                }

                if excludedPaths.contains(where: { url.path.contains($0) }) {
                    return false
                }

                return true
            }
    }
}

enum CachedSidebarTreeStore {
    static let fileName = "sidebarTree"

    static func load(from cacheDirectory: URL) -> [URL]? {
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        return try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSURL.self], from: data) as? [URL]
    }

    static func save(_ urls: [URL], to cacheDirectory: URL) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: urls, requiringSecureCoding: true) else {
            return
        }

        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            print("B. Sidebar tree caching is finished")
        } catch {
            print("Sidebar caching error")
        }
    }

    static func remove(from cacheDirectory: URL) {
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
