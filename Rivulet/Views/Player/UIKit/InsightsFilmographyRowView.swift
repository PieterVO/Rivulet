//
//  InsightsFilmographyRowView.swift
//  Rivulet
//
//  Compact filmography shelf for the in-panel `.actor` state (Docs/
//  superpowers/plans/2026-07-07-insights-in-panel-actor.md). Deliberately
//  NOT `ShelfRowCell` + `PosterCell`: those are tuned for the 1920pt
//  full-screen canvas (`MediaRowMetrics.rowLeading` = 52pt insets,
//  `posterFullCount` = 6, `TVPosterView` posters fixed at 296x444) — inside
//  the ~440pt panel content width that combination shows a sliver of a
//  single poster and produces a "focus vanishes then row jumps"
//  scroll-pacing artifact (ShelfRowCell's own offset-pitch math assumes the
//  1920pt equation). `ShelfRowCell`/`PosterCell` are left untouched for
//  their real full-screen callers (PersonDetailViewController, home).
//
//  This row is a plain `UIImageView`-based poster (no `TVPosterView` —
//  that view has no precedent below ~260pt anywhere in this codebase and
//  bakes in a caption-footer reservation + its own focus-scale machinery
//  that isn't meant for a compact sidebar tile), hosted in a small
//  horizontal `UICollectionView` sized so ~1.5 tiles are visible with a
//  tight peek — display-only (no onSelect), matching the v1 spec for the
//  full-page filmography rows this mirrors.
//

import UIKit

final class InsightsFilmographyRowView: UIView {

    enum Metrics {
        static let tileWidth: CGFloat = 132
        static let tileHeight: CGFloat = 198   // 2:3 poster ratio
        static let gap: CGFloat = 12
        static let inset: CGFloat = 4
        static let headerHeight: CGFloat = 32
        static let focusGrowthPadding: CGFloat = 20

        static var rowHeight: CGFloat { headerHeight + tileHeight + focusGrowthPadding }
    }

    private let headerLabel = UILabel()
    private(set) var collectionView: UICollectionView!
    private let flow = UICollectionViewFlowLayout()

    private var entries: [FilmographyEntry] = []
    /// Identity of the configured content; a change forces a reload (mirrors
    /// ShelfRowCell's contentToken so a same-content reconfigure is cheap and
    /// focus-safe).
    private var contentToken: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        clipsToBounds = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        headerLabel.textColor = .white
        addSubview(headerLabel)

        flow.scrollDirection = .horizontal
        flow.itemSize = CGSize(width: Metrics.tileWidth, height: Metrics.tileHeight)
        flow.minimumLineSpacing = Metrics.gap
        flow.minimumInteritemSpacing = Metrics.gap
        flow.sectionInset = UIEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flow)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        // Same rationale as ShelfRowCell: the row owns its own small window,
        // not the focus engine's default scroll-to-visible.
        collectionView.isScrollEnabled = false
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.clipsToBounds = false
        collectionView.register(InsightsFilmographyPosterCell.self, forCellWithReuseIdentifier: InsightsFilmographyPosterCell.reuseID)
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            headerLabel.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            collectionView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(title: String, entries: [FilmographyEntry]) {
        headerLabel.text = title
        let token = Self.contentToken(for: entries)
        guard token != contentToken else { return }
        contentToken = token
        self.entries = entries
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    private static func contentToken(for entries: [FilmographyEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry.item.ref.itemID) }
        return hasher.finalize()
    }

    // The row container itself never takes focus — its tiles do (mirrors
    // ShelfRowCell).
    override var canBecomeFocused: Bool { false }
}

extension InsightsFilmographyRowView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: InsightsFilmographyPosterCell.reuseID, for: indexPath) as! InsightsFilmographyPosterCell
        if indexPath.item < entries.count {
            cell.configure(item: entries[indexPath.item].item)
        }
        return cell
    }

    /// Keep the focused tile inside the small window — same one-driver
    /// pattern as ShelfRowCell, tuned for a ~1.5-tile-visible panel row
    /// instead of the 6-wide full-screen shelf.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath else { return }
        let pitch = Metrics.tileWidth + Metrics.gap
        let targetX = CGFloat(next.item) * pitch - Metrics.inset
        let maxX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        let clamped = min(max(0, targetX), maxX)
        guard abs(clamped - collectionView.contentOffset.x) > 0.5 else { return }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            collectionView.contentOffset.x = clamped
        }
    }
}

/// Compact poster tile — plain `UIImageView`, not `TVPosterView` (see file
/// header). Display-only: no watched badge / progress overlay (v1 parity
/// with the full-page filmography rows this mirrors, which are also
/// display-only in-panel).
final class InsightsFilmographyPosterCell: UICollectionViewCell {
    static let reuseID = "InsightsFilmographyPosterCell"

    private let posterImageView = UIImageView()
    private let placeholderPanel = UIView()
    private let fallbackIcon = UIImageView()
    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    private static let cornerRadius: CGFloat = 10
    private static let restBorder = UIColor.white.withAlphaComponent(0.08).cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.3).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false

        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterImageView.layer.cornerRadius = Self.cornerRadius
        posterImageView.layer.cornerCurve = .continuous
        posterImageView.layer.borderWidth = 1
        posterImageView.layer.borderColor = Self.restBorder
        contentView.addSubview(posterImageView)

        placeholderPanel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        placeholderPanel.layer.cornerRadius = Self.cornerRadius
        placeholderPanel.layer.cornerCurve = .continuous
        placeholderPanel.translatesAutoresizingMaskIntoConstraints = false
        contentView.insertSubview(placeholderPanel, belowSubview: posterImageView)

        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        fallbackIcon.image = UIImage(systemName: "film")
        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        fallbackIcon.contentMode = .center
        contentView.addSubview(fallbackIcon)

        NSLayoutConstraint.activate([
            posterImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            placeholderPanel.topAnchor.constraint(equalTo: posterImageView.topAnchor),
            placeholderPanel.leadingAnchor.constraint(equalTo: posterImageView.leadingAnchor),
            placeholderPanel.trailingAnchor.constraint(equalTo: posterImageView.trailingAnchor),
            placeholderPanel.bottomAnchor.constraint(equalTo: posterImageView.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: posterImageView.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: posterImageView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: MediaItem) {
        let url = item.artwork.poster
        guard url != currentURL else { return }
        currentURL = url
        imageLoadTask?.cancel()
        posterImageView.image = nil
        fallbackIcon.isHidden = url != nil
        guard let url else { return }
        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            if let image {
                self.posterImageView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        currentURL = nil
        posterImageView.image = nil
        fallbackIcon.isHidden = false
        transform = .identity
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.posterImageView.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
        }, completion: nil)
    }
}
