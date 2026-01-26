//
//  PlexUserProfileManager.swift
//  Rivulet
//
//  Manages Plex Home user profile selection and persistence
//

import Foundation
import Combine

/// Manages user profile selection for Plex Home accounts
@MainActor
class PlexUserProfileManager: ObservableObject {
    static let shared = PlexUserProfileManager()

    // MARK: - Published State

    /// All available users in the Plex Home
    @Published var homeUsers: [PlexHomeUser] = []

    /// Currently selected user profile
    @Published var selectedUser: PlexHomeUser?

    /// Loading state for user fetch
    @Published var isLoadingUsers = false

    /// Error message if user fetch fails
    @Published var usersError: String?

    /// Whether to show profile picker on app launch
    @Published var showProfilePickerOnLaunch: Bool {
        didSet {
            userDefaults.set(showProfilePickerOnLaunch, forKey: showProfilePickerOnLaunchKey)
        }
    }

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let selectedUserIdKey = "selectedPlexUserId"
    private let selectedUserUUIDKey = "selectedPlexUserUUID"
    private let selectedUserNameKey = "selectedPlexUserName"
    private let showProfilePickerOnLaunchKey = "showPlexProfilePickerOnLaunch"

    // MARK: - Dependencies

    private let networkManager = PlexNetworkManager.shared

    // MARK: - Computed Properties

    /// The selected user's ID for API headers, or nil for default behavior
    var selectedUserId: Int? {
        selectedUser?.id
    }

    /// Whether the Plex Home has multiple profiles to choose from
    var hasMultipleProfiles: Bool {
        homeUsers.count > 1
    }

    /// Whether the current user is the admin/owner
    var isAdminUser: Bool {
        selectedUser?.admin ?? true
    }

    /// Whether profiles have been loaded
    var hasLoadedProfiles: Bool {
        !homeUsers.isEmpty
    }

    // MARK: - Initialization

    private init() {
        // Load saved preference for profile picker
        showProfilePickerOnLaunch = userDefaults.bool(forKey: showProfilePickerOnLaunchKey)

        print("👤 PlexUserProfileManager: Initialized")
        print("👤 PlexUserProfileManager: Show picker on launch: \(showProfilePickerOnLaunch)")

        // Load saved user info (will be validated when fetchHomeUsers is called)
        if let savedId = userDefaults.object(forKey: selectedUserIdKey) as? Int {
            print("👤 PlexUserProfileManager: Saved user ID: \(savedId)")
        }
    }

    // MARK: - Public Methods

    /// Fetch all users in the Plex Home
    /// Call this after authentication and on app launch
    func fetchHomeUsers() async {
        guard let authToken = PlexAuthManager.shared.authToken else {
            print("👤 PlexUserProfileManager: No auth token, skipping user fetch")
            return
        }

        isLoadingUsers = true
        usersError = nil

        do {
            let users = try await networkManager.getHomeUsers(authToken: authToken)
            homeUsers = users

            print("👤 PlexUserProfileManager: Loaded \(users.count) home users")
            for user in users {
                print("👤   - \(user.displayName) (id: \(user.id), admin: \(user.admin), protected: \(user.protected))")
            }

            // Restore previously selected user or default to admin
            await restoreOrSelectDefaultUser()

            isLoadingUsers = false
        } catch {
            print("👤 PlexUserProfileManager: Failed to fetch home users: \(error)")
            usersError = "Failed to load profiles"
            isLoadingUsers = false

            // If we can't fetch users, default to single-user mode (no profile switching)
            // The admin user's content will be shown via the main auth token
            homeUsers = []
            selectedUser = nil
        }
    }

    /// Select a user profile
    /// - Parameters:
    ///   - user: The user to switch to
    ///   - pin: Optional PIN if the user profile is protected
    /// - Returns: True if selection succeeded
    @discardableResult
    func selectUser(_ user: PlexHomeUser, pin: String? = nil) async -> Bool {
        print("👤 PlexUserProfileManager: selectUser called for \(user.displayName) (uuid: \(user.uuid))")

        // PIN required but not provided
        if user.requiresPin && (pin == nil || pin?.isEmpty == true) {
            print("👤 PlexUserProfileManager: PIN required but not provided")
            return false
        }

        // Call switch endpoint to get user-specific plex.tv token
        guard let authToken = PlexAuthManager.shared.authToken else {
            print("👤 PlexUserProfileManager: No auth token available")
            return false
        }

        print("👤 PlexUserProfileManager: Calling switch endpoint...")

        do {
            let userPlexToken = try await networkManager.switchToHomeUser(
                userUUID: user.uuid,
                pin: pin,
                authToken: authToken
            )

            guard let userPlexToken = userPlexToken else {
                print("👤 PlexUserProfileManager: Invalid PIN for \(user.displayName)")
                return false
            }

            print("👤 PlexUserProfileManager: Got plex.tv token, fetching server access token...")

            // Now get the server-specific access token using the user's plex.tv token
            guard let serverURL = PlexAuthManager.shared.selectedServerURL else {
                print("👤 PlexUserProfileManager: No server URL available")
                return false
            }

            print("👤 PlexUserProfileManager: Server URL: \(serverURL)")

            let serverAccessToken = await networkManager.getServerAccessToken(
                authToken: userPlexToken,
                serverURL: serverURL
            )

            guard let serverAccessToken = serverAccessToken else {
                print("👤 PlexUserProfileManager: Could not get server access token")
                return false
            }

            print("👤 PlexUserProfileManager: Got server access token, updating auth manager...")

            // Update the server token with the user's server-specific token
            PlexAuthManager.shared.updateServerToken(serverAccessToken)

            // Update selected user
            let previousUser = selectedUser
            selectedUser = user
            saveSelectedUser(user)

            print("👤 PlexUserProfileManager: ✅ Switched to \(user.displayName) (id: \(user.id))")

            // Notify data store to reload if user actually changed
            if previousUser?.id != user.id {
                print("👤 PlexUserProfileManager: User changed, triggering data reload...")
                await PlexDataStore.shared.onProfileSwitched()
            }

            return true
        } catch {
            print("👤 PlexUserProfileManager: ❌ Switch failed: \(error)")
            return false
        }
    }

    /// Reset profile state (call on sign out)
    func reset() {
        homeUsers = []
        selectedUser = nil
        usersError = nil

        // Clear persisted selection
        userDefaults.removeObject(forKey: selectedUserIdKey)
        userDefaults.removeObject(forKey: selectedUserUUIDKey)
        userDefaults.removeObject(forKey: selectedUserNameKey)

        print("👤 PlexUserProfileManager: Reset - cleared all profile data")
    }

    // MARK: - Private Methods

    /// Restore previously selected user or select the admin user
    private func restoreOrSelectDefaultUser() async {
        // Try to find previously selected user
        if let savedId = userDefaults.object(forKey: selectedUserIdKey) as? Int,
           let savedUser = homeUsers.first(where: { $0.id == savedId }) {

            // For non-protected users, switch to get their token
            if !savedUser.requiresPin {
                let success = await selectUser(savedUser, pin: nil)
                if success {
                    print("👤 PlexUserProfileManager: Restored previous user: \(savedUser.displayName)")
                    return
                }
            }

            // For protected users or if switch failed, just set locally
            // They'll need to re-enter PIN if they want their specific content
            selectedUser = savedUser
            print("👤 PlexUserProfileManager: Restored previous user (PIN required): \(savedUser.displayName)")
            return
        }

        // Default to admin user
        if let adminUser = homeUsers.first(where: { $0.admin }) {
            let success = await selectUser(adminUser, pin: nil)
            if !success {
                // Fallback: just set locally
                selectedUser = adminUser
                saveSelectedUser(adminUser)
            }
            print("👤 PlexUserProfileManager: Defaulted to admin user: \(adminUser.displayName)")
        } else if let firstUser = homeUsers.first, !firstUser.requiresPin {
            // Fallback to first non-protected user
            let success = await selectUser(firstUser, pin: nil)
            if !success {
                selectedUser = firstUser
                saveSelectedUser(firstUser)
            }
            print("👤 PlexUserProfileManager: Defaulted to first user: \(firstUser.displayName)")
        }
    }

    /// Save selected user to UserDefaults
    private func saveSelectedUser(_ user: PlexHomeUser) {
        userDefaults.set(user.id, forKey: selectedUserIdKey)
        userDefaults.set(user.uuid, forKey: selectedUserUUIDKey)
        userDefaults.set(user.displayName, forKey: selectedUserNameKey)
    }
}
