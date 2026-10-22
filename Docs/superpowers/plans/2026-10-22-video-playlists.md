# Video Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse, play in order, shuffle and edit Plex and Jellyfin video playlists on tvOS (#370).

**Architecture:** Playlist calls go on the `MediaProvider` seam with one implementation per backend. The sidebar gets a per-server `.playlists` tab that shows a `PlexHomeViewController` grid mode; a playlist opens as a second mode built on the collection page. Playback uses a client-side `PlayQueue` in `UniversalPlayerViewModel` that replaces the dead `shuffledQueue`.

**Tech Stack:** Swift 6, UIKit (tvOS 26), XCTest.

**Spec:** `Docs/superpowers/specs/2026-10-22-video-playlists-design.md`. Read it first; its Decisions section is binding.

## Global Constraints

- UIKit only on every surface touched. No SwiftUI added to a primary surface; no `UIHostingController` in a cell.
- `RivuletCore/` gets no `#if os(...)`.
- Only `AetherPlayer` names AetherEngine types (untouched here).
- Destructive confirms use `ConfirmationPopupViewController`, never `UIAlertController`.
- Text entry uses `TextEntryViewController`.
- Every new settings row gets a descriptor in `SettingsDescriptors.swift` and a reader (grep the key: more than one hit).
- Never show Plex `leafCount`. Count from `totalSize` / `TotalRecordCount` or don't show one.
- Comments: one or two lines, why not what.
- **Subagents never commit.** The coordinating session makes one commit at the end.
- **Shared checkout:** another session may have uncommitted edits (today: `HeroOverlayView.swift`, `PlexHomeViewController.swift` hero hunks). Never revert or restage foreign hunks. A build error in code you did not touch means wait and retry.
- Build: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build`. Tests: same with `test -only-testing:RivuletTests/<Class>`.

## Measured server facts

Plex PMS 1.43.4, token = server token, all JSON with `Accept: application/json`:
- List: `GET /playlists?playlistType=video` → `MediaContainer.Metadata[]` with `ratingKey`, `title`, `smart` (JSON bool), `composite`, `thumb`, `playlistType`.
- Items: `GET /playlists/{id}/items?X-Plex-Container-Start=&X-Plex-Container-Size=` (existing `getPlaylistItemsWithTotal`). Rows add `playlistItemID` (Int).
- Create: `POST /playlists?type=video&title={t}&smart=0&uri={libraryURI}` → 200 with the new playlist in `Metadata[0]`. Without `uri`: 400.
- Add: `PUT /playlists/{id}/items?uri={libraryURI}` (existing). Duplicate ignored; a season expands to episodes.
- Move: `PUT /playlists/{id}/items/{playlistItemID}/move[?after={playlistItemID}]`; no `after` = top.
- Remove: `DELETE /playlists/{id}/items/{playlistItemID}`. Rename: `PUT /playlists/{id}?title=`. Delete: `DELETE /playlists/{id}` (204).

Jellyfin 12.1 (`jellyfin-test`, creds in `.claude/test-servers.md`, gitignored):
- **Every playlist call needs the USER's session token.** With an API key, Move and Update fail 400 (`Guid can't be empty`, no user). The app already uses a user session; keep it.
- List: `GET Items?userId=&includeItemTypes=Playlist&recursive=true&fields=ChildCount`; video ones have `MediaType == "Video"` (audio = `"Audio"`).
- Items: `GET Playlists/{id}/Items?userId=` → rows carry `PlaylistItemId`. **On 12.1 `PlaylistItemId` equals the item `Id`, and a duplicate shares it**, so remove by entry id removes every copy. The app keys by index and accepts this.
- Create: `POST /Playlists` JSON `{"Name","Ids":[..],"UserId","MediaType":"Video"}` → `{"Id"}`. Empty `Ids` is allowed (create still seeds, per spec).
- Add: `POST Playlists/{id}/Items?ids=a,b&userId=` → 204. Duplicates are KEPT. A Series id expands to all its episodes.
- Move: `POST Playlists/{id}/Items/{PlaylistItemId}/Move/{newIndex}` → 204 (absolute 0-based index).
- Remove: `DELETE Playlists/{id}/Items?entryIds=` → 204. Rename: `POST Playlists/{id}` JSON `{"Name"}` → 204. Delete: `DELETE Items/{id}` → 204.

## Review Focus

1. **The last playlist item ends playback and closes the player**, including when the credits trigger already ran `handlePlaybackEnded` (movies run it twice). Test in Task 5: `test_lastItem_hasNoNext` and `test_secondEndPass_doesNotDismissWhileCardShows`.
2. **A title in the playlist twice** plays twice and the Playlist pane marks the right copy. Test in Task 4: `test_duplicates_advanceByIndex`; Task 6 marks rows by index.
3. **A playlist on a server whose session is signed out or unreachable** shows the page's error state with Retry, never an empty "No items" page. Task 3 reuses `pageZero` `.failed`.
4. **Settings reorder still works exactly as before** after extraction (Sidebar library order). Task 7 runs the existing Settings reorder tests and a manual pass.
5. **Add to Playlist on a smart or 0-item playlist list**: smart ones never appear in the picker. Test in Task 6: `test_picker_excludesSmart`.

---

### Task 1: Seam, models and Plex calls

**Files:**
- Modify: `Rivulet/Models/Media/MediaKind.swift` (add `case playlist`)
- Create: `Rivulet/Models/Media/PlaylistEntry.swift`
- Create: `RivuletCore/Plex/PlexNetworkManager+Playlists.swift` (move `PlexPlaylist`, `PlexPlaylistContainer`, `getPlaylistItemsWithTotal`, `addToPlaylist`, `libraryURI`, `getMachineIdentifier` here from `+Music.swift`; add the rest)
- Modify: `RivuletCore/Plex/PlexNetworkManager+Music.swift` (remove what moved; `getAudioPlaylists` calls `getPlaylists(type: "audio", …)`)
- Modify: `RivuletCore/Models/Plex/PlexMetadata.swift` (decode `playlistItemID: Int?`)
- Modify: `Rivulet/Services/MediaProvider/MediaProvider.swift` (requirements + defaults)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (`"playlist"` → `.playlist`)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexProvider.swift` (implement)
- Test: `RivuletTests/Unit/PlexPlaylistRequestTests.swift`, `RivuletTests/Unit/PlexPlaylistMappingTests.swift`

**Interfaces:**
- Produces:
  - `MediaKind.playlist`
  - `struct PlaylistEntry: Hashable, Sendable { let entryID: String; let item: MediaItem }`
  - `struct MediaPlaylist: Hashable, Sendable { let item: MediaItem; let isSmart: Bool }` (in `PlaylistEntry.swift`)
  - On `MediaProvider` (defaults: `supportsPlaylists` false, list/entries return `[]`, mutations throw `MediaProviderError.unsupported` or the file's existing unsupported error):
    - `var supportsPlaylists: Bool { get }`
    - `func videoPlaylists() async throws -> [MediaPlaylist]` (sorted by title, case-insensitive)
    - `func playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry]` (all pages, server order)
    - `func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist`
    - `func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws`
    - `func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws`
    - `func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws` (each backend derives what it needs: Plex `after` = the entry before `toIndex` after the move, Jellyfin the index)
    - `func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws`
    - `func deletePlaylist(_ playlist: MediaItemRef) async throws`
  - `PlexNetworkManager`: `getPlaylists(serverURL:authToken:type:sectionID:sort:)`, `createPlaylist(serverURL:authToken:type:title:uri:) -> PlexPlaylist`, `movePlaylistItem(…playlistItemID:after:)`, `removePlaylistItem(…playlistItemID:)`, `renamePlaylist(…title:)`, `deletePlaylist(…)`, plus `nonisolated static func playlistURL(...)` builders the tests call without a network.

- [ ] **Step 1: Write failing tests.** `PlexPlaylistRequestTests`: `test_create_buildsTypeTitleSmartUri` (query has `type=video`, `title=Road Trip` percent-encoded, `smart=0`, `uri=server://M/com.plexapp.plugins.library/library/metadata/1,2`), `test_move_withoutAfter_hasNoAfterParam`, `test_move_withAfter`, `test_remove_path`, `test_rename_query`, `test_delete_path`. `PlexPlaylistMappingTests`: `test_playlistMetadata_mapsToPlaylistKind`, `test_playlistItemID_decodes` (JSON fixture with `"playlistItemID": 82017`), `test_smart_decodes_jsonBool`, `test_leafCount_isNeverUsedForCount` (mapped item's `childProgress` is nil).
- [ ] **Step 2: Run, verify they fail.** `xcodebuild test … -only-testing:RivuletTests/PlexPlaylistRequestTests -only-testing:RivuletTests/PlexPlaylistMappingTests` → compile failure on missing symbols.
- [ ] **Step 3: Implement.** Machine identifier: cache per server URL inside `PlexProvider` (the music provider fetches it per call). `createPlaylist` returns the decoded `Metadata[0]`. Plex `entryID` = `String(playlistItemID)`; rows without one are dropped.
- [ ] **Step 4: Run tests, verify pass.** Also run `-only-testing:RivuletTests/` music provider tests if any exist (`grep -l PlexMusicProvider RivuletTests -r`).
- [ ] **Step 5: No live check here.** Task 3 exercises these calls in the simulator.

### Task 2: Jellyfin implementation

**Files:**
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinClient.swift` (add `func post<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?) async throws -> T` if create needs a decoded body with no query; the existing body-decoding `post` suffices for create)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinModels.swift` (`JFItem.playlistItemId: String?`, `mediaType` if absent; `JFCreatePlaylist` encodable `{Name, Ids, UserId, MediaType}`; `JFUpdatePlaylist {Name}`)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinMediaMapper.swift` (`"Playlist"` → `.playlist`)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinProvider.swift` (implement, `supportsPlaylists = true`)
- Test: `RivuletTests/Unit/Jellyfin/JellyfinPlaylistTests.swift`

**Interfaces:** Consumes Task 1's protocol. Produces nothing new.

- [ ] **Step 1: Failing tests.** `test_videoPlaylists_dropsAudio` (fixture with one `MediaType: "Audio"` and one `"Video"` → one result), `test_entries_carryPlaylistItemId`, `test_playlistKind_maps`, `test_move_sendsAbsoluteIndex` (assert the path built for moving entry at index 3 to 1 is `Playlists/P/Items/E/Move/1`; expose the path builder as `static`).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** against the measured endpoints above. `userId` is the provider's `userID`. Delete is `client.delete("Items/\(id)")`. Page entries with `startIndex`/`limit` 200 until `TotalRecordCount`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Live check** with curl against `jellyfin-test` only if a mapper assumption is in doubt; clean up anything created.

### Task 3: Sidebar row, Settings toggle, playlists grid, playlist page

**Files:**
- Modify: `Rivulet/Views/TVNavigation/NavigationEnvironment.swift` (`SidebarTab.playlists(providerID: String)`)
- Modify: `Rivulet/Views/TVNavigation/UIKit/ShellSidebarModel.swift` (`sections(...)` gains `playlistProviders: Set<String>` and `primaryProviderID: String?`; append an item titled "Playlists", icon `list.bullet.rectangle`, as the LAST row of each server's section whose provider ID is in the set)
- Modify: `Rivulet/Views/TVNavigation/TVSidebarView.swift` (`@AppStorage("showPlaylistsTab") = true`; pass the set only when on; `contentViewController(for:)` → `PlexHomeViewController(mode: .playlists(providerID:))`; exhaustive `tabContent`; bounce to Home when the tab disappears)
- Modify: `Rivulet/Views/TVNavigation/UIKit/ShellSidebarViewController.swift` (`liveSections()` seed passes an empty set)
- Create: `Rivulet/Services/MediaProvider/PlaylistAvailability.swift` (`@MainActor @Observable final class PlaylistAvailability { static let shared; private(set) var providerIDs: Set<String>; func refresh() async }` asks every registered provider with `supportsPlaylists` for `videoPlaylists()`, keeps IDs with ≥1. Refreshed on launch after providers connect, on `.plexDataNeedsRefresh`, and after create/delete.)
- Modify: `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift` (toggle `showPlaylistsTab`, "Show Playlists", right after the Watchlist toggle at ~:419) and `Rivulet/Views/Settings/SettingsDescriptors.swift` (descriptor: "Shows a Playlists row under each server that has video playlists.")
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift`:
  - `HomeMode.playlists(providerID: String)` (tab grid of playlists, built like `.watchlist`: no hero, one `.grid` section titled "Playlists", items = `MediaPlaylist.item`), and `HomeMode.playlist(MediaPlaylist)` (page).
  - `.playlist` follows `.collection` everywhere (`.overFullScreen` + blur fade, focus anchor, `pageZero`, Menu). Grid source: `provider.playlistEntries` loaded fully, kept in `playlistEntries: [PlaylistEntry]`; grid items are `entries.map(\.item)`. Empty copy: "This playlist is empty."
  - Header row above the grid on `.playlist`: **Play** and **Shuffle** buttons (reuse the button style the collection/library header uses, or `FocusableActionButton`); a `UIFocusGuide` so Up from row 0 reaches them.
  - Routing: `openPlaylistIfNeeded(_ item: MediaItem)` mirrors `openCollectionIfNeeded` (de-dupe by `ref.itemID` up the modal stack); called wherever `openCollectionIfNeeded` is (`presentPreview`, `PreviewCarouselViewController.swift:869`). `playableItem` returns nil for `.playlist`.
  - Every exhaustive `switch mode` handles both new cases (compiler lists them).
  - Observes `.plexDataNeedsRefresh`: `.playlists` refetches, `.playlist` reloads entries.
  - Duplicate-safe focus restore: `indexPath(for: PreviewSourceTarget)` on `.playlist` uses the slot index the preview opened from, not `first(where:)`.
- Test: `RivuletTests/Unit/ShellSidebarModelTests.swift`, `RivuletTests/Unit/CollectionPageRoutingTests.swift` (add playlist cases)

**Interfaces:**
- Consumes: Task 1 (`MediaPlaylist`, `videoPlaylists`, `playlistEntries`).
- Produces: `HomeMode.playlist(MediaPlaylist)`, `PlexHomeViewController.playlistEntries`, `PlaylistAvailability.shared.refresh()`, a hook `func startPlaylist(_ entries: [PlaylistEntry], at index: Int, shuffled: Bool)` stubbed here (logs) and implemented in Task 5.

- [ ] **Step 1: Failing tests.** `test_playlistsRow_onlyForServersWithPlaylists`, `test_playlistsRow_isLastInItsServerSection`, `test_playlistsRow_primaryPlexServer`, update `test_withServer_keepsEveryTab`; routing: `test_playlistTile_opensPlaylistPage`, `test_openPlaylist_dedupesStack`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run tests, verify pass; build.**
- [ ] **Step 5: Simulator check** (signed-in sim, primary PMS 192.168.1.140:32400): sidebar shows Playlists; grid shows 7 playlists; Star Wars page loads 246 entries in order with movies and Clone Wars episodes mixed; Menu returns; toggle off hides the row. Screenshot each. Never press Select on a tile twice in a row (playback-by-accident rule).

### Task 4: PlayQueue model

**Files:**
- Create: `Rivulet/Views/Player/PlayQueue.swift`
- Test: `RivuletTests/Unit/Player/PlayQueueTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct PlayQueue: Sendable, Equatable {
      let entries: [PlaylistEntry]
      private(set) var index: Int
      init(entries: [PlaylistEntry], startingAt index: Int)
      static func shuffled(_ entries: [PlaylistEntry]) -> PlayQueue   // starts at 0 of a shuffled copy
      var current: PlaylistEntry { get }
      var next: PlaylistEntry? { get }          // nil on the last entry
      mutating func advance()                   // index += 1, clamped
      mutating func jump(to index: Int)
      /// First entry not watched, or nil when none watched/in progress or all watched (Play then starts at 0 with no prompt).
      static func continuePoint(in entries: [PlaylistEntry]) -> Int?
  }
  ```
- [ ] **Step 1: Failing tests.** `test_next_crossesMovieToEpisode`, `test_lastItem_hasNoNext`, `test_duplicates_advanceByIndex` (entries A,B,A: after two advances `current` is the third entry and `index == 2`), `test_advance_onLast_staysPut`, `test_continuePoint_nilWhenNothingWatched`, `test_continuePoint_nilWhenAllWatched`, `test_continuePoint_firstUnwatchedAfterProgress` (watched, in-progress, unwatched → 1), `test_shuffled_keepsEveryEntry`.
- [ ] **Step 2: Run, verify fail.** **Step 3: Implement.** "Watched" = `item.userState.isPlayed`; "progress" = any entry `isPlayed` or `isInProgress` (`MediaUserState`). **Step 4: Run, verify pass.**

### Task 5: Player plays the queue

**Files:**
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift`
- Modify: `Rivulet/Views/Player/UIKit/PostVideoOverlayView.swift` (`NextEpisodeCardView`: movie shows title + year, episode keeps show + SxEy)
- Modify: `Rivulet/Views/Player/PlayerPresenter.swift` and `PlexHomeViewController.startPlaylist` (from Task 3)
- Modify: `Rivulet/Services/MediaProvider/ProviderPlayback+Prepare.swift` if the provider init needs to accept a queue
- Test: `RivuletTests/Unit/Player/PlaylistPlaybackTests.swift`

**Interfaces:**
- Consumes: `PlayQueue` (Task 4), `PlaylistEntry`.
- Produces: `UniversalPlayerViewModel.playQueue: PlayQueue?` (read-only outside), `func playQueueEntry(at index: Int) async` (jump), both init paths accept `playQueue: PlayQueue? = nil`.

Rules (from the spec's Player section, binding):
- Delete `shuffledQueue`, `shuffledQueueIndex`, `isShufflePlay`; `ContentView.swift:260` stops passing it.
- `fetchNextEpisode`: with a queue, return `playQueue.next` mapped to `PlexMetadata` (`ProviderPlaybackMetadata.listing(item:)` for both sources; Plex preload fills full metadata) **before** the provider branch, with no side effects.
- Index advances only at the commit point of the swap in `playNextEpisode` (after `itemGeneration` increments), and `playQueueEntry(at:)` uses `jump`.
- With a queue: `triggerPostVideoTransition` and `handlePlaybackEnded` take a queue branch ahead of the `isEpisode` / `showPostVideoUpNext` gates; `loadUpNextEpisodes` and `resolveNextEpisodeEarlyIfNeeded` return early.
- No next entry → `postVideoState` stays `.hidden`; `finishPlayback` dismisses.
- Provider queue: register entries in `providerEpisodeItems` so `preparedNextProviderPlayback` accepts them.
- `startOffset` for the next entry = its resume point via `WatchProgressPolicy` (not `nil`).
- `playEpisode`'s same-ratingKey guard does not apply to queue jumps.
- Countdown and Autoplay Limit unchanged.
- Launch (`startPlaylist`): Play → if `PlayQueue.continuePoint` is non-nil, present `ConfirmationPopupViewController`-style two-choice popup (reuse the existing "Resume Playback?" popup builder in `PlexHomeViewController` ~:4931) with "Continue with "<title>"" and "Play from Beginning"; Shuffle → `PlayQueue.shuffled`; Play from Here → index of that tile. The first entry's own resume prompt still applies when `promptResumeOrRestart` is on.

- [ ] **Step 1: Failing tests** (drive the VM with stub items the way existing VM tests do; find them with `grep -l "UniversalPlayerViewModel(" RivuletTests -r`): `test_queue_nextIsQueueEntry_notSeasonEpisode`, `test_queue_fetchNext_hasNoSideEffect` (call twice, same result), `test_queue_movieEnd_showsUpNext` (a movie with a next entry reaches `.showingEpisodeSummary`), `test_lastItem_hasNoNext` (postVideoState `.hidden` after `handlePlaybackEnded`), `test_secondEndPass_doesNotDismissWhileCardShows`, `test_nextEntry_startsAtItsResumePoint`.
- [ ] **Step 2: Run, verify fail.** **Step 3: Implement.** **Step 4: Run these plus the existing player suites (`-only-testing:RivuletTests/Player`) and verify pass.**
- [ ] **Step 5: Simulator check** on X-Men (2 entries: movie → movie): Play, seek to 1 min before the end, Up Next card shows Deadpool with title/year (no "S00E00"), countdown plays it; at Deadpool's end the player closes. Then Clone Wars around the film (episode → movie). Screenshots.

### Task 6: Editing from tiles

**Files:**
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (tile menu builders ~:6249-6420)
- Create: `Rivulet/Views/Media/UIKit/PlaylistMenus.swift` (picker + actions, so the big file only calls in)
- Modify: `Rivulet/Views/Music/UIKit/MusicMenus.swift` (`addToPlaylist` gets "New Playlist…" first)
- Modify: `RivuletCore/Plex/PlexNetworkManager+Playlists.swift` / `PlexMusicProvider` / `JellyfinMusicProvider` for audio create (`type=audio` / `MediaType=Audio`) via a `MusicProvider.createPlaylist(title:seededWith:)` requirement
- Test: `RivuletTests/Unit/PlaylistMenusTests.swift`

**Interfaces:**
- Consumes: Task 1 mutations, `TextEntryViewController`, `ConfirmationPopupViewController`, `TileMenuPopupViewController`, `PlaylistAvailability.refresh()`.
- Produces: `enum PlaylistMenus` with pure builders the tests call:
  - `static func pickerRows(playlists: [MediaPlaylist]) -> [PickerRow]` (`PickerRow` = `.newPlaylist` then `.playlist(MediaPlaylist)`, smart excluded, sorted by title)
  - `static func entryActions(isSmart: Bool) -> [EntryAction]` (`.playFromHere`, `.move`, `.remove`; `.move` and `.remove` only when not smart)
  - `static func playlistTileActions(isSmart: Bool) -> [PlaylistAction]` (`.play`, `.shuffle`, `.rename` when not smart, `.delete`)
  - `@MainActor static func presentAddToPlaylist(for item: MediaItem, from: UIViewController)`

Behaviour:
- Movies, episodes, seasons, shows get **Add to Playlist…** in their tile menu (Plex and provider builders). It fetches that server's playlists (no cache, they change) and presents a second `TileMenuPopupViewController` (pattern: `MusicMenus.presentPopup`).
- **New Playlist…** → `TextEntryViewController(title: "New Playlist", fieldName: "Playlist Name", allowsEmpty: false)` → `createPlaylist(title:seededWith: [item.ref])` → `PlaylistAvailability.refresh()` → post `.plexDataNeedsRefresh`.
- On the playlist page, entry tiles get the entry actions in a group ABOVE the usual title actions. Remove updates the grid first, rolls back and shows an error popup if the server throws.
- Playlist tiles (grid tab) get Play / Shuffle / Rename… / Delete…. Delete confirms with `ConfirmationPopupViewController(title: "Delete "<name>"?", message: "This removes the playlist from your server. The titles stay in your library.", confirmTitle: "Delete", destructive: true)`. Rename uses `TextEntryViewController` with `initialText`.
- Errors: one popup "Couldn't update the playlist." with the reason; no partial state left on screen.

- [ ] **Step 1: Failing tests** `test_picker_newPlaylistFirst`, `test_picker_excludesSmart`, `test_picker_sortedByTitle`, `test_entryActions_smartIsPlayOnly`, `test_playlistTileActions_smartHasNoRename`.
- [ ] **Step 2: Run, verify fail.** **Step 3: Implement.** **Step 4: Run, verify pass; build.**
- [ ] **Step 5: Simulator check** on the primary PMS using a throwaway playlist named "Rivulet Test" (delete it afterwards): create from a movie tile, add an episode, rename, remove the episode, delete. Confirm with curl `GET /playlists` that nothing named "Rivulet Test" remains.

### Task 7: Move (shared reorder controller)

**Files:**
- Create: `Rivulet/Views/Components/UIKit/GrabReorderController.swift` (or the nearest shared UIKit components folder; check `Rivulet/Views/Components/`)
- Modify: `Rivulet/Views/Settings/UIKit/SettingsPageViewController.swift` (adopt it; delete the private copy: state :34-42, gestures :93-129, `handleGrab` :131, `moveHeld` :145, `dropGrab` :158, `suppressNextSelect` :251, `shouldUpdateFocusIn` gate :302)
- Modify: `Rivulet/Views/Settings/UIKit/SettingsCell.swift` (wiggle moves to a shared `UIView` extension or helper the poster cell also calls)
- Modify: `PlexHomeViewController.swift` (Move action starts it on the playlist page grid)
- Test: `RivuletTests/Unit/GrabReorderControllerTests.swift` + existing Settings reorder tests (`grep -rl reorder RivuletTests`)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class GrabReorderController {
      enum Axis { case vertical, grid(columns: Int) }
      init(view: UIView, axis: Axis,
           canMove: @escaping (_ from: Int, _ to: Int) -> Bool,
           onStep: @escaping (_ from: Int, _ to: Int) -> Void,   // live swap, UI only
           onDrop: @escaping (_ original: Int, _ final: Int) -> Void,
           onCancel: @escaping (_ original: Int) -> Void)
      var isMoving: Bool { get }
      func begin(at index: Int)        // Settings: from its 0.6 s hold; playlist page: from the Move menu row
      static func target(from: Int, direction: UIFocusHeading, axis: Axis, count: Int) -> Int?   // pure, tested
  }
  ```
  Arrow presses and `.indirect` swipes both move (the remote rule). Select drops; Menu cancels (`MenuBackHandling`, gated on focus containment per CLAUDE.md). Focus is locked while moving (host's `shouldUpdateFocus` returns `!controller.isMoving`).
- Settings keeps sending `onReorder(up)` per step exactly as today (its `onStep` maps to that). The playlist page sends ONE `movePlaylistEntry` on drop and restores order on cancel or failure.

- [ ] **Step 1: Failing tests** `test_target_vertical_upDown`, `test_target_grid_leftRightWithinRowAndAcross`, `test_target_grid_upDownByColumns`, `test_target_clampsAtEnds`.
- [ ] **Step 2: Run, verify fail.** **Step 3: Implement** and adopt in Settings first, then the playlist page. **Step 4: Run the new tests and every existing Settings test; verify pass.**
- [ ] **Step 5: Simulator check:** Settings > Sidebar library reorder behaves as before (hold, wiggle, arrows, drop). Then on the throwaway playlist: Move an entry two slots right and one row down, drop, `GET` the items with curl to confirm the server order; Menu-cancel restores. Delete the throwaway playlist.

### Task 8: Player Playlist pane, changelog, device checks, commit

**Files:**
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift` (Up Next pane ~:1550/:1676: while `vm.playQueue != nil` its title is "Playlist", rows are the queue entries, current row by **index**, Select → `vm.playQueueEntry(at:)`; relax the `type == "episode"` gate at ~:1278 for the queue case; eyebrow "Movie" or "S1 E2")
- Modify: `Rivulet/Views/Player/UIKit/UpNextRowState.swift` (index-based current marker for the queue case)
- Modify: `Rivulet/Views/Components/WhatsNewView.swift` (one bullet in the CURRENT build's entry; use the `rivulet-changelog` skill): "Plex and Jellyfin video playlists: browse them from the sidebar, play in order or shuffled, and create, edit and reorder them from any title's long-press menu."
- Create: `Docs/superpowers/plans/2026-10-22-video-playlists-device-checks.md` (focus: header buttons ↔ grid, Move mode on a real remote with swipes and clicks, Menu during the countdown, a duplicate entry, iPhone Remote)

- [ ] **Step 1: Failing test** `test_upNextRows_markCurrentByIndex_forDuplicates` in the existing `UpNextRowState` tests.
- [ ] **Steps 2 to 4:** implement, run, pass.
- [ ] **Step 5: Full verification.** Full test suite; `swiftlint lint --strict` (or the docker form); iOS scheme build (`xcodebuild -scheme "Rivulet iOS" -destination 'generic/platform=iOS Simulator' build`) since RivuletCore changed.
- [ ] **Step 6: Review the diff** (`git diff`), excluding foreign hunks. Whole-branch review by a fresh reviewer.
- [ ] **Step 7: Commit (coordinator only)**, explicit paths, foreign hunks filtered: `git commit -m "Video playlists (#370)"`. Do not push.
