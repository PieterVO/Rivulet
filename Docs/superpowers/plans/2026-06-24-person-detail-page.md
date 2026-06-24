# Person (Actor) Detail Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user selects a cast (actor) member in a movie/show detail page, open a full-screen UIKit person page with a circular portrait + biography header and poster shelf rows of the Movies and Shows that person is in.

**Architecture:** A new `PersonDetailViewController` (UIKit) loads a `PersonDetail` from `PersonFilmographyProvider`. The provider fetches the person's bio, portrait, and full filmography from the Plex Discover person endpoint (via the role's `tagKey`), then partitions the filmography through the existing `LibraryGUIDIndex`: titles on the user's server become playable `MediaItem`s (sorted first); the rest become metadata-only ("more") items. Rows reuse the identical `ShelfRowCell` / `PosterCell` shelf used by Home/Library. Entry is a new `onSelectPerson` callback on `BelowFoldCollectionView`, forwarded through the existing callback chain.

**Tech Stack:** Swift 6, UIKit (tvOS 26), XCTest (`RivuletTests` target). Reuses `ShelfRowCell`, `PosterCell`, `FocusScrollControlledCollectionView`, `LibraryGUIDIndex`, `InfoPopupViewController`, `MediaItem`/`PlexMediaMapper`.

## Global Constraints

- Platform: tvOS 26+, Swift 6. UI is UIKit (SwiftUI detail is deprecated).
- Shelf rows MUST be the identical `ShelfRowCell` + `PosterCell` used elsewhere — same margins/gaps/focus chrome. **No per-poster caption** (PosterCell is intentionally caption-less).
- Discover/account calls use `PlexAuthManager.shared.authToken` (account-level), **never** `selectedServerToken`. Always pass `includeGuids=1` on Discover list/metadata endpoints.
- Person thumbs/poster URLs may be absolute (metadata-static CDN) — pass absolute URLs through unchanged; only concat `serverURL` + token for server-relative paths.
- Follow the `feedback_no_em_dashes` rule in any user-facing copy: no em or en dashes.
- During this UIKit session: build + install to the simulator after each UI task.

Build (compile): `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`
Unit tests: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/<TestClass>`

---

## File map

New:
- `Rivulet/Models/Media/PersonDetail.swift` — `PersonDetail`, `FilmographyEntry`, `PersonFilmographyProviding` protocol.
- `Rivulet/Services/MediaProvider/Person/PersonItemMapper.swift` — builds metadata-only `MediaItem`s for not-on-server filmography titles.
- `Rivulet/Services/Plex/PlexDiscoverPersonService.swift` — fetches person bio/portrait/filmography from `metadata.provider.plex.tv`.
- `Rivulet/Services/MediaProvider/Person/PersonFilmographyProvider.swift` — orchestration + `LibraryGUIDIndex` partition + bucketing/sort.
- `Rivulet/Views/Media/Person/UIKit/PersonHeaderCell.swift` — header (portrait + name + bio + MORE).
- `Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift` — the page.

Tests (new):
- `RivuletTests/Unit/PlexRolePersonDecodeTests.swift`
- `RivuletTests/Unit/PersonItemMapperTests.swift`
- `RivuletTests/Unit/PlexDiscoverPersonServiceTests.swift`
- `RivuletTests/Unit/PersonFilmographyProviderTests.swift`

Modified:
- `Rivulet/Models/Plex/PlexMetadata.swift` (PlexRole: add `tagKey`, `filter`).
- `Rivulet/Models/Media/MediaPerson.swift` (add `tagKey`, `originActorId`, `originSectionKey`).
- `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (populate new MediaPerson fields for cast).
- `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` (add `onSelectPerson` + `.cast` select case).
- `Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift` (forward `onSelectPerson`).
- `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` (present `PersonDetailViewController`, route its `onSelectItem`).

---

## Task 1: PersonDetail models + provider protocol

**Files:**
- Create: `Rivulet/Models/Media/PersonDetail.swift`

**Interfaces:**
- Produces: `PersonDetail`, `FilmographyEntry`, `PersonFilmographyProviding`.

```swift
// PersonDetail.swift
import Foundation

/// One title in a person's filmography, plus whether it exists on the user's server.
struct FilmographyEntry: Hashable, Sendable {
    let item: MediaItem        // playable (plex provider) when isOnServer, else metadata-only ("tmdb")
    let isOnServer: Bool
}

/// Fully resolved data backing the person detail page.
struct PersonDetail: Hashable, Sendable {
    let id: String             // Discover person key (role tagKey) or a synthetic fallback id
    let name: String
    let biography: String?
    let portraitURL: URL?
    let movies: [FilmographyEntry]   // server entries sorted first
    let shows: [FilmographyEntry]    // server entries sorted first
}

/// Seam the view controller depends on. The concrete Plex/Discover wiring lives behind it.
protocol PersonFilmographyProviding: Sendable {
    func load(person: MediaPerson) async throws -> PersonDetail
}
```

- [ ] **Step 1: Create the file** with the exact contents above.
- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`
Expected: BUILD SUCCEEDED (note: `MediaPerson` gains the fields it references — `tagKey` etc. — in Task 2; this file does not reference them, so it compiles now).

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Models/Media/PersonDetail.swift
git commit -m "feat(person): PersonDetail models + PersonFilmographyProviding protocol"
```

---

## Task 2: Carry the Discover person key from Plex Role to MediaPerson

Decode `tagKey` (Discover person GUID fragment) and `filter` (origin-library actor id, e.g. `actor=49`) on `PlexRole`, and carry `tagKey` + origin actor id + origin section key onto `MediaPerson` so a tapped cast cell knows which person to load.

**Files:**
- Modify: `Rivulet/Models/Plex/PlexMetadata.swift` (PlexRole struct, ~lines 15-20)
- Modify: `Rivulet/Models/Media/MediaPerson.swift` (struct, lines 10-15)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (cast mapping, ~lines 305-312)
- Test: `RivuletTests/Unit/PlexRolePersonDecodeTests.swift`

**Interfaces:**
- Produces: `PlexRole.tagKey: String?`, `PlexRole.filter: String?`, `PlexRole.originActorId: String?` (computed); `MediaPerson.tagKey/originActorId/originSectionKey`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

```swift
// RivuletTests/Unit/PlexRolePersonDecodeTests.swift
import XCTest
@testable import Rivulet

final class PlexRolePersonDecodeTests: XCTestCase {
    func test_decodesTagKeyAndFilter() throws {
        let json = """
        { "tag": "Jon Hamm", "role": "Don Draper",
          "thumb": "https://metadata-static.plex.tv/p/people/abc.jpg",
          "tagKey": "5d776831151a60001f24a6b1", "filter": "actor=49" }
        """.data(using: .utf8)!
        let role = try JSONDecoder().decode(PlexRole.self, from: json)
        XCTAssertEqual(role.tagKey, "5d776831151a60001f24a6b1")
        XCTAssertEqual(role.filter, "actor=49")
        XCTAssertEqual(role.originActorId, "49")
    }

    func test_missingFieldsDecodeNil() throws {
        let json = #"{ "tag": "Nobody" }"#.data(using: .utf8)!
        let role = try JSONDecoder().decode(PlexRole.self, from: json)
        XCTAssertNil(role.tagKey)
        XCTAssertNil(role.originActorId)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PlexRolePersonDecodeTests`
Expected: FAIL (no `tagKey`/`filter`/`originActorId` members).

- [ ] **Step 3: Extend `PlexRole`** in `Rivulet/Models/Plex/PlexMetadata.swift` to:

```swift
nonisolated struct PlexRole: Codable, Identifiable, Sendable {
    var id: String { "\(tag ?? "unknown")-\(role ?? "unknown")-\(thumb ?? "")" }
    var tag: String?        // Actor name
    var role: String?       // Character name
    var thumb: String?      // Photo URL
    var tagKey: String?     // Plex Discover person GUID fragment (e.g. "5d77...")
    var filter: String?     // Origin-library filter, e.g. "actor=49"

    /// Numeric origin-library actor id parsed from `filter` ("actor=49" -> "49").
    var originActorId: String? {
        guard let filter, let eq = filter.firstIndex(of: "=") else { return nil }
        let v = String(filter[filter.index(after: eq)...])
        return v.isEmpty ? nil : v
    }
}
```

(`tagKey` and `filter` match the JSON keys, so default Codable decodes them. `originActorId` is computed and not decoded.)

- [ ] **Step 4: Extend `MediaPerson`** in `Rivulet/Models/Media/MediaPerson.swift`:

```swift
struct MediaPerson: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    var tagKey: String? = nil           // Discover person key (cast only)
    var originActorId: String? = nil    // origin-library actor id (fallback path)
    var originSectionKey: String? = nil // origin library section key (fallback path)
}
```

(Defaulted stored properties keep the existing `MediaPerson(...)` call sites in `TMDBMediaMapper.swift:75` and `PlexMediaMapper.swift:314/322` compiling unchanged.)

- [ ] **Step 5: Populate the cast mapping** in `PlexMediaMapper.swift` (the `cast` map at ~line 305). Replace it with:

```swift
let cast = (meta.Role ?? []).map { role in
    MediaPerson(
        id: role.id,
        name: role.tag ?? "",
        role: role.role,
        imageURL: personURL(role.thumb),
        tagKey: role.tagKey,
        originActorId: role.originActorId,
        originSectionKey: meta.librarySectionID.map(String.init)
    )
}
```

NOTE: confirm the section-key property name on `PlexMetadata` (likely `librarySectionID`). If it is a `String?`, drop the `.map(String.init)`. If absent, pass `nil` and rely on the Discover path. Directors/writers mappings are unchanged.

- [ ] **Step 6: Run the test to verify it passes**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PlexRolePersonDecodeTests`
Expected: PASS.

- [ ] **Step 7: Build the app target to confirm no call sites broke**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Rivulet/Models/Plex/PlexMetadata.swift Rivulet/Models/Media/MediaPerson.swift Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift RivuletTests/Unit/PlexRolePersonDecodeTests.swift
git commit -m "feat(person): decode Role tagKey/filter and carry person key onto MediaPerson"
```

---

## Task 3: PersonItemMapper (metadata-only items for not-on-server titles)

Build a metadata-only `MediaItem` for a filmography title that is not on the server, keyed by its tmdb guid so it behaves like a Discover item (provider `"tmdb"`, `isMetadataOnly == true`, `tmdbID` decodes). Artwork uses the Plex Discover poster URL we already have (the title's TMDB poster path is not available here).

**Files:**
- Create: `Rivulet/Services/MediaProvider/Person/PersonItemMapper.swift`
- Test: `RivuletTests/Unit/PersonItemMapperTests.swift`

**Interfaces:**
- Consumes: `MediaItem`, `MediaItemRef`, `MediaArtwork`, `MediaUserState`, `TMDBMediaMapper.providerID`, `TMDBMediaMapper.encodeItemID`, `TMDBMediaType`.
- Produces: `PersonItemMapper.metadataOnlyItem(tmdbId:isMovie:title:year:posterURL:overview:) -> MediaItem`.

- [ ] **Step 1: Write the failing test**

```swift
// RivuletTests/Unit/PersonItemMapperTests.swift
import XCTest
@testable import Rivulet

final class PersonItemMapperTests: XCTestCase {
    func test_buildsMetadataOnlyMovieItem() {
        let url = URL(string: "https://metadata-static.plex.tv/p/poster.jpg")!
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: 1234, isMovie: true, title: "The Town", year: 2010,
            posterURL: url, overview: "Bank robbers.")
        XCTAssertTrue(item.isMetadataOnly)
        XCTAssertEqual(item.tmdbID, 1234)
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.title, "The Town")
        XCTAssertEqual(item.year, 2010)
        XCTAssertEqual(item.artwork.poster, url)
    }

    func test_buildsMetadataOnlyShowItem() {
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: 99, isMovie: false, title: "Mad Men", year: 2007,
            posterURL: nil, overview: nil)
        XCTAssertEqual(item.kind, .show)
        XCTAssertEqual(item.tmdbID, 99)
        XCTAssertNil(item.artwork.poster)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PersonItemMapperTests`
Expected: FAIL (no `PersonItemMapper`).

- [ ] **Step 3: Implement the mapper**

```swift
// PersonItemMapper.swift
import Foundation

enum PersonItemMapper {
    /// Metadata-only MediaItem for a filmography title not present on the server.
    /// Keyed by tmdb id so it routes through the existing Discover/metadata-only
    /// presentation (`isMetadataOnly == true`, `tmdbID` decodes).
    static func metadataOnlyItem(tmdbId: Int,
                                 isMovie: Bool,
                                 title: String,
                                 year: Int?,
                                 posterURL: URL?,
                                 overview: String?) -> MediaItem {
        let type: TMDBMediaType = isMovie ? .movie : .tv
        return MediaItem(
            ref: MediaItemRef(providerID: TMDBMediaMapper.providerID,
                              itemID: TMDBMediaMapper.encodeItemID(tmdbId: tmdbId, type: type)),
            kind: isMovie ? .movie : .show,
            title: title,
            sortTitle: nil,
            overview: overview,
            year: year,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: posterURL, backdrop: nil, thumbnail: posterURL, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }
}
```

NOTE: confirm `TMDBMediaType` spells the TV case `.tv` (it does in `TMDBMediaMapper`). Confirm `MediaUserState`'s memberwise init labels against `TMDBMediaMapper.item` (it uses `MediaUserState(isPlayed:viewOffset:isFavorite:lastViewedAt:)`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PersonItemMapperTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/MediaProvider/Person/PersonItemMapper.swift RivuletTests/Unit/PersonItemMapperTests.swift
git commit -m "feat(person): PersonItemMapper for metadata-only filmography items"
```

---

## Task 4: PlexDiscoverPersonService (fetch bio + portrait + filmography)

Fetch the Discover person from `metadata.provider.plex.tv` using the account token, and return a small DTO: name, biography (`summary`), portrait URL (`thumb`), and a flat list of filmography titles each with their external guids + type + title + year + poster.

**The live response shape is the project's one open risk.** This task assumes the most likely shape (person metadata + a `/children` filmography call returning a `MediaContainer` of `Metadata` with `Guid`), tests decoding against a fixture matching that shape, and **logs the raw JSON at runtime** so the exact path/shape is confirmed on-device in Task 4b before the provider is trusted.

**Files:**
- Create: `Rivulet/Services/Plex/PlexDiscoverPersonService.swift`
- Test: `RivuletTests/Unit/PlexDiscoverPersonServiceTests.swift`

**Interfaces:**
- Produces:
  - `struct DiscoverPersonDTO { let name: String; let biography: String?; let portraitURL: URL?; let titles: [DiscoverPersonTitle] }`
  - `struct DiscoverPersonTitle { let guids: [String]; let isMovie: Bool; let title: String; let year: Int?; let posterURL: URL? }`
  - `protocol DiscoverPersonFetching { func fetch(tagKey: String) async throws -> DiscoverPersonDTO }`
  - `final class PlexDiscoverPersonService: DiscoverPersonFetching` (uses `PlexAuthManager.shared.authToken`)
  - `static func decode(personData: Data, filmographyData: Data) throws -> DiscoverPersonDTO` (pure, testable)

- [ ] **Step 1: Write the failing decode test** (fixture matches the assumed shape; adjust in Task 4b after seeing real JSON)

```swift
// RivuletTests/Unit/PlexDiscoverPersonServiceTests.swift
import XCTest
@testable import Rivulet

final class PlexDiscoverPersonServiceTests: XCTestCase {
    func test_decodesPersonAndFilmography() throws {
        let person = """
        {"MediaContainer":{"Metadata":[{"title":"Jon Hamm",
          "summary":"American actor.",
          "thumb":"https://metadata-static.plex.tv/p/people/abc.jpg"}]}}
        """.data(using: .utf8)!
        let films = """
        {"MediaContainer":{"Metadata":[
          {"type":"movie","title":"The Town","year":2010,
           "thumb":"https://metadata-static.plex.tv/p/t.jpg",
           "Guid":[{"id":"tmdb://1234"}]},
          {"type":"show","title":"Mad Men","year":2007,
           "Guid":[{"id":"tmdb://99"}]}
        ]}}
        """.data(using: .utf8)!
        let dto = try PlexDiscoverPersonService.decode(personData: person, filmographyData: films)
        XCTAssertEqual(dto.name, "Jon Hamm")
        XCTAssertEqual(dto.biography, "American actor.")
        XCTAssertEqual(dto.titles.count, 2)
        XCTAssertEqual(dto.titles[0].guids.first, "tmdb://1234")
        XCTAssertTrue(dto.titles[0].isMovie)
        XCTAssertFalse(dto.titles[1].isMovie)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PlexDiscoverPersonServiceTests`
Expected: FAIL (no service).

- [ ] **Step 3: Implement the service** (reuse the metadata-host + account-token pattern from `PlexContentAdvisoryService` / `PlexWatchlistAPI`). Decode against `PlexMetadata` where possible (it already decodes `title`, `summary`, `thumb`, `type`, `year`, `Guid`).

```swift
// PlexDiscoverPersonService.swift
import Foundation

struct DiscoverPersonTitle: Sendable {
    let guids: [String]
    let isMovie: Bool
    let title: String
    let year: Int?
    let posterURL: URL?
}

struct DiscoverPersonDTO: Sendable {
    let name: String
    let biography: String?
    let portraitURL: URL?
    let titles: [DiscoverPersonTitle]
}

protocol DiscoverPersonFetching: Sendable {
    func fetch(tagKey: String) async throws -> DiscoverPersonDTO
}

final class PlexDiscoverPersonService: DiscoverPersonFetching {
    private let host = "https://metadata.provider.plex.tv"
    private let session: URLSession = .shared

    func fetch(tagKey: String) async throws -> DiscoverPersonDTO {
        guard let token = PlexAuthManager.shared.authToken else {
            throw PlexAPIError.invalidURL   // no account token -> caller uses fallback
        }
        let personData = try await get("/library/metadata/\(tagKey)", token: token)
        // ASSUMED filmography sub-path. Confirm/adjust in Task 4b after logging real JSON.
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
        let (data, _) = try await session.data(for: req)
        return data
    }

    static func decode(personData: Data, filmographyData: Data) throws -> DiscoverPersonDTO {
        let dec = JSONDecoder()
        let personContainer = try dec.decode(PlexMetadataResponse.self, from: personData)
        let person = personContainer.MediaContainer.Metadata?.first
        let filmContainer = try dec.decode(PlexMetadataResponse.self, from: filmographyData)
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
```

NOTE: confirm the response wrapper type name used elsewhere for `{ "MediaContainer": { "Metadata": [...] } }` (referred to here as `PlexMetadataResponse`). Reuse the existing wrapper the codebase already decodes with (grep `MediaContainer` in `Models/Plex`); do not introduce a duplicate if one exists. Confirm `PlexMetadata` exposes `summary`, `thumb`, `type`, `year`, `Guid` (it does per the cast/detail mapping).

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PlexDiscoverPersonServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/Plex/PlexDiscoverPersonService.swift RivuletTests/Unit/PlexDiscoverPersonServiceTests.swift
git commit -m "feat(person): PlexDiscoverPersonService (assumed shape + instrumented spike log)"
```

### Task 4b: Confirm the live shape (the spike)

This step requires a running app with a signed-in account and a movie/show open. It is verified after Task 7 wires the entry point (so an actor is tappable). When you can tap an actor:

- [ ] Build + install to the simulator/device, open a movie detail, tap a cast member.
- [ ] Read the `[PersonSpike]` log lines (Console / `launch --console-pty` per `tvos_sim_contextmenu_trigger` memory).
- [ ] If the filmography is NOT under `/children`, adjust `fetch`'s sub-path (try `/related`, or inline hubs in the person response) and the `decode` accordingly; update the fixture in `PlexDiscoverPersonServiceTests` to match the real JSON and re-run it.
- [ ] Remove the `#if DEBUG` spike `print`s once confirmed. Commit.

---

## Task 5: PersonFilmographyProvider (partition + bucket + sort)

Turn a `MediaPerson` into a `PersonDetail`: fetch the Discover person, map each filmography title to a `FilmographyEntry` (server match via `LibraryGUIDIndex` -> playable `PlexMediaMapper.item`; else metadata-only via `PersonItemMapper`), bucket by movie/show, and sort server entries first. This is the core testable logic; the network + index are injected so it unit-tests with fakes.

**Files:**
- Create: `Rivulet/Services/MediaProvider/Person/PersonFilmographyProvider.swift`
- Test: `RivuletTests/Unit/PersonFilmographyProviderTests.swift`

**Interfaces:**
- Consumes: `DiscoverPersonFetching` (Task 4), `PersonItemMapper` (Task 3), `PersonFilmographyProviding`/`PersonDetail`/`FilmographyEntry` (Task 1), `LibraryGUIDIndex.lookup(guid:)`, `PlexMediaMapper.item`.
- Produces: `final class PersonFilmographyProvider: PersonFilmographyProviding` with an init that injects the fetcher and a server-match closure.

- [ ] **Step 1: Write the failing test** (inject a fake fetcher + a fake server-match closure to avoid the live index)

```swift
// RivuletTests/Unit/PersonFilmographyProviderTests.swift
import XCTest
@testable import Rivulet

private struct FakeFetcher: DiscoverPersonFetching {
    let dto: DiscoverPersonDTO
    func fetch(tagKey: String) async throws -> DiscoverPersonDTO { dto }
}

final class PersonFilmographyProviderTests: XCTestCase {
    func test_partitionsServerFirstAndBucketsByType() async throws {
        let dto = DiscoverPersonDTO(
            name: "Jon Hamm", biography: "Bio", portraitURL: nil,
            titles: [
                .init(guids: ["tmdb://1"], isMovie: true,  title: "OnServerMovie",  year: 2010, posterURL: nil),
                .init(guids: ["tmdb://2"], isMovie: true,  title: "OffServerMovie", year: 2016, posterURL: nil),
                .init(guids: ["tmdb://3"], isMovie: false, title: "OnServerShow",   year: 2007, posterURL: nil),
            ])
        // Fake server-match: only tmdb://1 and tmdb://3 are "on server".
        let onServer: Set<String> = ["tmdb://1", "tmdb://3"]
        let provider = PersonFilmographyProvider(
            fetcher: FakeFetcher(dto: dto),
            serverItemForGuids: { guids in
                guards: for g in guids where onServer.contains(g) {
                    return TestFixtures.playableItem(title: g == "tmdb://1" ? "OnServerMovie" : "OnServerShow",
                                                     isMovie: g == "tmdb://1")
                }
                return nil
            })
        let person = MediaPerson(id: "p", name: "Jon Hamm", role: nil, imageURL: nil, tagKey: "5d77")
        let detail = try await provider.load(person: person)

        XCTAssertEqual(detail.movies.map(\.isOnServer), [true, false]) // server first
        XCTAssertEqual(detail.movies.map(\.item.title), ["OnServerMovie", "OffServerMovie"])
        XCTAssertEqual(detail.shows.count, 1)
        XCTAssertTrue(detail.shows[0].isOnServer)
        XCTAssertEqual(detail.biography, "Bio")
    }
}

enum TestFixtures {
    static func playableItem(title: String, isMovie: Bool) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "plex:test", itemID: "rk-\(title)"),
                  kind: isMovie ? .movie : .show, title: title, sortTitle: nil, overview: nil,
                  year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }
}
```

(Fix the `guards:`/`for` typo to a normal loop when typing; shown compactly here. The point: the closure returns a playable item for on-server guids, nil otherwise.)

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PersonFilmographyProviderTests`
Expected: FAIL (no provider).

- [ ] **Step 3: Implement the provider**

```swift
// PersonFilmographyProvider.swift
import Foundation

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {
    private let fetcher: DiscoverPersonFetching
    /// Returns a playable MediaItem if any of the guids is on the user's server, else nil.
    private let serverItemForGuids: @Sendable ([String]) async -> MediaItem?

    init(fetcher: DiscoverPersonFetching = PlexDiscoverPersonService(),
         serverItemForGuids: @escaping @Sendable ([String]) async -> MediaItem? = Self.defaultServerMatch) {
        self.fetcher = fetcher
        self.serverItemForGuids = serverItemForGuids
    }

    func load(person: MediaPerson) async throws -> PersonDetail {
        guard let tagKey = person.tagKey else {
            // Fallback (no Discover person): origin-library filmography only.
            return try await loadFallback(person: person)
        }
        let dto = try await fetcher.fetch(tagKey: tagKey)
        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []
        for t in dto.titles {
            let entry: FilmographyEntry
            if let serverItem = await serverItemForGuids(t.guids) {
                entry = FilmographyEntry(item: serverItem, isOnServer: true)
            } else if let tmdbId = Self.tmdbId(from: t.guids) {
                let item = PersonItemMapper.metadataOnlyItem(
                    tmdbId: tmdbId, isMovie: t.isMovie, title: t.title,
                    year: t.year, posterURL: t.posterURL, overview: nil)
                entry = FilmographyEntry(item: item, isOnServer: false)
            } else { continue }   // not on server and no tmdb id -> not actionable
            if t.isMovie { movies.append(entry) } else { shows.append(entry) }
        }
        return PersonDetail(
            id: tagKey, name: dto.name.isEmpty ? person.name : dto.name,
            biography: dto.biography, portraitURL: dto.portraitURL ?? person.imageURL,
            movies: Self.serverFirst(movies), shows: Self.serverFirst(shows))
    }

    private static func serverFirst(_ e: [FilmographyEntry]) -> [FilmographyEntry] {
        // Stable partition: on-server entries keep relative order, then the rest.
        e.filter(\.isOnServer) + e.filter { !$0.isOnServer }
    }

    private static func tmdbId(from guids: [String]) -> Int? {
        for g in guids where g.hasPrefix("tmdb://") { return Int(g.dropFirst("tmdb://".count)) }
        return nil
    }

    // Default server match via the live index. Maps the matched PlexMetadata to a playable item.
    static let defaultServerMatch: @Sendable ([String]) async -> MediaItem? = { guids in
        for g in guids {
            if let meta = await LibraryGUIDIndex.shared.lookup(guid: g),
               let serverURL = PlexAuthManager.shared.selectedServerURL,
               let token = PlexAuthManager.shared.selectedServerToken {
                let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
                return PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
            }
        }
        return nil
    }

    private func loadFallback(person: MediaPerson) async throws -> PersonDetail {
        // Origin-library only: query /library/sections/{originSectionKey}/all?actor={originActorId}.
        // Build PlexMediaMapper.item entries (all isOnServer: true). Confirm the section-items
        // request method on PlexNetworkManager (getCollectionItems uses the same /all pattern).
        // If originSectionKey/originActorId are nil, return name + portrait with empty rows.
        return PersonDetail(id: person.tagKey ?? person.id, name: person.name,
                            biography: nil, portraitURL: person.imageURL,
                            movies: [], shows: [])
    }
}
```

NOTE: confirm `LibraryGUIDIndex.lookup(guid:)` is `async` (actor-isolated) and returns `PlexMetadata?` (it does). Confirm `MediaProviderRegistry.shared.primaryProvider?.id` (used identically in `DiscoverView`). The `loadFallback` body's origin-library query is implemented in Task 5b once the section-items request method is confirmed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PersonFilmographyProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/MediaProvider/Person/PersonFilmographyProvider.swift RivuletTests/Unit/PersonFilmographyProviderTests.swift
git commit -m "feat(person): PersonFilmographyProvider partition/bucket/sort"
```

### Task 5b: Origin-library fallback query (optional polish)

- [ ] Implement `loadFallback` to call the section-items endpoint
  (`/library/sections/{originSectionKey}/all?actor={originActorId}`) via the existing
  `PlexNetworkManager` request method, map results with `PlexMediaMapper.item` as on-server
  entries, bucket by type. Verify on-device. Commit. (Low priority: most cast have a `tagKey`.)

---

## Task 6: PersonHeaderCell + PersonDetailViewController (UIKit)

The page itself. Header cell (circular portrait + name + truncated bio + MORE) and an outer vertical `FocusScrollControlledCollectionView` that hosts the header plus two `ShelfRowCell` rows ("Movies", "Shows"), mirroring how `PlexHomeViewController` hosts shelf rows. Loads via `PersonFilmographyProvider`. Emits `onSelectItem` per poster tap. No per-poster caption.

**Files:**
- Create: `Rivulet/Views/Media/Person/UIKit/PersonHeaderCell.swift`
- Create: `Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift`

**Interfaces:**
- Consumes: `PersonDetail`/`FilmographyEntry`/`PersonFilmographyProviding`, `ShelfRowCell` (reuseID `"ShelfRowCell"`, `TileKind.poster`, `configure(kind:realCount:hasSkeleton:contentToken:initialOffset:)`, `cellProvider`, `onSelect`, `contextMenuProvider`, `headerTitle`), `PosterCell` (reuseID `"PosterCell"`, `configure(item: MediaItem)`), `FocusScrollControlledCollectionView`, `InfoPopupViewController(content:width:)` + `InfoPopupContent.description(title:subtitle:body:)`.
- Produces: `PersonDetailViewController(person: MediaPerson, provider: PersonFilmographyProviding = PersonFilmographyProvider())` with `var onSelectItem: ((MediaItem) -> Void)?`.

**Reference to mirror:** open `PlexHomeViewController.swift` and copy its outer collection-view setup for hosting `ShelfRowCell` as full-width list items: the compositional layout (one list section per row), the diffable/cell-provider wiring that sets each `ShelfRowCell`'s `cellProvider`/`onSelect`/`headerTitle`, and its use of `FocusScrollControlledCollectionView` for vertical focus scrolling. The person page is the same pattern with a fixed set of sections: `[header, movies, shows]` (omit a row if its entries are empty).

- [ ] **Step 1: Build `PersonHeaderCell`** — a `UICollectionViewCell` with:
  - A circular `UIImageView` (true circle: `layer.cornerRadius = side/2`, `clipsToBounds = true`), left, ~200pt, loaded from `portraitURL` via the project's image loader (match how `CastCell`/`PosterCell` load images; reuse `CachedAsyncImage`'s UIKit equivalent or the same `loadImage` helper PosterCell uses).
  - Name label (white, ~48pt semibold) and a bio label (muted, `numberOfLines` limited, truncating) to the right.
  - A focusable `MORE` button shown only when the bio is truncated; on primary action it calls a `onMore` closure.
  - `configure(name:biography:portraitURL:onMore:)`.
  - No glass backing; background clear (the VC paints the gradient).

- [ ] **Step 2: Build `PersonDetailViewController`**:
  - `modalPresentationStyle = .fullScreen` (opaque page).
  - Background: dark blue → black vertical gradient (`CAGradientLayer` on a background `UIView`, resized in `viewDidLayoutSubviews`).
  - Outer `FocusScrollControlledCollectionView` with a compositional layout mirroring `PlexHomeViewController`: section 0 = header (absolute/estimated height ~340), sections 1..2 = list sections each containing one `ShelfRowCell` item (height = `TileKind.poster.tileHeight` + the row header height).
  - In `viewDidLoad`: render an immediate skeleton/empty state; kick off `Task { await reload() }`.
  - `reload()`: `let detail = try await provider.load(person: person)`, store `movies`/`shows` arrays, rebuild sections (drop empty rows), reload. Set the header cell's `onMore` to present
    `InfoPopupViewController(content: InfoPopupContent.description(title: detail.name, subtitle: nil, body: detail.biography), width: 840)`.
  - For each `ShelfRowCell`: set `headerTitle = "Movies"` / `"Shows"`, `cellProvider` dequeues `PosterCell` and calls `configure(item: entry.item)`, `onSelect = { [weak self] idx in self?.onSelectItem?(entries[idx].item) }`, and `contextMenuProvider` returns the existing watchlist menu for `!entry.isOnServer` entries (reuse whatever `BelowFoldCollectionView`/Discover uses to build the watchlist `UIMenu`; nil for on-server entries).
  - Cancel the load `Task` in `deinit`/`viewWillDisappear` (per the tvOS skill: store the handle, never fire-and-forget).
  - `.onExitCommand`/Menu: default dismissal is fine (this VC is a normal full-screen modal with focusable content, so Menu pops it).

- [ ] **Step 3: Build + install to the simulator**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`
Expected: BUILD SUCCEEDED. (Visual verification happens in Task 7 once the page is reachable. Optionally add a temporary debug button to present it with a stub `MediaPerson` to verify layout in isolation, then remove it.)

- [ ] **Step 4: Commit**

```bash
git add Rivulet/Views/Media/Person/UIKit/PersonHeaderCell.swift Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift
git commit -m "feat(person): PersonDetailViewController + header, reusing ShelfRowCell rows"
```

---

## Task 7: Wire the entry point (cast tap -> present the page)

Make cast cells open the page. Add `onSelectPerson` to `BelowFoldCollectionView`, forward it through `ExpandedDetailContainerView`, and present `PersonDetailViewController` from `PreviewCarouselViewController`, routing the page's `onSelectItem` to the existing standalone-detail presentation.

**Files:**
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` (callbacks ~lines 68-82; `didSelectItemAt` ~lines 863-869; cast configure ~lines 425-428)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift` (callback forwarding block, near `onShowRelatedDetails`/`onShowEpisodeDetails`)
- Modify: `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` (callback wiring block ~lines 271-309)

**Interfaces:**
- Consumes: `MediaPerson` (with `tagKey`), `PersonDetailViewController` (Task 6), the existing `presentStandaloneDetail(_:)`.
- Produces: `BelowFoldCollectionView.onSelectPerson: ((MediaPerson) -> Void)?`; forwarded passthrough on `ExpandedDetailContainerView`.

- [ ] **Step 1:** In `BelowFoldCollectionView`, add the callback alongside the others:

```swift
var onSelectPerson: ((MediaPerson) -> Void)?
```

- [ ] **Step 2:** In `BelowFoldCollectionView.didSelectItemAt`, add the cast case (keep the existing related case):

```swift
func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let id = dataSource.itemIdentifier(for: indexPath)
    if case let .related(rid) = id, let item = relatedByID[rid] {
        onShowRelatedDetails?(item)
    } else if case let .cast(cid) = id, let entry = castEntriesByID[cid] {
        onSelectPerson?(entry.person)
    }
}
```

- [ ] **Step 3:** In `ExpandedDetailContainerView`, forward the callback (mirror the existing `onShowRelatedDetails` get/set passthrough to `belowFoldCollection`):

```swift
var onSelectPerson: ((MediaPerson) -> Void)? {
    get { belowFoldCollection.onSelectPerson }
    set { belowFoldCollection.onSelectPerson = newValue }
}
```

- [ ] **Step 4:** In `PreviewCarouselViewController`, wire it where the other `expandedDetail.on...` closures are set:

```swift
expandedDetail.onSelectPerson = { [weak self] person in
    guard let self else { return }
    let page = PersonDetailViewController(person: person)
    page.onSelectItem = { [weak self] item in self?.presentStandaloneDetail(item) }
    self.present(page, animated: true)
}
```

NOTE: confirm `presentStandaloneDetail(_:)` accepts a `MediaItem` and gracefully handles a metadata-only item (provider `"tmdb"`). If it does not handle metadata-only items, route those to the same presentation `DiscoverView` uses for a not-in-library item (present the metadata-only detail); on-server items go through `presentStandaloneDetail`. Confirm which during this step and branch on `item.isMetadataOnly`.

- [ ] **Step 5: Build + install to the simulator**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Visual verification on the simulator/device**
  - Open a movie with known cast (e.g. an actor with several titles on the server). Focus a cast member, press Select.
  - Confirm: the person page appears full-screen; circular portrait + name + bio render; `MORE` opens the info popup; "Movies" and "Shows" rows show server titles first; rows look identical to Home/Library rows (margins, focus chrome); selecting a poster opens its detail; Menu dismisses the page.
  - This is also where **Task 4b** (confirm the live Discover person shape via the `[PersonSpike]` logs) is performed and the decode adjusted if needed.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift
git commit -m "feat(person): wire cast tap -> present person detail page"
```

---

## Self-review

**Spec coverage:** Header (portrait+name+bio+MORE) → Task 6. Bio/portrait from Discover person → Task 4/5. Movies/Shows rows identical to other shelves → Task 6 (ShelfRowCell/PosterCell). Server-first partition → Task 5. "More" items behave like Discover (metadata-only, watchlist menu) → Task 3 + Task 6 contextMenuProvider + Task 7 routing. Cast-only entry → Task 7. Fallback (no tagKey) → Task 5/5b. No caption → Task 6 (PosterCell). All spec sections map to tasks.

**Placeholder scan:** Data-layer tasks (1-5) carry full code + real tests. UI tasks (6,7) carry concrete code for the wiring deltas and reference `PlexHomeViewController` as the canonical host to mirror for the outer layout (an existing-pattern reference, not a placeholder). The two "NOTE: confirm …" items (section-key property name; `presentStandaloneDetail` metadata-only handling) are explicit verification steps, not deferred work.

**Type consistency:** `PersonFilmographyProviding.load(person:) -> PersonDetail` used consistently in Tasks 1/5/6. `FilmographyEntry { item, isOnServer }` consistent. `DiscoverPersonDTO`/`DiscoverPersonTitle` produced in Task 4, consumed in Task 5. `PersonItemMapper.metadataOnlyItem(tmdbId:isMovie:title:year:posterURL:overview:)` defined Task 3, called Task 5 with matching labels. `MediaItem`/`MediaArtwork`/`MediaUserState` inits match the verified `TMDBMediaMapper.item` shape.

**Open risk:** the live Discover person filmography sub-path (Task 4b) — isolated behind `PlexDiscoverPersonService`/`PersonFilmographyProvider`, confirmed on-device during Task 7's visual pass.
