//
//  PlexDiscoverPersonService.swift
//  Rivulet
//
//  Fetches person bio + portrait + filmography from Plex Discover
//  (metadata.provider.plex.tv) using the account token. Returns a DiscoverPersonDTO.
//
//  NOTE: The filmography sub-path (/children) is ASSUMED. The #if DEBUG [PersonSpike]
//  prints below log the raw JSON so the real shape can be confirmed on-device in Task 4b
//  before the provider is trusted. Do NOT remove them until Task 4b.
//

import Foundation

// MARK: - DTOs

nonisolated struct DiscoverPersonTitle: Sendable {
    let guids: [String]
    let isMovie: Bool
    let title: String
    let year: Int?
    let posterURL: URL?
}

nonisolated struct DiscoverPersonDTO: Sendable {
    let name: String
    let biography: String?
    let portraitURL: URL?
    let titles: [DiscoverPersonTitle]
}

// MARK: - Protocol

protocol DiscoverPersonFetching: Sendable {
    func fetch(tagKey: String) async throws -> DiscoverPersonDTO
}

// MARK: - Service

final class PlexDiscoverPersonService: DiscoverPersonFetching {
    private let host = "https://metadata.provider.plex.tv"
    private let session: URLSession = .shared

    func fetch(tagKey: String) async throws -> DiscoverPersonDTO {
        // PlexAuthManager is @MainActor; hop to obtain the token.
        let token = await MainActor.run { PlexAuthManager.shared.authToken }
        guard let token else {
            throw PlexAPIError.invalidURL   // no account token; caller falls back
        }
        let personData = try await get("/library/metadata/\(tagKey)", token: token)
        // ASSUMED sub-path. Confirm/adjust in Task 4b after reading the spike logs.
        let filmData = try await get("/library/metadata/\(tagKey)/children?includeGuids=1", token: token)
        #if DEBUG
        print("[PersonSpike] person=\(String(data: personData, encoding: .utf8)?.prefix(400) ?? "")")
        print("[PersonSpike] films=\(String(data: filmData, encoding: .utf8)?.prefix(800) ?? "")")
        #endif
        return try Self.decode(personData: personData, filmographyData: filmData)
    }

    private func get(_ path: String, token: String) async throws -> Data {
        let sep = path.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(host)\(path)\(sep)X-Plex-Token=\(token)") else {
            throw PlexAPIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        req.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        let (data, _) = try await session.data(for: req)
        return data
    }

    /// Pure decode function — tested directly against fixtures.
    /// Uses `PlexMediaContainerWrapper` (the existing `{ "MediaContainer": { "Metadata": [...] } }`
    /// wrapper already used throughout the codebase) to decode both person and filmography payloads.
    static func decode(personData: Data, filmographyData: Data) throws -> DiscoverPersonDTO {
        let dec = JSONDecoder()
        let personContainer = try dec.decode(PlexMediaContainerWrapper.self, from: personData)
        let person = personContainer.MediaContainer.Metadata?.first

        let filmContainer = try dec.decode(PlexMediaContainerWrapper.self, from: filmographyData)
        let titles: [DiscoverPersonTitle] = (filmContainer.MediaContainer.Metadata ?? []).compactMap { m in
            guard let title = m.title else { return nil }
            let guids = (m.Guid ?? []).compactMap { $0.id }
            let poster = m.thumb.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }
            return DiscoverPersonTitle(
                guids: guids,
                isMovie: (m.type ?? "movie") == "movie",
                title: title,
                year: m.year,
                posterURL: poster)
        }
        let portrait = person?.thumb.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }
        return DiscoverPersonDTO(
            name: person?.title ?? "",
            biography: person?.summary,
            portraitURL: portrait,
            titles: titles)
    }
}
