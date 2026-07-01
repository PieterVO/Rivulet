//
//  LibraryGUIDIndex.swift
//  Rivulet
//
//  In-memory index of library items keyed by external GUIDs (TMDB/IMDB/TVDB).
//  Used by Discover and Watchlist surfaces to answer "do I own this?" in O(1).
//

import Foundation
import os.log

private let guidIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryGUIDIndex")

extension Notification.Name {
    /// Posted on the main thread after `LibraryGUIDIndex.shared.replace(with:)`
    /// completes. Views observing this can re-run library-match queries.
    static let libraryGUIDIndexDidUpdate = Notification.Name("LibraryGUIDIndexDidUpdate")
}

actor LibraryGUIDIndex {
    static let shared = LibraryGUIDIndex()

    private struct TypedKey: Hashable {
        let type: PlexItemType
        let key: String
    }

    enum PlexItemType: Hashable {
        case movie
        case show
    }

    private var byTypedTmdbId: [TypedKey: PlexMetadata] = [:]
    private var byGuid: [String: PlexMetadata] = [:]

    /// Live network data always supersedes a disk-hydrated snapshot. Once a real
    /// `replace(with:)` has run this launch, a late `hydrateFromDisk()` is a no-op
    /// so stale disk contents can't clobber fresh server data.
    private var hasFreshData = false

    /// Bumped on every rebuild. Consumers (e.g. the trending hero) read this to
    /// skip recomputation when the index hasn't actually changed since their last
    /// run, so overlapping triggers don't repeat identical work.
    private(set) var generation = 0

    /// Rebuild the index from a freshly-fetched library snapshot, persist it to
    /// disk for the next launch, and notify observers. This is the authoritative
    /// path — it always wins over `hydrateFromDisk()`.
    func replace(with items: [PlexMetadata]) {
        rebuild(from: items, source: "replace")
        hasFreshData = true
        persist(items)
    }

    /// Populate the index from the last persisted snapshot. Cheap (local decode),
    /// so it runs at launch to make "do I own this?" answers available before the
    /// ~20MB network refresh lands. Skips if fresh network data already arrived.
    /// Returns the number of items hydrated (0 = miss / skipped / decode failure).
    func hydrateFromDisk() -> Int {
        guard !hasFreshData else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk skipped: fresh network data already present")
            return 0
        }
        guard let items = Self.loadFromDisk() else {
            guidIndexLog.info("[GUIDIndex] hydrateFromDisk miss: no valid cache on disk")
            return 0
        }
        rebuild(from: items, source: "hydrateFromDisk")
        return items.count
    }

    /// Shared ingest + notify used by both `replace` and `hydrateFromDisk`.
    private func rebuild(from items: [PlexMetadata], source: String) {
        byTypedTmdbId.removeAll(keepingCapacity: true)
        byGuid.removeAll(keepingCapacity: true)

        for item in items {
            ingest(item)
        }
        generation += 1

        let typedCount = byTypedTmdbId.count
        let guidCount = byGuid.count
        guidIndexLog.info("[Hero] LibraryGUIDIndex.\(source, privacy: .public): ingested \(items.count, privacy: .public) items -> typedTmdbCount=\(typedCount, privacy: .public), guidCount=\(guidCount, privacy: .public)")
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .libraryGUIDIndexDidUpdate,
                object: nil,
                userInfo: ["typedTmdbCount": typedCount, "guidCount": guidCount]
            )
        }
    }

    var isEmpty: Bool {
        byGuid.isEmpty
    }

    func lookup(tmdbId: Int, type: TMDBMediaType) -> PlexMetadata? {
        let plexType: PlexItemType = (type == .movie) ? .movie : .show
        return byTypedTmdbId[TypedKey(type: plexType, key: "\(tmdbId)")]
    }

    func lookup(guid: String) -> PlexMetadata? {
        byGuid[guid]
    }

    func contains(guid: String) -> Bool {
        byGuid[guid] != nil
    }

    // MARK: - Ingestion

    private func ingest(_ item: PlexMetadata) {
        let plexType: PlexItemType
        switch item.type {
        case "movie": plexType = .movie
        case "show": plexType = .show
        default: return
        }

        let externalGuids = (item.Guid ?? []).compactMap { $0.id }
        for raw in externalGuids {
            byGuid[raw] = item

            if let tmdbId = Self.tmdbId(from: raw) {
                byTypedTmdbId[TypedKey(type: plexType, key: "\(tmdbId)")] = item
            }
        }
    }

    private static func tmdbId(from guid: String) -> Int? {
        guard guid.hasPrefix("tmdb://") else { return nil }
        let raw = guid.dropFirst("tmdb://".count)
        return Int(raw)
    }

    // MARK: - Disk persistence

    /// Bump when the persisted shape changes so old caches are ignored, not
    /// mis-decoded, on the next launch after an app update.
    private static let cacheVersion = 1

    private struct DiskCache: Codable {
        let version: Int
        let savedAt: Date
        let items: [PlexMetadata]
    }

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("library-guid-index.json")
    }

    /// Persist the ingested snapshot for the next launch. Fire-and-forget on a
    /// background task so the encode + write never serializes behind other
    /// actor work or the caller's critical path.
    private func persist(_ items: [PlexMetadata]) {
        guard let url = Self.cacheURL else { return }
        Task.detached(priority: .utility) {
            let cache = DiskCache(version: Self.cacheVersion, savedAt: Date(), items: items)
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
                guidIndexLog.info("[GUIDIndex] persisted \(items.count, privacy: .public) items (\(data.count / 1024, privacy: .public) KB) to disk")
            } catch {
                guidIndexLog.error("[GUIDIndex] persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Load and validate the persisted snapshot. Returns nil on miss, version
    /// mismatch, or decode failure (caller falls back to the network build).
    private static func loadFromDisk() -> [PlexMetadata]? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            guidIndexLog.error("[GUIDIndex] disk cache decode failed; ignoring")
            return nil
        }
        guard cache.version == cacheVersion else {
            guidIndexLog.info("[GUIDIndex] disk cache version \(cache.version, privacy: .public) != \(cacheVersion, privacy: .public); ignoring")
            return nil
        }
        return cache.items
    }
}
