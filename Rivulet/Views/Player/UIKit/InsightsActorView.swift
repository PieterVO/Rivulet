//
//  InsightsActorView.swift
//  Rivulet
//
//  `.actor` state of the in-panel Insights cast panel (Docs/superpowers/
//  plans/2026-07-07-insights-in-panel-actor.md, Task C). Compact portrait +
//  name + bio header, then Movies/Shows filmography rows underneath — all
//  panel-sized (~440pt content width), NOT the full-screen Person page's
//  `PersonHeaderCell` / `ShelfRowCell`. Seeds instantly with the `MediaPerson`
//  already in hand (name + headshot); `populate(_:)` fills in bio +
//  filmography once `PersonFilmographyProvider.load` resolves. No VC
//  presentation, no pause — the container owns this view and keeps video
//  playing throughout.
//
//  Review finding (fixed here): the original version reused
//  `PersonHeaderCell` + `ShelfRowCell` verbatim. `PersonHeaderCell` pins a
//  FIXED 1151pt-wide centered `headerContent` (built for the 1920pt
//  full-screen canvas) that spilled ~350pt past each panel edge over the
//  video; `ShelfRowCell`'s `MediaRowMetrics`-driven insets/pacing (52pt
//  insets, 6-wide window) produced a "focus vanishes then row jumps"
//  scroll-pacing artifact at ~440pt. Both shared cells are left untouched
//  for their real full-screen callers (PersonDetailViewController, home) —
//  this view now uses two purpose-built panel-sized views instead:
//  `InsightsActorHeaderView` and `InsightsFilmographyRowView`.
//
//  Structure is a plain `UIScrollView` + `UIStackView` (the same pattern
//  `InsightsCastListView` already uses successfully in this panel), not a
//  `UICollectionView` with a diffable snapshot — there's no cell-reuse
//  benefit for at-most-3 stacked pieces of content, and it drops the
//  compositional-layout self-sizing-header complexity entirely.
//
//  Differs from PersonDetailViewController's page (intentional, not
//  oversights):
//  - Normal scrolling `UIScrollView` (isScrollEnabled default true) — same
//    choice CardInfoView makes for panel-hosted content — bounded by
//    PlayerRailPanelView's maxHeight (560).
//  - Filmography shelves wire NO `onSelect` (v1 display-only per spec).
//  - No MORE affordance / full-bio popup (no full-screen bio sheet
//    in-panel); bio truncates at a fixed line count in the header itself.
//

import UIKit

final class InsightsActorView: UIView {

    private enum Metrics {
        static let rowSpacing: CGFloat = 20
        static let rowInset: CGFloat = 8
        /// Offset per Up/Down edge click while the header holds focus —
        /// same step CardInfoView's InfoScrollView uses.
        static let clickStep: CGFloat = 240
    }

    private let person: MediaPerson
    /// Internal (not private) visibility so `@testable import Rivulet` tests
    /// can observe whether a load result actually reached this view — the
    /// stale-load integration test asserts on this after a coordinator-token
    /// mismatch to prove `populate(_:)` never got called for a dropped load.
    private(set) var detail: PersonDetail?
    private var movies: [FilmographyEntry] = []
    private var shows: [FilmographyEntry] = []
    /// True until `populate`/`showDetailsUnavailable` drives the header's
    /// loading state, so the panel reads as "working" on first paint.
    private var isLoading = true
    /// Set once `showDetailsUnavailable()` is called — swaps in a quiet
    /// "No details available" line instead of the loading state; the
    /// filmography rows stay hidden regardless (empty movies/shows).
    private var detailsUnavailable = false

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let headerView = InsightsActorHeaderView()
    private let moviesRow = InsightsFilmographyRowView()
    private let showsRow = InsightsFilmographyRowView()

    /// Pin focus to the header/first row on first landing only, then free —
    /// same pin-then-free pattern as InsightsCastListView / UpNextListView,
    /// so re-entering the actor state (e.g. rapid actor switch) doesn't yank
    /// focus back to the top.
    private var hasPinnedInitialFocus = false

    // MARK: - Init

    init(person: MediaPerson) {
        self.person = person
        super.init(frame: .zero)
        setUp()
        headerView.configure(name: person.name, biography: nil, portraitURL: person.imageURL, isLoading: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Public

    /// Fills in bio + filmography once the provider resolves. Safe to call
    /// at most once per instance (a fresh `InsightsActorView` is built per
    /// selection by the owning container).
    func populate(_ detail: PersonDetail) {
        self.detail = detail
        self.movies = detail.movies
        self.shows = detail.shows
        self.isLoading = false
        self.detailsUnavailable = false
        applyContent()
    }

    /// Graceful degrade when the load fails or returns nothing usable:
    /// portrait + name stay, a quiet line replaces the loading state, and
    /// the filmography rows stay hidden.
    func showDetailsUnavailable() {
        self.isLoading = false
        self.detailsUnavailable = true
        self.movies = []
        self.shows = []
        applyContent()
    }

    // MARK: - Setup

    private func setUp() {
        clipsToBounds = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // UIScrollView clips by default — keep it, or the self-driven
        // scroll draws the bio/filmography straight past the panel's
        // bottom edge over the video (CardInfoView contains its content
        // for exactly this reason). rowInset gives the focused rows'
        // scale headroom inside the clip.
        scrollView.clipsToBounds = true
        scrollView.showsVerticalScrollIndicator = false
        // Same rationale as InsightsCastListView/InsightsFilmographyRowView:
        // the focus engine's own scroll-to-visible fights a self-driven
        // offset, and with header+movies+shows exceeding the panel's
        // actorHeightCap, this must drive its own vertical scroll from
        // didUpdateFocus (below) rather than rely on the disabled default.
        scrollView.isScrollEnabled = false
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = Metrics.rowSpacing
        scrollView.addSubview(stack)

        [headerView, moviesRow, showsRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview($0)
        }
        moviesRow.heightAnchor.constraint(equalToConstant: InsightsFilmographyRowView.Metrics.rowHeight).isActive = true
        showsRow.heightAnchor.constraint(equalToConstant: InsightsFilmographyRowView.Metrics.rowHeight).isActive = true
        moviesRow.isHidden = true
        showsRow.isHidden = true

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    private func applyContent() {
        headerView.configure(
            name: detail?.name ?? person.name,
            // "No details available" is shown via the loading-state slot
            // being replaced by a quiet unavailable string — reuse the same
            // biography text slot so no header-only special case is needed.
            biography: detailsUnavailable ? "No details available" : detail?.biography,
            // PersonFilmographyProvider always sets portraitURL = the same
            // Plex role thumb passed in via `person.imageURL` (it never
            // swaps in a TMDB image — see PersonFilmographyProvider.load),
            // so `person.imageURL` alone is enough; keeping the read off
            // `person` (not `detail`) also means the portrait never
            // reloads/flickers when `detail` arrives.
            portraitURL: person.imageURL,
            isLoading: isLoading)

        moviesRow.configure(title: "Movies", entries: movies)
        showsRow.configure(title: "Shows", entries: shows)
        moviesRow.isHidden = movies.isEmpty
        showsRow.isHidden = shows.isEmpty
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Pin to the header on first landing only (it is always focusable,
        // even before the filmography loads); once focus has moved into the
        // content, express no preference so the container's own
        // re-presentation of this view (e.g. rapid actor switch) doesn't
        // yank focus back to the top.
        guard !hasPinnedInitialFocus else { return [] }
        return [headerView]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // When focus lands on the header, gate the filmography off if the bio
        // extends below the fold, so Down click-steps the bio (info-popup
        // style) rather than the engine snatching focus down into the movie
        // list. A short bio that already fits leaves the tiles reachable.
        if context.nextFocusedView === headerView {
            setFilmographyFocusable(headerFullyVisible(at: scrollView.contentOffset.y))
        }
        guard let next = context.nextFocusedView, next.isDescendant(of: scrollView) else { return }
        hasPinnedInitialFocus = true
        scrollFocusedContentIntoView(next, coordinator: coordinator)
    }

    private func setFilmographyFocusable(_ on: Bool) {
        moviesRow.tilesFocusable = on
        showsRow.tilesFocusable = on
    }

    /// Whether the header (portrait + name + bio) is fully within the visible
    /// window at the given vertical offset — i.e. there is no more bio to
    /// scroll into view.
    private func headerFullyVisible(at offsetY: CGFloat) -> Bool {
        let headerFrame = headerView.convert(headerView.bounds, to: scrollView)
        return headerFrame.maxY <= offsetY + scrollView.bounds.height + 0.5
    }

    /// While the header holds focus, Up/Down edge clicks step the panel's
    /// scroll instead of moving focus — this is what makes a bio taller
    /// than the panel readable at all (a single focusable block can't be
    /// revealed by focus-driven row-hopping). Runs here because presses are
    /// delivered to the focused view (the header) and bubble up through
    /// this ancestor. Down stops consuming once the header's bottom is
    /// visible, so the press falls through to the focus engine and focus
    /// moves on to the filmography rows; Up stops consuming at the top.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .upArrow || press.type == .downArrow {
            if headerView.isFocused, step(up: press.type == .upArrow) {
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Steps the scroll one click in the given direction. Returns false —
    /// leaving the press to the focus engine — when there is nothing left
    /// to reveal in that direction.
    private func step(up: Bool) -> Bool {
        let target: CGFloat
        if up {
            guard scrollView.contentOffset.y > 0.5 else { return false }
            target = scrollView.contentOffset.y - Metrics.clickStep
        } else {
            // Bio already fully read — unlock the filmography and let the
            // press reach the focus engine so Down moves into the movie list.
            guard !headerFullyVisible(at: scrollView.contentOffset.y) else {
                setFilmographyFocusable(true)
                return false
            }
            target = scrollView.contentOffset.y + Metrics.clickStep
        }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clamped = min(max(0, target), maxY)
        guard abs(clamped - scrollView.contentOffset.y) > 0.5 else {
            if !up { setFilmographyFocusable(true) }   // hit the bottom exactly
            return false
        }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: clamped), animated: true)
        // If this click brings the bio's bottom into view, unlock the
        // filmography so the *next* Down lands on the movie list with no
        // wasted press.
        if !up, headerFullyVisible(at: clamped) {
            setFilmographyFocusable(true)
        }
        return true
    }

    /// Self-driven vertical scroll (scrollView.isScrollEnabled = false
    /// above), paged by section rather than minimally — see body.
    private func scrollFocusedContentIntoView(_ focused: UIView, coordinator: UIFocusAnimationCoordinator) {
        // SECTIONED paging: align the top of the arranged section that
        // contains the newly-focused view (header / Movies / Shows) to the
        // viewport top, so each focus hop reads as "next section" — never a
        // partial jumble of two sections.
        guard let section = stack.arrangedSubviews.first(where: { focused === $0 || focused.isDescendant(of: $0) })
        else { return }
        let sectionFrame = section.convert(section.bounds, to: scrollView)
        var targetY = sectionFrame.minY
        // The header with a long bio is taller than the viewport: when it
        // regains focus from the filmography below, align its BOTTOM — the
        // reading position right above where the user came from — and let
        // Up-clicks step back through the bio. Aligning its top would
        // teleport to the bio's first line.
        if sectionFrame.height > scrollView.bounds.height, sectionFrame.minY < scrollView.contentOffset.y {
            targetY = sectionFrame.maxY - scrollView.bounds.height
        }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clamped = min(max(0, targetY), maxY)
        guard abs(clamped - scrollView.contentOffset.y) > 0.5 else { return }
        // Driven on the shared focus-scroll duration/curve rather than the
        // focus coordinator's own ~0.2s animation, which read as an abrupt
        // snap between sections. Matches the home/detail focus-scroll feel.
        // (Plain scroll view, no cell recycling — a UIView animation on the
        // offset is enough; no CADisplayLink needed as in the filmography
        // collection.)
        UIView.animate(withDuration: FocusScrollMotion.settleDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.scrollView.contentOffset.y = clamped
        }
    }
}
