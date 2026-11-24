//
//  GPEngine.swift
//  GameParks
//
//  Coordinates the streaming engine for the GameParks front-end:
//  discovery, pairing, the host's app list, Wake-on-LAN and launching
//  streams. This follows the same flow the engine's own front-end
//  uses, so pairing and streaming behave identically — only the
//  face is GameParks.
//

import UIKit
import GameController

final class GPEngine: NSObject {
    static let shared = GPEngine()

    // UI callbacks (always invoked on the main queue)
    var onHostsChanged: (() -> Void)?
    var onAppListChanged: (() -> Void)?
    var onPairingPIN: ((String) -> Void)?
    var onPairingResult: ((Bool, String?) -> Void)?

    private(set) var hosts: [TemporaryHost] = []
    var selectedHost: TemporaryHost?

    private var dataManager: DataManager { return DataManager() }
    private var discoveryManager: DiscoveryManager?
    private let opQueue = OperationQueue()
    private var clientCert: Data?
    private var started = false
    private var lastPingSamples: [String: [Int]] = [:]

    // Active stream tracking for stats
    private var activeStreamAppKey: String?
    private var activeStreamStart: Date?
    private var activeStreamBitrateKbps: Int = 20000
    private weak var activeStreamVC: UIViewController?

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else {
            return
        }
        started = true

        CryptoManager.generateKeyPairUsingSSL()
        clientCert = CryptoManager.readCertFromFile()
        seedSettingsIfNeeded()

        hosts = (dataManager.getHosts() as? [TemporaryHost] ?? []).sorted { $0.compareName($1) == .orderedAscending }
        if selectedHost == nil {
            selectedHost = hosts.first
        }

        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
        discoveryManager?.startDiscovery()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        discoveryManager?.resetDiscoveryState()
        discoveryManager?.startDiscovery()
        if let host = selectedHost, host.state == .online, host.pairState == .paired {
            refreshAppList(host)
        }
    }

    @objc private func appWillResignActive() {
        discoveryManager?.stopDiscovery()
    }

    // MARK: - Settings

    /// First run: write Glenda's settled stream defaults (1080p, 60 fps,
    /// 20 Mb/s, codec on Auto, stats overlay on). Later runs keep her choices.
    private func seedSettingsIfNeeded() {
        let key = "GPSeededSettingsV1"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        let current = dataManager.getSettings()
        dataManager.saveSettings(withBitrate: 20000,
                                 framerate: 60,
                                 height: 1080,
                                 width: 1920,
                                 audioConfig: current?.audioConfig?.intValue ?? 2,
                                 onscreenControls: current?.onscreenControls?.intValue ?? 2,
                                 optimizeGames: current?.optimizeGames ?? false,
                                 multiController: current?.multiController ?? true,
                                 swapABXYButtons: current?.swapABXYButtons ?? false,
                                 audioOnPC: current?.playAudioOnPC ?? false,
                                 preferredCodec: 0, // CODEC_PREF_AUTO — never forced
                                 useFramePacing: current?.useFramePacing ?? false,
                                 enableHdr: false,
                                 btMouseSupport: current?.btMouseSupport ?? false,
                                 absoluteTouchMode: current?.absoluteTouchMode ?? false,
                                 statsOverlay: true)
        UserDefaults.standard.set(true, forKey: key)
    }

    func currentSettings() -> TemporarySettings? {
        return dataManager.getSettings()
    }

    /// Saves stream settings, preserving everything the GameParks
    /// settings screen does not manage.
    func saveStreamSettings(width: Int, height: Int, fps: Int, bitrateKbps: Int,
                            codec: UInt32, statsOverlay: Bool, audioChannels: Int,
                            onscreenControls: Int) {
        let current = dataManager.getSettings()
        dataManager.saveSettings(withBitrate: bitrateKbps,
                                 framerate: fps,
                                 height: height,
                                 width: width,
                                 audioConfig: audioChannels,
                                 onscreenControls: onscreenControls,
                                 optimizeGames: current?.optimizeGames ?? false,
                                 multiController: current?.multiController ?? true,
                                 swapABXYButtons: current?.swapABXYButtons ?? false,
                                 audioOnPC: current?.playAudioOnPC ?? false,
                                 preferredCodec: codec,
                                 useFramePacing: current?.useFramePacing ?? false,
                                 enableHdr: current?.enableHdr ?? false,
                                 btMouseSupport: current?.btMouseSupport ?? false,
                                 absoluteTouchMode: current?.absoluteTouchMode ?? false,
                                 statsOverlay: statsOverlay)
    }

    /// The saved codec preference (0 = Auto, 1 = H.264, 2 = H.265, 3 = AV1).
    func currentCodecPref() -> Int {
        guard let settings = dataManager.getSettings() else {
            return 0
        }
        return (settings.value(forKey: "preferredCodec") as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Host helpers

    func ping(for host: TemporaryHost) -> Int? {
        guard let samples = lastPingSamples[host.uuid], !samples.isEmpty else {
            return nil
        }
        return samples.reduce(0, +) / samples.count
    }

    func sortedApps(for host: TemporaryHost) -> [TemporaryApp] {
        let apps = host.appList.compactMap { $0 as? TemporaryApp }.filter { !$0.hidden }
        return apps.sorted { $0.compareName($1) == .orderedAscending }
    }

    func runningApp(for host: TemporaryHost) -> TemporaryApp? {
        guard let currentGame = host.currentGame, !currentGame.isEmpty, currentGame != "0" else {
            return nil
        }
        return sortedApps(for: host).first { $0.id == currentGame }
    }

    // MARK: - Host selection, pairing, app list

    /// The main entry when a host is chosen: wake it if asleep, pair if
    /// needed, then load its games.
    func activateHost(_ host: TemporaryHost, userInitiated: Bool) {
        selectedHost = host
        if host.state == .offline {
            if userInitiated {
                wake(host)
            }
            notifyHostsChanged()
            return
        }
        if host.state == .unknown {
            notifyHostsChanged()
            return
        }
        fetchServerInfo(host) { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                host.state = .offline
                self.notifyHostsChanged()
                return
            }
            if host.pairState == .paired {
                self.refreshAppList(host)
            } else if userInitiated {
                self.pair(host)
            }
            self.notifyHostsChanged()
        }
    }

    private func fetchServerInfo(_ host: TemporaryHost, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = Date()
            guard let hMan = HttpManager(host: host) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let response = ServerInfoResponse()
            let request = HttpRequest(forResponse: response,
                                      withUrlRequest: hMan.newServerInfoRequest(false),
                                      fallbackError: 401,
                                      fallbackRequest: hMan.newHttpServerInfoRequest())
            self?.discoveryManager?.pauseDiscovery(for: host)
            hMan.executeRequestSynchronously(request)
            self?.discoveryManager?.resumeDiscovery(for: host)

            let ok = response.isStatusOk()
            if ok {
                response.populateHost(host)
                let ms = max(Int(Date().timeIntervalSince(start) * 1000), 1)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    var samples = self.lastPingSamples[host.uuid] ?? []
                    samples.append(ms)
                    self.lastPingSamples[host.uuid] = Array(samples.suffix(10))
                }
            }
            DispatchQueue.main.async {
                completion(ok)
            }
        }
    }

    private func pair(_ host: TemporaryHost) {
        guard let cert = clientCert else {
            onPairingResult?(false, "Pairing is not ready yet — try again in a moment.")
            return
        }
        // Polling the server while pairing causes the server to screw up,
        // so discovery stops completely first (same as the engine's own flow).
        discoveryManager?.stopDiscoveryBlocking()
        guard let hMan = HttpManager(host: host),
              let pairManager = PairManager(manager: hMan, clientCert: cert, callback: self) else {
            onPairingResult?(false, "Pairing is not ready yet — try again in a moment.")
            return
        }
        opQueue.addOperation(pairManager)
    }

    func refreshAppList(_ host: TemporaryHost) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.discoveryManager?.pauseDiscovery(for: host)
            let response = ConnectionHelper.getAppListForHost(host)
            self?.discoveryManager?.resumeDiscovery(for: host)

            DispatchQueue.main.async {
                guard let self = self else { return }
                if let response = response, response.isStatusOk(), let appList = response.getAppList() {
                    host.appList = appList
                    self.dataManager.updateApps(forExistingHost: host)
                    NotificationCenter.default.post(name: .gpAppListChanged, object: nil)
                    self.onAppListChanged?()
                }
                self.notifyHostsChanged()
            }
        }
    }

    func wake(_ host: TemporaryHost) {
        DispatchQueue.global(qos: .userInitiated).async {
            WakeOnLanManager.wake(host)
        }
    }

    func addHost(address: String, completion: @escaping (Bool, String?) -> Void) {
        discoveryManager?.discoverHost(address) { [weak self] host, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let host = host {
                    self.dataManager.update(host)
                    if !self.hosts.contains(where: { $0.uuid == host.uuid }) {
                        self.hosts.append(host)
                        self.hosts.sort { $0.compareName($1) == .orderedAscending }
                    }
                    self.selectedHost = host
                    self.notifyHostsChanged()
                    completion(true, nil)
                } else {
                    completion(false, error)
                }
            }
        }
    }

    func removeHost(_ host: TemporaryHost) {
        discoveryManager?.removeHost(fromDiscovery: host)
        dataManager.remove(host)
        hosts.removeAll { $0.uuid == host.uuid }
        if selectedHost?.uuid == host.uuid {
            selectedHost = hosts.first
        }
        notifyHostsChanged()
    }

    func quitCurrentApp(on host: TemporaryHost, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let hMan = HttpManager(host: host) else {
                DispatchQueue.main.async { completion() }
                return
            }
            let response = HttpResponse()
            let request = HttpRequest(forResponse: response, withUrlRequest: hMan.newQuitAppRequest())
            self?.discoveryManager?.pauseDiscovery(for: host)
            hMan.executeRequestSynchronously(request)
            self?.discoveryManager?.resumeDiscovery(for: host)
            DispatchQueue.main.async {
                host.currentGame = nil
                completion()
            }
        }
    }

    // MARK: - Launching a stream

    /// Creates the engine's stream view controller for an app, ready to
    /// be pushed. The connecting screen owns the presentation so it can
    /// replace itself in the navigation stack.
    func makeStreamViewController(for app: TemporaryApp) -> UIViewController? {
        guard let host = app.host, host.pairState == .paired else {
            return nil
        }
        let config = GPStreamConfigBuilder.config(for: app)
        return GPStreamLauncher.streamViewController(withConfig: config)
    }

    /// Records the start of a stream so its session lands in Stats
    /// when the stream view leaves the screen.
    func registerStreamStart(app: TemporaryApp, viewController: UIViewController) {
        guard let host = app.host else {
            return
        }
        activeStreamAppKey = GPStats.appKey(host: host, app: app)
        activeStreamStart = Date()
        activeStreamBitrateKbps = dataManager.getSettings()?.bitrate?.intValue ?? 20000
        activeStreamVC = viewController
    }

    /// Called by the tab bar controller (as navigation delegate) whenever
    /// the visible screen changes — used to notice a stream has ended.
    func noteVisibleViewController(_ viewController: UIViewController) {
        guard let streamVC = activeStreamVC, viewController !== streamVC,
              let start = activeStreamStart, let appKey = activeStreamAppKey else {
            return
        }
        let duration = Date().timeIntervalSince(start)
        GPStats.shared.recordSession(appKey: appKey, duration: duration, bitrateKbps: activeStreamBitrateKbps)
        activeStreamVC = nil
        activeStreamStart = nil
        activeStreamAppKey = nil
        if let host = selectedHost, host.pairState == .paired {
            refreshAppList(host)
        }
    }

    // MARK: - Controller

    var bluetoothControllerConnected: Bool {
        return !(GCController.controllers().filter { $0.extendedGamepad != nil || $0.microGamepad != nil }.isEmpty)
    }

    // MARK: - Notifications

    private func notifyHostsChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .gpHostsChanged, object: nil)
            onHostsChanged?()
        } else {
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(name: .gpHostsChanged, object: nil)
                self?.onHostsChanged?()
            }
        }
    }
}

extension Notification.Name {
    static let gpHostsChanged = Notification.Name("GPHostsChanged")
    static let gpAppListChanged = Notification.Name("GPAppListChanged")
}

// MARK: - DiscoveryCallback

extension GPEngine: DiscoveryCallback {
    func updateAllHosts(_ hosts: [Any]) {
        let discovered = (hosts as? [TemporaryHost] ?? []).sorted { $0.compareName($1) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hosts = discovered
            if let selected = self.selectedHost {
                self.selectedHost = discovered.first { $0.uuid == selected.uuid } ?? discovered.first
            } else {
                self.selectedHost = discovered.first
            }
            self.onHostsChanged?()
            if let host = self.selectedHost, host.state == .online, host.pairState == .paired,
               host.appList.count == 0 {
                self.refreshAppList(host)
            }
        }
    }
}

// MARK: - PairCallback

extension GPEngine: PairCallback {
    func startPairing(_ pin: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPairingPIN?(pin)
        }
    }

    func pairSuccessful(_ serverCert: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.selectedHost?.serverCert = serverCert
            self.discoveryManager?.startDiscovery()
            self.onPairingResult?(true, nil)
            if let host = self.selectedHost {
                host.pairState = .paired
                self.refreshAppList(host)
            }
            self.notifyHostsChanged()
        }
    }

    func pairFailed(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.discoveryManager?.startDiscovery()
            self?.onPairingResult?(false, message)
        }
    }

    func alreadyPaired() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let host = self.selectedHost {
                self.refreshAppList(host)
            }
        }
    }
}
