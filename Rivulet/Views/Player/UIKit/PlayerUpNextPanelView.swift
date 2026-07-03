//
//  PlayerUpNextPanelView.swift
//  Rivulet
//
//  Right-side Up Next panel for the 2a chrome. Unfocused: a single
//  collapsed row (the up-next episode) vertically centered at the right
//  edge. Focused: expands to the season list ("UP NEXT · SEASON n"),
//  auto-scrolled to the playing episode. Collapse/expand is driven purely
//  by focus membership (didUpdateFocus); Menu is NOT handled here — the
//  container's exitControlsFocus step pulls focus back to the card and
//  the panel collapses on focus loss.
//

import UIKit

final class PlayerUpNextPanelView: UIView {

    private enum Metrics {
        static let width: CGFloat = 470
        static let maxHeight: CGFloat = 520
        static let cornerRadius: CGFloat = 26
        static let padding: CGFloat = 24
    }

    var onSelectEpisode: ((PlexMetadata) -> Void)?
    var isEmpty: Bool { rows.isEmpty }

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [UpNextRowButton] = []
    private var expanded = false
    private var currentRatingKey: String?

    /// The header isn't in the stack, so hiding it doesn't collapse its
    /// layout space — the scroll view's top constraint is swapped instead.
    private var expandedTopConstraint: NSLayoutConstraint?
    private var collapsedTopConstraint: NSLayoutConstraint?

    private static let restBorderColor = UIColor.white.withAlphaComponent(0.1).cgColor
    private static let focusedBorderColor = UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 0.55).cgColor
    private static let focusedGlowColor = UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 0.22).cgColor

    init() {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupChrome()
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupChrome() {
        // The panel itself stays unclipped so the focus glow (an outer
        // shadow) can render; the glass layers are rounded and clipped
        // individually (same split as PlayerTrackPopupView).
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorderColor
        layer.shadowColor = Self.focusedGlowColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 24
        layer.shadowOffset = .zero

        backgroundEffectView.layer.cornerRadius = Metrics.cornerRadius
        backgroundEffectView.layer.cornerCurve = .continuous
        backgroundEffectView.clipsToBounds = true

        tintView.backgroundColor = UIColor(red: 14/255, green: 17/255, blue: 23/255, alpha: 0.55)
        tintView.layer.cornerRadius = Metrics.cornerRadius
        tintView.layer.cornerCurve = .continuous
        tintView.clipsToBounds = true

        [backgroundEffectView, tintView].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The panel's own layer has no contents, so the glow shadow needs
        // an explicit path.
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: Metrics.cornerRadius
        ).cgPath
    }

    private func setupContent() {
        headerLabel.font = .systemFont(ofSize: 15, weight: .bold)
        headerLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        headerLabel.isHidden = true

        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(headerLabel)
        addSubview(scrollView)

        // The scroll view grows with content up to a cap, so a short
        // season hugs its rows and a long one scrolls.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        let expandedTop = scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16)
        let collapsedTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding)
        expandedTopConstraint = expandedTop
        collapsedTopConstraint = collapsedTop
        collapsedTop.isActive = true

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.padding),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight - Metrics.padding * 2),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    // MARK: - Content API

    /// Rebuilds rows from scratch. Called whenever the VM's up-next list
    /// changes (episode advance, season boundary, playback of a different
    /// item). Old rows' in-flight thumbnail tasks are cancelled before
    /// they're torn down.
    func setEpisodes(_ episodes: [PlexMetadata], currentRatingKey: String?, seasonNumber: Int?,
                      serverURL: String, authToken: String) {
        self.currentRatingKey = currentRatingKey
        rows.forEach {
            $0.cancelImageLoad()
            $0.removeFromSuperview()
        }
        rows.removeAll()

        let headerText = seasonNumber.map { "UP NEXT · SEASON \($0)" } ?? "UP NEXT"
        headerLabel.attributedText = NSAttributedString(
            string: headerText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .kern: 1.5,
            ]
        )

        for episode in episodes {
            let state = UpNextRowState.state(for: episode, in: episodes, currentRatingKey: currentRatingKey)
            let row = UpNextRowButton(episode: episode, state: state, serverURL: serverURL, authToken: authToken)
            row.onTap = { [weak self] in self?.onSelectEpisode?(episode) }
            stack.addArrangedSubview(row)
            rows.append(row)
        }

        applyExpansion()
    }

    // MARK: - Collapse / Expand

    /// Collapsed: only the up-next row is visible (fallback now-playing,
    /// then the first row); header hidden. Expanded: every row visible.
    private func applyExpansion() {
        headerLabel.isHidden = !expanded
        // Swap the scroll view's top edge: below the header when expanded,
        // straight to the panel padding when collapsed (deactivate first
        // so both are never active at once).
        if expanded {
            collapsedTopConstraint?.isActive = false
            expandedTopConstraint?.isActive = true
        } else {
            expandedTopConstraint?.isActive = false
            collapsedTopConstraint?.isActive = true
        }

        if expanded {
            rows.forEach { $0.isHidden = false }
        } else {
            let visible = rows.first(where: { $0.rowState == .upNext })
                ?? rows.first(where: { $0.rowState == .nowPlaying })
                ?? rows.first
            rows.forEach { $0.isHidden = ($0 !== visible) }
        }

        // `expanded` is only ever true while focus is contained here (see
        // didUpdateFocus below), so it doubles as the "expanded AND
        // containing focus" condition from the design spec.
        layer.borderColor = expanded ? Self.focusedBorderColor : Self.restBorderColor
        layer.shadowOpacity = expanded ? 1 : 0
    }

    private func scrollToCurrentRow() {
        guard let target = rows.first(where: { $0.rowState == .nowPlaying }) else { return }
        layoutIfNeeded()
        let targetFrame = target.convert(target.bounds, to: scrollView)
        scrollView.scrollRectToVisible(targetFrame.insetBy(dx: 0, dy: -(scrollView.bounds.height / 2 - targetFrame.height / 2)), animated: false)
    }

    // MARK: - Focus

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let containsFocus = context.nextFocusedView?.isDescendant(of: self) == true
        guard containsFocus != expanded else { return }
        expanded = containsFocus
        coordinator.addCoordinatedAnimations({
            self.applyExpansion()
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] in
            guard let self, self.expanded else { return }
            self.scrollToCurrentRow()
        })
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Land on the up-next row first (the collapsed row), then free movement.
        if let target = rows.first(where: { $0.rowState == .upNext }) ?? rows.first { return [target] }
        return [self]
    }
}

// MARK: - UpNextRowButton

final class UpNextRowButton: UIControl {

    let rowState: UpNextRowState
    var onTap: (() -> Void)?

    private let thumbView = UIImageView()
    private let accentBar = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?

    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let restBackgroundClear = UIColor.clear
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let restBorder = UIColor.clear.cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor
    private static let accentColor = UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 1)

    init(episode: PlexMetadata, state: UpNextRowState, serverURL: String, authToken: String) {
        self.rowState = state
        super.init(frame: .zero)
        setupViews(episode: episode)
        loadThumbnail(episode: episode, serverURL: serverURL, authToken: authToken)
        applyRestAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews(episode: PlexMetadata) {
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorder

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 8
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        accentBar.backgroundColor = Self.accentColor
        accentBar.isHidden = rowState != .nowPlaying

        let index = episode.index ?? 0
        let title = episode.title ?? ""
        titleLabel.text = "E\(index) · \(title)"
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        subtitleLabel.text = Self.subtitleText(for: rowState, episode: episode)
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        [accentBar, thumbView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 92),

            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 120),
            thumbView.heightAnchor.constraint(equalToConstant: 68),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func subtitleText(for state: UpNextRowState, episode: PlexMetadata) -> String {
        let mins = (episode.duration ?? 0) / 60000
        switch state {
        case .watched: return "Watched"
        case .nowPlaying: return "Now playing"
        case .upNext: return "Up next · \(mins) min"
        case .future: return "\(mins) min"
        }
    }

    private func loadThumbnail(episode: PlexMetadata, serverURL: String, authToken: String) {
        guard let thumbPath = episode.thumb else { return }
        guard let url = PlexNetworkManager.shared.buildThumbnailURL(
            serverURL: serverURL, authToken: authToken, thumbPath: thumbPath, width: 300, height: 169
        ) else { return }

        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            self.thumbView.image = image
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    private func applyRestAppearance() {
        backgroundColor = rowState == .upNext ? Self.restBackground : Self.restBackgroundClear
        layer.borderColor = Self.restBorder
        transform = .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? Self.focusedBackground : (self.rowState == .upNext ? Self.restBackground : Self.restBackgroundClear)
            self.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS; handle the press directly (same trap as CardTrackRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
