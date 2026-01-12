//
//  LibrarySettingsManager.swift
//  Rivulet
//
//  Manages library visibility and ordering preferences
//

import Foundation
import Combine

/// Manages user preferences for library visibility and ordering in the sidebar
@MainActor
class LibrarySettingsManager: ObservableObject {
    static let shared = LibrarySettingsManager()

    // MARK: - Published State

    /// Library keys that are hidden from the sidebar
    @Published var hiddenLibraryKeys: Set<String> {
        didSet {
            saveHiddenLibraries()
        }
    }

    /// Ordered list of library keys (libraries not in this list appear at the end in default order)
    @Published var libraryOrder: [String] {
        didSet {
            saveLibraryOrder()
        }
    }

    /// Library keys that should appear on the Home screen (separate from sidebar visibility)
    /// Empty set means "not yet configured" - all visible libraries will be shown by default
    @Published var librariesShownOnHome: Set<String> {
        didSet {
            saveHomeLibraries()
        }
    }

    /// Track whether Home visibility has been explicitly configured
    @Published private(set) var homeVisibilityConfigured: Bool {
        didSet {
            userDefaults.set(homeVisibilityConfigured, forKey: homeVisibilityConfiguredKey)
        }
    }

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let hiddenLibrariesKey = "hiddenLibraryKeys"
    private let libraryOrderKey = "libraryOrder"
    private let homeLibrariesKey = "librariesShownOnHome"
    private let homeVisibilityConfiguredKey = "homeVisibilityConfigured"

    // MARK: - Initialization

    private init() {
        // Load hidden libraries
        if let hidden = userDefaults.array(forKey: hiddenLibrariesKey) as? [String] {
            self.hiddenLibraryKeys = Set(hidden)
        } else {
            self.hiddenLibraryKeys = []
        }

        // Load library order
        if let order = userDefaults.array(forKey: libraryOrderKey) as? [String] {
            self.libraryOrder = order
        } else {
            self.libraryOrder = []
        }

        // Load Home screen libraries
        if let homeLibs = userDefaults.array(forKey: homeLibrariesKey) as? [String] {
            self.librariesShownOnHome = Set(homeLibs)
        } else {
            self.librariesShownOnHome = []
        }

        // Load whether Home visibility has been configured
        self.homeVisibilityConfigured = userDefaults.bool(forKey: homeVisibilityConfiguredKey)
    }

    // MARK: - Public Methods

    /// Check if a library is visible
    func isLibraryVisible(_ libraryKey: String) -> Bool {
        !hiddenLibraryKeys.contains(libraryKey)
    }

    /// Toggle library visibility in sidebar
    /// When showing a library, it's automatically added to Home screen
    func toggleVisibility(for libraryKey: String) {
        if hiddenLibraryKeys.contains(libraryKey) {
            // Showing the library - also add to Home
            hiddenLibraryKeys.remove(libraryKey)
            if homeVisibilityConfigured {
                librariesShownOnHome.insert(libraryKey)
            }
        } else {
            hiddenLibraryKeys.insert(libraryKey)
        }
    }

    /// Show a library in sidebar (also adds to Home screen)
    func showLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.remove(libraryKey)
        if homeVisibilityConfigured {
            librariesShownOnHome.insert(libraryKey)
        }
    }

    /// Hide a library from sidebar
    func hideLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.insert(libraryKey)
    }

    // MARK: - Home Screen Visibility

    /// Check if a library should appear on the Home screen
    /// If not yet configured, all visible libraries are shown by default
    func isLibraryShownOnHome(_ libraryKey: String) -> Bool {
        if !homeVisibilityConfigured {
            // Not configured yet - show all visible libraries
            return isLibraryVisible(libraryKey)
        }
        return librariesShownOnHome.contains(libraryKey)
    }

    /// Set whether a library appears on the Home screen
    /// - Parameters:
    ///   - libraryKey: The library key
    ///   - shown: Whether to show on Home
    ///   - allLibraryKeys: All current library keys (needed for first-time setup)
    func setLibraryShownOnHome(_ libraryKey: String, shown: Bool, allLibraryKeys: [String]? = nil) {
        // When first configuring, populate with all libraries as ON, then apply change
        if !homeVisibilityConfigured {
            if let allKeys = allLibraryKeys {
                // Start with all libraries visible on Home
                for key in allKeys {
                    librariesShownOnHome.insert(key)
                }
            }
            homeVisibilityConfigured = true
        }

        if shown {
            librariesShownOnHome.insert(libraryKey)
        } else {
            librariesShownOnHome.remove(libraryKey)
        }
    }

    /// Toggle Home screen visibility for a library
    /// - Parameters:
    ///   - libraryKey: The library key to toggle
    ///   - allLibraryKeys: All current visible library keys (needed for first-time setup)
    func toggleHomeVisibility(for libraryKey: String, allLibraryKeys: [String] = []) {
        setLibraryShownOnHome(libraryKey, shown: !isLibraryShownOnHome(libraryKey), allLibraryKeys: allLibraryKeys)
    }

    /// Initialize Home visibility for all visible libraries
    /// Called when libraries are first loaded to set up defaults
    func initializeHomeVisibility(for libraries: [PlexLibrary]) {
        guard !homeVisibilityConfigured else { return }

        // Default: show all visible video and music libraries on Home
        for library in libraries where (library.isVideoLibrary || library.isMusicLibrary) && isLibraryVisible(library.key) {
            librariesShownOnHome.insert(library.key)
        }
        homeVisibilityConfigured = true
    }

    /// Move a library in the order list
    /// - Parameters:
    ///   - fromIndex: Source index in the ordered list
    ///   - toIndex: Destination index in the ordered list
    func moveLibrary(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < libraryOrder.count,
              toIndex >= 0, toIndex <= libraryOrder.count else {
            return
        }

        let key = libraryOrder.remove(at: fromIndex)
        let adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        libraryOrder.insert(key, at: min(adjustedIndex, libraryOrder.count))
    }

    /// Sort libraries according to saved preferences
    /// - Parameter libraries: The full list of libraries from Plex
    /// - Returns: Libraries sorted by user preference, with unordered ones at the end
    func sortLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        // Create a lookup for quick access
        // Use uniquingKeysWith to handle potential duplicate keys (keep first occurrence)
        let libraryByKey = Dictionary(
            libraries.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [PlexLibrary] = []

        // First, add libraries in the specified order
        for key in libraryOrder {
            if let library = libraryByKey[key] {
                result.append(library)
            }
        }

        // Then add any libraries not in the order list (in their original order)
        let orderedKeys = Set(libraryOrder)
        for library in libraries {
            if !orderedKeys.contains(library.key) {
                result.append(library)
            }
        }

        return result
    }

    /// Filter libraries to only visible ones
    /// - Parameter libraries: The full list of libraries
    /// - Returns: Only libraries that are not hidden
    func filterVisibleLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        libraries.filter { isLibraryVisible($0.key) }
    }

    /// Filter and sort libraries according to user preferences
    /// - Parameter libraries: The full list of libraries from Plex
    /// - Returns: Visible libraries sorted by user preference
    func filterAndSortLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        let visible = filterVisibleLibraries(libraries)
        return sortLibraries(visible)
    }

    /// Update the order list to include all current libraries
    /// This ensures new libraries get added to the order list
    func syncOrderWithLibraries(_ libraries: [PlexLibrary]) {
        let currentKeys = Set(libraries.map { $0.key })
        let orderedKeys = Set(libraryOrder)

        // Add any new libraries to the end of the order
        for library in libraries {
            if !orderedKeys.contains(library.key) {
                libraryOrder.append(library.key)

                // If Home visibility is already configured, add new video/music libraries to Home by default
                if homeVisibilityConfigured && (library.isVideoLibrary || library.isMusicLibrary) && isLibraryVisible(library.key) {
                    librariesShownOnHome.insert(library.key)
                }
            }
        }

        // Remove any libraries from order that no longer exist
        libraryOrder = libraryOrder.filter { currentKeys.contains($0) }

        // Also clean up hidden keys for libraries that no longer exist
        hiddenLibraryKeys = hiddenLibraryKeys.filter { currentKeys.contains($0) }

        // Clean up Home visibility for libraries that no longer exist
        librariesShownOnHome = librariesShownOnHome.filter { currentKeys.contains($0) }
    }

    /// Reset all library settings to defaults
    func resetToDefaults() {
        hiddenLibraryKeys = []
        libraryOrder = []
        librariesShownOnHome = []
        homeVisibilityConfigured = false
    }

    // MARK: - Private Methods

    private func saveHiddenLibraries() {
        userDefaults.set(Array(hiddenLibraryKeys), forKey: hiddenLibrariesKey)
    }

    private func saveLibraryOrder() {
        userDefaults.set(libraryOrder, forKey: libraryOrderKey)
    }

    private func saveHomeLibraries() {
        userDefaults.set(Array(librariesShownOnHome), forKey: homeLibrariesKey)
    }
}
