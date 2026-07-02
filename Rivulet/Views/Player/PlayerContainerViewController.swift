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
    private var transportBar: PlayerTransportBarView?
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
            let bar = PlayerTransportBarView(viewModel: vm)
            bar.onSkipTapped = { [weak vm] in
                Task { await vm?.skipActiveMarker() }
            }
            view.addSubview(bar)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.transportBar = bar

            vm.$showControls
                .receive(on: DispatchQueue.main)
                .sink { [weak bar] show in
                    UIView.animate(withDuration: 0.25) {
                        bar?.alpha = show ? 1 : 0
                    }
                }
                .store(in: &cancellables)

            // Route focus into (and back out of) the transport bar's
            // buttons when controls-focus mode toggles.
            vm.$controlsFocusActive
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.setNeedsFocusUpdate()
                    self?.updateFocusIfNeeded()
                }
                .store(in: &cancellables)
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

    /// Focus routing for the UIKit transport layer. An open popup owns
    /// focus outright (its preferredFocusEnvironments pick the selected
    /// row); otherwise controls-focus mode prefers the transport bar's
    /// buttons (the bar itself remembers which one). The popup MUST be
    /// routed from here: a focus request from the popup itself is
    /// ignored by the focus system because the popup does not contain
    /// the currently focused view.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let popup = transportBar?.activePopupView, popup.window != nil {
            return [popup]
        }
        if viewModel?.controlsFocusActive == true, let bar = transportBar {
            return [bar]
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
            if transportBar?.hasActivePopup == true {
                transportBar?.dismissActivePopup()
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

        // Close an open popup before anything else in the unwind chain.
        // The popup consumes Menu itself when one of its rows is focused;
        // this is the container-level backstop so a popup can never be
        // orphaned by the .back chain (which doesn't know about popups).
        if vm.postVideoState == .hidden, !vm.isScrubbing,
           transportBar?.hasActivePopup == true {
            transportBar?.dismissActivePopup()
            blockDismissTemporarily()
            return
        }

        if inputCoordinator.target == nil {
            if vm.postVideoState != .hidden {
                vm.dismissPostVideo()
                dismissPlayer()
            } else if vm.isScrubbing {
                vm.cancelScrub()
            } else if transportBar?.hasActivePopup == true {
                transportBar?.dismissActivePopup()
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
}

