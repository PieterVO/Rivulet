import UIKit

@MainActor
private final class SiloRequestCell: UITableViewCell {
    static let reuseIdentifier = "SiloRequestCell"
    private let kindLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let labels = UIStackView()
    private var showsFocus = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.backgroundColor = .clear
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        kindLabel.font = .systemFont(ofSize: 20, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 23, weight: .regular)
        [kindLabel, titleLabel, statusLabel].forEach {
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview($0)
        }
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            labels.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    func configure(kind: String, title: String, status: String) {
        kindLabel.text = kind
        titleLabel.text = title
        statusLabel.text = status
        accessibilityLabel = "\(kind), \(title), \(status)"
        updateAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        showsFocus = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ self.updateAppearance() }, completion: nil)
    }

    private func updateAppearance() {
        let focused = showsFocus
        contentView.backgroundColor = focused ? .white : .clear
        kindLabel.textColor = focused ? UIColor(white: 0.28, alpha: 1) : UIColor(white: 0.74, alpha: 1)
        titleLabel.textColor = focused ? .black : .white
        statusLabel.textColor = focused ? UIColor(white: 0.23, alpha: 1) : UIColor(white: 0.82, alpha: 1)
    }
}

/// Standalone Requests route. Present in a navigation controller or push onto an existing stack.
@MainActor final class SiloRequestsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Context { case list, search(String) }

    private let service: SiloRequests
    private let providerID: String
    private let authorityRevision: UInt64
    private let context: Context
    private let searchBar = UISearchBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var records: [SiloRequestRecord] = []
    private var results: [SiloRequestSearchResult] = []
    private var capability: SiloRequestsCapability?
    private var modeSearch = false
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var generation = 0
    private var nextSearchPage: Int?
    private var loadingNextPage = false

    init(provider: SiloProvider, context: Context = .list) {
        service = SiloRequests(provider: provider)
        providerID = provider.id
        authorityRevision = provider.authorityRevision
        self.context = context
        super.init(nibName: nil, bundle: nil)
        if case .search = context { modeSearch = true }
    }
    required init?(coder: NSCoder) { fatalError("Use init(provider:context:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Requests"
        view.backgroundColor = .black
        let heading = UILabel()
        heading.text = "Requests"
        heading.font = .systemFont(ofSize: 40, weight: .bold)
        heading.textColor = .white
        heading.translatesAutoresizingMaskIntoConstraints = false
        navigationItem.title = ""
        view.addSubview(heading)
        searchBar.placeholder = "Search movies and series"
        searchBar.overrideUserInterfaceStyle = .dark
        searchBar.tintColor = .white
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self
        table.register(SiloRequestCell.self, forCellReuseIdentifier: SiloRequestCell.reuseIdentifier)
        table.backgroundColor = .black
        table.rowHeight = 116
        message.textAlignment = .center
        message.numberOfLines = 0
        message.textColor = UIColor(white: 0.85, alpha: 1)
        message.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        view.addSubview(searchBar); view.addSubview(table); view.addSubview(message); view.addSubview(spinner)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            heading.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor),
            searchBar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            searchBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -24)
        ])
        if case let .search(query) = context { searchBar.text = query }
        refresh()
    }

    deinit { loadTask?.cancel(); mutationTask?.cancel() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private var ownsCurrentProfile: Bool {
        guard let provider = SiloSession.storedProvider() else { return false }
        return provider.id == providerID && provider.authorityRevision == authorityRevision
    }

    func invalidateAuthority() {
        generation += 1
        loadTask?.cancel()
        mutationTask?.cancel()
        if let presented = presentedViewController { presented.dismiss(animated: false) }
        records = []; results = []; capability = nil; nextSearchPage = nil
        if isViewLoaded {
            table.reloadData()
            spinner.stopAnimating()
            message.text = "Requests are unavailable for this profile."
        }
    }

    /// Call after returning from another route or when account/profile changes.
    func refresh() {
        guard ownsCurrentProfile else { invalidateAuthority(); return }
        generation += 1
        let current = generation
        loadTask?.cancel()
        nextSearchPage = nil
        loadingNextPage = false
        records = []; results = []; capability = nil
        table.reloadData()
        spinner.startAnimating(); message.text = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await service.status()
                guard current == generation else { return }
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                capability = status
                guard status.isAvailable else {
                    records = []; results = []; table.reloadData(); message.text = "Requests are unavailable for this profile."
                    spinner.stopAnimating(); return
                }
                if modeSearch, let query = searchBar.text, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let page = try await service.search(query)
                    guard current == generation else { return }
                    guard ownsCurrentProfile else { invalidateAuthority(); return }
                    results = page.results
                    nextSearchPage = page.page < page.totalPages ? page.page + 1 : nil
                } else {
                    let latest = try await service.mine()
                    guard current == generation else { return }
                    guard ownsCurrentProfile else { invalidateAuthority(); return }
                    records = latest
                    modeSearch = false
                }
                table.reloadData()
                message.text = (modeSearch ? results.isEmpty : records.isEmpty) ? "No requests found." : nil
            } catch {
                guard current == generation else { return }
                if !ownsCurrentProfile { invalidateAuthority(); return }
                message.text = error.localizedDescription + "  Press Play/Pause to retry."
            }
            spinner.stopAnimating()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        modeSearch = !(searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchBar.resignFirstResponder()
        refresh()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .playPause }) { refresh(); return }
        super.pressesBegan(presses, with: event)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { modeSearch ? results.count : records.count }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if modeSearch && indexPath.row >= results.count - 5 { loadMoreSearchResults() }
    }

    private func loadMoreSearchResults() {
        guard ownsCurrentProfile, !loadingNextPage, let page = nextSearchPage,
              let query = searchBar.text, !query.isEmpty else { return }
        loadingNextPage = true
        nextSearchPage = nil
        let current = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.search(query, page: page)
                guard current == generation else { return }
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                let seen = Set(results.map(\.id))
                results += response.results.filter { !seen.contains($0.id) }
                nextSearchPage = response.page < response.totalPages ? response.page + 1 : nil
                table.reloadData()
                message.text = nil
            } catch {
                guard current == generation else { return }
                if !ownsCurrentProfile { invalidateAuthority(); return }
                nextSearchPage = page
                message.text = error.localizedDescription + "  Press Play/Pause to retry."
            }
            loadingNextPage = false
        }
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SiloRequestCell.reuseIdentifier,
                                                       for: indexPath) as? SiloRequestCell else { fatalError("SiloRequestCell registration failed") }
        if modeSearch {
            let item = results[indexPath.row]
            cell.configure(kind: mediaKind(item.mediaType, year: item.year), title: item.title,
                           status: searchStatus(item))
        } else {
            let item = records[indexPath.row]
            cell.configure(kind: mediaKind(item.mediaType, year: item.year), title: item.title,
                           status: recordStatus(item))
        }
        return cell
    }

    private func mediaKind(_ type: SiloRequestMediaType, year: Int?) -> String {
        let kind = type == .series ? "Series" : type == .movie ? "Movie" : "Media"
        return year.map { "\(kind) · \($0)" } ?? kind
    }

    private func searchStatus(_ item: SiloRequestSearchResult) -> String {
        let request = item.request
        var parts: [String] = []
        if let state = request.state ?? request.status, !state.isEmpty {
            parts.append(state.replacingOccurrences(of: "_", with: " ").capitalized)
        } else if request.requestedByViewer == true || request.requestId != nil {
            parts.append("Requested")
        } else if item.availability == .available {
            parts.append("In library")
        } else if request.requestable {
            parts.append("Available to request")
        } else if item.availability == .unknown {
            parts.append("Availability unknown")
        } else {
            parts.append(request.reason ?? "Unavailable to request")
        }
        if request.following == true { parts.append("Following") }
        return parts.joined(separator: " · ")
    }

    private func recordStatus(_ item: SiloRequestRecord) -> String {
        switch item.outcome {
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .active, .unknown: return item.progress
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard ownsCurrentProfile, capability?.isAvailable == true else { invalidateAuthority(); return }
        let actions = UIAlertController(title: modeSearch ? results[indexPath.row].title : records[indexPath.row].title,
                                        message: nil, preferredStyle: .alert)
        if modeSearch {
            let item = results[indexPath.row]
            if item.request.requestable && item.availability == .missing {
                actions.addAction(UIAlertAction(title: "Request", style: .default) { [weak self] _ in
                    self?.mutate { service in _ = try await service.create(item) }
                })
            }
            if capability?.canFollow == true && item.request.canFollow {
                actions.addAction(UIAlertAction(title: "Follow", style: .default) { [weak self] _ in
                    self?.mutate { service in _ = try await service.follow(item) }
                })
            }
            if capability?.canFollow == true && item.request.canUnfollow {
                actions.addAction(UIAlertAction(title: "Unfollow", style: .default) { [weak self] _ in
                    self?.mutate { service in try await service.unfollow(item) }
                })
            }
        } else {
            let item = records[indexPath.row]
            actions.message = item.progress
            if item.canCancel {
                actions.addAction(UIAlertAction(title: "Cancel request", style: .destructive) { [weak self] _ in
                    self?.mutate { service in _ = try await service.cancel(item) }
                })
            }
        }
        actions.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(actions, animated: true)
    }

    private func mutate(_ action: @escaping (SiloRequests) async throws -> Void) {
        guard ownsCurrentProfile, capability?.isAvailable == true, mutationTask == nil else { return }
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do { try await action(service) }
            catch {
                guard ownsCurrentProfile else { invalidateAuthority(); return }
                let alert = UIAlertController(title: "Request status uncertain", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            mutationTask = nil
            guard ownsCurrentProfile else { invalidateAuthority(); return }
            // Always reconcile from the server, including uncertain mutation outcomes.
            refresh()
        }
    }
}
