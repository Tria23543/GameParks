//
//  GPConnectingViewController.swift
//  GameParks
//
//  The design's connecting screen: a short checklist that does
//  real work — wake the PC if needed, confirm it over server-info,
//  build the stream exactly as upstream does, note the controller
//  state — and then pushes upstream's own stream view controller
//  onto the navigation stack, the way upstream's push segue does.
//  Every failure lands on words plus a next action, never a void.
//

import UIKit
import GameController

final class GPConnectingViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private enum StepState {
        case pending, active, done, warning, failed
    }

    private let hostUUID: String
    private var host: TemporaryHost
    private let app: TemporaryApp

    private var stepRows: [(icon: UILabel, label: UILabel, spinner: UIActivityIndicatorView)] = []
    private let footerStack = UIStackView()
    private var cancelled = false
    private var launched = false
    private var wakeAttempts = 0

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
        self.hostUUID = host.uuid ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(
            title: "Connecting…",
            subtitle: "\(app.name ?? "Game") · \(host.name ?? "your PC")",
            showsBack: true))

        let settings = DataManager().getSettings()
        let streamSummary = settings != nil
            ? "\(settings!.height?.intValue ?? 1080)p\(settings!.framerate?.intValue ?? 60)"
            : "1080p60"
        let stepTitles = [
            "Waking \(host.name ?? "your PC")",
            GPSessionController.shared().runningApp(for: host)?.id == app.id ? "Resuming the game" : "Starting the game",
            "Negotiating stream · \(streamSummary)",
            "Controller connected",
        ]
        for title in stepTitles {
            contentStack.addArrangedSubview(makeStepRow(title: title))
        }

        footerStack.axis = .vertical
        footerStack.spacing = 12
        contentStack.addArrangedSubview(footerStack)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !launched {
            runSequence()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !launched {
            cancelled = true
        }
    }

    // MARK: - Checklist UI

    private func makeStepRow(title: String) -> UIView {
        let card = UIView()
        card.backgroundColor = GPColor.panel
        card.layer.cornerRadius = 16

        let icon = gpLabel("○", font: GPFont.display(16, weight: .bold), color: GPColor.textFaint, lines: 1)
        icon.textAlignment = .center
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = GPColor.accent
        spinner.isHidden = true
        let label = gpLabel(title, font: GPFont.body(15, weight: .semibold), color: GPColor.textSecondary, lines: 0)

        let iconBox = UIView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        iconBox.addSubview(spinner)

        let row = UIStackView(arrangedSubviews: [iconBox, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 24),
            iconBox.heightAnchor.constraint(equalToConstant: 24),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        stepRows.append((icon: icon, label: label, spinner: spinner))
        return card
    }

    private func setStep(_ index: Int, state: StepState, text: String? = nil) {
        guard stepRows.indices.contains(index) else { return }
        let row = stepRows[index]
        if let text = text {
            row.label.text = text
        }
        switch state {
        case .pending:
            row.icon.text = "○"
            row.icon.textColor = GPColor.textFaint
            row.spinner.stopAnimating()
            row.spinner.isHidden = true
            row.icon.isHidden = false
            row.label.textColor = GPColor.textSecondary
        case .active:
            row.spinner.startAnimating()
            row.spinner.isHidden = false
            row.icon.isHidden = true
            row.label.textColor = GPColor.textPrimary
        case .done:
            row.icon.text = "✓"
            row.icon.textColor = GPColor.accent
            row.spinner.stopAnimating()
            row.spinner.isHidden = true
            row.icon.isHidden = false
            row.label.textColor = GPColor.textPrimary
        case .warning:
            row.icon.text = "!"
            row.icon.textColor = GPColor.warning
            row.spinner.stopAnimating()
            row.spinner.isHidden = true
            row.icon.isHidden = false
            row.label.textColor = GPColor.textPrimary
        case .failed:
            row.icon.text = "✕"
            row.icon.textColor = GPColor.danger
            row.spinner.stopAnimating()
            row.spinner.isHidden = true
            row.icon.isHidden = false
            row.label.textColor = GPColor.textPrimary
        }
    }

    private func showFailure(message: String) {
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let note = GPMessageView()
        note.configure(title: "Couldn't connect", message: message, actionTitle: "Try again")
        note.actionButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        footerStack.addArrangedSubview(note)
        let backButton = gpSecondaryButton("Back")
        backButton.addTarget(self, action: #selector(gpGoBack), for: .touchUpInside)
        footerStack.addArrangedSubview(backButton)
    }

    @objc private func retryTapped() {
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for index in stepRows.indices {
            setStep(index, state: .pending)
        }
        cancelled = false
        wakeAttempts = 0
        runSequence()
    }

    // MARK: - The sequence

    private func runSequence() {
        cancelled = false
        stepWake()
    }

    private func stepWake() {
        guard !cancelled else { return }
        refreshHost()
        if host.state == .online {
            setStep(0, state: .done)
            stepStart()
            return
        }
        setStep(0, state: .active)
        GPSessionController.shared().wakeHost(host)
        pollForWake()
    }

    private func pollForWake() {
        guard !cancelled else { return }
        wakeAttempts += 1
        if wakeAttempts > 15 {
            setStep(0, state: .failed)
            showFailure(message: "\(host.name ?? "Your PC") didn't answer. Check that it's on, Sunshine is running, and Wake-on-LAN is enabled on the PC.")
            return
        }
        // One silent server-info round trip per poll — the same
        // activation the host page uses, minus pairing.
        GPSessionController.shared().activateHost(host, userInitiated: false, skipFastPath: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.refreshHost()
            if self.host.state == .online {
                self.setStep(0, state: .done)
                self.stepStart()
            } else {
                self.pollForWake()
            }
        }
    }

    private func stepStart() {
        guard !cancelled else { return }
        setStep(1, state: .active)
        // One fresh server-info round trip so the running-game
        // state is current before we launch (upstream fetches it
        // in its host-tap flow for the same reason).
        GPSessionController.shared().activateHost(host, userInitiated: false, skipFastPath: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.refreshHost()
            if self.host.state != .online {
                self.setStep(1, state: .failed)
                self.showFailure(message: "Lost contact with \(self.host.name ?? "your PC") while starting. Check the PC and your Wi-Fi, then try again.")
                return
            }
            self.setStep(1, state: .done)
            self.stepNegotiate()
        }
    }

    private func stepNegotiate() {
        guard !cancelled else { return }
        setStep(2, state: .active)
        let session = GPSessionController.shared()
        guard let streamVC = session.streamViewController(for: app) else {
            setStep(2, state: .failed)
            showFailure(message: "The stream couldn't be set up for \(app.name ?? "this game"). Try again, or restart Sunshine on the PC.")
            return
        }
        setStep(2, state: .done)
        stepController(streamVC: streamVC)
    }

    private func stepController(streamVC: UIViewController) {
        guard !cancelled else { return }
        if GCController.controllers().isEmpty {
            setStep(3, state: .warning, text: "No controller — touch controls will be used")
        } else {
            setStep(3, state: .done)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.launch(streamVC: streamVC)
        }
    }

    private func launch(streamVC: UIViewController) {
        launched = true
        let settings = DataManager().getSettings()
        GPStats.shared.beginSession(appKey: GPCatalog.appKey(host: host, app: app),
                                    appName: app.name ?? "Game",
                                    bitrateKbps: settings?.bitrate?.intValue ?? 20000)
        GPSessionController.shared().noteStreamStarted()
        navigationController?.pushViewController(streamVC, animated: true)
    }

    private func refreshHost() {
        if let current = GPSessionController.shared().hosts.first(where: { $0.uuid == hostUUID }) {
            host = current
        }
    }
}
