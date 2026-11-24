//
//  GPTabBarController.swift
//  GameParks
//
//  The app's root: four tabs in the approved design —
//  Home, Library, Stats, Settings — on the dark GameParks theme.
//  Also owns the pairing dialogs, which can appear over any tab.
//

import UIKit

final class GPTabBarController: UITabBarController, UINavigationControllerDelegate {
    private var pairingProgressAlert: UIAlertController?
    private var pairingAlert: UIAlertController?
    private var pairingHostName: String?

    // The tab bar itself takes the selected tab's orientation mask —
    // every tab root is a GameParks screen, so this is portrait.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return selectedViewController?.supportedInterfaceOrientations ?? .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return selectedViewController?.preferredInterfaceOrientationForPresentation ?? .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GPTheme.bg

        let home = GPHomeViewController()
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), selectedImage: UIImage(systemName: "house.fill"))

        let library = GPLibraryViewController()
        library.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "square.grid.2x2"), selectedImage: UIImage(systemName: "square.grid.2x2.fill"))

        let stats = GPStatsViewController()
        stats.tabBarItem = UITabBarItem(title: "Stats", image: UIImage(systemName: "chart.bar"), selectedImage: UIImage(systemName: "chart.bar.fill"))

        let settings = GPSettingsViewController()
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))

        viewControllers = [home, library, stats, settings]

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(hex: 0x0B0D15)
        appearance.stackedLayoutAppearance.normal.iconColor = GPTheme.mut
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: GPTheme.mut, .font: GPTheme.body(11, weight: .bold)]
        appearance.stackedLayoutAppearance.selected.iconColor = GPTheme.accent
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: GPTheme.accent, .font: GPTheme.body(11, weight: .bold)]
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.layer.borderWidth = 0.5
        tabBar.layer.borderColor = GPTheme.line.cgColor

        wirePairingDialogs()
        GPEngine.shared.start()
    }

    // MARK: - Navigation delegate (stream-end detection)

    // Contract: GPBootstrap assigns this controller as the outer
    // navigation controller's delegate. If that assignment is ever
    // removed, stream-end detection (Stats recording, post-stream
    // refresh) silently stops — the engine also guards by checking
    // whether the stream screen has actually left the window.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        GPEngine.shared.noteVisibleViewController(viewController)
    }

    // MARK: - Pairing dialogs

    private func wirePairingDialogs() {
        let engine = GPEngine.shared

        engine.onPairingStarted = { [weak self] hostName in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pairingHostName = hostName
                // Progress first: pairing setup (stopping discovery,
                // contacting the host) can take a few seconds, and the
                // screen must show that something is happening.
                let alert = UIAlertController(title: "Pairing",
                                              message: "Contacting \(hostName)…",
                                              preferredStyle: .alert)
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.translatesAutoresizingMaskIntoConstraints = false
                spinner.startAnimating()
                alert.view.addSubview(spinner)
                NSLayoutConstraint.activate([
                    spinner.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
                    spinner.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -58),
                ])
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    self.pairingProgressAlert = nil
                    GPEngine.shared.cancelPairing()
                })
                self.pairingProgressAlert = alert
                self.topPresented().present(alert, animated: true)
            }
        }

        engine.onPairingPIN = { [weak self] pin in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let hostName = self.pairingHostName ?? engine.selectedHost?.name ?? "your PC"
                let message = "Enter the following PIN in the Sunshine web UI on \(hostName):\n\n\(pin)"
                if let existing = self.pairingAlert, existing.presentingViewController != nil {
                    // A PIN dialog is already up: update it in place.
                    // Presenting a second one on top of it fails and
                    // the new PIN would be lost.
                    existing.message = message
                    return
                }
                let showPIN = { [weak self] in
                    guard let self = self else { return }
                    let alert = UIAlertController(title: "Pairing",
                                                  message: message,
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                        self.pairingAlert = nil
                        GPEngine.shared.cancelPairing()
                    })
                    self.pairingAlert = alert
                    self.topPresented().present(alert, animated: true)
                }
                if let progress = self.pairingProgressAlert {
                    self.pairingProgressAlert = nil
                    progress.dismiss(animated: true) {
                        showPIN()
                    }
                } else {
                    showPIN()
                }
            }
        }

        engine.onPairingResult = { [weak self] success, message in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let progress = self.pairingProgressAlert
                let pinAlert = self.pairingAlert
                self.pairingProgressAlert = nil
                self.pairingAlert = nil
                let hostName = self.pairingHostName ?? "your PC"
                self.pairingHostName = nil

                let presentOutcome = { [weak self] in
                    guard let self = self else { return }
                    if success {
                        // Confirm only when a pairing dialog was up —
                        // a background "already paired" result needs no
                        // interruption.
                        guard progress != nil || pinAlert != nil else { return }
                        let alert = UIAlertController(title: "Paired",
                                                      message: "\(hostName) is paired and ready to play.",
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.topPresented().present(alert, animated: true)
                    } else {
                        // A failure is ALWAYS surfaced — including when
                        // the user had already dismissed the PIN dialog
                        // (previously this completion was chained off
                        // dismissing that dialog, so a failure after
                        // Cancel vanished silently).
                        let alert = UIAlertController(title: "Pairing failed",
                                                      message: message ?? "Pairing did not complete. Check the PIN and try again.",
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.topPresented().present(alert, animated: true)
                    }
                }

                if let pinAlert = pinAlert, pinAlert.presentingViewController != nil {
                    pinAlert.dismiss(animated: true) {
                        presentOutcome()
                    }
                } else if let progress = progress, progress.presentingViewController != nil {
                    progress.dismiss(animated: true) {
                        presentOutcome()
                    }
                } else {
                    presentOutcome()
                }
            }
        }
    }

    /// The controller alerts should be presented from: the true
    /// topmost one. Walks from the window root through presented
    /// controllers AND through navigation/tab containers — a PIN that
    /// arrives while a pushed screen (e.g. the host page) has its own
    /// alert up must land on top of that, not on the tab bar.
    private func topPresented() -> UIViewController {
        var top: UIViewController = view.window?.rootViewController ?? self
        while true {
            if let presented = top.presentedViewController {
                top = presented
            } else if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
                top = visible
            } else if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
                top = selected
            } else {
                break
            }
        }
        return top
    }
}
