//
//  InsightsActorView.swift
//  Rivulet
//
//  The `.actor` state of the in-panel Insights cast panel (Docs/superpowers/
//  plans/2026-07-07-insights-in-panel-actor.md, Task C). Portrait + name +
//  bio header, then Movies/Shows filmography rows underneath — the SAME
//  cells `PersonDetailViewController` uses (`PersonHeaderCell` +
//  `ShelfRowCell`), just hosted in a small panel-scoped collection instead of
//  a full-screen page. Seeds instantly from the `MediaPerson` already in
//  hand (name + headshot); `populate(_:)` fills in the bio + filmography
//  once `PersonFilmographyProvider.load` resolves. No VC presentation, no
//  pause — the container that owns this view keeps video playing throughout.
//
//  Differences from PersonDetailViewController's collection (intentional,
//  not oversights):
//   - No `FocusScrollControlledCollectionView` driver: that class exists to
//     pin a TOP section under a fixed band (episodes-under-season-pills) and
//     centers everything else, which fights a small bounded panel. Here the
//     collection is a normal scrolling `UICollectionView` (isScrollEnabled
//     default true) — the same choice CardInfoView makes for panel-hosted
//     content — bounded by PlayerRailPanelView's maxHeight (560).
//   - Filmography shelves wire NO `onSelect` (v1 is display-only per spec).
//   - The header's MORE affordance is a no-op here (no full-screen bio sheet
//     in-panel); the bio still truncates to 3 lines in the cell itself.
//

import UIKit

final class InsightsActorView: UIView {

    // MARK: - Section / item model (mirrors PersonDetailViewController)

    private enum Section: Int, CaseIterable {
        case header
        case movies
        case shows
    }

    nonisolated private struct ItemID: Hashable, Sendable {
        let section: Int
        let token: String
    }

    private static let headerItem = ItemID(section: Section.header.rawValue, token: "header")
    private static let moviesItem = ItemID(section: Section.movies.rawValue, token: "movies-row")
    private static let showsItem = ItemID(section: Section.shows.rawValue, token: "shows-row")

    // MARK: - State

    private let person: MediaPerson
    private var detail: PersonDetail?
    private var movies: [FilmographyEntry] = []
    private var shows: [FilmographyEntry] = []
    /// True until `populate`/`showDetailsUnavailable` — drives the header's
    /// loading dots so the panel reads as "working" from first paint.
    private var isLoading = true
    /// Set once `showDetailsUnavailable()` is called — swaps in a quiet
    /// "No details available" line instead of the loading dots, and keeps
    /// the shelves hidden regardless of (empty) movies/shows state.
    private var detailsUnavailable = false

    private var sections: [Section] = [.header]
    private var shelfOffsets: [Section: CGFloat] = [:]

    // MARK: - Views

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ItemID>!

    /// Pin focus to the header on first landing only, then free — same
    /// pin-then-free pattern as InsightsCastListView / UpNextListView, so
    /// re-entering the actor state (e.g. after a rapid actor switch) doesn't
    /// yank focus back to the top if the user had moved into the shelves.
    private var hasPinnedInitialFocus = false

    // MARK: - Init

    init(person: MediaPerson) {
        self.person = person
        super.init(frame: .zero)
        configureCollectionView()
        configureDataSource()
        applySnapshot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Public

    /// Fills in the bio + filmography once the provider resolves. Safe to
    /// call at most once per instance (a fresh `InsightsActorView` is built
    /// per selection by the owning container).
    func populate(_ detail: PersonDetail) {
        self.detail = detail
        self.movies = detail.movies
        self.shows = detail.shows
        self.isLoading = false
        self.detailsUnavailable = false
        applySnapshot()
    }

    /// Graceful degrade when the load fails or returns nothing usable:
    /// portrait + name stay, a quiet line replaces the loading dots, and the
    /// filmography shelves stay hidden.
    func showDetailsUnavailable() {
        self.isLoading = false
        self.detailsUnavailable = true
        self.movies = []
        self.shows = []
        applySnapshot()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            self?.layoutSection(at: sectionIndex, environment: environment)
        }
        let cv = UICollectionView(frame: bounds, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.clipsToBounds = false
        cv.register(PersonHeaderCell.self, forCellWithReuseIdentifier: PersonHeaderCell.reuseID)
        cv.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        addSubview(cv)
        NSLayoutConstraint.activate([
            cv.topAnchor.constraint(equalTo: topAnchor),
            cv.bottomAnchor.constraint(equalTo: bottomAnchor),
            cv.leadingAnchor.constraint(equalTo: leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        collectionView = cv
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, ItemID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, itemID in
            self?.cell(for: itemID, at: indexPath, in: collectionView)
        }
    }

    // MARK: - Layout

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sections.count else { return nil }
        switch sections[sectionIndex] {
        case .header:        return makeHeaderSectionLayout()
        case .movies, .shows: return makeShelfSectionLayout()
        }
    }

    private func makeHeaderSectionLayout() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .estimated(280))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0)
        return section
    }

    /// Copied from PersonDetailViewController.makeShelfSectionLayout — same
    /// ShelfRowCell height math so the shelves render identically.
    private func makeShelfSectionLayout() -> NSCollectionLayoutSection {
        let shelfHeaderHeight: CGFloat = 44
        let rowHeight = shelfHeaderHeight + MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: MediaRowMetrics.rowTopInset, leading: 0,
            bottom: MediaRowMetrics.rowBottomInset, trailing: 0)
        return section
    }

    // MARK: - Cells

    private func cell(for itemID: ItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sections.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath)
        }
        switch sections[indexPath.section] {
        case .header:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath) as! PersonHeaderCell
            configureHeader(cell)
            return cell
        case .movies:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelf(cell, section: .movies, title: "Movies", entries: movies)
            return cell
        case .shows:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelf(cell, section: .shows, title: "Shows", entries: shows)
            return cell
        }
    }

    private func configureHeader(_ cell: PersonHeaderCell) {
        cell.configure(
            name: detail?.name ?? person.name,
            // "No details available" is shown via the loading-dots slot
            // being replaced by a quiet unavailable string — reuse the same
            // biography text slot so no header-only special case is needed.
            biography: detailsUnavailable ? "No details available" : detail?.biography,
            portraitURL: detail?.portraitURL ?? person.imageURL,
            isLoading: isLoading,
            // No full-screen bio sheet in-panel (spec: "no VC presentation
            // in this flow") — MORE is a no-op here.
            onMore: {})
    }

    private func configureShelf(_ cell: ShelfRowCell, section: Section, title: String, entries: [FilmographyEntry]) {
        cell.headerTitle = title
        cell.cellProvider = { [weak self] innerCV, indexPath in
            guard let self else {
                return innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
            }
            let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            let entries = (section == .movies) ? self.movies : self.shows
            if indexPath.item < entries.count {
                poster.configure(item: entries[indexPath.item].item)
            }
            return poster
        }
        // Display-only in v1: filmography posters are focusable/browsable
        // but Select is intentionally a no-op — onSelect stays unset.
        cell.onOffsetChanged = { [weak self] offset in
            self?.shelfOffsets[section] = offset
        }
        cell.configure(
            kind: .poster,
            realCount: entries.count,
            hasSkeleton: false,
            contentToken: contentToken(for: entries),
            initialOffset: shelfOffsets[section] ?? 0)
    }

    private func contentToken(for entries: [FilmographyEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry.item.ref.itemID) }
        return hasher.finalize()
    }

    // MARK: - Data / snapshot

    private func applySnapshot() {
        var visible: [Section] = [.header]
        if !movies.isEmpty { visible.append(.movies) }
        if !shows.isEmpty { visible.append(.shows) }
        sections = visible

        var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
        for section in visible {
            snapshot.appendSections([section.rawValue])
            switch section {
            case .header: snapshot.appendItems([Self.headerItem], toSection: section.rawValue)
            case .movies: snapshot.appendItems([Self.moviesItem], toSection: section.rawValue)
            case .shows:  snapshot.appendItems([Self.showsItem], toSection: section.rawValue)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshVisibleCells()
    }

    private func refreshVisibleCells() {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  indexPath.section < sections.count else { continue }
            switch sections[indexPath.section] {
            case .header:
                (cell as? PersonHeaderCell).map(configureHeader)
            case .movies:
                if let row = cell as? ShelfRowCell { configureShelf(row, section: .movies, title: "Movies", entries: movies) }
            case .shows:
                if let row = cell as? ShelfRowCell { configureShelf(row, section: .shows, title: "Shows", entries: shows) }
            }
        }
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Pin to the header/first poster on first landing only; once focus
        // has moved into the collection, express no preference so the
        // container's own re-presentation of this view (e.g. rapid actor
        // switch) doesn't yank focus back to the top.
        guard !hasPinnedInitialFocus else { return [] }
        return [collectionView]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: collectionView) {
            hasPinnedInitialFocus = true
        }
    }
}
