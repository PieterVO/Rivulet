// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaLibrarySortControl.swift
//  Rivulet
//
//  Full-width sort header cell for MediaLibraryViewController.
//
//  Layout: library title (left, 34pt bold) + item count (below, 17pt dimmed) and,
//  on the right in glass style, a focusable sort button and the View menu
//  button (outermost: Titles, Collections, Folders).
//  The CELL itself is not focusable; only the embedded SortButtons receive focus.
//
//  Glass + focus appearance mirrors FocusableActionButton.swift and the
//  AppStoreActionButtonStyle values in GlassRowStyle.swift:
//    - resting fill: white.withAlphaComponent(0.15), border white 0.2
//    - focused fill: .white, content inverted to black
//    - scale: 1.0 -> 1.06 via UIFocusAnimationCoordinator
//
//  Both buttons open a system menu (`UIButton.menu`). Up and Down reach them
//  only from beneath them, so a column on the left passes straight by.
//

import UIKit

// MARK: - SortOption display name

extension SortOption {
    var displayName: String {
        switch self {
        case .titleAsc:        "Title A-Z"
        case .titleDesc:       "Title Z-A"
        case .releaseDateDesc: "Release Date"
        case .addedAtDesc:     "Date Added"
        case .addedAtAsc:      "Date Added (Oldest)"
        case .releaseDateAsc:  "Release Date (Oldest)"
        case .lastContentAddedDesc: "Recently Updated"
        case .ratingDesc:      "Rating"
        }
    }
}

// MARK: - LibraryViewMode

/// How a library tab shows its contents, saved per library and profile.
enum LibraryViewMode: String {
    case titles, collections, folders

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .titles: "square.grid.2x2"
        case .collections: "square.stack"
        case .folders: "folder"
        }
    }

    /// The View button's menu; nil when there is nothing to switch to.
    static func menu(_ modes: [LibraryViewMode], current: LibraryViewMode,
                     select: @escaping (LibraryViewMode) -> Void) -> UIMenu? {
        guard modes.count > 1 else { return nil }
        return UIMenu(children: modes.map { mode in
            UIAction(title: mode.title, image: UIImage(systemName: mode.symbol),
                     state: mode == current ? .on : .off) { _ in select(mode) }
        })
    }
}

// MARK: - SortButton

/// A focusable rounded button that renders a sort label + SF Symbol icon.
/// Manages its own glass/focus appearance via UIFocusAnimationCoordinator.
/// A UIButton so it can carry a `menu`, which Select then opens.
final class SortButton: UIButton {

    // MARK: - Subviews

    private let iconView: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = UIImage(systemName: "arrow.up.arrow.down", withConfiguration: cfg)
        let iv = UIImageView(image: img)
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let sortLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 17, weight: .semibold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let bgView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Whether a focus move may land here; nil always allows it.
    var isReachable: (() -> Bool)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        addSubview(bgView)
        bgView.addSubview(iconView)
        bgView.addSubview(sortLabel)

        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            sortLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            sortLabel.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -16),
            sortLabel.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
        ])
    }

    // MARK: - Configure

    /// The View button: shows `current` and opens `menu`; hidden without one.
    func configure(view current: LibraryViewMode, menu: UIMenu?) {
        configure(sortName: current.title, symbol: current.symbol)
        self.menu = menu
        showsMenuAsPrimaryAction = true
        isHidden = menu == nil
    }

    func configure(sortName: String, symbol: String = "arrow.up.arrow.down") {
        sortLabel.text = sortName
        iconView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { isReachable?() ?? true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.bgView.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.15)
            self.bgView.layer.borderColor = focused
                ? UIColor.white.withAlphaComponent(0.0).cgColor
                : UIColor.white.withAlphaComponent(0.2).cgColor
            self.iconView.tintColor = focused ? .black : .white
            self.sortLabel.textColor = focused ? .black : .white
        }
    }
}

// MARK: - MediaLibrarySortControl

/// Full-width UICollectionViewCell hosting the library title, item count, a
/// focusable sort button and the View menu button. The CELL is not focusable;
/// only the two SortButtons are.
final class MediaLibrarySortControl: UICollectionViewCell {

    static let reuseID = "library.sortHeader"

    // MARK: - Subviews

    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 34, weight: .bold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let countLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 17)
        lb.textColor = UIColor.white.withAlphaComponent(0.5)
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// The View menu: Titles, Collections, Folders.
    private let viewButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// The sort button's trailing edge: beside the View button while both
    /// show, otherwise at the cell edge. Not a UIStackView: its hiding
    /// constraint (width 0, required) fights SortButton's required internal
    /// padding and logs a conflict each toggle.
    private lazy var sortBesideView: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: viewButton.leadingAnchor, constant: -16)
    private lazy var sortAtEdge: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor)

    // MARK: - Public API


    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        for button in [sortButton, viewButton] { button.isReachable = { [weak self] in self?.buttonsReachable() ?? true } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setup() {
        // Cell must NOT be focusable; only the two buttons are.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(sortButton)
        contentView.addSubview(viewButton)

        NSLayoutConstraint.activate([
            // Title: left-aligned, vertically centered on the top text cluster.
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            // Count: just below the title, same left edge.
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            // View button: pinned to the right edge, so it never moves under
            // focus when the sort button hides.
            viewButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            viewButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            viewButton.heightAnchor.constraint(equalToConstant: 44),
            viewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Sort button: left of the View button, or at the edge
            // (configure() swaps these two).
            sortAtEdge,
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Keep the buttons from overrunning the title. Both stay active: a
            // hidden sort button parks under the View button, so either way the
            // leftmost visible button binds.
            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            viewButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

        ])
    }

    // MARK: - Configure

    /// In Collections the count reads "N collections" and the sort button
    /// hides, which also takes it out of the focus graph.
    func configure(title: String, count: Int, sortName: String, sortMenu: UIMenu,
                   view: LibraryViewMode, viewMenu: UIMenu?) {
        titleLabel.text = title
        countLabel.text = view == .collections ? "\(count) collections" : "\(count) items"
        sortButton.configure(sortName: sortName)
        sortButton.menu = sortMenu
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.isHidden = view == .collections
        viewButton.configure(view: view, menu: viewMenu)
        // Deactivate before activate, so the two are never active together.
        let beside = !viewButton.isHidden
        NSLayoutConstraint.deactivate([beside ? sortAtEdge : sortBesideView])
        NSLayoutConstraint.activate([beside ? sortBesideView : sortAtEdge])
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Reachable from inside the header, or from a view whose column overlaps the buttons.
    private func buttonsReachable() -> Bool {
        guard let window, let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return true }
        if focused.isDescendant(of: self) { return true }
        let left = [sortButton, viewButton].filter { !$0.isHidden }.map { $0.convert($0.bounds, to: window).minX }.min()
        guard let left else { return false }
        return focused.convert(focused.bounds, to: window).maxX > left
    }

    // Forward focus to the buttons (so the engine moves there on Up/Down into
    // this section rather than skipping past it entirely). A hidden sort button
    // is not focusable, so a programmatic request falls through to the View button.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, viewButton]
    }
}
