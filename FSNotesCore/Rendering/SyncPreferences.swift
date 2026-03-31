//
//  SyncPreferences.swift
//  FSNotesCore
//
//  Focused façade for sync/storage path preferences.
//

import Foundation

public struct SyncPreferences {
    public init() {}

    public var storagePath: String? { UserDefaultsManagement.storagePath }
    public var fileFormat: NoteType { UserDefaultsManagement.fileFormat }
    public var storageUrl: URL? { UserDefaultsManagement.storageUrl }
}
