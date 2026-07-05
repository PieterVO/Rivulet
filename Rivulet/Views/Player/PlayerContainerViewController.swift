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
    private var rail: PlayerRailView?
    private var progressBar: PlayerProgressBarView?
    private var scrubberProxy: ScrubberFocusProxyView?
    private var skipPill: SkipPillButton?
    private var pausedDimView: UIView?
    private var pauseIndicator: UIStackView?
    private var pauseTimeLabel: UILabel?
    private var loadingLabel: UILabel?
    private var chromeScrim = ChromeScrimView()
    private var cancellables = Set<AnyCancellable>()
    /// The one floating panel shared by CC/audio/info (Task 5) and Up
    /// Next (Task 6). Only one can be up at a time — presenting a new
    /// one dismisses whatever's showing first.
    private var activeRailPanel: PlayerRailPanelView?
    /// Snapshot of the last `$upNextEpisodes` emission — Task 6's panel
    /// reads this when it comes online; Task 3 only derives the rail
    /// button's availability from it.
    private var upNextEpisodesCache: [PlexMetadata] = []
    /// True while `activeRailPanel` is showing Up Next content, so the
    /// `$upNextEpisodes` sink can dismiss a now-stale list without
    /// touching the CC/audio/info panels, which don't go stale off that
    /// publisher.
    private var isShowingUpNextPanel = false
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

            // Full-frame pause dim sits just above the video, below every
            // other chrome layer (z-order bottom-up: scrim, dim, rail,
            // progress bar, skip pill, pause indicator, loading label).
            let dim = UIView()
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
            dim.alpha = 0
            dim.isUserInteractionEnabled = false

            let railView = PlayerRailView()
            let bar = PlayerProgressBarView()
            let proxy = ScrubberFocusProxyView()
            let pill = SkipPillButton()
            pill.isHidden = true
            pill.addTarget(self, action: #selector(skipPillTapped), for: .primaryActionTriggered)

            // Top-left pause indicator: two bars + "Paused · Xm left".
            let barsStack = UIStackView()
            barsStack.axis = .horizontal
            barsStack.spacing = 6
            barsStack.alignment = .center
            for _ in 0..<2 {
                let bar = UIView()
                bar.backgroundColor = .white
                bar.layer.cornerRadius = 2
                bar.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    bar.widthAnchor.constraint(equalToConstant: 7),
                    bar.heightAnchor.constraint(equalToConstant: 24),
                ])
                barsStack.addArrangedSubview(bar)
            }
            let timeLabel = UILabel()
            timeLabel.font = .systemFont(ofSize: 22, weight: .medium)
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.6)

            let indicator = UIStackView(arrangedSubviews: [barsStack, timeLabel])
            indicator.axis = .horizontal
            indicator.spacing = 12
            indicator.alignment = .center
            indicator.alpha = 0

            // Top-left "Loading" label — same spot the paused indicator
            // occupies, styled like its time label. The progress bar's own
            // skeleton shimmer (see `PlayerProgressBarView.setSkeleton`) is
            // the primary loading visual; this is a quiet text-only cue,
            // no spinner.
            let loadingLabel = UILabel()
            loadingLabel.font = .systemFont(ofSize: 22, weight: .medium)
            loadingLabel.textColor = UIColor.white.withAlphaComponent(0.6)
            loadingLabel.text = "Loading"
            loadingLabel.isHidden = true

            [chromeScrim, dim, railView, bar, proxy, pill, indicator, loadingLabel].forEach {
                view.addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            // Z-order bottom-up, explicit (subview-add order above already
            // matches, but state this is intentional, not incidental).
            view.bringSubviewToFront(chromeScrim)
            view.bringSubviewToFront(dim)
            view.bringSubviewToFront(railView)
            view.bringSubviewToFront(bar)
            view.bringSubviewToFront(proxy)
            view.bringSubviewToFront(pill)
            view.bringSubviewToFront(indicator)
            view.bringSubviewToFront(loadingLabel)

            NSLayoutConstraint.activate([
                chromeScrim.topAnchor.constraint(equalTo: view.topAnchor),
                chromeScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chromeScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                chromeScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                dim.topAnchor.constraint(equalTo: view.topAnchor),
                dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                // Rail: left/right 90, pinned to the bottom.
                railView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
                railView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90),
                railView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
                railView.heightAnchor.constraint(equalToConstant: PlayerRailView.railHeight),

                // Scrubber lives in the rail's lower region — a container
                // sibling overlaid on the rail, not a rail child (its
                // morph/behavior layer is untouched by this task). Leading/
                // trailing inset stays 132 at rest AND while scrubbing —
                // the bar never moves (see PlayerProgressBarView).
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 132),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -132),
                bar.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -34),

                // Invisible focus proxy: geometrically below the button
                // cluster (leading/trailing match the bar's; top/bottom pad
                // 8pt around it) so the focus engine's downward search from
                // ANY cluster button lands here rather than settling on a
                // same-row cone candidate (the bug this proxy fixes). The
                // bar itself is the visible indicator — this view draws
                // nothing.
                proxy.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                proxy.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                proxy.topAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
                proxy.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),

                // Skip pill floats above the scrubber's right end.
                pill.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                pill.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -28),

                // Pause indicator: top 44 / leading 64.
                indicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),

                // Loading label occupies the exact same spot as the pause
                // indicator (the two are disjoint states — never shown at
                // the same time — but kept as separate views).
                loadingLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                loadingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 64),
            ])
            rail = railView
            progressBar = bar
            scrubberProxy = proxy
            skipPill = pill
            pausedDimView = dim
            pauseIndicator = indicator
            pauseTimeLabel = timeLabel
            self.loadingLabel = loadingLabel

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
    /// prefers the rail (its own preferred-focus handles which button
    /// lands, remembering the last-focused control).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let panel = activeRailPanel, panel.window != nil {
            return [panel]
        }
        if viewModel?.controlsFocusActive == true, let rail {
            return [rail]
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
            if let panel = activeRailPanel {
                panel.dismissPanel()
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
    private var isHandlingPlayPausePress = false

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
            if press.type == .playPause {
                // Always honored, whatever holds focus — rail buttons, the
                // scrubber stop, or an open panel. SwiftUI's
                // .onPlayPauseCommand only fires while focus is in the
                // SwiftUI hierarchy, so the UIKit chrome dead-zoned the
                // button without this. Same coordinator action as the
                // SwiftUI path: commits an active scrub, else toggles.
                isHandlingPlayPausePress = true
                inputCoordinator.handle(action: .playPause, source: .irPress)
                return
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
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
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
            if press.type == .playPause && isHandlingPlayPausePress {
                isHandlingPlayPausePress = false
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

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                dismissPlayer()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if let panel = activeRailPanel {
                panel.dismissPanel()
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
        guard let rail, let bar = progressBar else { return }

        // Static metadata (re-applied on episode advance via itemGeneration).
        applyRailMetadata(vm: vm)

        // Scrubber focus proxy: an invisible view geometrically below the
        // rail's button cluster (see its constraints above) so the focus
        // engine's own downward search from ANY cluster button lands here,
        // not on a same-row cone candidate. The bar itself renders the
        // focus indication (grow-and-brighten) — the proxy draws nothing.
        scrubberProxy?.onFocusChange = { [weak bar] focused in
            bar?.setFocusEmphasis(focused)
        }
        scrubberProxy?.onActivate = { [weak self, weak vm] pressType in
            guard let vm else { return }
            // The proxy is the ONLY thing that ever sees this press: the
            // container's own DPad tap/long-press gesture recognizers are
            // attached higher up the responder chain and would normally
            // get first crack, but every one of their handlers guards on
            // `!controlsFocusActive` — true here, since the proxy is only
            // focusable while controls-focus mode is active — so they
            // silently no-op for this exact press. Route it to the same
            // effect those handlers would have had, rather than a
            // direction-blind `.scrubRelative(seconds: 0)` that used to
            // waste this press on merely exiting controls-focus mode with
            // no shuttle ever starting (a held FF/RW from a focused rail
            // button needed a second, separate press to actually seek).
            vm.exitControlsFocus()
            switch pressType {
            case .leftArrow:
                vm.scrubInDirection(forward: false)
                vm.showControlsTemporarily()
            case .rightArrow:
                vm.scrubInDirection(forward: true)
                vm.showControlsTemporarily()
            default:
                // .select: same seek-entry path the touchpad pan uses —
                // enter scrub at the current position, no direction yet.
                self?.inputCoordinator.handle(action: .scrubRelative(seconds: 0), source: .irPress)
            }
        }

        vm.$itemGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] _ in
                self?.progressBar?.resetFilmstrip()
                if let vm { self?.applyRailMetadata(vm: vm) }
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
                // Scrubbing hides the rail and skip pill; scrubber and
                // scrim stay (design mock state 2). The bar itself keeps
                // its rest geometry — no inset swap.
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
            .sink { [weak self, weak vm] state in
                guard let self, let vm else { return }
                let loading = state == .loading || state == .idle
                self.rail?.setLoading(loading)
                self.progressBar?.setSkeleton(loading)
                self.progressBar?.setPausedDim(state == .paused)
                self.skipPill?.isHidden = loading || !vm.showSkipButton

                self.loadingLabel?.isHidden = !loading

                if state == .paused, vm.duration > 0 {
                    let minutesLeft = Int(max(0, vm.duration - vm.currentTime) / 60)
                    self.pauseTimeLabel?.text = "Paused · \(minutesLeft)m left"
                }

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
            .sink { [weak rail] tracks in
                // Port of the old card binding: same enabled-look, applied
                // to the rail's subtitles button now.
                rail?.subtitlesButton.alpha = tracks.isEmpty ? 0.4 : 1
            }
            .store(in: &cancellables)

        vm.$upNextEpisodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm] episodes in
                guard let self, let vm else { return }
                self.upNextEpisodesCache = episodes
                self.rail?.setUpNextAvailable(!episodes.isEmpty && vm.metadata.type == "episode")
                // The open Up Next panel is reading a snapshot of the old
                // list — a fresh instance is built per presentation, so
                // there's no way to refresh it in place. Dismiss rather
                // than leave a stale list on screen; doesn't touch the
                // CC/audio/info panels, which don't key off this publisher.
                if self.isShowingUpNextPanel {
                    self.activeRailPanel?.dismissPanel()
                }
            }
            .store(in: &cancellables)

        vm.$controlsFocusActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsFocusUpdate()
                self?.updateFocusIfNeeded()
            }
            .store(in: &cancellables)

        // Rail actions. (No play/pause control, no skip-back — the remote owns seeking.)
        rail.onReplayLongPress = { [weak vm] in vm?.replayWithCaptions() }
        rail.onSubtitles = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Subtitles", tracks: vm.subtitleTracks,
                    selectedTrackId: vm.currentSubtitleTrackId, showsOffRow: true,
                    onSelect: { [weak vm, weak self] id in
                        vm?.selectSubtitleTrack(id: id)
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 452, from: rail.subtitlesButton)
        }
        rail.onAudio = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardTrackListView(
                    header: "Audio", tracks: vm.audioTracks,
                    selectedTrackId: vm.currentAudioTrackId, showsOffRow: false,
                    onSelect: { [weak vm, weak self] id in
                        if let id { vm?.selectAudioTrack(id: id) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 452, from: rail.audioButton)
        }
        rail.onInfo = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            self.presentRailPanel(
                content: CardInfoView(metadata: vm.metadata, liveStatsProvider: { [weak vm] in vm?.aetherPlayer?.liveStats() }),
                width: 480, from: rail.infoButton)
        }
        rail.onUpNext = { [weak self] in
            guard let self, let vm = self.viewModel, !self.upNextEpisodesCache.isEmpty else { return }
            let presented = self.presentRailPanel(
                content: UpNextListView(
                    episodes: self.upNextEpisodesCache, currentRatingKey: vm.metadata.ratingKey,
                    seasonNumber: vm.metadata.parentIndex, serverURL: vm.serverURL, authToken: vm.authToken,
                    onSelect: { [weak self, weak vm] episode in
                        vm?.exitControlsFocus()
                        Task { await vm?.playEpisode(episode) }
                        self?.activeRailPanel?.dismissPanel()
                    }),
                width: 452, from: rail.upNextButton)
            self.isShowingUpNextPanel = presented
        }
    }

    /// Shared presenter for the CC/audio/info/Up Next rail panel. Only
    /// one panel is ever up: presenting a new one dismisses whatever's
    /// showing. Guarded on the rail cluster actually being visible and
    /// not mid-scrub — the rail's buttons are hidden during a scrub and
    /// while loading, but a stray callback firing in that window (e.g.
    /// a race on the loading→ready edge) must not construct a panel
    /// anchored to a rail that isn't there to anchor to.
    ///
    /// Returns whether a panel was actually presented, so callers that
    /// track "which content is showing" (Task 6's Up Next staleness
    /// check) know whether their flag should stick.
    @discardableResult
    private func presentRailPanel(content: UIView, width: CGFloat, from button: UIView) -> Bool {
        guard let rail, rail.alpha > 0.5, viewModel?.isScrubbing != true else { return false }
        // Every presentation resets the content-type flag — only onUpNext
        // re-marks it (after this call returns). Without this, a CC/audio/info
        // panel superseding an open Up Next panel leaves the flag stuck true
        // (the old panel's onDismiss identity guard rightly won't touch it),
        // and the next $upNextEpisodes emission would dismiss the wrong panel.
        isShowingUpNextPanel = false
        activeRailPanel?.dismissPanel()
        let panel = PlayerRailPanelView.present(content: content, width: width,
                                                in: view, aboveRail: rail, towards: button)
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            // Guard on identity: a superseding presentRailPanel() call
            // dismisses this panel asynchronously (0.15s fade) then
            // synchronously swaps in the next one, so this completion can
            // fire after `activeRailPanel`/`isShowingUpNextPanel` already
            // describe a newer panel — must not clobber that state.
            if self.activeRailPanel === panel {
                self.activeRailPanel = nil
                self.isShowingUpNextPanel = false
            }
            self.setNeedsFocusUpdate(); self.updateFocusIfNeeded()
        }
        activeRailPanel = panel
        view.setNeedsFocusUpdate(); view.updateFocusIfNeeded()
        return true
    }

    /// Eyebrow + title + meta row from the current item, ported from the
    /// 2a card's identical composition.
    private func applyRailMetadata(vm: UniversalPlayerViewModel) {
        let meta = vm.metadata
        rail?.setTitle(vm.title, eyebrow: vm.subtitle)

        let runtime = meta.duration.map { "\($0 / 60000) min" }
        let audio = meta.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio })
            .flatMap { $0.displayTitle ?? $0.extendedDisplayTitle }
        rail?.setMeta(rating: meta.contentRating, runtime: runtime, audio: audio)
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
    ///   pause). `|| isScrubbing` keeps the scrubber + scrim up during a
    ///   scrub even on the one off-device path (MPRemoteCommand
    ///   scrubNudge) that can begin a scrub without showControls being set.
    /// - railVisible: chrome visible AND not scrubbing — scrubbing hides
    ///   the rail and skip pill so focus reads unambiguously on the
    ///   scrubber (user call 2026-07-03).
    /// - paused: playback paused AND the frame is live (not ambient) —
    ///   drives the top-left pause indicator and the full-frame dim.
    /// - loading: the top-left "Loading" label shows whenever loading/idle
    ///   AND not ambient (the progress bar's own skeleton shimmer carries
    ///   the rest of the loading look); it uses `isHidden` from the state
    ///   sink too so it never intercepts focus while alpha is mid-fade.
    /// - scrubberProxy.isFocusEnabled: a FOCUS gate, not an alpha write (the
    ///   proxy is always invisible) — it must never be focusable while
    ///   controls are hidden, mid-scrub, or ambient, and only actually
    ///   reachable once controls-focus mode has moved focus onto the rail.
    private func applyChromeVisibility() {
        guard let vm = viewModel else { return }
        let ambient = vm.pausePresentation != .frame
        let isLoading = vm.playbackState == .loading || vm.playbackState == .idle
        let chromeVisible = (vm.showControls || vm.isScrubbing) && !ambient
        let railVisible = chromeVisible && !vm.isScrubbing
        let paused = vm.playbackState == .paused && !ambient

        scrubberProxy?.isFocusEnabled = railVisible && !isLoading && vm.controlsFocusActive

        // The panel floats above the rail — a scrub/ambient/hide that
        // takes the rail away must take the panel with it, since it
        // has nothing to anchor to and no route back to visible.
        if !railVisible {
            activeRailPanel?.dismissPanel()
        }

        let targets: [(UIView?, CGFloat)] = [
            (chromeScrim, chromeVisible ? 1 : 0),
            (progressBar, chromeVisible ? 1 : 0),
            (rail, railVisible ? 1 : 0),
            (skipPill, railVisible && !isLoading ? 1 : 0),
            (pauseIndicator, paused ? 1 : 0),
            (pausedDimView, paused ? 1 : 0),
            (loadingLabel, isLoading && !ambient ? 1 : 0),
        ]
        guard targets.contains(where: { view, alpha in view.map { abs($0.alpha - alpha) > 0.01 } == true }) else { return }
        UIView.animate(withDuration: 0.25) {
            for (view, alpha) in targets { view?.alpha = alpha }
        }
    }

    @objc private func skipPillTapped() {
        Task { await viewModel?.skipActiveMarker() }
    }
}

/// Invisible focus stop for the scrubber. Sits geometrically below the
/// rail's button cluster (see the container's constraints) so the focus
/// engine's downward search from ANY cluster button lands here rather than
/// settling on a same-row cone candidate — the bug this view fixes. Draws
/// nothing; the progress bar itself is the visible focus indicator
/// (`PlayerProgressBarView.setFocusEmphasis(_:)`).
private final class ScrubberFocusProxyView: UIView {

    /// Focus gate, set by `PlayerContainerViewController.applyChromeVisibility()`.
    /// Never true while controls are hidden, mid-scrub, or ambient.
    var isFocusEnabled = false

    /// Fired when this view gains or loses focus.
    var onFocusChange: ((Bool) -> Void)?

    /// Fired on `.select`/`.leftArrow`/`.rightArrow` while focused; those
    /// press types are consumed here. Everything else (notably `.menu`) is
    /// passed to `super` so it bubbles to the container's own handling.
    var onActivate: ((UIPress.PressType) -> Void)?

    override var canBecomeFocused: Bool { isFocusEnabled }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self {
            onFocusChange?(true)
        } else if context.previouslyFocusedView === self {
            onFocusChange?(false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select, .leftArrow, .rightArrow:
                onActivate?(press.type)
            default:
                super.pressesBegan(presses, with: event)
            }
        }
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

