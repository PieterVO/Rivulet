<div align="center">

<img src="Branding/logo_glow_transparent.png" alt="Rivulet" width="220">

# Rivulet

**Built for simplicity.**

A native Apple TV app for Plex, Jellyfin, and Live TV.

<a href="https://apps.apple.com/us/app/rivulet-for-plex/id6756892857">
  <img src="https://img.shields.io/badge/Download_on_the-App_Store-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download on the App Store">
</a>
&nbsp;
<a href="https://testflight.apple.com/join/TcCsF5As">
  <img src="https://img.shields.io/badge/Join_the-TestFlight_Beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white" alt="Join the TestFlight Beta">
</a>

<br><br>

![tvOS 26+](https://img.shields.io/badge/tvOS-26+-000000?logo=apple)
![iOS 26+](https://img.shields.io/badge/iOS-26+-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-PolyForm_NC_1.0.0-blue)
![Not for sale](https://img.shields.io/badge/⚠_not_for_sale-Noncommercial_only-red)

</div>

---

<div align="center">

<img src="Screenshots/tvOS/01-home.jpg" alt="Home" width="100%">

</div>

<div align="center">

<img src="Screenshots/tvOS/02-detail.jpg" alt="Movie detail" width="49%">
<img src="Screenshots/tvOS/07-music-album.jpg" alt="Music album" width="49%">

</div>

---

Rivulet is an Apple TV app first. Every feature is designed for the Siri Remote and the big screen before anything else. There is also an iPhone and iPad app that gets regular updates and support, built on the same Plex and Live TV code.

## Why this exists

This project has fairly *opinionated* designs and logic, with a few focal points:

- **Simplicity**: what is the best design to get me to the media I want to watch.
- **Live TV**: Plex's live TV is, to put it nicely, sub-par. I've spent too long trying to get it to work well for me (kudos if you don't have this problem). I don't want live TV in a separate app, so this solves my problems.
- **HomePod Integration**: the Plex app has never worked well when setting HomePod as the default audio output on my Apple TV. It hurts to have a HomePod sitting there collecting dust while my sub-par TV speakers play sound. This app helps the hurt.
- **Direct Play**: no server transcoding. The bar I'm chasing is Infuse. This was frustratingly built because Apple's frameworks can't direct play most video containers, and the third-party players that handle the trickier formats can't use Apple's HomePod controls.
- **Apple TV+ Inspired**: the UI takes heavy inspiration from Apple's own TV app. Clean, focused, and native-feeling.

## Live TV

Some people could use Rivulet just for Live TV, and that's fine by me.

- **What's On**: what's airing now, what starts soon, and a For You row that learns what you watch.
- **Guide**: a full channel guide for every source.
- **Multiview**: watch up to four channels at once. Promote one to the big tile while the rest keep playing muted.
- **Scores**: live scores for NFL, college football, NBA, MLB, and NHL right in the player. Pick a game and Rivulet tunes to the channel airing it. Multiview has a scores layout too: the game on one side, the scoreboard on the other.
- **Favorites** from every source in one list, in the order you choose, plus Recently Watched.
- **Sources**: Dispatcharr, Plex Live TV (HDHomeRun and DVB tuners), and any M3U/XMLTV playlist.

<div align="center">

<img src="Screenshots/tvOS/03-whats-on.jpg" alt="What's On" width="49%">
<img src="Screenshots/tvOS/04-multiview.jpg" alt="Multiview" width="49%">

</div>

Dispatcharr and Plex Live TV are tested regularly. Generic M3U/XMLTV is wired up but less battle-tested. Feedback welcome.

## Insights

Pause on a scene and wonder where you've seen that actor before? Open Insights from the player.

- **Cast**: who is on screen, with a bio and their filmography. Jump straight to anything else they're in.
- **Trivia**: behind-the-scenes facts sorted into production, casting, adaptation, references, lore, goofs, and music, plus a Top 10 of the best ones.
- Works on movies and TV episodes.

Insights is still growing. Coverage and accuracy improve with every release.

<div align="center">

<img src="Screenshots/tvOS/05-insights-trivia.jpg" alt="Insights trivia" width="49%">
<img src="Screenshots/tvOS/06-insights-cast.jpg" alt="Insights cast" width="49%">

</div>

## Media servers

|                                  | Plex | Jellyfin |
|----------------------------------|:----:|:--------:|
| Movie and TV libraries           |  ✓   |    ✓     |
| Continue Watching and Up Next    |  ✓   |    ✓     |
| Collections                      |  ✓   |    ✓     |
| Skip intro and credits           |  ✓   |    ✓     |
| Watched state sync               |  ✓   |    ✓     |
| Photo libraries                  |  ✓   |    ✓     |
| Music                            |  ✓   |          |
| Live TV and DVR tuners           |  ✓   |          |
| Watchlist and Discover           |  ✓   |          |
| Managed users and profiles       |  ✓   |          |
| iPhone and iPad app              |  ✓   |          |

Jellyfin support is new (server 10.10 or later). Bug reports welcome. M3U and Dispatcharr Live TV work with either server.

## Video player

Playback runs on [AetherEngine](https://github.com/superuser404notfound/AetherEngine): FFmpeg demuxing, remuxed to HLS-fMP4, handed to Apple's frameworks. Direct play is the primary path. A server transcode is only the fallback when a file has no direct-play URL, or when startup fails.

- **Video**: H.264 and HEVC through VideoToolbox. AV1, VP9, MPEG-2, VC-1, and MPEG-4 Part 2 fall back to software decode.
- **HDR**: HDR10, HDR10+, HLG, and Dolby Vision. DV profiles 5 and 8.1 play with full Dolby Vision. Profile 7 plays as its HDR10 base layer.
- **Audio**: AAC, AC3, E-AC3 (including Atmos / JOC), TrueHD, DTS, DTS-HD MA, FLAC, ALAC, MP3, and PCM.
- **Subtitles**: text (SRT, ASS/SSA) and bitmap (PGS, DVB). ASS/SSA keeps its original styling.
- **Stream quality**: direct play by default, or pick a transcode quality when bandwidth is tight.
- **Content filtering** (work in progress): mute language and skip scenes on your device, from the title's subtitles or an imported EDL list. The file is never touched.

## Music

- Album, artist, and playlist browsing, modeled on Apple's Music app for tvOS.
- Lyrics, synced when the source provides timestamps.
- System Now Playing controls. HomePod, AirPods, Siri Remote, and Control Center all work.

## More

- **Discover and Watchlist**: browse trending and upcoming titles, add them to your Plex watchlist, and see at a glance what you already own.
- **Top Shelf and Siri**: Continue Watching on the Apple TV home screen, and Siri to play or search your library.
- **Smart artwork**: title logos are placed with Apple's Vision framework so they stay clear of faces and busy parts of the image.

## iPhone and iPad

The iOS app follows the Apple TV app. It shares the same Plex and Live TV code, so a fix on one platform fixes both.

- Home, library, search, and detail pages built for touch
- Live TV
- Downloads for offline viewing
- Picture in Picture

<div align="center">

<img src="Screenshots/iOS/01-home.jpg" alt="iPhone home" width="24%">
<img src="Screenshots/iOS/02-movie.jpg" alt="iPhone movie detail" width="24%">
<img src="Screenshots/iOS/03-show.jpg" alt="iPhone show detail" width="24%">
<img src="Screenshots/iOS/04-library.jpg" alt="iPhone library" width="24%">

</div>

---

> [!IMPORTANT]
> ## Rivulet is free, but not for sale.
>
> Licensed under [PolyForm Noncommercial 1.0.0](LICENSE). You may **clone it, run it, modify it, share it, and contribute back** for personal, educational, research, hobby, or any other noncommercial use.
>
> You may **not** sell Rivulet, charge for access to it, or bundle it (or any derivative of it) into a paid app, product, or service. **Anything derived from this code inherits the same restriction.** I'd rather give this away than watch someone else charge for it.

---

## Building

Requires Xcode 27. Copy the secrets template once (placeholder values are fine), then open the project:

```bash
cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift
open Rivulet.xcodeproj
```

`Rivulet` is the tvOS scheme and `Rivulet iOS` is the iPhone and iPad scheme. `Rivulet/` holds the tvOS app, `RivuletiOS/` the iOS app, and `RivuletCore/` the code both share. See `CLAUDE.md` for the architecture.

## Contributing

Found a bug? [Open an issue](../../issues/new/choose) and pick the platform (tvOS or iOS). If the same bug shows up on both, open one issue per platform so each fix is tracked on its own.

I welcome all contributions from any level of developer. I welcome contributions from LLMs too as long as they are checked and tested.

**If you do contribute, please build and test on an actual Apple TV. The simulator is close, but does not mimic the Apple TV fully.**

By submitting a pull request, you agree to license your contribution under the same terms as Rivulet (PolyForm Noncommercial 1.0.0, see [LICENSE](LICENSE)).

## License

Rivulet is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

Everything here is free to use, read, fork, and build on. The only thing you can't do is sell it. I'd rather give this away than watch someone else charge for it.

In short: clone it, run it, modify it, share it, contribute back, for personal, educational, research, hobby, or other noncommercial use. You may not use Rivulet (or anything derived from it) for commercial purposes, including selling it, charging for access to it, or bundling it into a paid product or service.

This restriction is not decorative. If you ship Rivulet's code (in whole or in part, modified or not) inside something you sell, you are infringing the copyright in this project. If you spot a commercial app built on this code, please [open an issue](../../issues) so it can be reported to the relevant platform (App Store, GitHub, etc.).

Third-party components retain their original licenses. FFmpeg is included under LGPL-2.1+; libdovi under MIT. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine): the playback engine
- [FFmpeg](https://ffmpeg.org/): demuxing, decoding, and remuxing
- [libdovi](https://github.com/quietvoid/dovi_tool): Dolby Vision RPU handling
- [libass](https://github.com/libass/libass): ASS/SSA subtitle rendering
- [Plex](https://plex.tv/): media server platform
- [Jellyfin](https://jellyfin.org/): open source media server
- [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr): IPTV management
- [TMDB](https://www.themoviedb.org/): artwork and metadata for Discover

---

<div align="center">

Rivulet is not affiliated with or endorsed by Plex, Inc. or the Jellyfin project.

</div>
