//
//  PlayerTrackPopupView.swift
//  Rivulet
//
//  Focus-trapped anchored popup for track selection (Subtitles / Audio),
//  styled after AVPlayerViewController's picker: a bold header, rows
//  with a leading checkmark column, and the system player's signature
//  focus treatment — the focused row fills white with black text.
//  Positioned above the control button that opened it. tvOS has no
//  native anchored-popover API (no UIPopoverPresentationController), so
//  this is a fully custom positioned view.
//
//  Focus is trapped to this view's rows via preferredFocusEnvironments;
//  no direct button-to-button navigation while open (must back out first).
//

import UIKit

final class PlayerTrackPopupView: UIView, AnchoredPopupPresenting {

    struct Row {
        let title: String
        let subtitle: String?
        let trackId: Int?
        let isSelected: Bool
    }

    private let header: String
    private let rows: [Row]
    private let onSelect: (Int?) -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let backgroundEffectView: UIVisualEffectView
    private var rowButtons: [PopupRowButton] = []

    var onDismiss: (() -> Void)?
    let presentedWidth: CGFloat = 420

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
        self.header = header
        self.rows = rows
        self.onSelect = onSelect

        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundEffectView.layer.cornerRadius = 24
        backgroundEffectView.layer.cornerCurve = .continuous
        backgroundEffectView.clipsToBounds = true
        addSubview(backgroundEffectView)

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

        [backgroundEffectView, headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        // The scroll view grows with content up to a cap, so short lists
        // hug their rows and long ones scroll.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 560),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        for row in rows {
            let button = PopupRowButton(row: row)
            button.onTap = { [weak self] in
                self?.onSelect(row.trackId)
                self?.dismiss()
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

    /// Real focus trap: preferredFocusEnvironments only steers the
    /// initial landing; directional presses can still walk focus out to
    /// the controls behind the popup. Fence them while presented.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if window != nil, let next = context.nextFocusedView, !next.isDescendant(of: self) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            dismiss()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // The ended phase of the same Menu press must be swallowed too:
    // if it bubbles, the system's default menu behavior invokes
    // dismiss() on the player and a second unwind layer peels.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            return
        }
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - Popup Row Button

private final class PopupRowButton: UIControl {

    let row: PlayerTrackPopupView.Row
    var onTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)
    ))
    private let vStack = UIStackView()

    init(row: PlayerTrackPopupView.Row) {
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
