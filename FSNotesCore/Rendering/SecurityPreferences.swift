//
//  SecurityPreferences.swift
//  FSNotesCore
//
//  Focused façade for security/encryption preferences.
//

import Foundation

public struct SecurityPreferences {
    public init() {}

    public var lockOnSleep: Bool { UserDefaultsManagement.lockOnSleep }
    public var lockOnScreenActivated: Bool { UserDefaultsManagement.lockOnScreenActivated }
    public var lockOnUserSwitch: Bool { UserDefaultsManagement.lockOnUserSwitch }
    public var allowTouchID: Bool { UserDefaultsManagement.allowTouchID }
    public var masterPasswordHint: String { UserDefaultsManagement.masterPasswordHint }
}
