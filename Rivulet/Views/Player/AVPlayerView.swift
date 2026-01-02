//
//  AVPlayerView.swift
//  Rivulet
//
//  SwiftUI wrapper for AVPlayer-based video playback
//  Used for Live TV streams for better resource efficiency
//

import SwiftUI
import AVFoundation
import Combine

/// A SwiftUI view that displays video content using AVPlayer
struct AVPlayerView: UIViewRepresentable {
    @ObservedObject var playerWrapper: AVPlayerWrapper

    func makeUIView(context: Context) -> AVPlayerUIView {
        let view = AVPlayerUIView()
        // Attach player immediately if available
        if let player = playerWrapper.player {
            view.player = player
            print("🎬 AVPlayerView: Attached player on creation")
        }
        return view
    }

    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {
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

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue
            // Debug: Log video track info
            if let currentItem = newValue?.currentItem {
                let asset = currentItem.asset
                let videoTracks = asset.tracks(withMediaType: .video)
                print("🎬 AVPlayerUIView: Player attached - video tracks: \(videoTracks.count)")
                for (i, track) in videoTracks.enumerated() {
                    print("🎬 AVPlayerUIView: Track \(i): naturalSize=\(track.naturalSize), enabled=\(track.isEnabled)")
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // AVPlayerLayer automatically resizes with the view
        print("🎬 AVPlayerUIView: layoutSubviews - bounds=\(bounds), layer.frame=\(playerLayer.frame)")
        print("🎬 AVPlayerUIView: videoRect=\(playerLayer.videoRect), isReadyForDisplay=\(playerLayer.isReadyForDisplay)")
    }
}

#Preview {
    AVPlayerView(playerWrapper: AVPlayerWrapper())
        .frame(width: 400, height: 300)
        .background(Color.black)
}
