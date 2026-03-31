//
//  Note+FileOps.swift
//  FSNotesCore
//
//  File move, rename, delete, and image operations extracted from Note.swift.
//

import Foundation
#if os(macOS)
import Cocoa
#else
import UIKit
#endif

extension Note {
    func move(to: URL, project: Project? = nil, forceRewrite: Bool = false) -> Bool {
        let sharedStorage = sharedStorage

        do {
            var destination = to

            if FileManager.default.fileExists(atPath: to.path) && !forceRewrite {
                guard let project = project ?? sharedStorage.getProjectByNote(url: to) else { return false }

                let ext = url.pathExtension
                destination = NameHelper.getUniqueFileName(name: title, project: project, ext: ext)
            }

            try FileManager.default.moveItem(at: url, to: destination)
            removeCacheForPreviewImages()

            #if os(OSX)
                let restorePin = isPinned
                if isPinned {
                    removePin()
                }

                overwrite(url: destination)

                if restorePin {
                    addPin()
                }
            #endif

            NSLog("File moved from \"\(url.deletingPathExtension().lastPathComponent)\" to \"\(destination.deletingPathExtension().lastPathComponent)\"")
        } catch {
            Swift.print(error)
            return false
        }

        return true
    }
    
    func getNewURL(name: String) -> URL {
        let escapedName = name
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")
        
        var newUrl = url.deletingLastPathComponent()
        newUrl.appendPathComponent(escapedName + "." + url.pathExtension)
        return newUrl
    }

    public func remove() {
        if !isTrash() && !isEmpty() {
            let src = url
            if let trashURLs = removeFile() {
                let dst = trashURLs[0]
                self.url = dst
                parseURL()

                #if IOS_APP
                    moveHistory(src: src, dst: dst)
                #endif
            }
        } else {
            _ = removeFile()

            if self.isPinned {
                removePin()
            }

            #if IOS_APP
                dropRevisions()
            #endif
        }
    }

    public func isEmpty() -> Bool {
        return content.length == 0 && !isEncrypted()
    }

    #if os(iOS)
    // Return URL moved in
    func removeFile(completely: Bool = false) -> Array<URL>? {
        if FileManager.default.fileExists(atPath: url.path) {
            if isTrash() || completely || isEmpty() {
                try? FileManager.default.removeItem(at: url)

                if type == .Markdown && container == .none {
                    let urls = content.getImagesAndFiles()
                    for url in urls {
                        try? FileManager.default.removeItem(at: url.url)
                    }
                }

                return nil
            }

            guard let trashUrl = getDefaultTrashURL() else {
                print("Trash not found")

                var resultingItemUrl: NSURL?
                if #available(iOS 11.0, *) {
                    if let trash = sharedStorage.getDefaultTrash() {
                        moveImages(to: trash)
                    }

                    try? FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemUrl)

                    if let result = resultingItemUrl, let path = result.path {
                        return [URL(fileURLWithPath: path), url]
                    }
                }

                return nil
            }

            var trashUrlTo = trashUrl.appendingPathComponent(name)

            if FileManager.default.fileExists(atPath: trashUrlTo.path) {
                let reserveName = "\(Int(Date().timeIntervalSince1970)) \(name)"
                trashUrlTo = trashUrl.appendingPathComponent(reserveName)
            }

            print("Note moved in custom Trash folder")

            if let trash = sharedStorage.getDefaultTrash() {
                moveImages(to: trash)
            }
            
            try? FileManager.default.moveItem(at: url, to: trashUrlTo)

            return [trashUrlTo, url]
        }
        
        return nil
    }
    #endif

    #if os(OSX)
    func removeFile(completely: Bool = false) -> Array<URL>? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if isTrash() || completely {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError {
                Swift.print("Remove file error: \(error.localizedDescription)")
                Swift.print("Error details: \(error.userInfo)")
            }

            if type == .Markdown && container == .none {
                let urls = content.getImagesAndFiles()
                for url in urls {
                    try? FileManager.default.removeItem(at: url.url)
                }
            }

            return nil
        }

        do {
            guard let dst = sharedStorage.trashItem(url: url) else {
                var resultingItemUrl: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemUrl)

                guard let dst = resultingItemUrl else { return nil }

                let originalURL = url

                overwrite(url: dst as URL)

                return [self.url, originalURL]
            }

            if let trash = sharedStorage.getDefaultTrash() {
                moveImages(to: trash)
            }

            try FileManager.default.moveItem(at: url, to: dst)

            let originalURL = url
            overwrite(url: dst)
            return [self.url, originalURL]

        } catch {
            print("Trash error: \(error)")
        }

        return nil
    }
    #endif

    public func getAttachPrefix(url: URL? = nil) -> String {
        if let url = url, !url.isImage {
            return "files/"
        }

        return "i/"
    }

    public func move(from imageURL: URL, imagePath: String, to project: Project, copy: Bool = false) {
        let dstPrefix = getAttachPrefix(url: imageURL)
        let dest = project.url.appendingPathComponent(dstPrefix, isDirectory: true)

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)

            if let data = "true".data(using: .utf8) {
                try? dest.setExtendedAttribute(data: data, forName: "es.fsnot.hidden.dir")
            }
        }

        do {
            if copy {
                try FileManager.default.copyItem(at: imageURL, to: dest)
            } else {
                try FileManager.default.moveItem(at: imageURL, to: dest)
            }
        } catch {
            if let fileName = ImagesProcessor.getFileName(from: imageURL, to: dest, ext: imageURL.pathExtension) {
                let dest = dest.appendingPathComponent(fileName)

                if copy {
                    try? FileManager.default.copyItem(at: imageURL, to: dest)
                } else {
                    try? FileManager.default.moveItem(at: imageURL, to: dest)
                }

                let prefix = "]("
                let postfix = ")"
                
                let imagePath = imagePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imagePath

                let find = prefix + imagePath + postfix
                let replace = prefix + dstPrefix + fileName + postfix

                guard find != replace else { return }

                while content.mutableString.contains(find) {
                    let range = content.mutableString.range(of: find)
                    content.replaceCharacters(in: range, with: replace)
                }
            }
        }
    }

    public func moveImages(to project: Project) {
        if type == .Markdown && container == .none {
            let imagesMeta = content.getImagesAndFiles()
            for imageMeta in imagesMeta {
                let imagePath = project.url.appendingPathComponent(imageMeta.path).path
                project.storage.hideImages(directory: imagePath, srcPath: imagePath)

                // Copy if image used more then one time on project
                let copy = self.project.countNotes(contains: imageMeta.url) > 0
                move(from: imageMeta.url, imagePath: imageMeta.path, to: project, copy: copy)
            }

            if imagesMeta.count > 0 {
                if save() {
                    sharedStorage.add(self)
                }
            }
        }
    }
    
    private func getDefaultTrashURL() -> URL? {
        if let url = sharedStorage.getDefaultTrash()?.url {
            return url
        }

        return nil
    }
    public func rename(to name: String) {
        var name = name
        var i = 1

        while project.fileExist(fileName: name, ext: url.pathExtension) {

            // disables renaming loop
            if fileName.startsWith(string: name) {
                return
            }

            let items = name.split(separator: " ")

            if let last = items.last, let position = Int(last) {
                let full = items.dropLast()

                name = full.joined(separator: " ") + " " + String(position + 1)

                i = position + 1
            } else {
                name = name + " " + String(i)

                i += 1
            }
        }

        let isPinned = self.isPinned
        let dst = getNewURL(name: name)

        removePin()

        if isEncrypted() {
            _ = lock()
        }

        if move(to: dst) {
            url = dst
            parseURL()
        }

        if isPinned {
            addPin()
        }
    }
}
