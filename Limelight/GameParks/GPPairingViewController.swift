//
//  GPPairingViewController.swift
//  GameParks
//
//  The pairing sheet the host page presents. Three states, all on
//  one card: working (spinner), PIN (the number to type into the
//  Sunshine web UI), and failed (the engine's message). Cancel is
//  always available; every terminal state offers a way out. The
//  pairing itself runs in GPSessionController on the engine's
//  queues — this screen only renders its callbacks.
//

import UIKit

final class GPPairingViewController: UIViewController {
    private let host: TemporaryHost
    private let card = UIView()
    private let titleLabel = gpLabel("Pairing", font: GPFont.display(20, weight: .bold), color: GPColor.textPrimary, lines: 1)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pinLabel = gpLabel(nil, font: GPFont.display(40, weight: .extrabold), color: GPColor.accent, lines: 1)
    private let messageLabel = gpLabel(nil, font: GPFont.body(14), color: GPColor.textSecondary, lines: 0)
    private let cancelButton = gpSecondaryButton("Cancel")
    private let closeButton = gpPrimaryButton("Done")
    private var finished = false

    init(host: TemporaryHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)

        card.backgroundColor = GPColor.panel
        card.layer.cornerRadius = 24
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "Pairing with \(host.name ?? "your PC")"
        messageLabel.text = "Contacting your PC…"
        messageLabel.textAlignment = .center
        pinLabel.textAlignment = .center
        pinLabel.isHidden = true
        titleLabel.textAlignment = .center
        spinner.color = GPColor.accent
        spinner.startAnimating()
        closeButton.isHidden = true

        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner, pinLabel, messageLabel, cancelButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            cancelButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            closeButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let session = GPSessionController.shared
        session.onPairingPIN = { [weak self] pin in
            self?.showPIN(pin)
        }
        session.onPairingResult = { [weak self] success, message in
            self?.showResult(success: success, message: message)
        }

        // Two outcomes arrive outside the pairing callbacks: the
        // server-info re-check inside activation can find the PC
        // already paired, or fail to reach it at all.
        NotificationCenter.default.addObserver(self, selector: #selector(hostsChanged),
                                               name: GPHostsChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hostInfoError(_:)),
                                               name: GPHostInfoErrorNotification, object: nil)
    }

    @objc private func hostsChanged() {
        guard !finished,
              let current = GPSessionController.shared.hosts.first(where: { $0.uuid == host.uuid }),
              current.pairState == .paired else {
            return
        }
        showResult(success: true, message: nil)
    }

    @objc private func hostInfoError(_ note: Notification) {
        guard !finished,
              let errorHost = note.object as? TemporaryHost, errorHost.uuid == host.uuid,
              let message = note.userInfo?[GPHostInfoErrorMessageKey] as? String else {
            return
        }
        showResult(success: false, message: message)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick the flow off only once we're on screen, so the PIN
        // (delivered synchronously by the engine) has somewhere to go.
        GPSessionController.shared.pairSelectedHost()
    }

    private func showPIN(_ pin: String) {
        guard !finished else { return }
        spinner.stopAnimating()
        spinner.isHidden = true
        pinLabel.text = pin
        pinLabel.isHidden = false
        messageLabel.text = "Enter this PIN in the Sunshine web UI on your PC. Pairing finishes by itself once you do."
    }

    private func showResult(success: Bool, message: String?) {
        guard !finished else { return }
        finished = true
        spinner.stopAnimating()
        spinner.isHidden = true
        pinLabel.isHidden = true
        cancelButton.isHidden = true
        closeButton.isHidden = false
        if success {
            titleLabel.text = "Paired"
            messageLabel.text = "This phone is now paired with \(host.name ?? "your PC"). Your games are loading."
        } else {
            titleLabel.text = "Pairing failed"
            messageLabel.text = message ?? "Pairing did not complete. Check the PC is on and Sunshine is running, then try again."
        }
    }

    @objc private func cancelTapped() {
        GPSessionController.shared.cancelPairing()
        cleanupAndDismiss()
    }

    @objc private func closeTapped() {
        cleanupAndDismiss()
    }

    private func cleanupAndDismiss() {
        let session = GPSessionController.shared
        session.onPairingPIN = nil
        session.onPairingResult = nil
        dismiss(animated: true)
    }
}
