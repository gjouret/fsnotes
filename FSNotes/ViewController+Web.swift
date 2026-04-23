//
//  ViewController+Web.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.09.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa
import Shout
import SSZipArchive

struct PublishedNoteSite {
    let workingDirectory: URL
    let indexURL: URL
    let zipURL: URL
    let assetURLs: [URL]
}

enum WebNotePublisher {
    static func renderHTML(title: String, content: NSAttributedString) -> String? {
        let mutable = NSMutableAttributedString(attributedString: content)
        let attachments = mutable.getImagesAndFiles()
        let markdown = rewrittenMarkdown(from: mutable, attachments: attachments)

        guard let body = renderMarkdownHTML(markdown: markdown) else {
            return nil
        }

        return wrapHTML(title: title, body: body)
    }

    static func makeSite(note: Note, content: NSAttributedString) throws -> PublishedNoteSite {
        let workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Upload")
            .appendingPathComponent(note.getLatinName(), isDirectory: true)

        try? FileManager.default.removeItem(at: workingDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: nil)

        let mutable = NSMutableAttributedString(attributedString: content)
        let attachments = mutable.getImagesAndFiles().filter {
            !$0.path.startsWith(string: "http://") && !$0.path.startsWith(string: "https://")
        }
        let markdown = rewrittenMarkdown(from: mutable, attachments: attachments)

        guard let body = renderMarkdownHTML(markdown: markdown) else {
            throw "Unable to render markdown as HTML"
        }

        let indexURL = workingDirectory.appendingPathComponent("index.html")
        try wrapHTML(title: note.title, body: body).write(to: indexURL, atomically: true, encoding: .utf8)

        let assetURLs = try copyAttachments(attachments, into: workingDirectory)
        let zipURL = workingDirectory.deletingLastPathComponent().appendingPathComponent(note.getLatinName()).appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: zipURL)
        SSZipArchive.createZipFile(atPath: zipURL.path, withContentsOfDirectory: workingDirectory.path)

        return PublishedNoteSite(
            workingDirectory: workingDirectory,
            indexURL: indexURL,
            zipURL: zipURL,
            assetURLs: assetURLs
        )
    }

    static func verifyRemoteWriteAccess(ssh: SSH, remoteRoot: String) throws {
        let remoteDir = normalizedRemoteDirectory(remoteRoot)
        let testDir = remoteDir + "__fsnotes_test__/"
        let testFileName = "index.html"
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(testFileName)

        defer {
            try? FileManager.default.removeItem(at: localURL)
            try? ssh.execute("rm -rf \(testDir)")
        }

        try "<html><body>FSNotes publish test</body></html>".write(to: localURL, atomically: true, encoding: .utf8)

        try ssh.execute("mkdir -p \(testDir)")
        let sftp = try ssh.openSftp()
        try sftp.upload(localURL: localURL, remotePath: testDir + testFileName)
    }

    private static func rewrittenMarkdown(
        from content: NSMutableAttributedString,
        attachments: [(url: URL, title: String, path: String)]
    ) -> String {
        // Phase 4.7: inline the prepareForSave two-step pipeline.
        let prepared = NSMutableAttributedString(attributedString: content)
        _ = prepared.restoreRenderedBlocks()
        var markdown = prepared.unloadImagesAndFiles().string
        for attachment in attachments {
            let encodedPath = attachment.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? attachment.path
            markdown = markdown.replacingOccurrences(of: encodedPath, with: "i/\(attachment.url.lastPathComponent)")
        }
        return markdown
    }

    private static func copyAttachments(
        _ attachments: [(url: URL, title: String, path: String)],
        into workingDirectory: URL
    ) throws -> [URL] {
        guard !attachments.isEmpty else { return [] }

        let assetDirectory = workingDirectory.appendingPathComponent("i", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true, attributes: nil)

        var copied = [URL]()
        for attachment in attachments {
            let destination = assetDirectory.appendingPathComponent(attachment.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                copied.append(destination)
                continue
            }

            try FileManager.default.copyItem(at: attachment.url, to: destination)
            copied.append(destination)
        }

        return copied
    }

    private static func wrapHTML(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            <style>
                :root { color-scheme: light dark; }
                body {
                    margin: 0;
                    font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
                    background: #f6f5f2;
                    color: #1d1d1f;
                }
                main {
                    max-width: 840px;
                    margin: 0 auto;
                    padding: 48px 24px 72px;
                }
                img { max-width: 100%; height: auto; }
                pre, code {
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    background: rgba(0, 0, 0, 0.05);
                    border-radius: 6px;
                }
                pre { padding: 14px 16px; overflow-x: auto; }
                code { padding: 0.1em 0.3em; }
                blockquote {
                    margin: 0;
                    padding-left: 16px;
                    border-left: 4px solid #d0d0d0;
                    color: #555;
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 1.5rem 0;
                }
                th, td {
                    border: 1px solid #d7d7d7;
                    padding: 8px 10px;
                    text-align: left;
                }
                hr {
                    border: 0;
                    border-top: 4px solid #e7e7e7;
                    margin: 2rem 0;
                }
                @media (prefers-color-scheme: dark) {
                    body { background: #121314; color: #ececec; }
                    pre, code { background: rgba(255, 255, 255, 0.08); }
                    blockquote { border-left-color: #4d4d4d; color: #c0c0c0; }
                    th, td { border-color: #414141; }
                    hr { border-top-color: #343434; }
                }
            </style>
        </head>
        <body>
            <main>
                \(body)
            </main>
        </body>
        </html>
        """
    }

    private static func normalizedRemoteDirectory(_ remoteRoot: String) -> String {
        if remoteRoot.hasSuffix("/") {
            return remoteRoot
        }

        return remoteRoot + "/"
    }
}

extension EditorViewController {
    
    public func getCurrentNote() -> Note? {
        return vcEditor?.note
    }
    
    @IBAction func removeWebNote(_ sender: NSMenuItem) {
        if !UserDefaultsManagement.customWebServer, let note = getCurrentNote() {
            ViewController.shared()?.deleteAPI(note: note, completion: {
                DispatchQueue.main.async {
                    ViewController.shared()?.notesTableView.reloadRow(note: note)
                }
            })
            return
        }
        
        guard let note = getCurrentNote(), let remotePath = note.uploadPath else { return }
        
        DispatchQueue.global().async {
            do {
                guard let ssh = self.getSSHResource() else { return }
                
                try ssh.execute("rm -r \(remotePath)")
                
                note.uploadPath = nil
                
                Storage.shared().saveUploadPaths()
                
                DispatchQueue.main.async {
                    ViewController.shared()?.notesTableView.reloadRow(note: note)
                }
            } catch {
                print(error, error.localizedDescription)
            }
        }
    }
        
    @IBAction func uploadWebNote(_ sender: NSMenuItem) {
        if !UserDefaultsManagement.customWebServer, let note = getCurrentNote() {
            ViewController.shared()?.createAPI(note: note, completion: { url in
                DispatchQueue.main.async {
                    ViewController.shared()?.notesTableView.reloadRow(note: note)
                    guard let url = url else { return }

                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
                    pasteboard.setString(url.absoluteString, forType: NSPasteboard.PasteboardType.string)

                    NSWorkspace.shared.open(url)
                }
            })
            return
        }
        
        guard let note = getCurrentNote() else { return }

        guard let sftpPath = UserDefaultsManagement.sftpPath,
              let web = UserDefaultsManagement.sftpWeb else { return }

        let content = exportAttributedContent(for: note)
        guard let package = try? WebNotePublisher.makeSite(note: note, content: content) else { return }

        let latinName  = note.getLatinName()
        let remoteDir = "\(sftpPath)\(latinName)/"
        let resultUrl = web + latinName + "/"
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(web + latinName + "/", forType: .string)
        
        DispatchQueue.global().async {
            do {
                guard let ssh = self.getSSHResource() else { return }
                
                try ssh.execute("mkdir -p \(remoteDir)")

                let sftp = try ssh.openSftp()
                
                let remoteIndex = remoteDir + "index.html"
                
                _ = try ssh.execute("rm -r \(remoteIndex)")
                try sftp.upload(localURL: package.indexURL, remotePath: remoteIndex)
                
                try? sftp.upload(localURL: package.zipURL, remotePath: remoteDir + note.getLatinName() + ".zip")
                
                if !package.assetURLs.isEmpty {
                    try ssh.execute("mkdir -p \(remoteDir)/i")
                    for assetURL in package.assetURLs {
                        try? sftp.upload(localURL: assetURL, remotePath: remoteDir + "i/" + assetURL.lastPathComponent)
                    }
                }

                if #available(macOS 10.14, *) {
                    DispatchQueue.main.async {
                        ViewController.shared()?.sendNotification()
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                        
                        NSWorkspace.shared.open(URL(string: resultUrl)!)
                    }
                }
                print("Upload was successfull for note: \(note.title)")
                
                note.uploadPath = remoteDir
                
                Storage.shared().saveUploadPaths()
            } catch {
                print(error, error.localizedDescription)
            }
        }
    }
        
    private func getSSHResource() -> SSH? {
        let host = UserDefaultsManagement.sftpHost
        let port = UserDefaultsManagement.sftpPort
        let username = UserDefaultsManagement.sftpUsername
        let password = UserDefaultsManagement.sftpPassword
        let passphrase = UserDefaultsManagement.sftpPassphrase
        
        var publicKeyURL: URL?
        var privateKeyURL: URL?
        
        if let accessData = UserDefaultsManagement.sftpAccessData,
            let bookmarks = NSKeyedUnarchiver.unarchiveObject(with: accessData) as? [URL: Data] {
            for bookmark in bookmarks {
                if bookmark.key.path.hasSuffix(".pub") {
                    publicKeyURL = bookmark.key
                } else {
                    privateKeyURL = bookmark.key
                }
            }
        }
        
        if password.count == 0, publicKeyURL == nil || publicKeyURL == nil {
            uploadError(text: "Please set private and public keys")
            return nil
        }
        
        do {
            let ssh = try SSH(host: host, port: port)
            
            if password.count > 0 {
                try ssh.authenticate(username: username, password: password)
            } else if let publicKeyURL = publicKeyURL, let privateKeyURL = privateKeyURL {
                try ssh.authenticate(username: username, privateKey: privateKeyURL.path, publicKey: publicKeyURL.path, passphrase: passphrase)
            }
            
            return ssh
        } catch {
            print(error, error.localizedDescription)
            
            return nil
        }
    }
    
    public func uploadError(text: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.informativeText = NSLocalizedString("Upload error", comment: "")
        alert.messageText = text
        alert.beginSheetModal(for: self.view.window!)
    }
    
    public func showAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.informativeText = NSLocalizedString(message, comment: "")
            alert.messageText = NSLocalizedString("Web publishing error", comment: "")
            alert.beginSheetModal(for: self.view.window!) { (returnCode: NSApplication.ModalResponse) -> Void in }
        }
    }
}
