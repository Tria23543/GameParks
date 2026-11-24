//
//  GPTabBarController.swift
//  GameParks
//
//  The app's root: Home / Library / Stats / Settings in the design's
//  tab bar. It sits at the root of the app's single navigation
//  controller; every other screen (host, game, connecting, the
//  stream itself) is pushed onto that controller, exactly the way
//  upstream pushes its stream screen from its root.
//
//  It is also the navigation delegate: when the stream screen pops
//  back to this root (upstream's stream always pops to root), the
//  play session is closed out and the engine refreshes.
//

import UIKit

final class GPTabBarController: UITabBarController, UINavigationControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GPColor.background

        let home = GPHomeViewController()
        home.tabBarItem = UITabBarItem(title: "Home",
                                       image: UIImage(systemName: "house"),
                                       selectedImage: UIImage(systemName: "house.fill"))

        let library = GPLibraryViewController()
        library.tabBarItem = UITabBarItem(title: "Library",
                                          image: UIImage(systemName: "rectangle.grid.2x2"),
                                          selectedImage: UIImage(systemName: "rectangle.grid.2x2.fill"))

        let stats = GPStatsViewController()
        stats.tabBarItem = UITabBarItem(title: "Stats",
                                        image: UIImage(systemName: "chart.bar"),
                                        selectedImage: UIImage(systemName: "chart.bar.fill"))

        let settings = GPSettingsViewController()
        settings.tabBarItem = UITabBarItem(title: "Settings",
                                           image: UIImage(systemName: "gearshape"),
                                           selectedImage: UIImage(systemName: "gearshape.fill"))

        viewControllers = [home, library, stats, settings]

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GPColor.panel
        let normal = [NSAttributedString.Key.foregroundColor: GPColor.textSecondary]
        let selected = [NSAttributedString.Key.foregroundColor: GPColor.accent]
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                       appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = GPColor.textSecondary
            layout.normal.titleTextAttributes = normal
            layout.selected.iconColor = GPColor.accent
            layout.selected.titleTextAttributes = selected
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = GPColor.accent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return selectedViewController?.supportedInterfaceOrientations ?? .portrait
    }

    // MARK: - UINavigationControllerDelegate

    func navigationController(_ navigationController: UINavigationController,
                              didShow viewController: UIViewController, animated: Bool) {
        // The stream screen has popped back to the root: close the
        // session and let the engine refresh, like upstream's
        // return to its main screen.
        guard viewController === self else {
            return
        }
        // A-14: ending the stream at the engine is NOT gated on the
        // stats session — noteStreamEnded() is idempotent, and if it
        // is skipped, discovery stays stopped for the life of the
        // process. End the stats session too, when one is active.
        if GPStats.shared.hasActiveSession {
            GPStats.shared.endSession()
        }
        GPSessionController.shared().noteStreamEnded()
    }
}
