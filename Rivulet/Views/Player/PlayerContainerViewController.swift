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

#if os(tvOS)

/// Container view controller that hosts the SwiftUI player view and intercepts button presses.
/// This allows us to handle Menu button presses before SwiftUI dismisses the player.
class PlayerContainerViewController: UIViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var panGestureRecognizer: UIPanGestureRecognizer?

    /// Reference to the player view model for handling Menu button logic
    weak var viewModel: UniversalPlayerViewModel?

    /// Callback when player is dismissed (to update SwiftUI state)
    var onDismiss: (() -> Void)?

    // MARK: - Initialization

    init<Content: View>(rootView: Content, viewModel: UniversalPlayerViewModel? = nil) {
        self.viewModel = viewModel
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

        // Menu button is handled via pressesBegan (not gesture recognizer)
        // to avoid double-firing issues
        // Left/right arrows are handled by SwiftUI's onMoveCommand with RemoteHoldDetector
        // (UIKit gesture recognizers don't receive events when SwiftUI has focus)

        // Pan gesture for swipe-to-scrub on Siri Remote touchpad
        setupPanGesture()

        // Observe viewModel's shouldDismiss property for programmatic dismissal
        viewModel?.$shouldDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldDismiss in
                if shouldDismiss {
                    self?.dismissPlayer()
                }
            }
            .store(in: &cancellables)

        print("🎮 [SETUP] PlayerContainerViewController ready")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ensure we're first responder to intercept all button events
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        return true
    }

    /// Override dismiss to intercept system-triggered dismissals (e.g., from Menu button)
    /// and only allow dismissal when we've explicitly decided to dismiss.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // If we just handled a menu action that closed something, block this dismiss
        if blockNextDismiss {
            print("🎮 [DISMISS INTERCEPT] Blocked - menu action already handled this press")
            blockNextDismiss = false
            return
        }

        // Check if we have something to close before allowing dismiss
        if let vm = viewModel {
            if vm.postVideoState != .hidden {
                print("🎮 [DISMISS INTERCEPT] Post-video visible - dismissing normally")
                vm.dismissPostVideo()
                super.dismiss(animated: flag, completion: completion)
                return
            }
            if vm.isScrubbing {
                print("🎮 [DISMISS INTERCEPT] Scrubbing active - cancelling scrub instead")
                vm.cancelScrub()
                return
            }
            if vm.showInfoPanel {
                print("🎮 [DISMISS INTERCEPT] Info panel open - closing it instead")
                withAnimation(.easeOut(duration: 0.3)) {
                    vm.showInfoPanel = false
                }
                return
            }
            if vm.showControls {
                print("🎮 [DISMISS INTERCEPT] Controls visible - hiding them instead")
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.showControls = false
                }
                return
            }
        }
        // Nothing to close, allow normal dismiss
        print("🎮 [DISMISS INTERCEPT] Nothing to close - allowing dismiss")
        super.dismiss(animated: flag, completion: completion)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                handleMenuButton()
                return
            }
            if press.type == .select {
                if let vm = viewModel {
                    if vm.isScrubbing {
                        isHandlingSelectPress = true
                        Task { await vm.commitScrub() }
                        return
                    } else if vm.showInfoPanel {
                        isHandlingSelectPress = true
                        handleSelectButton()
                        return
                    }
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
    /// 1. Dismiss post-video overlay if showing
    /// 2. Cancel scrubbing if active
    /// 3. Close info panel if open
    /// 4. Hide controls if visible
    /// 5. Dismiss player if nothing else to close
    private func handleMenuButton() {
        guard let vm = viewModel else {
            print("🎮 [MENU] No viewModel - dismissing player")
            dismissPlayer()
            return
        }

        print("🎮 [MENU] State check: postVideo=\(vm.postVideoState), scrubbing=\(vm.isScrubbing), infoPanel=\(vm.showInfoPanel), controls=\(vm.showControls)")

        if vm.postVideoState != .hidden {
            print("🎮 [MENU] Dismissing post-video overlay and player")
            vm.dismissPostVideo()
            dismissPlayer()
        } else if vm.isScrubbing {
            print("🎮 [MENU] Cancelling scrub")
            blockNextDismiss = true  // Block any subsequent dismiss from SwiftUI
            vm.cancelScrub()
        } else if vm.showInfoPanel {
            print("🎮 [MENU] Closing info panel")
            blockNextDismiss = true  // Block any subsequent dismiss from SwiftUI
            withAnimation(.easeOut(duration: 0.3)) {
                vm.showInfoPanel = false
            }
        } else if vm.showControls {
            print("🎮 [MENU] Hiding controls")
            blockNextDismiss = true  // Block any subsequent dismiss from SwiftUI
            withAnimation(.easeOut(duration: 0.25)) {
                vm.showControls = false
            }
        } else {
            print("🎮 [MENU] Nothing to close - dismissing player")
            dismissPlayer()
        }
    }

    /// Handle Select button press when info panel is open
    private func handleSelectButton() {
        guard let vm = viewModel else { return }
        vm.selectFocusedSetting()
    }

    // MARK: - Swipe-to-Scrub Gesture

    private func setupPanGesture() {
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        // Only recognize indirect touches (Siri Remote touchpad, not direct screen touches)
        panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(panRecognizer)
        panGestureRecognizer = panRecognizer
        print("🎮 [SETUP] Pan gesture recognizer added for swipe-to-scrub")
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let vm = viewModel else { return }

        // Only allow swipe scrubbing when paused
        guard vm.playbackState == .paused else { return }

        // Don't handle pan when info panel or post-video is showing
        if vm.showInfoPanel || vm.postVideoState != .hidden {
            return
        }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            print("🎮 [PAN] Began - starting swipe scrub (paused)")
            // Only initialize scrub position if not already scrubbing
            // This allows multiple swipes to accumulate
            if !vm.isScrubbing {
                vm.startSwipeScrubbing()
            }

        case .changed:
            // Proportional scrubbing: horizontal translation maps to seek time
            // Sensitivity: ~1 second per 2 points of horizontal movement
            // Positive translation.x = swipe right = forward
            let seekDelta = translation.x * 0.5
            vm.updateSwipeScrubPosition(by: seekDelta)
            gesture.setTranslation(.zero, in: view)

        case .ended, .cancelled:
            print("🎮 [PAN] Ended - velocity: \(velocity.x), waiting for play/select to commit")
            // If significant horizontal velocity, apply a final "flick" adjustment
            if abs(velocity.x) > 500 {
                let flickSeekDelta = velocity.x * 0.02  // Small multiplier for flick
                vm.updateSwipeScrubPosition(by: flickSeekDelta)
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
}

#endif
