//
//  MultiStreamViewModel.swift
//  Rivulet
//
//  Central state management for multi-stream Live TV playback
//

import SwiftUI
import Combine
import UIKit

@MainActor
final class MultiStreamViewModel: ObservableObject {

    enum LayoutMode: Equatable {
        case grid
        case focus(mainId: UUID)
    }

    // MARK: - Stream Slot Model

    struct StreamSlot: Identifiable {
        let id = UUID()
        let channel: UnifiedChannel

        // Player wrappers - only one will be non-nil based on engine selection
        let mpvWrapper: MPVPlayerWrapper?
        let avWrapper: AVPlayerWrapper?
        var playerController: MPVMetalViewController?  // Only used for MPV

        var playbackState: UniversalPlaybackState
        var currentProgram: UnifiedProgram?
        var isMuted: Bool

        // MARK: - Convenience Accessors

        var isPlaying: Bool {
            mpvWrapper?.isPlaying ?? avWrapper?.isPlaying ?? false
        }

        var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
            mpvWrapper?.playbackStatePublisher ?? avWrapper?.playbackStatePublisher ?? Just(.idle).eraseToAnyPublisher()
        }

        func play() {
            mpvWrapper?.play()
            avWrapper?.play()
        }

        func pause() {
            mpvWrapper?.pause()
            avWrapper?.pause()
        }

        func stop() {
            mpvWrapper?.stop()
            avWrapper?.stop()
        }

        func setMuted(_ muted: Bool) {
            mpvWrapper?.setMuted(muted)
            avWrapper?.setMuted(muted)
        }

        func load(url: URL, headers: [String: String]?) async throws {
            if let mpv = mpvWrapper {
                try await mpv.load(url: url, headers: headers, startTime: nil)
            } else if let av = avWrapper {
                try await av.load(url: url, headers: headers, isLive: true)
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var streams: [StreamSlot] = []
    @Published var focusedSlotIndex: Int = 0
    @Published var showControls = true
    @Published var showChannelPicker = false {
        didSet {
            if showChannelPicker {
                // Picker opened - cancel timer so controls don't hide while browsing
                controlsTimer?.invalidate()
                controlsTimer = nil
            } else if oldValue && !showChannelPicker {
                // Picker closed - restart timer to hide controls
                startControlsHideTimer()
            }
        }
    }
    @Published var layoutMode: LayoutMode = .grid
    @Published var replaceSlotIndex: Int? = nil  // Set when replacing a stream

    // MARK: - Private State

    private var cancellables: [UUID: Set<AnyCancellable>] = [:]
    private var controlsTimer: Timer?
    private let controlsHideDelay: TimeInterval = 5

    /// The player engine selected at initialization (doesn't change during session)
    let playerEngine: LiveTVPlayerEngine

    // MARK: - Computed Properties

    var focusedStream: StreamSlot? {
        guard focusedSlotIndex >= 0, focusedSlotIndex < streams.count else { return nil }
        return streams[focusedSlotIndex]
    }

    var canAddStream: Bool {
        let maxStreams: Int
        if playerEngine == .avplayer {
            // AVPlayer is lightweight - allow 4 streams by default
            maxStreams = 4
        } else {
            // MPV uses significant memory per stream
            // Default to 2 streams, allow 4 with user opt-in (may cause crashes)
            let allowFourStreams = UserDefaults.standard.bool(forKey: "allowFourStreams")
            maxStreams = allowFourStreams ? 4 : 2
        }
        return streams.count < maxStreams
    }

    var activeChannelIds: Set<String> {
        Set(streams.map { $0.channel.id })
    }

    var streamCount: Int {
        streams.count
    }

    /// Returns true if currently in focus layout mode
    var isFocusLayout: Bool {
        if case .focus = layoutMode { return true }
        return false
    }

    /// Returns true if focused stream is NOT the main/expanded stream (i.e., it's in the sidebar)
    var isFocusedStreamInSidebar: Bool {
        guard case .focus(let mainId) = layoutMode,
              let focusedId = focusedStream?.id else { return false }
        return focusedId != mainId
    }

    // MARK: - Initialization

    init(initialChannel: UnifiedChannel) {
        // Capture engine selection at initialization time
        self.playerEngine = LiveTVPlayerEngine.current

        // Prevent screensaver during Live TV playback
        UIApplication.shared.isIdleTimerDisabled = true

        // Add the initial channel (unmuted since it's first)
        Task {
            await addChannel(initialChannel)
        }
    }

    // MARK: - Stream Management

    func addChannel(_ channel: UnifiedChannel) async {
        guard canAddStream else { return }
        guard !activeChannelIds.contains(channel.id) else { return }

        // Close the picker immediately for responsiveness
        showChannelPicker = false

        let isMuted = !streams.isEmpty  // First stream unmuted, others muted

        // Create the appropriate wrapper based on engine
        let mpvWrapper: MPVPlayerWrapper?
        let avWrapper: AVPlayerWrapper?

        if playerEngine == .mpv {
            mpvWrapper = MPVPlayerWrapper()
            avWrapper = nil
        } else {
            mpvWrapper = nil
            avWrapper = AVPlayerWrapper()
        }

        var slot = StreamSlot(
            channel: channel,
            mpvWrapper: mpvWrapper,
            avWrapper: avWrapper,
            playbackState: .loading,  // Start in loading state
            isMuted: isMuted
        )

        // Load EPG data
        slot.currentProgram = LiveTVDataStore.shared.getCurrentProgram(for: channel)

        streams.append(slot)
        let slotIndex = streams.count - 1

        // Subscribe to playback state changes
        subscribeToSlot(at: slotIndex)

        // Reset custom layout if only one stream
        if streams.count <= 1 {
            layoutMode = .grid
        }

        // Start playback
        if let url = LiveTVDataStore.shared.buildStreamURL(for: channel) {
            do {
                try await slot.load(url: url, headers: [:])
                slot.setMuted(isMuted)
                slot.play()

                // Focus the newly added stream
                setFocus(to: slotIndex)
            } catch {
                print("MultiStream: Failed to load '\(channel.name)': \(error)")
            }
        }
    }

    func removeStream(at index: Int) {
        guard index >= 0, index < streams.count else { return }

        let slot = streams[index]

        // Stop and cleanup player
        slot.stop()

        // Remove subscriptions
        cancellables.removeValue(forKey: slot.id)

        // Remove from array
        streams.remove(at: index)

        // Reset layout if no streams or main stream removed
        if streams.count <= 1 {
            layoutMode = .grid
        } else if case .focus(let mainId) = layoutMode, !streams.contains(where: { $0.id == mainId }) {
            layoutMode = .grid
        }

        // Adjust focus if needed
        if streams.isEmpty {
            focusedSlotIndex = 0
        } else if focusedSlotIndex >= streams.count {
            setFocus(to: streams.count - 1)
        } else if index == focusedSlotIndex {
            // Removed the focused stream, make sure new focused has audio
            setFocus(to: focusedSlotIndex)
        }
    }

    func stopAllStreams() {
        for slot in streams {
            slot.stop()
        }
        cancellables.removeAll()
        streams.removeAll()
        layoutMode = .grid
        // Re-enable screensaver when Live TV is closed
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Focus Management

    func setFocus(to newIndex: Int) {
        guard newIndex >= 0, newIndex < streams.count else { return }
        guard newIndex != focusedSlotIndex || streams[newIndex].isMuted else { return }

        // Mute previously focused stream
        if focusedSlotIndex >= 0, focusedSlotIndex < streams.count {
            streams[focusedSlotIndex].setMuted(true)
            streams[focusedSlotIndex].isMuted = true
        }

        // Unmute newly focused stream
        streams[newIndex].setMuted(false)
        streams[newIndex].isMuted = false

        focusedSlotIndex = newIndex
    }

    // MARK: - Layout

    func setFocusedLayout(on slotId: UUID) {
        guard streams.count > 1 else { return }
        guard streams.first(where: { $0.id == slotId }) != nil else { return }
        layoutMode = .focus(mainId: slotId)
    }

    func resetLayout() {
        guard case .focus = layoutMode else { return }
        layoutMode = .grid
    }

    /// Expands the currently focused sidebar stream to be the main stream
    func expandFocusedStream() {
        guard let focusedStream = focusedStream else { return }
        layoutMode = .focus(mainId: focusedStream.id)
    }

    /// Replaces the stream at the given index with a new channel
    func replaceStream(at index: Int, with channel: UnifiedChannel) async {
        guard index >= 0, index < streams.count else { return }
        guard !activeChannelIds.contains(channel.id) else { return }

        // Close the picker immediately for responsiveness
        showChannelPicker = false

        let oldSlot = streams[index]

        // Stop and cleanup old player
        oldSlot.stop()
        cancellables.removeValue(forKey: oldSlot.id)

        // Create the appropriate wrapper based on engine
        let mpvWrapper: MPVPlayerWrapper?
        let avWrapper: AVPlayerWrapper?

        if playerEngine == .mpv {
            mpvWrapper = MPVPlayerWrapper()
            avWrapper = nil
        } else {
            mpvWrapper = nil
            avWrapper = AVPlayerWrapper()
        }

        let isMuted = index != focusedSlotIndex  // Mute if not focused

        var newSlot = StreamSlot(
            channel: channel,
            mpvWrapper: mpvWrapper,
            avWrapper: avWrapper,
            playbackState: .loading,  // Start in loading state
            isMuted: isMuted
        )
        newSlot.currentProgram = LiveTVDataStore.shared.getCurrentProgram(for: channel)

        // Replace in array
        streams[index] = newSlot

        // Subscribe to state changes
        subscribeToSlot(at: index)

        // Update focus layout if the replaced stream was the main one
        if case .focus(let mainId) = layoutMode, mainId == oldSlot.id {
            layoutMode = .focus(mainId: newSlot.id)
        }

        // Start playback
        if let url = LiveTVDataStore.shared.buildStreamURL(for: channel) {
            do {
                try await newSlot.load(url: url, headers: [:])
                newSlot.setMuted(isMuted)
                newSlot.play()
            } catch {
                print("MultiStream: Failed to load replacement '\(channel.name)': \(error)")
            }
        }

        replaceSlotIndex = nil
    }

    // MARK: - Playback Controls

    func togglePlayPauseOnFocused() {
        guard let slot = focusedStream else { return }

        if slot.isPlaying {
            slot.pause()
        } else {
            slot.play()
        }

        showControlsTemporarily()
    }

    func playAll() {
        for slot in streams {
            slot.play()
        }
    }

    func pauseAll() {
        for slot in streams {
            slot.pause()
        }
    }

    // MARK: - Controller Binding (MPV only)

    func setPlayerController(_ controller: MPVMetalViewController, for slotId: UUID) {
        guard playerEngine == .mpv else { return }  // Only applies to MPV
        guard let index = streams.firstIndex(where: { $0.id == slotId }) else { return }

        streams[index].playerController = controller
        streams[index].mpvWrapper?.setPlayerController(controller)

        // Apply mute state
        controller.setMuted(streams[index].isMuted)
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        showControls = true
        startControlsHideTimer()
    }

    /// Reset the controls hide timer (call when user navigates between buttons)
    func resetControlsTimer() {
        guard showControls && !showChannelPicker else { return }
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Hide controls after timeout - user can press Select to show again
                // Note: Timer is cancelled when picker opens, so this won't fire during picker
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showControls = false
                }
            }
        }
    }

    // MARK: - Subscriptions

    private func subscribeToSlot(at index: Int) {
        guard index >= 0, index < streams.count else { return }

        let slot = streams[index]
        var slotCancellables = Set<AnyCancellable>()

        slot.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if let idx = self.streams.firstIndex(where: { $0.id == slot.id }) {
                    self.streams[idx].playbackState = state
                }
            }
            .store(in: &slotCancellables)

        cancellables[slot.id] = slotCancellables
    }

    // MARK: - Cleanup

    deinit {
        controlsTimer?.invalidate()
        // Ensure screensaver is re-enabled when Live TV is deallocated
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
