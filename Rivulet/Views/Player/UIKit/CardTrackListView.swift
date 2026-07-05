import UIKit

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
