# Rivulet - Claude Context

Rivulet is a tvOS media client for Plex and IPTV. SwiftUI throughout. The primary video player is **Rivulet Player** (RPlayer): a custom FFmpeg-to-Apple-TV pipeline (demux/decode in FFmpeg, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer`) with full HDR / Dolby Vision support. AVPlayer is also used (via `NativePlayerViewController`) for routes where it's the better fit: natively-playable MP4s, the local HLS-remux path, and HLS fallback. `ContentRouter.plan(...)` picks the route per item.

## Quick Reference

- **Platform**: tvOS 26+ (Apple TV)
- **Language**: Swift 6
- **UI Framework**: SwiftUI
- **Video Players**: Rivulet Player (RPlayer) for FFmpeg-routed playback; AVPlayer (`NativePlayerViewController`) for `avPlayerDirect` / `localRemux` / `hls` routes. See `Docs/RIVULET_PLAYER.md` for routing and `Docs/PLAYER_INTERNALS.md` for RPlayer internals.
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
│   │   └── Playback/   # RivuletPlayer + pipeline (see Docs/RIVULET_PLAYER.md)
│   │       ├── Pipeline/     # DirectPlayPipeline, HLSPipeline, SampleBufferRenderer, ContentRouter, SegmentBuffer
│   │       ├── FFmpeg/       # FFmpegDemuxer, URLSessionAVIOSource, FFmpegAudioDecoder, FFmpegSubtitleDecoder
│   │       ├── Dovi/         # DoviProfileConverter, HEVCNALParser, LibdoviWrapper
│   │       └── Subtitles/    # SubtitleManager, SubtitleParser, SubtitleOverlayView, SubtitleClockSyncController
│   ├── LiveTV/         # PlexLiveTVProvider, IPTVProvider, LiveTVDataStore
│   ├── IPTV/           # M3UParser, XMLTVParser, DispatcharrService
│   ├── Cache/          # CacheManager, ImageCacheManager
│   └── Focus/          # FocusMemory (tvOS section focus restoration)
├── Views/
│   ├── Player/         # UniversalPlayerView, UniversalPlayerViewModel, PlayerContainerViewController,
│   │                   #   NativePlayerViewController (AVPlayer host), SampleBufferDisplayView,
│   │                   #   AVPlayerLayerView, PlayerControlsOverlay, PlayerProgressBar,
│   │                   #   TrackSelectionSheet, VideoInfoOverlay
│   │   └── PostVideo/  # Post-playback summary overlays
│   ├── Media/          # MediaDetailView (canonical detail), PlexHomeView, PlexLibraryView,
│   │                   #   PlexSearchView, MediaPosterCard, MediaItemRow, ContinueWatchingCard,
│   │                   #   DetailCardCarousel, PreviewOverlayHost (carousel), PreviewContext,
│   │                   #   PreviewContainerViewController, HeroBackdropSupport
│   │   ├── Hero/       # HeroBackdropLayer + supporting hero composition
│   │   └── Hubs/       # WatchlistHubRow and other home-screen hub rows
│   ├── Music/          # MusicHomeView, MusicAlbumDetailView, MusicArtistDetailView,
│   │                   #   MusicNowPlayingView, MusicQueueListView, MusicQueueCarousel,
│   │                   #   MusicPlaylistView, MusicLyricsView, MusicVisualizerView
│   │   └── Components/ # MusicProgressBar, MusicPosterCard, MusicShelfRow
│   ├── Discover/       # DiscoverView, DiscoverRow, DiscoverTile, DiscoverHeroBackdrop, TMDBContextMenu
│   ├── LiveTV/         # ChannelListView, GuideLayoutView, LiveTVPlayerView, MultiStreamViewModel
│   ├── Settings/       # SettingsView, SettingsComponents, SettingsDescriptors, sub-pages
│   ├── Components/     # CachedAsyncImage, GlassRowStyle
│   ├── TVNavigation/   # TVSidebarView, NavigationEnvironment
│   └── Root/           # SidebarView
└── Docs/
    ├── RIVULET_PLAYER.md   # Canonical player reference (routing, AVPlayer + RPlayer)
    ├── PLAYER_INTERNALS.md # RPlayer pipeline internals + critical flows
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

Two video players coexist: **RivuletPlayer** (RPlayer, FFmpeg-driven) and **AVPlayer** (hosted by `NativePlayerViewController`). `ContentRouter.plan(...)` returns a `PlaybackPlan { primary, fallbacks }`; the view model picks the player based on the route case. Live TV instantiates `RivuletPlayer()` directly per slot (`MultiStreamViewModel`/`StreamSlotView`). Canonical reference: `Docs/RIVULET_PLAYER.md`. Internals: `Docs/PLAYER_INTERNALS.md`.

```
UniversalPlayerView (SwiftUI)
        │
UniversalPlayerViewModel  ← state, markers, post-video, NowPlaying, route changes
        │
   ContentRouter.plan(...) → PlaybackPlan { primary, fallbacks }
        │
        ├── .avPlayerDirect / .localRemux / .hls  → AVPlayer (NativePlayerViewController)
        │      └── localRemux is served by LocalRemuxServer (FFmpegRemuxSession over HLS on localhost)
        │
        └── RPlayer DirectPlay (FFmpeg demux + AVSampleBuffer render)
                │
                ├── FFmpegDemuxer (libavformat, with URLSessionAVIOSource for http(s))
                ├── DV P7/P8.6 → P8.1 RPU rewrite (HEVCNALParser + LibdoviWrapper)
                ├── FFmpegAudioDecoder for TrueHD/DTS/PCM/FLAC; passthrough otherwise
                └── SampleBufferRenderer (display layer + audio renderer + synchronizer)
```

Key components (RPlayer side):
- **`UniversalPlayerView`** / **`UniversalPlayerViewModel`**: SwiftUI container + state. Handles markers, post-video, route changes, NowPlaying.
- **`RivuletPlayer`**: `PlayerProtocol` conformance. Drives the pipeline, exposes Combine publishers for state, audio/subtitle tracks.
- **`DirectPlayPipeline`**: read loop (demux → decode → enqueue), seeking with dedup, preroll buffering, audio track switching, dead-loop detection on resume.
- **`SampleBufferRenderer`**: owns `AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`, and `AVSampleBufferRenderSynchronizer` (the A/V clock).
- **`FFmpegDemuxer`**: libavformat wrapper. Uses `URLSessionAVIOSource` for http(s) (parallel ranged GET, required for high-bitrate 4K on tvOS). Reuses one `AVPacket` across reads. Rebuilds dvh1 format description for DV.
- **`FFmpegAudioDecoder`**: client-side decode for codecs Apple TV can't decode natively (TrueHD, DTS, PCM variants, FLAC) → 32-bit float PCM.
- **`DoviProfileConverter`** + **`HEVCNALParser`** + **`LibdoviWrapper`**: on-the-fly RPU rewrite for incompatible DV profiles (P7 MEL, P8.6 → P8.1) before VideoToolbox decode.
- **`SubtitleManager`** + **`FFmpegSubtitleDecoder`** + **`SubtitleOverlayView`**: text (SRT/ASS) and bitmap (PGS/DVB) subs. PGS uses `end_display_time = UInt32.max` as "until next cue" sentinel.

**Playback States** (PlayerProtocol): `.idle`, `.loading`, `.playing`, `.paused`, `.buffering`, `.ended`, `.failed`

#### Codec routing (RPlayer path)
- **Video H.264 / H.265 / DV P5 / DV P8.1** → VideoToolbox HW decode → `AVSampleBufferDisplayLayer`.
- **Video DV P7 / P8.6** → HEVCNALParser extracts RPU → DoviProfileConverter rewrites to P8.1 → VideoToolbox.
- **Audio AAC / AC3 / EAC3** → wrap as `CMSampleBuffer` (passthrough) → `AVSampleBufferAudioRenderer`.
- **Audio TrueHD / DTS / PCM / FLAC** → FFmpegAudioDecoder → 32-bit float PCM → `AVSampleBufferAudioRenderer`.
- **Subs SRT / ASS** → `SubtitleParser` → text overlay.
- **Subs PGS / DVB** → `FFmpegSubtitleDecoder` → bitmap overlay.

#### Routing policy (VOD)
1. `ContentRouter.plan(...)` returns `PlaybackPlan { primary, fallbacks }`. Route cases: `.avPlayerDirect`, `.localRemux`, `.hls`, plus the RPlayer DirectPlay path.
2. AVPlayer routes: `.avPlayerDirect` (natively-playable MP4 + native audio, no DV P7) and `.localRemux` (MKV / DV P7 / DTS / TrueHD, served via `LocalRemuxServer` over HLS on localhost). The `useApplePlayer` UserDefault biases the router toward AVPlayer paths.
3. RPlayer routes: DirectPlay when FFmpeg can demux locally and AVPlayer isn't preferred. HLS via `HLSPipeline` as fallback after a direct-play crash.
4. Hard blockers that start on `.hls` immediately: FFmpeg unavailable, no direct-play source/part key, forced HLS.

#### Live TV
Routes through RivuletPlayer (`MultiStreamViewModel`/`StreamSlotView` instantiate `RivuletPlayer()` per slot). HDHomeRun delivers a direct stream; DVB tuners require a Plex transcode URL with full client-profile parameters (see Plex Live TV section below).

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
| Player container (UIKit) | `Views/Player/PlayerContainerViewController.swift` |
| AVPlayer host | `Views/Player/NativePlayerViewController.swift` |
| Render surface (RPlayer) | `Views/Player/SampleBufferDisplayView.swift` |
| RPlayer entry point | `Services/Plex/Playback/RivuletPlayer.swift` |
| Pipeline (direct play) | `Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` |
| Pipeline (HLS fallback) | `Services/Plex/Playback/Pipeline/HLSPipeline.swift` |
| Renderer (display layer + audio) | `Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift` |
| Routing decisions | `Services/Plex/Playback/Pipeline/ContentRouter.swift` |
| Local HLS remux server | `Services/Plex/Playback/Remux/LocalRemuxServer.swift` |
| FFmpeg remux session | `Services/Plex/Playback/Remux/FFmpegRemuxSession.swift` |
| Demuxer | `Services/Plex/Playback/FFmpeg/FFmpegDemuxer.swift` |
| HTTP source for FFmpeg | `Services/Plex/Playback/FFmpeg/URLSessionAVIOSource.swift` |
| Audio decode (FFmpeg) | `Services/Plex/Playback/FFmpeg/FFmpegAudioDecoder.swift` |
| DV profile conversion | `Services/Plex/Playback/Dovi/DoviProfileConverter.swift` |
| Subtitle pipeline | `Services/Plex/Playback/Subtitles/SubtitleManager.swift` |
| Focus memory | `Services/Focus/FocusMemory.swift` |
| Plex API | `Services/Plex/PlexNetworkManager.swift` |
| Glass row styling | `Views/Components/GlassRowStyle.swift` |
| Settings components | `Views/Settings/SettingsComponents.swift` |
| Player canon docs | `Docs/RIVULET_PLAYER.md`, `Docs/PLAYER_INTERNALS.md` |
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

### RPlayer Stalls on High-Bitrate 4K Over HTTP
- FFmpeg's built-in HTTP protocol is throughput-limited on tvOS (~7 Mbps observed)
- For http(s) URLs, RPlayer uses `URLSessionAVIOSource` (parallel ranged GETs) instead of libavformat's HTTP. This is the only path that sustains 4K HEVC/DV bitrates.
- Read-loop throttle is tuned to `AVSampleBufferDisplayLayer`'s ~1 s forward acceptance window for 4K HEVC. Do not raise without re-measuring.

### RPlayer Initial Stutter or Sync Drift
- Preroll buffers ~450 ms for DV, ~200 ms otherwise before starting the synchronizer clock
- Seeks within 0.5 s of current position are deduplicated
- After seeking while paused, only one preview frame is decoded; on `resume()` a dead read loop is detected and restarted with fresh preroll
- A/V clock comes from `AVSampleBufferRenderSynchronizer`; on AirPlay it auto-compensates latency via preroll. Do NOT add explicit video delay.

## RivuletPlayer (RPlayer) on tvOS

Demux/decode in FFmpeg, render in Apple sample-buffer APIs. VideoToolbox handles H.264/HEVC/DV (P5/P8.1 native, P7/P8.6 via on-the-fly RPU rewrite). Apple-native audio codecs pass through; everything else is decoded in `FFmpegAudioDecoder` to PCM.

### Rendering pipeline

| Stage | Component | Notes |
|------|-----------|-------|
| HTTP source | `URLSessionAVIOSource` | Parallel ranged GETs (up to 8 × 4 MB segments). Replaces libavformat's HTTP protocol for http(s) URLs (required for 4K throughput on tvOS). |
| Demux | `FFmpegDemuxer` | libavformat. Single reused `AVPacket`. Rebuilds dvh1 format description for DV. |
| Video decode | VideoToolbox via `CMSampleBuffer` | P7/P8.6 RPU rewrite happens upstream of decode. |
| Audio decode | passthrough OR `FFmpegAudioDecoder` | AAC/AC3/EAC3 passthrough; TrueHD/DTS/PCM/FLAC decoded to 32-bit float PCM. |
| Render | `SampleBufferRenderer` | Owns `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`. |

### Throughput / timing constants worth knowing
- `AVSampleBufferDisplayLayer` has an undocumented ~1 s forward acceptance window for 4K HEVC on tvOS. The read-loop throttle (currently ~0.8 s) matches that window.
- Preroll: ~450 ms for DV, ~200 ms otherwise.
- AirPlay startup buffer: 1.0 s (prevents silent starts in pull-mode).

### HDR / DV
- Display switching uses `DisplayCriteriaManager` → `AVDisplayManager` (tvOS Match Content for frame rate + dynamic range).
- DV profiles natively supported: P5, P8.1.
- DV profiles converted on the fly: P7 (MEL), P8.6. `HEVCNALParser` extracts RPU NAL (type 62), `LibdoviWrapper` rewrites profile, parser injects back. See `Services/Plex/Playback/Dovi/`.

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
| `Demuxer: no streams found` / `unsupported codec` | Wrong container or codec we don't route (check `FFmpegDemuxer` stream discovery) |
| `HLS transcode session failed` | Incomplete transcode URL parameters |
| `HTTP 500 on /hubs` | Plex server issue (not client-side) |
| `NSURLErrorDomain -999 cancelled` | User navigated away, request timeout |
| Direct play stalls at 4K but works at 1080p | FFmpeg HTTP protocol bottleneck; verify `URLSessionAVIOSource` is in use for http(s) |
| RPlayer init/runtime fatal → auto HLS fallback | Expected: ContentRouter falls back from DirectPlay to HLS once at current playback time |
