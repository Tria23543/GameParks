//
//  GPGameViewController.swift
//  GameParks
//
//  The game page from the approved design: big art, source and genre,
//  one full-width Play button, your stats for the title, and
//  per-game rows underneath.
//

import UIKit

final class GPGameViewController: GPBaseViewController {
    private let app: TemporaryApp
    // Created at declaration, configured in viewDidLoad: as an
    // implicitly-unwrapped optional assigned halfway through
    // viewDidLoad, any early return left it nil for later calls.
    private var favouriteButton = UIButton(type: .system)
    private var playtimeValueLabel: UILabel?
    private var lastPlayedValueLabel: UILabel?
    private var streamValueLabel: UILabel?
    private var runningNoteLabel: UILabel?
    private var playInFlight = false

    init(app: TemporaryApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let meta = GPGameMeta.meta(forAppName: app.name ?? "")
        let engine = GPEngine.shared

        let scrollView = UIScrollView()
        scrollView.delaysContentTouches = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        guard let host = app.host else {
            // The PC was removed while this page exists (or its host
            // never resolved): an explained placeholder, not the
            // completely blank page this used to render.
            let title = GPLabel(app.name ?? "Game", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink, lines: 2)
            let note = GPLabel("This game's PC is no longer available. It may have been removed — go back and pick it up again from Home if it reappears.",
                               font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut, lines: 0)
            stack.addArrangedSubview(padded(title, insets: UIEdgeInsets(top: 24, left: 20, bottom: 0, right: 20)))
            stack.addArrangedSubview(padded(note, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))
            return
        }

        // Hero art
        let hero = UIImageView()
        hero.image = GPCoverArt.cover(for: app)
        hero.contentMode = .scaleAspectFill
        hero.clipsToBounds = true
        hero.backgroundColor = GPTheme.panel2
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.heightAnchor.constraint(equalTo: hero.widthAnchor, multiplier: 0.56).isActive = true
        stack.addArrangedSubview(hero)

        // Title block
        let titleBlock = UIStackView()
        titleBlock.axis = .vertical
        titleBlock.spacing = 5
        titleBlock.isLayoutMarginsRelativeArrangement = true
        titleBlock.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        titleBlock.addArrangedSubview(GPLabel(app.name ?? "", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink, lines: 2))
        titleBlock.addArrangedSubview(GPLabel(meta.sourceTag, font: GPTheme.body(13, weight: .extrabold), color: GPTheme.accent))
        titleBlock.addArrangedSubview(GPLabel(meta.genreLine, font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut))
        stack.addArrangedSubview(titleBlock)

        // Play button + favourite
        let playButton = GPPlayButton(title: "Play on \(host.name)")
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        favouriteButton.tintColor = GPTheme.accent
        favouriteButton.backgroundColor = GPTheme.panel
        favouriteButton.round(16)
        favouriteButton.addTarget(self, action: #selector(favouriteTapped), for: .touchUpInside)
        updateFavouriteButton()
        let playRow = UIStackView(arrangedSubviews: [playButton, favouriteButton])
        playRow.axis = .horizontal
        playRow.spacing = 12
        playRow.isLayoutMarginsRelativeArrangement = true
        playRow.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        favouriteButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        stack.addArrangedSubview(playRow)

        // Stats strip (values refreshed by updateStats on every appearance)
        let playtimeLabel = GPLabel("—", font: GPTheme.display(16, weight: .bold), color: GPTheme.ink)
        let lastPlayedLabel = GPLabel("—", font: GPTheme.display(16, weight: .bold), color: GPTheme.ink)
        let streamLabel = GPLabel("—", font: GPTheme.display(16, weight: .bold), color: GPTheme.ink)
        playtimeValueLabel = playtimeLabel
        lastPlayedValueLabel = lastPlayedLabel
        streamValueLabel = streamLabel
        let statsCard = UIStackView()
        statsCard.axis = .horizontal
        statsCard.distribution = .fillEqually
        statsCard.backgroundColor = GPTheme.panel
        statsCard.round(16)
        statsCard.isLayoutMarginsRelativeArrangement = true
        statsCard.layoutMargins = UIEdgeInsets(top: 14, left: 8, bottom: 14, right: 8)
        statsCard.addArrangedSubview(statColumn(valueLabel: playtimeLabel, label: "Played"))
        statsCard.addArrangedSubview(statColumn(valueLabel: lastPlayedLabel, label: "Last played"))
        statsCard.addArrangedSubview(statColumn(valueLabel: streamLabel, label: "Stream"))
        let statsContainer = padded(statsCard, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        stack.addArrangedSubview(statsContainer)

        // Description
        if let description = meta.description {
            let label = GPLabel(description, font: GPTheme.body(14, weight: .regular), color: GPTheme.mut, lines: 0)
            stack.addArrangedSubview(padded(label, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))
        }

        // This game. The row copy describes what tapping actually
        // does — it used to advertise per-game resolution/bitrate and
        // launch flags the app does not have.
        stack.addArrangedSubview(padded(GPSectionHeader(title: "This game"), insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))
        let perGame = GPRow(title: "Per-game settings", subtitle: "Uses your global stream settings", value: "Info")
        perGame.addTarget(self, action: #selector(perGameTapped), for: .touchUpInside)
        stack.addArrangedSubview(padded(perGame, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))
        let launchOptions = GPRow(title: "Launch options", subtitle: "Set per-game launch flags in Sunshine", value: "Info")
        launchOptions.addTarget(self, action: #selector(launchOptionsTapped), for: .touchUpInside)
        stack.addArrangedSubview(padded(launchOptions, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))

        let note = GPLabel("", font: GPTheme.body(13, weight: .bold), color: GPTheme.live, lines: 2)
        runningNoteLabel = note
        stack.addArrangedSubview(padded(note, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)))

        updateStats()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        playInFlight = false
        updateStats()
    }

    /// Playtime, last-played, stream summary and the running note are
    /// computed from live state — they used to be frozen at whatever
    /// they were when the page was first built.
    private func updateStats() {
        guard let host = app.host else { return }
        let engine = GPEngine.shared
        let appKey = GPStats.appKey(host: host, app: app)
        let playtime = GPStats.shared.playtime(forAppKey: appKey)
        playtimeValueLabel?.text = playtime > 0 ? GPFormatPlaytime(playtime) : "—"
        if let lastPlayed = GPStats.shared.lastPlayed(forAppKey: appKey) {
            lastPlayedValueLabel?.text = GPFormatLastPlayed(lastPlayed)
        } else {
            lastPlayedValueLabel?.text = "—"
        }
        let settings = engine.currentSettings()
        streamValueLabel?.text = "\(settings?.height?.intValue ?? 1080)p\(settings?.framerate?.intValue ?? 60)"
        if engine.runningApp(for: host)?.id == app.id {
            runningNoteLabel?.text = "Running now on \(host.name) — Play resumes it."
            runningNoteLabel?.isHidden = false
        } else {
            runningNoteLabel?.text = nil
            runningNoteLabel?.isHidden = true
        }
    }

    private func statColumn(valueLabel: UILabel, label: String) -> UIView {
        let stack = UIStackView(arrangedSubviews: [
            valueLabel,
            GPLabel(label, font: GPTheme.body(11, weight: .semibold), color: GPTheme.dim),
        ])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        return stack
    }

    private func padded(_ inner: UIView, insets: UIEdgeInsets) -> UIView {
        let container = UIView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
        ])
        return container
    }

    private func updateFavouriteButton() {
        guard let host = app.host else { return }
        let isFavourite = GPFavourites.shared.contains(GPStats.appKey(host: host, app: app))
        favouriteButton.setImage(UIImage(systemName: isFavourite ? "heart.fill" : "heart"), for: .normal)
    }

    @objc private func favouriteTapped() {
        guard let host = app.host else { return }
        GPFavourites.shared.toggle(GPStats.appKey(host: host, app: app))
        updateFavouriteButton()
    }

    @objc private func playTapped() {
        // A double-tap used to push two connecting screens, each
        // starting its own connection sequence (double wakes, double
        // running-app alerts).
        guard !playInFlight else { return }
        guard let host = app.host else { return }
        let engine = GPEngine.shared
        if host.pairState != .paired {
            if host.state == .online {
                // The pairing flow is global: the progress dialog and
                // then the PIN dialog appear on their own. The old
                // "Pairing" message raced that PIN dialog for the same
                // screen and told her to press Play again even though
                // pairing was already starting.
                engine.activateHost(host, userInitiated: true)
            } else {
                engine.activateHost(host, userInitiated: true)
                showMessage(title: "Not paired yet", message: "\(host.name) needs to be online and paired before games can start. Wake it from the Host tab, pair once with a PIN, then press Play.")
            }
            return
        }
        playInFlight = true
        let connecting = GPConnectingViewController(app: app)
        navigationController?.pushViewController(connecting, animated: true)
    }

    @objc private func perGameTapped() {
        showMessage(title: "Per-game settings",
                    message: "This title uses your global stream settings for now — change them anytime in the Settings tab. Per-game overrides are on the GameParks list for a future update.")
    }

    @objc private func launchOptionsTapped() {
        showMessage(title: "Launch options",
                    message: "Games launch fullscreen through Sunshine with your saved stream settings. Launch flags for a specific title can be set in Sunshine on the PC, and this app will use them automatically.")
    }
}
