//
//  MusicProviderRegistry.swift
//  Rivulet
//
//  Sibling to MediaProviderRegistry, holding MusicProvider instances keyed
//  by provider ID. Same ID convention ("plex:<machineID>") lets a single
//  backend register into both registries and be cross-referenced via
//  MediaItemRef.providerID.
//

import Foundation

@Observable @MainActor
final class MusicProviderRegistry {
    static let shared = MusicProviderRegistry()

    private(set) var providers: [String: any MusicProvider] = [:]

    func provider(for id: String) -> (any MusicProvider)? {
        providers[id]
    }

    func enabledProviders() -> [any MusicProvider] {
        Array(providers.values)
    }

    var primaryProvider: (any MusicProvider)? {
        providers.values.first
    }

    func register(_ provider: any MusicProvider) {
        providers[provider.id] = provider
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
    }

    /// Reads the active Plex auth state from `PlexAuthManager.shared` and
    /// creates/updates the corresponding `PlexMusicProvider` entry. Called at
    /// app launch and after auth-state changes (sign-in, sign-out, server
    /// switch). Wave 1 single-server: at most one provider entry.
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        guard
            let serverURL = auth.selectedServerURL,
            let token = auth.selectedServerToken
        else {
            providers.removeAll()
            return
        }
        let machineID: String = {
            if let id = auth.selectedServer?.machineIdentifier { return id }
            return Self.stableHash(of: serverURL)
        }()
        let displayName = auth.selectedServer?.name
            ?? UserDefaults.standard.string(forKey: "selectedServerName")
            ?? "Plex"
        let provider = PlexMusicProvider(
            machineIdentifier: machineID,
            displayName: displayName,
            serverURL: serverURL,
            authToken: token
        )
        register(provider)
    }

    /// Process-stable hash. Avoid `String.hashValue` (per-process randomized).
    private static func stableHash(of input: String) -> String {
        // FNV-1a 64-bit — small, deterministic, no Crypto dependency.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
