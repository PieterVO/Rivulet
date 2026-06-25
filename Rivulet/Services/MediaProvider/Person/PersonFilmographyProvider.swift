//
//  PersonFilmographyProvider.swift
//  Rivulet
//
//  Turns a MediaPerson into a PersonDetail by:
//    1. Fetching the Discover person (bio + filmography titles) via DiscoverPersonFetching.
//    2. Partitioning each title: server match via LibraryGUIDIndex -> playable PlexMediaMapper.item,
//       else metadata-only via PersonItemMapper.
//    3. Bucketing by movie/show and sorting server entries first (stable).
//
//  The fetcher and server-match closure are injected so the logic unit-tests with fakes.
//

import Foundation

// MARK: - Default server-match (module-level to sidestep @MainActor covariant-Self restriction)

/// Maps any guid in the list through LibraryGUIDIndex (actor) -> PlexMediaMapper.item.
/// @MainActor-isolated singletons are accessed via await MainActor.run {}.
private let _defaultServerMatch: @Sendable ([String]) async -> MediaItem? = { guids in
    for g in guids {
        guard let meta = await LibraryGUIDIndex.shared.lookup(guid: g) else { continue }
        let (serverURL, token, providerID): (String?, String?, String) = await MainActor.run {
            let url = PlexAuthManager.shared.selectedServerURL
            let tok = PlexAuthManager.shared.selectedServerToken
            let pid = MediaProviderRegistry.shared.primaryProvider?.id ?? url.map { "plex:\($0)" } ?? "plex:unknown"
            return (url, tok, pid)
        }
        guard let serverURL, let token else { continue }
        return PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
    }
    return nil
}

// MARK: - Provider

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {

    private let fetcher: DiscoverPersonFetching
    /// Returns a playable MediaItem if any of the guids is on the user's server, else nil.
    private let serverItemForGuids: @Sendable ([String]) async -> MediaItem?

    nonisolated init(
        fetcher: DiscoverPersonFetching = PlexDiscoverPersonService(),
        serverItemForGuids: @escaping @Sendable ([String]) async -> MediaItem? = _defaultServerMatch
    ) {
        self.fetcher = fetcher
        self.serverItemForGuids = serverItemForGuids
    }

    // MARK: - PersonFilmographyProviding

    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        guard let tagKey = person.tagKey else {
            return loadFallback(person: person)
        }

        let dto: DiscoverPersonDTO
        do {
            dto = try await fetcher.fetch(tagKey: tagKey)
        } catch {
            // No account token or network failure: degrade gracefully instead of propagating.
            return loadFallback(person: person)
        }

        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []

        for t in dto.titles {
            let entry: FilmographyEntry
            if let serverItem = await serverItemForGuids(t.guids) {
                entry = FilmographyEntry(item: serverItem, isOnServer: true)
            } else if let tmdbId = tmdbId(from: t.guids) {
                let item = PersonItemMapper.metadataOnlyItem(
                    tmdbId: tmdbId,
                    isMovie: t.isMovie,
                    title: t.title,
                    year: t.year,
                    posterURL: t.posterURL,
                    overview: nil)
                entry = FilmographyEntry(item: item, isOnServer: false)
            } else {
                continue // not on server and no tmdb id -> not actionable
            }

            if t.isMovie {
                movies.append(entry)
            } else {
                shows.append(entry)
            }
        }

        return PersonDetail(
            id: tagKey,
            name: dto.name.isEmpty ? person.name : dto.name,
            biography: dto.biography,
            portraitURL: dto.portraitURL ?? person.imageURL,
            movies: serverFirst(movies),
            shows: serverFirst(shows))
    }

    // MARK: - Helpers

    /// Stable partition: on-server entries first (relative order preserved), then off-server.
    nonisolated private func serverFirst(_ entries: [FilmographyEntry]) -> [FilmographyEntry] {
        entries.filter(\.isOnServer) + entries.filter { !$0.isOnServer }
    }

    nonisolated private func tmdbId(from guids: [String]) -> Int? {
        for g in guids where g.hasPrefix("tmdb://") {
            return Int(g.dropFirst("tmdb://".count))
        }
        return nil
    }

    // MARK: - Fallback (no Discover person / fetch failure)

    /// Returns name + portrait with empty rows.
    /// TODO(Task 5b): implement origin-library query via
    /// /library/sections/{originSectionKey}/all?actor={originActorId}
    /// via PlexNetworkManager, map with PlexMediaMapper.item as on-server entries, bucket by type.
    nonisolated private func loadFallback(person: MediaPerson) -> PersonDetail {
        PersonDetail(
            id: person.tagKey ?? person.id,
            name: person.name,
            biography: nil,
            portraitURL: person.imageURL,
            movies: [],
            shows: [])
    }
}
