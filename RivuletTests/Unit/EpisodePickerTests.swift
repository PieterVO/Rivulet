import XCTest
@testable import Rivulet

final class EpisodePickerTests: XCTestCase {

    // MARK: - Builders

    private func episode(
        _ id: String,
        season: Int? = 1,
        number: Int?,
        played: Bool = false,
        offset: TimeInterval = 0
    ) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: id),
            kind: .episode,
            title: "Episode \(number.map(String.init) ?? "?")",
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: 1800,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: number,
            seasonNumber: season,
            childProgress: nil,
            userState: MediaUserState(
                isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil
            ),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    // MARK: - firstUnplayed

    func testEmptySeasonReturnsNil() {
        XCTAssertNil(EpisodePicker.firstUnplayed(in: []))
    }

    func testFreshSeasonStartsAtEpisodeOne() {
        let eps = [episode("e1", number: 1), episode("e2", number: 2)]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testSkipsWatchedEpisodesToFirstUnplayed() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
            episode("e3", number: 3),
            episode("e4", number: 4),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e3")
    }

    func testInProgressEpisodeWinsOverLaterUnplayed() {
        // e1 watched, e2 started but unfinished, e3 untouched → resume e2.
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, offset: 300),
            episode("e3", number: 3),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testFullyWatchedSeasonRestartsAtEpisodeOne() {
        let eps = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e1")
    }

    func testPlayedEpisodeWithResumeOffsetIsNotTreatedAsInProgress() {
        // A rewatch leaves viewCount > 0 AND a viewOffset. The next NEW episode
        // should still win over resuming a finished one.
        let eps = [
            episode("e1", number: 1, played: true, offset: 120),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testUnorderedInputIsSortedBeforePicking() {
        let eps = [
            episode("e3", number: 3),
            episode("e1", number: 1, played: true),
            episode("e2", number: 2),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "e2")
    }

    func testSortsAcrossSeasonsBeforeEpisodes() {
        let eps = [
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2),
            episode("s1e1", season: 1, number: 1, played: true),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "s1e2")
    }

    func testMissingEpisodeNumbersFallBackToServerOrder() {
        let eps = [
            episode("first", season: nil, number: nil, played: true),
            episode("second", season: nil, number: nil),
        ]
        XCTAssertEqual(EpisodePicker.firstUnplayed(in: eps)?.ref.itemID, "second")
    }

    // MARK: - nextUpLabel

    func testNextUpLabelFormat() {
        let ep = episode("e3", season: 1, number: 3)
        XCTAssertEqual(EpisodePicker.nextUpLabel(for: ep), "Next Up: S1E3 · Episode 3")
    }

    func testResumeLabelWhenInProgress() {
        let ep = episode("e3", season: 2, number: 5, offset: 300)
        XCTAssertEqual(EpisodePicker.nextUpLabel(for: ep), "Resume: S2E5 · Episode 5")
    }

    func testNextUpLabelNilWithoutNumbering() {
        let ep = episode("e1", season: nil, number: nil)
        XCTAssertNil(EpisodePicker.nextUpLabel(for: ep))
    }

    // MARK: - isInProgress

    func testIsInProgressSemantics() {
        let untouched = MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let started = MediaUserState(isPlayed: false, viewOffset: 60, isFavorite: false, lastViewedAt: nil)
        let finished = MediaUserState(isPlayed: true, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        let rewatching = MediaUserState(isPlayed: true, viewOffset: 60, isFavorite: false, lastViewedAt: nil)

        XCTAssertFalse(untouched.isInProgress)
        XCTAssertTrue(started.isInProgress)
        XCTAssertFalse(finished.isInProgress)
        XCTAssertFalse(rewatching.isInProgress)
    }
}
