//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  Cast list content for the Insights rail panel (P1). Structure and
//  focus behavior mirror UpNextListView: scroll + stack, capped height,
//  pin-first-focus-then-free. Rows deep-link to the Person detail page.
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 520
        // Horizontal inset for the row stack inside the scroll view so the
        // focused row's 1.02 scale doesn't overflow the clipping scroll
        // view's left/right edges. Matches UpNextListView.
        static let rowInset: CGFloat = 8
    }

    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [InsightsCastRowButton] = []
    /// Pin focus to the first row only on the FIRST landing; afterwards
    /// express no preference so the focus engine leaves focus where the
    /// user navigated (no bounce back). Matching flag in UpNextListView.
    private var hasPinnedInitialFocus = false

    init(cast: [MediaPerson], onSelect: @escaping (MediaPerson) -> Void) {
        super.init(frame: .zero)
        setupContent()
        buildRows(cast: cast, onSelect: onSelect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(headerLabel)
        addSubview(scrollView)

        headerLabel.attributedText = NSAttributedString(
            string: "CAST",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .kern: 1.5,
            ]
        )

        // Scroll view caps content up to a maxHeight, so a short cast
        // hugs its rows while a long one scrolls.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            // Header stays flush with the rows' own (inset) content, not
            // the outer view edge, so it aligns with row text/thumbnails
            // rather than the scroll view's outer bounds.
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.rowInset),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    private func buildRows(cast: [MediaPerson], onSelect: @escaping (MediaPerson) -> Void) {
        for person in cast {
            let row = InsightsCastRowButton(person: person)
            row.onTap = { onSelect(person) }
            stack.addArrangedSubview(row)
            rows.append(row)
        }
    }

    // MARK: - Teardown

    override func removeFromSuperview() {
        rows.forEach { $0.cancelImageLoad() }
        super.removeFromSuperview()
    }

    deinit {
        rows.forEach { $0.cancelImageLoad() }
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Once focus has landed, express no preference so the engine keeps
        // focus on the current row (no bounce back to the first row).
        guard !hasPinnedInitialFocus else { return [] }
        if let first = rows.first { return [first] }
        return [self]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Once focus enters any of our rows, stop pinning the first row.
        if let next = context.nextFocusedView, rows.contains(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
        }
    }
}

// MARK: - InsightsCastRowButton

final class InsightsCastRowButton: UIControl {

    var onTap: (() -> Void)?

    private let headshotView = UIImageView()
    private let fallbackIcon = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let nameLabel = UILabel()
    private let roleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?

    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let restBorder = UIColor.clear.cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor
    private static let headshotSide: CGFloat = 68

    init(person: MediaPerson) {
        super.init(frame: .zero)
        setupViews(person: person)
        loadHeadshot(person.imageURL)
        applyRestAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews(person: MediaPerson) {
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorder

        let side = Self.headshotSide
        headshotView.contentMode = .scaleAspectFill
        headshotView.clipsToBounds = true
        headshotView.layer.cornerRadius = side / 2
        headshotView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.35)
        fallbackIcon.contentMode = .scaleAspectFit
        headshotView.addSubview(fallbackIcon)

        nameLabel.text = person.name
        nameLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1

        let role = person.role ?? ""
        roleLabel.text = role
        roleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        roleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        roleLabel.numberOfLines = 1
        roleLabel.isHidden = role.isEmpty

        let textStack = UIStackView(arrangedSubviews: [nameLabel, roleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        [headshotView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 92),

            headshotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headshotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            headshotView.widthAnchor.constraint(equalToConstant: side),
            headshotView.heightAnchor.constraint(equalToConstant: side),

            fallbackIcon.centerXAnchor.constraint(equalTo: headshotView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: headshotView.centerYAnchor),
            fallbackIcon.widthAnchor.constraint(equalToConstant: 34),
            fallbackIcon.heightAnchor.constraint(equalToConstant: 34),

            textStack.leadingAnchor.constraint(equalTo: headshotView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func loadHeadshot(_ url: URL?) {
        guard let url else { return }
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            if let image {
                self.headshotView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    private func applyRestAppearance() {
        backgroundColor = Self.restBackground
        layer.borderColor = Self.restBorder
        transform = .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? Self.focusedBackground : Self.restBackground
            self.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }

    // Select does not fire .primaryActionTriggered on plain UIControl on
    // tvOS; handle the press directly (same trap as UpNextRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
