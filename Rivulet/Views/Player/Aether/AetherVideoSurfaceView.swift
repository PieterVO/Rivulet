//
//  AetherVideoSurfaceView.swift
//  Rivulet
//
//  SwiftUI wrapper for AetherEngine's render surface (AetherPlayerView).
//  The engine attaches whichever CALayer the active backend uses —
//  AVPlayerLayer on the native loopback-HLS path, or
//  AVSampleBufferDisplayLayer on the software path (AV1 / VP9 / MPEG-2 /
//  VC-1 / MPEG-4 Part 2) — and re-attaches it across internal session
//  swaps (audio-track switch, background reopen). Hosting this view is
//  the only correct way to display Aether video: binding an
//  AVPlayerLayer to `currentAVPlayer` covers the native backend only.
//

import SwiftUI
import AetherEngine

struct AetherVideoSurfaceView: UIViewRepresentable {
    let player: AetherPlayer

    @MainActor
    final class Coordinator {
        var boundPlayer: AetherPlayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        player.bind(view: view)
        context.coordinator.boundPlayer = player
        return view
    }

    func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        guard context.coordinator.boundPlayer !== player else { return }
        context.coordinator.boundPlayer?.unbind(view: uiView)
        player.bind(view: uiView)
        context.coordinator.boundPlayer = player
    }

    static func dismantleUIView(_ uiView: AetherPlayerView, coordinator: Coordinator) {
        coordinator.boundPlayer?.unbind(view: uiView)
        coordinator.boundPlayer = nil
    }
}
