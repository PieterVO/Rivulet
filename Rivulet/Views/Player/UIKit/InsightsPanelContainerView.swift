//
//  InsightsPanelContainerView.swift
//  Rivulet
//
//  Two-state content for the Insights rail panel (Docs/superpowers/plans/
//  2026-07-07-insights-in-panel-actor.md, Task D). Replaces the old
//  person-page deep link: selecting a cast member CROSSFADES IN PLACE from
//  the cast list to an actor view (portrait + bio + filmography) while video
//  keeps playing — no pause/resume, no VC presentation anywhere in this flow.
//
//  Menu handling (mirrors the panel's own Menu ownership rather than
//  fighting it): in `.actor` state Menu is CONSUMED here (reverse-crossfade
//  back to `.list`); in `.list` state Menu is NOT consumed, so it bubbles to
//  `PlayerRailPanelView.pressesBegan`, which dismisses the whole panel.
//

import UIKit

final class InsightsPanelContainerView: UIView {

    private enum Metrics {
        /// Height cap for the `.actor` state — matches PlayerRailPanelView's
        /// own `maxHeight` (560) minus its content padding (20 top + 20
        /// bottom), so the panel never exceeds its own ceiling.
        static let actorHeightCap: CGFloat = 520
        static let crossfadeDuration: TimeInterval = 0.2
    }

    private enum State {
        case list
        case actor
    }

    private let cast: [MediaPerson]
    private let provider: PersonFilmographyProviding

    private let listView: InsightsCastListView
    private var actorView: InsightsActorView?
    private let coordinator = InsightsActorLoadCoordinator()
    private var state: State = .list

    private var heightConstraint: NSLayoutConstraint!

    init(cast: [MediaPerson], provider: PersonFilmographyProviding = PersonFilmographyProvider()) {
        self.cast = cast
        self.provider = provider
        // InsightsCastListView takes its onSelect closure at init, so the
        // container can't capture `self` there directly (not yet fully
        // initialized). Indirect through a box that's filled in right after
        // super.init() — the closure itself is never invoked before then
        // (it only fires on a user Select press on a row).
        let selectionBox = PersonSelectionBox()
        self.listView = InsightsCastListView(cast: cast, onSelect: { person in
            selectionBox.onSelect?(person)
        })
        super.init(frame: .zero)

        selectionBox.onSelect = { [weak self] person in
            self?.crossfadeToActor(person)
        }

        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Crossfade

    private func crossfadeToActor(_ person: MediaPerson) {
        guard state == .list else { return }
        let token = coordinator.begin()

        let actor = InsightsActorView(person: person)
        actor.translatesAutoresizingMaskIntoConstraints = false
        actor.alpha = 0
        addSubview(actor)
        NSLayoutConstraint.activate([
            actor.topAnchor.constraint(equalTo: topAnchor),
            actor.leadingAnchor.constraint(equalTo: leadingAnchor),
            actor.trailingAnchor.constraint(equalTo: trailingAnchor),
            actor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        actorView = actor
        state = .actor

        heightConstraint.constant = Metrics.actorHeightCap
        heightConstraint.isActive = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            self.listView.alpha = 0
            actor.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })

        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.provider.load(person: person)
            guard self.coordinator.isCurrent(token) else { return }
            // The actor view for THIS token is still `self.actorView` as
            // long as no newer selection/cancel has happened (guaranteed by
            // the token check above — cancel()/begin() are the only ways
            // the token goes stale, and both accompany a state change that
            // replaces or tears down `actorView`).
            if let result {
                actor.populate(result)
            } else {
                actor.showDetailsUnavailable()
            }
        }
    }

    private func reverseCrossfadeToList() {
        guard state == .actor, let actor = actorView else { return }
        coordinator.cancel()
        state = .list

        heightConstraint.isActive = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            actor.alpha = 0
            self.listView.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            actor.removeFromSuperview()
            if self?.actorView === actor {
                self?.actorView = nil
            }
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch state {
        case .list: return [listView]
        case .actor: return actorView.map { [$0] } ?? [listView]
        }
    }

    // MARK: - Menu handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            if state == .actor {
                reverseCrossfadeToList()
                return  // consumed — stays open, back to the cast list
            }
            // .list state: fall through to super so this bubbles to
            // PlayerRailPanelView, which owns closing the whole panel.
            break
        }
        super.pressesBegan(presses, with: event)
    }
}

/// Indirection so `InsightsPanelContainerView.init` can hand
/// `InsightsCastListView` an `onSelect` closure before `self` exists yet
/// (Swift forbids capturing `self` before `super.init()` returns). The real
/// handler is filled in immediately after `super.init()`; the row closure
/// only ever fires later, on a user Select press.
private final class PersonSelectionBox {
    var onSelect: ((MediaPerson) -> Void)?
}
