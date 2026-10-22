# Video Playlists (#370)

Browse, play in order, and edit Plex and Jellyfin video playlists on tvOS. iOS is a later, separate slice.

## Background

- #240 asked for "Collection and Playlist Support" and was closed after collections went out. #370 asks for the playlist half.
- Music already has audio playlists on both servers (`MusicProvider.playlists`, `tracks(inPlaylist:)`, `addToPlaylist`). Video has nothing: Plex `type="playlist"` maps to `MediaKind.unknown`, and Jellyfin's playlist view is dropped.
- Reference apps (read for ideas only, all GPL or similar, no code taken): Plezy is the only one that edits playlists. Plozz and jellyfin-androidtv play from an in-app list. Plex's own web and TV apps put "Playlists" in the sidebar. Plex's mobile app moved it inside each library in 2025, and users have complained about it since.

## Measured on PMS 1.43.4 (2026-10-21, probe playlist created and deleted)

| Action | Call | Result |
|---|---|---|
| List | `GET /playlists?playlistType=video` | 7 playlists, all regular. `sectionID=` filters correctly (6 of 7 for section 1). |
| Items | `GET /playlists/{id}/items` + Start/Size | Rows carry `playlistItemID`, `viewOffset`, `viewCount`. Movies and episodes mix. |
| Create | `POST /playlists?type=video&title=&smart=0&uri=server://{machineId}/com.plexapp.plugins.library/library/metadata/{keys}` | 200. **No `uri` = 400**: a playlist starts with an item. |
| Add | `PUT /playlists/{id}/items?uri=` | 200. A duplicate is silently ignored. A season expands into its episodes. |
| Move | `PUT /playlists/{id}/items/{playlistItemID}/move?after={playlistItemID}` | 200. No `after` = top. |
| Remove | `DELETE /playlists/{id}/items/{playlistItemID}` | 200 |
| Rename | `PUT /playlists/{id}?title=` | 200 |
| Delete | `DELETE /playlists/{id}` | 204 |

- `leafCount` on `/playlists` lies: X-Men says 9, `/items` returns 2 (the other files are gone). Never show `leafCount`.
- Playlists belong to the Plex user that made them, so each Home profile sees its own. Use the server token, as Music does.

Jellyfin 12.1 (measured on `jellyfin-test` 2026-10-22, probe playlists deleted): the endpoints match Plezy's (list `Items?includeItemTypes=Playlist`, items `Playlists/{id}/Items`, create `POST /Playlists`, add `POST Playlists/{id}/Items?ids=`, remove `DELETE Playlists/{id}/Items?entryIds=`, move `POST Playlists/{id}/Items/{entry}/Move/{index}`, rename `POST Playlists/{id}` with `{"Name"}`, delete `DELETE Items/{id}`). Differences from Plex: an empty create is allowed, a duplicate add is KEPT, and `PlaylistItemId` equals the item id, so both copies of a duplicate share it and remove takes both. Move and rename need a user session token; an API key gets 400. Full detail in the plan.

## Decisions

1. **One "Playlists" sidebar row per server**, inside that server's section, shown only when the server has at least one video playlist. Settings > Sidebar gets a **Playlists** toggle (`showPlaylistsTab`, default on), next to the Watchlist one, with a description panel entry.
2. **Playlist tiles show the title only.** No counts (`leafCount` lies) and no watch badge.
3. **Smart playlists are read-only.** They play and can be deleted; no add, remove, move or rename, and they never appear in the Add to Playlist picker.
4. **Play order is an in-app list.** Plex play queues are unused: Jellyfin needs the list anyway, so both servers share one mechanism. The unused `shuffledQueue` becomes it.
5. **Position is an index into the list**, never a ratingKey, so a title in the list twice works.
6. **Every item resumes from its own resume point** (`WatchProgressPolicy`), with no prompt when the list moves on to it. Progress is the item's own, so a half-watched entry also sits in Continue Watching like any other title. The item the user starts on still gets the existing resume prompt when that setting is on.
7. **"Play" starts at the first item.** When the playlist has progress (some entries watched or in progress, not all watched), a popup asks first: **Continue with "<next title>"** or **Play from Beginning**. Same look as the existing Resume Playback popup. With no progress, or everything watched, Play starts at the top with no popup.
8. **Series Up Next is off while a playlist plays.** The next item is always the next list entry, of any type. The last item ends playback and closes the player.
9. **Add to Playlist lives in the tile long-press menu only.** Every title on every surface has a tile. The detail page gets no new button.
10. **A playlist holds one server's items.** The picker lists only the tile's own server's playlists.

## What the user sees

### Sidebar and the playlists grid
- "Playlists" row (icon `list.bullet.rectangle`) under each server that has any. Selecting it shows a poster grid of that server's video playlists, sorted by title, built like the Watchlist tab (a `PlexHomeViewController` mode, grid section, no hero).
- Select on a playlist tile opens the playlist page.
- Long press on a playlist tile: **Play**, **Shuffle**, **Rename…** (regular only), **Delete…**.

### Playlist page
- Built like the collection page: presented over full screen with the blur fade, title above one poster grid, in the server's order, every page loaded.
- A header row with **Play** and **Shuffle** buttons above the grid. Up from the first grid row reaches them.
- Select on a tile opens the title's detail page, as everywhere else. That detail page's Play plays only that title.
- Long press on a tile adds, above the usual title actions: **Play from Here**, **Move**, **Remove from Playlist** (Move and Remove only on regular playlists).
- **Move** puts that tile into the Settings reorder mode: the same wiggle, focus lock, arrow presses and swipes, Select to drop. Left and Right move one slot, Up and Down move a row. Menu cancels and restores the order. One move call is sent on drop.
- The grab logic in `SettingsPageViewController` (state, gestures, `moveHeld`, `dropGrab`, `suppressNextSelect`) is extracted into one shared reorder controller that both surfaces use, with left and right added for the grid. Settings must behave exactly as before; its reorder tests and a manual pass on Sidebar order check that. The wiggle moves from `SettingsCell.setReordering` into something the poster cell can also call. This is extraction, not a move onto `DirectionalInputBinding`, which CLAUDE.md rules out for Settings.
- Edits are applied to the grid first, then rolled back with an error popup if the server refuses.

### Add to Playlist (every video tile)
- Tile menu row **Add to Playlist…** on movies, episodes, seasons and shows. It opens a second popup (the `MusicMenus.presentPopup` pattern): **New Playlist…** first, then that server's regular video playlists by title.
- **New Playlist…** opens `TextEntryViewController` for the name, then creates the playlist seeded with the tile's item. The sidebar row appears if this was the server's first playlist.
- Adding a season or show adds its episodes (Plex measured for seasons; shows and Jellyfin to be measured, and Jellyfin limited to movies and episodes if it adds the series object itself).
- Music's existing "Add to a Playlist…" gains the same **New Playlist…** entry (`type=audio`), since it is the same server call.

### Rename and Delete
- Rename: `TextEntryViewController` with the current name, `allowsEmpty: false`.
- Delete: `ConfirmationPopupViewController` (the house popup, not `UIAlertController`), destructive. The sidebar row disappears when the last one goes.

### In the player
- Next-item card: a movie shows its title and year, an episode its show and SxEy. Today the card always renders `S%02dE%02d`, which would read "S00E00" for a movie.
- The rail's Up Next pane becomes **Playlist** while a list plays: every entry, the current one marked Watching, Select jumps to that entry.
- Countdown and the Autoplay Limit apply as they do for episodes.

## Model and seam

- `MediaKind.playlist`. `PlexMediaMapper.kind` maps `"playlist"`; the Jellyfin mapper maps `Playlist`. Tiles route `.playlist` like `.collection`: not playable from the tile, Select opens the page.
- `struct PlaylistEntry { let entryID: String; let item: MediaItem }`. `entryID` is Plex `playlistItemID` / Jellyfin `PlaylistItemId` (new decoded fields on `PlexMetadata` and `JFItem`).
- New `MediaProvider` requirements with defaults that return empty or throw (the `collections(in:)` pattern):
  - `supportsPlaylists: Bool`
  - `videoPlaylists() async throws -> [MediaItem]` (each carries `isSmart`)
  - `playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry]` (all pages)
  - `createPlaylist(title: String, seededWith: MediaItemRef) async throws -> MediaItem`
  - `addToPlaylist(_:items:)`, `removeFromPlaylist(_:entryID:)`, `movePlaylistEntry(_:entryID:after:)`, `renamePlaylist(_:title:)`, `deletePlaylist(_:)`
- Plex network calls move out of `PlexNetworkManager+Music.swift` into a shared `PlexNetworkManager+Playlists.swift` (RivuletCore, so iOS gets them later): `getPlaylists(type:)`, the existing item pager, create, add (existing), remove, move, rename, delete. `PlexPlaylist` gains `playlistType`. The "Unverified" comment on `addToPlaylist` goes: it is measured now.
- `PlexHomeViewController` gets `HomeMode.playlists(providerID:)` (the sidebar grid) and `HomeMode.playlist(MediaItem)` (the page). Every exhaustive `switch mode` is updated; the page reuses the collection path wholesale (`loadGridPage`, `pageZero`, anchor, Menu).
- `SidebarTab.playlists(providerID:)`; `ShellSidebarModel.sections` takes the set of provider IDs that have playlists. Counts come from `ServerDataStore.load(from:)` for extra servers and `PlexDataStore` for the primary Plex server, refetched after create and delete.
- Mutations post `.plexDataNeedsRefresh`; the playlists grid and the playlist page observe it.

## Player changes (`UniversalPlayerViewModel`, the riskiest part)

- Replace `shuffledQueue`/`shuffledQueueIndex` with `playQueue: PlayQueue?` (`items: [MediaItem]`, `index: Int`). Plex entries become shells with `ProviderPlaybackMetadata.listing(item:)`; the existing Plex preload fetches full metadata.
- **The index advances in exactly one place**, the commit point of the swap in `playNextEpisode` / `playEpisode`. `fetchNextEpisode` returns `items[index + 1]` and has no side effects. (It has three callers today and the shuffle version advanced on each: `661e7af` was that bug.)
- With a queue active, `triggerPostVideoTransition` and `handlePlaybackEnded` take a queue branch ahead of the `isEpisode` and `showPostVideoUpNext` gates. `loadUpNextEpisodes` and `resolveNextEpisodeEarlyIfNeeded` do nothing.
- No next entry: `postVideoState` stays `.hidden` and `finishPlayback` dismisses.
- Provider queues register entries in `providerEpisodeItems` so `preparedNextProviderPlayback` accepts them.
- `playNextEpisode` sets `startOffset` from the entry's resume point in a queue instead of `nil`.
- `playEpisode`'s same-ratingKey guard and `UpNextRowState`'s `firstIndex(ratingKey)` are bypassed for queue jumps, which go by index.
- Launch: `PlayerPresenter` callers pass the queue and a start index. Play, Shuffle and Play from Here build it from the loaded entries.

## Out of scope

- iOS (separate slice once tvOS ships).
- Smart playlist creation or rule editing. Playlist artwork editing.
- Playlists on Home, and Plex Lists.

## Risks

- `UniversalPlayerViewModel` and `PlayerContainerViewController` are the two files with the most bug fixes in the repo. The queue changes need a device pass, including movie to episode to movie, the last item, a duplicate entry, and Menu during the countdown.
- Focus on the playlist page: the header buttons above the grid and move mode. Simulator verification of these is provisional.
- Movies already run `handlePlaybackEnded` twice (credits trigger, then `.ended`). In a queue the second pass must not dismiss the player while the Up Next card shows; the existing `postVideoState == .hidden` guard covers it, and a test pins it.

## Tests

- `ShellSidebarModelTests`: the row appears only for servers with playlists, in the right section.
- Mapper tests: Plex `playlist` and `playlistItemID`, Jellyfin `Playlist` and `PlaylistItemId`, `smart`.
- Plex request builders: create, add, move, remove, rename and delete URLs, including `move` without `after`.
- `PlayQueue`: next across mixed types, duplicates, last item returns nil, index advances once per swap, Play's first-unwatched rule.
- Device checks list in `Docs/superpowers/plans/` alongside the plan.

## Build order (one commit at the end)

1. Seam, models, Plex calls, mappers, tests.
2. Sidebar row and the playlists grid.
3. Playlist page and Play / Shuffle / Play from Here, with the player queue.
4. Add to Playlist, New Playlist, Remove, Rename, Delete, Music's New Playlist.
5. Move mode.
6. Jellyfin half (after measuring), changelog line, device checks.

## Later: playlists on Home

When playlists get a Home row, use the Apple TV app's tall Home tile, measured from a 4K capture on 2026-10-22:
- Tiles are 4:5, about 558x698 pt, 3 across on the 80/40 grid.
- Text sits 40 pt from the leading edge and about 50 pt from the bottom.
- Plex's composite renders a 4:5 collage when asked for `?width=1120&height=1400`.

The playlists grid keeps 16:9 cards.
