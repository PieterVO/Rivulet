// Player focus card view — persistent bottom-left glass card metadata mode 2a chrome.
// Metadata mode: series line, large title, meta row, flexible spacer, controls row (Resume pill + round buttons) pinned to
// bottom. Later tasks add: in-card panels (Task 6) and loading (Task 7).

import UIKit

final class PlayerFocusCardView: UIView {

    static let cardWidth: CGFloat = 720
    static let cardHeight: CGFloat = 520

    private enum Metrics {
        static let cornerRadius: CGFloat = 34
        static let paddingV: CGFloat = 46
        static let paddingH: CGFloat = 48
        static let roundButtonDiameter: CGFloat = 72
    }

    // MARK: - Callbacks (wired by PlayerContainerViewController)

    var onPlayPause: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onSubtitles: (() -> Void)?
    var onAudio: (() -> Void)?
    var onInfo: (() -> Void)?
    var onReplayLongPress: (() -> Void)?
    /// Down pressed while card control focused focus cannot move
    /// (nothing focusable below card) — container enters seek mode.
    var onNavigateDown: (() -> Void)?

    // MARK: - Chrome

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()

    // MARK: - Metadata mode content

    private let pausedLabel = UILabel()
    private let seriesLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    let resumeButton = PlayerPrimaryButton()
    let skipBackButton = TransportControlButton(
        icon: UIImage(systemName: "gobackward.15"), accessibilityLabel: "Skip back 15 seconds",
        diameter: Metrics.roundButtonDiameter)
    let subtitlesButton = TransportControlButton(
        icon: UIImage(systemName: "captions.bubble"), accessibilityLabel: "Subtitles",
        diameter: Metrics.roundButtonDiameter)
    let audioButton = TransportControlButton(
        icon: UIImage(systemName: "waveform"), accessibilityLabel: "Audio",
        diameter: Metrics.roundButtonDiameter)
    let infoButton = TransportControlButton(
        icon: UIImage(systemName: "info.circle"), accessibilityLabel: "Info",
        diameter: Metrics.roundButtonDiameter)

    private let metadataContainer = UIView()
    private let controlsRow = UIStackView()

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupChrome()
        setupMetadataContent()
        setupControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not been implemented") }

    func setupChrome() {
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        clipsToBounds = true

        tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.42)

        [backgroundEffectView, tintView, metadataContainer].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            heightAnchor.constraint(equalToConstant: Self.cardHeight),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            metadataContainer.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.paddingV),
            metadataContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.paddingH),
            metadataContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.paddingH),
            metadataContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.paddingV),
        ])
    }

    func setupMetadataContent() {
        pausedLabel.text = "⏸ Paused"
        pausedLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        pausedLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        pausedLabel.isHidden = true

        seriesLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        seriesLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        metaLabel.font = .systemFont(ofSize: 19, weight: .regular)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        let metadataStack = UIStackView(arrangedSubviews: [pausedLabel, seriesLabel, titleLabel, metaLabel])
        metadataStack.axis = .vertical
        metadataStack.spacing = 12
        metadataStack.distribution = .fill
        metadataStack.alignment = .leading
        metadataStack.translatesAutoresizingMaskIntoConstraints = false

        metadataContainer.addSubview(metadataStack)
        metadataContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            metadataStack.topAnchor.constraint(equalTo: metadataContainer.topAnchor),
            metadataStack.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            metadataStack.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor),
        ])
    }

    func setupControls() {
        controlsRow.axis = .horizontal
        controlsRow.spacing = 24
        controlsRow.alignment = .center
        controlsRow.distribution = .fill
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        resumeButton.translatesAutoresizingMaskIntoConstraints = false

        controlsRow.addArrangedSubview(resumeButton)
        controlsRow.addArrangedSubview(skipBackButton)
        controlsRow.addArrangedSubview(subtitlesButton)
        controlsRow.addArrangedSubview(audioButton)
        controlsRow.addArrangedSubview(infoButton)

        metadataContainer.addSubview(controlsRow)

        NSLayoutConstraint.activate([
            controlsRow.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            controlsRow.trailingAnchor.constraint(lessThanOrEqualTo: metadataContainer.trailingAnchor),
            controlsRow.bottomAnchor.constraint(equalTo: metadataContainer.bottomAnchor),
        ])

        resumeButton.onPress = { [weak self] in self?.onPlayPause?() }
        skipBackButton.onPress = { [weak self] in self?.onSkipBack?() }
        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        skipBackButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
    }

    // MARK: - Content API

    func setTitle(_ title: String, seriesLine: String?, metaLine: String?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.05
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white,
            .kern: 48 * -0.015,
            .paragraphStyle: paragraph,
        ])
        seriesLabel.text = seriesLine
        seriesLabel.isHidden = seriesLine == nil
        metaLabel.text = metaLine
        metaLabel.isHidden = metaLine == nil
    }

    func setPaused(_ paused: Bool) {
        pausedLabel.isHidden = !paused
        resumeButton.setTitle(paused ? "Resume" : "Pause",
            icon: UIImage(systemName: paused ? "play.fill" : "pause.fill"))
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        subtitlesButton.isHidden = !enabled
    }

    // MARK: - Focus

    /// Landing point container routes controls-focus here; last
    /// focused control wins after first landing (popup-return parity).
    private weak var lastFocusedControl: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let last = lastFocusedControl, !last.isHidden {
            return [last]
        }
        return [resumeButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedControl = next
        }
    }

    /// Nothing focusable sits below card, so Down press with card
    /// control focused delivered here (focus can't move). Right/left/up
    /// left focus engine (right walks controls row, then wraps; up bounces
    /// to metadata); Down with focused button engages seek mode.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            // Dismiss card focus (let container handle menu routing)
            // TODO(task-3): wired by PlayerContainerViewController dismissal routing
            return
        }
        // Right/left/up handled by focus engine; Down with control focused
        // (nothing below) routes to seek mode container handler.
        for press in presses where press.type == .downArrow {
            onNavigateDown?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

}

// MARK: - PlayerPrimaryButton

final class PlayerPrimaryButton: UIControl {

    var onPress: (() -> Void)?
    private let label = UILabel()
    private let iconView = UIImageView()
    private let row = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = .white
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor(red: 180/255, green: 205/255, blue: 1.0, alpha: 1).cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 20
        layer.shadowOffset = .zero

        label.font = .systemFont(ofSize: 25, weight: .bold)
        label.textColor = UIColor(red: 6/255, green: 7/255, blue: 11/255, alpha: 1)
        iconView.tintColor = UIColor(red: 6/255, green: 7/255, blue: 11/255, alpha: 1)
        iconView.contentMode = .center

        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)

        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 72),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 34),
        ])
        setTitle("Resume", icon: UIImage(systemName: "play.fill"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not been implemented") }

    func setTitle(_ title: String, icon: UIImage?) {
        label.text = title
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        iconView.image = icon?.applyingSymbolConfiguration(config)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard press.type == .select else { continue }
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

}
