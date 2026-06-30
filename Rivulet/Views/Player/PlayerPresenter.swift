//
//  PlayerPresenter.swift
//  Rivulet
//
//  Single source of truth for picking the right presentation host based
//  on the user's PlayerPreference:
//
//    - .rivulet -> UniversalPlayerView inside PlayerContainerViewController.
//    - .apple   -> UniversalPlayerView inside PlayerContainerViewController.
//                  (viewModel routes internally to AVPlayer; UniversalPlayerView
//                   renders via AVPlayerLayerView when rivuletPlayer is nil)
//    - .aether  -> AetherPlayerViewController (AVPlayerViewController subclass).
//                  Stays on AVKit for native track picker + AVContentProposal.
//

import SwiftUI
import UIKit

@MainActor
enum PlayerPresenter {

    /// Build the UIViewController to present for the given playback
    /// session. The view model is shared between hosts; only the
    /// presentation surface differs.
    static func makeViewController(
        viewModel: UniversalPlayerViewModel,
        onDismiss: (() -> Void)? = nil
    ) -> UIViewController {
        switch PlayerPreference.current {
        case .rivulet, .apple:
            let inputCoordinator = PlaybackInputCoordinator()
            let playerView = UniversalPlayerView(
                viewModel: viewModel,
                inputCoordinator: inputCoordinator
            )
            let vc = PlayerContainerViewController(
                rootView: playerView,
                viewModel: viewModel,
                inputCoordinator: inputCoordinator
            )
            vc.onDismiss = onDismiss
            return vc

        case .aether:
            let vc = AetherPlayerViewController(viewModel: viewModel)
            vc.onDismiss = onDismiss
            return vc
        }
    }
}
