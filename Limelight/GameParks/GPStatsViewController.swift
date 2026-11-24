//
//  GPStatsViewController.swift
//  GameParks
//
//  Stats in the approved design — your play, counted automatically:
//  total playtime, sessions, streamed data, average home ping,
//  most-played games and this week's sessions.
//

import UIKit

final class GPStatsViewController: GPBaseViewController {
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 20, bottom: 28, right: 20)
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    @objc private func rebuild() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stats = GPStats.shared
        let engine = GPEngine.shared

        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 3
        header.addArrangedSubview(GPLabel("Stats", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink))
        header.addArrangedSubview(GPLabel("Your play, counted automatically", font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut))
        stack.addArrangedSubview(header)

        // Tiles
        let pingText: String
        if let host = engine.selectedHost, let ping = engine.ping(for: host) {
            pingText = "\(ping) ms"
        } else {
            pingText = "—"
        }
        let dataText: String
        let dataMB = stats.totalDataMB()
        if dataMB >= 1000 {
            dataText = String(format: "%.1f GB", dataMB / 1000.0)
        } else {
            dataText = "\(Int(dataMB)) MB"
        }
        let tilesRow1 = UIStackView(arrangedSubviews: [
            tile(value: GPFormatPlaytime(stats.totalPlaytime()), label: "Total playtime"),
            tile(value: "\(stats.totalSessions())", label: "Sessions"),
        ])
        let tilesRow2 = UIStackView(arrangedSubviews: [
            tile(value: dataText, label: "Streamed data"),
            tile(value: pingText, label: "Avg. home ping"),
        ])
        for row in [tilesRow1, tilesRow2] {
            row.axis = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually
            stack.addArrangedSubview(row)
        }

        // Most played
        stack.addArrangedSubview(GPSectionHeader(title: "Most played"))
        let ranked = stats.rankedPlaytime().prefix(5)
        if ranked.isEmpty {
            stack.addArrangedSubview(GPLabel("Nothing yet — your most-played games will appear here after your first sessions.",
                                             font: GPTheme.body(13.5, weight: .semibold), color: GPTheme.mut, lines: 3))
        } else {
            for entry in ranked {
                stack.addArrangedSubview(mostPlayedRow(appKey: entry.key, seconds: entry.seconds))
            }
        }

        // This week
        stack.addArrangedSubview(GPSectionHeader(title: "This week", subtitle: "\(stats.sessionsThisWeekCount()) sessions"))
        stack.addArrangedSubview(weekChart(counts: stats.sessionsThisWeek()))

        stack.addArrangedSubview(GPLabel("Counted on this phone from your GameParks sessions — playtime, sessions and streamed data are recorded as you play.",
                                         font: GPTheme.body(12, weight: .semibold), color: GPTheme.dim, lines: 3))
    }

    private func tile(value: String, label: String) -> UIView {
        let card = UIView()
        card.backgroundColor = GPTheme.panel
        card.round(16)
        let valueLabel = GPLabel(value, font: GPTheme.display(22, weight: .extrabold), color: GPTheme.ink)
        let labelLabel = GPLabel(label, font: GPTheme.body(12, weight: .semibold), color: GPTheme.mut)
        let stack = UIStackView(arrangedSubviews: [valueLabel, labelLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func mostPlayedRow(appKey: String, seconds: TimeInterval) -> UIView {
        // Resolve the app key (hostUUID/appId) back to a game name.
        var name = "Game"
        if let slash = appKey.lastIndex(of: "/") {
            let appId = String(appKey[appKey.index(after: slash)...])
            for host in GPEngine.shared.hosts {
                if let app = GPEngine.shared.sortedApps(for: host).first(where: { $0.id == appId }) {
                    name = app.name ?? name
                    break
                }
            }
        }
        let row = UIView()
        row.backgroundColor = GPTheme.panel
        row.round(14)
        let nameLabel = GPLabel(name, font: GPTheme.body(14.5, weight: .semibold), color: GPTheme.ink, lines: 2)
        let hoursLabel = GPLabel(GPFormatPlaytime(seconds), font: GPTheme.display(14, weight: .bold), color: GPTheme.accent)
        let inner = UIStackView(arrangedSubviews: [nameLabel, hoursLabel])
        inner.axis = .horizontal
        inner.alignment = .center
        inner.isLayoutMarginsRelativeArrangement = true
        inner.layoutMargins = UIEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        inner.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: row.topAnchor),
            inner.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private func weekChart(counts: [Int]) -> UIView {
        let card = UIView()
        card.backgroundColor = GPTheme.panel
        card.round(16)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let maxCount = max(counts.max() ?? 0, 1)
        let bars = UIStackView()
        bars.axis = .horizontal
        bars.distribution = .fillEqually
        bars.alignment = .bottom
        bars.spacing = 10
        for (index, count) in counts.enumerated() {
            let column = UIStackView()
            column.axis = .vertical
            column.spacing = 6
            column.alignment = .center
            let bar = UIView()
            bar.backgroundColor = count > 0 ? GPTheme.accent : GPTheme.panel2
            bar.round(4)
            let height = count > 0 ? max(10, CGFloat(count) / CGFloat(maxCount) * 54) : 6
            bar.widthAnchor.constraint(equalToConstant: 22).isActive = true
            bar.heightAnchor.constraint(equalToConstant: height).isActive = true
            column.addArrangedSubview(bar)
            column.addArrangedSubview(GPLabel(days[index], font: GPTheme.body(10.5, weight: .bold), color: GPTheme.dim))
            bars.addArrangedSubview(column)
        }
        bars.isLayoutMarginsRelativeArrangement = true
        bars.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        bars.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bars)
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: card.topAnchor),
            bars.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            bars.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }
}
