//
//  AetherSlotPlayerView.swift
//  Rivulet
//
//  Render surface for a single Live TV grid slot backed by AetherPlayer.
//  Hosts the engine's own render surface (AetherVideoSurfaceView), which
//  covers both backends: AVPlayerLayer on the native loopback-HLS path and
//  AVSampleBufferDisplayLayer on the software path (raw MPEG-2 broadcast
//  streams from HDHomeRun tuners land there). The engine re-attaches the
//  layer across internal reloads, so no per-swap rebinding is needed here.
//

import SwiftUI

struct AetherSlotPlayerView: View {
    let player: AetherPlayer

    var body: some View {
        ZStack {
            Color.black
            AetherVideoSurfaceView(player: player)
        }
    }
}
