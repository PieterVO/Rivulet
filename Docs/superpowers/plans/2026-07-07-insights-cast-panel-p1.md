# Insights Cast Panel (P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **UIKit tasks (4–6):** also load the `rivulet-tvos-uikit` skill before writing code.

**Goal:** Add a cast panel to the player rail — TMDB credits (with episode guest stars) primary, Plex Role fallback — with Select-on-actor deep-linking to the existing Person detail page.

**Architecture:** Phase 1 of the Insights feature (spec: `Docs/superpowers/specs/2026-07-07-insights-panel-design.md`). Entirely in-app: `UniversalPlayerViewModel` gains a `@Published insightsCast: [MediaPerson]` loaded once per item (TMDB → Plex fallback); `PlayerContainerViewController` mirrors the Up Next wiring (sink → cache → rail button → `presentRailPanel`); a new `InsightsCastListView` panel content view mirrors `UpNextListView`. One small worker route (`episode_credits`) adds TV guest stars; the client tolerates its absence.

**Tech Stack:** Swift 6 / tvOS 26 UIKit (player chrome), Combine, XCTest, Cloudflare Worker (TypeScript) for the proxy route.

## Global Constraints

- Swift 6, tvOS 26+. Player chrome is UIKit (`Rivulet/Views/Player/UIKit/`); do not add SwiftUI here.
- Glass focus style (Docs/DESIGN_GUIDE.md): focused bg `white 0.18` / border `white 0.25`; unfocused `white 0.08` / `white 0.08`; focus scale `1.02`. Subtle animations only.
- tvOS Select: plain `UIControl` does NOT fire `.primaryActionTriggered` — handle `.select` in `pressesBegan` (see `UpNextRowButton`, `PlayerUpNextPanelView.swift:310`).
- Plex person `thumb` values may be ABSOLUTE URLs (metadata CDN) — never blindly concatenate `serverURL` (see `PlexMediaMapper.swift:297-305`).
- CLI builds: ALWAYS use a scratch derived-data path and a concrete simulator destination. Resolve the sim UDID first: `xcrun simctl list devices | grep 33E70EDB` (1080p Apple TV 4K sim). Never use `generic/platform=tvOS`.
  - Build command used throughout: `xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" -derivedDataPath /tmp/rivulet-insights-dd build`
- Commit locally after each task; do NOT push to origin.
- `vm.metadata` on `UniversalPlayerViewModel` is NOT `@Published`; `$itemGeneration` is the per-item identity signal (bumped at `UniversalPlayerViewModel.swift:4012`).

---

### Task 1: tmdb-proxy `episode_credits` route

**Files:**
- Modify: `tmdb-proxy/src/index.ts` (routing switch, ~lines 84–113)

**Interfaces:**
- Consumes: existing worker routing (`/tmdb/{kind}/{id}`), existing upstream fetch + cache plumbing.
- Produces: `GET /tmdb/episode_credits/{showTmdbId}?season={s}&episode={e}` → TMDB `tv/{id}/season/{s}/episode/{e}/credits` JSON (`cast`, `guest_stars`, `crew` arrays). Task 2's `episodeCastCredits` calls this.

- [ ] **Step 1: Read the routing switch and cache-key handling**

Read `tmdb-proxy/src/index.ts`. Confirm: (a) the per-item switch on `kind` (cases `keywords`, `credits`, `details`, `images`, `find`, `person`); (b) that the edge cache is keyed on the full incoming request URL including query string (Cache API `caches.default` keyed by request URL). If the cache key strips query params, include `season`/`episode` in the key — otherwise different episodes would collide.

- [ ] **Step 2: Add the route**

Add a case to the switch (alongside `credits`). This route is TV-only; it ignores `?type` and hardcodes the `tv/` upstream path:

```ts
case "episode_credits": {
  const season = url.searchParams.get("season");
  const episode = url.searchParams.get("episode");
  if (!/^\d+$/.test(season ?? "") || !/^\d+$/.test(episode ?? "")) {
    return addCors(new Response("Missing or invalid season/episode", { status: 400 }));
  }
  upstreamPath = `tv/${tmdbId}/season/${season}/episode/${episode}/credits`;
  break;
}
```

Match the surrounding code style exactly (how `upstreamPath` is declared/consumed, how `find` structures its block).

- [ ] **Step 3: Verify locally**

```bash
cd tmdb-proxy && npx wrangler dev
# in another shell (Breaking Bad S1E1, show id 1396):
curl -s "http://localhost:8787/tmdb/episode_credits/1396?season=1&episode=1" | head -c 400
```
Expected: JSON containing `"cast":[...]` and `"guest_stars":[...]`. Also verify the 400 path: `curl -s -o /dev/null -w "%{http_code}" "http://localhost:8787/tmdb/episode_credits/1396?season=1"` → `400`.

- [ ] **Step 4: Deploy**

```bash
cd tmdb-proxy && npx wrangler deploy
curl -s "https://tmdb-proxy.baingurley.workers.dev/tmdb/episode_credits/1396?season=1&episode=1" | head -c 400
```
If deploy fails on auth, STOP and tell the user to run `npx wrangler deploy` themselves — do not block the remaining tasks (the client tolerates a missing route by falling back to show credits).

- [ ] **Step 5: Commit**

```bash
git add tmdb-proxy/src/index.ts
git commit -m "feat(tmdb-proxy): episode_credits route for per-episode cast + guest stars"
```

---

### Task 2: TMDBClient structured cast fetch

**Files:**
- Modify: `Rivulet/Services/TMDB/TMDBClient.swift`
- Test: `RivuletTests/Unit/TMDBEpisodeCreditsTests.swift` (create)

**Interfaces:**
- Consumes: existing `private func request<T: Decodable>(endpoint:type:)` and `request<T:Decodable>(endpoint:queryItems:)` (TMDBClient.swift:158, 164); existing `TMDBCredit` (line 40, has `name`, `character`, `profilePath`, `id`).
- Produces (Task 3 calls these):
  - `func castCredits(tmdbId: Int, type: TMDBMediaType) async -> [TMDBCredit]` — `[]` on failure.
  - `func episodeCastCredits(showTmdbId: Int, season: Int, episode: Int) async -> [TMDBCredit]?` — `nil` on failure/route-missing (caller falls back to `castCredits`).
  - `struct TMDBEpisodeCreditsResponse: Codable` (internal) + `static func mergedEpisodeCast(_ response: TMDBEpisodeCreditsResponse) -> [TMDBCredit]`.

- [ ] **Step 1: Write the failing tests**

Create `RivuletTests/Unit/TMDBEpisodeCreditsTests.swift`:

```swift
import XCTest
@testable import Rivulet

final class TMDBEpisodeCreditsTests: XCTestCase {

    private let fixture = """
    {
      "cast": [
        {"id": 17419, "name": "Bryan Cranston", "character": "Walter White", "profile_path": "/aXf.jpg"},
        {"id": 84497, "name": "Aaron Paul", "character": "Jesse Pinkman", "profile_path": null}
      ],
      "guest_stars": [
        {"id": 92495, "name": "John Koyama", "character": "Emilio Koyama", "profile_path": "/qQx.jpg"},
        {"id": 17419, "name": "Bryan Cranston", "character": "Walter White", "profile_path": "/aXf.jpg"}
      ],
      "crew": []
    }
    """.data(using: .utf8)!

    func testDecodesGuestStarsSnakeCase() throws {
        let response = try JSONDecoder().decode(TMDBEpisodeCreditsResponse.self, from: fixture)
        XCTAssertEqual(response.cast?.count, 2)
        XCTAssertEqual(response.guestStars?.count, 2)
        XCTAssertEqual(response.guestStars?.first?.character, "Emilio Koyama")
    }

    func testMergedEpisodeCastOrdersRegularsFirstAndDedupes() throws {
        let response = try JSONDecoder().decode(TMDBEpisodeCreditsResponse.self, from: fixture)
        let merged = TMDBClient.mergedEpisodeCast(response)
        // 2 regulars + 1 unique guest; duplicate Cranston (id 17419) dropped.
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].name, "Bryan Cranston")
        XCTAssertEqual(merged[2].name, "John Koyama")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcrun simctl list devices | grep 33E70EDB   # note the full UDID
xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd \
  -only-testing:RivuletTests/TMDBEpisodeCreditsTests 2>&1 | tail -20
```
Expected: BUILD FAILED — `cannot find 'TMDBEpisodeCreditsResponse' in scope`.

- [ ] **Step 3: Implement**

In `TMDBClient.swift`, add below the existing `private struct TMDBCreditsResponse` (line 73) — note the new struct is **internal** (no `private`) for test access:

```swift
struct TMDBEpisodeCreditsResponse: Codable {
    let cast: [TMDBCredit]?
    let guestStars: [TMDBCredit]?
    enum CodingKeys: String, CodingKey {
        case cast
        case guestStars = "guest_stars"
    }
}
```

Inside `final class TMDBClient`, add a `// MARK: - Structured cast (Insights)` section after `actorBiography`:

```swift
/// Structured cast for a movie or show. Returns [] on any failure —
/// callers treat empty as "fall back to Plex roles".
func castCredits(tmdbId: Int, type: TMDBMediaType) async -> [TMDBCredit] {
    let credits: TMDBCreditsResponse? = try? await request(endpoint: "tmdb/credits/\(tmdbId)", type: type)
    return credits?.cast ?? []
}

/// Episode-level cast: season regulars followed by this episode's guest
/// stars. Requires the proxy's `episode_credits` route; returns nil when
/// unavailable so callers can fall back to show-level `castCredits`.
func episodeCastCredits(showTmdbId: Int, season: Int, episode: Int) async -> [TMDBCredit]? {
    let response: TMDBEpisodeCreditsResponse? = try? await request(
        endpoint: "tmdb/episode_credits/\(showTmdbId)",
        queryItems: [
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode)),
        ])
    guard let response else { return nil }
    let merged = Self.mergedEpisodeCast(response)
    return merged.isEmpty ? nil : merged
}

/// Regulars first, then guests; dedupe by person id (a regular can also
/// appear in guest_stars for some shows).
static func mergedEpisodeCast(_ response: TMDBEpisodeCreditsResponse) -> [TMDBCredit] {
    var seen = Set<Int>()
    return ((response.cast ?? []) + (response.guestStars ?? [])).filter { credit in
        guard let id = credit.id else { return true }
        return seen.insert(id).inserted
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'TMDBEpisodeCreditsTests' passed` (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/TMDB/TMDBClient.swift RivuletTests/Unit/TMDBEpisodeCreditsTests.swift
git commit -m "feat(tmdb): structured cast fetch (title credits + episode guest stars)"
```

---

### Task 3: Cast mapper + view-model loader

**Files:**
- Create: `Rivulet/Services/TMDB/InsightsCastMapper.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (near line 388 for the published var; new loader func near `loadUpNextEpisodes` line 3735; reset at line ~4014)
- Test: `RivuletTests/Unit/InsightsCastMapperTests.swift` (create)

**Interfaces:**
- Consumes: `TMDBClient.shared.castCredits/episodeCastCredits` (Task 2); `MediaPerson` (`Rivulet/Models/Media/MediaPerson.swift:10` — memberwise init `id:name:role:imageURL:` + defaulted `tagKey:originActorId:originSectionKey:titleTmdbId:titleIsMovie:backdropURL:`); `PlexRole` (`Rivulet/Models/Plex/PlexMetadata.swift:15` — `tag`, `role`, `thumb`, `tagKey`, `originActorId`, synthesized `id`); TMDB-id helpers `metadata.tmdbId ?? metadata.parentShowTmdbId ?? metadata.showTmdbId` (`PlexMetadata.swift:505-533`); `PlexNetworkManager.shared.getFullMetadata(serverURL:authToken:ratingKey:)` (`PlexNetworkManager.swift:410` — check the exact signature/throws-ness there and match it).
- Produces (Tasks 5–6 rely on these):
  - `enum InsightsCastMapper` with `mediaPeople(fromTMDB:titleTmdbId:titleIsMovie:) -> [MediaPerson]`, `mediaPeople(fromPlexRoles:serverURL:authToken:titleTmdbId:titleIsMovie:) -> [MediaPerson]`, `personThumbURL(_:serverURL:authToken:) -> URL?`.
  - On `UniversalPlayerViewModel`: `@Published private(set) var insightsCast: [MediaPerson]` and `func loadInsightsCast() async`.

- [ ] **Step 1: Write the failing mapper tests**

Create `RivuletTests/Unit/InsightsCastMapperTests.swift`:

```swift
import XCTest
@testable import Rivulet

final class InsightsCastMapperTests: XCTestCase {

    func testTMDBMappingBuildsProfileURLAndCharacterRole() {
        let credit = TMDBCredit(id: 1, name: "Ellen Page", job: nil, department: nil,
                                character: "Ariadne", profilePath: "/abc.jpg")
        let people = InsightsCastMapper.mediaPeople(fromTMDB: [credit], titleTmdbId: 27205, titleIsMovie: true)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Ellen Page")
        XCTAssertEqual(people[0].role, "Ariadne")
        XCTAssertEqual(people[0].imageURL?.absoluteString, "https://image.tmdb.org/t/p/w342/abc.jpg")
        XCTAssertEqual(people[0].titleTmdbId, 27205)
        XCTAssertTrue(people[0].titleIsMovie)
    }

    func testTMDBMappingDropsNamelessAndHandlesNilProfile() {
        let nameless = TMDBCredit(id: 2, name: nil, job: nil, department: nil, character: "X", profilePath: nil)
        let noPhoto = TMDBCredit(id: 3, name: "Someone", job: nil, department: nil, character: nil, profilePath: nil)
        let people = InsightsCastMapper.mediaPeople(fromTMDB: [nameless, noPhoto], titleTmdbId: 1, titleIsMovie: false)
        XCTAssertEqual(people.count, 1)
        XCTAssertNil(people[0].imageURL)
    }

    func testPlexAbsoluteThumbPassesThroughUnchanged() {
        // Plex person thumbs are often absolute metadata-CDN URLs; concatenating
        // serverURL onto them breaks the URL.
        let url = InsightsCastMapper.personThumbURL(
            "https://metadata-static.plex.tv/people/x.jpg",
            serverURL: "http://127.0.0.1:32400", authToken: "tok")
        XCTAssertEqual(url?.absoluteString, "https://metadata-static.plex.tv/people/x.jpg")
    }

    func testPlexRelativeThumbGetsServerAndToken() {
        let url = InsightsCastMapper.personThumbURL(
            "/library/metadata/1/thumb/2",
            serverURL: "http://127.0.0.1:32400", authToken: "tok")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:32400/library/metadata/1/thumb/2?X-Plex-Token=tok")
    }
}
```

Note: if `TMDBCredit` has no memberwise init available to tests (it's a `struct` with `let`s, so it does — but if an explicit init exists, match it), decode from JSON instead.

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd \
  -only-testing:RivuletTests/InsightsCastMapperTests 2>&1 | tail -20
```
Expected: BUILD FAILED — `cannot find 'InsightsCastMapper' in scope`.

- [ ] **Step 3: Implement the mapper**

Create `Rivulet/Services/TMDB/InsightsCastMapper.swift`:

```swift
//
//  InsightsCastMapper.swift
//  Rivulet
//
//  Maps TMDB credits / Plex roles into MediaPerson values for the
//  player's Insights cast panel (P1 of the Insights feature).
//

import Foundation

enum InsightsCastMapper {

    private static let tmdbProfileBase = "https://image.tmdb.org/t/p/w342"

    static func mediaPeople(fromTMDB credits: [TMDBCredit], titleTmdbId: Int, titleIsMovie: Bool) -> [MediaPerson] {
        credits.compactMap { credit in
            guard let name = credit.name, !name.isEmpty else { return nil }
            return MediaPerson(
                id: credit.id.map { "tmdb-person-\($0)" } ?? "tmdb-person-\(name)",
                name: name,
                role: credit.character,
                imageURL: credit.profilePath.flatMap { URL(string: tmdbProfileBase + $0) },
                titleTmdbId: titleTmdbId,
                titleIsMovie: titleIsMovie
            )
        }
    }

    static func mediaPeople(fromPlexRoles roles: [PlexRole], serverURL: String, authToken: String,
                            titleTmdbId: Int?, titleIsMovie: Bool) -> [MediaPerson] {
        roles.compactMap { role in
            guard let name = role.tag, !name.isEmpty else { return nil }
            return MediaPerson(
                id: role.id,
                name: name,
                role: role.role,
                imageURL: personThumbURL(role.thumb, serverURL: serverURL, authToken: authToken),
                tagKey: role.tagKey,
                originActorId: role.originActorId,
                titleTmdbId: titleTmdbId,
                titleIsMovie: titleIsMovie
            )
        }
    }

    /// Plex people thumbs are absolute (metadata CDN) or relative server
    /// paths; concatenating serverURL onto an absolute URL would break it.
    static func personThumbURL(_ thumb: String?, serverURL: String, authToken: String) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
            return URL(string: thumb)
        }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: 4 tests pass.

- [ ] **Step 5: Add the view-model state + loader**

In `UniversalPlayerViewModel.swift`, next to `@Published private(set) var upNextEpisodes` (line ~388):

```swift
/// Cast for the Insights rail panel. TMDB credits primary (headshots +
/// character names for anything with a tmdb guid), Plex Role fallback
/// for home media / unmatched items. Loaded once per item by the
/// container's $itemGeneration sink; reset on item swap.
@Published private(set) var insightsCast: [MediaPerson] = []
```

New method near `loadUpNextEpisodes()` (line ~3735):

```swift
func loadInsightsCast() async {
    let generation = itemGeneration
    let isMovie = metadata.type == "movie"
    let tmdbId = metadata.tmdbId ?? metadata.parentShowTmdbId ?? metadata.showTmdbId

    var people: [MediaPerson] = []

    if let tmdbId {
        if metadata.type == "episode",
           let season = metadata.parentIndex, let episode = metadata.index,
           let episodeCast = await TMDBClient.shared.episodeCastCredits(
               showTmdbId: tmdbId, season: season, episode: episode) {
            people = InsightsCastMapper.mediaPeople(fromTMDB: episodeCast, titleTmdbId: tmdbId, titleIsMovie: false)
        } else {
            let credits = await TMDBClient.shared.castCredits(tmdbId: tmdbId, type: isMovie ? .movie : .tv)
            people = InsightsCastMapper.mediaPeople(fromTMDB: credits, titleTmdbId: tmdbId, titleIsMovie: isMovie)
        }
    }

    // Plex Role fallback: item roles, then (episodes) the show's roles.
    if people.isEmpty {
        var roles = metadata.Role ?? []
        if roles.isEmpty, let key = metadata.ratingKey,
           let full = try? await PlexNetworkManager.shared.getFullMetadata(
               serverURL: serverURL, authToken: authToken, ratingKey: key) {
            roles = full.Role ?? []
        }
        if roles.isEmpty, metadata.type == "episode", let showKey = metadata.grandparentRatingKey,
           let show = try? await PlexNetworkManager.shared.getFullMetadata(
               serverURL: serverURL, authToken: authToken, ratingKey: showKey) {
            roles = show.Role ?? []
        }
        people = InsightsCastMapper.mediaPeople(
            fromPlexRoles: roles, serverURL: serverURL, authToken: authToken,
            titleTmdbId: tmdbId, titleIsMovie: isMovie)
    }

    guard generation == itemGeneration else { return }
    insightsCast = people
}
```

Adjust the two `getFullMetadata` calls to the real signature at `PlexNetworkManager.swift:410` (throwing vs optional-returning). If `metadata` lacks `grandparentRatingKey` as a property name, use the actual field on `PlexMetadata`.

In the item-swap block at line ~4014 (immediately after `upNextEpisodes = []`):

```swift
// Clear the outgoing item's cast; the container's $itemGeneration
// sink reloads it for the new episode.
insightsCast = []
```

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Services/TMDB/InsightsCastMapper.swift RivuletTests/Unit/InsightsCastMapperTests.swift Rivulet/Views/Player/UniversalPlayerViewModel.swift
git commit -m "feat(insights): cast mapper + view-model insightsCast loader (TMDB primary, Plex fallback)"
```

---

### Task 4: Rail button

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerRailView.swift` (button props lines 28–39, cluster line 114, closures lines 41–45, wiring lines 150–154, setters lines 161–183)

**Interfaces:**
- Consumes: `TransportControlButton(icon:accessibilityLabel:diameter:)` (existing, same file/pattern as the four current buttons).
- Produces (Task 6 uses): `let insightsButton: TransportControlButton`, `var onInsights: (() -> Void)?`, `func setInsightsAvailable(_ available: Bool)`.

- [ ] **Step 1: Add the button**

In `PlayerRailView.swift`, alongside the existing four button properties (after `infoButton`):

```swift
let insightsButton = TransportControlButton(icon: UIImage(systemName: "person.crop.circle"), accessibilityLabel: "Cast", diameter: Metrics.buttonDiameter)
```

Add the closure alongside the others:

```swift
var onInsights: (() -> Void)?
```

Update the cluster array (line ~114) to place it between Info and Up Next:

```swift
[subtitlesButton, audioButton, infoButton, insightsButton, upNextButton].forEach { cluster.addArrangedSubview($0) }
```

Wire the press (with the other wirings, line ~154):

```swift
insightsButton.onPress = { [weak self] in self?.onInsights?() }
```

Immediately after the wiring lines, start hidden until cast arrives:

```swift
insightsButton.isHidden = true
```

- [ ] **Step 2: Add the availability setter**

Read `setUpNextAvailable(_:)` (lines 161–183) and mirror its exact body/style:

```swift
func setInsightsAvailable(_ available: Bool) {
    insightsButton.isHidden = !available
}
```

If `setUpNextAvailable` does more than toggle `isHidden` (e.g. animation or focus invalidation), replicate that too.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerRailView.swift
git commit -m "feat(insights): Cast rail button (hidden until cast loads)"
```

---

### Task 5: InsightsCastListView panel content

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`

**Interfaces:**
- Consumes: `MediaPerson` (Task 3), `ImageCacheManager.shared.image(for:)` (`Rivulet/Services/Cache/ImageCacheManager.swift:139`). Structural template: `UpNextListView` (`PlayerUpNextPanelView.swift:17`) — read it first and mirror its scroll+stack layout, height capping, and pin-then-free focus pattern.
- Produces (Task 6 presents this): `final class InsightsCastListView: UIView` with `init(cast: [MediaPerson], onSelect: @escaping (MediaPerson) -> Void)`. No `prepareForPresentation` needed (no scroll-to-current).

- [ ] **Step 1: Read the template**

Read `Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift` fully — the new file mirrors: header label style, `scrollView` + vertical `stack` with height cap (`maxHeight` 520, `.defaultHigh` priority), `hasPinnedInitialFocus` focus pattern (lines 152–169), row `UIControl` with `.select` in `pressesBegan`, image-task retention + cancellation.

- [ ] **Step 2: Implement**

Create `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift`:

```swift
//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  Cast list content for the Insights rail panel (P1). Structure and
//  focus behavior mirror UpNextListView: scroll + stack, capped height,
//  pin-first-focus-then-free. Rows deep-link to the Person detail page.
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 520
        static let rowInset: CGFloat = 8
        static let headshot: CGFloat = 56
    }

    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var hasPinnedInitialFocus = false

    init(cast: [MediaPerson], onSelect: @escaping (MediaPerson) -> Void) {
        super.init(frame: .zero)

        headerLabel.text = "Cast"
        headerLabel.font = .systemFont(ofSize: 29, weight: .semibold)
        headerLabel.textColor = .white
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cast.forEach { person in
            let row = InsightsCastRowButton(person: person)
            row.onSelect = { onSelect(person) }
            stack.addArrangedSubview(row)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.clipsToBounds = false
        scrollView.addSubview(stack)
        addSubview(scrollView)

        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.rowInset),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Pin first focus to the first row, then express no preference so the
    // engine leaves focus wherever the user navigated (no bounce-back).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !hasPinnedInitialFocus, let first = stack.arrangedSubviews.first {
            return [first]
        }
        return []
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self) {
            hasPinnedInitialFocus = true
        }
    }
}

// MARK: - Row

final class InsightsCastRowButton: UIControl {

    var onSelect: (() -> Void)?

    private let headshotView = UIImageView()
    private let fallbackIcon = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let nameLabel = UILabel()
    private let characterLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?

    init(person: MediaPerson) {
        super.init(frame: .zero)

        layer.cornerRadius = 12
        backgroundColor = .white.withAlphaComponent(0.08)
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

        let side: CGFloat = 56
        headshotView.contentMode = .scaleAspectFill
        headshotView.clipsToBounds = true
        headshotView.layer.cornerRadius = side / 2
        headshotView.backgroundColor = .white.withAlphaComponent(0.08)
        headshotView.translatesAutoresizingMaskIntoConstraints = false

        fallbackIcon.tintColor = .white.withAlphaComponent(0.35)
        fallbackIcon.contentMode = .scaleAspectFit
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        headshotView.addSubview(fallbackIcon)

        nameLabel.text = person.name
        nameLabel.font = .systemFont(ofSize: 26, weight: .medium)
        nameLabel.textColor = .white

        characterLabel.text = person.role
        characterLabel.font = .systemFont(ofSize: 22)
        characterLabel.textColor = .white.withAlphaComponent(0.6)
        characterLabel.isHidden = (person.role ?? "").isEmpty

        let labels = UIStackView(arrangedSubviews: [nameLabel, characterLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headshotView)
        addSubview(labels)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),
            headshotView.widthAnchor.constraint(equalToConstant: side),
            headshotView.heightAnchor.constraint(equalToConstant: side),
            headshotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headshotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            fallbackIcon.centerXAnchor.constraint(equalTo: headshotView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: headshotView.centerYAnchor),
            fallbackIcon.widthAnchor.constraint(equalToConstant: 34),
            fallbackIcon.heightAnchor.constraint(equalToConstant: 34),
            labels.leadingAnchor.constraint(equalTo: headshotView.trailingAnchor, constant: 16),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        loadHeadshot(person.imageURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
            self.backgroundColor = .white.withAlphaComponent(focused ? 0.18 : 0.08)
            self.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.25 : 0.08).cgColor
        })
    }

    // Plain UIControl doesn't get .primaryActionTriggered for Select on
    // tvOS — handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            onSelect?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func loadHeadshot(_ url: URL?) {
        guard let url else { return }
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, let image else { return }
            self.headshotView.image = image
            self.fallbackIcon.isHidden = true
        }
    }
}
```

Adjust cosmetic constants (fonts, insets) to match `UpNextRowButton`'s actual values after reading it — the row must feel identical to its neighbors, and any Metrics divergence from the template needs a reason.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift
git commit -m "feat(insights): cast list panel content view (UpNext-pattern rows + focus pin)"
```

---

### Task 6: Container wiring + person deep link

**Files:**
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift` (cache var near line 39; sinks after the `$upNextEpisodes` sink ~line 846; rail closure after `onUpNext` ~line 903; `dismiss` override lines 302–344)
- Modify: `Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift` (public callback near line 34; `viewWillDisappear` line 144)

**Interfaces:**
- Consumes: `vm.$insightsCast`, `vm.$itemGeneration`, `vm.loadInsightsCast()`, `vm.pause()`, `vm.resume()` (all on `UniversalPlayerViewModel`); `rail.insightsButton`, `rail.onInsights`, `rail.setInsightsAvailable(_:)` (Task 4); `InsightsCastListView(cast:onSelect:)` (Task 5); `PersonDetailViewController(person:)` (`PersonDetailViewController.swift:98`, presents `.overFullScreen`); `presentRailPanel(content:width:from:)` (`PlayerContainerViewController.swift:916`).
- Produces: user-facing feature; `PersonDetailViewController.onDismiss: (() -> Void)?`.

- [ ] **Step 1: Person page dismissal callback**

In `PersonDetailViewController.swift`, add below `onSelectItem` (line 34):

```swift
/// Fired when the page is being dismissed. The player presents this page
/// over paused playback and uses this to resume.
var onDismiss: (() -> Void)?
```

Extend `viewWillDisappear` (line 144):

```swift
override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    loadTask?.cancel()
    loadTask = nil
    if isBeingDismissed { onDismiss?() }
}
```

- [ ] **Step 2: Guard the container's dismiss ladder**

`PlayerContainerViewController.dismiss(animated:completion:)` (lines 302–344) is a priority ladder (intro-skip → post-video → scrubbing → rail panel → player). When the presented person page is dismissed (Menu), UIKit routes the call through this override — without a guard, the ladder would swallow it. Add at the TOP of the override, before all existing checks:

```swift
// A presented page (person detail) is being dismissed — let UIKit
// handle it; the ladder below is only for the player's own chrome.
if presentedViewController != nil {
    super.dismiss(animated: flag, completion: completion)
    return
}
```

(Match the override's actual parameter names.)

- [ ] **Step 3: Container cache + sinks**

Near `upNextEpisodesCache` (line ~39):

```swift
private var insightsCastCache: [MediaPerson] = []
```

After the `vm.$upNextEpisodes` sink (ends ~line 846), add:

```swift
vm.$insightsCast
    .receive(on: DispatchQueue.main)
    .sink { [weak self] cast in
        guard let self else { return }
        self.insightsCastCache = cast
        self.rail?.setInsightsAvailable(!cast.isEmpty)
    }
    .store(in: &cancellables)

// Kick the cast load per item. @Published replays the current value on
// subscribe, so this also fires once at bind time for the first item.
vm.$itemGeneration
    .removeDuplicates()
    .receive(on: DispatchQueue.main)
    .sink { [weak vm] _ in
        Task { await vm?.loadInsightsCast() }
    }
    .store(in: &cancellables)
```

- [ ] **Step 4: Rail closure + presentation**

After the `rail.onUpNext` closure (ends ~line 902), add:

```swift
rail.onInsights = { [weak self] in
    guard let self, !self.insightsCastCache.isEmpty else { return }
    self.presentRailPanel(
        content: InsightsCastListView(
            cast: self.insightsCastCache,
            onSelect: { [weak self] person in self?.presentPersonPage(person) }),
        width: 480, from: rail.insightsButton)
}
```

Add the presentation helper near `presentRailPanel` (line ~916):

```swift
/// Cast row Select → person detail page over paused playback. The rail
/// panel is dismissed first (its focus fence would fight the presented
/// page), and playback resumes when the page is dismissed. Filmography
/// posters are intentionally inert from the player (onSelectItem unset)
/// — navigating to another title mid-playback is out of scope for P1.
private func presentPersonPage(_ person: MediaPerson) {
    guard let vm = viewModel else { return }
    activeRailPanel?.dismissPanel()
    vm.pause()
    let page = PersonDetailViewController(person: person)
    page.onDismiss = { [weak vm] in vm?.resume() }
    present(page, animated: true)
}
```

- [ ] **Step 5: Build and run unit tests**

```bash
xcodebuild test -scheme Rivulet -destination "platform=tvOS Simulator,id=<UDID>" \
  -derivedDataPath /tmp/rivulet-insights-dd \
  -only-testing:RivuletTests/InsightsCastMapperTests \
  -only-testing:RivuletTests/TMDBEpisodeCreditsTests 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED, 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Rivulet/Views/Player/PlayerContainerViewController.swift Rivulet/Views/Media/Person/UIKit/PersonDetailViewController.swift
git commit -m "feat(insights): wire Cast panel into player rail + person page deep link"
```

---

### Task 7: End-to-end verification on simulator

**Files:** none (verification only)

- [ ] **Step 1: Build + install to the simulator**

```bash
UDID=$(xcrun simctl list devices | grep -o '33E70EDB[A-F0-9-]*' | head -1)
xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/rivulet-insights-dd build 2>&1 | tail -3
xcrun simctl install "$UDID" /tmp/rivulet-insights-dd/Build/Products/Debug-appletvsimulator/Rivulet.app
```

- [ ] **Step 2: Manual checklist (run with the user, or via the /playback-test skill against 183532 Interstellar for movie + any episode for TV)**

1. Start playback → show chrome → rail shows a fifth button (person icon) once cast loads; hidden if the item has no cast.
2. Select Cast → panel rises above the rail (same look as Up Next), header "Cast", rows show headshot / name / character. First row focused.
3. Scroll to bottom, scroll back — no focus bounce, no layout jumps.
4. Menu with panel open → panel closes, player stays.
5. Select an actor → panel closes, playback pauses, person page appears with bio/filmography.
6. Menu on person page → page dismisses, playback resumes, chrome briefly visible.
7. Episode content: guest stars appear after regulars (requires Task 1 deployed; otherwise show cast only — verify no crash either way).
8. Home-media item without a tmdb guid: Cast button appears only if Plex roles exist; no errors.

- [ ] **Step 3: Report results**

Report each checklist item's pass/fail honestly. Any failure: stop and fix before proceeding (systematic-debugging skill), re-run the checklist.
