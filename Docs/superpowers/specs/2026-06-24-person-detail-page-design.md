# Person (Actor) Detail Page — Design

Date: 2026-06-24
Status: Approved (pending written-spec review)
Reference: `Docs/atv_ref/actor_details_ref.{md,JPG}`

## 1. Goal

When a user selects a cast (actor) member in a movie/show detail page, open a
full-screen **person detail page**: a circular portrait + name + biography header
(the bio truncates with a `MORE` action into the existing info popup), followed by
poster shelf rows of the **Movies** and **Shows** that person is in.

The reference is the Apple TV app's actor page (`actor_details_ref.JPG`): dark
blue→black gradient, true-circle portrait on the left, name + muted bio on the right
with an uppercase `MORE` truncation, then horizontal poster rows.

## 2. Scope (v1)

In scope:
- Cast (actors) only are tappable. Crew (directors/writers) remain inert in v1.
- Header: circular portrait + name + truncated biography + `MORE` → info popup.
- Two poster shelf rows: **Movies** and **Shows**.
- Filmography = the person's titles, **server-owned titles shown first** in each row,
  then the rest of their filmography as Discover/watchlist-style items.
- Discover-only ("more") posters carry the existing watchlist long-press menu.

Out of scope (v1):
- Crew tappability, person search, deep links.
- Per-poster caption text (see §6 — our shelf is intentionally caption-less).
- Nested cast browsing from within the person page.
- Entry from the lighter episode detail page (`MediaItemDetailPageViewController`);
  v1 entry is from the expanded detail's below-fold cast row only.

## 3. Decisions (resolved during brainstorming)

| Question | Decision |
|---|---|
| Filmography breadth | Server titles **first**, then the rest of the filmography as Discover-style items. |
| Bio + portrait source | **Plex Discover person** (via the role's `tagKey`). No TMDB dependency. |
| Who is tappable | **Cast (actors) only.** |
| Poster caption | **None.** Reuse the identical caption-less shelf; do not diverge from other rows. |

## 4. Data flow (the core)

One primary fetch drives the page. Instead of resolving the actor's per-library
numeric id in every library (that id is library-scoped and we only have the origin
library's), we fetch the person's full filmography once from Plex Discover and
partition it against the existing in-library index.

```
Cast cell tap  →  MediaPerson { tagKey, name, thumb, originActorId?, originSectionKey? }
        │
PersonFilmographyProvider.load(person)
        │
  ┌─────┴───────────────────────────────────────────────────────────┐
  │ GET metadata.provider.plex.tv/library/metadata/{tagKey}          │  account authToken,
  │     (+ filmography sub-call)  ?includeGuids=1                     │  includeGuids=1
  └─────┬───────────────────────────────────────────────────────────┘
        │  → biography (summary), portrait (thumb),
        │    filmography [Discover items, each carrying external guids]
        │
   partition each filmography item via LibraryGUIDIndex.lookup(guid:)
        │
   ┌────┴───────────────────────────────┐
   │ found on server  → playable MediaItem (plex provider)      ── shown FIRST
   │ not on server    → metadata-only MediaItem (discover/tmdb) ── "more"
   └────────────────────────────────────┘
        │
   bucket by type → Movies row, Shows row   (server titles first, then more)
```

Why this shape:
- The Discover person already enumerates the full filmography with stable external
  guids; `LibraryGUIDIndex` already maps a guid → server item in O(1). So "what can
  they play" vs "more" is a clean partition, not N per-library `?actor=` queries.
- "Server titles first, then more" falls directly out of the partition + a stable sort.
- "More" items already carry tmdb/imdb guids, so they behave exactly like existing
  Discover tiles (watchlist add, metadata-only detail).

### Fallback (no `tagKey`)

Some people are not matched to Plex's people DB and have no `tagKey`. The page then
degrades gracefully (never a dead end — the actor is in at least the current title):
- Portrait = the enlarged role `thumb`.
- No biography, no `MORE` action.
- Filmography via the **origin library only**:
  `GET /library/sections/{originSectionKey}/all?actor={originActorId}`, using the
  numeric id we get from `Role.filter` (e.g. `actor=49`). These are all server-owned,
  so they render as playable items.

## 5. Models & networking

### Extend existing
- `PlexRole` (`Models/Plex/PlexMetadata.swift`): decode `tagKey` and `filter`
  (currently only `tag`, `role`, `thumb` are decoded). `filter` yields the origin
  library numeric actor id; `tagKey` is the Discover person GUID fragment.
- `MediaPerson` (`Models/Media/MediaPerson.swift`): add `tagKey: String?`,
  `originActorId: String?`, `originSectionKey: String?` so the cast cell carries
  what the page needs.
- `PlexMediaMapper` (`Services/MediaProvider/Plex/PlexMediaMapper.swift`): populate
  the new `MediaPerson` fields when mapping `Role` → `MediaPerson`, and record the
  origin library section key on the detail mapping.

### New
- `PersonDetail` model:
  `{ id (tagKey), name, biography: String?, portraitURL: URL?, movies: [FilmographyEntry], shows: [FilmographyEntry] }`
- `FilmographyEntry`: `{ item: MediaItem, isOnServer: Bool }`
- `PlexDiscoverPersonService` (`Services/Plex/…`): GET the person + filmography from
  `metadata.provider.plex.tv` using the account-level token
  (`PlexAuthManager.shared.authToken`) and `includeGuids=1`, decode to raw items.
  Mirrors the existing `PlexContentAdvisoryService` / `PlexWatchlistAPI` host pattern.
- `PersonFilmographyProvider` (`@MainActor`): orchestrates the fetch, partitions via
  `LibraryGUIDIndex`, maps to `MediaItem`, buckets by type, applies the server-first
  sort, and returns a `PersonDetail`. Server matches map via `PlexMediaMapper.item`.
  Discover-only items arrive Plex-Discover-shaped (from `metadata.provider.plex.tv`),
  **not** as `TMDBListItem`; they are mapped to a metadata-only `MediaItem` keyed by
  their `tmdb://` guid — the same representation Discover/watchlist already use — so
  they route through the existing metadata-only presentation. The exact small mapper
  (extract tmdb id + title + poster → metadata-only `MediaItem`) is confirmed in
  implementation. This provider is the seam the VC depends on; the exact Discover
  endpoint shape lives entirely behind it.

### Reused
`LibraryGUIDIndex` (guid → server item), `MediaItem` / `PlexMediaMapper` /
TMDB metadata-only mapper, `InfoPopupViewController` (the `MORE` popup), the watchlist
add path + context menu.

## 6. UI — `PersonDetailViewController` (UIKit)

Built in UIKit, consistent with the canonical detail stack (SwiftUI detail is
deprecated). Presented full-screen and **opaque** (the reference is a full dark page),
over a dark blue→black gradient background.

The VC hosts an outer **vertical** collection that follows the established
`FocusScrollControlledCollectionView` pattern (scroll disabled, vertical scroll
self-driven from `didUpdateFocus`) so vertical focus motion matches the rest of the
detail UI:

- **Header section** (bespoke cell): true-circle portrait on the left (no square
  backing), name on the right (large, semibold, ~48pt white), biography paragraph
  below the name (muted light gray, truncated) with an uppercase `MORE` affordance.
  `MORE` presents `InfoPopupViewController(content: .description(title: name,
  subtitle: nil, body: biography), width: 840)` — the same popup used for the
  synopsis. No glass backing behind the header (reference is flat).

- **Shelf rows** (`Movies`, `Shows`): the **identical** `ShelfRowCell` used by Home /
  Library / the below-fold Related row — `TileKind.poster`, `PosterCell` tiles via
  `configure(item: MediaItem)`, `MediaRowMetrics` margins/gaps/slivers, the in-cell
  `headerTitle` ("Movies" / "Shows"). No per-poster caption (PosterCell is
  deliberately caption-less to avoid cropping 2:3 posters; matching the other rows is
  the governing constraint). Server titles sort first within each row. Discover-only
  tiles get the watchlist menu via `ShelfRowCell.contextMenuProvider`; an optional
  subtle "not in library" affordance MAY mark them, but must not change tile geometry.

Empty rows (e.g. no shows) are omitted rather than shown empty.

## 7. Navigation

### Into the page
Today cast cells are focusable but inert (no select handler). Add:
- `BelowFoldCollectionView.onSelectPerson: ((MediaPerson) -> Void)?` and a `.cast`
  case in its `didSelectItemAt`.
- Forward it through `ExpandedDetailContainerView` (mirroring `onShowRelatedDetails` /
  `onShowEpisodeDetails`).
- `PreviewCarouselViewController` wires it to `present(PersonDetailViewController(...))`.

### Out of a poster
Routed by item source, exactly as the rest of the app already does:
- Server item → the existing UIKit standalone detail (`presentStandaloneDetail`).
- Discover-only item → the existing Discover metadata-only presentation (so "more"
  items behave like Discover items). The exact call is confirmed during the wiring
  step against how `DiscoverView` presents a metadata-only `MediaItem`.

## 8. Risks & first step

- **Exact Discover person filmography sub-path.** The person endpoint returns the
  person; the filmography may be inline hubs vs a `/children` (or `/related`) call.
  Web sources point to `/children`. **First implementation step is a small live spike**
  against the real server to pin the exact path + JSON before building the VC. The
  `PlexDiscoverPersonService` / `PersonFilmographyProvider` seam isolates the rest of
  the code from the answer, so the UI work is unblocked regardless.
- **Discover person coverage.** People without a `tagKey` use the §4 fallback path.
- **Account token availability.** Discover requires `PlexAuthManager.shared.authToken`
  (account-level), never `selectedServerToken`. Shared-server-only users without an
  account token fall back to §4 (origin-library filmography, no bio).

## 9. Files

New:
- `Models/.../PersonDetail.swift` (`PersonDetail`, `FilmographyEntry`)
- `Services/Plex/PlexDiscoverPersonService.swift`
- `Services/.../PersonFilmographyProvider.swift`
- `Views/Media/.../UIKit/PersonDetailViewController.swift` (+ a header cell;
  reuse `ShelfRowCell` / `PosterCell` for the rows)

Changed:
- `Models/Plex/PlexMetadata.swift` (PlexRole: `tagKey`, `filter`)
- `Models/Media/MediaPerson.swift` (carry `tagKey`, `originActorId`, `originSectionKey`)
- `Services/MediaProvider/Plex/PlexMediaMapper.swift` (populate the above)
- `Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` (`onSelectPerson` +
  `.cast` select case)
- `Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift` (forward callback)
- `Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` (present the
  person page)

## 10. Reuse summary

Identical shelf rows (`ShelfRowCell` + `PosterCell` + `MediaRowMetrics`), unified
`MediaItem`, `LibraryGUIDIndex` partition, `InfoPopupViewController`, the watchlist
path, and the existing below-fold callback-forwarding pattern. New code is confined to
the person data layer (service + provider + model) and the person VC's header + outer
vertical layout.
