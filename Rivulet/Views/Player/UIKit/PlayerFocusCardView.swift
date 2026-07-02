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
        resumeButton.setTitle(paused ? "Resume" : "Pause",
            icon: UIImage(systemName: paused ? "play.fill" : "pause.fill"))
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
        if mode != .metadata, let panel = panelContainer { return [panel] }
        if let last = lastFocusedControl, !last.isHidden { return [last] }
        return [resumeButton]
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
        if mode != .metadata, window != nil,
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

// MARK: - PlayerPrimaryButton

final class PlayerPrimaryButton: UIControl {

    var onPress: (() -> Void)?
    private let label = UILabel()
    private let iconView = UIImageView()
    private let row = UIStackView()

    override var canBecomeFocused: Bool { true }

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

// MARK: - CardTrackListView (Task 6 — ported from PlayerTrackPopupView)

/// In-card track list panel for Subtitles/Audio. Ported from
/// PlayerTrackPopupView: same row model, scroll+stack layout, and
/// system-picker row focus treatment, minus the glass background and
/// AnchoredPopupPresenting conformance/Menu handling — the card owns
/// Menu and framing now.
final class CardTrackListView: UIView {

    struct Row {
        let title: String
        let subtitle: String?
        let trackId: Int?
        let isSelected: Bool
    }

    private let rows: [Row]
    private let onSelect: (Int?) -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rowButtons: [CardTrackRowButton] = []

    init(header: String, tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool, onSelect: @escaping (Int?) -> Void) {
        var rows: [Row] = []
        if showsOffRow {
            rows.append(Row(title: "Off", subtitle: nil, trackId: nil, isSelected: selectedTrackId == nil))
        }
        rows.append(contentsOf: tracks.map { track in
            Row(
                title: track.name,
                subtitle: [track.language, track.codec?.uppercased()].compactMap { $0 }.joined(separator: " • "),
                trackId: track.id,
                isSelected: track.id == selectedTrackId
            )
        })
        self.rows = rows
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupViews(header: header)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews(header: String) {
        let headerLabel = UILabel()
        headerLabel.text = header
        headerLabel.font = .systemFont(ofSize: 26, weight: .bold)
        headerLabel.textColor = .white
        addSubview(headerLabel)

        stack.axis = .vertical
        stack.spacing = 2
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // The scroll view grows with content up to a cap, so short lists
        // hug their rows and long ones scroll.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        for row in rows {
            let button = CardTrackRowButton(row: row)
            button.onTap = { [weak self] in
                self?.onSelect(row.trackId)
            }
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let first = rowButtons.first(where: { $0.row.isSelected }) {
            return [first]
        }
        return rowButtons.isEmpty ? [self] : [rowButtons[0]]
    }
}

// MARK: - CardTrackRowButton (verbatim port of PopupRowButton)

final class CardTrackRowButton: UIControl {

    let row: CardTrackListView.Row
    var onTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    ))
    private let vStack = UIStackView()

    init(row: CardTrackListView.Row) {
        self.row = row
        super.init(frame: .zero)

        titleLabel.text = row.title
        titleLabel.font = .systemFont(ofSize: 23, weight: .medium)
        titleLabel.textColor = .white

        subtitleLabel.text = row.subtitle
        subtitleLabel.font = .systemFont(ofSize: 17, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.isHidden = row.subtitle == nil || row.subtitle?.isEmpty == true

        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.isUserInteractionEnabled = false
        vStack.addArrangedSubview(titleLabel)
        vStack.addArrangedSubview(subtitleLabel)

        // Leading checkmark column, reserved for every row so titles
        // align whether or not a row is selected (system-picker layout).
        checkmarkView.tintColor = .white
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .center

        addSubview(checkmarkView)
        addSubview(vStack)

        [vStack, checkmarkView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            checkmarkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 26),

            vStack.leadingAnchor.constraint(equalTo: checkmarkView.trailingAnchor, constant: 14),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl
    // on tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            // System-picker focus treatment: white fill, black content.
            self.backgroundColor = isFocused ? .white : .clear
            self.titleLabel.textColor = isFocused ? .black : .white
            self.subtitleLabel.textColor = isFocused
                ? UIColor.black.withAlphaComponent(0.6)
                : UIColor.white.withAlphaComponent(0.6)
            self.checkmarkView.tintColor = isFocused ? .black : .white
        }, completion: nil)
    }
}

// MARK: - CardInfoView (Task 6 — ported from PlayerInfoPopupView)

/// In-card info/tech sheet panel. Ported from PlayerInfoPopupView: same
/// scroll+stack layout, populate() section builders, formatters, and the
/// 1Hz live-tick lifecycle tied to window attach/detach — minus the glass
/// background and AnchoredPopupPresenting conformance/Menu handling (the
/// card owns Menu and framing now).
final class CardInfoView: UIView {

    private let metadata: PlexMetadata
    /// Supplies a fresh engine snapshot on demand. nil on the `hls` route
    /// (no AetherPlayer) — in that case the PLAYBACK section is omitted
    /// entirely rather than showing stale or synthesized numbers.
    private let liveStatsProvider: (() -> AetherLiveStats?)?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// Live PLAYBACK rows, updated in place every tick. nil when the
    /// PLAYBACK section was omitted at populate() time.
    private var bufferRow: UILabel?
    private var backendRow: UILabel?
    private var audioBridgeRow: UILabel?
    private var liveTickTimer: Timer?

    init(metadata: PlexMetadata, liveStatsProvider: (() -> AetherLiveStats?)? = nil) {
        self.metadata = metadata
        self.liveStatsProvider = liveStatsProvider
        super.init(frame: .zero)
        setupViews()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Live tick lifecycle
    //
    // The panel is added/removed via PlayerFocusCardView.swapContent, which
    // always ends in removeFromSuperview() for the outgoing panel — so
    // didMoveToWindow with window == nil is a reliable "panel is gone"
    // signal for tearing the timer down. Starting in didMoveToWindow
    // (rather than init) avoids ticking a timer for a view that's
    // constructed but never actually shown.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startLiveTick()
        } else {
            stopLiveTick()
        }
    }

    private func startLiveTick() {
        guard liveStatsProvider != nil, liveTickTimer == nil else { return }
        liveTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLiveRows()
            }
        }
    }

    private func stopLiveTick() {
        liveTickTimer?.invalidate()
        liveTickTimer = nil
    }

    private func refreshLiveRows() {
        guard let stats = liveStatsProvider?() else { return }
        if let bufferRow, let seconds = stats.bufferedSeconds {
            bufferRow.text = "Buffer: \(Self.formatBufferSeconds(seconds))"
        }
        if let backendRow, let backend = stats.backend {
            backendRow.text = "Backend: \(backend)"
        }
        if let audioBridgeRow, let audioBridge = stats.audioBridge {
            audioBridgeRow.text = "Audio Bridge: \(audioBridge)"
        }
    }

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    // MARK: - Content

    private var primaryVideoStream: PlexStream? {
        metadata.Media?.first?.Part?.first?.Stream?.first { $0.isVideo }
    }

    private var audioStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isAudio } ?? []
    }

    private var subtitleStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isSubtitle } ?? []
    }

    private func populate() {
        stack.addArrangedSubview(headerLabel("Media Info"))
        if let title = metadata.title {
            stack.addArrangedSubview(bodyLabel(title, secondary: true))
        }

        populatePlaybackSection()

        stack.addArrangedSubview(sectionLabel("VIDEO"))
        if let videoStream = primaryVideoStream {
            if let displayTitle = videoStream.displayTitle ?? videoStream.extendedDisplayTitle {
                stack.addArrangedSubview(infoRow("Format", displayTitle))
            }
            if videoStream.isDolbyVision {
                var dvInfo = "Profile \(videoStream.DOVIProfile ?? 0)"
                if let compatID = videoStream.DOVIBLCompatID {
                    dvInfo += " (CompatID \(compatID))"
                }
                stack.addArrangedSubview(infoRow("Dolby Vision", dvInfo))
            } else if videoStream.isHDR {
                stack.addArrangedSubview(infoRow("HDR", "HDR10"))
            }
            if let bitDepth = videoStream.bitDepth {
                stack.addArrangedSubview(infoRow("Bit Depth", "\(bitDepth)-bit"))
            }
            if let colorSpace = videoStream.colorSpace {
                stack.addArrangedSubview(infoRow("Color Space", colorSpace))
            }
        } else if let media = metadata.Media?.first {
            if let codec = media.videoCodec {
                stack.addArrangedSubview(infoRow("Codec", codec.uppercased()))
            }
            if let res = media.videoResolution {
                stack.addArrangedSubview(infoRow("Resolution", res))
            }
        }
        if let media = metadata.Media?.first {
            if let width = media.width, let height = media.height {
                stack.addArrangedSubview(infoRow("Dimensions", "\(width) × \(height)"))
            }
            if let frameRate = media.videoFrameRate {
                stack.addArrangedSubview(infoRow("Frame Rate", frameRate))
            }
            if let bitrate = media.bitrate {
                stack.addArrangedSubview(infoRow("Bitrate", Self.formatBitrate(bitrate)))
            }
        }

        if !audioStreams.isEmpty {
            stack.addArrangedSubview(sectionLabel("AUDIO"))
            for (index, stream) in audioStreams.enumerated() {
                let title = stream.displayTitle ?? stream.extendedDisplayTitle ?? "Track \(index + 1)"
                var detail = title
                if let bitrate = stream.bitrate {
                    detail += " · \(Self.formatBitrate(bitrate))"
                }
                if let sampleRate = stream.samplingRate {
                    detail += " · \(sampleRate / 1000) kHz"
                }
                stack.addArrangedSubview(bodyLabel(detail, secondary: false))
            }
        }

        if !subtitleStreams.isEmpty {
            stack.addArrangedSubview(sectionLabel("SUBTITLES"))
            for stream in subtitleStreams {
                var title = stream.extendedDisplayTitle ?? stream.displayTitle ?? "Unknown"
                var badges: [String] = []
                if stream.forced == true { badges.append("Forced") }
                if stream.hearingImpaired == true { badges.append("SDH") }
                if stream.default == true { badges.append("Default") }
                if !badges.isEmpty {
                    title += " (\(badges.joined(separator: ", ")))"
                }
                stack.addArrangedSubview(bodyLabel(title, secondary: false))
            }
        }

        if let part = metadata.Media?.first?.Part?.first {
            stack.addArrangedSubview(sectionLabel("FILE"))
            if let file = part.file {
                let filename = (file as NSString).lastPathComponent
                stack.addArrangedSubview(infoRow("Name", filename))
            }
            if let container = part.container ?? metadata.Media?.first?.container {
                stack.addArrangedSubview(infoRow("Container", container.uppercased()))
            }
            if let size = part.size {
                stack.addArrangedSubview(infoRow("Size", Self.formatFileSize(Int64(size))))
            }
            if let duration = metadata.duration ?? part.duration {
                stack.addArrangedSubview(infoRow("Duration", Self.formatDuration(duration)))
            }
        }
    }

    /// Live engine stats section, inserted first (ahead of the static Plex
    /// metadata sections). Omitted entirely when there's no provider (the
    /// `hls` route has no AetherPlayer) or the first snapshot is all-nil —
    /// never rendered as an empty/placeholder header.
    private func populatePlaybackSection() {
        guard let stats = liveStatsProvider?(), !stats.isEmpty else { return }

        stack.addArrangedSubview(sectionLabel("PLAYBACK"))

        if let seconds = stats.bufferedSeconds {
            let row = bodyLabel("Buffer: \(Self.formatBufferSeconds(seconds))", secondary: false)
            stack.addArrangedSubview(row)
            bufferRow = row
        }
        if let backend = stats.backend {
            let row = bodyLabel("Backend: \(backend)", secondary: false)
            stack.addArrangedSubview(row)
            backendRow = row
        }
        if let audioBridge = stats.audioBridge {
            let row = bodyLabel("Audio Bridge: \(audioBridge)", secondary: false)
            stack.addArrangedSubview(row)
            audioBridgeRow = row
        }
    }

    // MARK: - Row builders

    private func headerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.textColor = .white
        return label
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        return label
    }

    private func bodyLabel(_ text: String, secondary: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 18, weight: .regular)
        label.textColor = secondary ? UIColor.white.withAlphaComponent(0.6) : .white
        label.numberOfLines = 0
        return label
    }

    private func infoRow(_ label: String, _ value: String) -> UILabel {
        let row = UILabel()
        row.numberOfLines = 0
        let text = NSMutableAttributedString(
            string: "\(label): ",
            attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
        )
        text.append(NSAttributedString(
            string: value,
            attributes: [.font: UIFont.systemFont(ofSize: 18, weight: .regular), .foregroundColor: UIColor.white]
        ))
        row.attributedText = text
        return row
    }

    // MARK: - Formatting

    /// Whole seconds, clamped to never print negative (AetherPlayer.liveStats
    /// already clamps at the source, but the display layer stays defensive).
    private static func formatBufferSeconds(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return "\(whole)s"
    }

    private static func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
        } else if bitrate >= 1000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1000.0)
        } else {
            return "\(bitrate) bps"
        }
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    // Info has no selectable rows, but the panel still needs to be a real
    // focus target -- otherwise focus never lands inside it and up/down
    // presses never scroll it. Scrolling is driven by up/down presses via
    // the inherited UIScrollView focus-scroll behavior.
    override var canBecomeFocused: Bool { true }
}

// MARK: - IrisSpinnerView (Task 7)

/// 64pt conic accent-gradient ring, masked to an 8pt stroke, spinning
/// 1.4s/rev. Animation is re-added on window attach (CAAnimations die
/// on removal).
final class IrisSpinnerView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let g = layer as! CAGradientLayer
        g.type = .conic
        g.colors = [
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
            UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 0).cgColor,
        ]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 0.5, y: 0)

        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 8
        ring.lineCap = .round
        layer.mask = ring
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: 64, height: 64) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
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
        let bar = UIView()
        bar.backgroundColor = UIColor.white.withAlphaComponent(alpha)
        bar.layer.cornerRadius = 6
        bar.layer.cornerCurve = .continuous
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 22).isActive = true
        // Widths are relative to the panel itself (self), not the arranged
        // stack, since a UIStackView's arranged subviews don't have a fixed
        // width to anchor against directly.
        bar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: widthMultiplier).isActive = true
        return bar
    }

    // Not focusable: while loading, controlsFocusActive is false so the
    // container never routes focus here.
    override var canBecomeFocused: Bool { false }
}
