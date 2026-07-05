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

        seriesLabel.font = .systemFont(ofSize: 23, weight: .medium)
        seriesLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        metaLabel.font = .systemFont(ofSize: 21, weight: .medium)
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

        // No play/pause control: that's the remote's job (system-player
        // parity), and a permanently-white pill read as focused-when-not —
        // white fill is the focus signifier on tvOS. Removed 2026-07-03.
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

        skipBackButton.onPress = { [weak self] in self?.onSkipBack?() }
        subtitlesButton.onPress = { [weak self] in self?.onSubtitles?() }
        audioButton.onPress = { [weak self] in self?.onAudio?() }
        infoButton.onPress = { [weak self] in self?.onInfo?() }
        subtitlesButton.onLongPress = { [weak self] in self?.onReplayLongPress?() }
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
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        subtitlesButton.isHidden = !enabled
    }

    // MARK: - In-card modes (Task 6)

    enum Mode { case metadata, subtitleTracks, audioTracks, info, loading }
    private(set) var mode: Mode = .metadata
    private var panelContainer: UIView?

    private func swapContent(to mode: Mode, panel: UIView?) {
        self.mode = mode
        let showMetadata = (mode == .metadata)
        UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) {
            self.metadataContainer.isHidden = !showMetadata
            self.panelContainer?.removeFromSuperview()
            self.panelContainer = panel
            if let panel {
                self.addSubview(panel)
                panel.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    panel.topAnchor.constraint(equalTo: self.topAnchor, constant: Metrics.paddingV),
                    panel.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Metrics.paddingH),
                    panel.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Metrics.paddingH),
                    panel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -Metrics.paddingV),
                ])
            }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    func returnToMetadata() {
        guard mode != .metadata else { return }
        swapContent(to: .metadata, panel: nil)
    }

    /// Swaps in a `CardTrackListView` for Subtitles/Audio. Selecting a row
    /// (or "Off") applies the selection then returns the card to metadata.
    func showTracks(header: String, tracks: [MediaTrack], selectedTrackId: Int?,
                     showsOffRow: Bool, onSelect: @escaping (Int?) -> Void) {
        let list = CardTrackListView(header: header, tracks: tracks,
                                     selectedTrackId: selectedTrackId, showsOffRow: showsOffRow,
                                     onSelect: { [weak self] id in
                                         onSelect(id)
                                         self?.returnToMetadata()
                                     })
        swapContent(to: header == "Audio" ? .audioTracks : .subtitleTracks, panel: list)
    }

    /// Swaps in a `CardInfoView` info/tech sheet.
    func showInfo(metadata: PlexMetadata, liveStatsProvider: (() -> AetherLiveStats?)?) {
        swapContent(to: .info, panel: CardInfoView(metadata: metadata, liveStatsProvider: liveStatsProvider))
    }

    /// Swaps in a `CardLoadingView` (spinner + skeleton) while playback
    /// starts, or returns to metadata once loading clears. Not focusable —
    /// `controlsFocusActive` is false while loading so the container never
    /// routes focus into the card.
    func setLoading(_ loading: Bool, seriesLine: String?, title: String) {
        if loading {
            tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.40)
            swapContent(to: .loading, panel: CardLoadingView(seriesLine: seriesLine, title: title))
        } else if mode == .loading {
            tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.42)
            returnToMetadata()
        }
    }

    // MARK: - Focus

    /// Landing point container routes controls-focus here; last
    /// focused control wins after first landing (popup-return parity).
    private weak var lastFocusedControl: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if mode != .metadata, mode != .loading, let panel = panelContainer { return [panel] }
        if let last = lastFocusedControl, !last.isHidden { return [last] }
        return [skipBackButton]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self), next is UIControl {
            lastFocusedControl = next
        }
    }

    /// Real focus trap while a panel is up: preferredFocusEnvironments only
    /// steers the initial landing; directional presses can still walk focus
    /// out to the controls row behind the panel. Fence them while presented
    /// (same trap the popups fixed).
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if mode != .metadata, mode != .loading, window != nil,
           let next = context.nextFocusedView, !next.isDescendant(of: self) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    /// Nothing focusable sits below card, so Down press with card
    /// control focused delivered here (focus can't move). Right/left/up
    /// left focus engine (right walks controls row, then wraps; up bounces
    /// to metadata); Down with focused button engages seek mode. Menu
    /// while a panel is up returns to metadata (card owns Menu itself).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu, mode != .metadata {
                returnToMetadata()
                return
            }
            if press.type == .downArrow, mode == .metadata {
                onNavigateDown?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // Swallow the ended phase of a consumed Menu press (same trap the
    // popups fixed: letting it bubble peels a second unwind layer via the
    // system dismiss).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            return
        }
        super.pressesEnded(presses, with: event)
    }

}

// MARK: - CardLoadingView (Task 7)

/// In-card loading panel: spinner + "Loading · <series>" row, title, and
/// two skeleton bars standing in for the meta row / controls row while
/// playback starts (or an episode advance swaps content). Not focusable —
/// see `PlayerFocusCardView.setLoading`.
final class CardLoadingView: UIView {

    init(seriesLine: String?, title: String) {
        super.init(frame: .zero)

        let spinner = IrisSpinnerView()

        let loadingLabel = UILabel()
        let seriesText = seriesLine.map { " · \($0)" } ?? ""
        loadingLabel.text = "Loading\(seriesText)"
        loadingLabel.font = .systemFont(ofSize: 23, weight: .medium)
        loadingLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        loadingLabel.numberOfLines = 1

        let spinnerRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
        spinnerRow.axis = .horizontal
        spinnerRow.spacing = 20
        spinnerRow.alignment = .center

        let titleLabel = UILabel()
        titleLabel.numberOfLines = 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.05
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white,
            .kern: 48 * -0.015,
            .paragraphStyle: paragraph,
        ])

        let barTall = skeletonBar(widthMultiplier: 0.6, alpha: 0.08)
        let barShort = skeletonBar(widthMultiplier: 0.4, alpha: 0.06)

        let stack = UIStackView(arrangedSubviews: [spinnerRow, titleLabel, barTall, barShort])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.setCustomSpacing(28, after: spinnerRow)

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func skeletonBar(widthMultiplier: CGFloat, alpha: CGFloat) -> UIView {
        // The bar lives inside a plain container: the stack's .fill
        // alignment stretches the container to full width while the bar
        // keeps its fractional width, leading-pinned. Constraining the bar
        // against `self` here crashed — cross-view constraints need a
        // common ancestor at activation, and the bar only joins the card's
        // hierarchy after init adds the stack. Container + bar are already
        // one subtree, so these activate safely.
        let container = UIView()
        let bar = UIView()
        bar.backgroundColor = UIColor.white.withAlphaComponent(alpha)
        bar.layer.cornerRadius = 6
        bar.layer.cornerCurve = .continuous
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 22),
            bar.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: widthMultiplier),
        ])
        return container
    }

    // Not focusable: while loading, controlsFocusActive is false so the
    // container never routes focus here.
    override var canBecomeFocused: Bool { false }
}
