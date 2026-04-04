//
//  NoteStore.swift
//  FSNotesCore
//  Focused facade for note collection operations.

import Foundation

public class NoteStore {
    public init() {}

    public func add(_ note: Note) {
        Storage.shared().add(note)
    }

    public func remove(_ note: Note) {
        Storage.shared().removeBy(note: note)
    }

    public func getBy(url: URL) -> Note? {
        return Storage.shared().getBy(url: url)
    }

    public func getBy(title: String) -> Note? {
        return Storage.shared().getBy(title: title)
    }

    public var noteList: [Note] {
        return Storage.shared().noteList
    }

    public func getDefault() -> Project? {
        return Storage.shared().getDefault()
    }

    public func getDefaultTrash() -> Project? {
        return Storage.shared().getDefaultTrash()
    }
}
