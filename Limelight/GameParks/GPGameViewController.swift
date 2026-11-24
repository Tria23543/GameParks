//
//  GPGameViewController.swift
//  GameParks
//
//  The design's game page: big art, your playtime, one full-width
//  Play button. Play mirrors upstream's app-tap behaviour — if
//  another game is already running on the PC, the choice (resume
//  it, or quit it and start this one) is offered before anything
//  launches, exactly as upstream's app menu does.
//

import UIKit

final class GPGameViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private let hostUUID: String
    private let appID: String
    /// B-08: not a `let` — a successful id match refreshes the
    /// stored name, so the name fallback below compares against
    /// the game's CURRENT name, not the one it had when this page
    /// was opened.
    private var appName: String
    private let hostName: String
    private var host: TemporaryHost
    private var app: TemporaryApp
    private let dynamicStack = UIStackView()
    /// A-76: header labels, refreshed in rebuildContent.
    private var headerTitleLabel: UILabel?
    private var headerSubtitleLabel: UILabel?
    /// A-24: set once re-resolution has failed.
    private var appUnavailable = false

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
        self.hostUUID = host.uuid ?? ""
        self.appID = app.id ?? ""
        self.appName = app.name ?? ""
        self.hostName = (host.name as String?) ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let info = GPCatalog.info(for: app)
        let header = makeHeader(title: app.name ?? "Game",
                                subtitle: info.detailLine ?? info.sourceTag,
                                showsBack: true)
        let headerLabels = (header as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UILabel } ?? []
        headerTitleLabel = headerLabels.first
        headerSubtitleLabel = headerLabels.dropFirst().first
        contentStack.addArrangedSubview(header)
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPAppListChanged, object: nil)
        rebuildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A-31: appearance goes through the scroll-safe path.
        requestContentRebuild()
    }

    /// A-77: an id match counts only when BOTH ids are non-empty.
    private func idMatches(_ candidate: TemporaryApp) -> Bool {
        guard let candidateID = candidate.id, !candidateID.isEmpty, !appID.isEmpty else { return false }
        return candidateID == appID
    }

    private func isThisApp(_ candidate: TemporaryApp?) -> Bool {
        guard let candidate = candidate else { return false }
        return idMatches(candidate)
    }

    /// B-08: the name fallback compares normalised forms — case-
    /// and diacritic-folded, whitespace-collapsed — so a cosmetic
    /// rename in Sunshine doesn't defeat it the way exact equality
    /// against the originally stored name did.
    private static func normalisedName(_ name: String?) -> String {
        let folded = (name ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func nameMatches(_ candidate: TemporaryApp) -> Bool {
        let stored = Self.normalisedName(appName)
        guard !stored.isEmpty else { return false }
        return Self.normalisedName(candidate.name) == stored
    }

    @objc private func stateChanged() {
        let hosts = GPSessionController.shared().hosts
        // A-77: nil/empty UUID falls back to a name match.
        guard let currentHost = hosts.first(where: { $0.uuid == hostUUID && !hostUUID.isEmpty })
            ?? (hostUUID.isEmpty ? hosts.first(where: { $0.name == hostName }) : nil) else {
            markUnavailable()
            return
        }
        host = currentHost
        let apps = GPCatalog.sortedApps(for: currentHost)
        if apps.isEmpty {
            // The list hasn't loaded for this host yet — absence
            // here is not proof the game is gone.
            requestContentRebuild()
            return
        }
        if let currentApp = apps.first(where: { idMatches($0) }) {
            app = currentApp
            // B-08: keep the stored name current, so the fallback
            // below doesn't decay as the game is renamed over time.
            if let freshName = currentApp.name, !freshName.isEmpty {
                appName = freshName
            }
        } else if !appID.isEmpty {
            // A-77: id matching failed — fall back to the name-based
            // identity the appKey uses (host UUID + name). B-08:
            // the comparison is normalised, not exact.
            if let byName = apps.first(where: { nameMatches($0) }) {
                app = byName
            } else {
                markUnavailable()
                return
            }
        } else if let byName = apps.first(where: { nameMatches($0) }) {
            app = byName
        } else {
            markUnavailable()
            return
        }
        // B-09: a successful re-resolution clears the unavailable
        // latch — the game came back, so the page must not keep
        // showing "no longer available" for the rest of its life.
        appUnavailable = false
        requestContentRebuild()
    }

    /// A-24: the game (or its host) is gone — show the
    /// not-available state. B-08: in ALL cases, topmost included —
    /// the page never pops silently; the message view explains
    /// what happened and carries the Back affordance.
    private func markUnavailable() {
        if appUnavailable { requestContentRebuild(); return }
        appUnavailable = true
        requestContentRebuild()
    }

    // MARK: - Rendering

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared()
        let info = GPCatalog.info(for: app)
        let key = GPCatalog.appKey(host: host, app: app)

        // A-76: header follows the freshest app/host objects.
        headerTitleLabel?.text = app.name ?? "Game"
        headerSubtitleLabel?.text = info.detailLine ?? info.sourceTag

        if appUnavailable {
            let message = GPMessageView()
            message.configure(title: "This game is no longer available",
                              message: "It was removed from Sunshine or its PC is no longer known to GameParks.",
                              actionTitle: "Back")
            message.actionButton.addTarget(self, action: #selector(gpGoBack), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

        // Cover banner
        let banner = UIView()
        banner.backgroundColor = GPColor.panelRaised
        banner.layer.cornerRadius = 20
        banner.clipsToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.heightAnchor.constraint(equalToConstant: 190).isActive = true
        if let cover = GPCatalog.coverImage(for: app) {
            let imageView = UIImageView(image: cover)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            banner.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: banner.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            ])
        } else {
            let tile = gpLabel(app.name, font: GPFont.display(24, weight: .extrabold), color: GPColor.textPrimary, lines: 3)
            tile.textAlignment = .center
            tile.translatesAutoresizingMaskIntoConstraints = false
            banner.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
                tile.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 20),
                tile.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -20),
            ])
        }
        dynamicStack.addArrangedSubview(banner)

        // State-specific primary area
        if host.pairState != .paired {
            let message = GPMessageView()
            message.configure(title: "Pair with your PC first",
                              message: "This game lives on \(host.name ?? "your PC"), and this phone isn't paired with it yet. Pair once — one PIN — and you can play.",
                              actionTitle: "Go to the PC page")
            message.actionButton.addTarget(self, action: #selector(openHostPage), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
        } else if host.state != .online {
            let message = GPMessageView()
            message.configure(title: "This PC is offline",
                              message: "Wake it from its page, or check that it's on and Sunshine is running.",
                              actionTitle: "Go to the PC page")
            message.actionButton.addTarget(self, action: #selector(openHostPage), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
        } else {
            let running = session.runningApp(for: host)
            let playButton = gpPrimaryButton(isThisApp(running) ? "Resume on \(host.name ?? "your PC")" : "Play on \(host.name ?? "your PC")")
            playButton.addTarget(self, action: #selector(playTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(playButton)
            if let running = running, !isThisApp(running) {
                dynamicStack.addArrangedSubview(gpLabel("\(running.name ?? "Another game") is currently running on this PC — you'll get the choice to resume it or switch.",
                                                         font: GPFont.body(12), color: GPColor.textFaint, lines: 0))
            }
        }

        // Stats row. B-41: the height goes through the same label
        // mapping Stream settings uses — 2160 is "4K", not "2160p".
        let currentSettings = DataManager().getSettings()
        let settingsHeight = currentSettings?.height?.intValue ?? 1080
        let settingsFps = currentSettings?.framerate?.intValue ?? 60
        let streamSummary = "\(settingsHeight == 2160 ? "4K" : "\(settingsHeight)p")\(settingsFps)"
        let statsRow = UIStackView(arrangedSubviews: [
            statTile(title: "Played", value: gpFormatPlaytime(GPStats.shared.seconds(forAppKey: key))),
            statTile(title: "Last played", value: gpFormatLastPlayed(GPStats.shared.lastPlayed(forAppKey: key))),
            statTile(title: "Stream", value: streamSummary),
        ])
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        dynamicStack.addArrangedSubview(statsRow)

        // This game
        dynamicStack.addArrangedSubview(gpSectionHeader("This game"))
        let favouriteRow = GPSwitchRow()
        favouriteRow.titleLabel.text = "Favourite"
        favouriteRow.subtitle = "Show it under the Favourites filter in Library"
        favouriteRow.isOn = GPCatalog.isFavourite(host: host, app: app)
        favouriteRow.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            GPCatalog.setFavourite(isOn, host: self.host, app: self.app)
        }
        dynamicStack.addArrangedSubview(favouriteRow)

        let perGameRow = GPRow(showsChevron: false)
        perGameRow.titleLabel.text = "Per-game settings"
        perGameRow.subtitle = "One stream setup for every game"
        perGameRow.valueLabel.text = "Info"
        perGameRow.addTarget(self, action: #selector(perGameSettingsTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(perGameRow)

        let launchRow = GPRow(showsChevron: false)
        launchRow.titleLabel.text = "Launch options"
        launchRow.subtitle = "Games start from Sunshine as-is"
        launchRow.valueLabel.text = "Info"
        launchRow.addTarget(self, action: #selector(launchOptionsTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(launchRow)

        _ = info
    }

    private func statTile(title: String, value: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = GPColor.panel
        tile.layer.cornerRadius = 16
        let valueLabel = gpLabel(value, font: GPFont.display(16, weight: .bold), color: GPColor.textPrimary, lines: 1)
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7
        let stack = UIStackView(arrangedSubviews: [
            valueLabel,
            gpLabel(title, font: GPFont.body(11), color: GPColor.textSecondary, lines: 1),
        ])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
        ])
        return tile
    }

    // MARK: - Actions

    @objc private func playTapped(_ sender: UIButton) {
        let session = GPSessionController.shared()
        guard let running = session.runningApp(for: host) else {
            pushConnecting(app: app)
            return
        }
        if isThisApp(running) {
            pushConnecting(app: app)
            return
        }
        // Another game is running — upstream's menu, as a sheet.
        let sheet = UIAlertController(title: running.name,
                                      message: "\(running.name ?? "Another game") is currently running",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Resume \(running.name ?? "running game")", style: .default) { [weak self] _ in
            self?.pushConnecting(app: running)
        })
        sheet.addAction(UIAlertAction(title: "Quit and start \(app.name ?? "this game")", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            GPSessionController.shared().quitApp(running, on: self.host) { success in
                if success {
                    self.pushConnecting(app: self.app)
                } else {
                    self.presentAlert(title: "Quitting failed",
                                      message: "Failed to quit the running game. If it was started by another device, you'll need to quit it from that device.")
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // B-04: on iPad an action sheet MUST have a popover anchor
        // — presenting one without it raises and terminates the
        // app. Anchor it to the Play button that summoned it.
        sheet.popoverPresentationController?.sourceView = sender
        sheet.popoverPresentationController?.sourceRect = sender.bounds
        present(sheet, animated: true)
    }

    private func pushConnecting(app target: TemporaryApp) {
        navigationController?.pushViewController(GPConnectingViewController(host: host, app: target), animated: true)
    }

    @objc private func openHostPage() {
        // A-25: the PC page (and any Library route from it) must be
        // about THIS host.
        GPSessionController.shared().selectHost(host)
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func perGameSettingsTapped() {
        presentAlert(title: "Per-game settings",
                     message: "GameParks uses one stream setup for every game, so the picture behaves the same everywhere. Change it any time in Settings → Stream settings.")
    }

    @objc private func launchOptionsTapped() {
        presentAlert(title: "Launch options",
                     message: "\(app.name ?? "This game") starts exactly the way Sunshine launches it on the PC. Launch options live in Sunshine's app settings on the PC itself.")
    }
}
