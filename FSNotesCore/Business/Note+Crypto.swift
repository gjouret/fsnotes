//
//  Note+Crypto.swift
//  FSNotesCore
//
//  Encryption/decryption operations extracted from Note.swift.
//  Handles encrypted text pack (.etp) creation, locking, and unlocking.
//

import Foundation
import RNCryptor
import SSZipArchive
#if os(macOS)
import Cocoa
#else
import UIKit
#endif

extension Note {
    public func unLock(password: String) -> Bool {
        let sharedStorage = sharedStorage

        do {
            let name = url.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: url)

            guard let temporary = sharedStorage.makeTempEncryptionDirectory()?.appendingPathComponent(name) else { return false }

            let temporaryTextPack = temporary.appendingPathExtension("textpack")
            let temporaryTextBundle = temporary.appendingPathExtension("textbundle")

            let decryptedData = try RNCryptor.decrypt(data: data, withPassword: password)
            try decryptedData.write(to: temporaryTextPack)

            let successUnZip = SSZipArchive.unzipFile(atPath: temporaryTextPack.path, toDestination: temporaryTextBundle.path)

            try FileManager.default.removeItem(at: temporaryTextPack)
            guard successUnZip else { return false }

            self.decryptedTemporarySrc = temporaryTextBundle

            guard loadTextBundle() else {
                container = .encryptedTextPack
                return false
            }

            invalidateCache()
            load(tags: false)
            loadTitle()
            
            self.password = password

            return true
        } catch {
            print("Decryption error: \(error)")
            return false
        }
    }

    public func unEncrypt(password: String) -> Bool {
        let originalSrc = url

        do {
            let name = url.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: url)

            let decryptedData = try RNCryptor.decrypt(data: data, withPassword: password)
            let textPackURL = getTempTextPackURL()
            try decryptedData.write(to: textPackURL)

            let newURL = project.url.appendingPathComponent(name + ".textbundle", isDirectory: false)
            url = newURL
            container = .textBundleV2

            let successUnZip = SSZipArchive.unzipFile(atPath: textPackURL.path, toDestination: newURL.path)

            guard successUnZip else {
                url = originalSrc
                container = .encryptedTextPack
                return false
            }

            try FileManager.default.removeItem(at: textPackURL)
            try FileManager.default.removeItem(at: originalSrc)

            self.decryptedTemporarySrc = nil
            self.password = nil

            invalidateCache()
            load()
            parseURL()

            return true

        } catch {
            print("Decryption error: \(error)")

            return false
        }
    }

    public func unEncryptUnlocked() -> Bool {
        guard let decSrcUrl = decryptedTemporarySrc else { return false }

        let originalSrc = url

        do {
            let name = url.deletingPathExtension().lastPathComponent
            let newURL = project.url.appendingPathComponent(name).appendingPathExtension("textbundle")

            url = newURL
            container = .textBundleV2

            try FileManager.default.removeItem(at: originalSrc)
            try FileManager.default.moveItem(at: decSrcUrl, to: newURL)

            self.decryptedTemporarySrc = nil

            load()
            parseURL()
            
            return true

        } catch {
            print("Encryption removing error: \(error)")

            return false
        }
    }

    public func encrypt(password: String) -> Bool {
        if container == .encryptedTextPack {
            return false
        }
        
        var temporaryFlatSrc: URL?
        let isContainer = isTextBundle()

        if !isContainer {
            temporaryFlatSrc = convertFlatToTextBundle()
        }

        let originalSrc = url
        let fileName = url.deletingPathExtension().lastPathComponent

        let baseTextPack = temporaryFlatSrc ?? url
        let textPackURL = getTempTextPackURL()

        SSZipArchive.createZipFile(atPath: textPackURL.path, withContentsOfDirectory: baseTextPack.path)

        do {
            if let tempURL = temporaryFlatSrc {
                try FileManager.default.removeItem(at: tempURL)
            }

            let encryptedURL = 
                self.project.url
                .appendingPathComponent(fileName)
                .appendingPathExtension("etp")

            let data = try Data(contentsOf: textPackURL)
            let encrypted = RNCryptor.encrypt(data: data, withPassword: password)

            url = encryptedURL
            container = .encryptedTextPack
            parseURL()

            try encrypted.write(to: encryptedURL)

            try FileManager.default.removeItem(at: originalSrc)
            try FileManager.default.removeItem(at: textPackURL)

            cleanOut()
            removeTempContainer()
            invalidateCache()

            return true
        } catch {
            url = originalSrc
            parseURL()

            print("Encyption error: \(error) \(error.localizedDescription)")

            return false
        }
    }

    public func getTempTextPackURL() -> URL {
        let fileName = url.deletingPathExtension().lastPathComponent

        let textPackURL =
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(fileName, isDirectory: false)
                .appendingPathExtension("textpack")

        return textPackURL
    }

    public func encryptAndUnlock(password: String) {
        if encrypt(password: password) {
            _ = unLock(password: password)
        }
    }

    public func cleanOut() {
        isParsed = false
        imageUrl = nil
        cacheHash = nil
        content = NSMutableAttributedString(string: String())
        preview = String()
        title = String()
    }

    private func removeTempContainer() {
        if let url = decryptedTemporarySrc {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func isUnlocked() -> Bool {
        return (decryptedTemporarySrc != nil)
    }

    public func isEncrypted() -> Bool {
        return (container == .encryptedTextPack || isUnlocked())
    }

    public func isEncryptedAndLocked() -> Bool {
        return container == .encryptedTextPack && decryptedTemporarySrc == nil
    }

    public func lock() -> Bool {
        guard let temporaryURL = self.decryptedTemporarySrc else { return false }

        // Wait for pending cipher operations to complete (max 5 seconds, non-blocking check)
        let writer = sharedStorage.ciphertextWriter
        let timeout = Date().addingTimeInterval(5)
        writer.waitUntilAllOperationsAreFinished()

        container = .encryptedTextPack
        cleanOut()
        parseURL()

        try? FileManager.default.removeItem(at: temporaryURL)
        self.decryptedTemporarySrc = nil
        self.password = nil

        return true
    }
}
