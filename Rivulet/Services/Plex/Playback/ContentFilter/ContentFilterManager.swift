// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterManager.swift
//  Rivulet
//
//  Runtime for the local content filter. Owned by UniversalPlayerViewModel
//  (VOD only). Two independent sources feed it:
//
//    1. Subtitle-driven language muting — the active subtitle line is matched
//       against ProfanityDictionary; a hit mutes the whole cue window. Works on
//       any title with a subtitle track, no external data.
//    2. Imported time-coded lists (MCF/EDL) — precise mute + scene-skip windows
//       fetched per title from a user-configured source URL. This is the only
//       way to skip scenes (violence, nudity) that dialogue can't reveal.
//
//  Nothing here modifies the media. Muting sets the player volume to zero for
//  the window; skipping seeks past it. Both are undone the instant the window
//  ends — the client-side approach protected by the Family Movie Act of 2005.
//

import Foundation
import Combine

@MainActor
final class ContentFilterManager: ObservableObject {

    // MARK: - Published state

    /// True while the filter wants the audio silenced right now. The view model
    /// mirrors this onto the active player.
    @Published private(set) var isFilterMuting = false

    /// Master switch state, mirrored for quick UI reads (rail toggle).
    @Published private(set) var isEnabled = false

    /// Bumped each time a scene is skipped, so the player can flash a brief
    /// "Scene skipped" note without the manager owning any UI.
    @Published private(set) var lastSkip: SkipEvent?

    struct SkipEvent: Equatable {
        let category: FilterCategory
        let toTime: TimeInterval
        /// Monotonic counter so identical skips still publish a change.
        let sequence: Int
    }

    // MARK: - Settings snapshot

    private var enabledCategories: Set<FilterCategory> = []
    private var profanityThreshold: FilterSeverity = .moderate
    private var listSourceURL: String = ""

    // MARK: - Per-item runtime

    private var regions: [FilterRegion] = []
    private var skippedRegionIDs: Set<Int> = []
    private var currentTime: TimeInterval = 0
    private var subtitleMatched = false
    private var lastSubtitleTexts: [String] = []
    private var itemRatingKey: String?
    private var skipSequence = 0
    private var sidecarTask: Task<Void, Never>?

    /// Seek a hair past a skip window so the next tick doesn't re-enter it.
    private let skipEpsilon: TimeInterval = 0.25

    // MARK: - Lifecycle

    init() {
        refreshSettings()
    }

    /// Re-read the persisted settings (call when playback starts and whenever
    /// the user may have changed them). Recomputes the active mute state.
    func refreshSettings() {
        let s = Settings.load()
        isEnabled = s.enabled
        profanityThreshold = s.profanityThreshold
        listSourceURL = s.listSourceURL

        var categories: Set<FilterCategory> = []
        if s.enabled {
            for category in FilterCategory.userToggleable where s.isCategoryEnabled(category) {
                categories.insert(category)
            }
            // `.other` (uncategorized imported regions) rides the master switch.
            categories.insert(.other)
        }
        enabledCategories = categories
        // Force the next subtitle feed to re-evaluate (categories/strength or the
        // master switch may have just changed mid-cue). Drop any current match
        // too — under the new rules it may no longer apply, and holding it
        // would keep audio muted until the next cue change re-evaluates.
        lastSubtitleTexts = []
        subtitleMatched = false
        recomputeMute()
    }

    /// Begin filtering a new item. Clears prior state, loads any cached list for
    /// this rating key, then refreshes it from the source URL in the background.
    func beginItem(ratingKey: String?) {
        reset()
        itemRatingKey = ratingKey
        refreshSettings()
        guard isEnabled, let ratingKey else { return }

        if let cached = Self.loadCachedList(ratingKey: ratingKey) {
            regions = cached.regions
        }
        loadSidecarIfConfigured(ratingKey: ratingKey)
    }

    /// Tear down per-item state (call on stop / item change).
    func reset() {
        sidecarTask?.cancel()
        sidecarTask = nil
        regions = []
        skippedRegionIDs = []
        subtitleMatched = false
        lastSubtitleTexts = []
        currentTime = 0
        itemRatingKey = nil
        if isFilterMuting { isFilterMuting = false }
    }

    // MARK: - Playback hooks

    /// Feed the playhead. Returns a seek target when the playhead should jump
    /// past a scene-skip window, otherwise nil. Always recomputes muting.
    /// `allowSkip` is false while the user is scrubbing, so we keep muting in
    /// sync without consuming (or fighting) a scene skip they're seeking through.
    func timeDidUpdate(_ time: TimeInterval, allowSkip: Bool = true) -> TimeInterval? {
        currentTime = time
        guard isEnabled else {
            if isFilterMuting { isFilterMuting = false }
            return nil
        }

        // Rewind reset: any skip window now ahead of the playhead is armed again.
        if !skippedRegionIDs.isEmpty {
            for region in regions where skippedRegionIDs.contains(region.id) && time < region.start {
                skippedRegionIDs.remove(region.id)
            }
        }

        guard allowSkip else {
            recomputeMute()
            return nil
        }

        var skipTarget: TimeInterval?
        for region in regions where region.action == .skip {
            guard enabledCategories.contains(region.category) else { continue }
            guard !skippedRegionIDs.contains(region.id), region.contains(time) else { continue }
            skippedRegionIDs.insert(region.id)
            let target = min(region.end + skipEpsilon, .greatestFiniteMagnitude)
            skipTarget = max(skipTarget ?? 0, target)  // if windows stack, jump to the furthest
            skipSequence += 1
            lastSkip = SkipEvent(category: region.category, toTime: target, sequence: skipSequence)
        }

        recomputeMute()
        return skipTarget
    }

    /// Feed the currently-visible subtitle text (one entry per active cue).
    /// A match mutes for as long as the cue stays active. Cheap to call every
    /// tick: it early-outs when the on-screen text hasn't changed.
    func activeSubtitlesDidChange(texts: [String]) {
        guard isEnabled, !enabledCategories.isEmpty else {
            lastSubtitleTexts = texts
            if subtitleMatched { subtitleMatched = false; recomputeMute() }
            return
        }
        if texts == lastSubtitleTexts { return }
        lastSubtitleTexts = texts
        let match = texts.contains { text in
            ProfanityDictionary.shouldMute(
                text: text,
                enabledCategories: enabledCategories,
                profanityThreshold: profanityThreshold)
        }
        if match != subtitleMatched {
            subtitleMatched = match
            recomputeMute()
        }
    }

    // MARK: - Master toggle (rail)

    /// Flip the master switch and persist it (used by the player rail toggle).
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled, let ratingKey = itemRatingKey {
            refreshSettings()
            if regions.isEmpty {
                if let cached = Self.loadCachedList(ratingKey: ratingKey) { regions = cached.regions }
                loadSidecarIfConfigured(ratingKey: ratingKey)
            }
        } else {
            refreshSettings()
        }
    }

    /// Install an imported list as this item's regions and re-evaluate the
    /// mute state. The application step for both the disk cache and the
    /// sidecar fetch.
    func applyList(_ list: ContentFilterList) {
        regions = list.regions
        recomputeMute()
    }

    // MARK: - Mute recompute

    private func recomputeMute() {
        guard isEnabled else {
            if isFilterMuting { isFilterMuting = false }
            return
        }
        let inMuteRegion = regions.contains { region in
            region.action == .mute
                && enabledCategories.contains(region.category)
                && region.contains(currentTime)
        }
        let shouldMute = subtitleMatched || inMuteRegion
        if shouldMute != isFilterMuting {
            isFilterMuting = shouldMute
        }
    }

    // MARK: - Sidecar loading

    private func loadSidecarIfConfigured(ratingKey: String) {
        let template = listSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return }
        let candidates = Self.sidecarURLs(template: template, ratingKey: ratingKey)
        guard !candidates.isEmpty else { return }

        sidecarTask?.cancel()
        // Runs on the main actor (the parsers share VTTParser with the subtitle
        // pipeline, which is main-actor); only the fetch suspends. Lists are a
        // few KB, so parsing here is negligible.
        sidecarTask = Task { [weak self] in
            for url in candidates {
                if Task.isCancelled { return }
                guard let (content, sourceURL) = await Self.fetch(url) else { continue }
                guard let list = try? ContentFilterParser.parse(content: content, url: sourceURL),
                      !list.isEmpty else { continue }
                Self.cacheList(list, ratingKey: ratingKey)
                guard let self, !Task.isCancelled, self.itemRatingKey == ratingKey else { return }
                self.applyList(list)
                return
            }
        }
    }

    /// Build the ordered list of URLs to try for a rating key. If the template
    /// points straight at a `.mcf`/`.edl` file it's used verbatim; if it
    /// contains `{id}` that's substituted; otherwise it's treated as a directory
    /// and `<id>.mcf` then `<id>.edl` are appended.
    nonisolated static func sidecarURLs(template: String, ratingKey: String) -> [URL] {
        let encodedID = ratingKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ratingKey
        if template.contains("{id}") {
            let filled = template.replacingOccurrences(of: "{id}", with: encodedID)
            return URL(string: filled).map { [$0] } ?? []
        }
        let lower = template.lowercased()
        if lower.hasSuffix(".mcf") || lower.hasSuffix(".edl") {
            return URL(string: template).map { [$0] } ?? []
        }
        let base = template.hasSuffix("/") ? template : template + "/"
        return [base + encodedID + ".mcf", base + encodedID + ".edl"].compactMap { URL(string: $0) }
    }

    nonisolated private static func fetch(_ url: URL) async -> (content: String, url: URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return (content, url)
    }

    // MARK: - Disk cache

    nonisolated private static var cacheDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("ContentFilters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func cacheURL(ratingKey: String) -> URL? {
        let safe = ratingKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ratingKey
        return cacheDirectory?.appendingPathComponent("\(safe).json")
    }

    nonisolated private static func loadCachedList(ratingKey: String) -> ContentFilterList? {
        guard let url = cacheURL(ratingKey: ratingKey),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ContentFilterList.self, from: data) else {
            return nil
        }
        return list
    }

    nonisolated private static func cacheList(_ list: ContentFilterList, ratingKey: String) {
        guard let url = cacheURL(ratingKey: ratingKey),
              let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Settings

extension ContentFilterManager {

    /// UserDefaults keys shared with the Settings surface. Kept here so the
    /// manager and the Settings page can never drift apart.
    enum Keys {
        static let enabled = "contentFilter.enabled"
        static let profanityStrength = "contentFilter.profanityStrength"
        static let listSourceURL = "contentFilter.listSourceURL"
    }

    /// A snapshot of the persisted settings.
    struct Settings {
        var enabled: Bool
        var profanityThreshold: FilterSeverity
        var listSourceURL: String

        static func load() -> Settings {
            let d = UserDefaults.standard
            let enabled = d.object(forKey: Keys.enabled) == nil ? false : d.bool(forKey: Keys.enabled)
            let rawStrength = d.object(forKey: Keys.profanityStrength) == nil
                ? FilterSeverity.moderate.rawValue
                : d.integer(forKey: Keys.profanityStrength)
            let threshold = FilterSeverity(rawValue: rawStrength) ?? .moderate
            let source = d.string(forKey: Keys.listSourceURL) ?? ""
            return Settings(enabled: enabled, profanityThreshold: threshold, listSourceURL: source)
        }

        func isCategoryEnabled(_ category: FilterCategory) -> Bool {
            let d = UserDefaults.standard
            let key = category.enabledDefaultsKey
            return d.object(forKey: key) == nil ? category.defaultEnabled : d.bool(forKey: key)
        }
    }
}
