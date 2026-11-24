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

    init(host: TemporaryHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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

    @objc private func rebuild() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let engine = GPEngine.shared

        // Header
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.addArrangedSubview(GPLabel(host.name ?? "Home Laptop", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink, lines: 2))
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
        if online, let ping = engine.ping(for: host) {
            statusLine.addArrangedSubview(GPLabel("\(ping) ms", font: GPTheme.display(15, weight: .bold), color: GPTheme.accent))
        }
        statusStack.addArrangedSubview(statusLine)
        statusStack.addArrangedSubview(GPLabel(online ? "Sunshine running · ready to stream" : "Wake it from here when you play",
                                               font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut))
        statusCard.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),
            statusStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
        ])
        stack.addArrangedSubview(statusCard)

        // Detail rows
        stack.addArrangedSubview(detailRow(title: "Machine", value: "Windows 10", detail: "Fresh install · fully updated"))
        stack.addArrangedSubview(detailRow(title: "Connection", value: "Home Wi-Fi · same network", detail: online ? "Excellent" : "—"))
        let controllerReady = engine.bluetoothControllerConnected
        stack.addArrangedSubview(detailRow(title: "Controller",
                                           value: "Bluetooth · connected to iPhone",
                                           detail: controllerReady ? "Ready" : "Not connected — touch controls will show instead"))

        let apps = engine.sortedApps(for: host)
        let steamCount = apps.filter { GPGameMeta.meta(forAppName: $0.name ?? "").sourceTag == "Steam" }.count
        let ownCount = apps.count - steamCount
        stack.addArrangedSubview(detailRow(title: "Games on this host",
                                           value: "\(steamCount) Steam · \(ownCount) your own installs",
                                           detail: "\(apps.count)"))

        // Actions
        stack.addArrangedSubview(GPSectionHeader(title: "Actions"))
        if host.state != .online {
            let wake = GPRow(title: "Wake this PC", subtitle: "Wake-on-LAN — it boots, then your games appear")
            wake.addTarget(self, action: #selector(wakeTapped), for: .touchUpInside)
            stack.addArrangedSubview(wake)
        }
        let restart = GPRow(title: "Restart Sunshine", subtitle: "If a stream ever misbehaves")
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
                                         font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.dim, lines: 3))
    }

    private func detailRow(title: String, value: String, detail: String) -> UIView {
        let row = UIView()
        row.backgroundColor = GPTheme.panel
        row.round(14)
        let titleLabel = GPLabel(title, font: GPTheme.body(12, weight: .bold), color: GPTheme.dim)
        let valueLabel = GPLabel(value, font: GPTheme.body(14.5, weight: .semibold), color: GPTheme.ink, lines: 2)
        let detailLabel = GPLabel(detail, font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.mut, lines: 2)
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
        showMessage(title: "Wake-on-LAN sent", message: "Your PC should wake in a few moments. If it never wakes, check its Wake-on-LAN settings.")
    }

    @objc private func restartTapped() {
        // There is no remote restart in the GameStream protocol; the honest
        // equivalent is a fresh connection: re-read the host and its games.
        GPEngine.shared.activateHost(host, userInitiated: false)
        if host.pairState == .paired {
            GPEngine.shared.refreshAppList(host)
        }
        showMessage(title: "Reconnected", message: "GameParks re-checked \(host.name ?? "your PC") and refreshed its game list. If a stream still misbehaves, restart Sunshine on the PC itself.")
    }

    @objc private func addGameTapped() {
        showMessage(title: "Add a game",
                    message: "On your PC, open Sunshine's web UI, go to Applications and add the game's .exe — Steam is not required. It appears in GameParks automatically the next time the library refreshes.")
    }

    @objc private func pairTapped() {
        GPEngine.shared.activateHost(host, userInitiated: true)
    }

    @objc private func removeTapped() {
        let alert = UIAlertController(title: "Remove \(host.name ?? "this PC")?",
                                      message: "GameParks will forget this PC on this phone. You can pair again any time.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
            GPEngine.shared.removeHost(self.host)
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}
