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

// MARK: - Default origin-library lookup (module-level; mirrors _defaultServerMatch pattern)

/// Queries /library/sections/{sectionKey}/all?actor={actorId} on the user's selected server
/// and maps results as on-server MediaItems via PlexMediaMapper.
/// Returns [] on any failure (missing creds, network error, decode error).
private let _defaultOriginLibraryItems: @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem] = { sectionKey, actorId in
    // Single MainActor hop to read all shared state together (avoid TOCTOU).
    let (serverURL, token, providerID): (String?, String?, String) = await MainActor.run {
        let url = PlexAuthManager.shared.selectedServerURL
        let tok = PlexAuthManager.shared.selectedServerToken
        let pid = MediaProviderRegistry.shared.primaryProvider?.id ?? url.map { "plex:\($0)" } ?? "plex:unknown"
        return (url, tok, pid)
    }
    guard let serverURL, let token else { return [] }

    guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionKey)/all") else {
        return []
    }
    components.queryItems = [URLQueryItem(name: "actor", value: actorId)]
    guard let url = components.url else { return [] }

    let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(
        url,
        headers: PlexNetworkManager.shared.plexHeaders(authToken: token)
    )
    let metadatas = container?.MediaContainer.Metadata ?? []

    return metadatas.compactMap { meta in
        PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
    }
}

// MARK: - Provider

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {

    private let fetcher: DiscoverPersonFetching
    /// Returns a playable MediaItem if any of the guids is on the user's server, else nil.
    private let serverItemForGuids: @Sendable ([String]) async -> MediaItem?
    /// Queries the origin Plex library section by actorId, returns on-server items.
    private let originLibraryItems: @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem]

    nonisolated init(
        fetcher: DiscoverPersonFetching = PlexDiscoverPersonService(),
        serverItemForGuids: @escaping @Sendable ([String]) async -> MediaItem? = _defaultServerMatch,
        originLibraryItems: @escaping @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem] = _defaultOriginLibraryItems
    ) {
        self.fetcher = fetcher
        self.serverItemForGuids = serverItemForGuids
        self.originLibraryItems = originLibraryItems
    }

    // MARK: - PersonFilmographyProviding

    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        guard let tagKey = person.tagKey else {
            return await loadFallback(person: person)
        }

        let dto: DiscoverPersonDTO
        do {
            dto = try await fetcher.fetch(tagKey: tagKey)
        } catch {
            // No account token or network failure: degrade gracefully instead of propagating.
            return await loadFallback(person: person)
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

    /// When we have originSectionKey + originActorId, queries the origin Plex library section
    /// and returns items bucketed as on-server entries. Degrades to empty rows on any failure.
    nonisolated private func loadFallback(person: MediaPerson) async -> PersonDetail {
        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []

        if let sectionKey = person.originSectionKey, let actorId = person.originActorId {
            let items = await originLibraryItems(sectionKey, actorId)
            for item in items {
                let entry = FilmographyEntry(item: item, isOnServer: true)
                switch item.kind {
                case .movie:
                    movies.append(entry)
                case .show:
                    shows.append(entry)
                default:
                    break
                }
            }
        }

        return PersonDetail(
            id: person.tagKey ?? person.id,
            name: person.name,
            biography: nil,
            portraitURL: person.imageURL,
            movies: movies,
            shows: shows)
    }
}
