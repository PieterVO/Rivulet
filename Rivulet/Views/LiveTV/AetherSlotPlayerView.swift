//
//  AetherSlotPlayerView.swift
//  Rivulet
//
//  Render surface for a single Live TV grid slot backed by AetherPlayer.
//  AetherPlayer drives an internally-created AVPlayer (republished as
//  `currentAVPlayer` and swapped on internal reloads), so the slot subscribes
//  to that publisher and hosts the current player in an AVPlayerLayer. While
//  the player is nil (pre-load / between reloads) the slot stays black.
//

import SwiftUI
import AVFoundation

struct AetherSlotPlayerView: View {
    let player: AetherPlayer

    @State private var avPlayer: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let avPlayer {
                AVPlayerLayerView(player: avPlayer)
            }
        }
        .onReceive(player.$currentAVPlayer) { avPlayer = $0 }
    }
}
