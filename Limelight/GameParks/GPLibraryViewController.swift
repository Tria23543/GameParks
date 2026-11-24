//
//  GPLibraryViewController.swift
//  GameParks
//
//  Library in the approved design: searchable poster grid of the
//  host's whole Sunshine app list, with filter chips —
//  All · Big games · Classics · Favourites.
//

import UIKit

final class GPLibraryViewController: GPBaseViewController {
    private let searchBar = UISearchBar()
    private let chipsStack = UIStackView()
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private let emptyLabel = GPLabel("No games match — try another search.", font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut, lines: 0)
    private let emptyButton = UIButton(type: .system)
    private let headerTitle = GPLabel("Library", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink)
    private let headerSubtitle = GPLabel("", font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut)

    private enum Filter: Int {
        case all, big, classics, favourites
    }
    private var filter: Filter = .all
    private var searchText: String = ""
    private var allApps: [TemporaryApp] = []
    private var visibleApps: [TemporaryApp] = []
    private var chips: [GPChip] = []
    private var lastReloadSignature: String?
    private var searchDebounce: DispatchWorkItem?
    private var emptyContainer: UIStackView?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let headerStack = UIStackView(arrangedSubviews: [headerTitle, headerSubtitle])
        headerStack.axis = .vertical
        headerStack.spacing = 3
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerStack)

        searchBar.placeholder = "Search your games"
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.tintColor = GPTheme.accent
        searchBar.showsCancelButton = true
        let field = searchBar.searchTextField
        field.textColor = GPTheme.ink
        field.backgroundColor = GPTheme.panel
        field.font = GPTheme.body(14, weight: .semibold)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        chipsStack.axis = .horizontal
        chipsStack.spacing = 8
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        let chipTitles = ["All", "Big games", "Classics", "Favourites"]
        for (index, title) in chipTitles.enumerated() {
            let chip = GPChip(title: title)
            chip.tag = index
            chip.chipSelected = index == 0
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips.append(chip)
            chipsStack.addArrangedSubview(chip)
        }
        let chipsScroll = UIScrollView()
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.addSubview(chipsStack)
        view.addSubview(chipsScroll)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(GPPosterCell.self, forCellWithReuseIdentifier: GPPosterCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        emptyLabel.textAlignment = .center
        emptyButton.setTitleColor(GPTheme.accent, for: .normal)
        emptyButton.titleLabel?.font = GPTheme.body(15, weight: .bold)
        emptyButton.addTarget(self, action: #selector(emptyButtonTapped), for: .touchUpInside)
        let emptyStack = UIStackView(arrangedSubviews: [emptyLabel, emptyButton])
        emptyStack.axis = .vertical
        emptyStack.spacing = 10
        emptyStack.alignment = .center
        emptyStack.isHidden = true
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStack)
        emptyContainer = emptyStack

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            searchBar.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            chipsScroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 6),
            chipsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            chipsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsScroll.heightAnchor.constraint(equalToConstant: 40),
            chipsStack.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
            chipsStack.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor),
            chipsStack.heightAnchor.constraint(equalTo: chipsScroll.frameLayoutGuide.heightAnchor),

            collectionView.topAnchor.constraint(equalTo: chipsScroll.bottomAnchor, constant: 12),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpAppListChanged, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.reload() }
            return
        }
        guard isViewLoaded else { return }
        let engine = GPEngine.shared
        let host = engine.selectedHost
        let apps = host.map { engine.sortedApps(for: $0) } ?? []
        // Skip the refilter/reload when nothing the grid renders has
        // changed (notifications + viewWillAppear used to rerun the
        // whole filter on every appearance and every ping).
        let signature = [host?.uuid ?? "none", "\(host?.state.rawValue ?? -1)", "\(host?.pairState.rawValue ?? -1)",
                         apps.map { $0.id ?? $0.name ?? "?" }.joined(separator: ",")].joined(separator: "|")
        if signature == lastReloadSignature {
            return
        }
        lastReloadSignature = signature
        allApps = apps
        if host == nil {
            headerSubtitle.text = "No PC selected"
        } else {
            headerSubtitle.text = "\(allApps.count) \(allApps.count == 1 ? "game" : "games") · Steam + your own installs"
        }
        applyFilter()
    }

    private func applyFilter() {
        // Hoisted out of the per-app closure: the host and the
        // favourites set are the same for every app in the list.
        let favourites = GPFavourites.shared.all()
        let host = GPEngine.shared.selectedHost
        visibleApps = allApps.filter { app in
            let meta = GPGameMeta.meta(forAppName: app.name ?? "")
            switch filter {
            case .all:
                break
            case .big:
                if meta.group != .big { return false }
            case .classics:
                if meta.group != .classic { return false }
            case .favourites:
                guard let host = host else { return false }
                if !favourites.contains(GPStats.appKey(host: host, app: app)) { return false }
            }
            if !searchText.isEmpty {
                return (app.name ?? "").localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
        updateEmptyState()
        collectionView.reloadData()
    }

    /// The empty state must say WHERE the user is stuck and offer the
    /// way out — "try another search" was the only text for no-host,
    /// unpaired and offline states too, which made Library a dead end.
    private func updateEmptyState() {
        guard visibleApps.isEmpty else {
            emptyContainer?.isHidden = true
            return
        }
        let engine = GPEngine.shared
        let host = engine.selectedHost
        var showButton = false
        if !searchText.isEmpty || filter != .all {
            emptyLabel.text = "No games match — try another search."
        } else if host == nil {
            emptyLabel.text = "No PC found yet. Your games appear here once a PC is found on your network."
            showButton = true
        } else if host?.pairState != .paired {
            emptyLabel.text = "This PC is not paired yet. Pair it from the Home tab — one PIN, entered once — and your games will appear here."
            showButton = true
        } else if host?.state != .online {
            emptyLabel.text = "Your PC is asleep or offline. Wake it from the Home tab and your games will appear here."
            showButton = true
        } else {
            emptyLabel.text = "No games found on this PC yet. Add your games in Sunshine on the PC — they appear here automatically."
        }
        emptyButton.setTitle("Go to Home", for: .normal)
        emptyButton.isHidden = !showButton
        emptyContainer?.isHidden = false
    }

    @objc private func emptyButtonTapped() {
        tabBarController?.selectedIndex = 0
    }

    @objc private func chipTapped(_ sender: GPChip) {
        filter = Filter(rawValue: sender.tag) ?? .all
        chips.forEach { $0.chipSelected = $0.tag == sender.tag }
        applyFilter()
    }
}

extension GPLibraryViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        // Debounced: refiltering the whole library on every keystroke
        // made typing lag on large lists.
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyFilter()
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        self.searchText = ""
        applyFilter()
        searchBar.resignFirstResponder()
    }
}

extension GPLibraryViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Cell sizing belongs in the flow-layout delegate — mutating
        // the layout from inside viewDidLayoutSubviews invalidated
        // layout during a layout pass.
        let columns: CGFloat = view.bounds.width > 500 ? 4 : 3
        let spacing: CGFloat = 14
        let width = (collectionView.bounds.width - spacing * (columns - 1)) / columns
        // Poster (×1.42) + 7 spacing + two title lines + subtitle ≈ +56.
        return CGSize(width: width, height: width * 1.42 + 56)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return visibleApps.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard visibleApps.indices.contains(indexPath.item),
              let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GPPosterCell.reuseID, for: indexPath) as? GPPosterCell else {
            return UICollectionViewCell()
        }
        let app = visibleApps[indexPath.item]
        let meta = GPGameMeta.meta(forAppName: app.name ?? "")
        cell.configure(app: app, subtitle: meta.sourceTag, badge: nil)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard visibleApps.indices.contains(indexPath.item) else { return }
        let gameVC = GPGameViewController(app: visibleApps[indexPath.item])
        navigationController?.pushViewController(gameVC, animated: true)
    }
}

// MARK: - Favourites

final class GPFavourites {
    static let shared = GPFavourites()
    private let key = "GPFavourites.appKeys"

    func all() -> Set<String> {
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func contains(_ appKey: String) -> Bool {
        return all().contains(appKey)
    }

    func toggle(_ appKey: String) {
        var set = all()
        if set.contains(appKey) {
            set.remove(appKey)
        } else {
            set.insert(appKey)
        }
        UserDefaults.standard.set(Array(set), forKey: key)
    }
}
