//
//  NextEpisodeCard.swift
//  Rivulet
//
//  Card displaying next episode information for post-video summary
//

import SwiftUI

struct NextEpisodeCard: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }

    private var episodeString: String {
        let season = episode.parentIndex ?? 0
        let ep = episode.index ?? 0
        return String(format: "S%02dE%02d", season, ep)
    }

    private var showTitle: String {
        episode.grandparentTitle ?? ""
    }

    var body: some View {
        HStack(spacing: 24) {
            // Episode thumbnail
            CachedAsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .overlay {
                            Image(systemName: "tv")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                case .empty:
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                }
            }
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Episode info
            VStack(alignment: .leading, spacing: 8) {
                // Show title
                if !showTitle.isEmpty {
                    Text(showTitle)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                // Episode title with number
                HStack(spacing: 12) {
                    Text(episodeString)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    Text(episode.title ?? "Episode")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                // Episode description
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                // Duration if available
                if let duration = episode.duration {
                    let minutes = duration / 60000
                    Text("\(minutes) min")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)  // Force dark on bright HDR/DV content
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        NextEpisodeCard(
            episode: PlexMetadata(
                ratingKey: "123",
                type: "episode",
                title: "The One Where They Build a Post-Video Screen",
                summary: "The gang discovers the joy of autoplay when binge-watching their favorite shows. Hilarity ensues.",
                duration: 1320000,
                parentIndex: 1,
                grandparentTitle: "Friends",
                index: 5
            ),
            serverURL: "http://localhost:32400",
            authToken: "test"
        )
        .padding(40)
    }
}
