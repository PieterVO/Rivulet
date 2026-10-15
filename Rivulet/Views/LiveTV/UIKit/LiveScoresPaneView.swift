// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveScoresPaneView.swift
//  Rivulet
//
//  The Live TV player's Scores pane, in the Channels pane's glass box: league
//  tabs over a row of score cards, the game on screen first. Select tunes the
//  channel airing a game. Keeps the poller running while it is on screen.
//  Vertical, it is multiview's scores column.
//

import Combine
import UIKit

final class LiveScoresPaneView: UIView {

    private enum Metrics {
        static let height: CGFloat = 286
        static let radius: CGFloat = 48
        static let gap: CGFloat = 24
        static let sideInset: CGFloat = 30
        static let tabsTop: CGFloat = 18
        static let rowHeight: CGFloat = 196
    }

    private(set) var currentGameID: String?
    private let axis: NSLayoutConstraint.Axis
    private let channelAiring: (ScoreGame) -> UnifiedChannel?
    private let onSelect: (UnifiedChannel) -> Void
    private let onWatchWithScores: (() -> Void)?

    private let tabRow = UIStackView()
    /// Vertical only: the tabs scroll sideways when the column is too narrow.
    private let tabScroll = UIScrollView()
    private let statusLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    /// Up from the cards lands on the selected tab, Down from the tabs on the cards.
    private let tabGuide = UIFocusGuide()
    private var leagues: [League] = []
    private var league: League
    private var cards: [ScoresPaneCardView] = []
    private var subscription: ScoreboardPoller.Subscription?
    private var observers = Set<AnyCancellable>()

    init(league: League, currentGameID: String?, axis: NSLayoutConstraint.Axis = .horizontal,
         channelAiring: @escaping (ScoreGame) -> UnifiedChannel?,
         onSelect: @escaping (UnifiedChannel) -> Void,
         onWatchWithScores: (() -> Void)?) {
        self.league = league
        self.currentGameID = currentGameID
        self.axis = axis
        self.channelAiring = channelAiring
        self.onSelect = onSelect
        self.onWatchWithScores = onWatchWithScores
        super.init(frame: .zero)

        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        tabRow.axis = .horizontal
        tabRow.spacing = 16
        statusLabel.font = .systemFont(ofSize: 21, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        scrollView.clipsToBounds = true
        scrollView.layer.cornerRadius = Metrics.radius
        scrollView.layer.cornerCurve = .continuous
        stack.axis = axis
        stack.spacing = Metrics.gap
        scrollView.addSubview(stack)

        [glass, tabRow, statusLabel, scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        [glass, statusLabel, scrollView].forEach { addSubview($0) }
        addLayoutGuide(tabGuide)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tabGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabGuide.bottomAnchor.constraint(equalTo: scrollView.topAnchor),
        ])
        if axis == .horizontal {
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.contentInset = UIEdgeInsets(top: 0, left: Metrics.sideInset, bottom: 0, right: Metrics.sideInset)
            stack.alignment = .center
            addSubview(tabRow)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Metrics.height),
                tabRow.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.tabsTop),
                tabRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideInset + 10),
                statusLabel.centerYAnchor.constraint(equalTo: tabRow.centerYAnchor),
                statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.sideInset - 10),
                statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tabRow.trailingAnchor, constant: Metrics.gap),
                scrollView.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
                tabGuide.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            ])
        } else {
            // Room above and below the tabs for their focus growth.
            let tabPad: CGFloat = 10
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
            stack.alignment = .fill
            tabScroll.showsHorizontalScrollIndicator = false
            tabScroll.clipsToBounds = true
            tabScroll.contentInset = UIEdgeInsets(top: 0, left: Metrics.sideInset, bottom: 0, right: Metrics.sideInset)
            tabScroll.addSubview(tabRow)
            tabScroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tabScroll)
            NSLayoutConstraint.activate([
                tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.tabsTop - tabPad),
                tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                tabScroll.heightAnchor.constraint(equalTo: tabRow.heightAnchor, constant: tabPad * 2),
                tabRow.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor, constant: tabPad),
                tabRow.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor, constant: -tabPad),
                tabRow.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
                tabRow.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
                statusLabel.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 4),
                statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.sideInset + 10),
                statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.sideInset),
                scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor,
                                             constant: -Metrics.sideInset * 2),
                stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor,
                                               constant: Metrics.sideInset),
                tabGuide.topAnchor.constraint(equalTo: tabScroll.bottomAnchor),
            ])
        }
        buildTabs()
        buildCards()
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Pure helpers

    /// Leagues worth a tab: those whose board has games, in `League` order.
    static func leagues(in boards: [League: Scoreboard]) -> [League] {
        League.allCases.filter { boards[$0]?.games.isEmpty == false }
    }

    /// The game on screen first, then live, upcoming and final, each by start.
    static func ordered(_ games: [ScoreGame], currentID: String?) -> [ScoreGame] {
        func rank(_ game: ScoreGame) -> Int {
            if game.id == currentID { return 0 }
            switch game.state {
            case .in: return 1
            case .pre: return 2
            case .post: return 3
            }
        }
        return games.sorted { (rank($0), $0.start) < (rank($1), $1.start) }
    }

    /// "Scores paused" while polls fail, "Updated N min ago" on the worker's stale copy.
    static func statusText(board: Scoreboard?, isPaused: Bool, now: Date) -> String? {
        if isPaused { return "Scores paused" }
        guard let board, board.stale else { return nil }
        let minutes = max(1, Int(now.timeIntervalSince(board.fetchedAt) / 60))
        return "Updated \(minutes) min ago"
    }

    // MARK: - Content

    private func buildTabs() {
        leagues = Self.leagues(in: ScoreboardPoller.shared.boards)
        if !leagues.contains(league), let first = leagues.first { league = first }
        tabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in leagues {
            let tab = PlayerInfoPillButton(title: item.title, compact: true)
            tab.isSelectedTab = item == league
            tabRow.addArrangedSubview(tab)
        }
    }

    private var selectedTab: UIView? {
        leagues.firstIndex(of: league).map { tabRow.arrangedSubviews[$0] }
    }

    private func buildCards() {
        cards.forEach { $0.removeFromSuperview() }
        let games = Self.ordered(ScoreboardPoller.shared.boards[league]?.games ?? [], currentID: currentGameID)
        cards = games.map { game in
            let channel = channelAiring(game)
            let card = ScoresPaneCardView(game: game, isCurrent: game.id == currentGameID, isAiring: channel != nil)
            if let channel { card.onPress = { [weak self] in self?.onSelect(channel) } }
            return card
        }
        if let onWatchWithScores {
            let card = ScoresPaneCardView(watchWithScores: ())
            card.onPress = onWatchWithScores
            cards.append(card)
        }
        cards.forEach { stack.addArrangedSubview($0) }
        scrollView.contentOffset = axis == .horizontal
            ? CGPoint(x: -Metrics.sideInset, y: 0) : CGPoint(x: 0, y: -scrollView.contentInset.top)
        tabGuide.preferredFocusEnvironments = cards.first.map { [$0] } ?? []
    }

    /// Highlights a new current game (multiview's main tile changed channel) and puts it first.
    func setCurrentGame(_ id: String?, league: League) {
        guard id != currentGameID || league != self.league else { return }
        currentGameID = id
        self.league = league
        buildTabs()
        buildCards()
        updateStatus()
    }

    /// New scores land in the cards already on screen; the order holds while open.
    private func refresh() {
        let games = ScoreboardPoller.shared.boards[league]?.games ?? []
        let byID = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for card in cards {
            if let id = card.gameID, let game = byID[id] { card.configure(game) }
        }
        updateStatus()
    }

    private func updateStatus() {
        let poller = ScoreboardPoller.shared
        statusLabel.text = Self.statusText(board: poller.boards[league], isPaused: poller.isPaused, now: Date())
    }

    // MARK: - Polling

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            subscription = nil
            observers.removeAll()
            return
        }
        guard subscription == nil else { return }
        let poller = ScoreboardPoller.shared
        subscription = poller.subscribe()
        // `@Published` fires before the store; hop a turn so the new value is in.
        poller.$boards.combineLatest(poller.$isPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        cards.first.map { [$0] } ?? []
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if let index = tabRow.arrangedSubviews.firstIndex(of: next) {
            tabGuide.preferredFocusEnvironments = cards.first.map { [$0] } ?? []
            guard leagues[index] != league else { return }
            league = leagues[index]
            for case let (i, tab as PlayerInfoPillButton) in tabRow.arrangedSubviews.enumerated() {
                tab.isSelectedTab = i == index
            }
            buildCards()
            updateStatus()
        } else if next.isDescendant(of: stack) {
            tabGuide.preferredFocusEnvironments = selectedTab.map { [$0] } ?? []
        }
    }
}

/// One game: both teams' logo, abbreviation and score (from kickoff), the
/// status line and a LIVE marker. Dimmed when no channel airs it. Also the
/// closing "Watch with Scores" card.
private final class ScoresPaneCardView: UIView {

    private enum Metrics {
        static let size = CGSize(width: 300, height: 186)
        static let logo: CGFloat = 44
        static let inset: CGFloat = 22
    }

    private(set) var gameID: String?
    var onPress: (() -> Void)?
    private let isCurrent: Bool
    private let plate = UIView()
    private var rows: [(logo: UIImageView, abbr: UILabel, score: UILabel)] = []
    private let detail = UILabel()
    private let liveBadge = UILabel()
    private var logoURLs: [URL?] = []
    private var imageTasks: [Task<Void, Never>] = []

    init(game: ScoreGame, isCurrent: Bool, isAiring: Bool) {
        self.isCurrent = isCurrent
        gameID = game.id
        super.init(frame: .zero)
        setUpPlate()
        alpha = isAiring ? 1 : 0.4

        var previous: UIView?
        for _ in 0..<2 {
            let logo = UIImageView()
            logo.contentMode = .scaleAspectFit
            let abbr = UILabel()
            abbr.font = .systemFont(ofSize: 28, weight: .semibold)
            abbr.textColor = .white
            let score = UILabel()
            score.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold)
            score.textColor = .white
            [logo, abbr, score].forEach {
                addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            NSLayoutConstraint.activate([
                logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
                logo.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor, constant: previous == nil ? 18 : 10),
                logo.widthAnchor.constraint(equalToConstant: Metrics.logo),
                logo.heightAnchor.constraint(equalToConstant: Metrics.logo),
                abbr.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 14),
                abbr.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
                score.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
                score.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
                score.leadingAnchor.constraint(greaterThanOrEqualTo: abbr.trailingAnchor, constant: 10),
            ])
            rows.append((logo, abbr, score))
            previous = logo
        }

        liveBadge.text = "LIVE"
        liveBadge.font = .systemFont(ofSize: 17, weight: .bold)
        liveBadge.textColor = .white
        liveBadge.textAlignment = .center
        liveBadge.backgroundColor = .systemRed
        liveBadge.layer.cornerRadius = 6
        liveBadge.clipsToBounds = true
        detail.font = .systemFont(ofSize: 21, weight: .medium)
        detail.textColor = UIColor.white.withAlphaComponent(0.6)
        let status = UIStackView(arrangedSubviews: [liveBadge, detail])
        status.spacing = 10
        status.alignment = .center
        addSubview(status)
        status.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            liveBadge.widthAnchor.constraint(equalToConstant: 58),
            liveBadge.heightAnchor.constraint(equalToConstant: 26),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.inset),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        configure(game)
    }

    /// The closing card that opens multiview's scores layout.
    init(watchWithScores: Void) {
        isCurrent = false
        super.init(frame: .zero)
        setUpPlate()
        let icon = UIImageView(image: UIImage(systemName: "rectangle.split.2x1"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = "Watch with Scores"
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = .white
        [icon, title].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -22),
            icon.heightAnchor.constraint(equalToConstant: 56),
            icon.widthAnchor.constraint(equalToConstant: 72),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTasks.forEach { $0.cancel() } }

    private func setUpPlate() {
        plate.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        plate.layer.cornerRadius = 24
        plate.layer.cornerCurve = .continuous
        plate.alpha = isCurrent ? 0.5 : 0
        plate.isUserInteractionEnabled = false
        addSubview(plate)
        plate.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Below required so a vertical list's `.fill` can stretch the card.
            widthAnchor.constraint(equalToConstant: Metrics.size.width).withPriority(UILayoutPriority.defaultHigh.rawValue),
            heightAnchor.constraint(equalToConstant: Metrics.size.height),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(_ game: ScoreGame) {
        for (row, team) in zip(rows, [game.away, game.home]) {
            row.abbr.text = team.abbr
            row.score.text = game.state == .pre ? nil : team.score.map(String.init)
        }
        detail.text = game.detail
        liveBadge.isHidden = game.state != .in
        let urls = [game.away.logo, game.home.logo]
        guard urls != logoURLs else { return }
        logoURLs = urls
        imageTasks.forEach { $0.cancel() }
        imageTasks = zip(rows, urls).compactMap { row, url in
            guard let url else { return nil }
            return Task { [weak logo = row.logo] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard !Task.isCancelled else { return }
                logo?.image = image
            }
        }
    }

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onPress?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.plate.alpha = focused ? 1 : (self.isCurrent ? 0.5 : 0)
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }
    }
}
