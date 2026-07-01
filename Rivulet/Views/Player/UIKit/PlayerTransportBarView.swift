//
//  PlayerTransportBarView.swift
//  Rivulet
//
//  Native UIKit transport bar: title, progress bar, skip button. Pill
//  row (subtitles/audio/info) is added in a later task. Replaces
//  PlayerControlsOverlay's transport-bar half (SwiftUI) for every route.
//

import UIKit
import Combine

final class PlayerTransportBarView: UIView {

    private weak var viewModel: UniversalPlayerViewModel?
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bufferingIndicator = UIActivityIndicatorView(style: .medium)
    let progressBar = PlayerProgressBarView()
    private let skipButton = UIButton(type: .system)
    private let backgroundEffectView: UIVisualEffectView

    let subtitlesPill = PlayerPillButton(icon: UIImage(systemName: "captions.bubble"), title: "Subtitles")
    let audioPill = PlayerPillButton(icon: UIImage(systemName: "speaker.wave.3"), title: "Audio")
    let infoPill = PlayerPillButton(icon: UIImage(systemName: "info.circle"), title: "Info")
    private let pillStack = UIStackView()

    private var activePopup: PlayerTrackPopupView?

    var onSkipTapped: (() -> Void)?

    var hasActivePopup: Bool { activePopup != nil }

    func dismissActivePopup() {
        activePopup?.dismiss()
    }

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupViews()
        bind()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        addSubview(backgroundEffectView)

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 20, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.numberOfLines = 1

        bufferingIndicator.color = .white
        bufferingIndicator.hidesWhenStopped = true

        skipButton.setTitleColor(.white, for: .normal)
        skipButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        skipButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        skipButton.layer.cornerRadius = 12
        skipButton.layer.cornerCurve = .continuous
        skipButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .primaryActionTriggered)

        [titleLabel, subtitleLabel, bufferingIndicator, progressBar, skipButton].forEach { addSubview($0) }

        [backgroundEffectView, titleLabel, subtitleLabel, bufferingIndicator, progressBar, skipButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        pillStack.axis = .horizontal
        pillStack.spacing = 16
        pillStack.addArrangedSubview(subtitlesPill)
        pillStack.addArrangedSubview(audioPill)
        pillStack.addArrangedSubview(infoPill)
        addSubview(pillStack)
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: skipButton.leadingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            bufferingIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bufferingIndicator.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),

            skipButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -80),

            pillStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pillStack.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -80),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
        ])
    }

    private func bind() {
        guard let viewModel else { return }

        viewModel.$currentTime
            .combineLatest(viewModel.$duration, viewModel.$isScrubbing, viewModel.$scrubTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentTime, duration, isScrubbing, scrubTime in
                guard let self, let viewModel = self.viewModel else { return }
                self.progressBar.update(
                    currentTime: currentTime,
                    duration: duration,
                    isScrubbing: isScrubbing,
                    scrubTime: scrubTime,
                    scrubStepLabelText: viewModel.scrubStepLabel,
                    scrubThumbnail: viewModel.scrubThumbnail,
                    markers: viewModel.metadata.allMarkers
                )
            }
            .store(in: &cancellables)

        viewModel.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffering in
                if buffering {
                    self?.bufferingIndicator.startAnimating()
                } else {
                    self?.bufferingIndicator.stopAnimating()
                }
            }
            .store(in: &cancellables)

        viewModel.$showSkipButton
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                self?.skipButton.isHidden = !show
                self?.skipButton.setTitle(self?.viewModel?.skipButtonLabel, for: .normal)
            }
            .store(in: &cancellables)

        titleLabel.text = viewModel.title
        subtitleLabel.text = viewModel.subtitle
        subtitleLabel.isHidden = viewModel.subtitle == nil

        subtitlesPill.onPress = { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            let popup = PlayerTrackPopupView(
                tracks: viewModel.subtitleTracks,
                selectedTrackId: viewModel.currentSubtitleTrackId,
                showsOffRow: true,
                onSelect: { id in viewModel.selectSubtitleTrack(id: id) }
            )
            self.presentPopup(popup, anchoredTo: self.subtitlesPill)
        }

        audioPill.onPress = { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            let popup = PlayerTrackPopupView(
                tracks: viewModel.audioTracks,
                selectedTrackId: viewModel.currentAudioTrackId,
                showsOffRow: false,
                onSelect: { id in
                    guard let id else { return }
                    viewModel.selectAudioTrack(id: id)
                }
            )
            self.presentPopup(popup, anchoredTo: self.audioPill)
        }
    }

    private func presentPopup(_ popup: PlayerTrackPopupView, anchoredTo pill: PlayerPillButton) {
        guard let container = superview else { return }
        activePopup?.dismiss()
        popup.onDismiss = { [weak self] in self?.activePopup = nil }
        activePopup = popup
        popup.present(in: container, anchoredTo: pill)
    }

    @objc private func skipTapped() {
        onSkipTapped?()
    }
}
