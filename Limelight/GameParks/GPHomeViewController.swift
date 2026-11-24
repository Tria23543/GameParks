//
//  GPHomeViewController.swift
//  GameParks
//
//  Home in the approved design: greeting, the host status card,
//  a Continue Playing hero, then poster rails —
//  "Jump back in" (Steam library) and "Your classics" (your own copies).
//

import UIKit

/// The host status card, factored out so a state-only change (online,
/// ping, pairing) can update its labels IN PLACE. Recreating the card
/// on every host-list notification destroyed in-flight touches — the
/// card is the screen's main tap target.
private final class GPHostCardView: UIControl {
    private let dot = UIView()
    private let titleLabel = GPLabel("", font: GPTheme.display(17, weight: .bold), color: GPTheme.ink)
    private let subtitleLabel = GPLabel("", font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.mut, lines: 2)
    private let trailingLabel = GPLabel("", font: GPTheme.display(15, weight: .bold), color: GPTheme.accent)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = GPTheme.panel
        round(18)

        dot.round(5)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [dot, textStack, trailingLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(name: String, subtitle: String, online: Bool, pingText: String) {
        titleLabel.text = name
        subtitleLabel.text = subtitle
        dot.backgroundColor = online ? GPTheme.live : GPTheme.dim
        trailingLabel.text = pingText
    }
}

/// A wide game row that carries its app with it, instead of smuggling
/// the app id through accessibilityIdentifier and re-resolving it
/// against a possibly-changed list at tap time.
private final class GPAppRow: GPRow {
    var app: TemporaryApp?
}

final class GPHomeViewController: GPBaseViewController {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var bigRail: UICollectionView!
    private var classicsRail: UICollectionView!
    private var bigApps: [TemporaryApp] = []
    private var classicApps: [TemporaryApp] = []
    private var heroApp: TemporaryApp?

    private weak var hostCard: GPHostCardView?
    private weak var emptyStateLabel: UILabel?
    private var lastStructureSignature: String?
    private var lastStateSignature: String?

    private enum RailTag {
        static let big = 1
        static let classics = 2
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Card/row taps must not wait for scroll-vs-tap disambiguation.
        scrollView.delaysContentTouches = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refreshPulled(_:)), for: .valueChanged)
        scrollView.refreshControl = refreshControl

        stack.axis = .vertical
        stack.spacing = 26
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        bigRail = makeRail(tag: RailTag.big)
        classicsRail = makeRail(tag: RailTag.classics)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .gpAppListChanged, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GPEngine.shared.scanLocalNetwork()
        reload()
    }

    @objc private func refreshPulled(_ sender: UIRefreshControl) {
        GPEngine.shared.scanLocalNetwork(force: true) {
            sender.endRefreshing()
        }
        // Belt and braces: the spinner must end even if a scan
        // completion is ever dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            sender.endRefreshing()
        }
    }

    private func makeRail(tag: Int) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        // Poster (118 × 1.42 ≈ 168) + 7 spacing + two title lines +
        // subtitle ≈ 222 — the old 208 clipped the second line.
        layout.itemSize = CGSize(width: 118, height: 224)
        layout.minimumLineSpacing = 14
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.tag = tag
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(GPPosterCell.self, forCellWithReuseIdentifier: GPPosterCell.reuseID)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.heightAnchor.constraint(equalToConstant: 224).isActive = true
        return collection
    }

    // MARK: - Building the screen

    /// Two-tier rebuild. The STRUCTURE (which host, which games, the
    /// greeting hour, the stats revision) changes rarely; when only
    /// the host's STATE changed (online, paired, ping), the card and
    /// the empty-state message update in place and nothing is torn
    /// down — a teardown mid-tap is what ate the user's taps in v1.1.
    @objc private func reload() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.reload() }
            return
        }
        guard isViewLoaded else { return }
        let engine = GPEngine.shared
        let host = engine.selectedHost
        let apps = host.map { engine.sortedApps(for: $0) } ?? []
        let structure = structureSignature(host: host, apps: apps)
        let state = stateSignature(host: host)
        if structure == lastStructureSignature {
            if state != lastStateSignature {
                lastStateSignature = state
                updateHostCardInPlace(host: host)
            }
            return
        }
        lastStructureSignature = structure
        lastStateSignature = state
        rebuildContent(host: host, apps: apps)
    }

    private func structureSignature(host: TemporaryHost?, apps: [TemporaryApp]) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let appIds = apps.map { $0.id ?? $0.name ?? "?" }.joined(separator: ",")
        return "h:\(hour)|host:\(host?.uuid ?? "none")|apps:\(appIds)|stats:\(GPStats.shared.revision)"
    }

    private func stateSignature(host: TemporaryHost?) -> String {
        guard let host = host else { return "none" }
        let ping = GPEngine.shared.ping(for: host).map { "\($0)" } ?? "-"
        return "\(host.state.rawValue)/\(host.pairState.rawValue)/\(host.name)/\(ping)"
    }

    private func updateHostCardInPlace(host: TemporaryHost?) {
        hostCard?.update(name: host?.name ?? "No PC yet",
                         subtitle: hostStatusText(host),
                         online: host?.state == .online,
                         pingText: pingText(for: host))
        if let label = emptyStateLabel, let host = host {
            label.text = emptyAppsMessage(for: host)
        }
    }

    private func pingText(for host: TemporaryHost?) -> String {
        guard let host = host, host.state == .online, let ping = GPEngine.shared.ping(for: host) else {
            return ""
        }
        return "\(ping) ms"
    }

    private func rebuildContent(host: TemporaryHost?, apps: [TemporaryApp]) {
        // Preserve the scroll position across the rebuild: resetting
        // it to the top on every genuine change felt like the app
        // jumping around under the user's finger.
        let savedOffsetY = scrollView.contentOffset.y
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let engine = GPEngine.shared

        // Greeting
        let greetingStack = UIStackView()
        greetingStack.axis = .vertical
        greetingStack.spacing = 4
        greetingStack.addArrangedSubview(GPLabel(greetingText(), font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink))
        greetingStack.addArrangedSubview(GPLabel("Ready to play, Glenda?", font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut))
        stack.addArrangedSubview(greetingStack)

        // Host card
        stack.addArrangedSubview(makeHostCard(host: host))

        guard let host = host else {
            stack.addArrangedSubview(GPLabel("No PC found yet. Make sure Sunshine is running on your PC and both devices are on the same Wi-Fi. If your PC doesn't appear on its own, add it directly by its address:",
                                             font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut, lines: 0))
            let addButton = UIButton(type: .system)
            addButton.setTitle("Add your PC by address", for: .normal)
            addButton.setTitleColor(GPTheme.accentInk, for: .normal)
            addButton.titleLabel?.font = GPTheme.display(17, weight: .extrabold)
            addButton.backgroundColor = GPTheme.accent
            addButton.round(16)
            addButton.contentEdgeInsets = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            addButton.addTarget(self, action: #selector(addByAddressTapped), for: .touchUpInside)
            stack.addArrangedSubview(addButton)
            let searchButton = UIButton(type: .system)
            searchButton.setTitle("Search again", for: .normal)
            searchButton.setTitleColor(GPTheme.accent, for: .normal)
            searchButton.titleLabel?.font = GPTheme.body(15, weight: .bold)
            searchButton.addTarget(self, action: #selector(searchAgainTapped), for: .touchUpInside)
            stack.addArrangedSubview(searchButton)
            restoreScrollOffset(savedOffsetY)
            return
        }

        // One metadata pass, partitioned once — the old code re-ran
        // the lookup three times per app on every rebuild.
        let metas = apps.map { (app: $0, meta: GPGameMeta.meta(forAppName: $0.name ?? "")) }
        bigApps = metas.filter { $0.meta.group == .big }.map { $0.app }
        classicApps = metas.filter { $0.meta.group == .classic }.map { $0.app }
        let otherApps = metas.filter { $0.meta.group != .big && $0.meta.group != .classic }.map { $0.app }

        // Continue Playing hero: the most recently played game, else the first big game.
        heroApp = mostRecentApp(in: apps) ?? bigApps.first ?? apps.first
        if let hero = heroApp {
            stack.addArrangedSubview(makeHero(app: hero, host: host))
        }

        if !bigApps.isEmpty {
            stack.addArrangedSubview(makeSectionHeader(title: "Jump back in", trailing: "Steam library"))
            stack.addArrangedSubview(bigRail)
            bigRail.reloadData()
        }
        if !classicApps.isEmpty {
            stack.addArrangedSubview(makeSectionHeader(title: "Your classics", trailing: "Your own copies"))
            stack.addArrangedSubview(classicsRail)
            classicsRail.reloadData()
        }
        if !otherApps.isEmpty {
            stack.addArrangedSubview(makeSectionHeader(title: "More on \(host.name)", trailing: ""))
            for app in otherApps {
                stack.addArrangedSubview(makeWideRow(app: app, host: host))
            }
        }
        if apps.isEmpty {
            let message = GPLabel(emptyAppsMessage(for: host),
                                  font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut, lines: 0)
            emptyStateLabel = message
            stack.addArrangedSubview(message)
        }
        restoreScrollOffset(savedOffsetY)
    }

    private func restoreScrollOffset(_ y: CGFloat) {
        guard y > 0 else { return }
        view.layoutIfNeeded()
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        scrollView.contentOffset.y = min(y, maxY)
    }

    private func emptyAppsMessage(for host: TemporaryHost) -> String {
        if host.pairState != .paired {
            return "This PC is not paired yet. Tap the card above to pair — one PIN, entered once — and your games will appear here."
        } else if host.state != .online {
            return "Your PC is asleep or offline. Tap the card above to wake it, and your games will appear here."
        } else {
            return "No games found on this PC yet. Add your games in Sunshine on the PC — Steam titles and your own installs both appear here automatically."
        }
    }

    private func greetingText() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<23: return "Good evening"
        default: return "Up late?"
        }
    }

    private func mostRecentApp(in apps: [TemporaryApp]) -> TemporaryApp? {
        guard let host = GPEngine.shared.selectedHost else { return nil }
        var best: TemporaryApp?
        var bestDate = Date.distantPast
        for app in apps {
            let key = GPStats.appKey(host: host, app: app)
            if let date = GPStats.shared.lastPlayed(forAppKey: key), date > bestDate {
                bestDate = date
                best = app
            }
        }
        return best
    }

    private func makeSectionHeader(title: String, trailing: String) -> UIView {
        let container = UIView()
        let titleLabel = GPLabel(title, font: GPTheme.display(19, weight: .bold), color: GPTheme.ink)
        let trailingLabel = GPLabel(trailing, font: GPTheme.body(12, weight: .bold), color: GPTheme.dim)
        container.addSubview(titleLabel)
        container.addSubview(trailingLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -8),
            trailingLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            trailingLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        return container
    }

    private func makeHostCard(host: TemporaryHost?) -> UIView {
        let card = GPHostCardView()
        card.addTarget(self, action: #selector(hostCardTapped), for: .touchUpInside)
        card.update(name: host?.name ?? "No PC yet",
                    subtitle: hostStatusText(host),
                    online: host?.state == .online,
                    pingText: pingText(for: host))
        // With no PC there is nothing to open: the card is inert
        // rather than silently swallowing taps.
        card.isEnabled = host != nil
        hostCard = card
        return card
    }

    private func hostStatusText(_ host: TemporaryHost?) -> String {
        guard let host = host else {
            return "Searching for PCs on your network…"
        }
        switch host.state {
        case .online:
            if host.pairState == .paired {
                return "Online · Home Wi-Fi · Sunshine ready"
            }
            return "Online · Not paired — tap to pair"
        case .offline:
            return "Asleep · tap to wake"
        default:
            return "Searching…"
        }
    }

    private func makeHero(app: TemporaryApp, host: TemporaryHost) -> UIView {
        let hero = UIControl()
        hero.round(20)
        hero.backgroundColor = GPTheme.panel2
        hero.addTarget(self, action: #selector(heroTapped), for: .touchUpInside)

        let image = UIImageView()
        image.image = GPCoverArt.cover(for: app)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(image)

        let scrim = UIView()
        scrim.backgroundColor = UIColor(hex: 0x05060A, alpha: 0.45)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(scrim)

        let key = GPStats.appKey(host: host, app: app)
        let playtime = GPStats.shared.playtime(forAppKey: key)
        var metaParts: [String] = []
        if playtime > 0 {
            metaParts.append("\(GPFormatPlaytime(playtime)) played")
        }
        if let last = GPStats.shared.lastPlayed(forAppKey: key) {
            metaParts.append("Last played \(GPFormatLastPlayed(last))")
        }
        let meta = metaParts.isEmpty ? "Ready when you are" : metaParts.joined(separator: " · ")

        let kicker = GPLabel("Continue playing", font: GPTheme.body(11, weight: .extrabold), color: GPTheme.accent)
        kicker.text = kicker.text?.uppercased()
        let title = GPLabel(app.name ?? "", font: GPTheme.display(24, weight: .extrabold), color: .white, lines: 2)
        let metaLabel = GPLabel(meta, font: GPTheme.body(13, weight: .semibold), color: UIColor(hex: 0xD7DCEA), lines: 2)

        let playButton = GPPlayButton(title: "Play")
        playButton.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [kicker, title, metaLabel])
        textStack.axis = .vertical
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(textStack)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(playButton)

        NSLayoutConstraint.activate([
            hero.heightAnchor.constraint(equalTo: hero.widthAnchor, multiplier: 0.62),
            image.topAnchor.constraint(equalTo: hero.topAnchor),
            image.bottomAnchor.constraint(equalTo: hero.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: hero.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: hero.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            textStack.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 18),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor, constant: -18),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: hero.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: -12),
            playButton.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 18),
            playButton.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -16),
        ])
        return hero
    }

    private func makeWideRow(app: TemporaryApp, host: TemporaryHost) -> UIView {
        let row = GPAppRow(title: app.name ?? "", subtitle: GPGameMeta.meta(forAppName: app.name ?? "").genreLine)
        row.app = app
        row.addTarget(self, action: #selector(wideRowTapped(_:)), for: .touchUpInside)
        return row
    }

    // MARK: - Actions

    @objc private func addByAddressTapped() {
        presentAddByAddress()
    }

    @objc private func searchAgainTapped() {
        GPEngine.shared.scanLocalNetwork(force: true)
    }

    @objc private func hostCardTapped() {
        guard let host = GPEngine.shared.selectedHost else { return }
        if host.state == .offline {
            GPEngine.shared.wake(host)
        }
        let hostVC = GPHostViewController(host: host)
        navigationController?.pushViewController(hostVC, animated: true)
    }

    @objc private func heroTapped() {
        guard let app = heroApp else { return }
        openGame(app)
    }

    @objc private func wideRowTapped(_ sender: GPAppRow) {
        guard let app = sender.app else { return }
        openGame(app)
    }

    private func openGame(_ app: TemporaryApp) {
        let gameVC = GPGameViewController(app: app)
        navigationController?.pushViewController(gameVC, animated: true)
    }
}

// MARK: - Rails

extension GPHomeViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    private func railApps(for collectionView: UICollectionView) -> [TemporaryApp] {
        switch collectionView.tag {
        case RailTag.big:
            return bigApps
        case RailTag.classics:
            return classicApps
        default:
            return []
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return railApps(for: collectionView).count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let apps = railApps(for: collectionView)
        guard apps.indices.contains(indexPath.item),
              let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GPPosterCell.reuseID, for: indexPath) as? GPPosterCell else {
            // A notification can shrink the list between the count
            // query and cell creation; a blank cell beats a crash.
            return UICollectionViewCell()
        }
        let app = apps[indexPath.item]
        let meta = GPGameMeta.meta(forAppName: app.name ?? "")
        var subtitle: String
        if collectionView.tag == RailTag.classics {
            subtitle = meta.sourceTag
        } else if let host = GPEngine.shared.selectedHost {
            let playtime = GPStats.shared.playtime(forAppKey: GPStats.appKey(host: host, app: app))
            subtitle = playtime > 0 ? "\(GPFormatPlaytime(playtime)) played" : meta.sourceTag
        } else {
            subtitle = meta.sourceTag
        }
        cell.configure(app: app, subtitle: subtitle, badge: nil)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let apps = railApps(for: collectionView)
        guard apps.indices.contains(indexPath.item) else { return }
        openGame(apps[indexPath.item])
    }
}
