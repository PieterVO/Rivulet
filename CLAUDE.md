# Rivulet - Claude Context

Rivulet is a tvOS media client for Plex and IPTV. The primary surfaces (Home, Library, Search, Discover, Media Detail, the preview carousel, Person detail, and the player chrome) are **UIKit**; SwiftUI remains for thin navigation shells, Music, Live TV slots, Settings, and the shared `MediaDetailView` navigation destination.

The video player is **AetherPlayer** — an adapter around AetherEngine (FFmpeg demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a software sample-buffer backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It is the only player: VOD **and** Live TV. Video MUST render through the engine surface (`AetherVideoSurfaceView` → `engine.bind(view:)`), never an AVPlayerLayer on `currentAVPlayer`. The only other path is `hls`: AVPlayer on a Plex server transcode, used when no direct-play URL exists or as the fallback after an Aether startup failure. `ContentRouter.plan(...)` picks aether vs hls per item. (RPlayer and the localRemux/avPlayerDirect routes have been removed — see git history.)

## Quick Reference

- **Platform**: tvOS 26+ (Apple TV)
- **Language**: Swift 6
- **UI Framework**: UIKit for the primary surfaces (see above); SwiftUI for the rest
- **Video Player**: AetherPlayer for VOD and Live TV; AVPlayer only for the `hls` route (server transcode, primary-when-no-direct-URL or Aether fallback). See `Docs/RIVULET_PLAYER.md`.
- **Design Guide**: See `Docs/DESIGN_GUIDE.md` for UI/UX patterns

## Project Structure

```
Rivulet/
├── Models/
│   ├── Plex/           # Plex API models (PlexMetadata, PlexStream, etc.)
│   └── SwiftData/      # Persistent models (Channel, EPGProgram, PlexServer)
├── Services/
│   ├── Plex/
│   │   ├── (PlexNetworkManager, PlexAuthManager, PlexDataStore, …)
│   │   └── Playback/   # AetherPlayer + routing/remux (see Docs/RIVULET_PLAYER.md)
│   │       ├── Pipeline/     # ContentRouter (routing decisions)
│   │       └── Subtitles/    # SubtitleManager, SubtitleParser, SubtitleOverlayView, SubtitleClockSyncController
│   ├── LiveTV/         # PlexLiveTVProvider, IPTVProvider, LiveTVDataStore
│   ├── IPTV/           # M3UParser, XMLTVParser, DispatcharrService
│   ├── Cache/          # CacheManager, ImageCacheManager
│   └── Focus/          # FocusMemory (tvOS section focus restoration)
├── Views/
│   ├── Player/         # UniversalPlayerView, UniversalPlayerViewModel, PlayerContainerViewController,
│   │                   #   AVPlayerLayerView, TrackSelectionSheet, PlayerPresenter
│   │   ├── Aether/     # AetherSubtitleCue (bridge type)
│   │   ├── Subtitles/  # SubtitleModel-era types removed; see Services/…/Subtitles
│   │   ├── UIKit/      # PlayerRailView, PlayerRailPanelView, PlayerProgressBarView, UpNextListView, pills (canonical player chrome)
│   │   └── PostVideo/  # Post-playback summary overlays
│   ├── Media/          # MediaDetailView (SwiftUI detail, still the nav destination),
│   │                   #   PreviewContext, PreviewMenuBridge, HeroBackdropSupport, SharedMediaComponents,
│   │                   #   CastMemberCard (CastCrewRow), SummarySheet, PreviewContainerViewController
│   │   ├── UIKit/, PlexHome/UIKit/, MediaDetail/UIKit/, Person/UIKit/, Library/UIKit/, PreviewCarousel/UIKit/
│   │   │              #   — the canonical UIKit home/detail/library/person/carousel surfaces
│   │   └── Hero/       # HeroPlaySession + hero support (SwiftUI HeroBackdropLayer/OverlayContent removed)
│   ├── Music/          # MusicHomeView, MusicAlbumDetailView, MusicArtistDetailView,
│   │                   #   MusicNowPlayingView, MusicQueueListView, MusicQueueCarousel,
│   │                   #   MusicPlaylistView, MusicLyricsView, MusicVisualizerView
│   │   └── Components/ # MusicProgressBar, MusicPosterCard, MusicShelfRow
│   ├── Discover/       # DiscoverViewModel (SwiftUI Discover* views removed; UIKit home renders Discover)
│   ├── LiveTV/         # ChannelListView, GuideLayoutView, MultiStreamViewModel, StreamSlotView, AetherSlotPlayerView
│   ├── Settings/       # SettingsView, SettingsComponents, SettingsDescriptors, sub-pages
│   ├── Components/     # CachedAsyncImage, GlassRowStyle
│   ├── TVNavigation/   # TVSidebarView, NavigationEnvironment
│   └── Root/           # SidebarView
└── Docs/
    ├── RIVULET_PLAYER.md   # Canonical player reference (routing, AetherPlayer + AVPlayer)
    └── DESIGN_GUIDE.md     # UI/UX documentation
```

## Key Architectural Patterns

### Focus Management (tvOS)

Uses standard SwiftUI focus primitives with `FocusMemory` for section-level restoration. No custom focus scope manager — focus isolation is handled by system mechanisms:

- **`fullScreenCover`** — automatic focus isolation for overlays/popups
- **`TabView` with `sidebarAdaptable`** — system-managed sidebar/content focus
- **`@FocusState` + `.onAppear`** — setting initial focus in presented views
- **`FocusMemory`** — remembers and restores focus within scrollable sections

```swift
// Section focus memory
.focusSection()
.remembersFocus(key: "uniqueSectionKey", focusedId: $focusedItemId)

// Initial focus in fullScreenCover (no Namespace/resetFocus needed)
.onAppear {
    focusedUserId = profileManager.selectedUser?.id
}
```

### Video Player Architecture

**AetherPlayer** (an adapter around AetherEngine) is the only player, used for both VOD and Live TV. It conforms to `PlayerProtocol`; video renders through the engine surface via `AetherVideoSurfaceView` (`engine.bind(view:)`), which hosts whichever layer the active backend uses. The app drives a plain `AVPlayer` only on the `hls` route (Plex server transcode). `ContentRouter.plan(...)` returns a `PlaybackPlan { primary, fallbacks }`. Canonical reference: `Docs/RIVULET_PLAYER.md`.

```
UniversalPlayerView (SwiftUI) + PlayerContainerViewController (UIKit chrome)
        │
UniversalPlayerViewModel  ← state, markers, post-video, NowPlaying, route changes
        │
   ContentRouter.plan(...) → PlaybackPlan { primary, fallbacks }
        │
        ├── .aether → AetherPlayer, rendered via AetherVideoSurfaceView (direct-play URL exists; the default)
        └── .hls    → AVPlayer on Plex server transcode (no direct-play URL, or fallback after Aether failure)

Live TV: MultiStreamViewModel / StreamSlotView instantiate AetherPlayer() per grid slot,
         rendered via AetherSlotPlayerView (AVPlayerLayer). Up to 4 concurrent slots.
```

Key components:
- **`UniversalPlayerView`** / **`UniversalPlayerViewModel`**: SwiftUI container + state. Handles markers, post-video, route changes, NowPlaying. The player chrome itself is UIKit (`Views/Player/UIKit/`).
- **`AetherPlayer`**: `PlayerProtocol` adapter around AetherEngine. Exposes Combine publishers for state, audio/subtitle tracks, and `currentAVPlayer`. Handles HDR10+ / HLG / EAC3+JOC Atmos. `setMuted` persists across Aether's internal player swaps (used by the Live TV grid).
- **`ContentRouter`**: routing decisions → `PlaybackPlan`.
- **`SubtitleManager` + `SubtitleParser` + `SubtitleOverlayView` + `SubtitleClockSyncController`**: subtitle rendering for the `hls` route. On the aether route, subtitles come from the engine's cue publishers rendered by `AetherSubtitleOverlayView` (fed via `SubtitleModel`).

**Playback States** (PlayerProtocol): `.idle`, `.loading`, `.playing`, `.paused`, `.buffering`, `.ended`, `.failed`

#### Routing policy (VOD)
1. `ContentRouter.plan(...)` returns `PlaybackPlan { primary, fallbacks }`. Route cases: `.aether`, `.hls`.
2. `.aether` — whenever a direct-play URL is available (AetherEngine handles demux + remux + HDR internally; software-decodes AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). DV P7 plays as HDR10 base.
3. `.hls` — server-side transcode; primary when no direct-play URL exists, and the fallback after an Aether startup failure. `requiresVideoTranscode` codecs force a video transcode (not just remux) on this route.

#### Live TV
Routes through **AetherPlayer** per grid slot (`MultiStreamViewModel` / `StreamSlotView` instantiate `AetherPlayer()`, rendered via `AetherSlotPlayerView`). The grid supports up to 4 concurrent slots (opt-in past 2). HDHomeRun delivers a direct stream; DVB tuners require a Plex transcode URL with full client-profile parameters (see Plex Live TV section below).

### Plex Metadata Hierarchy

For TV shows:
- **Show** (`grandparentRatingKey`) → **Season** (`parentRatingKey`) → **Episode** (`ratingKey`)
- Episode has `index` (episode number) and `parentIndex` (season number)

**Note**: Items from "Continue Watching" hub may lack parent metadata. Use `PlexNetworkManager.getMetadata()` to fetch full details.

### Glass UI Style

All focusable rows use consistent styling (see `Docs/DESIGN_GUIDE.md`):

```swift
// Background
.fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
.strokeBorder(isFocused ? .white.opacity(0.25) : .white.opacity(0.08), lineWidth: 1)

// Scale
.scaleEffect(isFocused ? 1.02 : 1.0)

// Animation
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
```

## Common Tasks

### Presenting a Focus-Isolated Overlay

Use `fullScreenCover` — it provides automatic focus isolation without manual scope management:

```swift
.fullScreenCover(isPresented: $showOverlay) {
    MyOverlayView(isPresented: $showOverlay)
        .presentationBackground(.clear)  // See-through to content behind
}
```

In the presented view, use `@FocusState` with `.onAppear`:
```swift
@FocusState private var focusedItem: String?

.onAppear {
    focusedItem = defaultItemId
}
.onExitCommand {
    isPresented = false
}
```

### Fetching Next Episode

```swift
// Get episodes in current season
let episodes = try await networkManager.getChildren(
    serverURL: serverURL,
    authToken: authToken,
    ratingKey: metadata.parentRatingKey  // Season key
)

// Find next episode
let next = episodes.first(where: { $0.index == currentEpisodeIndex + 1 })
```

### Release Notes / Changelog

Release notes live ONLY in the `changelogs` array in
`Rivulet/Views/Components/WhatsNewView.swift` (root `CHANGELOG.md` is a stub).
Entries are keyed by build-qualified version (`"1.0.3 (65)"`), newest first.
Settings → About → Changelog renders the full history; the fresh-launch
"What's New" shows only the current build's entry. Write bullets as simple,
user-facing sentences (what users get, not internal details); no em dashes.
Every AetherEngine bump gets a changelog line.

### Adding Settings

Use components from `SettingsComponents.swift`:
- `SettingsRow` - Navigation with chevron
- `SettingsToggleRow` - On/Off toggle
- `SettingsPickerRow` - Cycles through options
- `SettingsActionRow` - Action button (supports destructive)

**Never put a subtitle/description inside a settings row.** Rows are title-only
so the list stays scannable and the focus target stays compact. Any descriptive
copy lives in the **left-side description panel**, which is driven by
`SettingsDescriptors.swift`. Register a descriptor keyed by the row's
`focusedSettingId` with an icon, color, and a clear description. The panel
updates as the user moves focus between rows.

### Image Loading

Always use `CachedAsyncImage` for remote images:
```swift
CachedAsyncImage(url: imageURL) { phase in
    switch phase {
    case .success(let image): image.resizable()
    case .empty: ProgressView()
    case .failure: Image(systemName: "photo")
    }
}
```

## Build & Run

```bash
# Build for tvOS Simulator
xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build

# Build for device
xcodebuild -scheme Rivulet -destination 'platform=tvOS,name=My Apple TV' build
```

## Key Files

| Purpose | File |
|---------|------|
| Player container (SwiftUI) | `Views/Player/UniversalPlayerView.swift` |
| Player view model | `Views/Player/UniversalPlayerViewModel.swift` |
| Player container (UIKit chrome) | `Views/Player/PlayerContainerViewController.swift` |
| Player rail UI (UIKit) | `Views/Player/UIKit/PlayerRailView.swift` |
| Rail panel (UIKit) | `Views/Player/UIKit/PlayerRailPanelView.swift` |
| Up Next panel (UIKit) | `Views/Player/UIKit/PlayerUpNextPanelView.swift` |
| Player (AetherEngine adapter) | `Services/Plex/Playback/AetherPlayer.swift` |
| Live TV slot render surface | `Views/LiveTV/AetherSlotPlayerView.swift` |
| Routing decisions | `Services/Plex/Playback/Pipeline/ContentRouter.swift` |
| Aether render surface | `Views/Player/Aether/AetherVideoSurfaceView.swift` |
| Aether subtitle overlay | `Views/Player/Aether/AetherSubtitleOverlayView.swift` |
| Subtitle pipeline | `Services/Plex/Playback/Subtitles/SubtitleManager.swift` |
| Focus memory | `Services/Focus/FocusMemory.swift` |
| Plex API | `Services/Plex/PlexNetworkManager.swift` |
| Glass row styling | `Views/Components/GlassRowStyle.swift` |
| Settings components | `Views/Settings/SettingsComponents.swift` |
| Player canon docs | `Docs/RIVULET_PLAYER.md` |
| Design patterns | `Docs/DESIGN_GUIDE.md` |

## Design Philosophy

From `Docs/DESIGN_GUIDE.md`:

- **Simplicity First**: Remove rather than add. The interface should feel calm.
- **Elegant Restraint**: Subtle effects (2% scale, soft glow) over flashy ones.
- **Liquid Glass**: Translucent backgrounds with subtle borders (tvOS 26 aesthetic).
- **Subtle Motion**: Small scale effects, natural animations.
- **Invisible Complexity**: Complex features should feel simple to use.

**Design Don'ts**:
- No over-decoration (gradients, unnecessary shadows)
- No aggressive animations (bouncing, overshooting)
- No redundant icons/labels
- No "just in case" features

## PR Review Standard

Every PR review — contributor or AI-generated — requires two assessments, not one:

1. **Technical**: Will it work? Bugs, Swift 6 correctness, edge cases, regressions.
2. **Fit**: Does it belong in Rivulet? Apply these filters:
   - Does it match the design philosophy above (Simplicity First, no "just in case" features)?
   - Is this better owned by the OS/platform? (If AVPlayer / AetherEngine gets it for free, defer to the system rather than replicate.)
   - Does it add ongoing maintenance surface the project has to own?
   - Does it pull Rivulet toward a focused, calm product or away from it?

Good code that adds the wrong thing is still a no. A verdict of MERGE requires both assessments to pass.

## Troubleshooting

### Focus Not Working in Overlay
- Use `fullScreenCover` for focus-isolated overlays (provides its own focus hierarchy)
- Set initial focus via `@FocusState` in `.onAppear`
- Use `.onExitCommand` for Menu button dismissal
- For transparent overlays, add `.presentationBackground(.clear)` to the cover content

### Video Not Shrinking/Positioning
- Check `VideoFrameState` offset values (positive = padding from top-left with `.topLeading` anchor)
- Ensure `videoFrameState` is being set to `.shrunk`

### Post-Video Not Triggering
- Check if `hasTriggeredPostVideo` flag needs resetting
- Verify credits marker detection in `checkMarkers(at:)`
- Ensure `duration > 60` for time-based trigger (45s before end)

### Plex Live TV Not Starting (DVB Tuners)
- DVB tuners (TBS cards, etc.) don't have HDHomeRun stream URLs
- They require Plex server transcode via `/video/:/transcode/universal/start.m3u8`
- The transcode URL must include comprehensive client profile parameters
- Minimal URLs will cause stream-load failures; Plex needs to know client capabilities
- See `PlexLiveTVModels.buildPlexLiveTVStreamURL()` for required parameters

## Player (AetherPlayer / AVPlayer) on tvOS

VOD is served by AetherPlayer (`aether` route, the default) or AVPlayer (`hls` route: server transcode). Live TV runs on AetherPlayer per grid slot with `LoadOptions.isLive`. AetherEngine does its own demux + HLS-fMP4 remux + HDR handling internally; Rivulet has no app-level FFmpeg layer anymore (the packages are linked transitively through AetherEngine only).

### HDR / DV
- Aether drives `AVDisplayManager.preferredDisplayCriteria` itself (host `DisplayCriteriaManager` stands down on the aether route).
- DV P5 / P8.1 play with Dolby Vision via dvh1+dvcC sample entries; DV P7 plays as HDR10 base (the localRemux P7→P8 conversion path was removed).

## Plex Discover API

The Plex Discover API uses three different hosts:
- `discover.provider.plex.tv` — watchlist CRUD (`/library/sections/watchlist/all`, `/actions/addToWatchlist`, `/actions/removeFromWatchlist`)
- `metadata.provider.plex.tv` — metadata matches (`/library/metadata/matches?type={1|2}&guid=tmdb://X`)
- `metadata-static.plex.tv` — image CDN (fully-qualified URLs, no auth needed)

| Requirement | Notes |
|------------|-------|
| Token | Must use `authToken` (account-level), NOT `selectedServerToken` |
| GUIDs | Pass `includeGuids=1` — Plex omits the `Guid` array by default |
| Pagination | `X-Plex-Container-Size` is rejected on the watchlist endpoint |
| Mutations | Resolve external GUID → discover `ratingKey` via matches endpoint first, then PUT actions |

## Plex Live TV

### Stream URL Types

| Tuner Type | URL Source | Notes |
|------------|-----------|-------|
| HDHomeRun | `PlexLiveTVChannel.streamURL` | Direct stream, works out of box |
| DVB (TBS, etc.) | Built via `buildPlexLiveTVStreamURL()` | Requires full transcode params |

### Required Transcode Parameters for DVB
```
X-Plex-Client-Profile-Name, X-Plex-Client-Profile-Extra
mediaIndex, partIndex, offset
container, segmentFormat, segmentContainer
videoCodec, videoResolution, maxVideoBitrate, videoQuality
audioCodec, audioBitrate, audioChannels
session (unique UUID per session)
```

Without these, Plex returns errors or empty responses and the demuxer fails to open the stream.

## Sentry Error Patterns

| Error | Likely Cause |
|-------|-------------|
| `FFmpeg avformat_open_input failed` | Bad stream URL, network issue, missing transcode params, or Plex returned an HTML error page instead of a stream |
| `Demuxer: no streams found` / `unsupported codec` | AetherEngine probe failure — check the engine's demux logs |
| `HLS transcode session failed` | Incomplete transcode URL parameters |
| `HTTP 500 on /hubs` | Plex server issue (not client-side) |
| `NSURLErrorDomain -999 cancelled` | User navigated away, request timeout |
| Aether/AVPlayer startup fatal → auto HLS fallback | Expected: ContentRouter falls back to `.hls` once at current playback time |
