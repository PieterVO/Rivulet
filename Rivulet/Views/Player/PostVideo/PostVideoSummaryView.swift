//
//  PostVideoSummaryView.swift
//  Rivulet
//
//  Container view that displays the appropriate post-video overlay based on content type
//

import SwiftUI

/// Focus targets for post-video overlays
enum PostVideoFocusTarget: Hashable {
    case playNext
    case cancel
    case close
    case season
    case show
}

struct PostVideoSummaryView: View {
    @ObservedObject var viewModel: UniversalPlayerViewModel

    var body: some View {
        Group {
            switch viewModel.postVideoState {
            case .hidden:
                EmptyView()

            case .loading:
                // Loading state - subtle indicator
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()

                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }

            case .showingEpisodeSummary:
                EpisodeSummaryOverlay(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))

            case .showingMovieSummary:
                MovieSummaryOverlay(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: viewModel.postVideoState)
    }
}

#Preview("Episode Summary") {
    PostVideoSummaryView(
        viewModel: {
            let vm = UniversalPlayerViewModel(
                metadata: PlexMetadata(ratingKey: "1", type: "episode", title: "Test Episode"),
                serverURL: "http://localhost:32400",
                authToken: "test"
            )
            vm.postVideoState = .showingEpisodeSummary
            return vm
        }()
    )
}

#Preview("Movie Summary") {
    PostVideoSummaryView(
        viewModel: {
            let vm = UniversalPlayerViewModel(
                metadata: PlexMetadata(ratingKey: "1", type: "movie", title: "Test Movie"),
                serverURL: "http://localhost:32400",
                authToken: "test"
            )
            vm.postVideoState = .showingMovieSummary
            return vm
        }()
    )
}
