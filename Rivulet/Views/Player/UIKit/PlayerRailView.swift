//
//  PlayerRailView.swift
//  Rivulet
//
//  The 3a bottom glass rail: metadata block left, five round transport
//  buttons right. The scrubber (PlayerProgressBarView) is NOT a child —
//  it stays a container sibling overlaid on the rail's lower region so
//  its morph/behavior layer is untouched; this view is the glass plate
//  and the top row only.
//

import UIKit

final class PlayerRailView: UIView {

    static let railHeight: CGFloat = 260

    private enum Metrics {
        static let padV: CGFloat = 34
        static let padH: CGFloat = 42
        static let topRowGap: CGFloat = 32
        static let buttonGap: CGFloat = 20
        static let buttonDiameter: CGFloat = 74
    }

    // No skip-back control — the remote's own scrub gesture owns seeking
    // (same philosophy as the earlier Resume-pill removal).
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.buttonDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.buttonDiameter)
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info.circle"), accessibilityLabel: "Info",
        diameter: Metrics.buttonDiameter)
    let insightsButton = TransportControlButton(
        icon: UIImage(systemName: "sparkles"), accessibilityLabel: "Insights",
        diameter: Metrics.buttonDiameter)
    let upNextButton = TransportControlButton(
        icon: UIImage(systemName: "list.and.film"), accessibilityLabel: "Up Next",
        diameter: Metrics.buttonDiameter)

    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onInsights: (() -> Void)?
    var onUpNext: (() -> Void)?
    var onReplayLongPress: (() -> Void)?

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaRow = UIStackView()
    private let ratingChip = UILabel()
    private let runtimeLabel = UILabel()
    private let dividerLabel = UILabel()
    private let audioLabel = UILabel()
    private let cluster = UIStackView()

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        // Shadow lives on the unclipped self layer; glass clips itself.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 35
        layer.shadowOffset = CGSize(width: 0, height: 15)

        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.layer.cornerRadius = 32
        backgroundEffectView.layer.cornerCurve = .continuous
        tintView.backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 26/255, alpha: 0.5)
        tintView.clipsToBounds = true
        tintView.layer.cornerRadius = 32
        tintView.layer.cornerCurve = .continuous

        eyebrowLabel.font = .systemFont(ofSize: 23, weight: .medium)
        eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.66)

        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        ratingChip.font = .systemFont(ofSize: 17, weight: .medium)
        ratingChip.textColor = UIColor.white.withAlphaComponent(0.55)
        ratingChip.layer.borderWidth = 1
        ratingChip.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        ratingChip.layer.cornerRadius = 6
        ratingChip.layer.cornerCurve = .continuous
        ratingChip.textAlignment = .center

        for label in [runtimeLabel, dividerLabel, audioLabel] {
            label.font = .systemFont(ofSize: 20, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
        }
        dividerLabel.text = "·"
        dividerLabel.textColor = UIColor.white.withAlphaComponent(0.4)

        metaRow.axis = .horizontal
        metaRow.spacing = 14
        metaRow.alignment = .center
        [ratingChip, runtimeLabel, dividerLabel, audioLabel].forEach { metaRow.addArrangedSubview($0) }

        cluster.axis = .horizontal
        cluster.spacing = Metrics.buttonGap
        cluster.alignment = .center
        [subtitlesButton, audioButton, infoButton, insightsButton, upNextButton].forEach {
            cluster.addArrangedSubview($0)
        }

        [backgroundEffectView, tintView, eyebrowLabel, titleLabel, metaRow, cluster].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padV),
            eyebrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padH),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cluster.leadingAnchor, constant: -Metrics.topRowGap),

            metaRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            metaRow.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),

            ratingChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            ratingChip.heightAnchor.constraint(equalToConstant: 28),

            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padH),
            cluster.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])

        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        insightsButton.onPress = { [weak self] in self?.onInsights?() }
        upNextButton.onPress = { [weak self] in self?.onUpNext?() }
        insightsButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func setTitle(_ title: String, eyebrow: String?) {
        titleLabel.text = title
        eyebrowLabel.text = eyebrow
        eyebrowLabel.isHidden = eyebrow == nil
    }

    func setMeta(rating: String?, runtime: String?, audio: String?) {
        ratingChip.text = rating
        ratingChip.isHidden = rating == nil
        runtimeLabel.text = runtime
        runtimeLabel.isHidden = runtime == nil
        audioLabel.text = audio
        audioLabel.isHidden = audio == nil
        dividerLabel.isHidden = runtime == nil || audio == nil
    }

    func setLoading(_ loading: Bool) {
        cluster.isHidden = loading
    }

    func setUpNextAvailable(_ available: Bool) {
        upNextButton.isHidden = !available
    }

    func setInsightsAvailable(_ available: Bool) {
        insightsButton.isHidden = !available
    }

    // MARK: - Ambient pause

    /// During ambient pause the glass plate, eyebrow, meta, and buttons fade
    /// out, but for a show the episode `titleLabel` stays exactly where the
    /// rail draws it (same place, same 38pt bold) — it does not fade with the
    /// rest. `keepTitle` is false for movies (logo only, nothing kept here).
    /// The container holds the rail's own alpha at 1 while ambient so this
    /// held title can show through.
    ///
    /// `ambientState` lets the container detect a real change (the sub-view
    /// alpha shifts here aren't visible to its own top-level `targets` diff).
    private(set) var ambientState: (ambient: Bool, keepTitle: Bool) = (false, false)

    func setAmbient(_ ambient: Bool, keepTitle: Bool) {
        ambientState = (ambient, keepTitle)
        let plateAlpha: CGFloat = ambient ? 0 : 1
        backgroundEffectView.alpha = plateAlpha
        tintView.alpha = plateAlpha
        eyebrowLabel.alpha = plateAlpha
        metaRow.alpha = plateAlpha
        cluster.alpha = plateAlpha
        // Shadow belongs to the plate; drop it so no glass ghost lingers.
        layer.shadowOpacity = ambient ? 0 : 0.6
        titleLabel.alpha = ambient ? (keepTitle ? 1 : 0) : 1
    }

    // MARK: - Focus

    private weak var lastFocusedButton: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedButton, !last.isHidden { return [last] }
        return [subtitlesButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedButton = next
        }
    }
}
