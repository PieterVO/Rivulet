//
//  PersonFilmographyProvider.swift
//  Rivulet
//
//  Turns a MediaPerson into a PersonDetail:
//    - Filmography: the person's titles on the user's Plex server, via the
//      origin library `?actor=` filter (Plex is the filmography source).
//    - Biography + portrait: TMDB (Plex exposes no actor-bio API). Resolved via
//      the originating title's TMDB credits + a name match, then /tmdb/person.
//  The two data sources are injected so the logic unit-tests with fakes.
//

import Foundation

// MARK: - Default origin-library lookup (server ?actor= filmography)

/// Queries /library/sections/{sectionKey}/all?actor={actorId} on the selected server
/// and maps results as on-server MediaItems. Returns [] on any failure.
private let _defaultOriginLibraryItems: @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem] = { sectionKey, actorId in
    let (serverURL, token, providerID): (String?, String?, String) = await MainActor.run {
        let url = PlexAuthManager.shared.selectedServerURL
        let tok = PlexAuthManager.shared.selectedServerToken
        let pid = MediaProviderRegistry.shared.primaryProvider?.id ?? url.map { "plex:\($0)" } ?? "plex:unknown"
        return (url, tok, pid)
    }
    guard let serverURL, let token else { return [] }
    guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionKey)/all") else { return [] }
    components.queryItems = [URLQueryItem(name: "actor", value: actorId)]
    guard let url = components.url else { return [] }
    let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(
        url, headers: PlexNetworkManager.shared.plexHeaders(authToken: token))
    let metadatas = container?.MediaContainer.Metadata ?? []
    return metadatas.compactMap { PlexMediaMapper.item($0, providerID: providerID, serverURL: serverURL, authToken: token) }
}

// MARK: - Default person-info lookup (TMDB bio + portrait)

private let _defaultPersonInfo: @Sendable (MediaPerson) async -> (biography: String?, portraitURL: URL?)? = { person in
    guard let titleTmdbId = person.titleTmdbId else { return nil }
    let type: TMDBMediaType = person.titleIsMovie ? .movie : .tv
    return await TMDBClient.shared.actorInfo(titleTmdbId: titleTmdbId, type: type, actorName: person.name)
}

// MARK: - Provider

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {

    private let originLibraryItems: @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem]
    private let personInfo: @Sendable (MediaPerson) async -> (biography: String?, portraitURL: URL?)?

    nonisolated init(
        originLibraryItems: @escaping @Sendable (_ sectionKey: String, _ actorId: String) async -> [MediaItem] = _defaultOriginLibraryItems,
        personInfo: @escaping @Sendable (MediaPerson) async -> (biography: String?, portraitURL: URL?)? = _defaultPersonInfo
    ) {
        self.originLibraryItems = originLibraryItems
        self.personInfo = personInfo
    }

    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        async let filmTask = serverFilmography(person)
        async let infoTask = personInfo(person)
        let (movies, shows) = await filmTask
        let info = await infoTask
        return PersonDetail(
            id: person.tagKey ?? person.id,
            name: person.name,
            biography: info?.biography,
            portraitURL: info?.portraitURL ?? person.imageURL,
            movies: movies,
            shows: shows)
    }

    /// Server `?actor=` filmography (origin library), bucketed by kind. All on-server.
    nonisolated private func serverFilmography(_ person: MediaPerson) async -> (movies: [FilmographyEntry], shows: [FilmographyEntry]) {
        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []
        guard let sectionKey = person.originSectionKey, let actorId = person.originActorId else {
            return ([], [])
        }
        let items = await originLibraryItems(sectionKey, actorId)
        for item in items {
            let entry = FilmographyEntry(item: item, isOnServer: true)
            switch item.kind {
            case .movie: movies.append(entry)
            case .show: shows.append(entry)
            default: break
            }
        }
        return (movies, shows)
    }
}
