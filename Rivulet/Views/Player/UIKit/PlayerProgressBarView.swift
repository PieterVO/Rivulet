//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  UIKit transport progress bar: scrub track, marker highlights, playhead,
//  time labels, and scrub thumbnail preview. Ports TransportProgressBar
//  (formerly private inside PlayerControlsOverlay.swift) to native UIKit.
//

import UIKit

final class PlayerProgressBarView: UIView {

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
    private let currentProgressFill = UIView()
    private let scrubProgressFill = UIView()
    private let playheadView = UIView()
    private let markersContainer = UIView()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let scrubStepLabel = UILabel()
    private let thumbnailImageView = UIImageView()
    private let thumbnailContainer = UIView()

    private var trackHeightConstraint: NSLayoutConstraint!
    private var playheadWidthConstraint: NSLayoutConstraint!
    private var playheadHeightConstraint: NSLayoutConstraint!
    private var playheadLeadingConstraint: NSLayoutConstraint!
    private var thumbnailCenterXConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        trackBackground.layer.cornerRadius = 3
        trackBackground.layer.cornerCurve = .continuous

        currentProgressFill.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        currentProgressFill.isHidden = true

        scrubProgressFill.backgroundColor = .white

        playheadView.backgroundColor = .white
        playheadView.layer.shadowColor = UIColor.black.cgColor
        playheadView.layer.shadowOpacity = 0.3
        playheadView.layer.shadowRadius = 4
        playheadView.layer.shadowOffset = CGSize(width: 0, height: 2)

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        currentTimeLabel.textColor = .white

        remainingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        remainingTimeLabel.textAlignment = .right

        scrubStepLabel.font = .systemFont(ofSize: 20, weight: .medium)
        scrubStepLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        scrubStepLabel.isHidden = true

        thumbnailImageView.contentMode = .scaleAspectFit
        thumbnailImageView.layer.cornerRadius = 8
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        thumbnailImageView.layer.borderWidth = 1

        thumbnailContainer.isHidden = true
        thumbnailContainer.addSubview(thumbnailImageView)

        [trackBackground, currentProgressFill, scrubProgressFill, markersContainer, playheadView].forEach {
            addSubview($0)
        }
        addSubview(thumbnailContainer)
        addSubview(currentTimeLabel)
        addSubview(remainingTimeLabel)
        addSubview(scrubStepLabel)

        [trackBackground, currentProgressFill, scrubProgressFill, markersContainer, playheadView,
         thumbnailContainer, thumbnailImageView, currentTimeLabel, remainingTimeLabel, scrubStepLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        trackHeightConstraint = trackBackground.heightAnchor.constraint(equalToConstant: 6)
        playheadWidthConstraint = playheadView.widthAnchor.constraint(equalToConstant: 16)
        playheadHeightConstraint = playheadView.heightAnchor.constraint(equalToConstant: 16)
        playheadLeadingConstraint = playheadView.leadingAnchor.constraint(equalTo: trackBackground.leadingAnchor)
        thumbnailCenterXConstraint = thumbnailContainer.centerXAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            thumbnailContainer.bottomAnchor.constraint(equalTo: trackBackground.topAnchor, constant: -12),
            thumbnailContainer.widthAnchor.constraint(equalToConstant: 240),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: 135),
            thumbnailCenterXConstraint,

            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

            trackBackground.topAnchor.constraint(equalTo: topAnchor, constant: 155),
            trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackHeightConstraint,

            currentProgressFill.leadingAnchor.constraint(equalTo: trackBackground.leadingAnchor),
            currentProgressFill.topAnchor.constraint(equalTo: trackBackground.topAnchor),
            currentProgressFill.bottomAnchor.constraint(equalTo: trackBackground.bottomAnchor),

            scrubProgressFill.leadingAnchor.constraint(equalTo: trackBackground.leadingAnchor),
            scrubProgressFill.topAnchor.constraint(equalTo: trackBackground.topAnchor),
            scrubProgressFill.bottomAnchor.constraint(equalTo: trackBackground.bottomAnchor),

            markersContainer.leadingAnchor.constraint(equalTo: trackBackground.leadingAnchor),
            markersContainer.trailingAnchor.constraint(equalTo: trackBackground.trailingAnchor),
            markersContainer.topAnchor.constraint(equalTo: trackBackground.topAnchor),
            markersContainer.bottomAnchor.constraint(equalTo: trackBackground.bottomAnchor),

            playheadLeadingConstraint,
            playheadView.centerYAnchor.constraint(equalTo: trackBackground.centerYAnchor),
            playheadWidthConstraint,
            playheadHeightConstraint,

            currentTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: 8),
            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scrubStepLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            scrubStepLabel.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 16),

            remainingTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: 8),
            remainingTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        playheadView.layer.cornerRadius = 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playheadView.layer.cornerRadius = playheadWidthConstraint.constant / 2
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

        currentProgressFill.isHidden = !isScrubbing
        if isScrubbing {
            let currentProgress: Double = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            currentProgressFill.frame = CGRect(
                x: 0, y: 0,
                width: trackBackground.bounds.width * currentProgress,
                height: trackBackground.bounds.height
            )
        }

        scrubProgressFill.backgroundColor = isScrubbing ? .systemBlue : .white
        playheadView.backgroundColor = isScrubbing ? .systemBlue : .white

        let width = trackBackground.bounds.width
        scrubProgressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: trackBackground.bounds.height)

        let diameter: CGFloat = isScrubbing ? 24 : 16
        playheadWidthConstraint.constant = diameter
        playheadHeightConstraint.constant = diameter
        let maxLeading = width - diameter
        playheadLeadingConstraint.constant = max(0, min(maxLeading, width * progress - diameter / 2))
        trackHeightConstraint.constant = isScrubbing ? 10 : 6

        UIView.animate(withDuration: 0.15) {
            self.layoutIfNeeded()
        }

        renderMarkers(markers, duration: duration, trackWidth: width, trackHeight: trackBackground.bounds.height)

        currentTimeLabel.text = Self.formatTime(displayTime)
        currentTimeLabel.textColor = isScrubbing ? .systemBlue : .white
        remainingTimeLabel.text = "-\(Self.formatTime(max(0, duration - displayTime)))"

        scrubStepLabel.isHidden = !isScrubbing || scrubStepLabelText == nil
        scrubStepLabel.text = scrubStepLabelText

        thumbnailContainer.isHidden = !(isScrubbing && scrubThumbnail != nil)
        thumbnailImageView.image = scrubThumbnail
        if isScrubbing {
            thumbnailCenterXConstraint.constant = width * CGFloat(progress)
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
            markerView.layer.cornerRadius = 2
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
