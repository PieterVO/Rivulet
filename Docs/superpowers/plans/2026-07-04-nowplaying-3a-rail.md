# Now Playing 3a Rail Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 2a floating focus-card chrome with the 3a bottom glass rail (metadata + five buttons + embedded scrubber), one floating-panel grammar for CC/audio/info/Up Next, timeline-first scrubbing, and the centered watery loading spinner.

**Architecture:** Evolve in place. `PlayerContainerViewController` stays host and keeps `applyChromeVisibility()` as the sole alpha writer; `PlayerProgressBarView` keeps all scrub behavior and gets the 3a timeline skin; new `PlayerRailView` + `PlayerRailPanelView`; `PlayerFocusCardView` retires after its children are extracted.

**Tech Stack:** Swift 6, UIKit on tvOS 26, Combine bindings, XCTest.

## Global Constraints

- Spec: `Docs/superpowers/specs/2026-07-04-nowplaying-3a-rail-design.md` — all pixel values are 1080p points and canonical.
- Build command (exact): `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build` — check for `** BUILD SUCCEEDED **` in output, not the pipe's exit code.
- **Commits are path-limited**: always `git commit -m "..." -- <file> <file>`; NEVER bare `git commit` and NEVER `git add -A`. Another workstream shares this repo's index — its staged/dirty files must never enter a commit. Verify with `git show --stat HEAD` after each commit.
- New/deleted Swift files under `Rivulet/` need no project.pbxproj edits (filesystem-synchronized groups). Do not touch project.pbxproj.
- tvOS traps: `UIControl.primaryActionTriggered` never fires on Select — use `pressesBegan(.select)`; consumed Menu presses must swallow BOTH began and ended phases; `UIBlurEffect` has no systemMaterial styles on tvOS — use `UIGlassEffect(style:.regular)` on tvOS 26 with `UIBlurEffect(.dark)` fallback; cross-view constraints must not activate before both views share an ancestor.
- One-clock rule in `PlayerProgressBarView`: all strip/track morph animation rides the single existing `UIView.animate` block in `update(...)`. The only sanctioned extra animations: CAAnimations on dedicated layers (spinner, skeleton shimmer) that never run concurrently with the strip morph.
- The accent gradient (fills, spinner): `#7fb8ff → #b9a3ff 45% → #ffce93 80% → #8fe9d4`.
- Preserve unchanged behaviors: shuttle grammar + jog ring, CC long-press replay, marker skip pill, ambient pause tiers, BIF reset on `itemGeneration`, `loadUpNextEpisodes`/`playEpisode`, live tech stats.

---

### Task 1: Extract shared views out of PlayerFocusCardView.swift

**Files:**
- Create: `Rivulet/Views/Player/UIKit/CardTrackListView.swift` (move `CardTrackListView` + `CardTrackRowButton`, verbatim)
- Create: `Rivulet/Views/Player/UIKit/CardInfoView.swift` (move `CardInfoView`, verbatim)
- Create: `Rivulet/Views/Player/UIKit/IrisSpinnerView.swift` (move `IrisSpinnerView`, parameterized)
- Modify: `Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift` (remove the moved classes; file still compiles with the card + `CardLoadingView`)

**Interfaces:**
- Consumes: existing classes inside PlayerFocusCardView.swift.
- Produces: `IrisSpinnerView(diameter: CGFloat = 64, stroke: CGFloat = 8)` — everything else keeps its exact current name/API. Later tasks rely on `CardTrackListView(header:tracks:selectedTrackId:showsOffRow:onSelect:)`, `CardInfoView(metadata:liveStatsProvider:)`, and the spinner init above.

- [ ] **Step 1: Move the three MARK sections verbatim** into the new files (keep every comment). In `IrisSpinnerView` replace the hardcoded 64/8/4 with init parameters:

```swift
final class IrisSpinnerView: UIView {

    private let diameter: CGFloat
    private let stroke: CGFloat
    private let gradientLayer = CAGradientLayer()
    private let ringMask = CAShapeLayer()

    init(diameter: CGFloat = 64, stroke: CGFloat = 8) {
        self.diameter = diameter
        self.stroke = stroke
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        // … gradient/mask setup exactly as today, except:
        ringMask.lineWidth = stroke
        // and the size constraints use `diameter`:
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }
    // layoutSubviews: ring inset becomes stroke/2 (was 4):
    // ringMask.path = UIBezierPath(ovalIn: square.insetBy(dx: stroke / 2, dy: stroke / 2)).cgPath
    // intrinsicContentSize: CGSize(width: diameter, height: diameter)
    // didMoveToWindow: unchanged (spin 1.4s + shimmer 2.3s + slosh 3.7s)
}
```

Everything else in the spinner (palettes, three animations, CATransaction guards) is copied unchanged.

- [ ] **Step 2: Build** (exact command above). Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Run existing tests** to prove no behavior change:
`xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd test -only-testing:RivuletTests/CardLoadingViewTests -only-testing:RivuletTests/UpNextRowStateTests -only-testing:RivuletTests/ChapterSegmentLayoutTests 2>&1 | grep -E "^\*\* TEST"` → `** TEST SUCCEEDED **`.
- [ ] **Step 4: Commit (path-limited):**
```bash
git add Rivulet/Views/Player/UIKit/CardTrackListView.swift Rivulet/Views/Player/UIKit/CardInfoView.swift Rivulet/Views/Player/UIKit/IrisSpinnerView.swift Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift
git commit -m "refactor: extract track list, info sheet, and spinner from the focus card" -- Rivulet/Views/Player/UIKit/CardTrackListView.swift Rivulet/Views/Player/UIKit/CardInfoView.swift Rivulet/Views/Player/UIKit/IrisSpinnerView.swift Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift
git show --stat HEAD   # verify: exactly these 4 files
```

### Task 2: PlayerRailView

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerRailView.swift`

**Interfaces:**
- Consumes: `TransportControlButton(icon:accessibilityLabel:diameter:)` (existing).
- Produces (Task 3/5/6 depend on these EXACT names):
  - `let skipBackButton/subtitlesButton/audioButton/infoButton/upNextButton: TransportControlButton`
  - `var onSkipBack/onSubtitles/onAudio/onInfo/onUpNext/onReplayLongPress/onNavigateDown: (() -> Void)?`
  - `func setTitle(_ title: String, eyebrow: String?)`
  - `func setMeta(rating: String?, runtime: String?, audio: String?)`
  - `func setLoading(_ loading: Bool)` — hides/shows the whole cluster
  - `func setUpNextAvailable(_ available: Bool)` — hides/shows only `upNextButton`
  - `static let railHeight: CGFloat = 260`
  - `override var preferredFocusEnvironments` → last focused button, else `skipBackButton`

- [ ] **Step 1: Write the file:**

```swift
//
//  PlayerRailView.swift
//  Rivulet
//
//  The 3a bottom glass rail: metadata block left, five round transport
//  buttons right. The scrubber (PlayerProgressBarView) is NOT a child —
//  it stays a container sibling overlaid on the rail's lower region so
//  its morph/behavior layer is untouched; this view is the glass plate
//  and the top row only.
//

import UIKit

final class PlayerRailView: UIView {

    static let railHeight: CGFloat = 260

    private enum Metrics {
        static let padV: CGFloat = 34
        static let padH: CGFloat = 42
        static let topRowGap: CGFloat = 32
        static let buttonGap: CGFloat = 20
        static let buttonDiameter: CGFloat = 74
    }

    let skipBackButton = TransportControlButton(
        icon: UIImage(systemName: "gobackward.15"), accessibilityLabel: "Skip back 15 seconds",
        diameter: Metrics.buttonDiameter)
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.buttonDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.buttonDiameter)
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info.circle"), accessibilityLabel: "Info",
        diameter: Metrics.buttonDiameter)
    let upNextButton = TransportControlButton(
        icon: UIImage(systemName: "list.and.film"), accessibilityLabel: "Up Next",
        diameter: Metrics.buttonDiameter)

    var onSkipBack: (() -> Void)?
    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onUpNext: (() -> Void)?
    var onReplayLongPress: (() -> Void)?
    var onNavigateDown: (() -> Void)?

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaRow = UIStackView()
    private let ratingChip = UILabel()
    private let runtimeLabel = UILabel()
    private let dividerLabel = UILabel()
    private let audioLabel = UILabel()
    private let cluster = UIStackView()

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        // Shadow lives on the unclipped self layer; glass clips itself.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 35
        layer.shadowOffset = CGSize(width: 0, height: 15)

        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.layer.cornerRadius = 32
        backgroundEffectView.layer.cornerCurve = .continuous
        tintView.backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 26/255, alpha: 0.5)
        tintView.clipsToBounds = true
        tintView.layer.cornerRadius = 32
        tintView.layer.cornerCurve = .continuous

        eyebrowLabel.font = .systemFont(ofSize: 23, weight: .medium)
        eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.66)

        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        ratingChip.font = .systemFont(ofSize: 17, weight: .medium)
        ratingChip.textColor = UIColor.white.withAlphaComponent(0.55)
        ratingChip.layer.borderWidth = 1
        ratingChip.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        ratingChip.layer.cornerRadius = 6
        ratingChip.layer.cornerCurve = .continuous
        ratingChip.textAlignment = .center

        for label in [runtimeLabel, dividerLabel, audioLabel] {
            label.font = .systemFont(ofSize: 20, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
        }
        dividerLabel.text = "·"
        dividerLabel.textColor = UIColor.white.withAlphaComponent(0.4)

        metaRow.axis = .horizontal
        metaRow.spacing = 14
        metaRow.alignment = .center
        [ratingChip, runtimeLabel, dividerLabel, audioLabel].forEach { metaRow.addArrangedSubview($0) }

        cluster.axis = .horizontal
        cluster.spacing = Metrics.buttonGap
        cluster.alignment = .center
        [skipBackButton, subtitlesButton, audioButton, infoButton, upNextButton].forEach {
            cluster.addArrangedSubview($0)
        }

        [backgroundEffectView, tintView, eyebrowLabel, titleLabel, metaRow, cluster].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padV),
            eyebrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padH),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cluster.leadingAnchor, constant: -Metrics.topRowGap),

            metaRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            metaRow.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),

            ratingChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            ratingChip.heightAnchor.constraint(equalToConstant: 28),

            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padH),
            cluster.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])

        skipBackButton.onPress = { [weak self] in self?.onSkipBack?() }
        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        upNextButton.onPress = { [weak self] in self?.onUpNext?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func setTitle(_ title: String, eyebrow: String?) {
        titleLabel.text = title
        eyebrowLabel.text = eyebrow
        eyebrowLabel.isHidden = eyebrow == nil
    }

    func setMeta(rating: String?, runtime: String?, audio: String?) {
        ratingChip.text = rating
        ratingChip.isHidden = rating == nil
        runtimeLabel.text = runtime
        runtimeLabel.isHidden = runtime == nil
        audioLabel.text = audio
        audioLabel.isHidden = audio == nil
        dividerLabel.isHidden = runtime == nil || audio == nil
    }

    func setLoading(_ loading: Bool) {
        cluster.isHidden = loading
    }

    func setUpNextAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
    }

    // MARK: - Focus

    private weak var lastFocusedButton: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedButton, !last.isHidden { return [last] }
        return [skipBackButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedButton = next
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .downArrow {
            if let focused = UIScreen.main.focusedView, focused.isDescendant(of: cluster) {
                onNavigateDown?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
```

- [ ] **Step 2: Build.** The view is not hosted yet; it just compiles. Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Commit (path-limited):** `git commit -m "feat: 3a glass rail — metadata block and five-button cluster" -- Rivulet/Views/Player/UIKit/PlayerRailView.swift` (after `git add` of the same path). Verify `git show --stat HEAD`.

### Task 3: Rehost the chrome around the rail

**Files:**
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`

**Interfaces:**
- Consumes: everything Task 2 produces; `IrisSpinnerView(diameter:stroke:)`; existing VM publishers (`$showControls`, `$pausePresentation`, `$playbackState`, `$isScrubbing`, `$currentTime`, `$duration`, `$itemGeneration`, `$subtitleTracks`, `$showSkipButton`, `$upNextEpisodes`); `progressBar.setSkeleton/setPausedDim/update/resetFilmstrip`; `vm.title`, `vm.subtitle`, `vm.metadata` (contentRating, duration, audio display via the same reads `PlayerFocusCardView` uses today — port its meta-line composition).
- Produces (later tasks rely on): container properties `rail: PlayerRailView?`, `loadingSpinner`, `loadingLabel`, `pauseIndicator`, `pausedDimView`; `progressBarLeading/progressBarTrailing: NSLayoutConstraint?` (constants ±132 at rest); `applyChromeVisibility()` with tiers `chromeVisible` (scrim+progressBar) / `railVisible` (rail, pause indicator) / plus loading extras; rail button callbacks wired (CC/audio/info/upNext left as no-op closures with `// wired in Task 5/6` markers; skipBack → `Task { await vm.seekRelative(by: -15) }`; replay long-press → `vm.replayWithCaptions()`; onNavigateDown → existing exit-to-scrub handler).

- [ ] **Step 1:** In `viewDidLoad`'s chrome block: delete the `focusCard` creation/constraints, the `cardPanelFocusGuide` (property, creation, and its `didUpdateFocus` flipper — the whole override goes if it only serves the guide), and the `upNextPanel` creation → replace with `upNextPanel?.isHidden = true` removal entirely (panel view is rebuilt as content in Task 6; delete the property, its constraints, its `$upNextEpisodes` sink body becomes: keep the sink but only forward to `rail?.setUpNextAvailable(!episodes.isEmpty && vm.metadata.type == "episode")` plus stash `episodes` in a new container property `upNextEpisodesCache: [PlexMetadata]` for Task 6). Add:

```swift
let rail = PlayerRailView()
view.addSubview(rail)
rail.translatesAutoresizingMaskIntoConstraints = false
let progressLeading = bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 132)
let progressTrailing = bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -132)
NSLayoutConstraint.activate([
    rail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
    rail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
    rail.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
    rail.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),

    progressLeading, progressTrailing,
    bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -118), // 84 + 34
])
progressBarLeading = progressLeading
progressBarTrailing = progressTrailing
```

The bar must be added as a subview AFTER the rail (z-order: rail glass below, bar above). The skip pill re-anchors: `pill.bottomAnchor.constraint(equalTo: rail.topAnchor, constant: -28)`, trailing unchanged.

- [ ] **Step 2:** Add the paused/loading overlays in `viewDidLoad`:

```swift
// Flat dim under the rail while paused at the live frame.
let dim = UIView()
dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
dim.alpha = 0
view.insertSubview(dim, belowSubview: chromeScrim)   // full-frame constraints

// Top-left pause indicator: two bars + "Paused · Xm left".
let indicator = UIStackView()  // horizontal, spacing 12, alignment .center
// two 7×24 white bars (UIView, cornerRadius 2) in their own 6pt-gap HStack,
// plus pauseTimeLabel: 22pt medium, white@0.6
// pinned top 44 / leading 64
indicator.alpha = 0

// Centered loading spinner + label.
let spinner = IrisSpinnerView(diameter: 110, stroke: 9)
let loadingLabel = UILabel()
loadingLabel.font = .systemFont(ofSize: 22, weight: .medium)
loadingLabel.textColor = UIColor.white.withAlphaComponent(0.5)
// text set in the playbackState sink; uppercase, kern 22 * 0.14
// spinner centerX = view.centerX; centerY = view.topAnchor + 0.42 * view.height
//   (use NSLayoutConstraint(item:attribute:.centerY relatedBy:.equal toItem:view
//    attribute:.bottom multiplier:0.42 constant:0))
// label: top = spinner.bottom + 28, centerX = spinner.centerX
spinner.isHidden = true
loadingLabel.isHidden = true
```

- [ ] **Step 3:** Rewrite `bindChrome` chrome bindings (the progress-bar update sink, filmstripProvider, itemGeneration reset, skip pill, subtitleTracks → `rail.subtitlesButton` enabled-look stays as-is via `setSubtitlesEnabled` equivalent: keep the existing alpha treatment by porting the old card binding to `rail.subtitlesButton.alpha`):
  - metadata apply: `rail.setTitle(vm.title, eyebrow: vm.subtitle)` + meta line composed exactly like the old card's meta row (port that code) — re-applied on `$itemGeneration`.
  - `$playbackState` merged sink: `rail.setLoading(isLoading)`, `progressBar.setSkeleton(isLoading)`, `progressBar.setPausedDim(state == .paused)`, spinner/label `isHidden = !isLoading` (+ label text from quality: port `PlayerInfoPopupView`-style reads — `videoStream.isDolbyVision → "DOLBY VISION"`, else `isHDR → "HDR10"`, prefix `4K` when `media.videoResolution == "4k"`; fallback plain `"LOADING"`), pause indicator label `"Paused · \(Int(max(0, vm.duration - vm.currentTime) / 60))m left"`, then `applyChromeVisibility()`.
  - `$isScrubbing` (via the existing time sink): animate `progressBarLeading.constant = scrubbing ? 96 : 132` / trailing `∓96/132` alongside `applyChromeVisibility()` in a 0.15s `UIView.animate` with `view.layoutIfNeeded()`.
- [ ] **Step 4:** Rewrite `applyChromeVisibility()`:

```swift
private func applyChromeVisibility() {
    guard let vm = viewModel else { return }
    let ambient = vm.pausePresentation != .frame
    let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
    let chromeVisible = (vm.showControls || vm.isScrubbing) && !ambient
    let railVisible = chromeVisible && !vm.isScrubbing
    let paused = vm.playbackState == .paused && !ambient

    let targets: [(UIView?, CGFloat)] = [
        (chromeScrim, chromeVisible ? 1 : 0),
        (progressBar, chromeVisible ? 1 : 0),
        (rail, railVisible ? 1 : 0),
        (skipPill, railVisible && !isLoading ? 1 : 0),
        (pauseIndicator, paused ? 1 : 0),
        (pausedDimView, paused ? 1 : 0),
        (loadingSpinner, isLoading && !ambient ? 1 : 0),
        (loadingLabel, isLoading && !ambient ? 1 : 0),
    ]
    guard targets.contains(where: { view, alpha in view.map { abs($0.alpha - alpha) > 0.01 } == true }) else { return }
    UIView.animate(withDuration: 0.25) {
        for (view, alpha) in targets { view?.alpha = alpha }
    }
}
```

(Spinner/label use alpha via the applier AND `isHidden` from the state sink so they never intercept focus. The Task 5 panel adds its own line here.)

- [ ] **Step 5:** Menu unwind + focus: `preferredFocusEnvironments` controls-focus branch returns `[rail]`; delete the card-mode step from `dismiss()`/`handleMenuButton()` (panel step returns in Task 5). Wire `rail.onNavigateDown` to the old card's handler body (exitControlsFocus + `.scrubRelative(seconds: 0)` from `.irPress`).
- [ ] **Step 6: Build; fix all references to the deleted focusCard/guide/upNextPanel** (the compiler is the checklist — `PlayerFocusCardView` itself still compiles standalone). Expected `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit (path-limited):** `git commit -m "feat: rehost chrome on the 3a rail — pause indicator, centered spinner, scrubber inside the rail" -- Rivulet/Views/Player/PlayerContainerViewController.swift`. Verify stat.

### Task 4: Timeline-first scrub reskin

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift`

**Interfaces:**
- Consumes: existing internals (`stripContainer`, `segmentLayout`, `ChapterSegmentLayout`, `calloutLabel`, `playheadThread`, `handleView`/`handleRing`, `dimOverlay`, `trackHeightConstraint`, `update(...)`).
- Produces: same public API (`update(...)`, `setSkeleton(_:)`, `setPausedDim(_:)`, `resetFilmstrip()`, `filmstripProvider`). No signature changes.

READ THE WHOLE FILE FIRST. Changes, respecting the one-clock rule (all inside the existing animate block / existing layout passes):

- [ ] **Step 1: Geometry + knob.** `Metrics.stripHeight` 120 → **130**; segment container corner radius 12 → **14**; rest knob 24 → **26pt** (circle only — DELETE the 14×46 tall-bar morph: while the strip is open, `handleView`/`handleRing` are hidden entirely).
- [ ] **Step 2: Playhead bar** replaces the thread + strip playhead line: one white view, **8pt wide, radius 6**, from `stripTop − 14` to `stripBottom + 14`, `layer.shadowColor` white-blue glow (`shadowColor = UIColor(red: 180/255, green: 205/255, blue: 1, alpha: 1).cgColor, shadowOpacity 0.6, shadowRadius 13`) plus a 4pt black@0.4 ring drawn as a border-colored outer view or `shadowPath` — simplest: an 8pt white bar with `layer.borderWidth = 0` on top of a 16pt-wide black@0.4 rounded backing view. Position both in `layoutStripOverlay` at the seek x. Remove `playheadLine` and `playheadThread` usages (delete the views).
- [ ] **Step 3: Bottom progress line.** New 5pt strip pinned inside the strip's bottom edge, full ribbon width: track `white@0.12`, fill = `AccentGradientView` width = seek fraction × ribbon width. Laid out in `layoutStripOverlay`; hidden when strip closed.
- [ ] **Step 4: Oversized readout** replaces the chip: delete `PaddedChipLabel` styling usage; `calloutLabel` becomes two stacked labels (a small container view laid out frame-wise like the old callout): eyebrow `CHAPTER <n> · <NAME>` 16pt semibold uppercase kern 16*0.12 `white@0.5` (hidden when no named chapter — n is the same 1-based ordinal used today), timecode 50pt bold `monospacedDigitSystemFont` white. Keep the exact clamping logic. While the strip is open, hide `endsAtLabel` and `currentTimeLabel`/`remainingTimeLabel` keep showing seek/remaining (already the case).
- [ ] **Step 5: Skeleton shimmer.** In `setSkeleton(true)`: add a `CAGradientLayer` (horizontal, `[clear, white@0.22, clear]`, locations animating `[-0.4, -0.2, 0] → [1, 1.2, 1.4]`, duration 1.8, repeat infinite) masked to the track's rounded bounds; remove the layer + animation in `setSkeleton(false)`. This is a dedicated-layer CAAnimation sanctioned by the global constraints (skeleton never coexists with the strip morph — `update` is guarded by `isSkeleton`).
- [ ] **Step 6: Run tests** (`ChapterSegmentLayoutTests` + full player suites as in Task 1 Step 3) → `** TEST SUCCEEDED **`; build → SUCCEEDED. Fix `CardLoadingViewTests` ONLY if it references the removed chip (it should not).
- [ ] **Step 7: Commit (path-limited):** `git commit -m "feat: timeline-first scrub — 130pt ribbon, glowing playhead bar, oversized readout, skeleton shimmer" -- Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift`.

### Task 5: PlayerRailPanelView + CC/audio/info wiring

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerRailPanelView.swift`
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`

**Interfaces:**
- Consumes: `CardTrackListView`, `CardInfoView` (Task 1 files); `rail` + buttons (Task 3).
- Produces: 
  - `PlayerRailPanelView.present(content: UIView, width: CGFloat, in container: UIView, aboveRail rail: UIView, towards button: UIView) -> PlayerRailPanelView` (static factory that builds, adds, animates)
  - `func dismissPanel()` / `var onDismiss: (() -> Void)?`
  - Container: `private var activeRailPanel: PlayerRailPanelView?`, `private weak var railPanelSourceButton: UIView?`; unwind step `if let panel = activeRailPanel { panel.dismissPanel(); return }` in BOTH `dismiss()` and `handleMenuButton()` (position: after scrub-cancel, before controls-focus exit); `applyChromeVisibility` force-closes the panel when `!railVisible`.

- [ ] **Step 1: Write the panel.** Glass per spec (radius 20 continuous, tint `rgba(16,18,24,.5)` over UIGlassEffect/.dark fallback, border 1pt `rgba(143,233,212,.5)`, halo = `layer.shadowColor` teal `rgba(143,233,212,1)` opacity 0.18 radius 3 spread via shadowPath 3pt outset, plus a second drop shadow using a backing view — copy the two-layer shadow approach from `PlayerUpNextPanelView`'s current implementation). Content pinned with 20pt padding, `heightAnchor.constraint(lessThanOrEqualToConstant: 560)`. Constraints: `bottomAnchor = rail.topAnchor - 24`; trailing = min(button.trailing projected into container, rail.trailing − 42) — implement as `panel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(132))` for simplicity and note it; width per call (452 tracks/up-next, 480 info). Presentation animation: start `alpha 0, transform = translationY(12)` → animate 0.2s to identity. Focus: `preferredFocusEnvironments = [content]`; `shouldUpdateFocus` fences descendants while in window; Menu `pressesBegan` → `dismissPanel()`, `pressesEnded` swallows `.menu`; `canBecomeFocused = true` (info content scrolls by focus). Dismiss: animate out 0.15s, `removeFromSuperview`, fire `onDismiss`.
- [ ] **Step 2: Container wiring.** Replace the three no-op closures:

```swift
rail.onSubtitles = { [weak self] in
    guard let self, let vm = self.viewModel else { return }
    self.presentRailPanel(
        content: CardTrackListView(header: "Subtitles", tracks: vm.subtitleTracks,
                                   selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
                                   onSelect: { [weak self] id in
                                       vm.selectSubtitleTrack(id: id)
                                       self?.activeRailPanel?.dismissPanel()
                                   }),
        width: 452, from: rail.subtitlesButton)
}
// audio: same shape (showsOffRow: false, selectAudioTrack, width 452)
// info:  CardInfoView(metadata: vm.metadata, liveStatsProvider: { [weak vm] in vm?.aetherPlayer?.liveStats() }), width 480
```

with a private helper:

```swift
private func presentRailPanel(content: UIView, width: CGFloat, from button: UIView) {
    guard let rail else { return }
    activeRailPanel?.dismissPanel()
    railPanelSourceButton = button
    let panel = PlayerRailPanelView.present(content: content, width: width,
                                            in: view, aboveRail: rail, towards: button)
    panel.onDismiss = { [weak self] in
        self?.activeRailPanel = nil
        self?.setNeedsFocusUpdate(); self?.updateFocusIfNeeded()
    }
    activeRailPanel = panel
    view.setNeedsFocusUpdate(); view.updateFocusIfNeeded()
}
```

`preferredFocusEnvironments`: `if let panel = activeRailPanel, panel.window != nil { return [panel] }` before the `[rail]` branch; after dismiss the rail's `lastFocusedButton` restores landing (source button already recorded by the rail's own didUpdateFocus). Add the unwind step and the `applyChromeVisibility` force-close (`if !railVisible { activeRailPanel?.dismissPanel() }` before the guard).
- [ ] **Step 3: Build → SUCCEEDED. Commit (path-limited):** both files, `git commit -m "feat: shared rail panel — CC, audio, and info float above the rail" -- Rivulet/Views/Player/UIKit/PlayerRailPanelView.swift Rivulet/Views/Player/PlayerContainerViewController.swift`.

### Task 6: Up Next as the fifth panel

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift` (gut to list content; rename class `UpNextListView`)
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`

**Interfaces:**
- Consumes: Task 5 `presentRailPanel`; Task 3's `upNextEpisodesCache` + `rail.setUpNextAvailable`; existing `UpNextRowState`, `vm.playEpisode(_:)`.
- Produces: `UpNextListView(episodes:currentRatingKey:seasonNumber:serverURL:authToken:onSelect:)` — the header (`UP NEXT · SEASON <n>`) + scrollable rows exactly as they exist today (row styling, states, thumb loading, image-task cancellation, initial focus on the `.upNext` row via `preferredFocusEnvironments`). All collapsed-card chrome, glass, focus-expansion `didUpdateFocus`, and self-sizing width logic DELETED (the panel presenter owns chrome now).

- [ ] **Step 1:** Rework the file: keep `UpNextRowButton` (rename file-internal references only), keep row building/states/scroll-to-current; the view's init takes the full data set and an `onSelect: (PlexMetadata) -> Void`; drop `setEpisodes` statefulness (a fresh instance is built per presentation).
- [ ] **Step 2:** Container: `rail.onUpNext = { present UpNextListView(episodes: upNextEpisodesCache, …, onSelect: { episode in vm.exitControlsFocus(); Task { await vm.playEpisode(episode) }; self.activeRailPanel?.dismissPanel() }) via presentRailPanel(width: 452, from: rail.upNextButton) }`. The `$upNextEpisodes` sink (Task 3) already drives `setUpNextAvailable` + cache; add: if the up-next panel is open when the sink fires, dismiss it (stale list).
- [ ] **Step 3:** Build → SUCCEEDED; run `UpNextRowStateTests` → SUCCEEDED. **Commit (path-limited):** both files, `git commit -m "feat: Up Next is a rail button — season list rides the shared panel" -- Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift Rivulet/Views/Player/PlayerContainerViewController.swift`.

### Task 7: Delete the focus card; spinner tests; docs

**Files:**
- Delete: `Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift`, `RivuletTests/Unit/CardLoadingViewTests.swift`
- Create: `RivuletTests/Unit/IrisSpinnerViewTests.swift`
- Modify: `CLAUDE.md`, `Docs/RIVULET_PLAYER.md` (rail/panel naming — surgical, only lines naming the deleted/renamed types)

**Interfaces:** none new.

- [ ] **Step 1: Failing test first** (spinner file exists but the test asserts the new parameterization paths):

```swift
import XCTest
@testable import Rivulet

@MainActor
final class IrisSpinnerViewTests: XCTestCase {

    func test_defaultAndLoadingSizes_stayCircular() {
        for (diameter, stroke) in [(CGFloat(64), CGFloat(8)), (CGFloat(110), CGFloat(9))] {
            let spinner = IrisSpinnerView(diameter: diameter, stroke: stroke)
            spinner.layoutIfNeeded()
            XCTAssertEqual(spinner.bounds.width, diameter)
            XCTAssertEqual(spinner.bounds.height, diameter)
        }
    }

    func test_stretchingHost_cannotDistortTheRing() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let spinner = IrisSpinnerView(diameter: 110, stroke: 9)
        host.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutIfNeeded()
        XCTAssertEqual(spinner.bounds.size, CGSize(width: 110, height: 110))
    }
}
```

- [ ] **Step 2:** `git rm` the two deleted files; run the new tests + full build; grep `PlayerFocusCardView\|CardLoadingView\|cardPanelFocusGuide` across `Rivulet/ RivuletTests/` → only provenance comments may remain (reword any that misdescribe current architecture).
- [ ] **Step 3:** Docs: CLAUDE.md player sections — replace focus-card/Up-Next-panel naming with `PlayerRailView`, `PlayerRailPanelView`, `UpNextListView` (Key Files table rows included). Same for `Docs/RIVULET_PLAYER.md` (edit on disk; it is gitignored — do not commit it).
- [ ] **Step 4: Commit (path-limited):** `git commit -m "chore: delete focus card; spinner tests; docs name the rail chrome" -- Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift RivuletTests/Unit/CardLoadingViewTests.swift RivuletTests/Unit/IrisSpinnerViewTests.swift CLAUDE.md`.

### Task 8: Verification pass

**Files:** none (verification only).

- [ ] **Step 1:** Full clean build + entire test suite: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build test` → BUILD + TEST SUCCEEDED (check the strings, not exit codes).
- [ ] **Step 2:** Install + launch on the booted Apple TV simulator (`xcrun simctl install 33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3 /tmp/rivulet-cli-dd/Build/Products/Debug-appletvsimulator/Rivulet.app && xcrun simctl launch 33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3 com.gstudios.rivulet`).
- [ ] **Step 3:** Hand the user the walk-through checklist: rail states 1–4, five buttons + panel grammar (open/select/Menu), timeline scrub on chaptered content (183532), movie hides the Up Next button, paused indicator + ambient tiers, loading spinner + shimmer skeleton, shuttle/replay/markers regression pass.
- [ ] **Step 4:** Ledger updates in `.superpowers/sdd/nowplaying-3a-progress.md`; update the branch memory.

---

## Execution notes

- Ledger: `.superpowers/sdd/nowplaying-3a-progress.md` (create at Task 1).
- Reviewer gates per task as in the 2a wave; final whole-branch review covers `dfb247c..HEAD`.
- The 2a walk-through lesson stands: reviewers must verify constraint activation ordering (views in hierarchy before cross-view constraints) and that every state was CONSTRUCTED at least once by a test or the verification pass.
