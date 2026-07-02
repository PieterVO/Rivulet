//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  Transport scrubber styled after AVPlayerViewController (tvOS 15+):
//  a thin rounded white bar with no knob — the fill edge is the playhead.
//  While scrubbing the bar thickens slightly, the scrub time follows the
//  playhead below the bar, a ghost fill marks the actual playback
//  position, and a thumbnail preview floats above. Time remaining sits
//  below the right end. Plex markers (intro/credits) tint their range.
//
//  The view's own height covers only the track + label band; the
//  thumbnail overhangs above it (clipsToBounds = false) so the transport
//  bar doesn't reserve blank space when not scrubbing.
//

import UIKit

final class PlayerProgressBarView: UIView {

    // MARK: - Metrics (AVPlayerViewController-matched)

    private enum Metrics {
        static let trackHeight: CGFloat = 8
        static let trackHeightScrubbing: CGFloat = 12
        static let labelBandSpacing: CGFloat = 14
        static let thumbnailWidth: CGFloat = 320
        static let thumbnailHeight: CGFloat = 180
        static let thumbnailGap: CGFloat = 20
    }

    // MARK: - Marker coloring

    static func color(for marker: PlexMarker) -> UIColor {
        if marker.isIntro {
            return .systemBlue
        } else if marker.isCredits {
            return .systemPurple
        } else {
            return .systemYellow
        }
    }

    // MARK: - Subviews

    private let trackBackground = UIView()
    private let currentPositionGhost = UIView()
    private let progressFill = UIView()
    private let markersContainer = UIView()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let scrubStepLabel = UILabel()
    private let thumbnailImageView = UIImageView()
    private let thumbnailContainer = UIView()

    private var trackHeightConstraint: NSLayoutConstraint!
    private var currentTimeCenterXConstraint: NSLayoutConstraint!
    private var thumbnailCenterXConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        clipsToBounds = false

        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        trackBackground.layer.cornerCurve = .continuous
        trackBackground.clipsToBounds = true

        // Actual playback position while previewing elsewhere.
        currentPositionGhost.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        currentPositionGhost.isHidden = true

        progressFill.backgroundColor = .white

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        currentTimeLabel.textColor = .white

        remainingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        remainingTimeLabel.textAlignment = .right

        scrubStepLabel.font = .systemFont(ofSize: 20, weight: .medium)
        scrubStepLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        scrubStepLabel.isHidden = true

        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true

        thumbnailContainer.isHidden = true
        thumbnailContainer.layer.cornerRadius = 12
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        thumbnailContainer.layer.borderWidth = 1
        thumbnailContainer.layer.shadowColor = UIColor.black.cgColor
        thumbnailContainer.layer.shadowOpacity = 0.4
        thumbnailContainer.layer.shadowRadius = 16
        thumbnailContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        thumbnailContainer.clipsToBounds = false
        thumbnailImageView.layer.cornerRadius = 12
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailContainer.addSubview(thumbnailImageView)

        [trackBackground, thumbnailContainer, currentTimeLabel, remainingTimeLabel, scrubStepLabel].forEach {
            addSubview($0)
        }
        [currentPositionGhost, progressFill, markersContainer].forEach {
            trackBackground.addSubview($0)
        }

        [trackBackground, thumbnailContainer, thumbnailImageView,
         currentTimeLabel, remainingTimeLabel, scrubStepLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        trackHeightConstraint = trackBackground.heightAnchor.constraint(equalToConstant: Metrics.trackHeight)
        currentTimeCenterXConstraint = currentTimeLabel.centerXAnchor.constraint(equalTo: leadingAnchor)
        thumbnailCenterXConstraint = thumbnailContainer.centerXAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            trackBackground.topAnchor.constraint(equalTo: topAnchor),
            trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackHeightConstraint,

            // Thumbnail overhangs above the view; no reserved space.
            thumbnailContainer.bottomAnchor.constraint(equalTo: trackBackground.topAnchor, constant: -Metrics.thumbnailGap),
            thumbnailContainer.widthAnchor.constraint(equalToConstant: Metrics.thumbnailWidth),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: Metrics.thumbnailHeight),
            thumbnailCenterXConstraint,

            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

            // Label band below the track. The scrub time follows the
            // playhead (AVPlayerViewController behavior); remaining time
            // is pinned below the right end.
            currentTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            currentTimeCenterXConstraint,

            scrubStepLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            scrubStepLabel.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 16),

            remainingTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            remainingTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottomAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackBackground.layer.cornerRadius = trackHeightConstraint.constant / 2
    }

    // MARK: - Update

    func update(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isScrubbing: Bool,
        scrubTime: TimeInterval,
        scrubStepLabelText: String?,
        scrubThumbnail: UIImage?,
        markers: [PlexMarker]
    ) {
        let displayTime = isScrubbing ? scrubTime : currentTime
        let progress: Double = duration > 0 ? min(1, max(0, displayTime / duration)) : 0

        let width = trackBackground.bounds.width
        let trackHeight = isScrubbing ? Metrics.trackHeightScrubbing : Metrics.trackHeight

        currentPositionGhost.isHidden = !isScrubbing
        let currentProgress: Double = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
        trackHeightConstraint.constant = trackHeight

        UIView.animate(withDuration: 0.15) {
            self.progressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: trackHeight)
            if isScrubbing {
                self.currentPositionGhost.frame = CGRect(
                    x: 0, y: 0,
                    width: width * currentProgress,
                    height: trackHeight
                )
            }
            self.layoutIfNeeded()
        }

        renderMarkers(markers, duration: duration, trackWidth: width, trackHeight: trackHeight)

        // The playhead-following time label appears only while scrubbing
        // (the control buttons own that band otherwise), clamped so it
        // never runs off the track ends or under the remaining-time label.
        currentTimeLabel.isHidden = !isScrubbing
        currentTimeLabel.text = Self.formatTime(displayTime)
        currentTimeLabel.sizeToFit()
        let halfLabel = currentTimeLabel.bounds.width / 2
        let remainingWidth = remainingTimeLabel.intrinsicContentSize.width
        let minCenter = halfLabel
        let maxCenter = max(minCenter, width - remainingWidth - 24 - halfLabel)
        currentTimeCenterXConstraint.constant = min(maxCenter, max(minCenter, width * CGFloat(progress)))

        remainingTimeLabel.text = "-\(Self.formatTime(max(0, duration - displayTime)))"

        scrubStepLabel.isHidden = !isScrubbing || scrubStepLabelText == nil
        scrubStepLabel.text = scrubStepLabelText

        thumbnailContainer.isHidden = !(isScrubbing && scrubThumbnail != nil)
        thumbnailImageView.image = scrubThumbnail
        if isScrubbing {
            // Clamp the thumbnail inside the track bounds like
            // AVPlayerViewController does at the extremes.
            let halfThumb = Metrics.thumbnailWidth / 2
            let clampedCenter = min(max(width * CGFloat(progress), halfThumb), max(halfThumb, width - halfThumb))
            thumbnailCenterXConstraint.constant = clampedCenter
        }
    }

    private func renderMarkers(_ markers: [PlexMarker], duration: TimeInterval, trackWidth: CGFloat, trackHeight: CGFloat) {
        markersContainer.subviews.forEach { $0.removeFromSuperview() }
        guard duration > 0 else { return }

        for marker in markers {
            let startProgress = max(0, marker.startTimeSeconds / duration)
            let endProgress = min(1, marker.endTimeSeconds / duration)
            guard endProgress > startProgress else { continue }

            let markerView = UIView()
            markerView.backgroundColor = Self.color(for: marker).withAlphaComponent(0.85)
            let x = trackWidth * CGFloat(startProgress)
            let markerWidth = max(4, trackWidth * CGFloat(endProgress - startProgress))
            markerView.frame = CGRect(x: x, y: 0, width: markerWidth, height: trackHeight)
            markersContainer.addSubview(markerView)
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
