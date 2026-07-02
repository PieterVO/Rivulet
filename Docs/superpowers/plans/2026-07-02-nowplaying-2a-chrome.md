# Now Playing 2a Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the tvOS player overlay to the "2a / The Final" layout: persistent bottom-left focus card, right-side Up Next panel, height-locked accent-gradient scrubber, chapter-segmented BIF filmstrip, and a real loading state — with zero loss of shipped behavior (shuttle, replay, ambient pause, markers, tech stats).

**Architecture:** Restructure in place on `feature/nowplaying-redesign`. `PlayerContainerViewController` stays the host and gains the new chrome as direct subviews; `PlayerProgressBarView` is kept and restyled; two new views (`PlayerFocusCardView`, `PlayerUpNextPanelView`) absorb the transport bar's and popups' responsibilities; `PlayerTransportBarView` + the anchored popup system are deleted at the end.

**Tech Stack:** Swift 6, UIKit on tvOS 26, Combine bindings to `UniversalPlayerViewModel`, XCTest for pure-logic helpers.

Spec: `Docs/superpowers/specs/2026-07-02-nowplaying-2a-chrome-design.md`. Design reference: `Docs/design_handoff_now_playing/README.md` + `screenshots/*.png`.

## Global Constraints

- All pixel values are 1080p points used literally: card `left 96, width 720, height 520 (vertically centered)`; panel `right 80, width 470, same band`; scrubber `left 96 / right 96 / bottom 140`; filmstrip height `120`; corner radius card `34`, strip `12`.
- Card glass `rgba(16,18,24,.42)` on a dark blur, border 1pt `white@0.1`. Panel glass `rgba(14,17,23,.55)`, focus accent `rgba(143,233,212,.55)`. Accent gradient `#7fb8ff → #b9a3ff @45% → #ffce93 @80% → #8fe9d4`.
- tvOS has NO `.systemMaterial` blur styles — use `UIBlurEffect(style: .dark)` (or `UIGlassEffect` behind `#available(tvOS 26.0, *)`, matching `TransportControlButton`).
- The player must build after every task. Build command (scratch DerivedData — never share with the open Xcode):
  `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build`
- New files under `Rivulet/` and `RivuletTests/` auto-join their targets (filesystem-synchronized groups) — do NOT edit `project.pbxproj`.
- No feature cuts: shuttle grammar, jog ring, replay (CC long-press), marker skip pill, ambient pause, live tech stats, BIF filmstrip all survive.
- tvOS UIControl trap: `.primaryActionTriggered` does NOT fire on Select — handle `pressesBegan` with `press.type == .select` (see `TransportControlButton`).
- One-clock rule for the progress bar: all strip/track morphs ride the single `UIView.animate` block in `update(...)`. No second animator.
- Commit after every task (local only — do NOT push).

---

### Task 1: Strip focus-debug logging, keep the real input fixes

The working tree contains uncommitted changes: real fixes (input-mirror swallowing, Menu ended-phase handling, popup focus fences) entangled with `[FocusDbg]` NSLog debugging. Keep every behavior change; delete every debug log line.

**Files:**
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`
- Modify: `Rivulet/Views/Player/UIKit/AnchoredPopupPresenting.swift`
- Modify: `Rivulet/Views/Player/UIKit/PlayerTrackPopupView.swift`
- Modify: `Rivulet/Views/Player/UIKit/TransportControlButton.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerView.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a clean baseline commit; all `NSLog("[FocusDbg]...` lines gone; behavior changes retained.

- [ ] **Step 1: Remove every `[FocusDbg]` NSLog**

Search: `grep -rn "FocusDbg" Rivulet/` — expect ~12 hits. Delete each `NSLog` statement (and any now-empty `if isFocused { }` block in `TransportControlButton.didUpdateFocus`). Do NOT remove:
- `PlayerContainerViewController.pressesEnded` — the new Menu comment + unconditional `return` for `.menu`.
- `PlayerInfoPopupView` / `PlayerTrackPopupView` — `shouldUpdateFocus` fences and `pressesEnded` Menu swallows.
- `UniversalPlayerView.swift` `RemoteInputHandler` — the keyboard select-mirror swallow and `.back` mirror swallow (keep the comments, drop only the NSLogs).

- [ ] **Step 2: Verify no debug logging remains**

Run: `grep -rn "FocusDbg" Rivulet/` — expected: no output.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add -A Rivulet/
git commit -m "fix: swallow keyboard/controller input mirrors in controls focus; harden popup focus fences"
```

---

### Task 2: PlayerFocusCardView — glass card with metadata mode

New persistent bottom-left card. This task builds only the metadata mode (series line, title, meta row, controls row) and its focus behavior; in-card panels come in Task 6, loading in Task 7. The view compiles standalone; it is hosted in Task 3.

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift`
- Modify: `Rivulet/Views/Player/UIKit/TransportControlButton.swift` (configurable diameter)

**Interfaces:**
- Consumes: `TransportControlButton(icon:accessibilityLabel:diameter:)` (added here), `UniversalPlayerViewModel` published state (bound by the container in Task 3 — the card itself is VM-free and callback-driven).
- Produces (used by Tasks 3/6/7/9):
  - `final class PlayerFocusCardView: UIView`
  - `var onPlayPause: (() -> Void)?`, `var onSkipBack: (() -> Void)?`, `var onSubtitles: (() -> Void)?`, `var onAudio: (() -> Void)?`, `var onInfo: (() -> Void)?`, `var onReplayLongPress: (() -> Void)?`, `var onNavigateDown: (() -> Void)?`
  - `func setTitle(_ title: String, seriesLine: String?, metaLine: String?)`
  - `func setPaused(_ paused: Bool)` (Resume/Pause pill label + `⏸ Paused` indicator line)
  - `func setSubtitlesEnabled(_ enabled: Bool)` (hides CC when no subtitle tracks)
  - `let resumeButton: PlayerPrimaryButton` (focus landing target)
  - `static let cardWidth: CGFloat = 720`, `static let cardHeight: CGFloat = 520`

- [ ] **Step 1: Make TransportControlButton diameter configurable**

In `TransportControlButton.swift`, replace the static diameter usage:

```swift
final class TransportControlButton: UIControl {

    static let diameter: CGFloat = 64
    private let diameter: CGFloat
    ...
    init(icon: UIImage?, accessibilityLabel: String, diameter: CGFloat = TransportControlButton.diameter) {
        self.diameter = diameter
        ...
        backgroundEffectView.layer.cornerRadius = diameter / 2
        ...
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            ...
```

(The icon symbol config stays 25pt — correct for both 64 and 72.)

- [ ] **Step 2: Write PlayerFocusCardView**

```swift
//
//  PlayerFocusCardView.swift
//  Rivulet
//
//  Persistent bottom-left focus card for the 2a Now Playing chrome.
//  Fixed 720×520 glass frame that never moves or resizes; only its inner
//  content swaps between modes (metadata now; tracks/info in Task 6,
//  loading in Task 7). Metadata mode: series line, large title, meta row,
//  flexible spacer, controls row (Resume pill + round buttons) pinned to
//  the bottom.
//

import UIKit

final class PlayerFocusCardView: UIView {

    static let cardWidth: CGFloat = 720
    static let cardHeight: CGFloat = 520

    private enum Metrics {
        static let cornerRadius: CGFloat = 34
        static let paddingV: CGFloat = 46
        static let paddingH: CGFloat = 48
        static let roundButtonDiameter: CGFloat = 72
    }

    // MARK: - Callbacks (wired by PlayerContainerViewController)

    var onPlayPause: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onReplayLongPress: (() -> Void)?
    /// Down pressed while a card control is focused and focus cannot move
    /// (nothing focusable below the card) — the container enters seek mode.
    var onNavigateDown: (() -> Void)?

    // MARK: - Chrome

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()

    // MARK: - Metadata mode content

    private let pausedLabel = UILabel()
    private let seriesLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    let resumeButton = PlayerPrimaryButton()
    let skipBackButton = TransportControlButton(
        icon: UIImage(systemName: "gobackward.15"), accessibilityLabel: "Skip back 15 seconds",
        diameter: Metrics.roundButtonDiameter)
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.roundButtonDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.roundButtonDiameter)
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info"), accessibilityLabel: "Info",
        diameter: Metrics.roundButtonDiameter)
    private let controlsRow = UIStackView()
    private let metadataContainer = UIView()

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupChrome()
        setupMetadataContent()
        wireButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupChrome() {
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        clipsToBounds = true

        tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.42)

        [backgroundEffectView, tintView, metadataContainer].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            heightAnchor.constraint(equalToConstant: Self.cardHeight),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            metadataContainer.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.paddingV),
            metadataContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.paddingH),
            metadataContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.paddingH),
            metadataContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.paddingV),
        ])
    }

    private func setupMetadataContent() {
        pausedLabel.text = "⏸ Paused"
        pausedLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        pausedLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        pausedLabel.isHidden = true

        seriesLabel.font = .systemFont(ofSize: 23, weight: .medium)
        seriesLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        // −0.015em tracking, 1.05 line height applied via attributed text in setTitle.

        metaLabel.font = .systemFont(ofSize: 21, weight: .medium)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        controlsRow.axis = .horizontal
        controlsRow.spacing = 18
        controlsRow.alignment = .center
        [resumeButton, skipBackButton, subtitlesButton, audioButton, infoButton].forEach {
            controlsRow.addArrangedSubview($0)
        }

        [pausedLabel, seriesLabel, titleLabel, metaLabel, controlsRow].forEach {
            metadataContainer.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            pausedLabel.topAnchor.constraint(equalTo: metadataContainer.topAnchor),
            pausedLabel.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),

            seriesLabel.topAnchor.constraint(equalTo: pausedLabel.bottomAnchor, constant: 8),
            seriesLabel.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            seriesLabel.trailingAnchor.constraint(lessThanOrEqualTo: metadataContainer.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: seriesLabel.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metadataContainer.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            metaLabel.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: metadataContainer.trailingAnchor),

            controlsRow.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            controlsRow.bottomAnchor.constraint(equalTo: metadataContainer.bottomAnchor),
        ])
    }

    private func wireButtons() {
        resumeButton.onPress = { [weak self] in self?.onPlayPause?() }
        skipBackButton.onPress = { [weak self] in self?.onSkipBack?() }
        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
    }

    // MARK: - Content API

    func setTitle(_ title: String, seriesLine: String?, metaLine: String?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.05
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white,
            .kern: 48 * -0.015,
            .paragraphStyle: paragraph,
        ])
        seriesLabel.text = seriesLine
        seriesLabel.isHidden = seriesLine == nil
        metaLabel.text = metaLine
        metaLabel.isHidden = metaLine == nil
    }

    func setPaused(_ paused: Bool) {
        pausedLabel.isHidden = !paused
        resumeButton.setTitle(paused ? "Resume" : "Pause",
                              icon: UIImage(systemName: paused ? "play.fill" : "pause.fill"))
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        subtitlesButton.isHidden = !enabled
    }

    // MARK: - Focus

    /// Landing point when the container routes controls-focus here; last
    /// focused control wins after the first landing (popup-return parity).
    private weak var lastFocusedControl: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedControl, !last.isHidden { return [last] }
        return [resumeButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedControl = next
        }
    }

    /// Nothing focusable sits below the card, so a Down press with a card
    /// control focused is delivered here (focus can't move). Right/left/up
    /// are left to the focus engine (right walks the controls row, then
    /// exits toward the Up Next panel).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .downArrow {
            onNavigateDown?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - Primary pill button

/// White Resume/Pause pill: solid white fill, near-black content, subtle
/// glow. Focus scales it up slightly (the fill is already white at rest,
/// per the 2a mock — focus is shown by scale + stronger glow).
final class PlayerPrimaryButton: UIControl {

    var onPress: (() -> Void)?
    private let label = UILabel()
    private let iconView = UIImageView()
    private let row = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .white
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor(red: 180/255, green: 205/255, blue: 1.0, alpha: 1).cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 20
        layer.shadowOffset = .zero

        label.font = .systemFont(ofSize: 25, weight: .bold)
        label.textColor = UIColor(red: 6/255, green: 7/255, blue: 11/255, alpha: 1)
        iconView.tintColor = UIColor(red: 6/255, green: 7/255, blue: 11/255, alpha: 1)
        iconView.contentMode = .center

        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)

        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 34),
        ])
        setTitle("Resume", icon: UIImage(systemName: "play.fill"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, icon: UIImage?) {
        label.text = title
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        iconView.image = icon?.applyingSymbolConfiguration(config)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.layer.shadowOpacity = isFocused ? 0.5 : 0.28
        }, completion: nil)
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift Rivulet/Views/Player/UIKit/TransportControlButton.swift
git commit -m "feat: focus card view with metadata mode and primary pill (2a chrome)"
```

---

### Task 3: Rehost the chrome in PlayerContainerViewController

Replace the transport bar with the new chrome: focus card (bottom-left band), progress bar as a direct child at locked geometry, left-readability scrim, floating skip pill. Move all the bar's bindings into the container. Relocate the ambient-pause title logo into the SwiftUI ambient layer (the whole UIKit chrome now fades during ambient). Temporarily anchor the existing popups to the card's buttons (replaced by in-card modes in Task 6).

**Files:**
- Create: `Rivulet/Views/Player/UIKit/SkipPillButton.swift` (extracted from PlayerTransportBarView, `private` → `internal`)
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerView.swift` (ambient logo; `ambientBackdropView`)

**Interfaces:**
- Consumes: `PlayerFocusCardView` (Task 2), `PlayerProgressBarView` (existing), `AnchoredPopupPresenting.present(in:anchoredTo:)` (existing, temporary), VM: `$showControls, $controlsFocusActive, $currentTime/$duration/$isScrubbing/$scrubTime/$wheelScrubbing, $itemGeneration, $showSkipButton, $pausePresentation, $subtitleTracks, $playbackState, subtitle, title, metadata, togglePlayPause(), seekRelative(by:), replayWithCaptions(), selectSubtitleTrack(id:), selectAudioTrack(id:), currentSubtitleTrackId, currentAudioTrackId, aetherPlayer?.liveStats(), skipActiveMarker(), skipButtonLabel, filmstripImages(times:maxPixelWidth:), exitControlsFocus()`, `inputCoordinator.handle(action:source:)`.
- Produces (relied on by Tasks 6/7/9):
  - Container properties: `private var focusCard: PlayerFocusCardView?`, `private var progressBar: PlayerProgressBarView?`, `private var skipPill: SkipPillButton?`, `private var activePopup: (any AnchoredPopupPresenting)?`
  - `private func setChromeHidden(_ hidden: Bool, animated: Bool)` — drives card/scrubber/pill (and later panel) alpha as one unit.
  - Menu unwind + `preferredFocusEnvironments` now reference `focusCard` instead of `transportBar`.

- [ ] **Step 1: Extract SkipPillButton to its own file**

Create `Rivulet/Views/Player/UIKit/SkipPillButton.swift`; move the `SkipPillButton` class out of `PlayerTransportBarView.swift` verbatim, changing `private final class` → `final class`, and delete it from the bar file. Keep the bar compiling (it no longer declares the pill; its `skipButton` property moves out in Step 2 — simplest is to do Steps 1–2 together and build once).

- [ ] **Step 2: Rebuild the chrome in `viewDidLoad`**

In `PlayerContainerViewController`, replace the `if let vm = viewModel { let bar = PlayerTransportBarView... }` block (lines ~81–114) with the new chrome. Add properties:

```swift
private var focusCard: PlayerFocusCardView?
private var progressBar: PlayerProgressBarView?
private var skipPill: SkipPillButton?
private let chromeScrim = ChromeScrimView()
private var activePopup: (any AnchoredPopupPresenting)?   // temporary until Task 6
```

and in `viewDidLoad` (after the hosting-controller constraints):

```swift
if let vm = viewModel {
    chromeScrim.isUserInteractionEnabled = false

    let card = PlayerFocusCardView()
    let bar = PlayerProgressBarView()
    let pill = SkipPillButton()
    pill.isHidden = true
    pill.addTarget(self, action: #selector(skipPillTapped), for: .primaryActionTriggered)

    [chromeScrim, card, bar, pill].forEach {
        view.addSubview($0)
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    view.bringSubviewToFront(card)

    NSLayoutConstraint.activate([
        chromeScrim.topAnchor.constraint(equalTo: view.topAnchor),
        chromeScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        chromeScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        chromeScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

        // Focus card: left 96, vertically centered 520pt band (top/bottom 280 on a 1080 canvas).
        card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 96),
        card.centerYAnchor.constraint(equalTo: view.centerYAnchor),

        // Scrubber: locked left 96 / right 96 / bottom 140 in every state.
        bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 96),
        bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -96),
        bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -140),

        // Skip pill floats above the scrubber's right end.
        pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        pill.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -28),
    ])
    focusCard = card
    progressBar = bar
    skipPill = pill

    bindChrome(to: vm)
}
```

Note: the card's width/height are self-constrained (Task 2), so only position anchors are set here.

- [ ] **Step 3: Move the bar's bindings into `bindChrome(to:)`**

Add to `PlayerContainerViewController` (port from `PlayerTransportBarView.bind()` — then delete that from the bar in Task 10; the bar class stays unreferenced but compiling until then):

```swift
private func bindChrome(to vm: UniversalPlayerViewModel) {
    guard let card = focusCard, let bar = progressBar else { return }

    // Static metadata (re-applied on episode advance via itemGeneration).
    applyCardMetadata(vm: vm)

    bar.filmstripProvider = { [weak vm] times, maxWidth in
        await vm?.filmstripImages(times: times, maxPixelWidth: maxWidth) ?? times.map { _ in nil }
    }

    vm.$itemGeneration
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak vm] _ in
            self?.progressBar?.resetFilmstrip()
            if let vm { self?.applyCardMetadata(vm: vm) }
        }
        .store(in: &cancellables)

    vm.$currentTime
        .combineLatest(vm.$duration, vm.$isScrubbing, vm.$scrubTime)
        .combineLatest(vm.$wheelScrubbing.removeDuplicates())
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak vm] combined, isWheelScrubbing in
            let (currentTime, duration, isScrubbing, scrubTime) = combined
            guard let self, let vm else { return }
            self.progressBar?.update(
                currentTime: currentTime, duration: duration,
                isScrubbing: isScrubbing, scrubTime: scrubTime,
                scrubStepLabelText: vm.scrubStepLabel,
                scrubThumbnail: vm.scrubThumbnail,
                markers: vm.metadata.allMarkers,
                chapters: vm.metadata.Chapter ?? [],
                isWheelScrubbing: isWheelScrubbing
            )
            // Scrubbing hides the card and Up Next; scrubber stays.
            self.setAuxChromeHidden(isScrubbing)
        }
        .store(in: &cancellables)

    vm.$showControls
        .receive(on: DispatchQueue.main)
        .sink { [weak self] show in self?.setChromeHidden(!show, animated: true) }
        .store(in: &cancellables)

    // Ambient pause: the whole chrome yields to the clean backdrop.
    vm.$pausePresentation
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak vm] presentation in
            guard let vm else { return }
            self?.setChromeHidden(presentation != .frame || !vm.showControls, animated: true)
        }
        .store(in: &cancellables)

    vm.$playbackState
        .receive(on: DispatchQueue.main)
        .sink { [weak card] state in card?.setPaused(state == .paused) }
        .store(in: &cancellables)

    vm.$showSkipButton
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak vm] show in
            self?.skipPill?.isHidden = !show
            self?.skipPill?.setTitle(vm?.skipButtonLabel, for: .normal)
        }
        .store(in: &cancellables)

    vm.$subtitleTracks
        .receive(on: DispatchQueue.main)
        .sink { [weak card] tracks in card?.setSubtitlesEnabled(!tracks.isEmpty) }
        .store(in: &cancellables)

    vm.$controlsFocusActive
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        .store(in: &cancellables)

    // Card actions.
    card.onPlayPause = { [weak vm] in vm?.togglePlayPause() }
    card.onSkipBack = { [weak vm] in Task { await vm?.seekRelative(by: -15) } }
    card.onReplayLongPress = { [weak vm] in vm?.replayWithCaptions() }
    card.onNavigateDown = { [weak self, weak vm] in
        // Down from the card enters seek mode at the current position
        // (same entry the touchpad pan uses).
        vm?.exitControlsFocus()
        self?.inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)
    }
    // Temporary popup anchors — replaced by in-card modes in Task 6.
    card.onSubtitles = { [weak self, weak vm] in
        guard let self, let vm else { return }
        let popup = PlayerTrackPopupView(
            header: "Subtitles", tracks: vm.subtitleTracks,
            selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
            onSelect: { id in vm.selectSubtitleTrack(id: id) })
        self.presentPopup(popup, anchoredTo: self.focusCard!.subtitlesButton)
    }
    card.onAudio = { [weak self, weak vm] in
        guard let self, let vm else { return }
        let popup = PlayerTrackPopupView(
            header: "Audio", tracks: vm.audioTracks,
            selectedTrackId: vm.currentAudioTrackId, showsOffRow: false,
            onSelect: { id in if let id { vm.selectAudioTrack(id: id) } })
        self.presentPopup(popup, anchoredTo: self.focusCard!.audioButton)
    }
    card.onInfo = { [weak self, weak vm] in
        guard let self, let vm else { return }
        let popup = PlayerInfoPopupView(
            metadata: vm.metadata,
            liveStatsProvider: { [weak vm] in vm?.aetherPlayer?.liveStats() })
        self.presentPopup(popup, anchoredTo: self.focusCard!.infoButton)
    }
}

/// Series line + title + meta row from the current item.
private func applyCardMetadata(vm: UniversalPlayerViewModel) {
    let meta = vm.metadata
    var metaParts: [String] = []
    if let rating = meta.contentRating { metaParts.append(rating) }
    if let ms = meta.duration { metaParts.append("\(ms / 60000) min") }
    if let audio = meta.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio }),
       let display = audio.displayTitle ?? audio.extendedDisplayTitle {
        metaParts.append(display)
    }
    focusCard?.setTitle(vm.title, seriesLine: vm.subtitle,
                        metaLine: metaParts.isEmpty ? nil : metaParts.joined(separator: " · "))
}

/// Whole-chrome visibility (controls hidden / ambient pause).
private func setChromeHidden(_ hidden: Bool, animated: Bool) {
    let chrome: [UIView?] = [focusCard, progressBar, skipPill, chromeScrim]
    let apply = {
        chrome.compactMap { $0 }.forEach { $0.alpha = hidden ? 0 : 1 }
    }
    animated ? UIView.animate(withDuration: 0.25, animations: apply) : apply()
}

/// While scrubbing only the scrubber (and its strip) stays; the card,
/// pill, and scrim fade (mirrors the old bar's setChrome(hidden:)).
private func setAuxChromeHidden(_ hidden: Bool) {
    UIView.animate(withDuration: 0.15) {
        self.focusCard?.alpha = hidden ? 0 : 1
        self.skipPill?.alpha = hidden ? 0 : 1
    }
}

private func presentPopup<Popup: AnchoredPopupPresenting>(_ popup: Popup, anchoredTo anchor: UIView) {
    activePopup?.dismiss()
    var mutablePopup = popup
    mutablePopup.onDismiss = { [weak self] in self?.activePopup = nil }
    activePopup = mutablePopup
    mutablePopup.present(in: view, anchoredTo: anchor)
}

@objc private func skipPillTapped() {
    Task { await viewModel?.skipActiveMarker() }
}
```

Also add `ChromeScrimView` at file bottom (replaces `TransportScrimView`'s role):

```swift
/// 2a left-readability scrim: horizontal black gradient behind the card
/// (rgba(0,0,0,.8) → .2 @46% → transparent @66%).
final class ChromeScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.8).cgColor,
            UIColor.black.withAlphaComponent(0.2).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.46, 0.66]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
```

- [ ] **Step 4: Update focus routing and Menu/dismiss unwind**

Replace every `transportBar` reference in the container:
- `preferredFocusEnvironments`: popup branch checks `activePopup as? UIView` (`popup.window != nil` → `return [popup]`); controls branch returns `[card]` when `viewModel?.controlsFocusActive == true, let card = focusCard`.
- `dismiss(animated:)` override and `handleMenuButton()`: `transportBar?.hasActivePopup == true` → `activePopup != nil`; `transportBar?.dismissActivePopup()` → `activePopup?.dismiss()`.
- Delete the `private var transportBar: PlayerTransportBarView?` property.

- [ ] **Step 5: Relocate the ambient title logo into SwiftUI**

In `UniversalPlayerView.swift`, `ambientBackdropView(url:)` (~line 1032): overlay the resolved logo bottom-leading (the transport bar's logo swap dies with the bar):

```swift
// inside ambientBackdropView's ZStack, after the dim overlay:
if let logo = viewModel.titleLogoImage {
    VStack {
        Spacer()
        HStack {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 500, maxHeight: 130, alignment: .bottomLeading)
                .padding(.leading, 96)
                .padding(.bottom, 96)
            Spacer()
        }
    }
    .transition(.opacity)
}
```

- [ ] **Step 6: Build and verify on the simulator**

Run the build (expected `** BUILD SUCCEEDED **`), install to the booted Apple TV simulator, start playback on any item, and verify: card bottom-left with correct metadata; scrubber at the locked position; skip pill appears on an intro marker; controls fade on idle; pressing Down (from hidden controls) surfaces the chrome and lands on Resume; CC/audio/info popups open anchored to the card buttons; pause → ambient still fades everything to the backdrop + logo.

- [ ] **Step 7: Commit**

```bash
git add -A Rivulet/
git commit -m "feat: rehost player chrome — focus card, locked scrubber, floating skip pill, left scrim"
```

---

### Task 4: Scrubber 2a restyle + skeleton mode

Restyle `PlayerProgressBarView` to the 2a scrubber: 10pt track `white@0.16`, accent-gradient fill, 24pt circle handle that morphs to a 14×46 bar while scrubbing, end-pinned 22pt tabular times (elapsed `white@0.82` left, `-remaining` `white@0.55` right, ends-at kept beside remaining), and a skeleton mode for loading.

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift`

**Interfaces:**
- Consumes: existing `update(...)` call sites (signature unchanged).
- Produces:
  - `func setSkeleton(_ on: Bool)` — used by Task 7. While on: track `white@0.08`, fill+handle hidden, times `--:--` in `white@0.22`, ends-at hidden; `update(...)` calls are ignored until skeleton turns off.
  - Fill is `AccentGradientView` (file-internal `UIView` with `CAGradientLayer`, horizontal, colors `#7fb8ff, #b9a3ff, #ffce93, #8fe9d4` at `[0, 0.45, 0.8, 1]`).

- [ ] **Step 1: Metrics + track/fill/times restyle**

- `Metrics.trackHeight` 8 → `10`; `Metrics.stripHeight` 100 → `120`.
- `trackBackground.backgroundColor` → `UIColor.white.withAlphaComponent(0.16)`.
- Replace `progressFill` (`UIView`, white) with `AccentGradientView` (same frame-driven usage — it is laid out by `update(...)`'s animate block; a `CAGradientLayer`-backed view resizes its layer automatically via `layerClass`):

```swift
final class AccentGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
            UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
        ]
        g.locations = [0, 0.45, 0.8, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        layer.cornerRadius = 5
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
```

- Times: `currentTimeLabel` becomes the **left-pinned elapsed label** — delete `currentTimeCenterXConstraint` and the playhead-following clamp block in `update(...)`; constrain `currentTimeLabel.leadingAnchor == leadingAnchor`, same top band. It is now ALWAYS visible (shows `displayTime`), 22pt: `.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)`, color `white@0.82`. `remainingTimeLabel` → 22pt medium, `white@0.55`. `scrubStepLabel` moves beside the elapsed label (constraint already relative to `currentTimeLabel` — keep). The single-thumbnail no-BIF fallback keeps its own clamped centerX (unchanged).

- [ ] **Step 2: Handle (circle ↔ bar morph)**

Add subviews + state:

```swift
private let handleView = UIView()          // white core
private let handleRing = UIView()          // ring behind it

// in setupViews(), after trackBackground config:
handleRing.backgroundColor = UIColor.white.withAlphaComponent(0.14)
handleView.backgroundColor = .white
handleView.layer.shadowColor = UIColor.black.cgColor
handleView.layer.shadowOpacity = 0.5
handleView.layer.shadowRadius = 16
handleView.layer.shadowOffset = CGSize(width: 0, height: 4)
addSubview(handleRing)
addSubview(handleView)
```

In `update(...)`, inside the existing single animate block, position the handle at the fill edge, vertically centered on the track (frame-driven, no constraints):

```swift
let handleSize: CGSize = isScrubbing ? CGSize(width: 14, height: 46) : CGSize(width: 24, height: 24)
let ringInset: CGFloat = isScrubbing ? 5 : 6
let handleX = width * CGFloat(progress)
let trackMidY = self.trackBackground.frame.minY + trackHeight / 2
self.handleView.frame = CGRect(x: handleX - handleSize.width / 2, y: trackMidY - handleSize.height / 2,
                               width: handleSize.width, height: handleSize.height)
self.handleView.layer.cornerRadius = isScrubbing ? 8 : handleSize.width / 2
self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
self.handleRing.layer.cornerRadius = isScrubbing ? 8 + ringInset : self.handleRing.frame.width / 2
self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(isScrubbing ? 0.16 : 0.14)
```

The handle stays visible with the strip open (it rides the track below the strip). `clipsToBounds` is already `false` on the view; the track's own `clipsToBounds` stays `true` (handle is a sibling of `trackBackground`, not a child).

- [ ] **Step 3: Skeleton mode**

```swift
private var isSkeleton = false

/// Loading placeholder: keeps the locked geometry and vertical rhythm
/// while playback starts. update(...) is a no-op while on.
func setSkeleton(_ on: Bool) {
    guard on != isSkeleton else { return }
    isSkeleton = on
    trackBackground.backgroundColor = UIColor.white.withAlphaComponent(on ? 0.08 : 0.16)
    progressFill.isHidden = on
    handleView.isHidden = on
    handleRing.isHidden = on
    endsAtLabel.isHidden = on || duration <= 0
    markersContainer.isHidden = on
    let skeletonColor = UIColor.white.withAlphaComponent(0.22)
    if on {
        currentTimeLabel.text = "--:--"
        remainingTimeLabel.text = "--:--"
        currentTimeLabel.textColor = skeletonColor
        remainingTimeLabel.textColor = skeletonColor
    } else {
        currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
    }
}
```

Add `guard !isSkeleton else { return }` at the top of `update(...)`.

- [ ] **Step 4: Build + simulator check**

Build (expected `** BUILD SUCCEEDED **`), reinstall, play an item: gradient fill with circle handle at rest; hold right → handle becomes tall bar; elapsed pinned left, `-remaining` + ends-at right; marker tints still render.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift
git commit -m "feat: 2a scrubber skin — accent gradient fill, morphing handle, end-pinned times, skeleton mode"
```

---

### Task 5: Filmstrip chapter segments, dim overlay, chapter chip, playhead thread

Restructure the scrubbing filmstrip into chapter-proportional segments (6pt gaps, radius 12) tiled with BIF frames, add the played-side dim gradient, 2pt boundary ticks, a pill "chip" callout (time + chapter, uppercase), and the 3pt playhead thread. Segment math is a pure, tested helper.

**Files:**
- Create: `Rivulet/Views/Player/UIKit/ChapterSegmentLayout.swift`
- Create: `RivuletTests/Unit/ChapterSegmentLayoutTests.swift`
- Modify: `Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift`

**Interfaces:**
- Consumes: `PlexChapter` (`startTimeOffset`/`endTimeOffset` in ms, `tag`), existing BIF pipeline (`filmstripProvider`, `populateStrip`).
- Produces:
  - `struct ChapterSegmentLayout` with `struct Segment { let rect: CGRect; let startTime: TimeInterval; let endTime: TimeInterval }`, `init(chapters: [PlexChapter], duration: TimeInterval, width: CGFloat, height: CGFloat, gap: CGFloat)`, `var segments: [Segment]`, `func x(for time: TimeInterval) -> CGFloat`, `func time(for x: CGFloat) -> TimeInterval`. No chapters (or duration ≤ 0) → one full-width segment.

- [ ] **Step 1: Write the failing tests**

`RivuletTests/Unit/ChapterSegmentLayoutTests.swift`:

```swift
import XCTest
@testable import Rivulet

final class ChapterSegmentLayoutTests: XCTestCase {

    private func chapter(startMs: Int, endMs: Int?, tag: String? = nil) -> PlexChapter {
        var c = PlexChapter()
        c.startTimeOffset = startMs
        c.endTimeOffset = endMs
        c.tag = tag
        return c
    }

    func test_noChapters_isSingleFullWidthSegment() {
        let layout = ChapterSegmentLayout(chapters: [], duration: 100, width: 1000, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.segments[0].rect, CGRect(x: 0, y: 0, width: 1000, height: 120))
        XCTAssertEqual(layout.segments[0].startTime, 0)
        XCTAssertEqual(layout.segments[0].endTime, 100)
    }

    func test_segmentsAreProportionalWithGaps() {
        // Two chapters: 0–25s and 25–100s over 100s → 1:3 split of (width − gap).
        let chapters = [chapter(startMs: 0, endMs: 25_000), chapter(startMs: 25_000, endMs: 100_000)]
        let layout = ChapterSegmentLayout(chapters: chapters, duration: 100, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 2)
        XCTAssertEqual(layout.segments[0].rect.width, 250, accuracy: 0.5)
        XCTAssertEqual(layout.segments[1].rect.width, 750, accuracy: 0.5)
        XCTAssertEqual(layout.segments[1].rect.minX, 256, accuracy: 0.5)   // 250 + 6 gap
    }

    func test_xForTime_roundTripsThroughTimeForX() {
        let chapters = [chapter(startMs: 0, endMs: 30_000), chapter(startMs: 30_000, endMs: 100_000)]
        let layout = ChapterSegmentLayout(chapters: chapters, duration: 100, width: 1006, height: 120, gap: 6)
        for t: TimeInterval in [0, 10, 29.9, 30, 65, 100] {
            XCTAssertEqual(layout.time(for: layout.x(for: t)), t, accuracy: 0.2)
        }
    }

    func test_chapterNotStartingAtZero_getsLeadingImplicitSegment() {
        // Plex sometimes omits a chapter for the opening — treat 0→first start as an implicit segment.
        let chapters = [chapter(startMs: 40_000, endMs: 100_000)]
        let layout = ChapterSegmentLayout(chapters: chapters, duration: 100, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 2)
        XCTAssertEqual(layout.segments[0].startTime, 0)
        XCTAssertEqual(layout.segments[0].endTime, 40)
    }
}
```

(If `PlexChapter` has no memberwise/empty init available to tests, construct via `PlexChapter(from:)` JSON decoding in a small helper instead — check the model first; adjust the helper, not the assertions.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd test -only-testing:RivuletTests/ChapterSegmentLayoutTests 2>&1 | tail -8`
Expected: build failure — `ChapterSegmentLayout` not defined.

- [ ] **Step 3: Implement ChapterSegmentLayout**

```swift
//
//  ChapterSegmentLayout.swift
//  Rivulet
//
//  Pure geometry for the 2a chaptered filmstrip: chapter-proportional
//  segments with fixed gaps, and the piecewise time↔x mapping the
//  playhead/dim/chip layout needs (x positions inside gaps snap to the
//  nearest segment edge).
//

import UIKit

struct ChapterSegmentLayout {

    struct Segment {
        let rect: CGRect
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    let segments: [Segment]
    private let width: CGFloat
    private let duration: TimeInterval

    init(chapters: [PlexChapter], duration: TimeInterval, width: CGFloat, height: CGFloat, gap: CGFloat) {
        self.width = width
        self.duration = duration

        // Time ranges: chapter starts (sorted), with an implicit opening
        // range if the first chapter doesn't start at 0.
        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        let starts = chapters
            .compactMap { $0.startTimeOffset.map { TimeInterval($0) / 1000 } }
            .filter { $0 < duration }
            .sorted()
        if duration > 0, !starts.isEmpty {
            var boundaries = starts
            if boundaries.first! > 0 { boundaries.insert(0, at: 0) }
            for (i, start) in boundaries.enumerated() {
                let end = i + 1 < boundaries.count ? boundaries[i + 1] : duration
                if end > start { ranges.append((start, end)) }
            }
        }
        if ranges.isEmpty { ranges = [(0, max(duration, 1))] }

        let totalGap = gap * CGFloat(ranges.count - 1)
        let usable = max(0, width - totalGap)
        let total = ranges.reduce(0) { $0 + ($1.end - $1.start) }
        var x: CGFloat = 0
        var segments: [Segment] = []
        for range in ranges {
            let w = usable * CGFloat((range.end - range.start) / total)
            segments.append(Segment(rect: CGRect(x: x, y: 0, width: w, height: height),
                                    startTime: range.start, endTime: range.end))
            x += w + gap
        }
        self.segments = segments
    }

    func x(for time: TimeInterval) -> CGFloat {
        for segment in segments where time <= segment.endTime {
            let span = segment.endTime - segment.startTime
            guard span > 0 else { return segment.rect.minX }
            let fraction = max(0, (time - segment.startTime) / span)
            return segment.rect.minX + segment.rect.width * CGFloat(min(1, fraction))
        }
        return segments.last?.rect.maxX ?? width
    }

    func time(for x: CGFloat) -> TimeInterval {
        for segment in segments {
            if x <= segment.rect.maxX {
                let clamped = max(segment.rect.minX, x)
                guard segment.rect.width > 0 else { return segment.startTime }
                let fraction = (clamped - segment.rect.minX) / segment.rect.width
                return segment.startTime + (segment.endTime - segment.startTime) * TimeInterval(fraction)
            }
        }
        return duration
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'ChapterSegmentLayoutTests' passed`.

- [ ] **Step 5: Apply the segment layout to the strip**

In `PlayerProgressBarView`:

1. Add state: `private var segmentLayout: ChapterSegmentLayout?`, subviews `private let dimOverlay = AccentDimView()` — actually a plain gradient view:

```swift
/// Played-side dim: black .5 → .08 across the played region of the strip.
final class StripDimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [UIColor.black.withAlphaComponent(0.5).cgColor,
                    UIColor.black.withAlphaComponent(0.08).cgColor]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
```

plus `private let chipLabel = PaddedChipLabel()` (pill: `black@0.55` bg, radius 8, insets 4/12, 17pt uppercase with 0.1em kern) and `private let playheadThread = UIView()` (3pt, white, `alpha 0.9`).

2. In `populateStrip(images:tileWidth:)`: compute `segmentLayout = ChapterSegmentLayout(chapters: lastChapters, duration: duration, width: trackBackground.bounds.width, height: Metrics.stripHeight, gap: 6)`. For each segment create a rounded clipping container (`cornerRadius 12`, `.continuous`, `clipsToBounds = true`, `frame = segment.rect`) inside `stripContainer`, then lay the existing BIF tiles across the FULL strip width as before but parented so each tile lands in the container(s) it overlaps — simplest correct approach: add the full tile row inside EACH segment container with a negative x offset (`tile.frame.origin.x - segment.rect.minX`), letting the container's clip do the cropping. Tile count/times/fetch logic is unchanged.
3. `stripContainer` itself: `clipsToBounds = false`, `cornerRadius 0` while segmented (the per-segment containers own the rounding); keep the old behavior when `segments.count == 1`.
4. Replace the seam styling in `rebuildChapterSeamsIfNeeded` — with segment gaps the seams become the 2pt `white@0.22` ticks at `segmentLayout.x(for: segment.startTime)` for every segment after the first (skip when gaps already visually separate — per the mock BOTH exist: gaps between tiles and ticks at boundaries; draw the ticks centered in each gap).
5. In `layoutStripOverlay(progress:currentProgress:width:)`: map positions through the layout — `let playheadX = segmentLayout?.x(for: displayTime) ?? width * CGFloat(progress)` (same for `liveX` with `currentTime`). Size `dimOverlay.frame = CGRect(x: 0, y: 0, width: playheadX, height: Metrics.stripHeight)` (added to `stripContainer` above tiles, below lines). Chip: `chipLabel.text = "18:20 · CH 3 · BREAK ROOM"`-style — build as `"\(Self.formatTime(displayTime))\(chapterChipSuffix(at: displayTime))"` where `chapterChipSuffix` returns `" · CH \(n) · \(TAG.uppercased())"` for the chapter containing the time (n = 1-based chapter ordinal) or `""`; replace `calloutLabel`'s role with the chip (delete `calloutLabel` or restyle it into the chip — restyle in place to keep the clamping code). Playhead thread: `playheadThread.frame = CGRect(x: playheadX - 1.5, y: -(chipGap), width: 3, height: Metrics.stripHeight + threadDropBelow)` where `threadDropBelow` extends to the track below (thread is a sibling of `stripContainer` added to `self`, so compute in self coordinates: from strip top to `trackBackground.frame.maxY`).
6. `resetFilmstrip()`: also clear `segmentLayout = nil`, remove segment containers, hide chip/dim/thread.
7. The scrub-position → time mapping used elsewhere (`update` uses linear progress) stays LINEAR — segments are a display treatment; `x(for:)` is only for overlay positioning. (The playhead x on the strip and the handle x on the track below will differ slightly by design — the thread connects strip-playhead to the track; anchor the thread to the STRIP's x.)

- [ ] **Step 6: Build + simulator check on chaptered content**

Build, install, play ratingKey `183532` (Interstellar — chaptered), hold right to scrub: segmented strip with gaps + ticks, dim on the played side, uppercase chip with time + chapter, thread through the strip. Then a chapterless item: single continuous segment, no regression.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Views/Player/UIKit/ChapterSegmentLayout.swift RivuletTests/Unit/ChapterSegmentLayoutTests.swift Rivulet/Views/Player/UIKit/PlayerProgressBarView.swift
git commit -m "feat: chapter-segmented filmstrip with dim overlay, chip callout, and playhead thread"
```

---

### Task 6: In-card modes — track lists and info/tech sheet; retire popups from the flow

Card buttons swap the card's content in place: CC → subtitle list, audio → audio list, info → info/tech sheet. Menu returns to metadata. Focus is fenced inside the card while a panel mode is up. The popup system stops being used (files deleted in Task 10).

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift`
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`

**Interfaces:**
- Consumes: `MediaTrack` (`id`, `name`, `language`, `codec`), `PlexMetadata`, `AetherLiveStats`, VM track selection APIs.
- Produces (used by container unwind + Task 7):
  - `enum Mode { case metadata, subtitleTracks, audioTracks, info, loading }` (loading arrives Task 7 — declare the case now, unhandled content until then)
  - `private(set) var mode: Mode`
  - `func showTracks(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool, onSelect: @escaping (Int?) -> Void)`
  - `func showInfo(metadata: PlexMetadata, liveStatsProvider: (() -> AetherLiveStats?)?)`
  - `func returnToMetadata()`
  - Card consumes Menu (`pressesBegan`/`pressesEnded`) itself when `mode != .metadata`.

- [ ] **Step 1: Mode plumbing in the card**

Add to `PlayerFocusCardView`:

```swift
enum Mode { case metadata, subtitleTracks, audioTracks, info, loading }
private(set) var mode: Mode = .metadata
private var panelContainer: UIView?

private func swapContent(to mode: Mode, panel: UIView?) {
    self.mode = mode
    let showMetadata = (mode == .metadata)
    UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) {
        self.metadataContainer.isHidden = !showMetadata
        self.panelContainer?.removeFromSuperview()
        self.panelContainer = panel
        if let panel {
            self.addSubview(panel)
            panel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: self.topAnchor, constant: Metrics.paddingV),
                panel.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Metrics.paddingH),
                panel.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Metrics.paddingH),
                panel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -Metrics.paddingV),
            ])
        }
    }
    setNeedsFocusUpdate()
    updateFocusIfNeeded()
}

func returnToMetadata() {
    guard mode != .metadata else { return }
    swapContent(to: .metadata, panel: nil)
}
```

Focus fence + Menu consumption while a panel is up:

```swift
override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
    if mode != .metadata, window != nil,
       let next = context.nextFocusedView, !next.isDescendant(of: self) {
        return false
    }
    return super.shouldUpdateFocus(in: context)
}

// extend the existing pressesBegan:
override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
        if press.type == .menu, mode != .metadata {
            returnToMetadata()
            return
        }
        if press.type == .downArrow, mode == .metadata {
            onNavigateDown?()
            return
        }
    }
    super.pressesBegan(presses, with: event)
}

// Swallow the ended phase of a consumed Menu press (same trap the popups fixed:
// letting it bubble peels a second unwind layer via the system dismiss).
override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses where press.type == .menu {
        return
    }
    super.pressesEnded(presses, with: event)
}
```

and extend `preferredFocusEnvironments` to steer into the panel:

```swift
override var preferredFocusEnvironments: [UIFocusEnvironment] {
    if mode != .metadata, let panel = panelContainer { return [panel] }
    if let last = lastFocusedControl, !last.isHidden { return [last] }
    return [resumeButton]
}
```

- [ ] **Step 2: Track list panel**

Add a `CardTrackListView` to `PlayerFocusCardView.swift` — port `PlayerTrackPopupView`'s row model + `PopupRowButton` (copy the `Row` struct, the scroll+stack layout from `PlayerTrackPopupView.setupViews()` lines 69–129 minus the glass background, and `PopupRowButton` verbatim as `CardTrackRowButton`). Its `preferredFocusEnvironments` returns the selected row. Then:

```swift
func showTracks(header: String, tracks: [MediaTrack], selectedTrackId: Int?,
                showsOffRow: Bool, onSelect: @escaping (Int?) -> Void) {
    let list = CardTrackListView(header: header, tracks: tracks,
                                 selectedTrackId: selectedTrackId, showsOffRow: showsOffRow,
                                 onSelect: { [weak self] id in
                                     onSelect(id)
                                     self?.returnToMetadata()
                                 })
    swapContent(to: header == "Audio" ? .audioTracks : .subtitleTracks, panel: list)
}
```

- [ ] **Step 3: Info panel**

Add `CardInfoView` to `PlayerFocusCardView.swift`: port `PlayerInfoPopupView`'s scroll+stack, `populate()` content builders (lines 143–305: PLAYBACK live section, VIDEO/AUDIO/SUBTITLES/FILE sections, row builders, formatters) and the 1Hz live-tick lifecycle (`didMoveToWindow` start/stop) — everything except the glass background and the `AnchoredPopupPresenting` conformance/Menu handling (the card owns Menu now). `CardInfoView.canBecomeFocused` stays `true` for focus-scroll. Then:

```swift
func showInfo(metadata: PlexMetadata, liveStatsProvider: (() -> AetherLiveStats?)?) {
    swapContent(to: .info, panel: CardInfoView(metadata: metadata, liveStatsProvider: liveStatsProvider))
}
```

- [ ] **Step 4: Rewire the container**

In `bindChrome(to:)`, replace the three temporary popup closures:

```swift
card.onSubtitles = { [weak card, weak vm] in
    guard let card, let vm else { return }
    card.showTracks(header: "Subtitles", tracks: vm.subtitleTracks,
                    selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
                    onSelect: { id in vm.selectSubtitleTrack(id: id) })
}
card.onAudio = { [weak card, weak vm] in
    guard let card, let vm else { return }
    card.showTracks(header: "Audio", tracks: vm.audioTracks,
                    selectedTrackId: vm.currentAudioTrackId, showsOffRow: false,
                    onSelect: { id in if let id { vm.selectAudioTrack(id: id) } })
}
card.onInfo = { [weak card, weak vm] in
    guard let card, let vm else { return }
    card.showInfo(metadata: vm.metadata,
                  liveStatsProvider: { [weak vm] in vm?.aetherPlayer?.liveStats() })
}
```

Delete `presentPopup(_:anchoredTo:)` and the `activePopup` property. Update the unwind sites:
- `preferredFocusEnvironments`: drop the popup branch (the card's own preferred-focus handles panel landing).
- `dismiss(animated:)` override: replace the `hasActivePopup` step with `if focusCard?.mode != .metadata { focusCard?.returnToMetadata(); return }` placed before the `controlsFocusActive` step.
- `handleMenuButton()`: same replacement — the card consumes Menu itself when a row is focused; this is the container-level backstop.
- Also: exiting controls-focus mode or hiding controls must reset a non-metadata card: in the `$controlsFocusActive` sink, when `active == false` call `focusCard?.returnToMetadata()`.

- [ ] **Step 5: Build + simulator check**

Build, install, verify: CC/audio/info swap the card body in place; selection works and returns to metadata; Menu backs out panel → metadata → controls-hide → dismiss in that order; focus cannot escape the card while a panel is up; CC long-press still triggers replay.

- [ ] **Step 6: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift Rivulet/Views/Player/PlayerContainerViewController.swift
git commit -m "feat: in-card track lists and info/tech sheet replace anchored popups"
```

---

### Task 7: Loading state — iris spinner card + skeleton scrubber

Card loading mode (accent conic spinner + `Loading · <series>` + title + skeleton bars), skeleton scrubber, and slimming the SwiftUI loading view down to its backdrop role.

**Files:**
- Modify: `Rivulet/Views/Player/UIKit/PlayerFocusCardView.swift`
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerView.swift`

**Interfaces:**
- Consumes: `PlayerProgressBarView.setSkeleton(_:)` (Task 4), `Mode.loading` (declared Task 6), VM `$playbackState` (`.loading` / `.idle`).
- Produces: `func setLoading(_ loading: Bool, seriesLine: String?, title: String)` on the card.

- [ ] **Step 1: IrisSpinnerView + loading panel in the card**

Add to `PlayerFocusCardView.swift`:

```swift
/// 64pt conic accent-gradient ring, masked to an 8pt stroke, spinning
/// 1.4s/rev. Animation is re-added on window attach (CAAnimations die
/// on removal).
final class IrisSpinnerView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let g = layer as! CAGradientLayer
        g.type = .conic
        g.colors = [
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
            UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 0).cgColor,
        ]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 0.5, y: 0)

        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 8
        ring.lineCap = .round
        layer.mask = ring
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: 64, height: 64) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
    }
}
```

Loading panel (`CardLoadingView` in the same file): vertical stack — HStack(spinner, `Loading · <seriesLine>` 23pt `white@0.55`) → title (same 48pt attributed style as metadata) → two skeleton bars (`UIView`s, height 22, corner 6, widths 60%/40% of the panel, `white@0.08` / `white@0.06`). Card API:

```swift
func setLoading(_ loading: Bool, seriesLine: String?, title: String) {
    if loading {
        tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.40)
        swapContent(to: .loading, panel: CardLoadingView(seriesLine: seriesLine, title: title))
    } else if mode == .loading {
        tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.42)
        returnToMetadata()
    }
}
```

`CardLoadingView` is not focusable; extend the card's `preferredFocusEnvironments` so `.loading` returns `[resumeButton]`-free `[]`? No — return `[self]` is wrong too; while loading `controlsFocusActive` is false so the container never routes focus here; leave `preferredFocusEnvironments` untouched (the `.loading` panel simply never receives focus).

- [ ] **Step 2: Wire in the container**

In `bindChrome(to:)` add:

```swift
vm.$playbackState
    .map { $0 == .loading || $0 == .idle }
    .removeDuplicates()
    .receive(on: DispatchQueue.main)
    .sink { [weak self, weak vm] loading in
        guard let self, let vm else { return }
        self.focusCard?.setLoading(loading, seriesLine: vm.subtitle, title: vm.title)
        self.progressBar?.setSkeleton(loading)
        self.skipPill?.isHidden = loading || !vm.showSkipButton
    }
    .store(in: &cancellables)
```

(Merge with the existing `$playbackState` sink from Task 3 — one sink handling both `setPaused` and loading.)

- [ ] **Step 3: Slim the SwiftUI loadingView**

In `UniversalPlayerView.swift` `loadingView` (~line 1060): the UIKit card now owns the loading identity. Remove the centered spinner + "Loading..." text block (the `if viewModel.pausePresentation == .frame { ... ProgressView ... }` cluster ~lines 1160–1170) and the thumb/title overlay content (`loadingThumbImage` block ~line 1178 onward) — keep ONLY the full-bleed `loadingArtImage` backdrop + its dim gradient. The card + skeleton scrubber render above it.

- [ ] **Step 4: Build + simulator check**

Build, install, cold-start playback: backdrop art with the glass card showing spinner + skeleton bars + `--:--` skeleton scrubber, resolving into metadata + live scrubber when playback starts. Trigger an episode advance (post-video → next episode) and confirm the loading state shows during the swap.

- [ ] **Step 5: Commit**

```bash
git add -A Rivulet/
git commit -m "feat: loading state — iris spinner card, skeleton scrubber, slimmed SwiftUI loading layer"
```

---

### Task 8: View model — season episode list + playEpisode

Published season episode list for the Up Next panel, a tested row-state derivation, and an API to play an arbitrary episode through the existing episode-change path.

**Files:**
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift`
- Create: `Rivulet/Views/Player/UIKit/UpNextRowState.swift`
- Create: `RivuletTests/Unit/UpNextRowStateTests.swift`

**Interfaces:**
- Consumes: `PlexNetworkManager.getChildren(serverURL:authToken:ratingKey:)`, `fetchNextEpisode()` (existing, private — stays), `playNextEpisode()` (existing), `metadata.parentRatingKey/index/ratingKey/type`, `resolveNextEpisodeEarlyIfNeeded()` (hook point).
- Produces:
  - VM: `@Published private(set) var upNextEpisodes: [PlexMetadata]` — current season sorted by index; when the current episode is the season finale, the next season's opener is appended.
  - VM: `func playEpisode(_ episode: PlexMetadata) async`
  - `enum UpNextRowState { case watched, nowPlaying, upNext, future }` + `static func state(for episode: PlexMetadata, in episodes: [PlexMetadata], currentRatingKey: String?) -> UpNextRowState`

- [ ] **Step 1: Write the failing row-state tests**

`RivuletTests/Unit/UpNextRowStateTests.swift`:

```swift
import XCTest
@testable import Rivulet

final class UpNextRowStateTests: XCTestCase {

    private func episode(key: String, index: Int, viewCount: Int? = nil) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = key
        m.index = index
        m.type = "episode"
        m.viewCount = viewCount
        return m
    }

    func test_states_aroundCurrentEpisode() {
        let eps = [
            episode(key: "4", index: 4, viewCount: 1),
            episode(key: "5", index: 5),
            episode(key: "6", index: 6),
            episode(key: "7", index: 7),
        ]
        XCTAssertEqual(UpNextRowState.state(for: eps[0], in: eps, currentRatingKey: "5"), .watched)
        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: "5"), .nowPlaying)
        XCTAssertEqual(UpNextRowState.state(for: eps[2], in: eps, currentRatingKey: "5"), .upNext)
        XCTAssertEqual(UpNextRowState.state(for: eps[3], in: eps, currentRatingKey: "5"), .future)
    }

    func test_watchedEpisodeAfterCurrent_isStillUpNextOrFuture() {
        // A rewatch mid-season: episodes ahead of the playhead show their
        // queue position, not their watched history.
        let eps = [episode(key: "5", index: 5), episode(key: "6", index: 6, viewCount: 1)]
        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: "5"), .upNext)
    }

    func test_unknownCurrent_treatsWatchedAndRestAsFuture() {
        let eps = [episode(key: "1", index: 1, viewCount: 1), episode(key: "2", index: 2)]
        XCTAssertEqual(UpNextRowState.state(for: eps[0], in: eps, currentRatingKey: nil), .watched)
        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: nil), .future)
    }
}
```

(If `PlexMetadata()` has no empty init available, decode a minimal JSON fixture instead — adjust construction, not assertions.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd test -only-testing:RivuletTests/UpNextRowStateTests 2>&1 | tail -8`
Expected: build failure — `UpNextRowState` not defined.

- [ ] **Step 3: Implement UpNextRowState**

`Rivulet/Views/Player/UIKit/UpNextRowState.swift`:

```swift
//
//  UpNextRowState.swift
//  Rivulet
//
//  Row status for the Up Next panel: position relative to the playing
//  episode wins over watch history (a rewatch shows queue order).
//

import Foundation

enum UpNextRowState: Equatable {
    case watched
    case nowPlaying
    case upNext
    case future

    static func state(for episode: PlexMetadata, in episodes: [PlexMetadata],
                      currentRatingKey: String?) -> UpNextRowState {
        if let currentRatingKey, episode.ratingKey == currentRatingKey { return .nowPlaying }
        let currentPosition = episodes.firstIndex { $0.ratingKey == currentRatingKey }
        let position = episodes.firstIndex { $0.ratingKey == episode.ratingKey }
        if let currentPosition, let position, position > currentPosition {
            return position == currentPosition + 1 ? .upNext : .future
        }
        if (episode.viewCount ?? 0) > 0 { return .watched }
        return .future
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'UpNextRowStateTests' passed`.

- [ ] **Step 5: VM — upNextEpisodes + loader + playEpisode**

In `UniversalPlayerViewModel.swift`, next to `nextEpisode` (~line 377) add:

```swift
/// Season episode list for the Up Next panel (2a chrome): the playing
/// season sorted by index; when the current episode is the finale, the
/// next season's opener is appended so the panel always has an
/// "up next" row. Empty for movies / Live TV / fetch failure.
@Published private(set) var upNextEpisodes: [PlexMetadata] = []
```

Loader (near `fetchNextEpisode()`):

```swift
func loadUpNextEpisodes() async {
    guard metadata.type == "episode" else {
        upNextEpisodes = []
        return
    }
    if metadata.parentRatingKey == nil || metadata.index == nil {
        await fetchFullMetadataIfNeeded()
    }
    guard let seasonKey = metadata.parentRatingKey else {
        upNextEpisodes = []
        return
    }
    do {
        var episodes = try await PlexNetworkManager.shared.getChildren(
            serverURL: serverURL, authToken: authToken, ratingKey: seasonKey)
            .filter { $0.index != nil }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        // Season finale: surface the next season's opener as the up-next row.
        if episodes.last?.ratingKey == metadata.ratingKey,
           let next = await fetchNextEpisode(),
           next.parentRatingKey != metadata.parentRatingKey {
            episodes.append(next)
        }
        upNextEpisodes = episodes
    } catch {
        upNextEpisodes = []
    }
}
```

Hook: at the end of `resolveNextEpisodeEarlyIfNeeded()` (after the `nextEpisode = next` assignment; also fires per episode) add `Task { await loadUpNextEpisodes() }`. Also clear stale rows on episode swap: in `playNextEpisode()` right after `itemGeneration += 1`, add `upNextEpisodes = []` (the resolve hook repopulates for the new episode).

Play-arbitrary-episode (near `playNextEpisode()`):

```swift
/// Play a specific episode from the Up Next panel. Reuses the full
/// playNextEpisode() reset path (filmstrip/replay/marker/generation) by
/// substituting the target as the resolved next episode. Note this marks
/// the CURRENT episode watched — same semantics as advancing normally.
func playEpisode(_ episode: PlexMetadata) async {
    guard episode.ratingKey != metadata.ratingKey else { return }
    preloadedNextMetadata = nil
    preloadedNextStreamURL = nil
    nextEpisode = episode
    await playNextEpisode()
}
```

(Check the exact preloaded-property names next to `playNextEpisode()` — `preloadedNextMetadata` / `preloadedNextStreamURL` appear at lines ~3904/3952; clear whichever exist so a stale preload of the *sequential* next episode can't hijack the chosen one. If clearing is not possible because they're `let`/computed, guard inside `playNextEpisode` is already `preloadedNextMetadata ?? next` — clearing is required; they are `private var`, so this works.)

- [ ] **Step 6: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Views/Player/UniversalPlayerViewModel.swift Rivulet/Views/Player/UIKit/UpNextRowState.swift RivuletTests/Unit/UpNextRowStateTests.swift
git commit -m "feat: season episode list, row states, and playEpisode for the Up Next panel"
```

---

### Task 9: PlayerUpNextPanelView — collapsed row ↔ expanded season list

Right-side panel: collapsed single up-next row when unfocused; expands to the `UP NEXT · SEASON <n>` scrollable list when focus arrives from the card; Select plays the episode; hidden for movies/Live TV/scrubbing/empty.

**Files:**
- Create: `Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift`
- Modify: `Rivulet/Views/Player/PlayerContainerViewController.swift`

**Interfaces:**
- Consumes: `UpNextRowState` (Task 8), VM `$upNextEpisodes`, `playEpisode(_:)`, `metadata.ratingKey`, `$isScrubbing`, `PlexNetworkManager.shared.buildThumbnailURL(serverURL:authToken:thumbPath:width:height:)`, `ImageCacheManager.shared.image(for:)`.
- Produces:
  - `final class PlayerUpNextPanelView: UIView`
  - `var onSelectEpisode: ((PlexMetadata) -> Void)?`
  - `func setEpisodes(_ episodes: [PlexMetadata], currentRatingKey: String?, seasonNumber: Int?, serverURL: String, authToken: String)`
  - `var isEmpty: Bool` (no episodes → container keeps it hidden)

- [ ] **Step 1: Write the panel**

`Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift` — structure:

```swift
//
//  PlayerUpNextPanelView.swift
//  Rivulet
//
//  Right-side Up Next panel for the 2a chrome. Unfocused: a single
//  collapsed row (the up-next episode) vertically centered at the right
//  edge. Focused: expands to the season list ("UP NEXT · SEASON n"),
//  auto-scrolled to the playing episode. Collapse/expand is driven purely
//  by focus membership (didUpdateFocus); Menu is NOT handled here — the
//  container's exitControlsFocus step pulls focus back to the card and
//  the panel collapses on focus loss.
//

import UIKit

final class PlayerUpNextPanelView: UIView {

    private enum Metrics {
        static let width: CGFloat = 470
        static let maxHeight: CGFloat = 520
        static let cornerRadius: CGFloat = 26
        static let padding: CGFloat = 24
        static let rowHeight: CGFloat = 92
    }

    var onSelectEpisode: ((PlexMetadata) -> Void)?
    var isEmpty: Bool { rows.isEmpty }

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [UpNextRowButton] = []
    private var expanded = false
    private var currentRatingKey: String?
    ...
}
```

Key pieces (write in full):
- Glass: blur + `tintView` `rgba(14,17,23,.55)`, `cornerRadius 26 .continuous`, border 1pt `white@0.1`; when expanded AND containing focus, border animates to `rgba(143,233,212,.55)` with an outer ring (shadow with `UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 0.22)`).
- `headerLabel`: `"UP NEXT · SEASON \(n)"`, 15pt bold, `white@0.5`, kern 1.5, hidden while collapsed.
- Layout: `widthAnchor == 470`, `heightAnchor <= 520`; header top; scrollView below; stack of `UpNextRowButton`s (same grows-to-cap pattern as `PlayerTrackPopupView`: `scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)` at `.defaultHigh` + a `<= 520 - header` cap).
- Collapsed state: every row hidden except the `.upNext` one (fall back to `.nowPlaying`, then first); header hidden. Expanded: all visible; after layout, scroll the `.nowPlaying` row to visible center.
- `setEpisodes(...)`: rebuild rows; per row compute `UpNextRowState.state(for:in:currentRatingKey:)`; subtitle per state — `.watched` → `"Watched"`; `.nowPlaying` → `"Now playing"`; `.upNext` → `"Up next · \(mins) min"`; `.future` → `"\(mins) min"` (`mins = (episode.duration ?? 0) / 60000`); title `"E\(index) · \(title)"`. Thumb: `buildThumbnailURL(serverURL:authToken:thumbPath: episode.thumb ?? "", width: 300, height: 169)` loaded via `Task { await ImageCacheManager.shared.image(for: url) }` into a 120×68 rounded image view (guard `episode.thumb != nil`).
- `UpNextRowButton` (`UIControl`, same file): thumb + 2-line text column; `canBecomeFocused` true; Select via `pressesBegan` `.select` → `onTap`; focus treatment per glass grammar — focused: bg `white@0.16`, border `white@0.25`, `scale 1.02`; `.nowPlaying` row gets a leading 3pt accent bar (`#8fe9d4`); rest state bg `.clear` (`white@0.06` for the `.upNext` row per the mock's emphasis).
- Expansion via focus:

```swift
override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
    super.didUpdateFocus(in: context, with: coordinator)
    let containsFocus = context.nextFocusedView?.isDescendant(of: self) == true
    guard containsFocus != expanded else { return }
    expanded = containsFocus
    coordinator.addCoordinatedAnimations({
        self.applyExpansion()
        self.superview?.layoutIfNeeded()
    }, completion: { [weak self] in
        guard let self, self.expanded else { return }
        self.scrollToCurrentRow()
    })
}

override var preferredFocusEnvironments: [UIFocusEnvironment] {
    // Land on the up-next row first (the collapsed row), then free movement.
    if let target = rows.first(where: { $0.state == .upNext }) ?? rows.first { return [target] }
    return [self]
}
```

- [ ] **Step 2: Host it in the container**

In `viewDidLoad` chrome block: create `let panel = PlayerUpNextPanelView()`, `panel.isHidden = true`, add + constraints:

```swift
panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
```

Property `private var upNextPanel: PlayerUpNextPanelView?`. In `bindChrome(to:)`:

```swift
vm.$upNextEpisodes
    .receive(on: DispatchQueue.main)
    .sink { [weak self, weak vm] episodes in
        guard let self, let vm else { return }
        self.upNextPanel?.setEpisodes(episodes,
                                      currentRatingKey: vm.metadata.ratingKey,
                                      seasonNumber: vm.metadata.parentIndex,
                                      serverURL: vm.serverURL, authToken: vm.authToken)
        self.upNextPanel?.isHidden = episodes.isEmpty
    }
    .store(in: &cancellables)

panel.onSelectEpisode = { [weak vm] episode in
    vm?.exitControlsFocus()
    Task { await vm?.playEpisode(episode) }
}
```

Include the panel in `setChromeHidden` and `setAuxChromeHidden` (hidden while scrubbing, faded with the rest of the chrome, still respecting `isHidden` for movies — use `alpha`, `isHidden` stays data-driven).

- [ ] **Step 3: Build + simulator check**

Build, install, play an episode: collapsed up-next row at the right edge; Right from the card's controls row expands it; up/down walk the season; Select on a row starts that episode (loading card shows, filmstrip resets); Menu returns focus to the card and the panel collapses; a movie shows no panel.

- [ ] **Step 4: Commit**

```bash
git add Rivulet/Views/Player/UIKit/PlayerUpNextPanelView.swift Rivulet/Views/Player/PlayerContainerViewController.swift
git commit -m "feat: Up Next panel — collapsed row expands to season list on focus"
```

---

### Task 10: Delete the old chrome + docs sync

Remove the transport bar, popups, and the anchored-popup protocol; sweep for dangling references; sync the docs that name the deleted files.

**Files:**
- Delete: `Rivulet/Views/Player/UIKit/PlayerTransportBarView.swift`
- Delete: `Rivulet/Views/Player/UIKit/PlayerTrackPopupView.swift`
- Delete: `Rivulet/Views/Player/UIKit/PlayerInfoPopupView.swift`
- Delete: `Rivulet/Views/Player/UIKit/AnchoredPopupPresenting.swift`
- Modify: `CLAUDE.md`, `Docs/RIVULET_PLAYER.md`

**Interfaces:**
- Consumes: everything rewired in Tasks 3/6.
- Produces: a codebase with no references to the deleted types.

- [ ] **Step 1: Verify nothing references the doomed types, then delete**

Run: `grep -rn "PlayerTransportBarView\|PlayerTrackPopupView\|PlayerInfoPopupView\|AnchoredPopupPresenting\|TransportScrimView\|browseButton" Rivulet/ RivuletTests/ --include="*.swift"`
Expected: hits only inside the four files being deleted (if the container still has popup remnants, remove them now). Then `git rm` the four files.

- [ ] **Step 2: Build + run the unit tests**

Run the build AND `xcodebuild ... test -only-testing:RivuletTests 2>&1 | tail -10`.
Expected: `** BUILD SUCCEEDED **`, all tests pass.

- [ ] **Step 3: Docs sync**

- `CLAUDE.md` Key Files table: `Views/Player/UIKit/PlayerTransportBarView.swift` row → `Views/Player/UIKit/PlayerFocusCardView.swift` (focus card) and add `PlayerUpNextPanelView.swift`; update the project-structure comment `PlayerTransportBarView, PlayerProgressBarView, pills, popups` → `PlayerFocusCardView, PlayerProgressBarView, PlayerUpNextPanelView, pills`.
- `Docs/RIVULET_PLAYER.md`: update the transport-bar mentions to the 2a chrome (card + panel + locked scrubber; popups removed).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: delete transport bar and anchored popups; docs sync for 2a chrome"
```

---

### Task 11: Full verification pass

**Files:** none (verification + ledger only).

**Interfaces:** n/a.

- [ ] **Step 1: Clean build + full unit test run**

`xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-cli-dd build test 2>&1 | tail -10` — expected: succeeded, tests green.

- [ ] **Step 2: Simulator walk-through (every state + every kept behavior)**

Install to the booted Apple TV simulator and verify against the spec's testing checklist:
1. **Controls**: card bottom-left (metadata + Resume/↺15/CC/audio/info), collapsed Up Next right, gradient scrubber at the locked position, left scrim.
2. **Focus walk**: surface → Resume; Right along the row → panel expands; Menu → collapses back to card; Down from card → seek mode with filmstrip; Menu cancels scrub.
3. **Scrubbing**: chapter segments + gaps + ticks + dim + chip + thread on 183532; tall bar handle; single segment on chapterless content; shuttle clicks still step 2x/4x/6x; jog ring on wheel input.
4. **Card modes**: CC/audio lists select + return; info sheet shows PLAYBACK live rows ticking; CC long-press replay still fires; Menu unwind order panel → metadata → hide → dismiss.
5. **Paused**: `⏸ Paused` line + Resume label; ambient after idle → chrome fades to backdrop + logo; input restores.
6. **Loading**: cold start and episode-advance both show spinner card + skeleton scrubber.
7. **Up Next**: watched/now-playing/up-next/future states; Select starts the episode; movie hides the panel.
8. **Markers**: skip pill appears/works on an intro.

Fix anything broken before committing; re-run the relevant checklist line after each fix.

- [ ] **Step 3: Update the branch memory + progress ledger**

Update `nowplaying_redesign_branch.md` memory (2a chrome shipped on top; device checklist now includes the new items). Record any deviations in `.superpowers/sdd/nowplaying-progress.md`.

- [ ] **Step 4: Final commit (if verification produced fixes)**

```bash
git add -A
git commit -m "fix: 2a chrome verification pass"
```
