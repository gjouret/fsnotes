//
//  GitPreferences.swift
//  FSNotesCore
//
//  Focused façade for Git integration preferences.
//

import Foundation

public struct GitPreferences {
    public init() {}

    public var snapshotsInterval: Int { UserDefaultsManagement.snapshotsInterval }
    public var snapshotsIntervalMinutes: Int { UserDefaultsManagement.snapshotsIntervalMinutes }
    public var backupManually: Bool { UserDefaultsManagement.backupManually }
    public var pullInterval: Int { UserDefaultsManagement.pullInterval }
}
