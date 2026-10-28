// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension SiloProvider {
    func hubs() async throws -> [MediaHub] {
        let layout: SiloSectionLayout = try await client.get("home/layout")
        return try await sectionHubs(layout.sections, libraryID: nil)
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        let layout: SiloSectionLayout = try await client.get("library/\(Self.pathComponent(library.id))/layout")
        return try await sectionHubs(layout.sections, libraryID: library.id)
    }

    private func sectionHubs(_ sections: [SiloSectionEntry], libraryID: String?) async throws -> [MediaHub] {
        // Layout order is profile-configured. Featured rows stay at their exact
        // position, rather than being promoted over earlier non-featured rows.
        var hubs: [MediaHub] = []
        for section in sections {
            let route = SiloHubRoute(scope: libraryID == nil ? "home" : "library", sectionId: section.id, libraryId: libraryID)
            let suffix = section.sectionType == "continue_watching" ? "continueWatching" : section.sectionType == "recently_added" ? "recentlyAdded" : section.id
            let identifier = try route.identifier(suffix: suffix)
            let result = try await hubItems(identifier, page: Page(offset: 0, limit: min(max(section.itemLimit, 1), 200)))
            var hub = MediaHub(id: identifier, providerID: id, title: section.title,
                               style: section.featured ? .hero : .shelf, items: result.items)
            hub.total = result.total
            hub.nextPage = result.nextPage
            hubs.append(hub)
        }
        return hubs
    }

    func hubItems(_ hubID: String, page: Page) async throws -> PagedResult<MediaItem> {
        let route = try SiloHubRoute.decode(hubID)
        if route.scope == "recommendations", let kind = route.kind {
            // Recommendation sections are bounded by their contract (60 cards),
            // not cursor paged. Fetch their dedicated section rather than
            // substituting another catalog order or a TMDB feed.
            guard page.offset == 0 else { return PagedResult(items: [], total: 0, nextPage: nil) }
            var query = [URLQueryItem(name: "limit", value: "60")]
            if let key = route.key { query.append(URLQueryItem(name: "key", value: key)) }
            let result: SiloList<SiloItem> = try await getArtwork("recommendations/section/\(Self.pathComponent(kind))", query)
            let items = map(result.items)
            return PagedResult(items: items, total: items.count, nextPage: nil)
        }
        guard let sectionID = route.sectionId else { throw MediaProviderError.notFound }
        var query = [URLQueryItem(name: "source", value: "section"),
                     URLQueryItem(name: "scope", value: route.scope),
                     URLQueryItem(name: "section_id", value: sectionID)]
        if let libraryID = route.libraryId { query.append(URLQueryItem(name: "library_id", value: libraryID)) }
        return try await catalog(query, page: page)
    }

    func discoveryHubs() async throws -> [MediaHub]? {
        let result: SiloList<SiloRecommendationRow> = try await getArtwork("recommendations/discover")
        var hubs: [MediaHub] = []
        for (index, row) in result.items.enumerated() {
            let route = SiloHubRoute(scope: "recommendations", kind: row.kind, key: row.key)
            let identifier = try route.identifier(suffix: "\(index).\(row.type)")
            var items = map(row.items)
            // Dedicated rows can hold more than their preview. Load their
            // complete bounded section up front, so the grid never advertises
            // a fabricated cursor or loses cards after the preview.
            if row.kind != nil {
                items = try await hubItems(identifier, page: Page(offset: 0, limit: 60)).items
            }
            var hub = MediaHub(id: identifier, providerID: id, title: row.title, style: .shelf, items: items)
            hub.total = items.count
            hub.canBrowse = row.kind != nil
            hubs.append(hub)
        }
        return hubs
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await homeSection(type: "continue_watching", libraryID: nil, limit: limit)?.items ?? []
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        if let section = try await homeSection(type: "recently_added", libraryID: nil, limit: limit) { return section.items }
        return try await catalog([URLQueryItem(name: "type", value: "video"), URLQueryItem(name: "sort", value: "-added_at")],
                                 page: Page(offset: 0, limit: limit)).items
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        try await homeSection(type: "recently_added", libraryID: library.id, limit: 20)
    }

    private func homeSection(type: String, libraryID: String?, limit: Int) async throws -> MediaHub? {
        guard limit > 0 else { return nil }
        let path = libraryID.map { "library/\(Self.pathComponent($0))/layout" } ?? "home/layout"
        let layout: SiloSectionLayout = try await client.get(path)
        guard let section = layout.sections.first(where: { $0.sectionType == type }) else { return nil }
        let route = SiloHubRoute(scope: libraryID == nil ? "home" : "library", sectionId: section.id, libraryId: libraryID)
        let suffix = type == "continue_watching" ? "continueWatching" : "recentlyAdded"
        let identifier = try route.identifier(suffix: suffix)
        let result = try await hubItems(identifier, page: Page(offset: 0, limit: min(limit, 200)))
        var hub = MediaHub(id: identifier, providerID: id, title: section.title,
                           style: section.featured ? .hero : .shelf, items: result.items)
        hub.total = result.total
        hub.nextPage = result.nextPage
        return hub
    }
}
