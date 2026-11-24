//
//  GPHostViewController.swift
//  GameParks
//
//  The design's host screen: status at a glance, the facts rows,
//  and the actions — pair, wake, reconnect, add-a-game guidance,
//  remove. All loading for this screen happens here, after the
//  push that brought the user to it.
//

import UIKit
import GameController

final class GPHostViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private let hostUUID: String
    private var host: TemporaryHost
    private let dynamicStack = UIStackView()

    init(host: TemporaryHost) {
        self.host = host
        self.hostUUID = host.uuid ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(title: host.name ?? "Your PC",
                                                   subtitle: "Your host", showsBack: true))
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPAppListChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hostInfoError(_:)),
                                               name: .GPHostInfoError, object: nil)
        rebuildContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Entering the PC page is the natural refresh point — the
        // same work upstream does when a host is tapped, done here
        // on the destination screen instead of blocking the tap.
        GPSessionController.shared().activateHost(host, userInitiated: false, skipFastPath: false)
    }

    @objc private func stateChanged() {
        if let current = GPSessionController.shared().hosts.first(where: { $0.uuid == hostUUID }) {
            host = current
        }
        requestContentRebuild()
    }

    @objc private func hostInfoError(_ note: Notification) {
        guard navigationController?.topViewController === self,
              let errorHost = note.object as? TemporaryHost, errorHost.uuid == hostUUID,
              let message = note.userInfo?[GPHostInfoErrorMessageKey] as? String else {
            return
        }
        presentAlert(title: "Connection failed", message: message)
    }

    // MARK: - Rendering

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let session = GPSessionController.shared()

        // Status card
        let statusCard = GPCardButton()
        statusCard.isUserInteractionEnabled = false
        let statusLine: String
        let detailLine: String
        switch host.state {
        case .online:
            statusLine = "Online"
            detailLine = host.pairState == .paired
                ? "Sunshine running · ready to stream"
                : "Online · not paired yet"
        case .offline:
            statusLine = "Offline"
            detailLine = "Not answering right now"
        default:
            statusLine = "Connecting…"
            detailLine = "Checking this PC"
        }
        statusCard.stack.addArrangedSubview(gpLabel(statusLine, font: GPFont.display(20, weight: .extrabold), color: GPColor.textPrimary, lines: 1))
        statusCard.stack.addArrangedSubview(gpLabel(detailLine, font: GPFont.body(13), color: GPColor.textSecondary, lines: 1))
        if host.state == .online, session.lastPingMs(for: host) >= 0 {
            statusCard.stack.addArrangedSubview(gpLabel("\(session.lastPingMs(for: host)) ms", font: GPFont.body(12, weight: .semibold), color: GPColor.accent, lines: 1))
        }
        dynamicStack.addArrangedSubview(statusCard)

        // Primary action for the current state
        if host.state == .online && host.pairState != .paired {
            let pairButton = gpPrimaryButton("Pair with PIN")
            pairButton.addTarget(self, action: #selector(pairTapped), for: .touchUpInside)
            dynamicStack.addArrangedSubview(pairButton)
        }
        if host.state != .online {
            if host.mac != nil && host.mac != "00:00:00:00:00:00" {
                let wakeButton = gpPrimaryButton("Wake PC")
                wakeButton.addTarget(self, action: #selector(wakeTapped), for: .touchUpInside)
                dynamicStack.addArrangedSubview(wakeButton)
                dynamicStack.addArrangedSubview(gpLabel("It may take a few moments for the PC to wake.",
                                                         font: GPFont.body(12), color: GPColor.textFaint, lines: 0))
            } else {
                let note = GPMessageView()
                note.configure(title: "Wake isn't available",
                               message: "This PC never reported its network (MAC) address, so a wake-up packet can't be addressed to it. It will appear here by itself when it's on.",
                               actionTitle: nil)
                dynamicStack.addArrangedSubview(note)
            }
        }

        // Facts
        dynamicStack.addArrangedSubview(gpSectionHeader("This PC"))
        let serverRow = GPRow(showsChevron: false)
        serverRow.titleLabel.text = "Server software"
        serverRow.valueLabel.text = host.isNvidiaServerSoftware ? "GeForce Experience" : "Sunshine"
        dynamicStack.addArrangedSubview(serverRow)

        let connectionRow = GPRow(showsChevron: false)
        connectionRow.titleLabel.text = "Connection"
        connectionRow.subtitle = "Home Wi-Fi · same network"
        connectionRow.valueLabel.text = session.lastPingMs(for: host) >= 0
            ? "\(session.lastPingMs(for: host)) ms" : "—"
        dynamicStack.addArrangedSubview(connectionRow)

        let controllerRow = GPRow(showsChevron: false)
        controllerRow.titleLabel.text = "Controller"
        let controllerConnected = !GCController.controllers().isEmpty
        controllerRow.subtitle = controllerConnected ? "Bluetooth · connected to iPhone" : "Connect a Bluetooth controller to play"
        controllerRow.valueLabel.text = controllerConnected ? "Ready" : "Not connected"
        dynamicStack.addArrangedSubview(controllerRow)

        let apps = GPCatalog.sortedApps(for: host)
        let gamesRow = GPRow()
        gamesRow.titleLabel.text = "Games on this host"
        gamesRow.valueLabel.text = "\(apps.count)"
        gamesRow.addTarget(self, action: #selector(gamesRowTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(gamesRow)

        // Actions
        dynamicStack.addArrangedSubview(gpSectionHeader("Actions"))
        let reconnectRow = GPRow()
        reconnectRow.titleLabel.text = "Reconnect to Sunshine"
        reconnectRow.subtitle = "If a stream ever misbehaves"
        reconnectRow.addTarget(self, action: #selector(reconnectTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(reconnectRow)

        let addGameRow = GPRow()
        addGameRow.titleLabel.text = "Add a game"
        addGameRow.subtitle = "Point at any .exe — Steam not required"
        addGameRow.addTarget(self, action: #selector(addGameTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(addGameRow)

        let removeRow = GPRow()
        removeRow.titleLabel.text = "Remove this PC"
        removeRow.subtitle = "Forget this PC on this phone"
        removeRow.titleLabel.textColor = GPColor.danger
        removeRow.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(removeRow)

        // Games
        if host.pairState == .paired {
            if apps.isEmpty {
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
            } else {
                dynamicStack.addArrangedSubview(gpSectionHeader("Games on this host"))
                for app in apps {
                    let row = GPAppRow()
                    row.configure(name: app.name ?? "",
                                  subtitle: GPCatalog.info(for: app).sourceTag,
                                  cover: GPCatalog.coverImage(for: app))
                    row.accessibilityIdentifier = GPCatalog.appKey(host: host, app: app)
                    row.addTarget(self, action: #selector(appRowTapped(_:)), for: .touchUpInside)
                    dynamicStack.addArrangedSubview(row)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func pairTapped() {
        GPSessionController.shared().selectHost(host)
        present(GPPairingViewController(host: host), animated: true)
    }

    @objc private func wakeTapped() {
        GPSessionController.shared().wakeHost(host)
        presentAlert(title: "Wake-up sent",
                     message: "A wake-up packet was sent to \(host.name ?? "your PC"). Give it a few moments, then this page updates by itself when the PC answers.")
    }

    @objc private func reconnectTapped() {
        GPSessionController.shared().activateHost(host, userInitiated: true, skipFastPath: true)
    }

    @objc private func addGameTapped() {
        presentAlert(title: "Add a game",
                     message: "Games are added on the PC, in Sunshine: open the Sunshine web UI, go to Applications, and add any .exe — Steam is not required. It appears here and in your library automatically.")
    }

    @objc private func removeTapped() {
        let alert = UIAlertController(title: "Remove this PC?",
                                      message: "\(host.name ?? "This PC") will be forgotten on this phone, including its pairing. You can add it again any time.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            GPSessionController.shared().removeHost(self.host)
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func gamesRowTapped() {
        // The tab bar is the navigation stack's root, not an
        // ancestor of this pushed screen — reach it through the stack.
        if let tabBar = navigationController?.viewControllers.first as? GPTabBarController {
            navigationController?.popToRootViewController(animated: false)
            tabBar.selectedIndex = 1
        }
    }

    @objc private func appRowTapped(_ sender: GPAppRow) {
        guard let key = sender.accessibilityIdentifier,
              let app = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.appKey(host: host, app: $0) == key })
        else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func retryAppList() {
        GPSessionController.shared().fetchAppList(for: host)
    }
}
