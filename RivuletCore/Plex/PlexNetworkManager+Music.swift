// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+Music.swift
//  Rivulet
//
//  Music-only endpoints: the genre directory, audio playlist listing and lyrics.
//

import Foundation

// MARK: - Response shapes

/// One row of `/library/sections/{id}/genre`. `key` is the id a `genre=` filter takes.
nonisolated struct PlexGenreDirectory: Decodable, Sendable {
    let key: String
    let title: String
}

nonisolated struct PlexGenreContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Directory: [PlexGenreDirectory]?
    }
    let MediaContainer: Container
}

/// The server's parsed form of a lyric stream. Offsets are milliseconds;
/// an untimed line has no `startOffset`.
nonisolated struct PlexLyrics: Decodable, Sendable {
    nonisolated struct Line: Decodable, Sendable {
        nonisolated struct Span: Decodable, Sendable {
            let text: String?
        }
        let startOffset: Int?
        let Span: [Span]?
    }
    let Line: [Line]?
}

nonisolated struct PlexLyricsContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Lyrics: [PlexLyrics]?
    }
    let MediaContainer: Container
}

// MARK: - Requests

extension PlexNetworkManager {

    /// Genre directory of a section for one item type (8 artist, 9 album, 10 track).
    /// Without `type` the server answers with artist genres only.
    func getGenres(
        serverURL: String,
        authToken: String,
        sectionId: String,
        type: Int
    ) async throws -> [PlexGenreDirectory] {
        guard let url = URL(string: "\(serverURL)/library/sections/\(sectionId)/genre?type=\(type)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexGenreContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Directory ?? []
    }

    /// Audio playlists that hold tracks from one section.
    func getAudioPlaylists(
        serverURL: String,
        authToken: String,
        sectionId: String,
        sort: String
    ) async throws -> [PlexPlaylist] {
        try await getPlaylists(serverURL: serverURL, authToken: authToken, type: "audio", sectionID: sectionId, sort: sort)
    }

    /// A lyric stream as parsed lines, or nil when the server has no content for it.
    func getLyrics(serverURL: String, authToken: String, streamKey: String) async throws -> PlexLyrics? {
        guard let url = URL(string: "\(serverURL)\(streamKey)") else { throw PlexAPIError.invalidURL }
        var headers = plexHeaders(authToken: authToken)
        // Without it the server sends the raw file, and LyricFind streams send nothing.
        headers["Accept"] = "application/json"
        // requestData, not request: most LyricFind streams 404 and that is not worth a log line each.
        let data = try await requestData(url, headers: headers)
        return try Self.decodeRepairingUTF8(PlexLyricsContainer.self, from: data).MediaContainer.Lyrics?.first
    }
}
