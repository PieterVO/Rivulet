// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Guards the cost of decoding a launch-sized `[PlexMetadata]` payload.
///
/// A device launch logged `decodedCache(home_hero_items_cache_v1.json) read=0ms
/// decode=1033ms bytes=16245`, which reads as "PlexMetadata is too expensive to
/// decode on the launch path". It is not. Measured here (Apple TV sim, Release
/// semantics): first-ever decode of one entry 0.98ms, warm 0.09ms, nine entries
/// 0.40ms — so one-time `Decodable` witness warmup is ~0.9ms and the whole
/// payload parses in well under a millisecond. The device's 1033ms was wall
/// clock on a contended thread, not work. `CacheManager.decodedCache` now logs
/// cpu alongside wall so the two can never be confused again.
///
/// What this test is FOR: PlexMetadata has ~63 properties and ~15 nested types.
/// If someone adds a hand-written `init(from:)`, a `DateFormatter` per field, or
/// another nesting level, this fires before it reaches the launch path.
final class PlexMetadataDecodeCostTests: XCTestCase {

    /// One realistic hero-shaped entry: the nested containers are what make the
    /// type graph expensive, so they must be present, not just scalar fields.
    private static let entry = """
    {
      "ratingKey": "196518", "key": "/library/metadata/196518", "guid": "plex://movie/5d776b9",
      "type": "movie", "title": "Project Hail Mary", "originalTitle": "Project Hail Mary",
      "studio": "Amblin", "contentRating": "PG-13",
      "summary": "A lone astronaut must save the earth from disaster in this feature.",
      "tagline": "One man. One chance.", "year": 2026,
      "rating": 8.4, "audienceRating": 9.1,
      "ratingImage": "rottentomatoes://image.rating.ripe",
      "audienceRatingImage": "rottentomatoes://image.rating.upright",
      "thumb": "/library/metadata/196518/thumb/1750000000",
      "art": "/library/metadata/196518/art/1750000000",
      "duration": 8100000, "originallyAvailableAt": "2026-03-20",
      "addedAt": 1750000000, "updatedAt": 1750000001,
      "librarySectionTitle": "Movies", "librarySectionID": 1, "librarySectionKey": "/library/sections/1",
      "index": 1, "viewCount": 0, "viewOffset": 0, "lastViewedAt": 1750000002,
      "userRating": 9.0, "lastRatedAt": 1750000003,
      "Image": [
        {"alt": "Project Hail Mary", "type": "coverPoster", "url": "/library/metadata/196518/thumb/1"},
        {"alt": "Project Hail Mary", "type": "background", "url": "/library/metadata/196518/art/1"},
        {"alt": "Project Hail Mary", "type": "clearLogo", "url": "/library/metadata/196518/logo/1"}
      ],
      "Genre": [{"id": 1, "tag": "Science Fiction"}, {"id": 2, "tag": "Adventure"}, {"id": 3, "tag": "Drama"}],
      "Guid": [{"id": "tmdb://693134"}, {"id": "tvdb://12345"}, {"id": "imdb://tt1160419"}],
      "Collection": [{"id": 9, "tag": "Hard SF"}],
      "Country": [{"id": 4, "tag": "United States of America"}],
      "Role": [
        {"id": 11, "tag": "Ryan Gosling", "role": "Ryland Grace", "thumb": "https://metadata-static.plex.tv/1.jpg"},
        {"id": 12, "tag": "Sandra Hüller", "role": "Eva Stratt", "thumb": "https://metadata-static.plex.tv/2.jpg"},
        {"id": 13, "tag": "Milana Vayntrub", "role": "Astronaut", "thumb": "https://metadata-static.plex.tv/3.jpg"}
      ],
      "Director": [{"id": 21, "tag": "Phil Lord"}, {"id": 22, "tag": "Christopher Miller"}],
      "Writer": [{"id": 31, "tag": "Drew Goddard"}],
      "Media": [
        {
          "id": 41, "duration": 8100000, "bitrate": 24000, "width": 3840, "height": 2160,
          "aspectRatio": 2.39, "audioChannels": 6, "audioCodec": "eac3", "videoCodec": "hevc",
          "videoResolution": "4k", "container": "mkv", "videoFrameRate": "24p",
          "videoProfile": "main 10",
          "Part": [
            {
              "id": 51, "key": "/library/parts/51/1750000000/file.mkv", "duration": 8100000,
              "file": "/data/Movies/Project Hail Mary (2026)/Project Hail Mary (2026).mkv",
              "size": 24300000000, "container": "mkv", "videoProfile": "main 10",
              "Stream": [
                {"id": 61, "streamType": 1, "codec": "hevc", "index": 0, "bitrate": 22000,
                 "height": 2160, "width": 3840, "displayTitle": "4K HEVC HDR10"},
                {"id": 62, "streamType": 2, "codec": "eac3", "index": 1, "channels": 6,
                 "language": "English", "languageCode": "eng", "displayTitle": "English (EAC3 5.1)"},
                {"id": 63, "streamType": 3, "codec": "subrip", "index": 2,
                 "language": "English", "languageCode": "eng", "displayTitle": "English (SRT)"}
              ]
            }
          ]
        }
      ],
      "Marker": [
        {"id": 71, "type": "intro", "startTimeOffset": 0, "endTimeOffset": 90000},
        {"id": 72, "type": "credits", "startTimeOffset": 7900000, "endTimeOffset": 8100000}
      ],
      "Chapter": [{"id": 81, "index": 1, "startTimeOffset": 0, "endTimeOffset": 600000}]
    }
    """

    private func payload(count: Int) -> Data {
        Data(("[" + Array(repeating: Self.entry, count: count).joined(separator: ",") + "]").utf8)
    }

    private func decodeMillis(_ data: Data) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        let decoded = try? JSONDecoder().decode([PlexMetadata].self, from: data)
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertNotNil(decoded, "fixture must actually decode, else we are timing a throw")
        return ms
    }

    func testLaunchSizedPayloadDecodesCheaply() throws {
        // 9 entries ≈ 31KB, comfortably over the 16KB the device actually loads.
        let full = payload(count: 9)
        // First call absorbs one-time Decodable-witness warmup; second is steady
        // state. Budget covers both, generously, so this fails on a real
        // regression (a custom decoder, per-field DateFormatter) and not on the
        // noise of a busy CI machine.
        let cold = decodeMillis(full)
        let warm = decodeMillis(full)

        XCTAssertLessThan(cold, 150, "cold [PlexMetadata] decode regressed: \(cold)ms for \(full.count) bytes")
        XCTAssertLessThan(warm, 50, "warm [PlexMetadata] decode regressed: \(warm)ms for \(full.count) bytes")
    }
}
