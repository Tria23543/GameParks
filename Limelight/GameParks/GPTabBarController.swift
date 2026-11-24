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
    private var pairingAlert: UIAlertController?

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

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        GPEngine.shared.noteVisibleViewController(viewController)
    }

    // MARK: - Pairing dialogs

    private func wirePairingDialogs() {
        let engine = GPEngine.shared
        engine.onPairingPIN = { [weak self] pin in
            guard let self = self else { return }
            let hostName = engine.selectedHost?.name ?? "your PC"
            let alert = UIAlertController(title: "Pairing",
                                          message: "Enter the following PIN in the Sunshine web UI on \(hostName):\n\n\(pin)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                self.pairingAlert = nil
            })
            self.pairingAlert = alert
            self.topPresented().present(alert, animated: true)
        }
        engine.onPairingResult = { [weak self] success, message in
            guard let self = self else { return }
            self.pairingAlert?.dismiss(animated: true) {
                self.pairingAlert = nil
                if !success {
                    let alert = UIAlertController(title: "Pairing Failed",
                                                  message: message ?? "Pairing did not complete.",
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.topPresented().present(alert, animated: true)
                }
            }
        }
    }

    private func topPresented() -> UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
