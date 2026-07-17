# Info Popup — Advanced stats tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. tvOS UIKit focus/press code MUST be written with the `rivulet-tvos-uikit` skill loaded.

**Goal:** Add an "Advanced" tab to the player's Now Playing Info popup that surfaces AetherEngine's live telemetry ("stats for nerds"); the popup opens on today's metadata sheet and loads stats only when tabbed over.

**Architecture:** `rail.onInfo` presents a new `PlayerInfoTabsView` container (pill tab bar + two content sheets) instead of a bare `CardInfoView`. Info tab = the existing static metadata sheet (live PLAYBACK block removed). Advanced tab = new `CardStatsView` reading an app-side `AetherAdvancedStats` folded from `engine.diagnostics.liveTelemetry` + decoder labels, ticked 1 Hz only while visible. Tab bar appears only on the aether route (advanced provider closure non-nil); the hls route renders exactly as today.

**Tech Stack:** Swift 6, UIKit (tvOS 26), XCTest. AetherEngine consumed upstream (read-only; no engine change).

## Global Constraints

- Platform tvOS 26+, Swift 6, UIKit for this surface. Do NOT add SwiftUI.
- No AetherEngine change: read `engine.diagnostics.liveTelemetry` only; no new sampler (engine auto-starts it on native load).
- Styling MUST be cohesive with the app: pills match `InsightsTabPillView` tokens; rows/sections match `CardInfoView`'s type ramp. Design Guide restraint — no new gradients/shadows/decoration. No em dashes in user-facing copy.
- Info popup is VOD-player-only (`PlayerContainerViewController`); Live TV out of scope.
- Repo is public: short, plain commit messages.
- Changelog line required (`WhatsNewView.changelogs`, current build).

---

### Task 1: `AetherAdvancedStats` + `AetherPlayer.advancedStats()`

**Files:**
- Modify: `Rivulet/Services/Plex/Playback/AetherPlayer.swift` (add struct near `AetherLiveStats` ~L632; add method near `liveStats()` ~L620)
- Test: `RivuletTests/Unit/AetherAdvancedStatsTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct AetherAdvancedStats {
      let backend: String?
      let audioBridge: String?
      let instantBitrateMbps: Double?
      let averageBitrateMbps: Double?
      let audioBridgeBitrateMbps: Double?
      let observedFps: Double?
      let droppedFrameCount: Int?
      let forwardBufferSeconds: Double?
      let cachedBytes: Int64?
      let networkThroughputMbps: Double?
      let networkTransferredBytes: Int64?
      let avSyncGapMs: Double?
      let producerRestartCount: Int?
      let muxedBytesLifetime: Int64?
      let serverBytesSentLifetime: Int64?
      let serverRequestCount: Int?
      let demuxerBytesFetched: Int64?
      let audioBridgeLiveBytes: Int?
      let rssMb: Int?
      /// True when every display field is nil (no decoder labels yet AND no telemetry).
      var isEmpty: Bool
  }
  ```
  `func advancedStats() -> AetherAdvancedStats` on `AetherPlayer` (MainActor) — folds `engine.activeVideoDecoder` / `engine.activeAudioDecoder` + a 1:1 copy of `engine.diagnostics.liveTelemetry`'s fields (all nil when telemetry is nil).

- [ ] **Step 1: Write failing tests.** In the new test file, `@testable import Rivulet`. Test `isEmpty` true when all-nil; false when only `backend` set; false when a telemetry field set. Construct `AetherAdvancedStats` directly (memberwise) — no engine needed. Keep the type's memberwise init accessible to tests (internal struct, default init).
- [ ] **Step 2: Run — expect FAIL** (type not defined). Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3' -only-testing:RivuletTests/AetherAdvancedStatsTests -derivedDataPath /tmp/rivulet-dd`
- [ ] **Step 3: Add the struct + `isEmpty`** (all 18 display fields nil ⇒ empty) and `advancedStats()` mapping. Mirror `liveStats()`'s existing use of `engine.activeVideoDecoder`/`activeAudioDecoder`; pull the rest from `engine.diagnostics.liveTelemetry` (optional-chained).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat: AetherAdvancedStats telemetry snapshot`

---

### Task 2: Extract shared `PlayerInfoSheetStyle`; refactor `CardInfoView` onto it

Guarantees the two sheets are visually identical by construction (cohesion requirement) and gives `CardStatsView` its builders.

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerInfoSheetStyle.swift`
- Modify: `Rivulet/Views/Player/UIKit/CardInfoView.swift` (replace private `headerLabel/sectionLabel/bodyLabel/infoRow` + `formatBitrate/formatFileSize/formatDuration/formatBufferSeconds` with calls to the shared namespace)
- Test: `RivuletTests/Unit/PlayerInfoSheetStyleTests.swift` (new)

**Interfaces:**
- Produces `enum PlayerInfoSheetStyle` with static builders `headerLabel(_:)`, `sectionLabel(_:)`, `bodyLabel(_:secondary:)`, `infoRow(_:_:)` (exact fonts/colors moved verbatim from `CardInfoView`) and static formatters: existing `bitrate(_:)`, `fileSize(_:)`, `duration(_:)`, `bufferSeconds(_:)` plus new `mbps(_:) -> String` ("%.1f Mbps"), `fps(_:) -> String` ("%.0f fps"), `milliseconds(_:) -> String` (signed, "%+.0f ms").

- [ ] **Step 1: Write failing tests** for the new formatters: `mbps(12.34)=="12.3 Mbps"`, `fps(59.9)=="60 fps"`, `milliseconds(-8.2)=="-8 ms"`, `milliseconds(3.6)=="+4 ms"`. Also assert `fileSize`/`bufferSeconds` still format as before (guards the move).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Create `PlayerInfoSheetStyle`** with builders + formatters (copy tokens exactly from current `CardInfoView`). Then refactor `CardInfoView` to call them; delete the now-duplicated privates. Leave `CardInfoView`'s live section intact for now (Task 3 removes it).
- [ ] **Step 4: Run tests — expect PASS.** Then build the app target to confirm `CardInfoView` still compiles: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3' -derivedDataPath /tmp/rivulet-dd build`
- [ ] **Step 5: Commit** `refactor: shared PlayerInfoSheetStyle for info sheets`

---

### Task 3: Make `CardInfoView` a pure static sheet (remove live PLAYBACK block)

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/CardInfoView.swift`

- [ ] **Step 1:** Remove `liveStatsProvider` param + property, `bufferRow`/`backendRow`/`audioBridgeRow`, `liveTickTimer`, `didMoveToWindow`/`startLiveTick`/`stopLiveTick`/`refreshLiveRows`, `populatePlaybackSection()` and its call site. `init` becomes `init(metadata:modes:)`.
- [ ] **Step 2:** Build the app target — expect one break: the `rail.onInfo` call site in `PlayerContainerViewController` still passes `liveStatsProvider:`. Leave that break for Task 7 (or temporarily drop the arg). Since a red build blocks later tasks, temporarily change the call site to `CardInfoView(metadata: vm.metadata, modes: vm.streamingModeInfo)` — Task 7 replaces the whole line.
- [ ] **Step 3:** Build — expect PASS.
- [ ] **Step 4: Commit** `refactor: CardInfoView is a static metadata sheet`

---

### Task 4: `CardStatsView` (Advanced tab content)

**Files:**
- Create: `Rivulet/Views/Player/UIKit/CardStatsView.swift`

**Interfaces:**
- Consumes: `AetherAdvancedStats` (Task 1), `PlayerInfoSheetStyle` (Task 2), and the existing `InfoScrollView` pattern (copy from `CardInfoView`, or lift `InfoScrollView` into its own file if convenient — keep behavior identical).
- Produces:
  ```swift
  final class CardStatsView: UIView {
      init(provider: @escaping () -> AetherAdvancedStats?)
      var onFocusChange: ((Bool) -> Void)?
      /// Container calls this on tab switch: start/stop the 1 Hz tick + first populate.
      func setActive(_ active: Bool)
      /// True when the scroll surface is at its top (used for Up→tab-bar escape).
      func isFocusAtTop() -> Bool
      /// Container sets this; CardStatsView calls it when Up is pressed at the top.
      var onEscapeUp: (() -> Void)?
  }
  ```

- [ ] **Step 1:** Build sections via `PlayerInfoSheetStyle`: DECODE (Backend, Audio Bridge), STREAM (bitrate instant/avg, observed fps, dropped frames, audio-bridge bitrate), BUFFER / NETWORK (forward buffer, cached, throughput, transferred, A/V sync gap), ENGINE (producer restarts, muxed, server sent + requests, demuxer fetched, audio-bridge live bytes, RSS). Every row omitted when its source field is nil. If the whole snapshot `isEmpty`, show a single muted `bodyLabel("Gathering stats…", secondary: true)` so the tab is never blank.
- [ ] **Step 2:** 1 Hz `Timer` started in `setActive(true)` (and stopped in `setActive(false)`); on each tick re-read the provider and rebuild the stack if the set of present fields changed, else update text in place. Reuse `CardInfoView`'s window-detach safety: also stop in `didMoveToWindow(nil)`.
- [ ] **Step 3:** Implement `isFocusAtTop()` (scroll `contentOffset.y <= topInset + epsilon`) and, in the scroll surface's `pressesBegan`, when Up is pressed while at top, call `onEscapeUp?()` instead of swallowing; otherwise scroll as today.
- [ ] **Step 4:** Build the app target — expect PASS (not yet referenced anywhere).
- [ ] **Step 5: Commit** `feat: CardStatsView advanced telemetry sheet`

---

### Task 5: `InfoTabBarView` (2-pill bar)

**Files:**
- Create: `Rivulet/Views/Player/UIKit/InfoTabBarView.swift`

**Interfaces:**
- Produces:
  ```swift
  final class InfoTabBarView: UIView {
      enum Tab { case info, advanced }
      init(selected: Tab)
      var onSelect: ((Tab) -> Void)?
      func setSelected(_ tab: Tab)          // sync visual w/o firing onSelect
      var containsFocus: Bool               // focus currently on a pill
      // preferredFocusEnvironments → the selected pill
  }
  ```

- [ ] **Step 1:** Build a two-pill horizontal stack. Pill visuals copied token-for-token from `InsightsTabPillView` (capsule `cornerRadius=height/2`, `.continuous`; rest clear + `white 0.72` label bold 20; selected liquid-glass `UIGlassEffect(.regular)` tvOS 26 else `.light` blur, white heavy; focused opaque `white 0.9`, black heavy, `1.05` scale via focus coordinator). Add a header comment cross-referencing `InsightsTabPillView` to keep them in sync. Titles: "Info", "Advanced". Uniform pill width sized to the widest title at `.heavy`.
- [ ] **Step 2:** `Select` handled in pill `pressesBegan(.select)` (UIControl doesn't fire primaryAction on tvOS). Left/Right kept inside the bar via `shouldUpdateFocus` veto (copy `InsightsTabBarView`'s heading check). No horizontal scroll (two pills fit).
- [ ] **Step 3:** Build — expect PASS.
- [ ] **Step 4: Commit** `feat: InfoTabBarView pill bar`

---

### Task 6: `PlayerInfoTabsView` container

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerInfoTabsView.swift`
- Test: `RivuletTests/Unit/PlayerInfoTabsAvailabilityTests.swift` (new — pure availability helper)

**Interfaces:**
- Consumes: `CardInfoView`, `CardStatsView`, `InfoTabBarView`.
- Produces:
  ```swift
  final class PlayerInfoTabsView: UIView {
      init(metadata: PlexMetadata, modes: StreamingModeInfo,
           advancedProvider: (() -> AetherAdvancedStats?)?)
      // static helper for tests:
      static func showsTabBar(advancedProvider: (() -> AetherAdvancedStats?)?) -> Bool
  }
  ```

- [ ] **Step 1: Write failing test** for `showsTabBar`: non-nil closure ⇒ true; nil ⇒ false.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement.** When `advancedProvider == nil`: add only `infoView`, no tab bar (renders like today). Else: add `InfoTabBarView(selected: .info)` above a content region; `infoView` shown, `statsView` created lazily on first `.advanced` select. Tab switch toggles `isHidden` on the two content views (hidden ⇒ not focusable), calls `statsView.setActive(current == .advanced)`, keeps focus on the pill. Focus escapes mirror `InsightsPanelContainerView`: transient `focusEscapeTarget` + `setNeedsFocusUpdate()` from this container; **Down** when `tabBar.containsFocus` → current content; **Up** via `content.onEscapeUp` → tab bar (wire `infoView`/`statsView` `onEscapeUp` to `moveFocus(to: tabBar)`). `CardInfoView` needs the same `onEscapeUp`/`isFocusAtTop` hooks as `CardStatsView` — add them in this task (small addition to `CardInfoView`'s scroll surface). Menu: do NOT conform to `RailPanelMenuHandling` (or return false) so `PlayerRailPanelView` dismisses the panel from either tab. Drive `statsView.setActive` from `didMoveToWindow` too (stop on detach).
- [ ] **Step 4: Run tests — expect PASS;** build the app target — expect PASS.
- [ ] **Step 5: Commit** `feat: PlayerInfoTabsView tabbed info panel`

---

### Task 7: Wire `rail.onInfo`

**Files:**
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift` (~L1071 `rail.onInfo`)

- [ ] **Step 1:** Replace the `CardInfoView(...)` presentation with:
  ```swift
  rail.onInfo = { [weak self] in
      guard let self, let vm = self.viewModel else { return }
      let advancedProvider: (() -> AetherAdvancedStats?)? =
          vm.aetherPlayer != nil ? { [weak vm] in vm?.aetherPlayer?.advancedStats() } : nil
      self.presentRailPanel(
          content: PlayerInfoTabsView(metadata: vm.metadata, modes: vm.streamingModeInfo,
                                      advancedProvider: advancedProvider),
          width: 560, from: rail.infoButton)
  }
  ```
- [ ] **Step 2:** Build the app target — expect PASS.
- [ ] **Step 3: Commit** `feat: Info popup gains an Advanced stats tab`

---

### Task 8: Changelog + full verification

**Files:**
- Modify: `Rivulet/Views/Components/WhatsNewView.swift` (current build entry)

- [ ] **Step 1:** Add a bullet to the current build's changelog entry: `Info now has an Advanced tab showing live playback stats.` (no em dash).
- [ ] **Step 2:** Full build: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3' -derivedDataPath /tmp/rivulet-dd build` — expect PASS.
- [ ] **Step 3:** Full test run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,id=33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3' -only-testing:RivuletTests -derivedDataPath /tmp/rivulet-dd` — expect PASS.
- [ ] **Step 4:** Install to sim and open the player Info popup; confirm Info renders as before and Advanced shows live numbers on the aether route. (Do not drive the sim UI while the user is present — a manual smoke check by the user is fine.)
- [ ] **Step 5: Commit** `docs: changelog for Info Advanced tab`

## Self-Review notes

- Spec coverage: struct+mapping (T1), styling cohesion via shared builders + pill tokens (T2,T5), static Info tab (T3), Advanced content incl. ENGINE section (T4), tab bar (T5), route-based visibility + focus/menu (T6), wiring (T7), changelog (T8). All spec sections mapped.
- Types consistent across tasks: `AetherAdvancedStats`, `PlayerInfoSheetStyle`, `CardStatsView.setActive/isFocusAtTop/onEscapeUp`, `InfoTabBarView.Tab/containsFocus`, `PlayerInfoTabsView.showsTabBar`.
- Deviation note: pill styling is duplicated (not extracted) per the approved spec's sibling choice; the cross-ref comment (T5) is the drift guard. Shared *sheet* builders ARE extracted (T2) because both sheets are new/edited here and extraction carries no risk to the trivia panel.
