// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterTests.swift
//  RivuletTests
//
//  Pure tests for the local content filter: the MCF/EDL parsers, the
//  subtitle-driven language matcher, and the manager's tick logic
//  (mute windows, scene skips, re-arming on rewind). No network, no disk:
//  lists are injected via `applyList`; settings go through UserDefaults
//  and are cleaned up in tearDown.
//

import XCTest
@testable import Rivulet

// MARK: - Parsers

final class ContentFilterParserTests: XCTestCase {

    // MARK: EDL

    func testEDLBasicSkipAndMute() throws {
        let edl = """
        # comment line
        10.0 20.0 0
        30 40 1 profanity
        50 60 2
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.count, 2)

        let skip = list.regions[0]
        XCTAssertEqual(skip.start, 10.0)
        XCTAssertEqual(skip.end, 20.0)
        XCTAssertEqual(skip.action, .skip)
        XCTAssertEqual(skip.category, .other)

        let mute = list.regions[1]
        XCTAssertEqual(mute.action, .mute)
        XCTAssertEqual(mute.category, .profanity)
    }

    func testEDLIgnoresInvalidLines() throws {
        let edl = """
        20 10 0
        not a line
        5 6 0
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.count, 1)
        XCTAssertEqual(list.regions[0].start, 5)
    }

    func testEDLCommercialActionSkips() throws {
        let list = try ContentFilterParser.parse(content: "1 2 3", url: nil)
        XCTAssertEqual(list.regions.first?.action, .skip)
    }

    // MARK: MCF

    func testMCFCueBecomesRegion() throws {
        let mcf = """
        WEBVTT

        00:01:10.000 --> 00:01:12.500
        profanity=high
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.count, 1)
        let region = try XCTUnwrap(list.regions.first)
        XCTAssertEqual(region.start, 70.0, accuracy: 0.01)
        XCTAssertEqual(region.end, 72.5, accuracy: 0.01)
        XCTAssertEqual(region.category, .profanity)
        XCTAssertEqual(region.severity, .strong)
        XCTAssertEqual(region.action, .mute)   // language default
    }

    func testMCFSceneCategoryDefaultsToSkip() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=medium
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.first?.category, .violence)
        XCTAssertEqual(list.regions.first?.action, .skip)
    }

    func testMCFAudioChannelForcesMute() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=high channel=audio
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.first?.action, .mute)
    }

    func testMCFMultiplePairsInOneCue() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=high nudity=low
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.count, 2)
        XCTAssertEqual(Set(list.regions.map(\.category)), [.violence, .sexNudity])
    }

    func testUnrecognizedContentThrows() {
        XCTAssertThrowsError(try ContentFilterParser.parse(content: "hello world", url: nil))
        XCTAssertThrowsError(try ContentFilterParser.parse(content: "   ", url: nil))
    }

    func testFormatDetectionByExtension() throws {
        // A .edl extension wins even though the content alone is ambiguous.
        let url = URL(string: "https://example.com/123.edl")!
        let list = try ContentFilterParser.parse(content: "1 2 0", url: url)
        XCTAssertEqual(list.regions.count, 1)
    }

    func testRegionsSortedByStart() throws {
        let edl = """
        50 60 0
        5 6 0
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.map(\.start), [5, 50])
    }
}

// MARK: - Sidecar URL building

final class ContentFilterSidecarURLTests: XCTestCase {

    func testTemplateWithIDPlaceholder() {
        let urls = ContentFilterManager.sidecarURLs(
            template: "https://example.com/filters/{id}.mcf", ratingKey: "184065")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/filters/184065.mcf"])
    }

    func testDirectFileTemplateUsedVerbatim() {
        let urls = ContentFilterManager.sidecarURLs(
            template: "https://example.com/one.edl", ratingKey: "184065")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/one.edl"])
    }

    func testFolderTemplateTriesMCFThenEDL() {
        let urls = ContentFilterManager.sidecarURLs(
            template: "https://example.com/filters", ratingKey: "42")
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://example.com/filters/42.mcf",
                        "https://example.com/filters/42.edl"])
    }
}

// MARK: - Language matcher

final class ProfanityDictionaryTests: XCTestCase {

    private let language: Set<FilterCategory> = [.profanity, .blasphemy, .slur, .sexualLanguage]

    private func muted(_ text: String,
                       categories: Set<FilterCategory>? = nil,
                       threshold: FilterSeverity = .mild) -> Bool {
        ProfanityDictionary.shouldMute(
            text: text,
            enabledCategories: categories ?? language,
            profanityThreshold: threshold)
    }

    func testPlainStrongWord() {
        XCTAssertTrue(muted("What the fuck is that"))
    }

    func testWholeWordBoundaries() {
        XCTAssertFalse(muted("The class was an assessment"))
        XCTAssertFalse(muted("Hello there"))
        XCTAssertFalse(muted("Shell station up ahead"))
    }

    func testTrailingPunctuationStillMatches() {
        // Regression: "!" is also a masking character; a trailing one must not
        // corrupt the token ("shit!" once collapsed to "shiti" and missed).
        XCTAssertTrue(muted("Shit!"))
        XCTAssertTrue(muted("Damn!"))
        XCTAssertTrue(muted("Oh, shit."))
    }

    func testMaskedSpellings() {
        XCTAssertTrue(muted("You little sh*t"))
        XCTAssertTrue(muted("sh!t happens"))
        XCTAssertTrue(muted("What the f***"))
        XCTAssertTrue(muted("f**k this"))
        XCTAssertTrue(muted("b@stard"))
    }

    func testStubGuardAgainstInnocentShortTokens() {
        // Stub expansion only applies to genuinely censored tokens; "B1" must
        // not expand into a hit.
        XCTAssertFalse(muted("Vitamin B1 tablets"))
        XCTAssertFalse(muted("Gate B1 is closed"))
    }

    func testProfanityThreshold() {
        XCTAssertTrue(muted("damn it", threshold: .mild))
        XCTAssertFalse(muted("damn it", threshold: .strong))
        XCTAssertTrue(muted("fuck", threshold: .strong))
        // Non-profanity language categories ignore the threshold.
        XCTAssertTrue(muted("jesus christ", threshold: .strong))
    }

    func testPhraseMatching() {
        XCTAssertTrue(muted("God damn it, hurry"))
        XCTAssertTrue(muted("God damn!"))          // trailing punctuation
        XCTAssertTrue(muted("For god’s sake"))     // curly apostrophe
        XCTAssertFalse(muted("Thank god you came")) // "god" alone never mutes
    }

    func testCategoryGating() {
        XCTAssertFalse(muted("What the fuck", categories: [.blasphemy]))
        XCTAssertFalse(muted("jesus christ", categories: [.profanity]))
        XCTAssertFalse(muted("anything at all", categories: []))
    }
}

// MARK: - Manager tick logic

@MainActor
final class ContentFilterManagerTests: XCTestCase {

    private var manager: ContentFilterManager!

    private var allKeys: [String] {
        [ContentFilterManager.Keys.enabled,
         ContentFilterManager.Keys.profanityStrength,
         ContentFilterManager.Keys.listSourceURL]
        + FilterCategory.allCases.map(\.enabledDefaultsKey)
    }

    override func setUp() {
        super.setUp()
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: ContentFilterManager.Keys.enabled)
        manager = ContentFilterManager()
    }

    override func tearDown() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        manager = nil
        super.tearDown()
    }

    private func regions(_ list: [(Double, Double, FilterCategory, FilterAction)]) -> ContentFilterList {
        ContentFilterList(regions: list.enumerated().map { index, r in
            FilterRegion(id: index, start: r.0, end: r.1,
                         category: r.2, severity: .moderate, action: r.3)
        })
    }

    func testSkipTriggersOnceAndRearmsOnRewind() {
        manager.applyList(regions([(100, 110, .violence, .skip)]))

        XCTAssertNil(manager.timeDidUpdate(99))
        let target = manager.timeDidUpdate(100.5)
        XCTAssertNotNil(target)
        XCTAssertEqual(target ?? 0, 110.25, accuracy: 0.01)

        // Consumed: ticks inside the window while the seek is in flight
        // must not re-trigger.
        XCTAssertNil(manager.timeDidUpdate(100.7))

        // Rewinding to before the window re-arms it.
        XCTAssertNil(manager.timeDidUpdate(95))
        XCTAssertNotNil(manager.timeDidUpdate(101))
    }

    func testOverlappingSkipWindowsJumpToFurthestEnd() {
        manager.applyList(regions([
            (100, 110, .violence, .skip),
            (105, 130, .frightening, .skip)
        ]))
        let target = manager.timeDidUpdate(106)
        XCTAssertEqual(target ?? 0, 130.25, accuracy: 0.01)
    }

    func testScrubbingSuppressesSkipButKeepsMuteCurrent() {
        manager.applyList(regions([
            (10, 20, .violence, .skip),
            (30, 40, .other, .mute)
        ]))
        XCTAssertNil(manager.timeDidUpdate(15, allowSkip: false))
        XCTAssertNil(manager.timeDidUpdate(35, allowSkip: false))
        XCTAssertTrue(manager.isFilterMuting)
        XCTAssertNil(manager.timeDidUpdate(45, allowSkip: false))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testMuteRegionSetsAndClears() {
        manager.applyList(regions([(5, 8, .other, .mute)]))
        XCTAssertNil(manager.timeDidUpdate(6))
        XCTAssertTrue(manager.isFilterMuting)
        XCTAssertNil(manager.timeDidUpdate(9))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testDisabledCategoryDoesNotAct() {
        UserDefaults.standard.set(false, forKey: FilterCategory.violence.enabledDefaultsKey)
        manager.refreshSettings()
        manager.applyList(regions([(10, 20, .violence, .skip)]))
        XCTAssertNil(manager.timeDidUpdate(15))
    }

    func testMasterSwitchOffDoesNothing() {
        UserDefaults.standard.set(false, forKey: ContentFilterManager.Keys.enabled)
        manager.refreshSettings()
        manager.applyList(regions([(10, 20, .violence, .skip)]))
        XCTAssertNil(manager.timeDidUpdate(15))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testSubtitleTextMutesAndUnmutes() {
        manager.activeSubtitlesDidChange(texts: ["What the fuck"])
        _ = manager.timeDidUpdate(1)
        XCTAssertTrue(manager.isFilterMuting)

        manager.activeSubtitlesDidChange(texts: [])
        _ = manager.timeDidUpdate(2)
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testRefreshSettingsDropsStaleSubtitleMatch() {
        // Regression: a match latched while a cue was on screen must not
        // survive a settings refresh, or audio stays muted until the next
        // cue change re-evaluates.
        manager.activeSubtitlesDidChange(texts: ["What the fuck"])
        XCTAssertTrue(manager.isFilterMuting)
        manager.refreshSettings()
        XCTAssertFalse(manager.isFilterMuting)
    }
}
