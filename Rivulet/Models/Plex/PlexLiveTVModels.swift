//
//  PlexLiveTVModels.swift
//  Rivulet
//
//  Plex Live TV API response models
//

import Foundation

// MARK: - Live TV Capabilities

struct PlexLiveTVCapabilities: Codable, Sendable {
    let allowTuners: Bool
    let liveTVEnabled: Bool
    let hasDVR: Bool

    init(allowTuners: Bool = false, liveTVEnabled: Bool = false, hasDVR: Bool = false) {
        self.allowTuners = allowTuners
        self.liveTVEnabled = liveTVEnabled
        self.hasDVR = hasDVR
    }
}

// MARK: - Live TV Session/Provider

struct PlexLiveTVSessionContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVSessionMediaContainer
}

struct PlexLiveTVSessionMediaContainer: Codable, Sendable {
    let size: Int?
    let MediaSubscription: [PlexMediaSubscription]?
}

struct PlexMediaSubscription: Codable, Sendable {
    let id: Int?
    let type: String?
    let flavor: String?
    let status: String?
    let mediaGrabOperationId: Int?
}

// MARK: - Live TV Channels

struct PlexLiveTVChannelContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVChannelMediaContainer
}

struct PlexLiveTVChannelMediaContainer: Codable, Sendable {
    let size: Int?
    let Metadata: [PlexLiveTVChannel]?
}

struct PlexLiveTVChannel: Codable, Identifiable, Sendable {
    let ratingKey: String
    let key: String
    let guid: String?
    let type: String?
    let title: String
    let summary: String?
    let thumb: String?
    let art: String?
    let year: Int?
    let channelCallSign: String?
    let channelIdentifier: String?
    let channelShortTitle: String?
    let channelThumb: String?
    let channelTitle: String?
    let channelNumber: String?
    let streamURL: String?  // HDHomeRun stream URL

    var id: String { ratingKey }

    /// Parse channel number as Int
    var parsedChannelNumber: Int? {
        guard let numStr = channelNumber else { return nil }
        // Handle formats like "5.1" or "5-1"
        let cleaned = numStr.components(separatedBy: CharacterSet(charactersIn: ".-")).first ?? numStr
        return Int(cleaned)
    }

    /// Whether this appears to be an HD channel
    var isHD: Bool {
        let title = (channelTitle ?? title).lowercased()
        return title.contains(" hd") || title.hasSuffix("hd") ||
               title.contains("1080") || title.contains("720")
    }
}

// MARK: - Live TV Guide (EPG)

struct PlexLiveTVGuideContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVGuideMediaContainer
}

struct PlexLiveTVGuideMediaContainer: Codable, Sendable {
    let size: Int?
    let Metadata: [PlexLiveTVGuideChannel]?
}

struct PlexLiveTVGuideChannel: Codable, Sendable {
    let ratingKey: String?
    let key: String?
    let guid: String?
    let channelIdentifier: String?
    let channelTitle: String?
    let channelNumber: String?
    let channelThumb: String?
    let Metadata: [PlexLiveTVProgram]?
}

struct PlexLiveTVProgram: Codable, Identifiable, Sendable {
    let ratingKey: String?
    let key: String?
    let guid: String?
    let type: String?
    let title: String
    let grandparentTitle: String?
    let parentTitle: String?
    let summary: String?
    let thumb: String?
    let art: String?
    let year: Int?
    let originallyAvailableAt: String?
    let beginsAt: Int?           // Unix timestamp
    let endsAt: Int?             // Unix timestamp
    let onAir: Bool?
    let live: Bool?
    let premiere: Bool?
    let Genre: [PlexGenreTag]?
    let Media: [PlexMedia]?

    var id: String { ratingKey ?? "\(beginsAt ?? 0):\(title)" }

    /// Convert beginsAt to Date
    var startDate: Date? {
        guard let timestamp = beginsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Convert endsAt to Date
    var endDate: Date? {
        guard let timestamp = endsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Combined episode info
    var episodeInfo: String? {
        if let show = grandparentTitle {
            if let season = parentTitle {
                return "\(show) - \(season) - \(title)"
            }
            return "\(show) - \(title)"
        }
        return nil
    }

    /// Category from first genre
    var category: String? {
        Genre?.first?.tag
    }
}

struct PlexGenreTag: Codable, Sendable {
    let tag: String
}

// MARK: - DVR Info

struct PlexDVRContainer: Codable, Sendable {
    let MediaContainer: PlexDVRMediaContainer
}

struct PlexDVRMediaContainer: Codable, Sendable {
    let size: Int?
    let Dvr: [PlexDVR]?
}

struct PlexDVR: Codable, Sendable {
    let key: String?
    let uuid: String?
    let friendlyName: String?
    let device: String?
    let model: String?
    let make: String?
    let status: String?
    let lineup: String?
    let epgIdentifier: String?
    let Device: [PlexDVRDevice]?
}

struct PlexDVRDevice: Sendable {
    let key: String?
    let uuid: String?
    let uri: String?
    let parentID: String?  // Can be Int or String from Plex API
}

extension PlexDVRDevice: Decodable {
    private enum CodingKeys: String, CodingKey {
        case key, uuid, uri, parentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)

        // parentID can be Int or String from Plex API
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: .parentID) {
            parentID = String(intValue)
        } else {
            parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        }
    }
}

extension PlexDVRDevice: Encodable {}

// MARK: - Converters

extension PlexLiveTVChannel {
    /// Build a Plex HLS transcode URL for Live TV channels without an HDHomeRun stream URL.
    /// This is how official Plex clients stream from DVB tuners (e.g. TBS cards) — through
    /// the Plex server's universal transcode endpoint.
    private func buildPlexLiveTVStreamURL(serverURL: String, authToken: String) -> URL? {
        var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/start.m3u8")
        components?.queryItems = [
            URLQueryItem(name: "path", value: key),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "X-Plex-Token", value: authToken),
        ]
        return components?.url
    }

    /// Convert to UnifiedChannel
    func toUnifiedChannel(sourceId: String, serverURL: String, authToken: String) -> UnifiedChannel {
        let channelId = UnifiedChannel.makeId(
            sourceType: .plex,
            sourceId: sourceId,
            channelId: ratingKey
        )

        // Use the HDHomeRun stream URL if available, otherwise fall back to
        // Plex server transcode URL (needed for DVB tuners without HDHomeRun)
        let streamURLValue: URL? = {
            if let hdhrURL = streamURL {
                return URL(string: hdhrURL)
            }
            return buildPlexLiveTVStreamURL(serverURL: serverURL, authToken: authToken)
        }()

        // Build logo URL - handle both external URLs and Plex paths
        let logoURL: URL? = {
            guard let thumb = channelThumb ?? thumb else { return nil }
            // Check if it's already an absolute URL (external)
            if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
                return URL(string: thumb)
            }
            // Otherwise it's a Plex server path
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
        }()

        return UnifiedChannel(
            id: channelId,
            sourceType: .plex,
            sourceId: sourceId,
            channelNumber: parsedChannelNumber,
            name: channelTitle ?? title,
            callSign: channelCallSign ?? channelShortTitle,
            logoURL: logoURL,
            streamURL: streamURLValue,
            tvgId: channelIdentifier ?? ratingKey,
            groupTitle: nil,
            isHD: isHD
        )
    }
}

extension PlexLiveTVProgram {
    /// Convert to UnifiedProgram
    func toUnifiedProgram(unifiedChannelId: String) -> UnifiedProgram? {
        guard let start = startDate, let end = endDate else {
            return nil
        }

        let programId = "\(unifiedChannelId):\(beginsAt ?? 0)"

        return UnifiedProgram(
            id: programId,
            channelId: unifiedChannelId,
            title: grandparentTitle ?? title,
            subtitle: grandparentTitle != nil ? title : parentTitle,
            description: summary,
            startTime: start,
            endTime: end,
            category: category,
            iconURL: thumb.flatMap { URL(string: $0) },
            episodeNumber: nil,
            isNew: premiere ?? false
        )
    }
}
