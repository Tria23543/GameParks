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
    private let hostName: String
    private var host: TemporaryHost
    private let dynamicStack = UIStackView()
    /// A-76: header labels, refreshed in rebuildContent.
    private var headerTitleLabel: UILabel?
    private var headerSubtitleLabel: UILabel?
    /// A-24: set once re-resolution has failed; the page then shows
    /// a not-available state instead of stale content.
    private var hostUnavailable = false
    /// A-79: Reconnect feedback, cleared on the next state change.
    private var reconnectInProgress = false

    init(host: TemporaryHost) {
        self.host = host
        self.hostUUID = host.uuid ?? ""
        self.hostName = host.name ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let header = makeHeader(title: host.name ?? "Your PC",
                                subtitle: "Your host", showsBack: true)
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
        NotificationCenter.default.addObserver(self, selector: #selector(hostInfoError(_:)),
                                               name: .GPHostInfoError, object: nil)
        // A-80: keep the controller row honest while on this page.
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged),
                                               name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged),
                                               name: .GCControllerDidDisconnect, object: nil)
        rebuildContent()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func controllerChanged() {
        requestContentRebuild()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Entering the PC page is the natural refresh point — the
        // same work upstream does when a host is tapped, done here
        // on the destination screen instead of blocking the tap.
        GPSessionController.shared().activateHost(host, userInitiated: false, skipFastPath: false)
    }

    @objc private func stateChanged() {
        reconnectInProgress = false
        // A-77: a nil/empty UUID is unmatchable by UUID — fall back
        // to the host's name rather than never matching.
        let hosts = GPSessionController.shared().hosts
        if let current = hosts.first(where: { $0.uuid == hostUUID && !hostUUID.isEmpty })
            ?? (hostUUID.isEmpty ? hosts.first(where: { $0.name == hostName }) : nil) {
            host = current
            // B-09: a successful re-resolution clears the
            // unavailable latch — if the PC came back, the page
            // must not keep showing "no longer available" for the
            // rest of its life.
            hostUnavailable = false
        } else if !hostUnavailable {
            // A-24: the host is gone. Pop if this page is topmost;
            // otherwise show a not-available state (rebuildContent).
            hostUnavailable = true
            if navigationController?.topViewController === self {
                navigationController?.popViewController(animated: true)
                return
            }
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

        // A-76: header follows the freshest host object.
        headerTitleLabel?.text = (host.name as String?) ?? "Your PC"

        if hostUnavailable {
            let message = GPMessageView()
            message.configure(title: "This PC is no longer available",
                              message: "It was removed or is no longer known to GameParks.",
                              actionTitle: "Back")
            message.actionButton.addTarget(self, action: #selector(gpGoBack), for: .touchUpInside)
            dynamicStack.addArrangedSubview(message)
            return
        }

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
        statusCard.stack.addArrangedSubview(gpLabel(statusLine, font: GPFont.display(20, weight: .extrabold), color: GPColor.textPrimary, lines: 2))
        statusCard.stack.addArrangedSubview(gpLabel(detailLine, font: GPFont.body(13), color: GPColor.textSecondary, lines: 2))
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
        // A-79: Wake is offered only when the PC is actually offline
        // — not while it is mid-handshake ("Connecting…").
        if host.state == .offline {
            if host.mac != nil && host.mac != "00:00:00:00:00:00" {
                let wakeButton = gpPrimaryButton("Wake PC")
                wakeButton.addTarget(self, action: #selector(wakeTapped), for: .touchUpInside)
                dynamicStack.addArrangedSubview(wakeButton)
                dynamicStack.addArrangedSubview(gpLabel("It may take a few moments for the PC to wake.",
                                                         font: GPFont.body(12), color: GPColor.textFaint, lines: 0))
            } else {
                let note = GPMessageView()
                note.configure(title: "Wake isn't available",
                               message: "This PC never reported its MAC address, so a wake-up packet can't be addressed to it. It will appear here by itself when it's on.",
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
        // A-48: claim "same network" only when the address in use is
        // the host's local address; otherwise stay neutral. The
        // no-address fall-through is state-aware (v2.6, completing
        // A-48): it used to print "Online · Sunshine ready" even
        // for an offline host, directly under an Offline status
        // card.
        if let active = host.activeAddress, let local = host.localAddress, active == local {
            connectionRow.subtitle = "Home Wi-Fi · same network"
        } else if host.activeAddress != nil {
            connectionRow.subtitle = "Remote connection"
        } else if host.state == .online {
            connectionRow.subtitle = "Online · Sunshine ready"
        } else if host.state == .offline {
            connectionRow.subtitle = "Offline"
        } else {
            connectionRow.subtitle = "Checking this PC"
        }
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
        // B-40: this row links to the Library — retitle it so the
        // page doesn't carry two "Games on this host" headings
        // (the games section below keeps that title), and count
        // the way Library counts: games only, not Desktop.
        gamesRow.titleLabel.text = "View in Library"
        gamesRow.valueLabel.text = "\(apps.filter { !GPCatalog.isDesktop($0) }.count)"
        gamesRow.addTarget(self, action: #selector(gamesRowTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(gamesRow)

        // Actions
        dynamicStack.addArrangedSubview(gpSectionHeader("Actions"))
        let reconnectRow = GPRow()
        reconnectRow.titleLabel.text = "Reconnect to Sunshine"
        reconnectRow.subtitle = "If a stream ever misbehaves"
        if reconnectInProgress {
            reconnectRow.valueLabel.text = "Reconnecting…"
            reconnectRow.isEnabled = false
        }
        reconnectRow.addTarget(self, action: #selector(reconnectTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(reconnectRow)

        let addGameRow = GPRow(showsChevron: false)
        addGameRow.titleLabel.text = "Add a game"
        addGameRow.subtitle = "Games are added on the PC, in Sunshine"
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
                    row.appKey = GPCatalog.appKey(host: host, app: app)
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
                     message: "A wake-up packet was sent to \((host.name as String?) ?? "your PC"). Give it a few moments, then this page updates by itself when the PC answers.")
    }

    @objc private func reconnectTapped() {
        // A-79: visible in-progress feedback until the next
        // stateChanged rebuild clears it.
        reconnectInProgress = true
        requestContentRebuild()
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
        // A-25: show THIS host's games — select it first.
        GPSessionController.shared().selectHost(host)
        // The tab bar is the navigation stack's root, not an
        // ancestor of this pushed screen — reach it through the stack.
        if let tabBar = navigationController?.viewControllers.first as? GPTabBarController {
            navigationController?.popToRootViewController(animated: false)
            tabBar.selectedIndex = 1
        }
    }

    @objc private func appRowTapped(_ sender: GPAppRow) {
        guard let key = sender.appKey,
              let app = GPCatalog.sortedApps(for: host).first(where: { GPCatalog.appKey(host: host, app: $0) == key })
        else { return }
        navigationController?.pushViewController(GPGameViewController(host: host, app: app), animated: true)
    }

    @objc private func retryAppList() {
        GPSessionController.shared().fetchAppList(for: host)
    }
}
