//
//  AVPlayerView.swift
//  Rivulet
//
//  SwiftUI wrapper for AVPlayer-based video playback
//  Used for Live TV streams for better resource efficiency
//

import SwiftUI
import AVFoundation
import AVKit
import Combine

/// A SwiftUI view that displays video content using AVPlayer
struct AVPlayerView: UIViewRepresentable {
    @ObservedObject var playerWrapper: AVPlayerWrapper

    func makeUIView(context: Context) -> AVPlayerUIView {
        let view = AVPlayerUIView()

        // Wire up rendering status callback
        view.onRenderingStatusChanged = { [weak playerWrapper] isReady, videoRect in
            playerWrapper?.handleRenderingStatusChanged(isReady: isReady, videoRect: videoRect)
        }

        // Attach player immediately if available
        if let player = playerWrapper.player {
            view.player = player
            print("🎬 AVPlayerView: Attached player on creation")
        }
        return view
    }

    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {
        // Ensure callback is always set to current wrapper
        uiView.onRenderingStatusChanged = { [weak playerWrapper] isReady, videoRect in
            playerWrapper?.handleRenderingStatusChanged(isReady: isReady, videoRect: videoRect)
        }

        // Attach the player when it becomes available
        if let player = playerWrapper.player, uiView.player !== player {
            uiView.player = player
            print("🎬 AVPlayerView: Attached player on update")
        }
    }
}

/// UIView subclass that hosts an AVPlayerLayer for video rendering
final class AVPlayerUIView: UIView {

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    /// Callback when video rendering status changes
    var onRenderingStatusChanged: ((Bool, CGRect) -> Void)?

    private var readyForDisplayObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?

    /// Track last reported videoRect to avoid duplicate callbacks
    private var lastReportedVideoRect: CGRect = .zero

    /// Track if we've set HDR display criteria (to reset on cleanup)
    private var hasSetDisplayCriteria: Bool = false

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue

            // Stop observing old player
            readyForDisplayObservation?.invalidate()
            playerItemStatusObservation?.invalidate()

            // Reset tracking for new player
            lastReportedVideoRect = .zero

            // Reset display criteria when player changes
            if newValue == nil {
                resetDisplayCriteria()
            }

            // Debug: Log video track info
            if let currentItem = newValue?.currentItem {
                let asset = currentItem.asset
                let videoTracks = asset.tracks(withMediaType: .video)
                print("🎬 AVPlayerUIView: Player attached - video tracks: \(videoTracks.count)")
                for (i, track) in videoTracks.enumerated() {
                    print("🎬 AVPlayerUIView: Track \(i): naturalSize=\(track.naturalSize), enabled=\(track.isEnabled)")
                }

                // Observe player item status to configure HDR display mode when ready
                playerItemStatusObservation = currentItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard let self, item.status == .readyToPlay else { return }
                    self.configureDisplayCriteria(for: item)
                }
            }

            // Start observing isReadyForDisplay to detect when video actually renders
            if newValue != nil {
                readyForDisplayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new, .old]) { [weak self] layer, change in
                    guard let self else { return }
                    let isReady = layer.isReadyForDisplay
                    let videoRect = layer.videoRect
                    print("🎬 AVPlayerUIView: isReadyForDisplay changed to \(isReady), videoRect=\(videoRect)")
                    // Track reported rect to avoid duplicates from layoutSubviews
                    if videoRect.width > 10 && videoRect.height > 10 {
                        self.lastReportedVideoRect = videoRect
                    }
                    self.onRenderingStatusChanged?(isReady, videoRect)
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Try to configure display criteria when we get a window
        // This handles the case where player was ready before we had a window
        if window != nil, !hasSetDisplayCriteria,
           let playerItem = player?.currentItem,
           playerItem.status == .readyToPlay {
            configureDisplayCriteria(for: playerItem)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // AVPlayerLayer automatically resizes with the view
        let videoRect = playerLayer.videoRect
        let isReady = playerLayer.isReadyForDisplay
        print("🎬 AVPlayerUIView: layoutSubviews - bounds=\(bounds), layer.frame=\(playerLayer.frame)")
        print("🎬 AVPlayerUIView: videoRect=\(videoRect), isReadyForDisplay=\(isReady)")

        // If we have a valid videoRect that differs from last reported, call the callback
        // This catches the case where videoRect becomes valid AFTER isReadyForDisplay fires
        if isReady && videoRect.width > 10 && videoRect.height > 10 {
            // Only report if rect changed significantly (avoid duplicate callbacks)
            let rectChanged = abs(videoRect.width - lastReportedVideoRect.width) > 1 ||
                              abs(videoRect.height - lastReportedVideoRect.height) > 1
            if rectChanged {
                print("🎬 AVPlayerUIView: Reporting valid videoRect from layoutSubviews")
                lastReportedVideoRect = videoRect
                onRenderingStatusChanged?(isReady, videoRect)
            }
        }
    }

    // MARK: - HDR Display Mode

    /// Configure the TV's display mode based on the content's HDR/DV metadata
    /// This tells the TV to switch to the appropriate HDR mode (HDR10, HLG, Dolby Vision)
    private func configureDisplayCriteria(for playerItem: AVPlayerItem) {
        let asset = playerItem.asset
        let displayCriteria = asset.preferredDisplayCriteria

        guard let displayManager = window?.avDisplayManager else {
            print("🎬 AVPlayerUIView: No display manager available (window not ready)")
            return
        }

        print("🎬 AVPlayerUIView: Setting display criteria for HDR/DV content")
        displayManager.preferredDisplayCriteria = displayCriteria
        hasSetDisplayCriteria = true
    }

    /// Reset display criteria when playback ends or player is removed
    private func resetDisplayCriteria() {
        guard hasSetDisplayCriteria else { return }

        if let displayManager = window?.avDisplayManager {
            print("🎬 AVPlayerUIView: Resetting display criteria")
            displayManager.preferredDisplayCriteria = nil
        }
        hasSetDisplayCriteria = false
    }

    deinit {
        readyForDisplayObservation?.invalidate()
        playerItemStatusObservation?.invalidate()
        // Note: Can't call resetDisplayCriteria here as window may be nil
        // The system will reset display mode automatically when the view is removed
    }
}

#Preview {
    AVPlayerView(playerWrapper: AVPlayerWrapper())
        .frame(width: 400, height: 300)
        .background(Color.black)
}
