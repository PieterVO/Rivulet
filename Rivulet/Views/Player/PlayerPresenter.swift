//
//  PlayerPresenter.swift
//  Rivulet
//
//  Single source of truth for building the playback presentation host.
//  Aether is the only VOD engine; every VOD session presents through
//  PlayerContainerViewController.
//

import SwiftUI
import UIKit

@MainActor
enum PlayerPresenter {

    /// Build the UIViewController to present for the given playback session.
    static func makeViewController(
        viewModel: UniversalPlayerViewModel,
        onDismiss: (() -> Void)? = nil
    ) -> UIViewController {
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
    }
}
