//
//  PlayerTrackPopupView.swift
//  Rivulet
//
//  Focus-trapped anchored popup list for track selection (subtitles,
//  audio). Positioned above the pill button that opened it. tvOS has no
//  native anchored-popover API (confirmed: no UIPopoverPresentationController
//  on tvOS) -- this is a fully custom positioned view, styled to mimic
//  AVPlayerViewController's transport-bar picker as closely as possible.
//
//  Focus is trapped to this view's rows via preferredFocusEnvironments;
//  no direct pill-to-pill navigation while open (must back out first).
//

import UIKit

final class PlayerTrackPopupView: UIView, AnchoredPopupPresenting {

    struct Row {
        let title: String
        let subtitle: String?
        let trackId: Int?
        let isSelected: Bool
    }

    private let rows: [Row]
    private let onSelect: (Int?) -> Void
    private let stack = UIStackView()
    private let backgroundEffectView: UIVisualEffectView
    private var rowButtons: [PopupRowButton] = []

    var onDismiss: (() -> Void)?

    init(tracks: [MediaTrack], selectedTrackId: Int?, showsOffRow: Bool, onSelect: @escaping (Int?) -> Void) {
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
        backgroundEffectView.layer.cornerRadius = 16
        backgroundEffectView.layer.cornerCurve = .continuous
        backgroundEffectView.clipsToBounds = true
        addSubview(backgroundEffectView)

        stack.axis = .vertical
        stack.spacing = 4
        addSubview(stack)

        [backgroundEffectView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        for row in rows {
            let button = PopupRowButton(row: row)
            button.addTarget(self, action: #selector(rowTapped(_:)), for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }
    }

    @objc private func rowTapped(_ sender: PopupRowButton) {
        guard let index = rowButtons.firstIndex(of: sender) else { return }
        onSelect(rows[index].trackId)
        dismiss()
    }

    // MARK: - Presentation

    func present(in container: UIView, anchoredTo anchor: UIView) {
        presentAnchored(in: container, anchoredTo: anchor, width: 360)
    }

    func dismiss() {
        dismissAnchored()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let first = rowButtons.first(where: { $0.row.isSelected }) {
            return [first]
        }
        return rowButtons.isEmpty ? [self] : [rowButtons[0]]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            dismiss()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - Popup Row Button

private final class PopupRowButton: UIControl {

    let row: PlayerTrackPopupView.Row
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkView = UIImageView(image: UIImage(systemName: "checkmark"))
    private let vStack = UIStackView()

    init(row: PlayerTrackPopupView.Row) {
        self.row = row
        super.init(frame: .zero)

        titleLabel.text = row.title
        titleLabel.font = .systemFont(ofSize: 20, weight: row.isSelected ? .semibold : .regular)
        titleLabel.textColor = .white

        subtitleLabel.text = row.subtitle
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.isHidden = row.subtitle == nil || row.subtitle?.isEmpty == true

        vStack.axis = .vertical
        vStack.spacing = 2
        vStack.isUserInteractionEnabled = false
        vStack.addArrangedSubview(titleLabel)
        vStack.addArrangedSubview(subtitleLabel)

        checkmarkView.tintColor = .systemBlue
        checkmarkView.isHidden = !row.isSelected
        checkmarkView.contentMode = .scaleAspectFit

        addSubview(vStack)
        addSubview(checkmarkView)

        [vStack, checkmarkView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            checkmarkView.widthAnchor.constraint(equalToConstant: 20),
            checkmarkView.heightAnchor.constraint(equalToConstant: 20),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])

        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            let animator = UIViewPropertyAnimator(duration: 0.15, timingParameters: UISpringTimingParameters(dampingRatio: 0.9))
            animator.addAnimations {
                self.backgroundColor = UIColor.white.withAlphaComponent(isFocused ? 0.2 : 0)
            }
            animator.startAnimation()
        }, completion: nil)
    }
}
