# Folder Browsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse Plex and Jellyfin libraries by their on-disk folders on tvOS, in an Apple Music album-page layout (text list right, focused item's preview left, blurred backdrop).

**Architecture:** A new provider seam `FolderProvider` (beside `PhotoProvider`) returns a page of folder entries. Plex implements it over `/library/sections/<id>/folder`, Jellyfin over `Items?parentId=`. A new UIKit stack `FolderLibraryViewController` + `FolderListViewController` renders it; `TVSidebarView` routes no-metadata libraries to it, and a Folders control on normal Plex libraries opens it too.

**Tech Stack:** Swift 6, UIKit (tvOS 26), XCTest.

**Spec:** `Docs/superpowers/specs/2026-10-19-folder-browsing-design.md`

## Global Constraints

- UIKit only. No SwiftUI, no `UIHostingController` in this feature.
- No `#if os(...)` anywhere; all new files live under `Rivulet/` (tvOS-only), nothing in `RivuletCore/` except the one Plex endpoint (Task 1).
- Never call `URLSession.shared` for Plex; use `PlexNetworkManager`'s request path.
- Plex paging needs BOTH `X-Plex-Container-Start` and `X-Plex-Container-Size`.
- Remote input: list rows are focusable (both transports free); the preview pane holds no focus.
- Menu back at the window level gates on focus containment (copy `PhotoLibraryViewController.handleMenuBack`).
- No autoplay of the next file. No long-press menu on folders.
- Code comments: one or two lines, short.
- Subagents never commit. The coordinator commits once at the end.

## Review Focus

1. A Plex folder root with 1000+ subfolders (Movies root: 1030 rows): must page, focus must not stall.
2. Jellyfin `PhotoAlbum` rows show as folders.
3. Returning from the player re-focuses the same row and shows its new progress.
4. Menu inside a folder pops one level; Menu at the root reaches the sidebar; Menu while the player or tile menu is up is not eaten.
5. An empty folder shows "This folder is empty", and a failed page shows an error line that Select retries.

---

### Task 1: Folder seam, Plex and Jellyfin implementations

**Files:**
- Create: `Rivulet/Services/MediaProvider/FolderProvider.swift`
- Create: `Rivulet/Services/MediaProvider/Plex/PlexFolderProvider.swift`
- Create: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinFolderProvider.swift`
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (add `getFolder`, next to `getLibraryItemsWithTotal` at :455)
- Test: `RivuletTests/Unit/Folders/PlexFolderMapperTests.swift`, `RivuletTests/Unit/Folders/JellyfinFolderMapperTests.swift`

**Interfaces:**
- Produces:
```swift
nonisolated struct FolderEntry: Hashable, Sendable, Identifiable {
    enum Content: Hashable, Sendable {
        case folder(MediaItemRef, childCount: Int?)
        case video(MediaItem)
        case photo(PhotoItem)
    }
    let id: MediaItemRef
    let title: String
    let content: Content
}
nonisolated struct FolderPage: Sendable { let entries: [FolderEntry]; let nextPage: Page? }
protocol FolderProvider: Sendable {
    /// One page of a library's root (`folder` nil) or a folder: folders first, then files, by name.
    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage
}
enum PlexFolderMapper { static func entries(_ rows: [PlexMetadata], providerID: String, serverURL: String, authToken: String) -> [FolderEntry] }
enum JellyfinFolderMapper { static func entry(_ dto: JFItem, providerID: String, baseURL: URL) -> FolderEntry? }
```
- `PlexNetworkManager.getFolder(serverURL:authToken:sectionId:parent: String?, start: Int, size: Int) async throws -> (items: [PlexMetadata], totalSize: Int?)`

- [ ] **Step 1: Write the failing mapper tests** from real rows measured on PMS 1.43.4 and Jellyfin 12.1 (spec, "Measured server behaviour"):
  - `test_plexRowWithoutRatingKey_isFolder_withParentFromKey`: row `{key: "/library/sections/16/folder?parent=32756", title: "10 Minute Trainer"}` → `.folder(ref.itemID == "32756", childCount: nil)`, title "10 Minute Trainer".
  - `test_plexMovieRow_isVideo`: row with `ratingKey "95176"`, `type "movie"` → `.video` with `item.id` ref itemID "95176".
  - `test_plexEpisodeRow_isVideo`: `type "episode"`, ratingKey "214321" → `.video`.
  - `test_jellyfinFolderAndPhotoAlbum_areFolders`: `Type "Folder"` and `Type "PhotoAlbum"` with `ChildCount 9` → `.folder(childCount: 9)`.
  - `test_jellyfinVideo_isVideo`, `test_jellyfinPhoto_isPhoto`, `test_jellyfinUnknownType_isNil`.
- [ ] **Step 2: Run, verify they fail** (`xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/PlexFolderMapperTests -only-testing:RivuletTests/JellyfinFolderMapperTests`): compile failure.
- [ ] **Step 3: Implement.** Plex: `getFolder` hits `/library/sections/<id>/folder` with `parent=` when given, plus Start and Size. Folder test is `ratingKey == nil`; parent id is the `parent` query value of `key`. Videos via `PlexMediaMapper.item`. Jellyfin: `Items` with `parentId` (folder id or library id), `sortBy=IsFolder,SortName`, `sortOrder=Descending,Ascending`, `fields=Path,ChildCount,RecursiveItemCount,MediaSources`, `startIndex`/`limit`, `enableTotalRecordCount=true`; videos via `JellyfinMediaMapper`'s item mapping, photos via `JellyfinPhotoMapper.item`. Both providers adopt `FolderProvider` by extension, as `PhotoProvider` is adopted.
- [ ] **Step 4: Run, verify they pass.**

### Task 2: Library routing and kind rules

**Files:**
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (`library(_:providerID:)`)
- Modify: `Rivulet/Models/Media/MediaLibrary.swift` (add `browsesByFolder`)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinMediaMapper.swift:31`, `JellyfinProvider.swift:58-63`, `JellyfinPhotoProvider.swift:61` (`holdsPhotos` → also count videos)
- Modify: `Rivulet/Views/TVNavigation/TVSidebarView.swift:537` (Plex), `:548` (Jellyfin)
- Test: `RivuletTests/Unit/Folders/FolderRoutingTests.swift`

**Interfaces:**
- Produces: `MediaLibrary.browsesByFolder: Bool` (stored, default false). `PlexLibrary.hasNoMetadataAgent: Bool` (`agent` is `tv.plex.agents.none` or `com.plexapp.agents.none`). `JellyfinMediaMapper.library(_:providerID:homeVideos: HomeVideosContent)` where `enum HomeVideosContent { case photosOnly, videos }`.
- Consumes: `FolderLibraryViewController(title:source:)` from Task 3.

- [ ] **Step 1: Failing tests:**
  - `test_plexMovieSection_noneAgent_browsesByFolder` (agent `tv.plex.agents.none`, type movie → true), same for `com.plexapp.agents.none` with type show; `tv.plex.agents.movie` → false.
  - `test_jellyfinMixed_browsesByFolder` (no collection type → kind `.mixed`, true).
  - `test_jellyfinHomeVideos_withVideos_browsesByFolder`, `test_jellyfinHomeVideos_photosOnly_isPhotos`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** The Jellyfin probe becomes two `limit=0` counts (`Photo`, then `Video`); photos > 0 and videos == 0 → `.photosOnly`. A failed probe still throws. In `TVSidebarView`, a library with `browsesByFolder` returns `FolderLibraryViewController` before the photo/music/grid branches.
- [ ] **Step 4: Run, verify pass.**

### Task 3: Folder page UI (layout C)

**Files:**
- Create: `Rivulet/Views/Folders/FolderListing.swift` (paged model, modelled on `PhotoListing`)
- Create: `Rivulet/Views/Folders/UIKit/FolderLibraryViewController.swift` (stack + Menu, modelled on `PhotoLibraryViewController`)
- Create: `Rivulet/Views/Folders/UIKit/FolderListViewController.swift` (one level: list + preview + backdrop)
- Create: `Rivulet/Views/Folders/UIKit/FolderRowCell.swift`, `FolderPreviewView.swift`
- Test: `RivuletTests/Unit/Folders/FolderListingTests.swift`, `FolderRowDetailTests.swift`

**Interfaces:**
- Consumes: `FolderProvider`, `FolderEntry`, `FolderPage` (Task 1).
- Produces:
```swift
@MainActor final class FolderListing {
    typealias Source = @MainActor () -> (any FolderProvider, MediaLibrary)?
    init(folder: MediaItemRef?, source: @escaping Source)
    private(set) var entries: [FolderEntry]
    var onChange: ((Change) -> Void)?   // .reloaded, .appended(Range<Int>), .failed
    @discardableResult func loadFirst() -> Task<Void, Never>?
    @discardableResult func loadMore() -> Task<Void, Never>?
    func replace(_ item: MediaItem)      // swap a refreshed video in place
}
enum FolderRowDetail { static func text(for entry: FolderEntry) -> String }
@MainActor final class FolderLibraryViewController: UIViewController {
    init(title: String, source: @escaping FolderListing.Source)
}
```
- Page size 100.

- [ ] **Step 1: Failing tests:**
  - `FolderListingTests`: pages append and dedupe by `id`; a stale generation's page is dropped after `loadFirst`; a failed page keeps loaded entries and allows `loadMore` again (copy the shape of `PhotoListingTests`).
  - `FolderRowDetailTests`: folder → "›"; watched video → "✓"; in-progress video with 600 s duration and 240 s offset → "6 min left"; unwatched 660 s → "11 min".
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement the page.** Right: a `UICollectionView` list (one column) of `FolderRowCell` (title + trailing `FolderRowDetail.text`, glass row focus style from `GlassRowStyle`). Left: `FolderPreviewView`, non-focusable, showing the focused entry: still (video thumb, or for a folder the first video's thumb if loaded, else a folder glyph), title, length, format, progress, file path, folder item count. Behind both: the focused still, blurred, under the Home hero's constant scrim (`HeroBackdropView`'s scrim values). Header: library title over folder title. Load more within 10 rows of the end. Empty: "This folder is empty". Failure: one row "Couldn't load this folder", Select retries.
  - Select folder → push. Select video → `ProviderPlayer.play(item, fromBeginning: false, from: self, onDismiss:)`; on dismiss refetch that item through `MediaProvider` metadata, `listing.replace`, keep focus on the row. Select photo → `PhotoViewerViewController(listing: PhotoListing(folder: currentFolder, source: photoSource), index:)` at that photo's index among the folder's photos.
  - Long press on a video (`UILongPressGestureRecognizer`, simultaneous-permissive delegate) → `TileMenuPopupViewController(sections:)` with Play from Beginning, Mark Watched or Mark Unwatched via `MediaProvider.markPlayed`/`markUnplayed`, then post `.plexDataNeedsRefresh`.
  - Observe `.plexDataNeedsRefresh` to reload the visible level.
  - Metrics: measure Apple Music's tvOS 26 album page (rivulet-tvos-uikit skill, `MusicAlbumViewController` already clones it, reuse its metrics where they match).
- [ ] **Step 4: Run tests, verify pass; build the tvOS scheme clean.**
- [ ] **Step 5: Simulator check** against the live server: open Miscellaneous, enter 10 Minute Trainer, Menu back, play episode 3 and exit. One Select per script.

### Task 4: Folders control on normal Plex libraries

**Files:**
- Modify: `Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift` (a Folders button)
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (wire it)
- Test: none beyond the build (UI wiring only).

**Interfaces:**
- Consumes: `FolderLibraryViewController(title:source:)`.

- [ ] **Step 1:** Add a "Folders" `SortButton` beside the sort button on Plex `movies`/`shows` libraries, shown whether or not the Collections switch is (that switch hides when a library has no collections). Select pushes `FolderLibraryViewController` for that library onto the library's navigation (or presents it full screen if the tab has no navigation controller), Menu returns to the grid. Hidden for Jellyfin libraries.
- [ ] **Step 2:** Build; simulator check on Movies: Folders → a movie folder → play → back.

### Final

- [ ] `swiftlint lint --strict` clean; full `xcodebuild test` for the Rivulet scheme; changelog line via `rivulet-changelog`.
- [ ] Coordinator reviews the diff and commits once.
