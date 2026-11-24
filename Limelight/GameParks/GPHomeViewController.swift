//
//  GPHomeViewController.swift
//  GameParks
//
//  The design's Home: greeting, the live PC card, Continue Playing,
//  "Jump back in" and "Your classics". Everything renders from
//  GPSessionController's state; every tap navigates first and lets
//  the destination screen load — nothing network-shaped ever sits
//  in front of a push.
//

import UIKit

final class GPHomeViewController: GPBaseViewController {
    private let dynamicStack = UIStackView()
    private let refreshControl = UIRefreshControl()

    override func viewDidLoad() {
        super.viewDidLoad()

        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        contentStack.addArrangedSubview(makeHeader(title: greeting, subtitle: "Ready to play, Glenda?"))

        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)

        refreshControl.tintColor = GPColor.accent
        refreshControl.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
        scrollView.refreshControl = refreshControl

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: GPHostsChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: GPAppListChangedNotification, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    @objc private func stateChanged() {
        rebuild()
    }

    @objc private func pulledToRefresh() {
        GPSessionController.shared.rescanLocalNetwork()
        // The scan reports through the normal notifications; stop
        // the spinner shortly after regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshControl.endRefreshing()
        }
    }

    // MARK: - Rendering

    private func rebuild() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared

        guard let host = session.selectedHost ?? session.hosts.first else {
            dynamicStack.addArrangedSubview(searchingView())
            return
        }

        dynamicStack.addArrangedSubview(hostCard(for: host))

        switch host.pairState {
        case .paired:
            rebuildPairedContent(for: host)
        default:
            if host.state == .offline {
                let message = GPMessageView()
                message.configure(
                    title: "Your PC looks offline",
                    message: "If it's asleep, open its page and tap Wake PC. If it's on, check Sunshine is running.",
                    actionTitle: "Open PC page")
                message.actionButton.addTarget(self, action: #selector(openSelectedHostPage), for: .touchUpInside)
                dynamicStack.addArrangedSubview(message)
            } else {
                let message = GPMessageView()
                message.configure(
                    title: "Not paired yet",
                    message: "This PC is not paired yet. Tap the card above to pair — one PIN, entered once — and your games will appear here.",
                    actionTitle: nil)
                dynamicStack.addArrangedSubview(message)
            }
        }
    }

    private func rebuildPairedContent(for host: TemporaryHost) {
        let session = GPSessionController.shared
        let apps = GPCatalog.sortedApps(for: host)

        if apps.isEmpty {
            let message = GPMessageView()
            if let error = session.appListError(for: host) {
                message.configure(
                    title: "Couldn't load your games",
                    message: error,
                    actionTitle: "Try again")
            } else {
                message.configure(
                    title: "No games found on this PC yet",
                    message: "Games appear here once they're in Sunshine's app list on the PC. Desktop and Steam games are added by Sunshine itself; your own installs can be added there too.",
                    actionTitle: "Check again")
            }
            message.actionButton.addTarget(self, action: #selector(retryAppList), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        // Continue playing: the most recently played game that's
        // still in the list.
        let lastPlayed = apps
            .map { (app: $0, date: GPStats.shared.lastPlayed(forAppKey: GPCatalog.appKey(host: host, app: $0))) }
            .filter { $0.date != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .first
        if let hero = lastPlayed {
            dynamicStack.addArrangedSubview(gpSectionHeader("Continue playing"))
            dynamicStack.addArrangedSubview(heroCard(host: host, app: hero.app))
        }

        let bigGames = apps.filter { !GPCatalog.info(for: $0).isClassic && !GPCatalog.isDesktop($0) }
        if !bigGames.isEmpty {
            dynamicStack.addArrangedSubview(gpSectionHeader("Jump back in", subtitle: "Steam library"))
            dynamicStack.addArrangedSubview(rail(for: host, apps: bigGames))
        }

        let classics = apps.filter { GPCatalog.info(for: $0).isClassic }
        if !classics.isEmpty {
            dynamicStack.addArrangedSubview(gpSectionHeader("Your classics", subtitle: "Your own copies"))
            dynamicStack.addArrangedSubview(rail(for: host, apps: classics))
        }

        if let desktop = apps.first(where: { GPCatalog.isDesktop($0) }) {
            let card = GPCardButton()
            card.stack.addArrangedSubview(gpLabel("Stream Desktop", font: GPFont.display(17, weight: .bold), color: GPColor.textPrimary, lines: 1))
            card.stack.addArrangedSubview(gpLabel("Your PC's desktop, on this phone", font: GPFont.body(13), color: GPColor.textSecondary, lines: 1))
            card.addTarget(self, action: #selector(desktopCardTapped), for: .touchUpInside)
            dynamicStack.addArrangedSubview(card)
            _ = desktop
        }
    }

    private func searchingView() -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 16

        let message = GPMessageView()
        message.configure(
            title: "No PC found yet",
            message: "GameParks searches your home network by itself. Make sure your PC is on, Sunshine is running, and this phone is on the same Wi-Fi as the PC.",
            actionTitle: "Search again")
        message.actionButton.addTarget(self, action: #selector(searchAgainTapped), for: .touchUpInside)
        container.addArrangedSubview(message)

        let addButton = gpSecondaryButton("Add your PC by address")
        addButton.addTarget(self, action: #selector(addByAddressTapped), for: .touchUpInside)
        container.addArrangedSubview(addButton)
        return container
    }

    private func hostCard(for host: TemporaryHost) -> UIView {
        let card = GPCardButton()

        let dot = UIView()
        dot.backgroundColor = host.state == .online ? GPColor.success
            : (host.state == .offline ? GPColor.danger : GPColor.warning)
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let nameLabel = gpLabel(host.name, font: GPFont.display(18, weight: .bold), color: GPColor.textPrimary, lines: 1)
        let titleRow = UIStackView(arrangedSubviews: [dot, nameLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 10
        card.stack.addArrangedSubview(titleRow)

        let statusText: String
        switch (host.state, host.pairState) {
        case (.online, .paired):
            statusText = "Online · Home Wi-Fi · Sunshine ready"
        case (.online, _):
            statusText = "Online · Not paired — tap to pair"
        case (.offline, _):
            statusText = "Offline"
        default:
            statusText = "Connecting…"
        }
        card.stack.addArrangedSubview(gpLabel(statusText, font: GPFont.body(13), color: GPColor.textSecondary, lines: 1))

        let session = GPSessionController.shared
        if host.state == .online, session.lastPingMs(for: host) >= 0 {
            card.stack.addArrangedSubview(gpLabel("\(session.lastPingMs(for: host)) ms", font: GPFont.body(12, weight: .semibold), color: GPColor.accent, lines: 1))
        }

        card.addTarget(self, action: #selector(hostCardTapped), for: .touchUpInside)
        return card
    }

    private func heroCard(host: TemporaryHost, app: TemporaryApp) -> UIView {
        let card = GPCardButton()
        let key = GPCatalog.appKey(host: host, app: app)
        card.stack.addArrangedSubview(gpLabel(app.name, font: GPFont.display(20, weight: .extrabold), color: GPColor.textPrimary, lines: 2))
        let played = GPStats.shared.seconds(forAppKey: key)
        let subtitle = played > 0
            ? "\(gpFormatPlaytime(played)) played · Last played \(gpFormatLastPlayed(GPStats.shared.lastPlayed(forAppKey: key)).lowercased())"
            : "Last played \(gpFormatLastPlayed(GPStats.shared.lastPlayed(forAppKey: key)).lowercased())"
        card.stack.addArrangedSubview(gpLabel(subtitle, font: GPFont.body(13), color: GPColor.textSecondary, lines: 1))

        let playPill = gpLabel("  ▶  Play  ", font: GPFont.display(14, weight: .bold), color: GPColor.onAccent, lines: 1)
        playPill.backgroundColor = GPColor.accent
        playPill.layer.cornerRadius = 10
        playPill.clipsToBounds = true
        playPill.textAlignment = .center
        let pillRow = UIStackView(arrangedSubviews: [playPill, UIView()])
        pillRow.axis = .horizontal
        card.stack.addArrangedSubview(pillRow)

        card.addTarget(self, action: #selector(heroCardTapped), for: .touchUpInside)
        return card
    }

    private func rail(for host: TemporaryHost, apps: [TemporaryApp]) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        for app in apps.prefix(10) {
            let key = GPCatalog.appKey(host: host, app: app)
            let played = GPStats.shared.seconds(forAppKey: key)
            let info = GPCatalog.info(for: app)
            let poster = GPPosterView()
            poster.configure(name: app.name ?? "",
                             subtitle: played > 0 ? "\(gpFormatPlaytime(played)) played" : info.sourceTag,
                             cover: GPCatalog.coverImage(for: app))
            poster.translatesAutoresizingMaskIntoConstraints = false
            poster.widthAnchor.constraint(equalToConstant: 118).isActive = true
            poster.addTarget(self, action: #selector(posterTapped(_:)), for: .touchUpInside)
            poster.accessibilityIdentifier = key
            row.addArrangedSubview(poster)
        }

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 218).isActive = true
        return scroll
    }

    // MARK: - Actions — navigation is always the first thing

    @objc private func hostCardTapped() {
        guard let host = GPSessionController.shared.selectedHost
                ?? GPSessionController.shared.hosts.first else { return }
        GPSessionController.shared.selectHost(host)
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func openSelectedHostPage() {
        hostCardTapped()
    }

    @objc private func heroCardTapped() {
        guard let host = currentHost(),
              let app = mostRecentApp(for: host) else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func desktopCardTapped() {
        guard let host = currentHost(),
              let desktop = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.isDesktop($0) }) else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: desktop), animated: true)
    }

    @objc private func posterTapped(_ sender: GPPosterView) {
        guard let host = currentHost(), let key = sender.accessibilityIdentifier,
              let app = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.appKey(host: host, app: $0) == key })
        else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func retryAppList() {
        guard let host = currentHost() else { return }
        GPSessionController.shared.fetchAppList(for: host)
    }

    @objc private func searchAgainTapped() {
        GPSessionController.shared.rescanLocalNetwork()
    }

    @objc private func addByAddressTapped() {
        presentAddByAddress()
    }

    // MARK: - Helpers

    private func currentHost() -> TemporaryHost? {
        return GPSessionController.shared.selectedHost ?? GPSessionController.shared.hosts.first
    }

    private func mostRecentApp(for host: TemporaryHost) -> TemporaryApp? {
        return GPCatalog.sortedApps(for: host)
            .map { (app: $0, date: GPStats.shared.lastPlayed(forAppKey: GPCatalog.appKey(host: host, app: $0))) }
            .filter { $0.date != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .first?.app
    }
}
