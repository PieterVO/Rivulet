# TMDB Logo Artwork — Design

**Date:** 2026-04-23
**Branch:** `feature/discover-watchlist`
**Scope:** Display TMDB logo artwork in place of the plain-text title on two Discover surfaces: the hero carousel at the top of the Discover page, and the preview overlay that appears when a row item is opened.

## Motivation

Today the Discover hero renders `Text(item.title)` as a large bold string over the backdrop, and the preview overlay (`MediaDetailView`) falls back to the same when no logo URL is plumbed through. TMDB exposes per-title logo artwork via its `/images` endpoint; using it gives each title its native brand treatment instead of a generic typeface.

The Cloudflare Worker already proxies TMDB's images endpoint (`/tmdb/images/{id}?type={movie|tv}`, index.ts:94-96) and the agnostic `MediaArtwork` struct already carries a `logo: URL?` field that `MediaDetailView` already consumes. The missing piece is the TMDB-side wiring: fetching the images response, picking the right logo, caching the result, and feeding it into both surfaces.

## Out of scope

- Hero backdrop image quality (unchanged — already fetches `original`).
- Row-tile titling (tiles don't show a title today; no change).
- Plex logo handling (already works via `clearLogoPath`).
- Worker changes (already has the `/tmdb/images` route).

## Approach

Enrich `MediaItem.artwork.logo` in the existing TMDB pipeline, so every consumer downstream reads a single field. The hero carousel, which renders `TMDBListItem` directly and never goes through `MediaItem`, calls the same cache on its own.

One cache, two call sites, both using the same lookup. Consumers that have a `MediaItem` read `artwork.logo`; consumers that don't read the cache directly. The field is always the truth when present.

### Why not a dedicated service with a "consumers call me instead of reading the field" convention

Initially considered. Rejected because:
- `MediaArtwork.logo` already exists on the agnostic model.
- `MediaDetailView` already consumes it (`Views/Media/MediaDetailView.swift:1820`).
- A parallel "real logo lives elsewhere" convention creates a split that nobody remembers six months later.

## Components

### `TMDBLogoCache` (new)

**File:** `Rivulet/Services/TMDB/TMDBLogoCache.swift`

Actor singleton. Owns memory + disk cache and network fetching for TMDB logo URLs.

```swift
actor TMDBLogoCache {
    static let shared = TMDBLogoCache()

    func logoURL(tmdbId: Int, type: TMDBMediaType) async -> URL?
}
```

**Memory cache:**

```swift
private var cache: [Key: URL?] = [:]
private var inflight: [Key: Task<URL?, Never>] = [:]
private struct Key: Hashable { let tmdbId: Int; let type: TMDBMediaType }
```

Value is `URL?` — a confirmed "no logo" is a cacheable answer and won't re-fetch.

`inflight` dedupes concurrent calls for the same key: hero slide and prefetch ring asking for tmdb 12345 at the same time produce one network request with two awaiters.

**Disk cache:** `Caches/TMDBLogoCache/{type}_{id}.json`

```json
{ "resolvedAt": "2026-04-23T12:00:00Z", "logoPath": "/xyz.png" }
```

Stores the TMDB relative path, not the full URL — so changing the size (`w500` → `w300`) or the CDN base doesn't invalidate the cache. `logoPath: null` is a valid entry and a cache hit.

**Lookup order per call:**
1. Memory → return if present.
2. Disk (if within TTL) → hydrate memory, return.
3. Network → write both, return.

**TTL:** 30 days. Matches `TMDBDiscoverService.detailCacheTTL`. Logos almost never change.

**Failure handling:** network or decode failure returns `nil` but does **not** write to disk. Transient outages must not poison the cache for 30 days. Memory also skips the write so the next call retries.

**Session injection:** actor takes an optional `URLSession` in init, matching `TMDBDiscoverService`'s pattern. Tests inject a session with a `URLProtocol` stub.

### `TMDBImagesResponse` (new)

**File:** `Rivulet/Models/TMDB/TMDBImagesResponse.swift`

DTO decoded from `/tmdb/images/{id}`. Pure value type with one computed helper.

```swift
struct TMDBImagesResponse: Decodable {
    let logos: [TMDBImageEntry]
}

struct TMDBImageEntry: Decodable {
    let filePath: String?
    let iso6391: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
        case voteAverage = "vote_average"
    }
}

extension TMDBImagesResponse {
    /// Best logo path according to the selection rule. Nil if the response has none.
    var bestLogoPath: String? { ... }
}
```

**Logo selection rule** (implemented on the extension, consistent with existing `MediaItem.heroBackdropRequest()` / `PlexMetadata.heroBackdropRequest()` pattern):
1. Prefer `iso_639_1 == "en"`.
2. Else `iso_639_1 == nil` (language-agnostic — often a pure mark).
3. Else any remaining.
4. Within a tier, highest `voteAverage`.
5. Drop entries with missing `file_path`.

Returns the TMDB relative path (e.g. `/abc.png`). The cache's public method wraps it into `URL(string: "https://image.tmdb.org/t/p/w500\(path)")`.

**Why an extension on the DTO, not a method on the cache:** URL/path-picking logic is pure value-type work. Services own state; value types own their own derivations. Matches the convention set in commit `efabf2a` ("hero: drop 'plex' prefix from HeroBackdropRequest fields + add MediaItem adapter").

### Call site A — `DiscoverHeroSlide`

**File:** `Rivulet/Views/Discover/DiscoverHeroOverlay.swift` (the private `DiscoverHeroSlide` struct, lines 232-268).

Today: renders `Text(item.title)` unconditionally.

Change: add `@State private var logoURL: URL?` plus a `.task(id: item.id)` that calls the cache. Body branches: if `logoURL` non-nil, render via `CachedAsyncImage`; otherwise render the existing title `Text`.

**Logo frame:** `maxWidth: 520, maxHeight: 180`, `.scaledToFit()`, same drop shadow as the title. These are starting values — easy to tune once real content renders.

**Behavior:**
- First render: title shows immediately (logo not resolved yet).
- Logo resolves → swaps in. SwiftUI's default transition is fine; add `.animation(.easeInOut(duration: 0.2), value: logoURL)` if the swap feels harsh.
- Paging: `.task(id: item.id)` cancels + restarts. Return visits are instant (cache hit).
- No logo available: cache returns nil → title stays; subsequent visits are no-op (cache hit).
- Loading failure (`CachedAsyncImage` fails even though cache said there's a URL): fall back to title.

### Call site B — Preview overlay prefetch

**File:** TBD during implementation. Candidates based on recent commit messages ("carousel: resolve library matches + TMDB backdrops before/during prefetch"): `PreviewOverlayHost.swift` itself or a nearby prefetch helper.

Wherever the enrichment loop constructs the richer `MediaItem` from the TMDB stub, add an `async let logo = TMDBLogoCache.shared.logoURL(tmdbId: id, type: type)` in parallel with the existing awaits, then thread `logo` into `MediaArtwork(..., logo: await logo)`.

`async let` ensures this doesn't serialize behind the detail fetch or library match.

**No change needed:** `TMDBMediaMapper.item(_:)` stays synchronous. The enrichment happens where logos are already being fetched anyway (the ring), not in the general-purpose mapper.

### Call site C — `MediaDetailView`

**No code changes.**

`MediaDetailView` already reads `heroBackdrop.session.logoURL`, which flows from `MediaItem.heroBackdropRequest().logoURL`, which reads `artwork.logo`. The full pipeline works once call site B populates the field.

## Data flow

```
TMDB stub (TMDBListItem)
   │
   ├─► Hero carousel ──► DiscoverHeroSlide.task ──► TMDBLogoCache ──► @State logoURL
   │                                                     │
   │                                                     ▼
   │                                        (memory + disk cache hit on repeat)
   │
   └─► Preview overlay prefetch ─► enrich loop ─► TMDBLogoCache
                                                       │
                                                       ▼
                                            MediaItem.artwork.logo
                                                       │
                                                       ▼
                                            MediaDetailView (unchanged)
```

## Testing

### Unit tests — `RivuletTests/Unit/Services/TMDBLogoCacheTests.swift`

- **Selection rule** (on `TMDBImagesResponse.bestLogoPath`, pure value logic)
  - Prefers `en` over others.
  - Falls back to `nil` language when no `en`.
  - Highest `voteAverage` within a tier.
  - Empty `logos` → nil.
  - Entries with missing `file_path` are skipped.
- **Cache hits** — second call for same key doesn't hit network.
- **Nil caching** — "no logo" result caches; subsequent call doesn't refetch.
- **Inflight dedup** — two concurrent calls produce one request.
- **Disk round-trip** — cold start reads from disk, no network.
- **Disk TTL** — entry older than 30 days is refetched.
- **Network failure** — returns nil, does **not** write disk, next call retries.

Inject `URLSession` + `URLProtocol` stub to count and control requests.

### Manual verification

1. Discover hero: cycle through a few popular items; logo appears after a beat.
2. Discover hero: page away and back; logo instant (cache hit).
3. Preview overlay: open a TMDB item; logo appears in `MediaDetailView` hero.
4. Obscure title with no logo: title falls back cleanly, no flicker loop.
5. Relaunch app: previously-viewed titles show logos instantly (disk cache).

## Risks / open questions

- **Logo frame sizing** — starting with `maxWidth: 520, maxHeight: 180`. TMDB logos vary widely in aspect ratio (square marks vs. long wordmarks); may need tuning per manual verification.
- **Flicker on slow cold fetch** — first view shows title, then swaps to logo 200-400ms later. Acceptable; can tighten with the animation hint above if needed.
- **No logo selection in other languages** — user locale isn't considered (English-first). Not in scope; revisit if users ask.

## Files touched

- `Rivulet/Services/TMDB/TMDBLogoCache.swift` — new.
- `Rivulet/Models/TMDB/TMDBImagesResponse.swift` — new.
- `Rivulet/Views/Discover/DiscoverHeroOverlay.swift` — modify `DiscoverHeroSlide` to resolve + render logo.
- Preview overlay prefetch site (TBD) — add one `async let` and wire into `MediaArtwork.logo`.
- `RivuletTests/Unit/Services/TMDBLogoCacheTests.swift` — new.
