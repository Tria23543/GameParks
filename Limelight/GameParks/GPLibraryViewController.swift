//
//  GPLibraryViewController.swift
//  GameParks
//
//  The design's Library: the selected PC's full Sunshine app list
//  — Steam games and her own installs side by side — searchable,
//  with the All / Big games / Classics / Favourites chips. Every
//  state (no PC, unpaired, load failed, no matches) is explained
//  with a way forward.
//

import UIKit

final class GPLibraryViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private enum Filter {
        case all, big, classics, favourites
    }

    private let subtitleLabel = gpLabel(nil, font: GPFont.body(14), color: GPColor.textSecondary, lines: 1)
    private let searchField = UITextField()
    private var filter: Filter = .all
    private var chips: [Filter: GPChipButton] = [:]
    private let dynamicStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.addArrangedSubview(gpLabel("Library", font: GPFont.display(28, weight: .extrabold), color: GPColor.textPrimary, lines: 1))
        header.addArrangedSubview(subtitleLabel)
        contentStack.addArrangedSubview(header)

        // Search
        let searchContainer = UIView()
        searchContainer.backgroundColor = GPColor.panel
        searchContainer.layer.cornerRadius = 14
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search your games",
            attributes: [.foregroundColor: GPColor.textFaint])
        searchField.textColor = GPColor.textPrimary
        searchField.font = GPFont.body(15)
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchContainer.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 12),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -12),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -14),
        ])
        contentStack.addArrangedSubview(searchContainer)

        // Filter chips
        let chipRow = UIStackView()
        chipRow.axis = .horizontal
        chipRow.spacing = 8
        for (value, title) in [(Filter.all, "All"), (Filter.big, "Big games"), (Filter.classics, "Classics"), (Filter.favourites, "Favourites")] {
            let chip = GPChipButton(title: title)
            chip.tag = filterTag(value)
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips[value] = chip
            chipRow.addArrangedSubview(chip)
        }
        chipRow.addArrangedSubview(UIView())
        contentStack.addArrangedSubview(chipRow)

        dynamicStack.axis = .vertical
        dynamicStack.spacing = 10
        contentStack.addArrangedSubview(dynamicStack)

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPAppListChanged, object: nil)
        refreshChips()
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    @objc private func stateChanged() {
        rebuild()
    }

    @objc private func searchChanged() {
        rebuild()
    }

    private func filterTag(_ value: Filter) -> Int {
        switch value {
        case .all: return 0
        case .big: return 1
        case .classics: return 2
        case .favourites: return 3
        }
    }

    @objc private func chipTapped(_ sender: GPChipButton) {
        switch sender.tag {
        case 1: filter = .big
        case 2: filter = .classics
        case 3: filter = .favourites
        default: filter = .all
        }
        refreshChips()
        rebuild()
    }

    private func refreshChips() {
        for (value, chip) in chips {
            chip.chipSelected = (value == filter)
        }
    }

    // MARK: - Rendering

    private func rebuild() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared()

        guard let host = session.selectedHost ?? session.hosts.first else {
            subtitleLabel.text = "No PC yet"
            let message = GPMessageView()
            message.configure(title: "No PC found yet",
                              message: "Your games live on your PC. Once GameParks finds it on your network, they all appear here.",
                              actionTitle: "Go to Home")
            message.actionButton.addTarget(self, action: #selector(goHome), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        let allApps = GPCatalog.sortedApps(for: host)
        subtitleLabel.text = "\(allApps.count) games · Steam + your own installs"

        if host.pairState != .paired {
            let message = GPMessageView()
            message.configure(title: "Pair with your PC to see its games",
                              message: "Your library is read from Sunshine on the PC, and that needs the one-time pairing.",
                              actionTitle: "Open PC page")
            message.actionButton.addTarget(self, action: #selector(openHostPage), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        if allApps.isEmpty {
            let message = GPMessageView()
            if let error = session.appListError(for: host) {
                message.configure(title: "Couldn't load your games", message: error, actionTitle: "Try again")
            } else {
                message.configure(title: "No games found on this PC yet",
                                  message: "Games appear here once they're in Sunshine's app list on the PC.",
                                  actionTitle: "Check again")
            }
            message.actionButton.addTarget(self, action: #selector(retryAppList), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        var apps = allApps
        switch filter {
        case .all:
            break
        case .big:
            apps = apps.filter { !GPCatalog.info(for: $0).isClassic }
        case .classics:
            apps = apps.filter { GPCatalog.info(for: $0).isClassic }
        case .favourites:
            apps = apps.filter { GPCatalog.isFavourite(host: host, app: $0) }
        }
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            apps = apps.filter { ($0.name ?? "").lowercased().contains(query) }
        }

        if apps.isEmpty {
            dynamicStack.addArrangedSubview(gpLabel("No games match — try another search.",
                                                    font: GPFont.body(14), color: GPColor.textSecondary, lines: 0))
            return
        }

        for app in apps {
            let row = GPAppRow()
            let info = GPCatalog.info(for: app)
            row.configure(name: app.name ?? "",
                          subtitle: info.sourceTag,
                          cover: GPCatalog.coverImage(for: app))
            row.accessibilityIdentifier = GPCatalog.appKey(host: host, app: app)
            row.addTarget(self, action: #selector(appRowTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }
    }

    // MARK: - Actions — navigation first

    @objc private func appRowTapped(_ sender: GPAppRow) {
        guard let host = GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first,
              let key = sender.accessibilityIdentifier,
              let app = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.appKey(host: host, app: $0) == key })
        else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func goHome() {
        if let tabBar = navigationController?.viewControllers.first as? GPTabBarController {
            tabBar.selectedIndex = 0
        }
    }

    @objc private func openHostPage() {
        guard let host = GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first else { return }
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func retryAppList() {
        guard let host = GPSessionController.shared().selectedHost ?? GPSessionController.shared().hosts.first else { return }
        GPSessionController.shared().fetchAppList(for: host)
    }
}
