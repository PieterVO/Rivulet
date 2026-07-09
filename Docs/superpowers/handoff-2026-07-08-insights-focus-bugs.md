# Handoff: Insights panel focus/press bugs — unresolved after 4+ fix rounds

**Date:** 2026-07-08
**Branch:** `feature/insights-trivia-p2a`
**Status:** BLOCKED. Multiple independently-verified-correct fixes have produced ZERO observable
behavior change on device/simulator. This needs fresh eyes, not another incremental attempt from
the same angle.

## What this is

The Insights player panel was restructured (see `Docs/superpowers/specs/2026-07-08-insights-toptrivia-tabs-design.md`
and `Docs/superpowers/plans/2026-07-08-insights-toptrivia-tabs.md`, both already implemented and
merged into this branch in commits `a796d76..f170936`) from one flat scrolling list into a
pill-tab browser: `Top 10 | Cast | Production | Casting | ...`. That work is DONE, reviewed, and
its own automated tests all pass. **This document is only about bugs found in manual testing
AFTER that work was complete.**

## The 5 bugs reported (manual testing on tvOS Simulator, device `33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3`)

1. Cannot focus **Up** from the first/topmost row in the list to reach the tab pill bar above it.
2. Tab pills beyond the panel's width are unreachable — no way to scroll to them.
3. Cannot scroll down inside an actor's detail view (cast member bio + filmography) — content
   below the fold is unreachable. (Sub-issue: bio was also hard-capped at a fixed 8 lines with no
   way to read more — this part is now fixed, see "What IS confirmed fixed" below.)
4. Pressing **Menu** while inside an actor's detail view closes the WHOLE panel, instead of
   animating back to the cast list (one level up).
5. ~~Ambient-pause backdrop shows through/around an open rail panel~~ — **CONFIRMED FIXED**, see below.

## What IS confirmed fixed (do not re-investigate)

**Bug 5 (ambient backdrop) works.** Added `UniversalPlayerViewModel.isRailPanelOpen`
(`Rivulet/Views/Player/UniversalPlayerViewModel.swift:505-513`), guarded the ambient-timer arm
site and both timer-fire closures on it, and set it from the single `presentRailPanel` choke
point in `PlayerContainerViewController.swift`. User confirmed this specific fix working after
install. This is real, live evidence that: (a) the build/install/deploy pipeline genuinely works,
(b) a fix genuinely landing in compiled code CAN be observed working, (c) this class of "add a
flag, gate a timer" fix is NOT what's broken — only focus-engine/press-routing fixes are failing.

**Bio unbounded-text fix works (partially).** `InsightsActorHeaderView`'s bio label was capped at
a fixed 8 lines (`bioLineLimit`) with a fixed-height constraint. Removed the cap
(`numberOfLines = 0`, `greaterThanOrEqualToConstant` instead of a fixed height) — user confirmed
the bio now DOES show as much text as it wants (in fact "very large, goes off the popup"). The
label itself is unbounded correctly. What's still broken is that the SURROUNDING SCROLL VIEW
doesn't scroll to reveal the overflow (this is bug 3's remaining half).

## Confirmed root cause, bug 4 (Menu closes panel instead of animating back)

**Root cause found and a real fix applied — NOT YET CONFIRMED WORKING by the user on the latest
build (last message before this handoff: "all the same issues").**

`PlayerContainerViewController` calls `becomeFirstResponder()` in `viewDidAppear`
(`PlayerContainerViewController.swift:289` area) and `canBecomeFirstResponder` returns `true`
unconditionally. This makes it THE first responder for the entire scene. tvOS `UIPress` delivery
starts at the first responder and bubbles up the RESPONDER chain — it does NOT start at whatever
view currently holds visual FOCUS. Since `PlayerContainerViewController` already has its own
`pressesBegan` override (`PlayerContainerViewController.swift:383` area) that intercepts
`.menu` unconditionally and calls `handleMenuButton()` — which itself unconditionally called
`activeRailPanel?.dismissPanel()` — **`InsightsPanelContainerView`'s own `pressesBegan` override
(which correctly checked `state == .actor` and called `reverseCrossfadeToList()`) NEVER ACTUALLY
RAN.** The press was fully handled and consumed by the VC before the focus-based responder chain
delivery would ever have reached the panel's content.

**Fix applied** (uncommitted, in working tree):
- New protocol `RailPanelMenuHandling` in `Rivulet/Views/Player/UIKit/PlayerRailPanelView.swift`
  (full doc comment there explains the mechanism) — one method,
  `func handleMenuPress() -> Bool`.
- `PlayerRailPanelView.contentHandlesMenuPress()` — calls `(content as?
  RailPanelMenuHandling)?.handleMenuPress() ?? false`.
- `InsightsPanelContainerView` now conforms to `RailPanelMenuHandling`; its old (dead)
  `pressesBegan` override was DELETED and replaced with `func handleMenuPress() -> Bool { guard
  state == .actor else { return false }; reverseCrossfadeToList(); return true }`.
- `PlayerContainerViewController.handleMenuButton()` now does:
  ```swift
  } else if let panel = activeRailPanel {
      if !panel.contentHandlesMenuPress() {
          panel.dismissPanel()
      }
  } else if vm.controlsFocusActive {
  ```

**This SHOULD work** — the logic is sound, matches the actual press-delivery model, and is a
narrowly-scoped, mechanically verifiable change. It has NOT been confirmed working by the user
yet as of this handoff ("all the same issues" was the response after this fix was live on
device). **This is suspicious given how solid the reasoning is — see "Open question" below.**

## Confirmed root cause pattern, bug 1 (cannot focus Up to tab bar)

**Same first-responder theory applied — but this one is LESS certain, and also NOT confirmed
working.**

Diagnostic evidence gathered (via temporary `NSLog` instrumentation, since removed except where
noted below):
- `InsightsCastListView.scrollView.isScrollEnabled` is confirmed `false` at runtime (correct).
- `InsightsTabBarView`'s pills have a **fully valid, non-degenerate frame**: confirmed via
  `NSLog` dump of `InsightsPanelContainerView`'s `layoutSubviews` —
  `tabBar.frame=(0.0, 0.0, 600.0, 56.0)`, `isHidden=false`, `alpha=1.0`,
  `isUserInteractionEnabled=true`. Geometrically correct, positioned exactly where it should be
  (top of the panel, full width).
- Pressing Up from the FIRST row of the currently-active tab's list produces **ZERO
  `didUpdateFocus` events anywhere** — not "focus moved to the wrong place," but literally no
  focus-engine activity at all, as if the press vanished. Multiple consecutive `didUpdateFocus`
  fire for the SAME row (focus-in visual settling: alpha/border/scale animation), then nothing.
- The tab bar's pills (`InsightsTabPillView`) have never received focus even once, not even on
  initial panel landing — `NSLog("[InsightsDiag] pill focused: ...")` never fired in any capture.

Given the tab bar's geometry, visibility, and hierarchy are all confirmed correct, the working
theory (via a research agent, moderate-high confidence, NOT a documented Apple source — see
"Research findings" below) is: `UIScrollView.isScrollEnabled = false` disables touch/pan
scrolling but does NOT disable the scroll view's participation in focus arbitration — it still
conforms to `UIFocusItemScrollableContainer` and can silently veto a `shouldUpdateFocusInContext`
transition attempting to leave its bounds, producing exactly the observed "zero events, press
just vanishes" symptom (a veto produces the same zero-visible-effect outcome as "no candidate
found," per Apple's own docs, so these are hard to tell apart from the outside).

**Fix applied (uncommitted, mirrors the bug-4 fix exactly):**
- New protocol `RailPanelUpEscapeHandling` in `PlayerRailPanelView.swift` — one method,
  `func escapeUpFromTopRow() -> Bool`.
- `PlayerRailPanelView.escapeUpToTabBarIfAtTopRow()` — calls `(content as?
  RailPanelUpEscapeHandling)?.escapeUpFromTopRow() ?? false`.
- `InsightsPanelContainerView` now ALSO conforms to `RailPanelUpEscapeHandling`:
  ```swift
  func escapeUpFromTopRow() -> Bool {
      guard state == .list, let tabBar, listView.isFocusOnFirstRow() else { return false }
      tabBar.focusSelectedPill()
      return true
  }
  ```
- `InsightsCastListView` gained `func isFocusOnFirstRow() -> Bool` (checks
  `UIScreen.main.focusedItem` against `focusableRows.first`) — replacing an earlier, DELETED
  `pressesBegan` override that (per the same first-responder theory) would never have fired.
- `InsightsTabBarView` gained `override var preferredFocusEnvironments` (returns the selected
  pill, or first pill) and `func focusSelectedPill() { setNeedsFocusUpdate();
  updateFocusIfNeeded() }`.
- `PlayerContainerViewController.pressesBegan` now has a NEW branch, inserted before the existing
  `.select`/`.playPause` handling:
  ```swift
  if press.type == .upArrow {
      if let panel = activeRailPanel, panel.escapeUpToTabBarIfAtTopRow() {
          return
      }
  }
  ```

**User confirmed "all the same issues" after this build was live and freshly installed** (verified
via matching MD5 hash between the built binary and the installed one, and via a temporary
impossible-to-miss bright-red visible marker injected into `InsightsTabBarView`, which the user
DID see — ruling out any stale-build/deployment-pipeline theory conclusively).

## Bugs 2 and 3 — not yet specifically addressed with a targeted fix

Bug 2 (pill horizontal scroll) has an `isScrollEnabled = false` + self-driven-`contentOffset`
implementation in `InsightsTabBarView` (mirrors the established pattern from
`InsightsFilmographyRowView.swift`), wired via `InsightsTabPillView.onFocused`. This was NOT
separately verified working or broken in isolation — it depends on focus ever reaching a pill at
all, which per bug 1's evidence, it currently doesn't.

Bug 3's scroll half (not the already-fixed bio-cap half) has the identical
`isScrollEnabled = false` + self-driven-scroll pattern applied to `InsightsActorView.scrollView`
(mirrors `InsightsCastListView`'s implementation). Also not independently verified — same
dependency: if the general "scroll view vetoes focus engine" theory is right, this needs the same
class of first-responder-level explicit fix as bugs 1/4, not the self-driven-scroll approach
alone.

## Open question / the actual puzzle for the next investigator

**The bug-4 (Menu) fix is architecturally airtight and mechanically simple** — a boolean
short-circuit, one new protocol conformance, no focus-engine involvement at all (Menu press
routing is pure `UIResponder` chain logic, well-understood, easy to verify by inspection). Yet
the user's LATEST report ("all the same issues") came AFTER this fix was live on a
freshly-installed, MD5-verified-correct build. **This is the most important open thread**: if the
Menu fix — which has no focus-engine ambiguity at all — genuinely still doesn't work, that
strongly suggests one of:

1. **The user did not actually retest bug 4 specifically** in that last round (they may have only
   retested 1/2/3 and lumped 4 in as "same issues" without re-checking it individually). ASK
   EXPLICITLY, ISOLATED, before assuming the Menu fix itself is wrong.
2. **`activeRailPanel` is nil or is a different, stale panel instance** at the moment Menu is
   pressed — i.e., the press-routing fix is correct, but `PlayerContainerViewController`'s
   bookkeeping of WHICH panel is active has a bug, so `panel.contentHandlesMenuPress()` is being
   called on the wrong object (or not called at all because `activeRailPanel` is nil, falling
   through to a different branch of `handleMenuButton()` — re-read that whole function,
   `PlayerContainerViewController.swift:461+`, for other early-return branches above the
   `activeRailPanel` check that could be firing first: `vm.introSkipCountdownSeconds > 0`,
   `vm.postVideoState != .hidden`, `vm.isScrubbing`, `inputCoordinator.target != nil` — the whole
   `if inputCoordinator.target == nil { ... }` gate at line ~475 wraps ALL of this logic, so if
   `inputCoordinator.target` is non-nil for some reason while the Insights panel is open, NONE of
   this code runs at all and Menu does something else entirely not yet investigated).
3. **`PlayerContainerViewController` is not actually first-responder at the moment Menu is
   pressed** — the theory has never been directly proven, only inferred from `becomeFirstResponder()`
   being called once in `viewDidAppear`. If something later steals first-responder status (a
   panel's content becoming first responder itself, e.g. a `UIScrollView` or `UITextField`
   internally), the whole first-responder theory for BOTH bugs 1 and 4 could be wrong in a subtly
   different way than diagnosed. **Recommended immediate next diagnostic**: log
   `UIResponder.isFirstResponder` on `PlayerContainerViewController` itself at the moment Menu/Up
   is pressed, to directly confirm or refute the load-bearing assumption everything else is built
   on, rather than continuing to build more fixes on top of an unverified premise.

## Diagnostic infrastructure still in place (NOT cleaned up — safe to leave, or remove first)

- `Rivulet/Views/Player/UniversalPlayerViewModel.swift:507` — one `NSLog("[InsightsDiag]
  isRailPanelOpen didSet: ...")`.
- `Rivulet/Views/Player/UIKit/InsightsTabBarView.swift` — two `NSLog("[InsightsDiag] ...")` calls
  (setup tab count/scroll state, pill-focused).
- `Rivulet/Views/Player/UIKit/PlayerInsightsPanelView.swift:226` — one `NSLog("[InsightsDiag]
  InsightsCastListView.didUpdateFocus: ...")`.
- `Rivulet/Views/Player/UIKit/InsightsPanelContainerView.swift:133` — one `NSLog("[InsightsDiag]
  Container.layout: ...")` (fires once, guarded by `didLogLayout`).

Pull these via:
```bash
xcrun simctl spawn 33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3 log show --last 5m \
  --predicate 'eventMessage CONTAINS "[InsightsDiag]"' --style compact
```

The temporary bright-red `BUILD MARKER` visible-verification hack in `InsightsTabBarView.swift`
has already been removed (confirmed the user saw it, then it was deleted).

## Environment / workflow notes for whoever picks this up

- Sim UDID: `33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3` (Apple TV 4K 3rd gen, 1080p). It has shut down
  unprompted at least twice this session — always `xcrun simctl list devices | grep 33E70EDB` to
  confirm `(Booted)` before assuming a `launch` call succeeded; a `launch` against a shutdown
  device errors loudly (`Unable to lookup in current state: Shutdown`) but can be easy to miss in
  a busy terminal.
- Build: `xcodebuild -scheme Rivulet -destination "platform=tvOS Simulator,id=33E70EDB-..." -derivedDataPath /tmp/rivulet-dd-c build`
  (Release config was used for all testing this session — no `-configuration` flag needed if
  `/tmp/rivulet-dd-c/Build/Products/Release-appletvsimulator/` already exists from a prior build;
  otherwise add `-configuration Release`).
- ALWAYS `xcrun simctl terminate 33E70EDB-... com.gstudios.rivulet` before `install` +
  `launch` on every iteration — a background/foreground cycle without a full terminate can leave
  stale in-memory VC/view state (never conclusively proven to be a factor here, but cheap
  insurance and was standard practice throughout this session).
- Bundle ID: `com.gstudios.rivulet`.
- The user drives the simulator's remote manually (Apple TV Remote via keyboard/trackpad in
  Simulator.app) — there is no reliable programmatic way found this session to simulate remote
  presses from the CLI (osascript key-code attempts were tried earlier in the broader session and
  were unreliable). All testing requires the user physically present at the simulator.
- Full test suite (`xcodebuild test -scheme Rivulet -destination "platform=tvOS
  Simulator,id=33E70EDB-..."`) was green after all 4 tasks of the tab-bar restructure (429 tests)
  — this handoff's changes have NOT been run against the full suite yet; do that before
  committing.

## Recommended next steps, in order

1. **Verify the first-responder assumption directly** (see "Open question" #3) before writing any
   more fix code — this is the single highest-leverage diagnostic available and hasn't been done
   yet.
2. **Re-test bug 4 (Menu) in isolation**, explicitly asked as its own question, not lumped with
   1/2/3 — the fix for it is the most likely of the four to actually be correct, and deserves a
   clean confirm/deny before assuming it's also broken.
3. **Re-read `handleMenuButton()` in full** for early-return branches that could prevent the
   `activeRailPanel` check from ever being reached (see "Open question" #2) — this has NOT been
   done, only the `activeRailPanel` branch itself was inspected.
4. If the first-responder theory is confirmed correct and bug 4 genuinely still fails, add
   `NSLog` directly inside `handleMenuButton()`'s `activeRailPanel` branch and inside
   `InsightsPanelContainerView.handleMenuPress()` to prove or disprove whether the call chain
   itself is even being reached, before assuming the protocol wiring has a subtler bug (e.g. a
   type-cast failure — `content as? RailPanelMenuHandling` silently returning `nil` if
   `InsightsPanelContainerView`'s protocol conformance isn't actually compiling into the vtable
   correctly for some Swift-specific reason, though this would be unusual).
5. Only after 1-4 are resolved, revisit bugs 1/2/3 with whatever corrected understanding emerges
   — the current fixes for them are built on the same theory as bug 4's fix, so if that theory
   needs revision, all three need to be revisited together, not independently.

---

## RESOLVED 2026-07-08 (commit 88731f7) — the theory above was backwards

tvOS delivers presses to the **focused view** and bubbles them **up** the responder
chain. `becomeFirstResponder()` is irrelevant while anything holds focus (proven
in-repo: `CardInfoView`'s `InfoScrollView` is a nested view whose `pressesBegan`
works in production). Every fix above was correct logic installed at a dead address:

- Bug 4: `PlayerRailPanelView.pressesBegan` consumed `.menu` and dismissed the whole
  panel before the VC's `handleMenuButton()` fix could ever run. Fixed in the panel.
- Bug 1: the applied fix consumed Up, then called `setNeedsFocusUpdate()` on the tab
  bar — ignored by UIKit because the bar does not contain the focused item. That is
  the "press vanishes, zero focus events" symptom. Fixed by driving focus from the
  container (common ancestor) via a transient preferredFocusEnvironments override.
- Bug 3 + why the container's original `pressesBegan` "never ran": nothing in the
  actor state was focusable (header non-focusable, filmography hidden until load),
  so focus fell to the panel view itself, and presses bubble up from it, never down
  into children. Header is now focusable; Up/Down clicks step the bio scroll.

Do not reuse the first-responder press-routing theory from this document.
