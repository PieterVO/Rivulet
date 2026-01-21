//
//  UniversalPlayerView.swift
//  Rivulet
//
//  Universal video player using MPV with HDR passthrough
//

import SwiftUI
import Combine
#if os(tvOS)
import GameController
#endif

// MARK: - Simple Remote Input Handler

#if os(tvOS)
/// Simplified remote input detection using GameController.
/// Reads dpad position synchronously when button is pressed to avoid race conditions.
@MainActor
final class RemoteInputHandler: ObservableObject {
    private var holdTimer: Timer?
    private var clickedDirection: Bool?  // direction when click started
    private var currentDpadDirection: Bool?  // current finger position (just tracking)
    private var isButtonDown = false  // true while buttonA is pressed
    private let holdThreshold: TimeInterval = 0.4

    // Click wheel rotation tracking (iPod-style)
    private var lastAngle: Float?
    private var accumulatedRotation: Float = 0
    private let rotationThreshold: Float = 0.3  // ~17 degrees before triggering
    private let radiusThreshold: Float = 0.7    // Only track rotation on outer edge

    // Check viewModel's scrubbing state (single source of truth)
    var isScrubbingCheck: (() -> Bool)?
    // Check if actively scrubbing with timer (hold-based), vs passive scrubbing (swipe/wheel)
    var isActivelyScrubbing: (() -> Bool)?
    // Check if player is in error state (don't capture clicks - let dismiss button work)
    var isErrorCheck: (() -> Bool)?
    // Check if post-video overlay is showing (don't capture clicks - let buttons work)
    var isPostVideoCheck: (() -> Bool)?
    // Check if player is paused (taps start scrubbing when paused)
    var isPausedCheck: (() -> Bool)?

    var onTap: ((Bool) -> Void)?           // forward: Bool
    var onScrubStart: ((Bool) -> Void)?    // forward: Bool
    var onSpeedChange: ((Bool) -> Void)?   // forward: Bool
    var onScrubConfirm: (() -> Void)?
    var onScrubCancel: (() -> Void)?
    var onWheelRotation: ((Float) -> Void)?  // rotation delta in radians (clockwise = positive)

    private var controllerObserver: NSObjectProtocol?

    private var isScrubbing: Bool {
        isScrubbingCheck?() ?? false
    }

    func startMonitoring() {
        for controller in GCController.controllers() {
            setupController(controller)
        }

        controllerObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let controller = notification.object as? GCController {
                self?.setupController(controller)
            }
        }
    }

    func stopMonitoring() {
        for controller in GCController.controllers() {
            controller.microGamepad?.dpad.valueChangedHandler = nil
            controller.microGamepad?.buttonA.pressedChangedHandler = nil
        }
        if let observer = controllerObserver {
            NotificationCenter.default.removeObserver(observer)
            controllerObserver = nil
        }
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func setupController(_ controller: GCController) {
        guard let micro = controller.microGamepad else { return }
        micro.reportsAbsoluteDpadValues = true

        let threshold: Float = 0.3

        // Track dpad position and detect circular rotation (iPod-style click wheel)
        micro.dpad.valueChangedHandler = { [weak self] (dpad, xValue, yValue) in
            guard let self else { return }

            // Don't capture dpad when post-video is showing - let SwiftUI handle focus
            if self.isPostVideoCheck?() == true {
                return
            }

            let dir: Bool? = if xValue > threshold {
                true  // right
            } else if xValue < -threshold {
                false  // left
            } else {
                nil  // center
            }

            // Calculate radius and angle for click wheel rotation
            let radius = sqrt(xValue * xValue + yValue * yValue)
            let angle = atan2(yValue, xValue)

            Task { @MainActor in
                // Ignore dpad changes while button is pressed (click disrupts touch sensing)
                guard !self.isButtonDown else { return }

                // Track left/right direction for tap/hold detection
                if self.currentDpadDirection != dir {
                    print("🎮 [Remote] Dpad: \(dir.map { $0 ? "RIGHT" : "LEFT" } ?? "CENTER") (x=\(xValue))")
                }
                self.currentDpadDirection = dir

                // Click wheel rotation: only track when finger is on outer edge
                if radius > self.radiusThreshold {
                    if let lastAngle = self.lastAngle {
                        var delta = angle - lastAngle

                        // Handle wrap-around at ±π
                        if delta > .pi { delta -= 2 * .pi }
                        if delta < -.pi { delta += 2 * .pi }

                        self.accumulatedRotation += delta

                        // Trigger rotation callback when threshold exceeded
                        if abs(self.accumulatedRotation) > self.rotationThreshold {
                            let rotation = self.accumulatedRotation
                            self.accumulatedRotation = 0
                            self.onWheelRotation?(rotation)
                        }
                    }
                    self.lastAngle = angle
                } else {
                    // Finger moved to center - reset rotation tracking
                    self.lastAngle = nil
                    self.accumulatedRotation = 0
                }
            }
        }

        // Handle buttonA click (physical press on touchpad)
        micro.buttonA.pressedChangedHandler = { [weak self] (button, value, pressed) in
            guard let self else { return }

            Task { @MainActor in
                // Don't capture clicks in error state - let SwiftUI dismiss button work
                if self.isErrorCheck?() == true {
                    return
                }

                // Don't capture clicks when post-video overlay is showing - let buttons work
                if self.isPostVideoCheck?() == true {
                    return
                }

                if pressed {
                    self.isButtonDown = true
                    // Use tracked dpad direction (captured before click disrupted sensing)
                    self.handleClickDown(direction: self.currentDpadDirection)
                } else {
                    self.isButtonDown = false
                    self.handleClickUp()
                }
            }
        }
    }

    private func handleClickDown(direction: Bool?) {
        print("🎮 [Remote] Click DOWN, direction: \(direction.map { $0 ? "RIGHT" : "LEFT" } ?? "CENTER")")

        guard let forward = direction else {
            // Center click - handled by SwiftUI (play/pause) or confirm scrub
            if isScrubbing {
                print("🎮 [Remote] Center click confirms scrub")
                holdTimer?.invalidate()
                holdTimer = nil
                onScrubConfirm?()
            }
            return
        }

        let activelyScrubbingWithTimer = isActivelyScrubbing?() ?? false
        if isScrubbing && activelyScrubbingWithTimer {
            // Actively scrubbing with timer (hold-based) - click changes speed
            print("🎮 [Remote] Speed change while scrubbing")
            onSpeedChange?(forward)
        } else {
            // Not scrubbing, OR passively scrubbing (swipe/wheel) - allow tap detection
            // Start hold detection
            clickedDirection = forward
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.clickedDirection != nil else { return }
                    print("🎮 [Remote] Hold detected - starting scrub")
                    self.onScrubStart?(forward)
                }
            }
        }
    }

    private func handleClickUp() {
        print("🎮 [Remote] Click UP, clickedDirection: \(clickedDirection.map { $0 ? "RIGHT" : "LEFT" } ?? "nil")")

        // If hold timer is still running, it was a tap (quick click)
        if let timer = holdTimer, timer.isValid {
            timer.invalidate()
            holdTimer = nil

            if let forward = clickedDirection, !isScrubbing {
                // When paused, taps start scrubbing instead of seeking
                if isPausedCheck?() == true {
                    print("🎮 [Remote] Tap while paused - starting scrub \(forward ? "forward" : "backward")")
                    onScrubStart?(forward)
                } else {
                    print("🎮 [Remote] Tap detected - seeking \(forward ? "+10s" : "-10s")")
                    onTap?(forward)
                }
            }
        }
        clickedDirection = nil
    }

    func reset() {
        holdTimer?.invalidate()
        holdTimer = nil
        clickedDirection = nil
        currentDpadDirection = nil
        isButtonDown = false
        // Reset rotation tracking
        lastAngle = nil
        accumulatedRotation = 0
    }
}
#endif

struct UniversalPlayerView: View {
    @StateObject private var viewModel: UniversalPlayerViewModel
    @StateObject private var focusScopeManager = FocusScopeManager()
    #if os(tvOS)
    @StateObject private var remoteInput = RemoteInputHandler()
    #endif
    @Environment(\.dismiss) private var dismiss

    @State private var hasStartedPlayback = false
    @State private var playerController: MPVMetalViewController?
    @State private var lastReportedTime: TimeInterval = 0
    @FocusState private var isSkipButtonFocused: Bool

    /// Initialize with metadata (creates viewModel internally)
    init(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: TimeInterval? = nil
    ) {
        _viewModel = StateObject(wrappedValue: UniversalPlayerViewModel(
            metadata: metadata,
            serverURL: serverURL,
            authToken: authToken,
            startOffset: startOffset
        ))
    }

    /// Initialize with an externally-created viewModel (for UIViewController presentation)
    init(viewModel: UniversalPlayerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            // Player content layer - handles input when post-video is hidden
            playerContentLayer
                .zIndex(0)

            // Post-Video Summary Overlay - separate layer with its own focus handling
            if viewModel.postVideoState != .hidden {
                PostVideoSummaryView(viewModel: viewModel)
                    .zIndex(100)  // Ensure it's above everything
            }
        }
        .environment(\.focusScopeManager, focusScopeManager)
        .animation(.easeInOut(duration: 1.0), value: viewModel.playbackState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: viewModel.showInfoPanel)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showSkipButton)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: viewModel.seekIndicator)
        .animation(.easeInOut(duration: 0.5), value: viewModel.showPausedPoster)
        #if os(tvOS)
        .onPlayPauseCommand {
            // Skip button handles its own press via Button action
            guard !isSkipButtonFocused else { return }

            if viewModel.showInfoPanel {
                // Play/pause should still work when panel is open
                viewModel.togglePlayPause()
            } else {
                handleSelectCommand()
            }
        }
        // Note: Menu/Back button handling is done in PlayerContainerViewController
        // to intercept the event before SwiftUI can dismiss the player.
        // Do NOT add onExitCommand here - it would fire after PlayerContainerViewController
        // has already processed the event, causing double-handling.
        #endif
        .onChange(of: playerController) { _, controller in
            if let controller = controller {
                viewModel.setPlayerController(controller)
            }
        }
        .onAppear {
            #if os(tvOS)
            // Wire up remote input callbacks
            remoteInput.isScrubbingCheck = { [weak viewModel] in
                viewModel?.isScrubbing ?? false
            }
            remoteInput.isActivelyScrubbing = { [weak viewModel] in
                // Active scrubbing = hold-based with timer running (scrubSpeed != 0)
                // Passive scrubbing = swipe/wheel (scrubSpeed == 0)
                (viewModel?.scrubSpeed ?? 0) != 0
            }
            remoteInput.isErrorCheck = { [weak viewModel] in
                viewModel?.playbackState.isFailed ?? false
            }
            remoteInput.isPostVideoCheck = { [weak viewModel] in
                viewModel?.postVideoState != .hidden
            }
            remoteInput.isPausedCheck = { [weak viewModel] in
                viewModel?.playbackState == .paused
            }
            remoteInput.onTap = { [weak viewModel] forward in
                guard let vm = viewModel, !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
                if vm.isScrubbing {
                    // Passively scrubbing (swipe/wheel) - adjust scrub position
                    vm.updateSwipeScrubPosition(by: forward ? 10 : -10)
                } else {
                    // Not scrubbing - seek actual playback position
                    Task { await vm.seekRelative(by: forward ? 10 : -10) }
                }
                vm.showControlsTemporarily()
            }
            remoteInput.onScrubStart = { [weak viewModel] forward in
                guard let vm = viewModel, !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
                vm.scrubInDirection(forward: forward)
                vm.showControlsTemporarily()
            }
            remoteInput.onSpeedChange = { [weak viewModel] forward in
                guard let vm = viewModel, !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
                vm.scrubInDirection(forward: forward)
                vm.showControlsTemporarily()
            }
            remoteInput.onWheelRotation = { [weak viewModel] radians in
                guard let vm = viewModel, !vm.showInfoPanel, vm.postVideoState == .hidden else { return }
                // Click wheel scrubbing only works when paused (same as swipe)
                guard vm.playbackState == .paused else { return }
                vm.handleWheelRotation(radians)
                vm.showControlsTemporarily()
            }
            remoteInput.onScrubConfirm = { [weak viewModel] in
                guard let vm = viewModel else { return }
                // Commit scrub position and resume playback
                Task {
                    await vm.commitScrub()
                    vm.resume()
                }
                vm.showControlsTemporarily()
            }
            remoteInput.startMonitoring()
            #endif
        }
        .task {
            guard !hasStartedPlayback else { return }
            hasStartedPlayback = true
            // Activate player scope when player starts
            focusScopeManager.activate(.player)
            // Activate audio session BEFORE playback starts
            // This ensures MPV's AudioUnit is created with correct session config
            NowPlayingService.shared.attach(to: viewModel)
            await viewModel.startPlayback()
        }
        .onDisappear {
            // Stop playback first, then detach from Now Playing
            // (audio session must remain active until player stops)
            viewModel.stopPlayback()
            NowPlayingService.shared.detach()
            reportFinalProgress()
            #if os(tvOS)
            remoteInput.stopMonitoring()
            remoteInput.reset()
            #endif
            // Deactivate player scope when leaving
            focusScopeManager.deactivate()
            // Notify that Plex data should be refreshed (watch progress may have changed)
            // Delay slightly to let Plex server process the progress update before we request fresh hubs
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            }
        }
        .onChange(of: viewModel.currentTime) { _, newTime in
            // Report progress periodically
            reportProgress(time: newTime)
        }
        .onChange(of: viewModel.playbackState) { oldState, newState in
            // Immediately report state changes to Plex
            reportStateChange(from: oldState, to: newState)
        }
        // Manage focus scope when settings panel opens/closes
        .onChange(of: viewModel.showInfoPanel) { _, showPanel in
            if showPanel {
                viewModel.resetSettingsPanel()
                focusScopeManager.activate(.playerInfoBar)
            } else {
                focusScopeManager.deactivate()
            }
        }
        // Auto-focus skip button when it appears
        .onChange(of: viewModel.showSkipButton) { _, showButton in
            if showButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                // Brief delay to ensure button is rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Re-check conditions before focusing (state may have changed)
                    if viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                        print("⏭️ [Skip] Auto-focusing skip button")
                        isSkipButtonFocused = true
                    }
                }
            } else if !showButton {
                isSkipButtonFocused = false
            }
        }
        // Manage focus scope for post-video overlay
        .onChange(of: viewModel.postVideoState) { previous, state in
            if previous == .hidden && state != .hidden {
                focusScopeManager.activate(.postVideo)
            } else if previous != .hidden && state == .hidden {
                focusScopeManager.deactivate()
            }
        }
    }

    // MARK: - Player Content Layer (all player UI except post-video)

    @ViewBuilder
    private var playerContentLayer: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()

            // Player Layer
            playerLayer
                .ignoresSafeArea()

            // Loading State or Paused Poster (shows after 5s pause)
            if viewModel.playbackState == .loading || viewModel.playbackState == .idle || viewModel.showPausedPoster {
                loadingView
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 1.0)),
                            removal: .opacity.animation(.easeOut(duration: 0.5))
                        )
                    )
            }

            // Buffering Indicator
            if viewModel.isBuffering && viewModel.playbackState != .loading {
                bufferingIndicator
            }

            // Seek Indicator (10s skip)
            if let indicator = viewModel.seekIndicator {
                seekIndicatorView(indicator)
                    .transition(.scale.combined(with: .opacity))
            }

            // Compatibility Notice (e.g., DV fallback)
            if let notice = viewModel.compatibilityNotice {
                VStack {
                    HStack {
                        Spacer()
                        compatibilityNoticeView(notice)
                    }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(15)
            }

            // Error State
            if case .failed(let error) = viewModel.playbackState {
                errorView(message: error.localizedDescription)
            }

            // Skip Button (intro/credits) - shows regardless of controls visibility, but not during post-video
            if viewModel.showSkipButton && !viewModel.showInfoPanel && viewModel.postVideoState == .hidden {
                skipButtonOverlay
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Controls Overlay (transport bar at bottom)
            // Always show when scrubbing so user can see the progress bar, but not during post-video
            if (viewModel.showControls || viewModel.isScrubbing) && viewModel.playbackState.isActive && viewModel.postVideoState == .hidden {
                PlayerControlsOverlay(viewModel: viewModel, showInfoPanel: false, hideTitle: viewModel.showPausedPoster)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Info Panel (independent of controls visibility) - slides from top (triggered by d-pad down)
            if viewModel.showInfoPanel {
                VStack {
                    PlayerControlsOverlay(viewModel: viewModel, showInfoPanel: true)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)  // Keep above other elements during animation
            }
        }
        // Focusable when skip button is not focused, post-video is not showing, and not in error state
        // When in error state, let the dismiss button receive focus instead
        .focusable(!isSkipButtonFocused && viewModel.postVideoState == .hidden && !viewModel.playbackState.isFailed)
        .contentShape(Rectangle())
        .onTapGesture {
            // Don't toggle controls if info panel is showing or in error state
            guard !viewModel.showInfoPanel else { return }
            guard !viewModel.playbackState.isFailed else { return }

            // Tap anywhere to show/hide controls
            withAnimation(.easeInOut(duration: 0.25)) {
                if viewModel.showControls {
                    viewModel.showControls = false
                } else {
                    viewModel.showControlsTemporarily()
                }
            }
        }
        #if os(tvOS)
        .onMoveCommand { direction in
            // When post-video is showing, don't handle - let SwiftUI manage button focus
            guard viewModel.postVideoState == .hidden else { return }

            if viewModel.showInfoPanel {
                // Settings panel navigation - 3 column layout
                switch direction {
                case .up:
                    if viewModel.focusedRowIndex == 0 {
                        // At top row - close panel
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            viewModel.showInfoPanel = false
                        }
                    } else {
                        viewModel.navigateSettings(direction: direction)
                    }
                case .down, .left, .right:
                    viewModel.navigateSettings(direction: direction)
                @unknown default:
                    break
                }
            } else {
                // Left/right are handled by GameController via RemoteHoldDetector
                // for tap vs hold detection. Only handle up/down here.
                handleMoveCommand(direction)
            }
        }
        #endif
    }

    // MARK: - Player Layer

    @ViewBuilder
    private var playerLayer: some View {
        if viewModel.streamURL != nil {
            switch viewModel.playerType {
            case .mpv:
                if let mpv = viewModel.mpvPlayerWrapper {
                    MPVPlayerView(
                        url: viewModel.streamURL!,
                        headers: viewModel.streamHeaders,
                        startTime: viewModel.startOffset,
                        delegate: mpv,
                        playerController: $playerController
                    )
                    .scaleEffect(viewModel.videoFrameState.scale, anchor: .topLeading)
                    .offset(viewModel.videoFrameState.offset)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.videoFrameState)
                }
            case .avplayer:
                if let avp = viewModel.avPlayerWrapper {
                    AVPlayerView(playerWrapper: avp)
                        .scaleEffect(viewModel.videoFrameState.scale, anchor: .topLeading)
                        .offset(viewModel.videoFrameState.offset)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.videoFrameState)
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ZStack {
            // Solid black background (fallback)
            Color.black
                .ignoresSafeArea()

            // Background art (passed from detail view - instant display)
            if let artImage = viewModel.loadingArtImage {
                Image(uiImage: artImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
            }

            // Gradient overlay for readability
            LinearGradient(
                colors: [
                    .black.opacity(0.9),
                    .black.opacity(0.6),
                    .black.opacity(0.4),
                    .black.opacity(0.6)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()

            // Content
            HStack(alignment: .center, spacing: 0) {
                // Left side - metadata
                VStack(alignment: .leading, spacing: 16) {
                    // Show title (for episodes)
                    if let grandparentTitle = viewModel.metadata.grandparentTitle {
                        Text(grandparentTitle)
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Main title
                    Text(viewModel.title)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    // Season/Episode info
                    if let seasonNum = viewModel.metadata.parentIndex,
                       let episodeNum = viewModel.metadata.index {
                        Text("Season \(seasonNum), Episode \(episodeNum)")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Year and duration
                    HStack(spacing: 16) {
                        if let year = viewModel.metadata.year {
                            Text(String(year))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let duration = viewModel.metadata.duration {
                            Text(formatDuration(duration))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let rating = viewModel.metadata.contentRating {
                            Text(rating)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .font(.body)

                    Spacer()

                    // Loading indicator (only show when actually loading, not when paused)
                    if !viewModel.showPausedPoster {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text("Loading...")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.leading, 80)
                .padding(.vertical, 60)

                Spacer()

                // Right side - poster/thumbnail (passed from detail view - instant display)
                if let thumbImage = viewModel.loadingThumbImage {
                    let isLandscape = thumbImage.size.width > thumbImage.size.height
                    Image(uiImage: thumbImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: isLandscape ? 700 : nil, maxHeight: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
                        .padding(.trailing, 80)
                }
            }
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalMinutes = milliseconds / 60000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    // MARK: - Buffering Indicator

    private var bufferingIndicator: some View {
        ProgressView()
            .scaleEffect(1.5)
            .tint(.white)
            .padding(20)
            .background(
                Circle()
                    .fill(.black.opacity(0.5))
            )
    }

    // MARK: - Seek Indicator View

    private func seekIndicatorView(_ indicator: SeekIndicator) -> some View {
        Image(systemName: indicator.systemImage)
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    // MARK: - Compatibility Notice

    private func compatibilityNoticeView(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
            )
            .padding(.trailing, 36)
            .padding(.top, 24)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)

            Text("Playback Error")
                .font(.title)
                .foregroundStyle(.white)

            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            Button("Dismiss") {
                // On tvOS, set shouldDismiss so the container can handle it
                // On other platforms, use SwiftUI dismiss
                #if os(tvOS)
                viewModel.shouldDismiss = true
                #else
                dismiss()
                #endif
            }
            .buttonStyle(.bordered)
            .padding(.top, 20)
        }
    }

    // MARK: - Skip Button Overlay

    private var skipButtonOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Task { await viewModel.skipActiveMarker() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .semibold))
                        Text(viewModel.skipButtonLabel)
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .foregroundStyle(isSkipButtonFocused ? .white : .white.opacity(0.9))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSkipButtonFocused ? .white.opacity(0.25) : .white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        isSkipButtonFocused ? .white.opacity(0.4) : .white.opacity(0.08),
                                        lineWidth: isSkipButtonFocused ? 2 : 1
                                    )
                            )
                    )
                    .shadow(
                        color: isSkipButtonFocused ? .white.opacity(0.3) : .clear,
                        radius: 12,
                        x: 0,
                        y: 0
                    )
                    .scaleEffect(isSkipButtonFocused ? 1.04 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSkipButtonFocused)
                }
                #if os(tvOS)
                .buttonStyle(CardButtonStyle())
                .focused($isSkipButtonFocused)
                #else
                .buttonStyle(.plain)
                #endif
            }
            .padding(.trailing, 80)
            // Move button up when controls are visible to avoid overlap with transport bar
            .padding(.bottom, viewModel.showControls ? 200 : 80)
            .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        }
    }

    // MARK: - Input Handling

    #if os(tvOS)
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        // Hide paused poster on any d-pad input
        viewModel.hidePausedPoster()

        switch direction {
        case .left, .right:
            // Left/right are handled by GameController via RemoteHoldDetector
            // which gives us actual press/release timing for tap vs hold detection.
            // We ignore onMoveCommand for these directions.
            break
        case .down:
            if isSkipButtonFocused {
                // Down from skip button: unfocus skip button, show controls
                isSkipButtonFocused = false
                viewModel.showControlsTemporarily()
                return
            }
            // Show info panel (cancels any active scrubbing)
            if viewModel.isScrubbing {
                viewModel.cancelScrub()
                remoteInput.reset()
            }
            if !viewModel.showInfoPanel {
                viewModel.resetSettingsPanel()
                withAnimation(.easeOut(duration: 0.3)) {
                    viewModel.showInfoPanel = true
                }
            }
        case .up:
            // If skip button is visible and controls are showing, focus skip button
            if viewModel.showSkipButton && viewModel.showControls && !isSkipButtonFocused {
                isSkipButtonFocused = true
                return
            }
            // Cancel scrubbing on up
            if viewModel.isScrubbing {
                viewModel.cancelScrub()
                remoteInput.reset()
            }
        @unknown default:
            break
        }
    }

    private func handleSelectCommand() {
        if isSkipButtonFocused {
            // Skip button is focused - trigger skip
            Task { await viewModel.skipActiveMarker() }
            return
        }
        if viewModel.isScrubbing {
            // Commit scrub position and resume playback
            // (swipe-scrubbing only works when paused, so resume after confirming position)
            Task {
                await viewModel.commitScrub()
                viewModel.resume()
            }
            remoteInput.reset()
        } else {
            // Normal play/pause toggle
            viewModel.togglePlayPause()
        }
        viewModel.showControlsTemporarily()
    }
    #endif

    // MARK: - Progress Reporting

    private let reportingInterval: TimeInterval = 10

    private func reportProgress(time: TimeInterval) {
        // Report every 10 seconds
        guard abs(time - lastReportedTime) >= reportingInterval else { return }
        lastReportedTime = time

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: time,
                duration: viewModel.duration,
                state: viewModel.isPlaying ? "playing" : "paused"
            )
        }
    }

    private func reportFinalProgress() {
        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: viewModel.currentTime,
                duration: viewModel.duration,
                state: "stopped",
                forceReport: true
            )

            // Mark as watched if > 90% complete
            if viewModel.duration > 0 && viewModel.currentTime / viewModel.duration > 0.9 {
                await PlexProgressReporter.shared.markAsWatched(
                    ratingKey: viewModel.metadata.ratingKey ?? ""
                )
            }
        }
    }

    private func reportStateChange(from oldState: UniversalPlaybackState, to newState: UniversalPlaybackState) {
        // Only report significant state changes
        let plexState: String?
        switch newState {
        case .playing:
            plexState = "playing"
        case .paused:
            plexState = "paused"
        case .ended:
            plexState = "stopped"
        default:
            plexState = nil
        }

        guard let state = plexState else { return }

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: viewModel.metadata.ratingKey ?? "",
                time: viewModel.currentTime,
                duration: viewModel.duration,
                state: state,
                forceReport: true
            )
        }
    }
}

// MARK: - Convenience Initializer

extension UniversalPlayerView {
    /// Creates a player view using the shared auth manager for credentials
    init(metadata: PlexMetadata, startOffset: TimeInterval? = nil) {
        let authManager = PlexAuthManager.shared
        self.init(
            metadata: metadata,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            startOffset: startOffset
        )
    }
}

#Preview {
    UniversalPlayerView(
        metadata: PlexMetadata(
            ratingKey: "123",
            type: "movie",
            title: "Sample Movie",
            year: 2024,
            duration: 7200000
        ),
        serverURL: "http://localhost:32400",
        authToken: "test-token"
    )
}
