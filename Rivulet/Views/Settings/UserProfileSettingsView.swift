//
//  UserProfileSettingsView.swift
//  Rivulet
//
//  Settings view for Plex Home user profile selection
//

import SwiftUI

struct UserProfileSettingsView: View {
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @State private var showPinEntry = false
    @State private var selectedUserForPin: PlexHomeUser?
    @State private var pinEntryError: String?
    @State private var isLoading = false
    @FocusState private var focusedUserId: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                Text("User Profiles")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 80)
                    .padding(.top, 60)

                VStack(spacing: 24) {
                    if profileManager.isLoadingUsers {
                        // Loading state
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading profiles...")
                                .font(.system(size: 26))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else if profileManager.homeUsers.isEmpty {
                        // No profiles (single user or error)
                        VStack(spacing: 20) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 80, weight: .thin))
                                .foregroundStyle(.white.opacity(0.5))

                            Text("No Plex Home")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("Plex Home is not set up for this account.\nYou can create managed users on plex.tv.")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        // Current profile card
                        if let currentUser = profileManager.selectedUser {
                            SettingsSection(title: "Current Profile") {
                                CurrentProfileCard(user: currentUser)
                            }
                        }

                        // Available profiles
                        SettingsSection(title: "Available Profiles") {
                            ForEach(profileManager.homeUsers) { user in
                                ProfileRow(
                                    user: user,
                                    isSelected: user.id == profileManager.selectedUser?.id,
                                    isLoading: isLoading && selectedUserForPin?.id == user.id,
                                    isFocused: focusedUserId == user.id
                                ) {
                                    selectProfile(user)
                                }
                                .focused($focusedUserId, equals: user.id)
                            }
                        }

                        // Settings
                        SettingsSection(title: "Behavior") {
                            SettingsToggleRow(
                                icon: "person.2.square.stack",
                                iconColor: .purple,
                                title: "Profile Picker on Launch",
                                subtitle: "Choose profile when app opens",
                                isOn: $profileManager.showProfilePickerOnLaunch
                            )
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 80)
            }
        }
        .background(Color.black)
        .sheet(isPresented: $showPinEntry) {
            if let user = selectedUserForPin {
                PinEntrySheet(
                    user: user,
                    error: $pinEntryError,
                    onSubmit: { pin in
                        Task {
                            await verifyAndSwitch(user: user, pin: pin)
                        }
                    },
                    onCancel: {
                        showPinEntry = false
                        selectedUserForPin = nil
                        pinEntryError = nil
                    }
                )
            }
        }
        .onAppear {
            // Focus first profile if none focused
            if focusedUserId == nil, let first = profileManager.homeUsers.first {
                focusedUserId = first.id
            }
        }
    }

    private func selectProfile(_ user: PlexHomeUser) {
        if user.requiresPin {
            selectedUserForPin = user
            pinEntryError = nil
            showPinEntry = true
        } else {
            Task {
                isLoading = true
                selectedUserForPin = user
                _ = await profileManager.selectUser(user, pin: nil)
                isLoading = false
                selectedUserForPin = nil
            }
        }
    }

    private func verifyAndSwitch(user: PlexHomeUser, pin: String) async {
        isLoading = true
        pinEntryError = nil

        let success = await profileManager.selectUser(user, pin: pin)

        if success {
            showPinEntry = false
            selectedUserForPin = nil
        } else {
            pinEntryError = "Incorrect PIN. Please try again."
        }

        isLoading = false
    }
}

// MARK: - Current Profile Card

private struct CurrentProfileCard: View {
    let user: PlexHomeUser

    var body: some View {
        HStack(spacing: 20) {
            // Avatar
            ProfileAvatar(user: user, size: 80)

            VStack(alignment: .leading, spacing: 6) {
                Text(user.displayName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    if user.admin {
                        ProfileBadge(text: "Admin", color: .blue)
                    }
                    if user.restricted {
                        ProfileBadge(text: "Managed", color: .orange)
                    }
                    if user.protected {
                        ProfileBadge(text: "PIN", color: .purple)
                    }
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    let user: PlexHomeUser
    let isSelected: Bool
    let isLoading: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                // Avatar
                ProfileAvatar(user: user, size: 64)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        if user.admin {
                            Text("Account Owner")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        } else if user.restricted {
                            Text("Managed User")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        if user.protected {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }

                Spacer()

                // Status indicator
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Profile Avatar

private struct ProfileAvatar: View {
    let user: PlexHomeUser
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbURL = user.thumb, let url = URL(string: thumbURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        avatarPlaceholder
                    case .failure:
                        avatarPlaceholder
                    @unknown default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(.white.opacity(0.2), lineWidth: 2)
        )
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(profileColor.gradient)

            Text(user.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var profileColor: Color {
        // Generate a consistent color based on user ID
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        return colors[abs(user.id) % colors.count]
    }
}

// MARK: - Profile Badge

private struct ProfileBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.8))
            )
    }
}

// MARK: - PIN Entry Sheet (tvOS number pad)

struct PinEntrySheet: View {
    let user: PlexHomeUser
    @Binding var error: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""
    @FocusState private var focusedButton: String?

    private let numberPadLayout: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete", "0", "submit"]
    ]

    var body: some View {
        VStack(spacing: 50) {
            // Header
            VStack(spacing: 16) {
                ProfileAvatar(user: user, size: 100)

                Text(user.displayName)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)

                Text("Enter PIN to switch profile")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // PIN display
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        PinDigitView(
                            digit: pin.count > index ? "•" : "",
                            isFilled: pin.count > index
                        )
                    }
                }

                if let error = error {
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
            }

            // Number pad
            VStack(spacing: 12) {
                ForEach(numberPadLayout, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { key in
                            PinPadButton(
                                key: key,
                                pin: $pin,
                                isFocused: focusedButton == key,
                                onSubmit: {
                                    if pin.count == 4 {
                                        onSubmit(pin)
                                    }
                                }
                            )
                            .focused($focusedButton, equals: key)
                        }
                    }
                }
            }

            // Cancel button
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 20)
            .focused($focusedButton, equals: "cancel")
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            focusedButton = "1"
        }
        .onChange(of: pin) { _, newValue in
            if newValue.count == 4 {
                onSubmit(newValue)
            }
        }
    }
}

// MARK: - Number Pad Button

private struct PinPadButton: View {
    let key: String
    @Binding var pin: String
    let isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
                    .frame(width: 90, height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )

                if key == "delete" {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                } else if key == "submit" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(key)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var backgroundColor: Color {
        if key == "submit" && pin.count == 4 {
            return .blue.opacity(0.6)
        }
        return isFocused ? .white.opacity(0.18) : .white.opacity(0.08)
    }

    private func handleTap() {
        switch key {
        case "delete":
            if !pin.isEmpty {
                pin.removeLast()
            }
        case "submit":
            onSubmit()
        default:
            if pin.count < 4 {
                pin += key
            }
        }
    }
}

private struct PinDigitView: View {
    let digit: String
    let isFilled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isFilled ? 0.2 : 0.1))
                .frame(width: 60, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 2)
                )

            Text(digit)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    UserProfileSettingsView()
}
