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
    private var collectionView: UICollectionView!
    private let emptyLabel = GPLabel("No games match — try another search.", font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut)
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
        if let field = searchBar.value(forKey: "searchField") as? UITextField {
            field.textColor = GPTheme.ink
            field.backgroundColor = GPTheme.panel
            field.font = GPTheme.body(14, weight: .semibold)
        }
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

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(GPPosterCell.self, forCellWithReuseIdentifier: GPPosterCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

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

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpAppListChanged, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let columns: CGFloat = view.bounds.width > 500 ? 4 : 3
            let spacing: CGFloat = 14
            let width = (collectionView.bounds.width - spacing * (columns - 1)) / columns
            let height = width * 1.42 + 42
            if layout.itemSize.width != width {
                layout.itemSize = CGSize(width: width, height: height)
                layout.invalidateLayout()
            }
        }
    }

    @objc private func reload() {
        guard isViewLoaded else { return }
        let engine = GPEngine.shared
        if let host = engine.selectedHost {
            allApps = engine.sortedApps(for: host)
        } else {
            allApps = []
        }
        headerSubtitle.text = "\(allApps.count) games · Steam + your own installs"
        applyFilter()
    }

    private func applyFilter() {
        let favourites = GPFavourites.shared.all()
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
                guard let host = GPEngine.shared.selectedHost else { return false }
                if !favourites.contains(GPStats.appKey(host: host, app: app)) { return false }
            }
            if !searchText.isEmpty {
                return (app.name ?? "").localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
        emptyLabel.isHidden = !visibleApps.isEmpty
        collectionView.reloadData()
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
        applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension GPLibraryViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return visibleApps.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GPPosterCell.reuseID, for: indexPath) as! GPPosterCell
        let app = visibleApps[indexPath.item]
        let meta = GPGameMeta.meta(forAppName: app.name ?? "")
        cell.configure(app: app, subtitle: meta.sourceTag, badge: nil)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
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
