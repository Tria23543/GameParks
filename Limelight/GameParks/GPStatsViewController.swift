//
//  GPStatsViewController.swift
//  GameParks
//
//  The design's Stats screen, fed entirely by GPStats' on-device
//  session records and the session controller's measured ping.
//

import UIKit

final class GPStatsViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private let dynamicStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(title: "Stats",
                                                   subtitle: "Your play, counted automatically"))
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)
        rebuildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // B-17 (A-31 residual): appearance goes through the
        // scroll-safe path like the other tab roots.
        requestContentRebuild()
    }

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stats = GPStats.shared
        let session = GPSessionController.shared()

        if stats.sessionCount == 0 {
            let message = GPMessageView()
            message.configure(title: "No sessions yet",
                              message: "Play something and this page fills itself in — playtime, sessions and data are counted on this phone as you play.",
                              actionTitle: nil)
            dynamicStack.addArrangedSubview(message)
        }

        // Tiles — A-47: the home ping is the selected (or first)
        // host's own measured ping, not an average across hosts.
        let homeHost = session.selectedHost ?? session.hosts.first
        let homePingMs = homeHost != nil ? session.lastPingMs(for: homeHost!) : -1
        let homePing = homePingMs >= 0 ? "\(homePingMs) ms" : "—"
        let dataText = stats.totalStreamedGB >= 10
            ? String(format: "%.0f GB", stats.totalStreamedGB)
            : String(format: "%.1f GB", stats.totalStreamedGB)

        let row1 = UIStackView(arrangedSubviews: [
            tile(value: gpFormatPlaytime(stats.totalSeconds), title: "Total playtime"),
            tile(value: "\(stats.sessionCount)", title: "Sessions"),
        ])
        let row2 = UIStackView(arrangedSubviews: [
            tile(value: dataText, title: "Est. streamed data"),
            tile(value: homePing, title: "Home ping"),
        ])
        for row in [row1, row2] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            dynamicStack.addArrangedSubview(row)
        }

        // Most played
        let mostPlayed = stats.mostPlayed()
        if !mostPlayed.isEmpty {
            dynamicStack.addArrangedSubview(gpSectionHeader("Most played"))
            for entry in mostPlayed {
                let row = GPRow(showsChevron: false)
                row.titleLabel.text = entry.name
                row.valueLabel.text = gpFormatPlaytime(entry.seconds)
                dynamicStack.addArrangedSubview(row)
            }
        }

        // This week
        let week = stats.thisWeek()
        dynamicStack.addArrangedSubview(gpSectionHeader("This week", subtitle: week.total == 1 ? "1 session" : "\(week.total) sessions"))
        dynamicStack.addArrangedSubview(weekChart(days: week.days))
    }

    private func tile(value: String, title: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = GPColor.panel
        tile.layer.cornerRadius = 16
        let stack = UIStackView(arrangedSubviews: [
            gpLabel(value, font: GPFont.display(22, weight: .extrabold), color: GPColor.textPrimary, lines: 1),
            gpLabel(title, font: GPFont.body(12), color: GPColor.textSecondary, lines: 1),
        ])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -14),
        ])
        return tile
    }

    private func weekChart(days: [Int]) -> UIView {
        let card = UIView()
        card.backgroundColor = GPColor.panel
        card.layer.cornerRadius = 16

        let maxCount = max(days.max() ?? 0, 1)
        let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let bars = UIStackView()
        bars.axis = .horizontal
        bars.distribution = .fillEqually
        bars.alignment = .bottom
        bars.spacing = 8

        for (index, count) in days.enumerated() {
            let column = UIStackView()
            column.axis = .vertical
            column.spacing = 6
            column.alignment = .center

            let barTrack = UIView()
            barTrack.translatesAutoresizingMaskIntoConstraints = false
            barTrack.heightAnchor.constraint(equalToConstant: 72).isActive = true
            let bar = UIView()
            bar.backgroundColor = count > 0 ? GPColor.accent : GPColor.panelRaised
            bar.layer.cornerRadius = 4
            bar.translatesAutoresizingMaskIntoConstraints = false
            barTrack.addSubview(bar)
            let fraction = CGFloat(count) / CGFloat(maxCount)
            NSLayoutConstraint.activate([
                bar.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
                bar.centerXAnchor.constraint(equalTo: barTrack.centerXAnchor),
                bar.widthAnchor.constraint(equalToConstant: 16),
                bar.heightAnchor.constraint(equalToConstant: max(6, 72 * fraction)),
            ])
            column.addArrangedSubview(barTrack)
            column.addArrangedSubview(gpLabel(dayNames[index], font: GPFont.body(11), color: GPColor.textSecondary, lines: 1))
            bars.addArrangedSubview(column)
        }

        bars.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bars)
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            bars.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            bars.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            bars.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }
}
