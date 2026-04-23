//
//  ThemeDiscovery.swift
//  FSNotesCore
//
//  Phase 7.4 — Theme discovery + load-by-name helpers.
//
//  Pure functions that enumerate available themes (bundled + user) and
//  resolve a theme by its user-visible name. Feeds the Theme-picker UI
//  in Preferences → Editor. Additive to the existing Phase 7.1 loader
//  in `ThemeSchema.swift`; does NOT touch `BlockStyleTheme`,
//  `ThemeSchema`, or `ThemeAccess` beyond adding these helpers.
//
//  Architecture:
//    - `ThemeDescriptor { name, url, isBuiltIn }` is a value type that
//      describes one available theme without forcing us to parse it.
//    - `Theme.availableThemes(...)` walks the bundle + user directory
//      and returns descriptors. A dependency-injection parameter for
//      the user-themes directory keeps the function pure-testable.
//    - `Theme.load(named:...)` resolves a name against the discovered
//      list and loads the backing JSON via the existing
//      `BlockStyleTheme.load(from:)` pathway. Unknown or corrupt
//      themes fall back to the bundled default — never crash.
//    - `Theme.didChangeNotification` is posted by the Preferences UI
//      after a theme switch so every live view can re-render.
//
//  The canonical "Default" name is applied at enumeration time: the
//  bundled `default-theme.json` file is surfaced with the display name
//  "Default" rather than "default-theme" so the UI reads cleanly
//  without editing the JSON on disk.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - ThemeDescriptor

/// A lightweight description of one available theme.
///
/// The descriptor is what the UI list/popup uses; the full `Theme`
/// struct is only loaded when the user selects one (via
/// `Theme.load(named:)`).
public struct ThemeDescriptor: Equatable {

    /// User-visible name (without the `.json` extension). For the
    /// bundled default this is the canonical string "Default", for
    /// imported themes this is the basename of the file.
    public let name: String

    /// Absolute URL to the backing JSON file. `nil` for the compiled-in
    /// failsafe — which is only exposed as an in-memory fallback if
    /// even the bundled JSON cannot be read.
    public let url: URL?

    /// `true` for themes shipped inside the app bundle (read-only from
    /// the user's perspective), `false` for user-imported themes in
    /// Application Support.
    public let isBuiltIn: Bool

    public init(name: String, url: URL?, isBuiltIn: Bool) {
        self.name = name
        self.url = url
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Discovery + load helpers

extension BlockStyleTheme {

    /// Canonical display name for the bundled default theme. Using a
    /// constant keeps the name in one place instead of scattered
    /// string literals across the preferences UI + load paths.
    public static let defaultThemeName: String = "Default"

    /// Notification posted after the active theme has been swapped.
    /// Every live editor observes this and re-renders on receipt.
    ///
    /// Payload: `nil` (observers read `Theme.shared` directly).
    public static let didChangeNotification =
        Notification.Name("BlockStyleThemeDidChange")

    /// Default location of the user-themes directory on macOS.
    /// `~/Library/Application Support/FSNotes++/Themes/`.
    ///
    /// Separated from the Phase 7.1 `BlockStyleTheme.json` override
    /// file so user themes get their own flat directory that the user
    /// can open in Finder.
    public static func defaultUserThemesDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support
            .appendingPathComponent("FSNotes++")
            .appendingPathComponent("Themes")
    }

    /// Enumerate the themes available to the user, bundled + user.
    ///
    /// Returns descriptors — callers load the actual `Theme` via
    /// `Theme.load(named:)` only when the user picks one.
    ///
    /// The `userThemesDirectory` parameter allows tests to point the
    /// enumeration at a temp directory instead of the real user
    /// support folder. Defaults to the real folder in production.
    ///
    /// Order: the canonical "Default" first, then bundled extras
    /// (alphabetical), then user themes (alphabetical). Duplicate
    /// names (same basename in both places) keep the user copy —
    /// which matches how overrides work everywhere else in FSNotes.
    public static func availableThemes(
        userThemesDirectory: URL? = nil
    ) -> [ThemeDescriptor] {
        // Build the merged descriptor list with user-override semantics:
        // a user theme file with the same basename as a bundled theme
        // replaces the bundled entry at the same position. This matches
        // the "user overrides win" pattern used elsewhere in FSNotes
        // (user plist wins over bundled defaults, user syntax themes
        // win over bundled). Fix for Phase 7.5: the prior implementation
        // had bundled winning, which prevented `saveActiveTheme()` from
        // producing a loadable override for bundled themes.

        // ── Bundled "Default" always first in the ordering ───────
        var defaultURL: URL?
        for bundle in Self.candidateBundles() {
            if let url = bundle.url(
                forResource: "default-theme", withExtension: "json"
            ) {
                defaultURL = url
                break
            }
        }
        var orderedBundled: [ThemeDescriptor] = [
            ThemeDescriptor(
                name: Self.defaultThemeName,
                url: defaultURL,
                isBuiltIn: true
            )
        ]

        // ── Other bundled themes in `Themes/` subdirectory ───────
        //
        // Scope open for 7.4+: bundle `Solarized Dark.json`,
        // `Dracula.json`, etc. by dropping them into
        // `Resources/Themes/`. Today the directory may not exist;
        // that's fine — the enumeration just yields zero extras.
        let bundleExtras = enumerateBundledExtraThemes()
        for descriptor in bundleExtras {
            if orderedBundled.contains(where: {
                $0.name.caseInsensitiveCompare(descriptor.name) == .orderedSame
            }) { continue }
            orderedBundled.append(descriptor)
        }

        // ── User themes from Application Support ─────────────────
        let userDir = userThemesDirectory ?? defaultUserThemesDirectory()
        let userThemes = enumerateUserThemes(in: userDir)

        // Index user themes by lowercase name so we can replace any
        // bundled entry that shares a basename.
        var userByKey: [String: ThemeDescriptor] = [:]
        for descriptor in userThemes {
            userByKey[descriptor.name.lowercased()] = descriptor
        }

        var out: [ThemeDescriptor] = []
        var seen = Set<String>()
        for descriptor in orderedBundled {
            let key = descriptor.name.lowercased()
            if let override = userByKey[key] {
                out.append(override)
            } else {
                out.append(descriptor)
            }
            seen.insert(key)
        }
        // Any remaining user-only themes (no bundled sibling) appear
        // alphabetically at the end.
        for descriptor in userThemes {
            let key = descriptor.name.lowercased()
            if seen.contains(key) { continue }
            out.append(descriptor)
            seen.insert(key)
        }

        return out
    }

    /// Walk every candidate bundle for a `Themes/` subdirectory and
    /// yield one descriptor per `*.json` file found. Sorted
    /// alphabetically by display name.
    private static func enumerateBundledExtraThemes() -> [ThemeDescriptor] {
        var found: [ThemeDescriptor] = []
        for bundle in Self.candidateBundles() {
            guard let resourcePath = bundle.resourcePath else { continue }
            let themesDir = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("Themes")
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
                let name = fileURL.deletingPathExtension().lastPathComponent
                // Skip the canonical default — already surfaced
                // at the top of `availableThemes()`.
                if name.lowercased() == "default-theme" { continue }
                if name.lowercased() == Self.defaultThemeName.lowercased() { continue }
                found.append(ThemeDescriptor(
                    name: name,
                    url: fileURL,
                    isBuiltIn: true
                ))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Yield one descriptor per `*.json` file in the user-themes
    /// directory. Sorted alphabetically by display name. Missing
    /// directory → empty array (not an error).
    private static func enumerateUserThemes(in dir: URL) -> [ThemeDescriptor] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [ThemeDescriptor] = []
        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            let name = fileURL.deletingPathExtension().lastPathComponent
            found.append(ThemeDescriptor(
                name: name,
                url: fileURL,
                isBuiltIn: false
            ))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Load the theme with the given user-visible name. Falls back to
    /// the bundled default on unknown name, missing file, malformed
    /// JSON, or failed validation — never crashes.
    ///
    /// The `userThemesDirectory` parameter mirrors `availableThemes()`
    /// so tests can inject a temp location.
    public static func load(
        named name: String?,
        userThemesDirectory: URL? = nil
    ) -> BlockStyleTheme {
        let targetName = name ?? Self.defaultThemeName
        let descriptors = Self.availableThemes(userThemesDirectory: userThemesDirectory)

        // Case-insensitive match so "default" and "Default" work
        // the same way regardless of how the user typed the name
        // in UserDefaults (or fat-fingered it into a config file).
        if let match = descriptors.first(where: {
            $0.name.caseInsensitiveCompare(targetName) == .orderedSame
        }) {
            let (theme, _) = BlockStyleTheme.load(from: match.url)
            return theme
        }

        // Unknown name: log + fall back to the compiled-in / bundled
        // default. We do NOT silently substitute a neighbouring
        // theme — explicit fallback is easier to debug than a
        // surprise theme swap.
        themeLog("Unknown theme name '\(targetName)'; falling back to default.")
        let (theme, _) = BlockStyleTheme.loadBundledDefault()
        return theme
    }

    // MARK: - Phase 7.5: Active-theme write-back
    //
    // SEMANTICS
    // ---------
    // `Theme.saveActiveTheme()` writes the current in-memory `Theme.shared`
    // value out as JSON to the user-themes directory, under the basename
    // of the active theme (resolved via `activeThemeName` — typically
    // `UserDefaultsManagement.currentThemeName`, falling back to the
    // canonical "Default" when unset).
    //
    // Bundled themes live inside the read-only `.app` bundle. When the
    // user edits "Default" (or any other built-in), we can't mutate the
    // bundle — so we drop a same-named override into
    // `~/Library/Application Support/FSNotes++/Themes/<Name>.json`. On
    // subsequent launches `Theme.load(named: "Default")` resolves to the
    // user override (user > bundled precedence is enforced in
    // `availableThemes` — see comment there).
    //
    // Rationale for "user override wins" semantics (vs. spawning a new
    // "My Theme" copy): the user's personal customizations of Default
    // should remain discoverable under the name they know ("Default"),
    // not under a synthetic name. That matches how every other override
    // mechanism in FSNotes behaves (user plist wins over bundled
    // defaults, user syntax themes win over bundled, etc.).
    //
    // We post `Theme.didChangeNotification` after write so the 7.4
    // observer on EditTextView re-renders live.

    /// Resolve the active theme's display name — reads
    /// `UserDefaultsManagement.currentThemeName` when available, else
    /// the canonical `Default`. Exposed so tests / callers can override
    /// it without touching global state.
    public static func activeThemeName(
        preferredName: String? = nil
    ) -> String {
        if let preferredName = preferredName, !preferredName.isEmpty {
            return preferredName
        }
        // UserDefaultsManagement lives in FSNotesCore; reading it
        // directly is the path the rest of Phase 7 uses. Falls back to
        // the canonical "Default" when the key is unset.
        if let stored = UserDefaultsManagement.currentThemeName, !stored.isEmpty {
            return stored
        }
        return Self.defaultThemeName
    }

    /// Serialize `Theme.shared` and write it to the user-themes
    /// directory under the active theme's display name. Creates the
    /// directory if necessary. Returns the URL that was written, or
    /// `nil` on I/O failure.
    ///
    /// Behaviour summary:
    ///   1. Resolve active name (argument → UserDefaults → "Default").
    ///   2. Compute `<userThemesDir>/<ActiveName>.json`.
    ///   3. Encode `Theme.shared` as JSON with pretty-print + sorted keys.
    ///   4. Ensure the user themes directory exists.
    ///   5. Write atomically.
    ///   6. Update `UserDefaultsManagement.currentThemeName` to the
    ///      active name (ensures the loader picks up this override on
    ///      relaunch, and also handles the "saved while on bundled
    ///      Default" case).
    ///   7. Post `Theme.didChangeNotification`.
    @discardableResult
    public static func saveActiveTheme(
        preferredName: String? = nil,
        userThemesDirectory: URL? = nil
    ) -> URL? {
        let dir = userThemesDirectory ?? defaultUserThemesDirectory()
        let name = activeThemeName(preferredName: preferredName)
        let url = dir.appendingPathComponent("\(name).json")

        // Pull both flat + nested and encode them together so the
        // on-disk JSON matches what the loader expects to read back.
        let flat = BlockStyleTheme.shared
        let nested = ThemeNestedGroups.synthesized(from: flat)

        let data: Data
        do {
            data = try BlockStyleTheme.encodeWithNested(flat: flat, nested: nested)
        } catch {
            themeLog("Encode failed for active theme '\(name)': \(error.localizedDescription)")
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            themeLog("Write failed for active theme at \(url.path): \(error.localizedDescription)")
            return nil
        }

        // Ensure currentThemeName matches what we just wrote — if the
        // user was on the bundled Default and saved customizations, the
        // next launch must pick up our override file, which requires the
        // name to be persisted.
        UserDefaultsManagement.currentThemeName = name

        NotificationCenter.default.post(
            name: BlockStyleTheme.didChangeNotification, object: nil
        )
        return url
    }
}
