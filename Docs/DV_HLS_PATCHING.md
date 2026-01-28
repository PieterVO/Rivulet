# Dolby Vision HLS Playback - Implementation Log

## Problem

Plex server remuxes MKV+DV (Dolby Vision Profile 8) content to HLS, but:
- The HLS **master playlist** declares `CODECS="dvh1.08.06,ec-3"` (correct for DV)
- The fMP4 **init segment** contains `hvc1` codec tag (incorrect - should be `dvh1`)
- AVPlayer on tvOS **rejects `dvh1`** in the HLS master playlist CODECS string before downloading any content (error -11848)

This means AVPlayer can't play DV content from Plex MKV sources via HLS.

## Test Content

- **File**: Interstellar (MKV, Dolby Vision Profile 8, BL compat ID 1)
- **Video**: HEVC 3840x2160 23.976fps, ~52 Mbps
- **Audio**: EC-3 (Dolby Digital Plus)
- **Plex behavior**: HLS remux with `directPlay=1`, `directStreamAudio=1`, `useDoviCodecs=1`

## Approaches Tried

### 1. Resource Loader: Patch both master + init segment
- **Master**: `dvh1.08.06` → `hvc1.2.4.L153.B0`
- **Init**: `hvc1` → `dvh1`
- **I-frame stream**: Removed
- **Result**: Error **-12881** (`kCMFormatDescriptionError_InvalidFormatDescription`)
- **Why**: Mismatch - master says `hvc1` but init says `dvh1`. AVPlayer validates they match.

### 2. Resource Loader: Keep dvh1 in master, patch init only
- **Master**: `dvh1.08.06` (unchanged)
- **Init**: `hvc1` → `dvh1`
- **I-frame stream**: Removed
- **Result**: Error **-11848** (`AVErrorFileFormatNotRecognized` / "Cannot Open")
- **Why**: AVPlayer rejects `dvh1` codec declaration in master playlist before downloading anything.

### 3. Resource Loader: Patch master only, leave init as hvc1
- **Master**: `dvh1.08.06` → `hvc1.2.4.L153.B0`
- **Init**: `hvc1` (unchanged - matches master)
- **I-frame stream**: Removed
- **Result**: Error **-12889** ("No response for map in 10s")
- **Why**: The `AVAssetResourceLoaderDelegate` proxied ALL requests (playlists, init segment, media segments) through a custom URL scheme (`patched-hls-http://`). The init segment (`header`) request to Plex via `URLSession.shared` never completed within AVPlayer's 10-second timeout. Likely a connection pooling or threading issue with the resource loader proxy.

### 4. No resource loader, remove `useDoviCodecs=1`
- **Master**: Plex outputs `hvc1` natively (no `dvh1` without `useDoviCodecs=1`)
- **Init**: `hvc1` (unchanged)
- **No resource loader** - AVPlayer loads directly from Plex
- **Result**: **Video renders one frame, then buffers forever**
- **Why**: Without `useDoviCodecs=1`, Plex changes its transcoding behavior. Audio became AAC Stereo instead of EC-3 (confirming Plex was transcoding, not remuxing). Segments exceeded declared bandwidth (-12318 warning). Plex couldn't serve segments fast enough for real-time playback.

### 5. Temp file approach v1 (absolute URLs with inherited query params)
- **`useDoviCodecs=1` restored** in Plex URL (proper DV remuxing)
- **Master playlist**: Fetched via URLSession, patched (`dvh1` → `hvc1`), variant URLs made absolute, written to temp file
- **Init**: `hvc1` (unchanged - matches patched master)
- **No resource loader** - AVPlayer loads temp file for master, then fetches variant/init/segments directly from Plex
- **Result**: Error **-12865** (segment/variant not found)
- **Why it failed**: Two bugs in URL construction:
  1. `URL.appendingPathComponent()` preserved ALL query params from the master URL onto the variant URL. Plex got confused by receiving `X-Plex-Client-Profile-Name=...&useDoviCodecs=1&...` on the variant endpoint.
  2. `AVURLAssetHTTPHeaderFieldsKey` doesn't apply to sub-requests when the asset is loaded from a local `file://` URL. AVPlayer couldn't authenticate with Plex for variant/segment requests.

### 6. Temp file approach v2 (clean URLs + token in query)
- **`useDoviCodecs=1` restored** in Plex URL (proper DV remuxing)
- **Master playlist**: Fetched via URLSession, patched (`dvh1` → `hvc1`), variant URLs made absolute with ONLY `X-Plex-Token` query param, written to temp file
- **Init**: `hvc1` (unchanged - matches patched master)
- **No resource loader** - AVPlayer loads temp file for master, then fetches variant/init/segments directly from Plex
- **URL construction**: String concatenation (not `URL.appendingPathComponent`) to avoid query param inheritance
- **Auth**: `X-Plex-Token` extracted from headers and appended as query param on variant URL
- **Result**: Error **-12865** again (same as v1)
- **Why it failed**: The clean URL and auth fix didn't help. AVPlayer likely can't (or won't) load remote HLS variant playlists when the master is loaded from a local `file://` URL. This may be a fundamental AVPlayer limitation - HLS masters from file:// can't reference http:// variants.

## Status Summary

| # | Approach | Error | Root Cause |
|---|---------|-------|------------|
| 1 | Resource loader: patch both | -12881 | Master/init codec mismatch |
| 2 | Resource loader: keep dvh1 master | -11848 | AVPlayer rejects dvh1 |
| 3 | Resource loader: patch master only | -12889 | Proxy timeout on init segment |
| 4 | No useDoviCodecs, no proxy | Stalls | Plex transcodes (not remux) |
| 5 | Temp file v1 (bad URLs) | -12865 | Query params leaked into variant URL |
| 6 | Temp file v2 (clean URLs) | -12865 | file:// master can't reference http:// variants |
| 7 | Proxy: master hvc1, init hvc1 | **Plays as HDR10** | hvc1 signaling = no DV pipeline activation |
| 7b | Proxy: keep dvh1 in master | -11848 | AVPlayer still rejects dvh1 even via real HTTP |
| 7c | Proxy: master hvc1, init patched dvh1 | **Plays as HDR10** | Init dvh1 tolerated (no -12881!) but DV not activated |
| **8** | **DVSampleBufferPlayer** | **✅ Full DV** | **Bypass AVPlayer, feed dvh1-tagged samples to display layer** |

**Current solution**: Approach #8 (DVSampleBufferPlayer) successfully plays Dolby Vision content with full DV pipeline activation. TV enters Dolby Vision display mode.

**The AVPlayer problem** (for historical reference): AVPlayer rejects `dvh1` in HLS CODECS (-11848) regardless of transport (custom scheme, file://, real HTTP). When `hvc1` is used instead, AVPlayer never activates the DV pipeline. Approach #8 bypasses AVPlayer entirely.

### 7. Local HTTP reverse proxy (master hvc1, init hvc1)
- **Proxy**: NWListener on `127.0.0.1:PORT` (random available port)
- **Master playlist**: Proxy patches `dvh1.xx.xx` → `hvc1.2.4.L153.B0`, removes I-FRAME streams
- **Init**: `hvc1` (unchanged - matches patched master)
- **Result**: **Video plays smoothly as HDR10, not Dolby Vision**

### 7b. Local HTTP reverse proxy (keep dvh1 in master)
- **Master playlist**: Proxy keeps `dvh1.08.06` unchanged, only removes I-FRAME
- **Init**: `hvc1` (unchanged from Plex)
- **Result**: **-11848 "Cannot Open"** - AVPlayer rejects dvh1 even via real HTTP on localhost
- **Conclusion**: -11848 is fundamental to AVPlayer's HLS parser, not transport-dependent

### 7c. Local HTTP reverse proxy (master hvc1, init patched to dvh1)
- **Master playlist**: Proxy patches `dvh1` → `hvc1.2.4.L153.B0`
- **Init**: Proxy patches `hvc1` → `dvh1` in fMP4 stsd box (1 occurrence, 1434 bytes)
- **Result**: **Video plays smoothly as HDR10, not Dolby Vision**
- **Notable**: No -12881 error! Unlike approach #1 (resource loader), the master/init codec mismatch was tolerated via real HTTP proxy. AVPlayer accepted `hvc1` in master + `dvh1` in init without complaint.
- **But**: DV pipeline still not activated. AVPlayer uses the master CODECS string to select the decoder, not the init segment codec tag.

### Observations from real Apple TV 4K (approaches 7/7c):
- Video rendered at 1920x1080 (correct aspect ratio 1.78)
- Audio: AAC Stereo (not EC-3 - Plex transcoding audio despite useDoviCodecs=1)
- Warning -12318 "Segment exceeds specified bandwidth" (non-fatal)
- Display mode: HDR (not Dolby Vision) - TV did NOT activate DV mode
- Playback was smooth with no stalling or buffering issues

## Remaining Fallback Options

### B. In-app remuxing
Use FFmpeg/libav (compiled for tvOS) to remux MKV→MP4 on-the-fly, fixing codec tags. Very complex, large dependency, but gives full control.

### C. Accept HDR10 fallback
Use approach #4 but fix the Plex transcoding issue (adjust params so Plex remuxes even without `useDoviCodecs=1`). Video would play as HDR10/PQ, not full Dolby Vision. DV RPU metadata in bitstream may still be recognized by TV hardware.

### D. Server-side fix
Wait for Plex to fix the init segment codec tag bug (hvc1 → dvh1). This would make standard AVPlayer DV playback work without any client-side hacks.

## Key Findings

1. **AVPlayer rejects `dvh1` in HLS CODECS**: Confirmed across multiple tests. Error -11848 happens immediately, before any content is downloaded.

2. **AVPlayer validates master ↔ init segment codec match (resource loader only)**: Through `AVAssetResourceLoaderDelegate`, master `hvc1` + init `dvh1` = error -12881. But through a real HTTP proxy, the same mismatch is **tolerated** (no error). This suggests -12881 is stricter in the resource loader path.

3. **`useDoviCodecs=1` controls Plex behavior**: Without it, Plex transcodes audio (EC-3 → AAC) and may transcode video, causing stalling. With it, Plex does proper remux.

4. **Resource loader proxy causes timeouts**: Proxying all HLS requests through `AVAssetResourceLoaderDelegate` with a custom URL scheme causes the init segment request to time out. Direct AVPlayer ↔ Plex connections work fine.

5. **Plex's init segment has `hvc1` (not `dvh1`)**: This is a Plex bug - the fMP4 init segment should have `dvh1` for DV content. The master playlist correctly declares `dvh1.08.06`.

6. **`AVURLAssetHTTPHeaderFieldsKey` doesn't propagate from local files**: When AVPlayer loads an HLS master from a `file://` URL, custom HTTP headers set via `AVURLAssetHTTPHeaderFieldsKey` are NOT sent on subsequent remote HTTP requests. Auth must be embedded in the URL as query params.

7. **`URL.appendingPathComponent()` inherits query params**: When constructing absolute URLs from a base URL that has query params, `appendingPathComponent` preserves them. Must use string concatenation for clean URLs.

8. **Local HTTP reverse proxy works for playback**: NWListener-based proxy on localhost successfully intercepts and patches the master playlist. AVPlayer loads from `http://127.0.0.1:PORT/...` and fetches all sub-resources through the proxy. No timeouts, no auth issues, smooth playback.

9. **`hvc1` signaling does NOT activate DV pipeline**: Even though the DV RPU NAL units are present in the HEVC bitstream, AVPlayer does not activate Dolby Vision display mode when the codec is declared as `hvc1`. The Apple TV plays the content as HDR10 (PQ) instead. This confirms that DV activation requires `dvh1` codec signaling at the container/manifest level - bitstream-level RPU alone is not sufficient.

10. **Audio still transcoded despite `useDoviCodecs=1`**: Audio was AAC Stereo instead of EC-3. This suggests Plex is still transcoding audio even with `useDoviCodecs=1` and `directStreamAudio=1`. The video appears to be direct-streamed (52 Mbps bandwidth) but audio is being converted.

11. **-11848 is transport-independent**: AVPlayer rejects `dvh1` in HLS CODECS string whether loaded via custom URL scheme (approach #2), file:// URL, or real HTTP on localhost (approach #7b). This is a fundamental AVPlayer HLS parser limitation.

12. **Master/init codec mismatch behaves differently via HTTP vs resource loader**: Through a real HTTP proxy, master=`hvc1` + init=`dvh1` plays fine (no -12881). Through `AVAssetResourceLoaderDelegate`, the same mismatch causes -12881. However, even when tolerated, `dvh1` in the init segment alone does NOT activate the DV pipeline - AVPlayer uses the master CODECS string to select the decoder.

## Architecture

### Current approach (v7): Local HTTP reverse proxy

```
┌─────────────┐               ┌──────────────────┐               ┌──────────┐
│ Plex Server  │◀────────────▶│ DVHLSProxyServer  │◀────────────▶│ AVPlayer │
│              │  ALL requests │ (localhost:PORT)   │  ALL requests│          │
│              │  forwarded    │ patches master     │  real HTTP   │          │
└──────────────┘  with auth   │ only, rest passes  │              └──────────┘
                              │ through unmodified  │
                              └──────────────────┘
```

AVPlayer loads from `http://127.0.0.1:PORT/...` (real HTTP). The proxy patches only the master
playlist (dvh1→hvc1, remove I-FRAME). All variant/init/segment requests pass through unmodified.
Auth headers forwarded by proxy on every upstream request.

### Previous approach (v5/6): Temp file patching

```
┌─────────────┐  fetch master   ┌──────────────┐  write patched   ┌───────────┐
│ Plex Server  │───────────────▶│ AVPlayerWrap  │────────────────▶│ Temp File │
│              │                │ (patches dvh1 │                 │ master.m3u8│
│              │                │  → hvc1)      │                 └─────┬─────┘
│              │                └───────────────┘                       │
│              │                                                       │ load
│              │◀──────────────── AVPlayer ◀───────────────────────────┘
│              │  direct fetch   (variant, init, segments)
└──────────────┘
```

Failed: file:// master can't reference http:// variants (-12865).

### Previous approach (v1-3): Resource loader proxy

```
┌─────────────┐               ┌──────────────────────┐               ┌──────────┐
│ Plex Server  │◀────────────▶│ HLSCodecPatchingRL   │◀────────────▶│ AVPlayer │
│              │  ALL requests │ (custom URL scheme)   │  ALL requests│          │
└──────────────┘  proxied     └──────────────────────┘  intercepted  └──────────┘
```

ALL requests went through the resource loader, causing timeout issues (-12889).

## Files

| File | Purpose |
|------|---------|
| `Services/Playback/DVSampleBufferPlayer.swift` | **Current**: Main DV player - fetching, demuxing, sample buffer pipeline |
| `Services/Playback/HLSSegmentFetcher.swift` | **Current**: Parses HLS playlists, downloads segments |
| `Services/Playback/FMP4Demuxer.swift` | **Current**: Demuxes fMP4, creates dvh1-tagged CMSampleBuffers |
| `Views/Player/DVSampleBufferView.swift` | **Current**: SwiftUI wrapper for AVSampleBufferDisplayLayer |
| `Services/Playback/DVHLSProxyServer.swift` | Legacy: Local HTTP reverse proxy (approach #7) |
| `Services/Playback/AVPlayerWrapper.swift` | Used for non-DV content via AVPlayer |
| `Services/Playback/HLSCodecPatchingResourceLoader.swift` | Legacy: Resource loader approach (approaches #1-3) |
| `Services/Plex/PlexNetworkManager.swift` | `buildHLSDirectPlayURL()`, `startTranscodeDecision()`, `stopTranscodeSession()` |
| `Views/Player/UniversalPlayerViewModel.swift` | Routes to DVSampleBufferPlayer vs AVPlayer based on content |

## Open Questions

- ~~Will the local HTTP proxy approach successfully play on real Apple TV 4K?~~ **YES** - plays smoothly
- ~~With `hvc1` codec signaling, will the Apple TV hardware DV pipeline detect RPU NAL units and activate Dolby Vision display mode?~~ **NO** - plays as HDR10 only
- ~~Does real HTTP avoid -11848 for dvh1?~~ **NO** - -11848 is transport-independent (tested #7b)
- ~~Does patching init to dvh1 (while master=hvc1) trigger DV?~~ **NO** - tolerated but DV not activated (tested #7c)
- ~~Is HDR10 (PQ) display acceptable as a fallback for DV Profile 8 content?~~ **NO** - we found a better way
- ~~Is there ANY way to get AVPlayer to activate DV via HLS?~~ **YES** - bypass AVPlayer entirely with AVSampleBufferDisplayLayer (approach #8)
- ~~Could we use `AVAssetWriter` to remux the fMP4 segments into a proper DV MP4 container that AVPlayer accepts for DV?~~ Not needed - direct sample buffer feeding works
- ~~Is there a private/undocumented AVPlayer API or configuration that enables DV HLS playback?~~ Not needed

---

## Approach #8: DVSampleBufferPlayer (SUCCESS - Full Dolby Vision)

### Summary

Bypass AVPlayer's HLS parser entirely. Manually fetch HLS playlists, download fMP4 segments, demux them, patch the codec tag to `dvh1`, and feed CMSampleBuffers directly to `AVSampleBufferDisplayLayer`. This activates the full Dolby Vision pipeline.

### Why It Works

AVPlayer's HLS parser rejects `dvh1` in the CODECS string (-11848). But `AVSampleBufferDisplayLayer` doesn't care about HLS manifests - it only sees the `CMFormatDescription` attached to each sample buffer. By patching the format description to use `dvh1` (FourCC `0x64766831`), VideoToolbox activates the DV decoder and the TV enters Dolby Vision display mode.

### Architecture

```
┌─────────────┐   playlists    ┌──────────────────┐   CMSampleBuffer   ┌─────────────────────────┐
│ Plex Server │───────────────▶│ HLSSegmentFetcher │                    │ AVSampleBufferDisplayLayer│
│             │   + segments   │ (parses m3u8)     │                    │ (renders video)          │
│             │                └────────┬─────────┘                    └────────────▲────────────┘
│             │                         │                                           │
│             │                         ▼                                           │
│             │                ┌──────────────────┐   dvh1-tagged samples          │
│             │                │   FMP4Demuxer    │─────────────────────────────────┘
│             │                │ (extracts NALUs, │
│             │                │  patches codec)  │
│             │                └──────────────────┘
└─────────────┘
                               ┌──────────────────┐
                               │ AVSampleBuffer   │◀─── Audio samples
                               │ AudioRenderer    │
                               └────────┬─────────┘
                                        │
                                        ▼
                               ┌──────────────────┐
                               │ AVSampleBuffer   │◀─── Coordinates A/V timing
                               │ RenderSynchronizer│
                               └──────────────────┘
```

### Components

| File | Purpose |
|------|---------|
| `DVSampleBufferPlayer.swift` | Main player: coordinates fetching, demuxing, enqueuing, time updates |
| `HLSSegmentFetcher.swift` | Parses master + variant playlists, downloads init + media segments |
| `FMP4Demuxer.swift` | Parses fMP4 boxes, extracts NALUs, creates dvh1-tagged CMSampleBuffers |
| `DVSampleBufferView.swift` | SwiftUI wrapper hosting the AVSampleBufferDisplayLayer |
| `UniversalPlayerViewModel.swift` | Decides AVPlayer vs DVSampleBuffer based on `isDolbyVision` flag |

### Producer/Consumer Pipeline

The player uses a bounded buffer pattern to decouple downloading from decoding:

```
Download Task (Producer)              Segment Buffer (3 slots)           Enqueue Task (Consumer)
        │                                     │                                   │
        ├── fetch segment 0 ──────────────────▶ [seg0] ◀──────────────────────────┤
        ├── fetch segment 1 ──────────────────▶ [seg1]                            │
        ├── fetch segment 2 ──────────────────▶ [seg2]                            │
        │   (waits - buffer full)              │                                  │
        │                                      │ ◀── take seg0 ───────────────────┤
        ├── fetch segment 3 ──────────────────▶ [seg3]                            │
        │                                      │ ◀── take seg1 ───────────────────┤
        ...                                    ...                               ...
```

- **Producer** downloads segments with retry (3 attempts, exponential backoff)
- **Buffer** holds up to 3 segments (keeps download ahead of playback)
- **Consumer** demuxes and enqueues samples to display layer + audio renderer

### Plex Session Management

Plex's HLS transcode sessions can be finicky:

1. **Initial load**: Request `start.m3u8` directly (no `/decision` call)
2. **Init segment retry**: If init segment times out, retry up to 3 times with backoff (Plex may still be muxing)
3. **Full retry path** (on persistent failure):
   - Stop old transcode session via `/video/:/transcode/universal/stop`
   - Wait 3 seconds for cleanup
   - Send `/decision` ping to kick-start new session
   - Build fresh session URL with new `session` UUID
   - Retry load

### Seeking

1. Cancel download + enqueue tasks
2. Flush display layer and audio renderer
3. Find target segment via binary search on cumulative start times
4. Set synchronizer to target time (paused)
5. Restart feeding loop
6. After first video sample enqueues, restore playback rate

**Seek while paused**: The feeding loop starts regardless of play state. When paused, it enqueues one frame (so the seeked position displays) then stops.

### Initial Sync

The user's requested start time (e.g., resume at 38:20) may not align with the first keyframe in that segment (which could be at 38:29). To avoid a gap where the synchronizer runs but no frames display:

1. Set `needsInitialSync = true` on load with start time
2. Don't start synchronizer rate until first video sample enqueues
3. When first video sample arrives, sync to its actual PTS

---

## Playback Jitter Diagnostics

### Purpose

Detect micro-stutters that are hard to perceive visually but affect playback quality. The `PlaybackJitterStats` struct tracks multiple metrics to identify the source of any smoothness issues.

### Metrics Tracked

| Metric | What It Measures | Warning Threshold |
|--------|------------------|-------------------|
| **PTS gaps** | Time between consecutive video frame PTS values | >24× expected frame duration (~1 second) |
| **Buffer underruns** | Enqueue loop found download buffer empty | Any occurrence |
| **Enqueue stalls** | Display layer wasn't ready for more data | >100ms |
| **Sync drift** | Synchronizer clock vs wall clock deviation | >5% speed difference |

### FPS Detection

B-frame decode ordering makes consecutive PTS gaps unreliable for FPS detection. Instead:

1. Track `minPTS` and `maxPTS` across all frames
2. After 100 frames: `expectedFrameDuration = (maxPTS - minPTS) / 99`
3. Detected FPS = `1.0 / expectedFrameDuration`

This gives accurate results (23.5fps for 23.976fps content) regardless of B-frame patterns.

### Synchronizer Drift

Measures whether the `AVSampleBufferRenderSynchronizer` clock advances at the expected rate:

```
driftRate = (synchronizer time advance) / (wall time advance × playback rate)
```

- 100% = perfect sync
- <100% = sync running slow (potential stutters)
- >100% = sync running fast (unlikely)

High standard deviation indicates inconsistent clock advancement.

### Log Output

Every 30 seconds during playback:
```
📊 [Jitter] ✅ 2847 frames | 23.5fps | gaps: avg=42.1ms σ=18.32ms max=333.3ms | drops: 0 | underruns: 1 (1250.0ms) | stalls: 28 (max=1050.0ms total=29400.0ms) | sync: 100.0%±0.2% alerts:0
```

Immediate alerts for significant issues:
```
📊 [Jitter] ⚠️ Large PTS gap: 1200ms at frame 1523 (expected ~42ms)
📊 [Jitter] ⏱️ Enqueue stall: 150ms (frame 1842)
📊 [Jitter] ⚠️ Sync drift: 94.5% (wall: 250ms, sync: 236ms)
```

### Interpreting Results

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| High `drops` count | PTS gaps >1 second | Network issues, server load |
| High `underruns` | Download can't keep up | Increase buffer capacity, check bandwidth |
| High `stalls` (>100ms) | Display layer backpressure | Content bitrate too high, decoder overloaded |
| Sync drift <95% | Synchronizer falling behind | Investigate sample timestamps |
| High sync σ (>2%) | Inconsistent clock | Display layer timing issues |

### Clean Diagnostics But Still Stuttery?

If diagnostics show clean stats but playback still feels stuttery on fast motion:

1. **TV processing**: Some TVs add motion interpolation that can look off
2. **Frame rate mismatch**: 23.976fps content on 60Hz display without proper cadence
3. **Display layer presentation**: AVSampleBufferDisplayLayer may have its own timing quirks
4. **Bitrate spikes**: Individual frames may exceed decode capacity without triggering stalls

---

## Troubleshooting

### Init Segment Timeout

```
🎬 [HLSFetcher] ❌ Init segment fetch failed after 4 attempts
```

**Cause**: Plex server hasn't finished muxing the init segment yet.

**Fix**: The retry logic (3 attempts, 3s/6s/9s delays) usually handles this. If persistent:
- Check Plex server load
- Try stopping other transcodes
- Restart Plex Media Server

### Segment Download Failures

```
🎬 [DVPlayer] ⚠️ Segment 45 download failed (attempt 2/4): HTTP 500
```

**Cause**: Plex server error during transcode.

**Fix**: Retry logic handles transient errors. For persistent 500s:
- Check Plex server logs
- Reduce concurrent streams
- File may have problematic sections

### Display Layer Error

```
🎬 [DVPlayer] ⚠️ Display layer error: The operation could not be completed
```

**Cause**: VideoToolbox decoder failure.

**Fix**: Usually recoverable on seek. May indicate:
- Corrupted segment data
- Unsupported codec parameters
- Memory pressure

### Audio Not Playing

Check audio session configuration:
```swift
let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(.playback, mode: .moviePlayback)
try audioSession.setActive(true)
```

Also verify:
- `audioRenderer.isMuted` is false
- `audioRenderer.volume` is 1.0
- Content has audio track (`demuxer.audioTrackID != nil`)

### Playback Ends Early

If playback ends before content finishes:
1. Check `currentSegmentIndex >= segmentCount` condition
2. Verify `fetcher.segments.count` matches expected
3. Look for download errors that terminated the pipeline

---

## Key Learnings from DVSampleBufferPlayer

1. **AVSampleBufferDisplayLayer activates DV**: Unlike AVPlayer's HLS parser, the display layer respects the `dvh1` codec tag in CMFormatDescription.

2. **FourCC patching is sufficient**: Changing `hvc1` (0x68766331) to `dvh1` (0x64766831) in the format description triggers DV mode. No need to modify the actual HEVC bitstream.

3. **Producer/consumer decouples network from decode**: Bounded buffer absorbs network jitter, keeps playback smooth.

4. **Sync to first frame PTS**: Don't start the synchronizer at the requested time - wait for the actual first keyframe's PTS to avoid gaps.

5. **Retry with fresh Plex session**: Some failures require stopping the old transcode session and starting fresh with a new UUID.

6. **B-frames make PTS gaps unreliable**: Use min/max PTS range for FPS detection, not consecutive gaps.
