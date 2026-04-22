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
}
