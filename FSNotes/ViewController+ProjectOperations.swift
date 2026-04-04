//
//  ViewController+ProjectOperations.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Cocoa

extension ViewController {
    public func moveReq(notes: [Note], project: Project, completion: @escaping (Bool) -> ()) {
        for note in notes {
            if note.isEncrypted() && project.isEncrypted {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.informativeText = NSLocalizedString("You cannot move an already encrypted note to an encrypted directory. You must first decrypt the note and repeat the steps.", comment: "")
                alert.messageText = NSLocalizedString("Move error", comment: "")
                alert.runModal()
                return
            }
        }

        if project.isEncrypted && project.isLocked() {
            getMasterPassword() { password in
                self.sidebarOutlineView.unlock(projects: [project], password: password)
                if project.password != nil {
                    DispatchQueue.main.async {
                        self.move(notes: notes, project: project)

                        for note in notes {
                            note.encryptAndUnlock(password: password)
                        }

                        completion(true)
                    }
                    return
                }

                completion(false)
            }
            return
        }

        self.move(notes: notes, project: project)

        if project.isEncrypted, let password = project.password {
            for note in notes {
                note.encryptAndUnlock(password: password)
            }
        }

        completion(true)
    }

    private func move(notes: [Note], project: Project) {
        let selectedRow = notesTableView.selectedRowIndexes.min()

        for note in notes {
            if note.project == project {
                continue
            }

            if note.isEncrypted() {
                _ = note.lock()
            }

            let destination = project.url.appendingPathComponent(note.name, isDirectory: false)

            note.moveImages(to: project)

            _ = note.move(to: destination, project: project)

            if !storage.searchQuery.isFit(note: note) {
                notesTableView.removeRows(notes: [note])

                if let selectedRow, selectedRow > -1 {
                    if notesTableView.countNotes() > selectedRow {
                        notesTableView.selectRow(selectedRow)
                    } else {
                        notesTableView.selectRow(notesTableView.countNotes() - 1)
                    }
                }
            }

            note.invalidateCache()
        }

        editor.clear()
    }

    public func copy(project: Project, url: URL) -> URL {
        let fileName = url.lastPathComponent
        let destination = project.url.appendingPathComponent(fileName)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            let destinationCopy = NameHelper.generateCopy(file: url, dstDir: project.url)
            try? FileManager.default.copyItem(at: url, to: destinationCopy)
            return destinationCopy
        }
    }
}
