//
//  PlayerTransportBarView.swift
//  Rivulet
//
//  Native UIKit transport bar styled after AVPlayerViewController
//  (tvOS 15+): bottom scrim gradient, small metadata line above a large
//  title at the lower left, thin scrubber, time remaining below the
//  bar's right end. The transport controls (Skip pill, "What did they
//  say?" replay, Subtitles, Audio, reserved Browse slot) sit above the
//  bar's right end; Info sits below the bar's left end. While scrubbing,
//  the chrome fades out and only the scrubber + preview remain, matching
//  the system player.
//
//  Focus: buttons are reached via the view model's controlsFocusActive
//  mode (PlayerContainerViewController routes focus here through
//  preferredFocusEnvironments). The bar remembers the last focused
//  control so focus returns there after a popup closes.
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
    /// Title logo shown in place of `titleLabel` during the ambient pause
    /// moment (Task 7): same leading edge and baseline as the text title,
    /// swapped in only when both a logo image is resolved and the pause
    /// presentation has left `.frame`.
    private let logoImageView = UIImageView()
    private let bufferingIndicator = UIActivityIndicatorView(style: .medium)
    let progressBar = PlayerProgressBarView()
    private let skipButton = SkipPillButton()

    let replayButton = TransportControlButton(
        icon: UIImage(systemName: "gobackward.15"), accessibilityLabel: "What did they say?")
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles")
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio")
    /// Reserved slot for the episode-wheel browse feature (deferred). Hidden
    /// until the wheel ships; keeps the row's layout and focus order stable
    /// for when it does.
    let browseButton = TransportControlButton(
        icon: UIImage(systemName: "list.and.film"), accessibilityLabel: "Browse")
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

        logoImageView.contentMode = .scaleAspectFit
        logoImageView.isHidden = true

        bufferingIndicator.color = .white
        bufferingIndicator.hidesWhenStopped = true

        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .primaryActionTriggered)

        // Transport controls above the bar's right end (system-player
        // placement); the skip pill collapses out of the stack when hidden.
        controlsRow.axis = .horizontal
        controlsRow.spacing = 20
        controlsRow.alignment = .center
        controlsRow.addArrangedSubview(skipButton)
        controlsRow.addArrangedSubview(replayButton)
        controlsRow.addArrangedSubview(subtitlesButton)
        controlsRow.addArrangedSubview(audioButton)
        controlsRow.addArrangedSubview(browseButton)
        browseButton.isHidden = true

        [gradientView, secondaryLabel, titleLabel, logoImageView, bufferingIndicator,
         progressBar, controlsRow, infoButton].forEach {
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
            secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlsRow.leadingAnchor, constant: -24),

            titleLabel.topAnchor.constraint(equalTo: secondaryLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: secondaryLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlsRow.leadingAnchor, constant: -24),

            logoImageView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logoImageView.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            logoImageView.heightAnchor.constraint(equalToConstant: 68),
            logoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            logoImageView.trailingAnchor.constraint(lessThanOrEqualTo: controlsRow.leadingAnchor, constant: -24),

            bufferingIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bufferingIndicator.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),

            controlsRow.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -Metrics.titleBarGap),
            controlsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideMargin),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.titleBarGap),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideMargin),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideMargin),

            infoButton.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: Metrics.controlsRowGap),
            infoButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideMargin),
            infoButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomMargin),
        ])
    }

    // MARK: - Focus

    /// The control focus should land on when entering controls-focus
    /// mode, or return to after a popup closes.
    private weak var lastFocusedControl: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch viewModel?.controlsFocusEntry {
        case .up:
            return [subtitlesButton]
        case .down:
            return [infoButton]
        case nil:
            break
        }
        if let last = lastFocusedControl, !last.isHidden {
            return [last]
        }
        return [subtitlesButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self),
           next is UIControl {
            lastFocusedControl = next
            // Entry direction served its purpose once focus lands.
            viewModel?.clearControlsFocusEntry()
        }
    }

    private func bind() {
        guard let viewModel else { return }

        progressBar.filmstripProvider = { [weak viewModel] times, maxWidth in
            await viewModel?.filmstripImages(times: times, maxPixelWidth: maxWidth) ?? times.map { _ in nil }
        }

        // `metadata` itself isn't @Published (see UniversalPlayerViewModel),
        // so the view model bumps `itemGeneration` whenever it swaps to a
        // different playable item on this same instance (e.g. auto-advance
        // via playNextEpisode()). Reset the filmstrip's cached tiles on
        // every such swap so the next scrub doesn't show stale frames from
        // the previous episode. dropFirst() skips the initial publish at
        // subscription time (current item, nothing to reset).
        viewModel.$itemGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.progressBar.resetFilmstrip()
            }
            .store(in: &cancellables)

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
                    markers: viewModel.metadata.allMarkers,
                    chapters: viewModel.metadata.Chapter ?? []
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

        // Ambient pause moment (Task 7): swap the text title for the
        // title logo once paused long enough, but only when a logo
        // actually resolved — a title with no logo keeps its text.
        viewModel.$pausePresentation
            .combineLatest(viewModel.$titleLogoImage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation, logo in
                guard let self else { return }
                let useLogo = presentation != .frame && logo != nil
                self.logoImageView.image = logo
                self.logoImageView.isHidden = !useLogo
                self.titleLabel.isHidden = useLogo
                self.secondaryLabel.isHidden = useLogo || self.viewModel?.subtitle == nil
            }
            .store(in: &cancellables)

        replayButton.onPress = { [weak self] in self?.viewModel?.replayWithCaptions() }
        replayButton.isHidden = viewModel.subtitleTracks.isEmpty
        viewModel.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.replayButton.isHidden = tracks.isEmpty }
            .store(in: &cancellables)

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
        subtitlesButton.onLongPress = { [weak self] in self?.viewModel?.replayWithCaptions() }

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
            [self.titleLabel, self.secondaryLabel, self.logoImageView, self.controlsRow, self.infoButton].forEach {
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
