//
//  GPHostViewController.swift
//  GameParks
//
//  The host screen from the approved design: your PC's health at a
//  glance — online, ping, controller, Sunshine — plus its actions.
//

import UIKit

final class GPHostViewController: GPBaseViewController {
    private let host: TemporaryHost
    private let stack = UIStackView()
    private weak var statusPingLabel: UILabel?
    private weak var connectionDetailLabel: UILabel?
    private var lastBuildSignature: String?

    init(host: TemporaryHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = UIScrollView()
        scrollView.delaysContentTouches = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .gpHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .gpAppListChanged, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    private func buildSignature() -> String {
        let engine = GPEngine.shared
        let apps = engine.sortedApps(for: host).map { $0.id ?? $0.name ?? "?" }.joined(separator: ",")
        return [host.uuid, "\(host.state.rawValue)", "\(host.pairState.rawValue)", host.name,
                "\(engine.bluetoothControllerConnected)", apps].joined(separator: "|")
    }

    @objc private func rebuild() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
            return
        }
        guard isViewLoaded else { return }
        // Same two-tier rule as Home: rebuild only on a genuine
        // change; a ping-only change updates its two labels in place
        // (tearing down this screen mid-tap ate touches in v1.1).
        let signature = buildSignature()
        if signature == lastBuildSignature {
            refreshPingLabels()
            return
        }
        lastBuildSignature = signature
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let engine = GPEngine.shared

        // Header
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.addArrangedSubview(GPLabel(host.name, font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink, lines: 2))
        header.addArrangedSubview(GPLabel("Your host", font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut))
        stack.addArrangedSubview(header)

        // Status card
        let online = host.state == .online
        let statusCard = UIView()
        statusCard.backgroundColor = GPTheme.panel
        statusCard.round(16)
        let statusStack = UIStackView()
        statusStack.axis = .vertical
        statusStack.spacing = 4
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        let statusLine = UIStackView()
        statusLine.axis = .horizontal
        statusLine.spacing = 8
        statusLine.alignment = .center
        let dot = UIView()
        dot.backgroundColor = online ? GPTheme.live : GPTheme.dim
        dot.round(5)
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLine.addArrangedSubview(dot)
        statusLine.addArrangedSubview(GPLabel(online ? "Online" : (host.state == .offline ? "Asleep" : "Searching…"),
                                              font: GPTheme.display(16, weight: .bold), color: GPTheme.ink))
        let pingLabel = GPLabel("", font: GPTheme.display(15, weight: .bold), color: GPTheme.accent)
        statusLine.addArrangedSubview(pingLabel)
        statusPingLabel = pingLabel
        statusStack.addArrangedSubview(statusLine)
        let statusSubtitle: String
        switch host.state {
        case .online:
            statusSubtitle = "Sunshine running · ready to stream"
        case .offline:
            statusSubtitle = "Tap Wake below when you want to play"
        default:
            statusSubtitle = "Still looking for this PC on your network"
        }
        statusStack.addArrangedSubview(GPLabel(statusSubtitle,
                                               font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut, lines: 0))
        statusCard.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
        ])
        stack.addArrangedSubview(statusCard)

        // Detail rows
        stack.addArrangedSubview(detailRow(title: "Machine", value: "Sunshine host", detail: "Streams your games to this phone"))
        stack.addArrangedSubview(detailRow(title: "Connection", value: "Home Wi-Fi · same network", detail: connectionDetailText(),
                                           onDetailLabel: { [weak self] label in self?.connectionDetailLabel = label }))
        let controllerReady = engine.bluetoothControllerConnected
        stack.addArrangedSubview(detailRow(title: "Controller",
                                           value: controllerReady ? "Bluetooth · connected to iPhone" : "Bluetooth · not connected",
                                           detail: controllerReady ? "Ready" : "Touch controls will show instead"))

        let apps = engine.sortedApps(for: host)
        let steamCount = apps.filter { GPGameMeta.meta(forAppName: $0.name ?? "").sourceTag == "Steam" }.count
        let ownCount = apps.count - steamCount
        stack.addArrangedSubview(detailRow(title: "Games on this host",
                                           value: apps.count == 1 ? "1 game" : "\(apps.count) games",
                                           detail: "\(steamCount) Steam · \(ownCount) your own \(ownCount == 1 ? "install" : "installs")"))

        // Actions
        stack.addArrangedSubview(GPSectionHeader(title: "Actions"))
        if host.state != .online {
            let wake = GPRow(title: "Wake this PC", subtitle: "Wake-on-LAN — it boots, then your games appear")
            wake.addTarget(self, action: #selector(wakeTapped), for: .touchUpInside)
            stack.addArrangedSubview(wake)
        }
        let restart = GPRow(title: "Reconnect to Sunshine", subtitle: "If a stream ever misbehaves — refreshes the connection")
        restart.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        stack.addArrangedSubview(restart)

        let addGame = GPRow(title: "Add a game", subtitle: "Point at any .exe — Steam not required")
        addGame.addTarget(self, action: #selector(addGameTapped), for: .touchUpInside)
        stack.addArrangedSubview(addGame)

        if host.pairState != .paired {
            let pair = GPRow(title: "Pair this device", subtitle: "One PIN, entered once")
            pair.addTarget(self, action: #selector(pairTapped), for: .touchUpInside)
            stack.addArrangedSubview(pair)
        } else {
            let pairNew = GPRow(title: "Pair a new device", subtitle: "One PIN, entered once")
            pairNew.addTarget(self, action: #selector(pairTapped), for: .touchUpInside)
            stack.addArrangedSubview(pairNew)
        }

        let remove = GPRow(title: "Remove this PC", subtitle: "Forget this host on this phone")
        remove.titleLabel.textColor = GPTheme.danger
        remove.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        stack.addArrangedSubview(remove)

        stack.addArrangedSubview(GPLabel("When a cloud PC joins later, it appears as a second host right here — same library, same posters, same settings.",
                                         font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.dim, lines: 0))

        refreshPingLabels()
    }

    /// The ping-dependent texts, refreshed without a rebuild.
    private func refreshPingLabels() {
        let engine = GPEngine.shared
        if host.state == .online, let ping = engine.ping(for: host) {
            statusPingLabel?.text = "\(ping) ms"
        } else {
            statusPingLabel?.text = ""
        }
        connectionDetailLabel?.text = connectionDetailText()
    }

    private func connectionDetailText() -> String {
        if host.state == .online, let ping = GPEngine.shared.ping(for: host) {
            // Grade the word — it used to say "Excellent" at any ping.
            let quality: String
            switch ping {
            case ..<30: quality = "Excellent"
            case ..<80: quality = "Good"
            case ..<150: quality = "Fair"
            default: quality = "Poor"
            }
            return "\(ping) ms · \(quality)"
        }
        return host.state == .online ? "Online" : "Asleep"
    }

    private func detailRow(title: String, value: String, detail: String, onDetailLabel: ((UILabel) -> Void)? = nil) -> UIView {
        let row = UIView()
        row.backgroundColor = GPTheme.panel
        row.round(14)
        let titleLabel = GPLabel(title, font: GPTheme.body(12, weight: .bold), color: GPTheme.dim)
        let valueLabel = GPLabel(value, font: GPTheme.body(14.5, weight: .semibold), color: GPTheme.ink, lines: 2)
        let detailLabel = GPLabel(detail, font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.mut, lines: 2)
        onDetailLabel?(detailLabel)
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    // MARK: - Actions

    @objc private func wakeTapped() {
        GPEngine.shared.wake(host)
        showMessage(title: "Wake request sent", message: "Your PC should wake in a few moments. If it never wakes, check its Wake-on-LAN settings.")
    }

    @objc private func restartTapped() {
        // There is no remote restart in the GameStream protocol; the honest
        // equivalent is a fresh connection: re-read the host and its games.
        // The message says what was actually asked for — it used to claim
        // success (and a refreshed list) before anything had happened.
        GPEngine.shared.activateHost(host, userInitiated: false)
        if host.pairState == .paired {
            GPEngine.shared.refreshAppList(host)
            showMessage(title: "Reconnecting", message: "GameParks is re-checking \(host.name) and refreshing its game list. If a stream still misbehaves, restart Sunshine on the PC itself.")
        } else {
            showMessage(title: "Reconnecting", message: "GameParks is re-checking \(host.name). If a stream still misbehaves, restart Sunshine on the PC itself.")
        }
    }

    @objc private func addGameTapped() {
        showMessage(title: "Add a game",
                    message: "On your PC, open Sunshine's web UI, go to Applications and add the game's .exe — Steam is not required. It appears in GameParks automatically the next time the library refreshes.")
    }

    @objc private func pairTapped() {
        if host.pairState == .paired {
            showMessage(title: "Pair a new device",
                        message: "New devices pair from the new device itself: open GameParks there, tap this PC, and enter the PIN GameParks shows there into the Sunshine web UI on this PC.")
            return
        }
        GPEngine.shared.activateHost(host, userInitiated: true)
    }

    @objc private func removeTapped() {
        let alert = UIAlertController(title: "Remove \(host.name)?",
                                      message: "GameParks will forget this PC on this phone. You can pair again any time.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            GPEngine.shared.removeHost(self.host)
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}
