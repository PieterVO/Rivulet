//
//  PlayerContainerViewController.swift
//  Rivulet
//
//  UIViewController wrapper for video player that intercepts Menu button on tvOS.
//  This bypasses SwiftUI's fullScreenCover gesture handling to give us full control.
//

import SwiftUI
import UIKit
import Combine


/// Container view controller that hosts the SwiftUI player view and intercepts button presses.
/// This allows us to handle Menu button presses before SwiftUI dismisses the player.
class PlayerContainerViewController: UIViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<AnyView>?
    private var focusCard: PlayerFocusCardView?
    private var progressBar: PlayerProgressBarView?
    private var skipPill: SkipPillButton?
    private var upNextPanel: PlayerUpNextPanelView?
    private var cardPanelFocusGuide: UIFocusGuide?
    private var chromeScrim = ChromeScrimView()
    private var cancellables = Set<AnyCancellable>()
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var touchSurfaceTapGesture: UITapGestureRecognizer?

    // Directional gesture recognizers for IR remote support
    private var dPadLeftTapGesture: UITapGestureRecognizer?
    private var dPadRightTapGesture: UITapGestureRecognizer?
    private var dPadLeftLongPressGesture: UILongPressGestureRecognizer?
    private var dPadRightLongPressGesture: UILongPressGestureRecognizer?

    private let inputCoordinator: PlaybackInputCoordinator

    /// Reference to the player view model for handling Menu button logic
    weak var viewModel: UniversalPlayerViewModel?

    /// Callback when player is dismissed (to update SwiftUI state)
    var onDismiss: (() -> Void)?

    // MARK: - Initialization

    init<Content: View>(
        rootView: Content,
        viewModel: UniversalPlayerViewModel? = nil,
        inputCoordinator: PlaybackInputCoordinator
    ) {
        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator
        super.init(nibName: nil, bundle: nil)

        self.modalPresentationStyle = .fullScreen

        let hosting = UIHostingController(rootView: AnyView(rootView))
        hosting.view.backgroundColor = .black
        self.hostingController = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if let hosting = hostingController {
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }

        if let vm = viewModel {
            chromeScrim.isUserInteractionEnabled = false

            let card = PlayerFocusCardView()
            let bar = PlayerProgressBarView()
            let pill = SkipPillButton()
            pill.isHidden = true
            pill.addTarget(self, action: #selector(skipPillTapped), for: .primaryActionTriggered)

            let panel = PlayerUpNextPanelView()
            panel.isHidden = true

            [chromeScrim, card, bar, pill, panel].forEach {
                view.addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            view.bringSubviewToFront(card)
            view.bringSubviewToFront(panel)

            NSLayoutConstraint.activate([
                chromeScrim.topAnchor.constraint(equalTo: view.topAnchor),
                chromeScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chromeScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                chromeScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                // Focus card: left 96, vertically centered 520pt band (top/bottom 280 on 1080 canvas).
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 96),
                card.centerYAnchor.constraint(equalTo: view.centerYAnchor),

                // Scrubber: locked left 96 / right 96 / bottom 140 in every state.
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 96),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -96),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -140),

                // Skip pill floats above the scrubber's right end.
                pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                pill.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -28),

                // Up Next panel: right edge, vertically centered.
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
                panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            focusCard = card
            progressBar = bar
            skipPill = pill
            upNextPanel = panel

            // Focus bridge between the card and the Up Next panel. The
            // card's controls hug the card's bottom while the collapsed
            // panel row sits at centerY — no vertical overlap, so the
            // focus engine's directional beam never finds the other side.
            // The guide spans the gap at the card's full height; its
            // target flips in didUpdateFocus (toward the panel normally,
            // back to the card while focus is inside the panel) so lower
            // expanded rows can still exit leftward.
            let guide = UIFocusGuide()
            view.addLayoutGuide(guide)
            guide.preferredFocusEnvironments = [panel]
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: card.trailingAnchor),
                guide.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
                guide.topAnchor.constraint(equalTo: card.topAnchor),
                guide.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])
            cardPanelFocusGuide = guide

            bindChrome(to: vm)
        }

        // Menu button is handled via pressesBegan (not gesture recognizer)
        // to avoid double-firing issues
        // Left/right arrows are handled by SwiftUI's onMoveCommand with RemoteHoldDetector
        // (UIKit gesture recognizers don't receive events when SwiftUI has focus)

        // Pan gesture for swipe-to-scrub on Siri Remote touchpad
        setupPanGesture()

        // Bare-tap on the Siri Remote touch surface surfaces the timeline
        // overlay briefly (matches Plex's tvOS client behavior).
        setupTouchSurfaceTapGesture()

        // Directional gestures for IR remote support (learned remotes, universal remotes)
        // These fire UIPress events with leftArrow/rightArrow, NOT GameController events
        setupDirectionalGestures()

        // Observe viewModel's shouldDismiss property for programmatic dismissal
        viewModel?.$shouldDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldDismiss in
                if shouldDismiss {
                    self?.dismissPlayer()
                }
            }
            .store(in: &cancellables)

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ensure we're first responder to intercept all button events
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    /// Focus routing for the UIKit transport layer. Controls-focus mode
    /// prefers the card (the card's own preferred-focus handles panel
    /// landing when a track list / info sheet is up).
    /// Keeps the card↔panel focus guide pointing away from wherever focus
    /// currently is, so it always bridges toward the other side and can
    /// never bounce focus back into the panel it just left.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let guide = cardPanelFocusGuide, let panel = upNextPanel, let card = focusCard else { return }
        if let next = context.nextFocusedView, next.isDescendant(of: panel) {
            guide.preferredFocusEnvironments = [card]
        } else {
            guide.preferredFocusEnvironments = [panel]
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if viewModel?.controlsFocusActive == true, let card = focusCard {
            return [card]
        }
        return super.preferredFocusEnvironments
    }

    /// Override dismiss to intercept system-triggered dismissals (e.g., from Menu button)
    /// and only allow dismissal when we've explicitly decided to dismiss.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // If we just handled a menu action that closed something, block this dismiss
        if blockNextDismiss {
            blockNextDismiss = false
            return
        }

        // Check if we have something to close before allowing dismiss
        if let vm = viewModel {
            // Cancel intro skip countdown if active
            if vm.introSkipCountdownSeconds > 0 {
                vm.cancelIntroSkipCountdown()
                return
            }
            if vm.postVideoState != .hidden {
                print("🎮 [DISMISS INTERCEPT] Post-video visible - dismissing normally")
                vm.dismissPostVideo()
                super.dismiss(animated: flag, completion: completion)
                return
            }
            if vm.isScrubbing {
                vm.cancelScrub()
                return
            }
            if focusCard?.mode != .metadata {
                focusCard?.returnToMetadata()
                return
            }
            if vm.controlsFocusActive {
                vm.exitControlsFocus()
                return
            }
            if vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
                return
            }
        }
        // Nothing to close, allow normal dismiss
        super.dismiss(animated: flag, completion: completion)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        blockDismissResetWorkItem?.cancel()
        blockDismissResetWorkItem = nil

        // Notify when dismissed
        if isBeingDismissed || isMovingFromParent {
            onDismiss?()
        }
    }

    // MARK: - Button Interception (Menu and Select only)
    // Left/right arrows are handled by UITapGestureRecognizer and UILongPressGestureRecognizer
    // configured in setupDirectionalGestures()

    /// Track if we're currently consuming presses
    private var isHandlingMenuPress = false
    private var isHandlingSelectPress = false

    /// Flag to block dismiss calls that occur immediately after we handled a menu action
    /// This prevents the double-handling issue where handleMenuButton() closes something,
    /// then SwiftUI's responder chain also calls dismiss().
    private var blockNextDismiss = false
    private var blockDismissResetWorkItem: DispatchWorkItem?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuButton()
                return
            }
            if press.type == .select {
                if let vm = viewModel, vm.isScrubbing {
                    isHandlingSelectPress = true
                    inputCoordinator.handle(action: .scrubCommit, source: .irPress)
                    return
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                // Menu is always handled at the began phase, either by a
                // popup or by handleMenuButton. If focus moved mid-press
                // (a popup closed itself), the ended phase arrives on a
                // responder chain that never saw the began - letting it
                // bubble triggers the system's default dismiss and peels
                // an extra unwind layer (focus "goes to nil").
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
            if press.type == .select && isHandlingSelectPress {
                isHandlingSelectPress = false
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Handle Menu button press with priority:
    /// 1. Cancel intro skip countdown if active
    /// 2. Dismiss post-video overlay if showing
    /// 3. Cancel scrubbing if active
    /// 4. Close an open pill popup (Subtitles/Audio/Info) if any
    /// 5. Hide controls if visible
    /// 6. Dismiss player if nothing else to close
    private func handleMenuButton() {
        guard let vm = viewModel else {
            print("🎮 [MENU] No viewModel - dismissing player")
            dismissPlayer()
            return
        }

        // Cancel intro skip countdown if active (highest priority)
        if vm.introSkipCountdownSeconds > 0 {
            vm.cancelIntroSkipCountdown()
            blockDismissTemporarily()
            return
        }

        // Return the card to metadata before anything else in the unwind
        // chain. The card consumes Menu itself when a track row / info
        // sheet is focused; this is the container-level backstop so a
        // panel can never be orphaned by the .back chain (which doesn't
        // know about card modes).
        if vm.postVideoState == .hidden, !vm.isScrubbing,
           focusCard?.mode != .metadata {
            focusCard?.returnToMetadata()
            blockDismissTemporarily()
            return
        }

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                dismissPlayer()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if focusCard?.mode != .metadata {
                focusCard?.returnToMetadata()
            } else if vm.controlsFocusActive {
                vm.exitControlsFocus()
            } else if vm.showControls {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
            } else {
                dismissPlayer()
            }
            return
        }

        // If we're consuming this menu press in-app (not dismissing), block SwiftUI fallback dismiss briefly.
        let shouldBlockDismiss = vm.postVideoState == .hidden && (vm.isScrubbing || vm.showControls)
        if shouldBlockDismiss {
            blockDismissTemporarily()
        }

        inputCoordinator.handle(action: .back, source: .irPress)
    }

    // MARK: - Swipe-to-Scrub Gesture

    private func setupPanGesture() {
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        // Only recognize indirect touches (Siri Remote touchpad, not direct screen touches)
        panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
    }

    // MARK: - Touch-Surface Tap (timeline overlay)

    /// Bare-tap on the Siri Remote touch surface (no force/click). Fires
    /// only on `.indirect` touches — the touchpad — and not on `.select`
    /// presses (those are the click and are routed to play/pause via the
    /// micro-gamepad buttonA handler). Coexists with the pan recognizer:
    /// if the user starts moving, pan takes over and tap doesn't fire.
    private func setupTouchSurfaceTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouchSurfaceTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // On tvOS, UITapGestureRecognizer defaults allowedPressTypes to
        // [.select], so without this it would silently wait for a click
        // rather than a bare finger tap.
        tap.allowedPressTypes = []
        view.addGestureRecognizer(tap)
        touchSurfaceTapGesture = tap
    }

    @objc private func handleTouchSurfaceTap() {
        guard let vm = viewModel else { return }
        guard !vm.isScrubbing,
              vm.postVideoState == .hidden,
              !vm.playbackState.isFailed
        else { return }

        vm.showControlsTemporarily()
    }

    // MARK: - Directional Gestures (IR Remote Support)

    /// Sets up gesture recognizers for left/right arrow key presses.
    /// IR remotes (learned remotes, One For All, Harmony, etc.) send UIPress events
    /// rather than GameController events. This ensures FF/RW works on all remote types.
    private func setupDirectionalGestures() {
        // Tap gestures for short press (skip 10 seconds)
        let leftTap = UITapGestureRecognizer(target: self, action: #selector(handleDPadLeftTap))
        leftTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        view.addGestureRecognizer(leftTap)
        dPadLeftTapGesture = leftTap

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleDPadRightTap))
        rightTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        view.addGestureRecognizer(rightTap)
        dPadRightTapGesture = rightTap

        // Long press gestures for hold (start scrubbing)
        let leftLong = UILongPressGestureRecognizer(target: self, action: #selector(handleDPadLeftLongPress(_:)))
        leftLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        leftLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(leftLong)
        dPadLeftLongPressGesture = leftLong

        let rightLong = UILongPressGestureRecognizer(target: self, action: #selector(handleDPadRightLongPress(_:)))
        rightLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        rightLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(rightLong)
        dPadRightLongPressGesture = rightLong

        // Long press should prevent tap from firing
        leftTap.require(toFail: leftLong)
        rightTap.require(toFail: rightLong)

    }

    @objc private func handleDPadLeftTap() {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive else { return }

        inputCoordinator.handle(action: .stepSeek(forward: false), source: .irPress)
    }

    @objc private func handleDPadRightTap() {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive else { return }

        inputCoordinator.handle(action: .stepSeek(forward: true), source: .irPress)
    }

    @objc private func handleDPadLeftLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive else { return }

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubNudge(forward: false), source: .irPress)

        case .changed:
            // Continue scrubbing - speed increases are handled by clicking again
            break

        case .ended, .cancelled:
            break

        default:
            break
        }
    }

    @objc private func handleDPadRightLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let vm = viewModel else { return }
        guard vm.postVideoState == .hidden, !vm.controlsFocusActive else { return }

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubNudge(forward: true), source: .irPress)

        case .changed:
            // Continue scrubbing - speed increases are handled by clicking again
            break

        case .ended, .cancelled:
            break

        default:
            break
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let vm = viewModel else { return }

        // Bail in error / post-video / controls-focus states regardless of mode.
        if vm.playbackState.isFailed || vm.postVideoState != .hidden || vm.controlsFocusActive {
            return
        }

        // Touch-surface pan only drives continuous swipe-to-scrub while
        // paused. During active playback the pan is a no-op (previously
        // it also opened the legacy info panel on a downward swipe).
        guard vm.playbackState == .paused else { return }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)

        case .changed:
            // Proportional scrubbing: horizontal translation maps to seek time
            // Sensitivity: ~1 second per 2 points of horizontal movement
            // Positive translation.x = swipe right = forward
            let seekDelta = translation.x * 0.5
            inputCoordinator.handle(action: .scrubRelative(seconds: seekDelta), source: .irPress)
            gesture.setTranslation(.zero, in: view)

        case .ended, .cancelled:
            // If significant horizontal velocity, apply a final "flick" adjustment
            if abs(velocity.x) > 500 {
                let flickSeekDelta = velocity.x * 0.02  // Small multiplier for flick
                inputCoordinator.handle(action: .scrubRelative(seconds: flickSeekDelta), source: .irPress)
            }
            // Don't auto-commit - wait for user to press play/select to confirm position

        default:
            break
        }
    }

    private func dismissPlayer() {
        // Use super.dismiss to bypass our override checks
        super.dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }

    private func blockDismissTemporarily() {
        blockNextDismiss = true
        blockDismissResetWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.blockNextDismiss = false
            self?.blockDismissResetWorkItem = nil
        }
        blockDismissResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + InputConfig.blockDismissTimeout, execute: workItem)
    }

    // MARK: - Chrome Bindings

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
                // Scrubbing hides the skip pill and Up Next; scrubber and
                // card stay (design mock state 2).
                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        vm.$showControls
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        // Ambient pause: the whole chrome yields to the clean backdrop.
        vm.$pausePresentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeVisibility() }
            .store(in: &cancellables)

        vm.$playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak card, weak vm] state in
                card?.setPaused(state == .paused)
                guard let self, let vm else { return }
                let loading = state == .loading || state == .idle
                self.focusCard?.setLoading(loading, seriesLine: vm.subtitle, title: vm.title)
                self.progressBar?.setSkeleton(loading)
                self.progressBar?.setPausedDim(state == .paused)
                self.skipPill?.isHidden = loading || !vm.showSkipButton
                // Loading hides the Up Next panel; a mid-stream route-change
                // reload must re-hide it even while showControls stays true.
                self.applyChromeVisibility()
            }
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

        vm.$upNextEpisodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] episodes in
                guard let self, let vm else { return }
                self.upNextPanel?.setEpisodes(episodes,
                                              currentRatingKey: vm.metadata.ratingKey,
                                              seasonNumber: vm.metadata.parentIndex,
                                              serverURL: vm.serverURL, authToken: vm.authToken)
                self.upNextPanel?.isHidden = episodes.isEmpty
                // Re-derive the focus guide's enabled state now that the
                // panel's data-driven visibility changed.
                self.applyChromeVisibility()
            }
            .store(in: &cancellables)

        upNextPanel?.onSelectEpisode = { [weak vm] episode in
            vm?.exitControlsFocus()
            Task { await vm?.playEpisode(episode) }
        }

        vm.$controlsFocusActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                if !active {
                    self?.focusCard?.returnToMetadata()
                }
                self?.setNeedsFocusUpdate()
                self?.updateFocusIfNeeded()
            }
            .store(in: &cancellables)

        // Card actions. (No play/pause control — the remote owns that.)
        card.onSkipBack = { [weak vm] in Task { await vm?.seekRelative(by: -15) } }
        card.onReplayLongPress = { [weak vm] in vm?.replayWithCaptions() }
        card.onNavigateDown = { [weak self, weak vm] in
            // Down from the card enters seek mode at the current position
            // (same entry the touchpad pan uses).
            vm?.exitControlsFocus()
            self?.inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)
        }
        // In-card modes: track lists and info/tech sheet swap the card's
        // content in place (see PlayerFocusCardView.swapContent).
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

    /// Single writer for all chrome alphas. Every visibility rule lives
    /// here so no two sinks can fight over the same view's alpha (the old
    /// setChromeHidden / setAuxChromeHidden split let the ~0.5s time-sink
    /// re-reveal card/pill/panel over hidden controls). Called from the
    /// showControls, pausePresentation, playbackState, and time sinks; the
    /// guard-on-change makes per-tick calls free.
    ///
    /// Rules:
    /// - chromeVisible: controls up AND the frame is live (not ambient
    ///   pause). `|| isScrubbing` keeps the scrubber + scrim + card up
    ///   during a scrub even on the one off-device path (MPRemoteCommand
    ///   scrubNudge) that can begin a scrub without showControls being set.
    ///   The focus card stays visible while scrubbing (design mock state 2).
    /// - auxVisible: chrome visible AND not scrubbing — scrubbing hides the
    ///   card, skip pill, and Up Next panel so focus reads unambiguously on
    ///   the scrubber (user call 2026-07-03, reverting the card-stays mock
    ///   reading after trying it on screen).
    /// - panelVisible: aux visible AND not loading — the Up Next panel is
    ///   hidden while the loading card is up (spec: Loading hides it).
    ///   The panel's `isHidden` stays data-driven from the upNextEpisodes
    ///   sink; alpha is this applier's channel.
    private func applyChromeVisibility() {
        guard let vm = viewModel else { return }
        let chromeVisible = (vm.showControls || vm.isScrubbing) && vm.pausePresentation == .frame
        let auxVisible = chromeVisible && !vm.isScrubbing
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        let panelVisible = auxVisible && !isLoading

        let targets: [(UIView?, CGFloat)] = [
            (chromeScrim, chromeVisible ? 1 : 0),
            (progressBar, chromeVisible ? 1 : 0),
            (focusCard, auxVisible ? 1 : 0),
            (skipPill, auxVisible ? 1 : 0),
            (upNextPanel, panelVisible ? 1 : 0),
        ]
        // The card↔panel focus guide only bridges when there is actually
        // a visible panel to bridge to — otherwise a rightward move would
        // dead-end into a redirect at an invisible target.
        cardPanelFocusGuide?.isEnabled = panelVisible && upNextPanel?.isHidden == false

        guard targets.contains(where: { view, alpha in view.map { abs($0.alpha - alpha) > 0.01 } == true }) else { return }
        UIView.animate(withDuration: 0.25) {
            for (view, alpha) in targets { view?.alpha = alpha }
        }
    }

    @objc private func skipPillTapped() {
        Task { await viewModel?.skipActiveMarker() }
    }
}

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

