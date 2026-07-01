# Player Engine Decision: Aether 4.8.0 vs RPlayer

Date: 2026-07-01

## Goal

Rivulet's player goal is tvOS-specific:

- Fast and efficient playback.
- Play nearly any user media file without Plex/server transcoding.
- Own a polished custom tvOS playback UI inspired by `AVPlayerViewController`, but not dependent on it.
- Support one long-term player stack if possible.

The previous strategic reason to keep Aether was access to `AVPlayerViewController`. That is no longer the deciding factor. The new decision is engine quality, format breadth, performance, and maintenance cost.

## Current Recommendation

Use one custom Rivulet UI, but make Aether 4.8.0 the leading candidate for the long-term single playback engine.

Keep RPlayer temporarily as a performance benchmark and fallback while validating Aether 4.8.0 against Rivulet's real media library. If Aether passes the validation matrix, remove RPlayer and avoid maintaining two custom playback engines.

Blunt version: after dropping the `AVPlayerViewController` requirement, I would not invest heavily in making RPlayer a universal "plays everything" engine unless Aether 4.8.0 fails Rivulet's real-world performance and stutter tests badly.

## Important Local State

This workspace does not appear to be pinned to Aether 4.8.0 yet.

Local package state:

- `Rivulet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Rivulet.xcodeproj/project.pbxproj`
- Current package URL: `https://github.com/l984-451/AetherEngine`
- Current pinned revision: `91b8f68b0c8036097d9a96395e263d6c40d55a97`

Upstream Aether 4.8.0 is published at:

- `https://github.com/superuser404notfound/AetherEngine`
- Tag: `4.8.0`
- Peeled tag commit observed: `ab93219a6b7c24394a7d802e6819756f12963496`

Validation should start by confirming whether Rivulet intends to depend directly on upstream Aether 4.8.0 or on a Rivulet-owned fork of that tag.

## Aether 4.8.0 Findings

Sources checked:

- [Aether 4.8.0 README](https://raw.githubusercontent.com/superuser404notfound/AetherEngine/4.8.0/README.md)
- [Aether 4.8.0 CHANGELOG](https://raw.githubusercontent.com/superuser404notfound/AetherEngine/4.8.0/CHANGELOG.md)
- [Aether 4.8.0 architecture docs](https://raw.githubusercontent.com/superuser404notfound/AetherEngine/4.8.0/docs/architecture.md)
- [Aether 4.8.0 formats docs](https://raw.githubusercontent.com/superuser404notfound/AetherEngine/4.8.0/docs/formats.md)

Aether 4.8.0 is no longer best understood as the `AVPlayerViewController` option. Its README describes it as an engine where the host app ships the UI. It exposes player surfaces and state, but does not provide opinionated controls.

Relevant Aether engine capabilities:

- Three playback pipelines selected at load:
  - Audio-only path.
  - Native AVPlayer path using FFmpeg demux into local HLS/fMP4.
  - Software decode path using FFmpeg/dav1d into `AVSampleBufferDisplayLayer` and audio renderers.
- Containers: MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV.
- Disc playback: DVD-Video and Blu-ray ISO with title/chapter selection.
- Hardware video: H.264, HEVC, HEVC Main10, hardware AV1 where available.
- Software video: AV1 where no hardware support exists, VP9, VP8, MPEG-4 Part 2, MPEG-2, VC-1.
- Deinterlace support via bwdif.
- HDR/DV:
  - HDR10.
  - HDR10+ ST2094-40.
  - HLG.
  - Dolby Vision P5.
  - Dolby Vision P7 converted to single-layer P8.1 using libdovi, with enhancement layer dropped.
  - Dolby Vision P8.1/P8.4.
  - AV1 P10.x handling.
- Audio:
  - Stream-copy AAC, AC3, EAC3, FLAC, ALAC.
  - Stream-copy EAC3+JOC Atmos.
  - Bridge TrueHD, DTS, DTS-HD MA, MP3, Opus, Vorbis, PCM to EAC3 5.1 or FLAC.
- Subtitles:
  - SRT, ASS, SSA, VTT, mov_text.
  - PGS, DVB, DVD bitmap subtitles.
  - CEA-608.
  - Sidecars.
  - Raw ASS/fonts.
  - Optional native legible text tracks.
  - Secondary subtitle track support.
- Live/DVR and custom IOReader support.
- Frame extraction for thumbnails/snapshots.
- Unified `playbackPhase` state surface.

Recent 4.8.0 fixes that matter for Rivulet:

- Open-GOP/B-frame VOD segments decode cleanly after fresh decode.
- Bunched keyframe index under one segment is rejected rather than producing AVPlayer zero-track failure.
- Software-path seek avoids black flash.
- Software-decode audio crackle fix.
- Remote PGS subtitle startup stall fix.
- Correct HDR/DV labels in stats.

Known Aether limitations:

- TrueHD-MAT Atmos object metadata is not preserved.
- Some surround compatibility modes cap 7.1 to 5.1 unless FLAC lossless is used.
- AV1 on Apple TV is software decoded and CPU-heavy.
- tvOS 26 custom transport should avoid manual `MPNowPlayingInfoCenter` races and use `MPNowPlayingSession` against the engine's current AVPlayer where applicable.

## RPlayer Findings

RPlayer remains valuable because it is tailored to Rivulet and likely faster for the subset it handles well.

Local references:

- `Rivulet/Services/Plex/Playback/RivuletPlayer.swift`
- `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`
- `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`
- `Rivulet/Services/Plex/Playback/Pipeline/ContentRouter.swift`
- `Rivulet/Services/Plex/Playback/PlayerPreference.swift`

Current RPlayer strengths:

- Purpose-built for Rivulet and tvOS.
- Avoids Aether's local HLS/fMP4 loopback for its direct path.
- FFmpeg demuxes MKV/MP4-like sources and feeds compressed samples into the renderer.
- Uses VideoToolbox and `AVSampleBufferDisplayLayer`.
- Handles HEVC/H.264-oriented direct playback well.
- Has Rivulet-owned tuning for frame pacing, queue sizing, buffering, and renderer lookahead.
- Has recently been improved to derive timing/backpressure from media frame rate rather than hardcoding one-size values.

Current RPlayer limitations:

- It is not yet a universal no-server-transcode engine.
- Current routing still sends unsupported codecs to server-side video transcode. The router explicitly treats MPEG-2, VC-1, VP9, AV1, and MPEG-4 Part 2 as unsupported by the local RPlayer path.
- Matching Aether's breadth would require implementing or integrating:
  - Software decode path for AV1/VP9/VP8/MPEG-2/VC-1/MPEG-4 Part 2.
  - Deinterlacing.
  - Broader audio bridge behavior.
  - More subtitle formats and bitmap subtitle handling.
  - Disc title/chapter support.
  - More complete live/DVR behavior.
  - More edge-case HDR/DV handling.

The hard part is no longer the UI. The hard part is making the engine broad, correct, and stable across strange real-world media.

## Decision Logic

If the goal is the fastest possible player for the subset RPlayer already handles, RPlayer is still compelling.

If the goal is one player that handles nearly any file without server transcoding, Aether 4.8.0 is currently closer.

Owning the UI removes the main emotional and product objection to Aether. Rivulet can still provide a first-class custom tvOS experience while delegating the hardest playback breadth to Aether.

The remaining risk with Aether is dependency risk:

- Upstream changes can affect Rivulet.
- Performance may be worse than RPlayer for common HEVC/H.264 paths.
- Rivulet may need a fork for tvOS-specific tuning.
- Aether is LGPL-3.0 with an Apple Store/DRM exception, so license obligations need to be respected if modifying/distributing the engine.

The remaining risk with RPlayer is engineering scope:

- RPlayer can be excellent, but making it universal means building many subsystems Aether already has.
- Maintaining RPlayer and Aether together long term is high cost.
- User-visible correctness failures will likely come from rare media, subtitles, audio formats, HDR/DV metadata, and seek/buffer edge cases.

## Suggested Migration Plan

1. Pin Aether correctly.
   - Decide whether to depend on upstream `superuser404notfound/AetherEngine` from `4.8.0` or a Rivulet fork of that tag.
   - Update SwiftPM package URL/revision accordingly.

2. Treat Aether as an engine, not as an AVKit wrapper.
   - Remove assumptions in comments and architecture that Aether means `AVPlayerViewController`.
   - Replace the existing Aether `AVPlayerViewController` host with Rivulet's custom playback UI.

3. Define a neutral Rivulet player UI adapter.
   - Playback commands: play, pause, seek, skip, rate.
   - State: playing, paused, loading, stalled, seeking, ended, failed.
   - Timeline: current time, duration, buffered position.
   - Tracks: audio, subtitles, chapters/titles where available.
   - Presentation: HDR/DV labels, audio format labels, subtitle cues.

4. Run Aether 4.8.0 against a real media matrix before deleting RPlayer.
   - HEVC SDR.
   - HEVC HDR10.
   - HLG.
   - HDR10+.
   - Dolby Vision P5.
   - Dolby Vision P7.
   - Dolby Vision P8.1/P8.4.
   - EAC3+JOC Atmos.
   - TrueHD.
   - DTS/DTS-HD MA.
   - FLAC/ALAC.
   - PGS/DVB bitmap subtitles.
   - SRT/ASS/SSA/VTT.
   - CEA-608.
   - AV1.
   - VP9.
   - MPEG-2.
   - VC-1.
   - MPEG-4 Part 2.
   - Live TV/DVR.
   - High-bitrate remote MKV.
   - Long seek/rebuffer scenarios.

5. Compare against RPlayer on the same files.
   - Startup time.
   - Seek latency.
   - Stutter/frame pacing, especially HDR and Dolby Vision.
   - CPU/GPU load.
   - Memory growth.
   - Audio sync.
   - Subtitle sync.
   - Network buffering behavior.

6. Choose final engine.
   - If Aether passes, remove RPlayer.
   - If Aether has isolated issues, patch/fork Aether.
   - If Aether fails the core Rivulet experience badly, keep RPlayer and use Aether as a reference implementation for the missing subsystems.

## Validation Questions For Another Agent

- Does upstream Aether 4.8.0 compile cleanly in this Rivulet workspace?
- What API changes are required from the current local Aether adapter?
- Does Aether 4.8.0 expose enough state for the planned custom Rivulet UI without depending on `AVPlayerViewController`?
- Does Aether's software path work correctly on tvOS for the target codecs?
- Does Aether stutter less, equal, or more than RPlayer on HDR and Dolby Vision content?
- Does Aether preserve the system-level behavior Rivulet cares about: display criteria, match frame rate/range, Atmos where possible, Now Playing, remote control, and audio routing?
- Are there licensing or App Store distribution concerns with Rivulet's intended use of a modified Aether fork?

## Bottom Line

The custom UI pivot makes Aether more attractive, not less.

RPlayer is probably the better specialized engine for the files it already plays well. Aether 4.8.0 is probably the better foundation for Rivulet's stated one-engine goal. The next step should be validation, not more abstract debate: update/pin Aether 4.8.0, wire it behind the custom UI adapter, run the matrix, and decide from measured results.
