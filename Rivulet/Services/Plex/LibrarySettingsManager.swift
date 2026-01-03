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

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let hiddenLibrariesKey = "hiddenLibraryKeys"
    private let libraryOrderKey = "libraryOrder"

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

    }

    // MARK: - Public Methods

    /// Check if a library is visible
    func isLibraryVisible(_ libraryKey: String) -> Bool {
        !hiddenLibraryKeys.contains(libraryKey)
    }

    /// Toggle library visibility
    func toggleVisibility(for libraryKey: String) {
        if hiddenLibraryKeys.contains(libraryKey) {
            hiddenLibraryKeys.remove(libraryKey)
        } else {
            hiddenLibraryKeys.insert(libraryKey)
        }
    }

    /// Show a library
    func showLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.remove(libraryKey)
    }

    /// Hide a library
    func hideLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.insert(libraryKey)
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
            }
        }

        // Remove any libraries from order that no longer exist
        libraryOrder = libraryOrder.filter { currentKeys.contains($0) }

        // Also clean up hidden keys for libraries that no longer exist
        hiddenLibraryKeys = hiddenLibraryKeys.filter { currentKeys.contains($0) }
    }

    /// Reset all library settings to defaults
    func resetToDefaults() {
        hiddenLibraryKeys = []
        libraryOrder = []
    }

    // MARK: - Private Methods

    private func saveHiddenLibraries() {
        userDefaults.set(Array(hiddenLibraryKeys), forKey: hiddenLibrariesKey)
    }

    private func saveLibraryOrder() {
        userDefaults.set(libraryOrder, forKey: libraryOrderKey)
    }
}
