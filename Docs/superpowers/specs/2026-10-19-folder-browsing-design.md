# Folder browsing (tvOS)

Date: 2026-10-19. Status: approved 2026-10-19.

## Why

A user wrote: "there's no folder support for media I keep in simple folders without
metadata. (I have many)". Today a library with no metadata agent (Plex "Other Videos",
Jellyfin mixed or Home Videos) opens as one flat poster grid. On the maintainer's server
"Miscellaneous" is 623 loose videos in one grid, with the folder structure that gave them
meaning thrown away. The ask is to browse those libraries the way they sit on disk, and
to play what's in them.

## Goals

- Libraries with no metadata open as a folder tree: subfolders, then files.
- Any Plex library can be switched to the folder tree.
- Videos in a folder play through the normal player with normal watch state and resume.
- It feels like an Apple TV app page, measured against Apple Music's album page (layout C below).

## Non-goals

- No autoplay of the next file in a folder (decided: no).
- No change to photo libraries. They keep today's Photos grid (`PhotoLibraryViewController`).
- No files outside the server's libraries. Only what Plex or Jellyfin has scanned is reachable.
- No folder view on iOS.
- No user-selectable layouts (list vs grid vs list+preview). One layout for folders.
- Merging several servers into one interface: a separate request, and it conflicts with the
  standing "never merge across servers" decision. Out of scope here.

## Anti-goals

- A second Plex or Jellyfin client. Folder fetching goes through the existing provider seam.
- SwiftUI. This is a primary surface: UIKit only.
- A per-row subtitle or settings toggle for the layout.

## The page (layout C)

Picked by the user from three mockups (list, grid, list + preview).

- **Right side:** a vertical text list. Subfolders first, then files, by name (server order).
  Each row: name, plus a trailing detail: "›" for a folder, a checkmark for a watched video,
  "N min left" for in progress, otherwise the length.
- **Left side:** the focused item's preview. For a video: its still, title, length, video
  format, progress, and the file path. For a folder: item count and, when one exists, the
  first video's still (my call; servers give folders no artwork).
- **Backdrop:** the focused item's still, blurred, behind the whole page, with the same
  constant scrim the Home hero uses. It updates as focus moves.
- **Header:** the library name above the current folder name, as a breadcrumb.
- **Navigation:** Select on a folder pushes the next level. Menu pops one level; at the
  library root Menu behaves as on any library page (back to the sidebar).
- **Select on a video** plays it through `ProviderPlayer.play`. When playback ends or the
  user exits, the page shows the same row focused with its progress refreshed.
- **Select on a photo** that sits in a video folder opens the existing `PhotoViewerViewController`
  on that photo, paging through the photos of that folder already loaded (my call).
- **Long press** on a video opens the existing hand-built tile menu
  (`TileMenuPopupViewController`): Play from Beginning, Mark Watched/Unwatched. Folders get
  no menu (my call: a Plex folder has no id to mark, so "Mark All Watched" would mean walking
  the tree file by file).
- **Paging:** long folders load in pages as focus nears the end, like the library grid.
- **Empty folder:** a single "This folder is empty" line, no rows.

## Where it shows up

- **Plex:** a `movie` or `show` section whose agent is a "none" agent
  (`tv.plex.agents.none` or `com.plexapp.agents.none`) opens in folder view.
  Every other movie and show section gets a **Folders** button in the library header,
  beside the sort button, which opens the folder page for that library; Menu returns to the
  grid. Nothing to remember per library. The Collections switch is hidden when a library has
  no collections, so the Folders button stands on its own.
  Music and photo sections are unchanged.
- **Jellyfin:** a library with no collection type (mixed) opens in folder view. A
  `homevideos` library opens in folder view, except that it keeps opening in Photos when it
  holds photos and no videos (my call; today one stray photo flips the whole library to
  Photos via `holdsPhotos`). Jellyfin Movies and TV Shows get no Folders button: their
  `parentId` listing is flat (measured below), so the feature is absent there, as the
  provider rules allow.

## Measured server behaviour

### Plex (PMS 1.43.4, 192.168.1.140, 2026-10-19)

- `GET /library/sections/<id>/folder` lists the root; each folder row's `key` is
  `/library/sections/<id>/folder?parent=<n>`, which lists that folder.
- Works on every section type: Movies root returned 1030 folder rows (88 KB, 54 ms),
  TV 353 rows (28 KB, 90 ms), an Other Videos subfolder 1 folder + 8 videos (12 KB, 22 ms).
- A folder row has only `key` and `title`: no `ratingKey`, no `type`, no thumb, no count.
  "No `ratingKey`" is the folder test. (This is why the photo-libraries spec rejected
  `/folder` for the photo mapper; it does not block this feature.)
- A file row is full metadata: `ratingKey`, `type` (`movie` in an Other Videos section),
  `thumb`, `duration`, `Media`/`Part` with the file path, and user state. It maps to a
  `MediaItem` like any other item and plays through the normal route.
- In a `show` section the files are `episode` rows (ratingKey, type `episode`); folders
  still have no ratingKey. TV Shows: show folder, then `Season N` folders, then episodes.
  Piano Tutorials (none-agent `show`): folders, then episodes. Episodes play directly.
- Server order is folders first, then files, by name.
- Paging works only with `X-Plex-Container-Start` sent alongside `X-Plex-Container-Size`
  (then `totalSize` and `offset` appear). Without Start, the whole folder comes back.
- Sections on this server with a none agent: four Other Videos sections (ids 5, 16, 17, 19),
  plus Piano Tutorials (15, a `show`
  section with the none agent).

### Jellyfin (12.1 test server, 192.168.1.140:8096, 2026-10-19)

Two libraries were added over the same `/media/Miscellaneous` folder to compare: "Misc Mixed"
(no collection type) and "Misc Home" (`homevideos`).

- `GET /Items?userId=<u>&parentId=<folder>&sortBy=IsFolder,SortName&sortOrder=Descending,Ascending`
  walks the disk tree in both: 26 root entries, `Folder` items with `IsFolder=true`, then
  `Video` items inside. Root 40-285 ms, a subfolder 26-50 ms. `TotalRecordCount` pages it.
- `fields=Path,ChildCount,RecursiveItemCount` gives each folder its path and counts.
  Folders have no Primary image.
- A folder holding only a picture comes back as `PhotoAlbum`, not `Folder`. Treat both as folders.
- A Movies library's `parentId` listing is a flat list of `Movie` items with no folder
  level. Hence no Folders button on Jellyfin Movies/TV.

## How it is built (builder's latitude inside these lines)

- **Seam:** one new provider requirement next to `PhotoProvider`, shaped like it:
  a page of folders plus a page of items for `(library, folder?, page)`. Plex and Jellyfin
  each implement it in their own file. Videos come back as `MediaItem`; photos as `PhotoItem`.
- **Surface:** a new UIKit view controller stack under `Views/Folders/UIKit/`, modelled
  on `PhotoLibraryViewController`'s push/pop stack and Menu handling
  (`handleMenuBack`, deferred pop). Layout C is its own view; it does not reuse
  `PhotoGridViewController`.
- **No-metadata libraries are folders only** (decided): no Titles grid for them. Folder
  view is its own page chosen at routing time, like Photos, and the Folders button on a
  normal Plex library opens that same page. It does not live inside `PlexHomeViewController`.
- **Routing:** `TVSidebarView`'s library switch (`:537` Plex, `:548` Jellyfin) decides folder
  view from the rules above. 
- **Watch state:** after playback or a long-press mark, the page refreshes on
  `.plexDataNeedsRefresh` like the other UIKit surfaces.
- **Remote input:** the list is focusable, so both remote transports come free. The preview
  pane holds no focus.
- **Tests:** the folder/file mapping for both providers, from saved real responses.

## Left to the builder

Exact metrics (row pitch, preview width, type sizes): measure Apple Music's album page on
tvOS 26 and match it. Page size. Cache policy for folder pages. How the header switch
renders three states.
