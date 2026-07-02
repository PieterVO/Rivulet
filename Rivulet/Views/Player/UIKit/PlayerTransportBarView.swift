//
//  PlayerTransportBarView.swift
//  Rivulet
//
//  Native UIKit transport bar styled after AVPlayerViewController
//  (tvOS 15+): bottom scrim gradient, small metadata line above a large
//  title at the lower left, thin scrubber, time remaining below the
//  bar's right end, and a row of circular control buttons (Subtitles /
//  Audio / Info) below the bar's left end. While scrubbing, the chrome
//  fades out and only the scrubber + preview remain, matching the
//  system player.
//

import UIKit
import Combine

final class PlayerTransportBarView: UIView {

    private enum Metrics {
        static let sideMargin: CGFloat = 90
        static let bottomMargin: CGFloat = 60
        static let titleBarGap: CGFloat = 28
        static let controlsRowGap: CGFloat = 24
    }

    private weak var viewModel: UniversalPlayerViewModel?
    private var cancellables = Set<AnyCancellable>()

    private let gradientView = TransportScrimView()
    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let bufferingIndicator = UIActivityIndicatorView(style: .medium)
    let progressBar = PlayerProgressBarView()
    private let skipButton = SkipPillButton()

    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles")
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio")
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info"), accessibilityLabel: "Info")
    private let controlsRow = UIStackView()

    private var activePopup: (any AnchoredPopupPresenting)?

    var onSkipTapped: (() -> Void)?

    var hasActivePopup: Bool { activePopup != nil }

    func dismissActivePopup() {
        activePopup?.dismiss()
    }

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupViews()
        bind()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        addSubview(gradientView)

        // AVPlayerViewController order: small metadata line above the
        // large title (e.g. "Severance S1E2" over the episode title).
        secondaryLabel.font = .systemFont(ofSize: 23, weight: .medium)
        secondaryLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        secondaryLabel.numberOfLines = 1

        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        bufferingIndicator.color = .white
        bufferingIndicator.hidesWhenStopped = true

        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .primaryActionTriggered)

        controlsRow.axis = .horizontal
        controlsRow.spacing = 20
        controlsRow.addArrangedSubview(subtitlesButton)
        controlsRow.addArrangedSubview(audioButton)
        controlsRow.addArrangedSubview(infoButton)

        [gradientView, secondaryLabel, titleLabel, bufferingIndicator,
         progressBar, skipButton, controlsRow].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            gradientView.topAnchor.constraint(equalTo: topAnchor),
            gradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gradientView.bottomAnchor.constraint(equalTo: bottomAnchor),

            secondaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            secondaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideMargin),
            secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: skipButton.leadingAnchor, constant: -24),

            titleLabel.topAnchor.constraint(equalTo: secondaryLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: secondaryLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: skipButton.leadingAnchor, constant: -24),

            bufferingIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bufferingIndicator.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),

            skipButton.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -Metrics.titleBarGap),
            skipButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideMargin),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.titleBarGap),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideMargin),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideMargin),

            controlsRow.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: Metrics.controlsRowGap),
            controlsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideMargin),
            controlsRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomMargin),
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
                self.setChrome(hidden: isScrubbing)
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
        secondaryLabel.text = viewModel.subtitle
        secondaryLabel.isHidden = viewModel.subtitle == nil

        subtitlesButton.onPress = { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            let popup = PlayerTrackPopupView(
                header: "Subtitles",
                tracks: viewModel.subtitleTracks,
                selectedTrackId: viewModel.currentSubtitleTrackId,
                showsOffRow: true,
                onSelect: { id in viewModel.selectSubtitleTrack(id: id) }
            )
            self.presentPopup(popup, anchoredTo: self.subtitlesButton)
        }

        audioButton.onPress = { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            let popup = PlayerTrackPopupView(
                header: "Audio",
                tracks: viewModel.audioTracks,
                selectedTrackId: viewModel.currentAudioTrackId,
                showsOffRow: false,
                onSelect: { id in
                    guard let id else { return }
                    viewModel.selectAudioTrack(id: id)
                }
            )
            self.presentPopup(popup, anchoredTo: self.audioButton)
        }

        infoButton.onPress = { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            let popup = PlayerInfoPopupView(metadata: viewModel.metadata)
            self.presentPopup(popup, anchoredTo: self.infoButton)
        }
    }

    /// AVPlayerViewController fades the title and controls while
    /// scrubbing so only the scrubber, time, and preview remain.
    private var chromeHidden = false
    private func setChrome(hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        UIView.animate(withDuration: 0.15) {
            [self.titleLabel, self.secondaryLabel, self.controlsRow, self.skipButton].forEach {
                $0.alpha = hidden ? 0 : 1
            }
        }
    }

    private func presentPopup<Popup: AnchoredPopupPresenting>(_ popup: Popup, anchoredTo anchor: UIView) {
        guard let container = superview else { return }
        activePopup?.dismiss()
        var mutablePopup = popup
        mutablePopup.onDismiss = { [weak self] in self?.activePopup = nil }
        activePopup = mutablePopup
        mutablePopup.present(in: container, anchoredTo: anchor)
    }

    @objc private func skipTapped() {
        onSkipTapped?()
    }
}

// MARK: - Scrim

/// Bottom scrim gradient (clear → black) matching the system player's
/// transport backdrop. A UIView-backed gradient so it rides any
/// animation clock the bar itself is on.
private final class TransportScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.black.withAlphaComponent(0.8).cgColor,
        ]
        gradient.locations = [0, 0.45, 1]
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Skip pill

/// "Skip Intro" / "Skip Credits" capsule above the bar's right end,
/// matching the system-player pill: translucent glass at rest, white
/// fill with black text when focused.
private final class SkipPillButton: UIButton {

    private let effectView: UIVisualEffectView

    init() {
        if #available(tvOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        insertSubview(effectView, at: 0)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        contentEdgeInsets = UIEdgeInsets(top: 12, left: 26, bottom: 12, right: 26)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
        effectView.layer.cornerRadius = bounds.height / 2
        effectView.layer.cornerCurve = .continuous
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
            self.effectView.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
            self.setTitleColor(isFocused ? .black : .white, for: .normal)
        }, completion: nil)
    }
}
