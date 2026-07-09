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
        // Larger posters for TV viewing distance (2:3 ratio preserved).
        static let tileWidth: CGFloat = 168
        static let tileHeight: CGFloat = 252   // 2:3 poster ratio
        static let gap: CGFloat = 14
        static let inset: CGFloat = 4
        static let headerHeight: CGFloat = 36
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

    // Per-frame horizontal scroll driver state.
    //
    // `UIView.animate { contentOffset.x = … }` animates only the
    // PRESENTATION layer: the model offset jumps to the target immediately,
    // so the collection recycles cells against the FINAL rect and outgoing
    // tiles pop out before they visually reach the edge (same artifact —
    // and same CADisplayLink fix — as PlexHomeViewController's vertical
    // driver). Advancing the real offset per frame recycles progressively.
    fileprivate var offsetLink: CADisplayLink?
    fileprivate var offsetStartX: CGFloat = 0
    fileprivate var offsetTargetX: CGFloat = 0
    fileprivate var offsetStartTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        clipsToBounds = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        headerLabel.textColor = .white
        addSubview(headerLabel)

        flow.scrollDirection = .horizontal
        flow.itemSize = CGSize(width: Metrics.tileWidth, height: Metrics.tileHeight)
        flow.minimumLineSpacing = Metrics.gap
        flow.minimumInteritemSpacing = Metrics.gap
        // Vertical insets center the tiles in the row's focusGrowthPadding
        // so the focused 1.06 scale stays inside the clipping bounds.
        flow.sectionInset = UIEdgeInsets(
            top: Metrics.focusGrowthPadding / 2, left: Metrics.inset,
            bottom: Metrics.focusGrowthPadding / 2, right: Metrics.inset)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flow)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        // Same rationale as ShelfRowCell: the row owns its own small window,
        // not the focus engine's default scroll-to-visible.
        collectionView.isScrollEnabled = false
        // True so that if the focus engine ever re-resolves focus into this
        // row (e.g. after a vetoed off-the-edge move), it returns to the tile
        // that was focused instead of bouncing back to a default cell.
        collectionView.remembersLastFocusedIndexPath = true
        // Clipped: the culling boundary and the visual boundary must be the
        // same edge, or cells drawn past the bounds pop out mid-slide when
        // the collection recycles them.
        collectionView.clipsToBounds = true
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
        offsetLink?.invalidate()
        offsetLink = nil
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

    /// Host-gated focusability. The actor view turns the tiles OFF while the
    /// bio above is still being read (so Down click-steps the bio instead of
    /// the focus engine snatching focus down into the filmography), then ON
    /// once the bio is fully scrolled.
    var tilesFocusable: Bool = true

    /// Keeps Left/Right focus INSIDE this row so a press off the last tile
    /// stops there instead of the engine's diagonal search cone bouncing to
    /// a sibling section (Movies ↔ Shows) or the header. Up/Down still move
    /// between sections. This is the authoritative stop — a `pressesBegan`
    /// guard can't work, since the engine consumes the directional press the
    /// moment it finds any candidate.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left || context.focusHeading == .right else {
            return super.shouldUpdateFocus(in: context)
        }
        let prevInRow = context.previouslyFocusedView?.isDescendant(of: collectionView) ?? false
        let nextInRow = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
        if prevInRow && !nextInRow { return false }
        return super.shouldUpdateFocus(in: context)
    }
}

extension InsightsFilmographyRowView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        tilesFocusable
    }

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

    /// Keep the focused tile inside the small window — minimal scroll, not
    /// tile-to-left-edge alignment: only move when the focused tile is
    /// actually cut off, and only far enough to reveal it (aligning every
    /// focused tile to the left edge made the row visibly auto-scroll the
    /// moment focus entered it).
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath,
              let attrs = collectionView.layoutAttributesForItem(at: next) else { return }
        let visibleLeft = collectionView.contentOffset.x
        let visibleRight = visibleLeft + collectionView.bounds.width
        var targetX = collectionView.contentOffset.x
        if attrs.frame.minX - Metrics.inset < visibleLeft {
            targetX = attrs.frame.minX - Metrics.inset
        } else if attrs.frame.maxX + Metrics.inset > visibleRight {
            targetX = attrs.frame.maxX + Metrics.inset - collectionView.bounds.width
        } else {
            return
        }
        let maxX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        animateOffset(toX: min(max(0, targetX), maxX))
    }

    private func animateOffset(toX targetX: CGFloat) {
        guard abs(targetX - collectionView.contentOffset.x) > 0.5 else { return }
        offsetLink?.invalidate()
        offsetStartX = collectionView.contentOffset.x
        offsetTargetX = targetX
        offsetStartTime = CACurrentMediaTime()
        // Weak proxy: CADisplayLink retains its target strongly, and this
        // view has no reliable teardown hook while a link holds it alive —
        // the proxy self-invalidates once the row deallocates.
        let link = CADisplayLink(target: OffsetLinkProxy(self), selector: #selector(OffsetLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    fileprivate func tickOffset(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - offsetStartTime) / FocusScrollMotion.settleDuration)
        let e = FocusScrollMotion.ease(t)
        collectionView.contentOffset.x = offsetStartX + (offsetTargetX - offsetStartX) * CGFloat(e)
        if t >= 1 {
            link.invalidate()
            offsetLink = nil
        }
    }

    private final class OffsetLinkProxy: NSObject {
        private weak var target: InsightsFilmographyRowView?
        init(_ target: InsightsFilmographyRowView) { self.target = target }
        @objc func tick(_ link: CADisplayLink) {
            guard let target else { link.invalidate(); return }
            target.tickOffset(link)
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
