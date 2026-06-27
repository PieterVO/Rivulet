# Changelog

## 1.0.0 (Build 53)

- Fixed the Aether player not playing any content (black screen, no audio) for some users. Updated AetherEngine to pick up upstream playback fixes.

## 1.0.0 (Build 52)

- Actor detail pages now work. Tap any cast member to see their bio and the movies and shows they're in.
- Skip Intro and Skip Credits markers now work in the Aether player.
- The Aether player now plays the next episode and updates Continue Watching when a show finishes.
- Fixed connecting to your Plex server when you're away from home.
- Updated AetherEngine to the latest version.
- Bug fixes.

## 1.0.0 (Build 50)

- Refactored most views to UIKit. Performance should be much better.
- Added AetherEngine as a third video player option.
- Bug fixes.
- Live TV fixes coming soon!

## 1.0.0 (Build 48)

- Added Discover + Watchlist tabs
- Added Music browsing
- Added pre-play audio and subtitle track pickers
- Added "Resume or Restart Prompt" setting (off by default)
- Bare touchpad tap surfaces the timeline overlay
- Fixed focus on player error screens
- Auto-transcodes codecs Apple TV can't decode (MPEG-2, VC-1, VP9, AV1)
- Fixed freeze when resuming after a paused scrub
- Fixed audio flutter on AAC, FLAC, and PCM tracks
- Fixed 401s on multi-server Plex accounts
- Each install gets its own Plex Dashboard identity

Thanks to @rrgomes for PR contributions in this release.

## 1.0.0 (Build 43)

- Refined the GUI to be more Apple TV+ esque
- Removed MPVKit. Defaulting to AVPlayer while I continue working on custom player (sorry, this means direct stream for now)
