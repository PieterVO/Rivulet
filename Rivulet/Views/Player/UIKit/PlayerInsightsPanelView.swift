//
//  PlayerInsightsPanelView.swift
//  Rivulet
//
//  Cast list content for the Insights rail panel (P1), plus the read-only
//  Trivia section (P2a) appended below it in the same scroll view. Structure
//  and focus behavior mirror UpNextListView: scroll + stack, capped height,
//  pin-first-focus-then-free. Cast rows deep-link to the actor crossfade;
//  trivia rows are plain (non-focusable) text — read-only, scrollable only,
//  no per-fact action yet (Report lands in P2b).
//

import UIKit

final class InsightsCastListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 520
        // Horizontal inset for the row stack inside the scroll view so the
        // focused row's 1.02 scale doesn't overflow the clipping scroll
        // view's left/right edges. Matches UpNextListView.
        static let rowInset: CGFloat = 8
        static let sectionSpacing: CGFloat = 24
    }

    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [InsightsCastRowButton] = []
    /// Pin focus to the first row only on the FIRST landing; afterwards
    /// express no preference so the focus engine leaves focus where the
    /// user navigated (no bounce back). Matching flag in UpNextListView.
    private var hasPinnedInitialFocus = false

    /// Number of trivia fact rows currently in the stack. Internal (not
    /// private) so `@testable import Rivulet` tests can assert the
    /// graceful-absent rule (no trivia / all-filtered → 0) and the
    /// visible-count-after-filtering wiring without reaching into UIKit's
    /// `UIStackView.arrangedSubviews` directly.
    var triviaRowCount: Int {
        stack.arrangedSubviews.filter { $0 is InsightsTriviaRowView }.count
    }
    /// Whether the trivia section's header/footer chrome was added. Internal
    /// for the same testing reason as `triviaRowCount`.
    var hasTriviaSection: Bool { triviaRowCount > 0 }

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia? = nil,
        suppressedTriviaIDs: Set<String> = [],
        hideSpoilers: Bool = true,
        onSelect: @escaping (MediaPerson) -> Void
    ) {
        super.init(frame: .zero)
        setupContent()
        buildRows(cast: cast, onSelect: onSelect)
        buildTriviaSection(trivia: trivia, suppressedTriviaIDs: suppressedTriviaIDs, hideSpoilers: hideSpoilers)
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

    /// Appends the read-only Trivia section below the cast rows in the SAME
    /// stack/scroll view — no separate panel state, per the spec (Trivia
    /// lives in the panel's existing cast-list state). Graceful absent: nil
    /// trivia, or a trivia payload with no facts left after
    /// hide-spoilers/suppression filtering, adds nothing at all — same rule
    /// as cast's empty state.
    private func buildTriviaSection(trivia: TitleTrivia?, suppressedTriviaIDs: Set<String>, hideSpoilers: Bool) {
        guard let trivia else { return }
        let facts = trivia.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs)
        guard !facts.isEmpty else { return }

        // Extra breathing room between the cast rows and the trivia header,
        // beyond the stack's uniform inter-row spacing (matches the gap the
        // fixed "CAST" header keeps above the scroll view).
        if !rows.isEmpty {
            stack.setCustomSpacing(Metrics.sectionSpacing, after: rows[rows.count - 1])
        }

        let triviaHeader = UILabel()
        triviaHeader.attributedText = NSAttributedString(
            string: "TRIVIA",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .kern: 1.5,
            ]
        )
        stack.addArrangedSubview(triviaHeader)
        stack.setCustomSpacing(16, after: triviaHeader)

        for fact in facts {
            stack.addArrangedSubview(InsightsTriviaRowView(fact: fact))
        }

        if !trivia.attribution.isEmpty {
            let footer = UILabel()
            footer.numberOfLines = 1
            footer.font = .systemFont(ofSize: 13, weight: .regular)
            footer.textColor = UIColor.white.withAlphaComponent(0.35)
            let names = trivia.attribution.map(\.name).joined(separator: " · ")
            footer.text = "Info from \(names)"
            stack.setCustomSpacing(12, after: stack.arrangedSubviews.last ?? footer)
            stack.addArrangedSubview(footer)
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

// MARK: - InsightsTriviaRowView

/// One trivia fact row: fact text + a small category label. Read-only —
/// NOT focusable (no per-fact action exists yet; Report is P2b), so it
/// carries none of `InsightsCastRowButton`'s focus/press machinery. Matches
/// the cast rows' glass aesthetic (same rest background/corner radius) at
/// rest, just without the focus-reactive state.
final class InsightsTriviaRowView: UIView {

    private let textLabel = UILabel()
    private let categoryLabel = UILabel()

    init(fact: TriviaFact) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        textLabel.text = fact.text
        textLabel.font = .systemFont(ofSize: 17, weight: .regular)
        textLabel.textColor = .white
        textLabel.numberOfLines = 0

        categoryLabel.attributedText = NSAttributedString(
            string: fact.category.displayName.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.4),
                .kern: 1.0,
            ]
        )

        let contentStack = UIStackView(arrangedSubviews: [textLabel, categoryLabel])
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension TriviaCategory {
    /// Short display label for the row's category tag. Calm, no icons.
    var displayName: String {
        switch self {
        case .production: return "Production"
        case .casting: return "Casting"
        case .adaptation: return "Adaptation"
        case .reference: return "Reference"
        case .lore: return "Lore"
        case .goof: return "Goof"
        case .music: return "Music"
        case .other: return "Trivia"
        }
    }
}
