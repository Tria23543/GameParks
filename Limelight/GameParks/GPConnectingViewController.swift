//
//  GPConnectingViewController.swift
//  GameParks
//
//  The connecting screen from the approved design: the game's art,
//  a live checklist (waking the host, starting the game, negotiating
//  the stream, controller) and then straight into the stream.
//

import UIKit

final class GPConnectingViewController: GPBaseViewController {
    private let app: TemporaryApp
    private let backgroundImage = UIImageView()
    private let titleLabel = GPLabel("Connecting…", font: GPTheme.display(24, weight: .extrabold), color: GPTheme.ink)
    private let subtitleLabel = GPLabel("", font: GPTheme.body(14, weight: .semibold), color: GPTheme.mut)
    private var stepRows: [(row: UIView, check: UILabel, label: UILabel)] = []
    private var finished = false

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

        backgroundImage.image = GPCoverArt.cover(for: app)
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
        backgroundImage.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundImage)

        let dim = UIView()
        dim.backgroundColor = UIColor(hex: 0x05060A, alpha: 0.82)
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)

        subtitleLabel.text = "\(app.name ?? "") · \(app.host?.name ?? "")"

        let stepsStack = UIStackView()
        stepsStack.axis = .vertical
        stepsStack.spacing = 14
        stepsStack.translatesAutoresizingMaskIntoConstraints = false

        let hostName = app.host?.name ?? "your PC"
        let settings = GPEngine.shared.currentSettings()
        let resLabel = "\(settings?.height?.intValue ?? 1080)p\(settings?.framerate?.intValue ?? 60)"
        let stepTexts = [
            "Waking \(hostName)",
            "Starting the game",
            "Negotiating stream · \(resLabel)",
            GPEngine.shared.bluetoothControllerConnected ? "Controller connected" : "On-screen controls ready",
        ]
        for text in stepTexts {
            let check = GPLabel("○", font: GPTheme.body(16, weight: .bold), color: GPTheme.dim)
            let label = GPLabel(text, font: GPTheme.body(15, weight: .semibold), color: GPTheme.mut)
            let row = UIStackView(arrangedSubviews: [check, label])
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center
            stepsStack.addArrangedSubview(row)
            stepRows.append((row: row, check: check, label: label))
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(GPTheme.mut, for: .normal)
        cancelButton.titleLabel?.font = GPTheme.body(15, weight: .bold)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, stepsStack, cancelButton])
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .leading
        contentStack.setCustomSpacing(28, after: subtitleLabel)
        contentStack.setCustomSpacing(34, after: stepsStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            backgroundImage.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundImage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            contentStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runConnectionSequence()
    }

    private func markStep(_ index: Int) {
        guard stepRows.indices.contains(index) else { return }
        stepRows[index].check.text = "✓"
        stepRows[index].check.textColor = GPTheme.live
        stepRows[index].label.textColor = GPTheme.ink
    }

    private func runConnectionSequence() {
        guard let host = app.host else {
            fail(message: "This game's PC is no longer available.")
            return
        }
        let engine = GPEngine.shared

        // Step 1: the host must be awake and online.
        if host.state == .offline {
            engine.wake(host)
            waitForHostOnline(host, attempts: 12) { [weak self] online in
                guard let self = self else { return }
                if online {
                    self.markStep(0)
                    self.startGameSteps()
                } else {
                    self.fail(message: "\(host.name) did not wake up. Check it is plugged in and Wake-on-LAN is on, then try again.")
                }
            }
        } else {
            markStep(0)
            startGameSteps()
        }
    }

    private func waitForHostOnline(_ host: TemporaryHost, attempts: Int, completion: @escaping (Bool) -> Void) {
        if finished {
            return
        }
        if host.state == .online {
            completion(true)
            return
        }
        if attempts <= 0 {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.waitForHostOnline(host, attempts: attempts - 1, completion: completion)
        }
    }

    private func startGameSteps() {
        guard let host = app.host, let nav = navigationController else { return }
        let engine = GPEngine.shared

        // Another game already running on the host? Ask before quitting it.
        if let running = engine.runningApp(for: host), running.id != app.id {
            let alert = UIAlertController(title: running.name,
                                          message: "\(running.name ?? "Another game") is currently running on \(host.name).",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                self.navigationController?.popViewController(animated: true)
            })
            alert.addAction(UIAlertAction(title: "Quit and start \(app.name ?? "this game")", style: .destructive) { _ in
                engine.quitCurrentApp(on: host) { [weak self] in
                    self?.startGameSteps()
                }
            })
            present(alert, animated: true)
            return
        }

        markStep(1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.markStep(2)
            self.markStep(3)
            guard let streamVC = engine.makeStreamViewController(for: self.app) else {
                self.fail(message: "The stream could not be created. Make sure the PC is paired and online.")
                return
            }
            self.finished = true
            engine.registerStreamStart(app: self.app, viewController: streamVC)
            var stack = nav.viewControllers
            if let index = stack.firstIndex(of: self) {
                stack[index] = streamVC
            } else {
                stack.append(streamVC)
            }
            nav.setViewControllers(stack, animated: true)
        }
    }

    private func fail(message: String) {
        titleLabel.text = "Could not connect"
        let alert = UIAlertController(title: "Could not connect", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func cancelTapped() {
        finished = true
        navigationController?.popViewController(animated: true)
    }
}
