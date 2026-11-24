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
    private let hostUUID: String
    private let appID: String
    private var host: TemporaryHost
    private var app: TemporaryApp
    private let dynamicStack = UIStackView()

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
        self.hostUUID = host.uuid ?? ""
        self.appID = app.id ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let info = GPCatalog.info(for: app)
        contentStack.addArrangedSubview(makeHeader(title: app.name ?? "Game",
                                                   subtitle: info.detailLine ?? info.sourceTag,
                                                   showsBack: true))
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)

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
        if let currentHost = GPSessionController.shared.hosts.first(where: { $0.uuid == hostUUID }) {
            host = currentHost
            if let currentApp = GPCatalog.sortedApps(for: currentHost).first(where: { $0.id == appID }) {
                app = currentApp
            }
        }
        rebuild()
    }

    // MARK: - Rendering

    private func rebuild() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared
        let info = GPCatalog.info(for: app)
        let key = GPCatalog.appKey(host: host, app: app)

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
            let playButton = gpPrimaryButton(running?.id == app.id ? "Resume on \(host.name ?? "your PC")" : "Play on \(host.name ?? "your PC")")
            playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
            dynamicStack.addArrangedSubview(playButton)
            if let running = running, running.id != app.id {
                dynamicStack.addArrangedSubview(gpLabel("\(running.name ?? "Another game") is currently running on this PC — you'll get the choice to resume it or switch.",
                                                         font: GPFont.body(12), color: GPColor.textFaint, lines: 0))
            }
        }

        // Stats row
        let settings = DataManager().getSettings()
        let streamSummary = settings != nil
            ? "\(settings!.height?.intValue ?? 1080)p\(settings!.framerate?.intValue ?? 60)"
            : "1080p60"
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
        favouriteRow.subtitle = "Keep it one tap away in Library"
        favouriteRow.isOn = GPCatalog.isFavourite(host: host, app: app)
        favouriteRow.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            GPCatalog.setFavourite(isOn, host: self.host, app: self.app)
        }
        dynamicStack.addArrangedSubview(favouriteRow)

        let perGameRow = GPRow()
        perGameRow.titleLabel.text = "Per-game settings"
        perGameRow.subtitle = "Resolution & bitrate just for this title"
        perGameRow.valueLabel.text = "Info"
        perGameRow.addTarget(self, action: #selector(perGameSettingsTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(perGameRow)

        let launchRow = GPRow()
        launchRow.titleLabel.text = "Launch options"
        launchRow.subtitle = "Start fullscreen · skip intro videos"
        launchRow.valueLabel.text = "Info"
        launchRow.addTarget(self, action: #selector(launchOptionsTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(launchRow)

        _ = info
    }

    private func statTile(title: String, value: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = GPColor.panel
        tile.layer.cornerRadius = 16
        let stack = UIStackView(arrangedSubviews: [
            gpLabel(value, font: GPFont.display(16, weight: .bold), color: GPColor.textPrimary, lines: 1),
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

    @objc private func playTapped() {
        let session = GPSessionController.shared
        guard let running = session.runningApp(for: host) else {
            pushConnecting(app: app)
            return
        }
        if running.id == app.id {
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
            GPSessionController.shared.quitApp(running, onHost: self.host) { success in
                if success {
                    self.pushConnecting(app: self.app)
                } else {
                    self.presentAlert(title: "Quitting failed",
                                      message: "Failed to quit the running game. If it was started by another device, you'll need to quit it from that device.")
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func pushConnecting(app target: TemporaryApp) {
        navigationController?.pushViewController(GPConnectingViewController(host: host, app: target), animated: true)
    }

    @objc private func openHostPage() {
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
