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
    var onPairingStarted: ((String) -> Void)?
    var onPairingPIN: ((String) -> Void)?
    var onPairingResult: ((Bool, String?) -> Void)?

    private(set) var hosts: [TemporaryHost] = []
    var selectedHost: TemporaryHost?

    // One shared DataManager. Creating one per access is wasteful, and
    // its initialiser synchronises with the main queue when built on a
    // background thread — a hidden sync wait on hot paths.
    private var dataManagerInstance: DataManager?
    private var dataManager: DataManager {
        if let instance = dataManagerInstance {
            return instance
        }
        let instance = DataManager()
        dataManagerInstance = instance
        return instance
    }
    private var discoveryManager: DiscoveryManager?
    private let subnetScanner = GPSubnetScanner()
    private var scanInProgress = false
    private var lastScanStarted: Date?
    private var scanCompletions: [() -> Void] = []
    private let opQueue = OperationQueue()
    private var clientCert: Data?
    private var started = false
    private var lastPingSamples: [String: [Int]] = [:]

    // Pairing state. Pairing callbacks apply to pairingHost — never to
    // whatever host happens to be selected by the time the user has
    // typed the PIN. pairingSuppressed records that the user dismissed
    // the pairing UI: state still updates, dialogs stay down.
    private var pairingHost: TemporaryHost?
    private var pairingSuppressed = false
    private let pairingStateLock = NSLock()

    // Notification coalescing: the last published host-list signature.
    // .gpHostsChanged is posted only when this actually changes.
    private var lastHostsSignature: String?

    // App-list fetch coalescing, keyed by host uuid (main queue only).
    private var appListInFlight: Set<String> = []
    private var appListPending: Set<String> = []

    // Active stream tracking for stats
    private var activeStreamAppKey: String?
    private var activeStreamStart: Date?
    private var activeStreamAccumulated: TimeInterval = 0
    private var activeStreamBitrateKbps: Int = 20000
    private weak var activeStreamVC: UIViewController?

    private override init() {
        super.init()
        // Pairing operations must never run concurrently with each other.
        opQueue.maxConcurrentOperationCount = 1
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else {
            return
        }

        CryptoManager.generateKeyPairUsingSSL()
        clientCert = CryptoManager.readCertFromFile()
        seedSettingsIfNeeded()

        hosts = (dataManager.getHosts() as? [TemporaryHost] ?? []).sorted { $0.compareName($1) == .orderedAscending }
        if selectedHost == nil {
            selectedHost = hosts.first
        }

        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
        discoveryManager?.startDiscovery()
        scanLocalNetwork(force: true)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        // Only mark started once setup has actually run, so a failure
        // above cannot wedge the engine in a half-started state.
        started = true
    }

    @objc private func appDidBecomeActive() {
        discoveryManager?.resetDiscoveryState()
        discoveryManager?.startDiscovery()
        scanLocalNetwork()
        // Resume the clock on a stream that was backgrounded mid-session.
        if activeStreamAppKey != nil, activeStreamStart == nil, activeStreamVC != nil {
            activeStreamStart = Date()
        }
        if let host = selectedHost, host.state == .online, host.pairState == .paired {
            refreshAppList(host)
        }
    }

    @objc private func appWillResignActive() {
        discoveryManager?.stopDiscovery()
        subnetScanner.cancel()
        // Pause the stream clock while backgrounded so Stats does not
        // count time the stream was suspended.
        if let start = activeStreamStart {
            activeStreamAccumulated += Date().timeIntervalSince(start)
            activeStreamStart = nil
        }
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
                                 enableHdr: current?.enableHdr ?? false,
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
        // Typed property (see TemporarySettings.h): a rename or type
        // change here is a compile error, not a silent "Auto".
        return Int(settings.preferredCodec)
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

    /// The running app without the hidden-app filter sortedApps applies:
    /// a hidden game still blocks a new launch, so the connecting
    /// screen's "another game is running" check must see it too.
    func anyRunningApp(for host: TemporaryHost) -> TemporaryApp? {
        guard let currentGame = host.currentGame, !currentGame.isEmpty, currentGame != "0" else {
            return nil
        }
        return host.appList.compactMap { $0 as? TemporaryApp }.first { $0.id == currentGame }
    }

    // MARK: - Host selection, pairing, app list

    /// The main entry when a host is chosen: wake it if asleep, pair if
    /// needed, then load its games.
    func activateHost(_ host: TemporaryHost, userInitiated: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.activateHost(host, userInitiated: userInitiated)
            }
            return
        }
        selectedHost = host
        if host.state == .offline {
            if userInitiated {
                wake(host)
                // Re-probe once, shortly after the wake request, so the
                // screens catch up when the PC boots instead of the
                // user having to tap again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self = self, host.state == .offline,
                          self.hosts.contains(where: { $0.uuid == host.uuid }) else { return }
                    self.fetchServerInfo(host) { ok in
                        if ok {
                            host.state = .online
                        }
                        self.notifyHostsChanged()
                    }
                }
            }
            notifyHostsChanged()
            return
        }
        // .online and .unknown both probe: an unknown host must never be
        // a dead end — tapping it retries the connection.
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
            let request = HttpRequest(for: response,
                                      with: hMan.newServerInfoRequest(false),
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

    /// Sets up pairing for a host. EVERYTHING here runs on a background
    /// queue — this is the fix for the v1.1 pairing freeze:
    /// stopDiscoveryBlocking waits for every discovery worker to drain,
    /// a worker can be blocked inside DataManager (whose Core Data
    /// context lives on the main queue), so calling it ON the main
    /// queue — as this did, via fetchServerInfo's main-queue completion
    /// — deadlocks the app permanently. The engine's own front-end
    /// calls it from a background queue for the same reason.
    private func pair(_ host: TemporaryHost) {
        pairingStateLock.lock()
        guard pairingHost == nil else {
            // A pairing is already in flight; re-entrant taps (the host
            // row, Play, repeated activateHost calls) must not enqueue
            // competing PairManagers against the same server.
            pairingStateLock.unlock()
            return
        }
        pairingHost = host
        pairingSuppressed = false
        pairingStateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onPairingStarted?(host.name)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.clientCert == nil {
                // The certificate may not have existed when start() ran;
                // pairing must not dead-end on that — retry once here.
                CryptoManager.generateKeyPairUsingSSL()
                self.clientCert = CryptoManager.readCertFromFile()
            }
            guard let cert = self.clientCert else {
                self.finishPairingWithFailure(host, message: "Pairing is not ready yet — try again in a moment.")
                return
            }
            // Polling the server during pairing corrupts the pairing
            // handshake, so discovery stops completely first (same as
            // the engine's own flow). This blocks until the discovery
            // workers drain — safe here, fatal on the main queue.
            self.discoveryManager?.stopDiscoveryBlocking()
            guard let hMan = HttpManager(host: host),
                  let pairManager = PairManager(manager: hMan, clientCert: cert, callback: self) else {
                self.discoveryManager?.startDiscovery()
                self.finishPairingWithFailure(host, message: "Could not reach \(host.name) to start pairing. Check it is online, then try again.")
                return
            }
            self.opQueue.addOperation(pairManager)
        }
    }

    /// The user dismissed the pairing UI. Queued pairing work is
    /// cancelled and discovery resumes. If the server-side attempt
    /// still completes afterwards, the next discovery poll corrects
    /// the host's pair state, so nothing is left inconsistent.
    func cancelPairing() {
        pairingStateLock.lock()
        pairingSuppressed = true
        pairingHost = nil
        pairingStateLock.unlock()
        opQueue.cancelAllOperations()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.discoveryManager?.startDiscovery()
        }
    }

    private func finishPairingWithFailure(_ host: TemporaryHost, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pairingStateLock.lock()
            let suppressed = self.pairingSuppressed
            if self.pairingHost?.uuid == host.uuid {
                self.pairingHost = nil
                self.pairingSuppressed = false
            }
            self.pairingStateLock.unlock()
            if !suppressed {
                self.onPairingResult?(false, message)
            }
        }
    }

    /// Atomically takes the pairing state for a completion callback:
    /// the host the result belongs to, and whether the UI was dismissed.
    private func claimPairingCompletion() -> (host: TemporaryHost?, suppressed: Bool) {
        pairingStateLock.lock()
        defer { pairingStateLock.unlock() }
        let host = pairingHost
        let suppressed = pairingSuppressed
        pairingHost = nil
        pairingSuppressed = false
        return (host, suppressed)
    }

    private func isPairingUIActive() -> Bool {
        pairingStateLock.lock()
        defer { pairingStateLock.unlock() }
        return pairingHost != nil && !pairingSuppressed
    }

    func refreshAppList(_ host: TemporaryHost) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshAppList(host)
            }
            return
        }
        // Coalesce: this is called from at least six places, and
        // overlapping fetches unpause discovery for each other (the
        // pause exists so polling cannot corrupt the fetch) and race
        // to write host.appList. One fetch per host at a time; a call
        // that arrives mid-fetch schedules exactly one follow-up.
        let uuid = host.uuid
        if appListInFlight.contains(uuid) {
            appListPending.insert(uuid)
            return
        }
        appListInFlight.insert(uuid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.discoveryManager?.pauseDiscovery(for: host)
            let response = ConnectionHelper.getAppList(for: host)
            self?.discoveryManager?.resumeDiscovery(for: host)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.appListInFlight.remove(uuid)
                if let response = response, response.isStatusOk(), let appList = response.getAppList() {
                    host.appList = appList
                    self.dataManager.updateApps(forExisting: host)
                    NotificationCenter.default.post(name: .gpAppListChanged, object: nil)
                    self.onAppListChanged?()
                }
                // On failure the previous list stays on screen (it is
                // refreshed again on the next trigger); there is no
                // error surface for it in the approved design.
                self.notifyHostsChanged()
                if self.appListPending.remove(uuid) != nil {
                    self.refreshAppList(host)
                }
            }
        }
    }

    func wake(_ host: TemporaryHost) {
        DispatchQueue.global(qos: .userInitiated).async {
            WakeOnLanManager.wake(host)
        }
    }

    func addHost(address: String, completion: @escaping (Bool, String?) -> Void) {
        // discoverHost performs synchronous HTTP (plus a possible STUN
        // lookup): it must never run on the caller's queue — the
        // add-by-address dialog calls this from the main queue, where a
        // silent host would freeze the app.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.discoveryManager?.discoverHost(address) { [weak self] host, error in
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
    }

    func removeHost(_ host: TemporaryHost) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.removeHost(host)
            }
            return
        }
        discoveryManager?.removeHost(fromDiscovery: host)
        dataManager.remove(host)
        hosts.removeAll { $0.uuid == host.uuid }
        if selectedHost?.uuid == host.uuid {
            selectedHost = hosts.first
        }
        notifyHostsChanged()
    }

    // MARK: - Subnet scan (automatic discovery without Bonjour)

    /// Sweeps the local subnet for GameStream PCs and adopts every
    /// validated host it finds. This is the automatic discovery that
    /// works inside LiveContainer, where Bonjour cannot be relied on
    /// (see GPSubnetScanner). Non-forced calls are throttled so the
    /// Home screen appearing can't start sweep after sweep.
    func scanLocalNetwork(force: Bool = false, completion: (() -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.scanLocalNetwork(force: force, completion: completion)
            }
            return
        }
        if let completion = completion {
            scanCompletions.append(completion)
        }
        guard let discoveryManager = discoveryManager else {
            finishScan()
            return
        }
        if scanInProgress {
            return
        }
        if !force, let last = lastScanStarted, Date().timeIntervalSince(last) < 20 {
            finishScan()
            return
        }
        scanInProgress = true
        lastScanStarted = Date()
        subnetScanner.scan(discoveryManager: discoveryManager, onHost: { [weak self] host in
            DispatchQueue.main.async {
                self?.adoptDiscoveredHost(host)
            }
        }, completion: { [weak self] completedNormally in
            guard let self = self else { return }
            self.scanInProgress = false
            if !completedNormally {
                // A cancelled or network-less sweep must not throttle
                // the next attempt for the full 20 s.
                self.lastScanStarted = nil
            }
            // One batched publish for everything the sweep changed.
            self.notifyHostsChanged()
            self.finishScan()
        })
    }

    private func finishScan() {
        let completions = scanCompletions
        scanCompletions.removeAll()
        completions.forEach { $0() }
    }

    /// A PC found by the subnet scan — already validated and built by
    /// DiscoveryManager.discoverHost (the manual add-by-IP code path),
    /// and already in the discovery queue. Save it, merge it into the
    /// host list (deduped by uuid against saved and Bonjour-found
    /// hosts) and tell the screens, exactly like a manual add.
    private func adoptDiscoveredHost(_ host: TemporaryHost) {
        dataManager.update(host)
        let isNew = !hosts.contains(where: { $0.uuid == host.uuid })
        if isNew {
            hosts.append(host)
            hosts.sort { $0.compareName($1) == .orderedAscending }
        }
        if selectedHost == nil {
            selectedHost = host
        }
        // During a sweep, updates to already-known hosts are batched
        // into the single publish at scan end; a genuinely new host
        // publishes immediately so it appears as soon as it is found.
        if isNew || !scanInProgress {
            notifyHostsChanged()
        }
        if host.pairState == .paired {
            refreshAppList(host)
        }
    }

    /// Quits the running app on the host. The completion reports
    /// whether the host actually quit it — callers must not proceed
    /// with a launch on failure (the host is still busy).
    func quitCurrentApp(on host: TemporaryHost, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let hMan = HttpManager(host: host) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let response = HttpResponse()
            let request = HttpRequest(for: response, with: hMan.newQuitAppRequest())
            self?.discoveryManager?.pauseDiscovery(for: host)
            hMan.executeRequestSynchronously(request)
            self?.discoveryManager?.resumeDiscovery(for: host)
            let ok = response.isStatusOk()
            DispatchQueue.main.async {
                if ok {
                    host.currentGame = nil
                }
                completion(ok)
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
        guard let config = GPStreamConfigBuilder.config(for: app) else {
            return nil
        }
        return GPStreamLauncher.streamViewController(withConfig: config)
    }

    /// Records the start of a stream so its session lands in Stats
    /// when the stream view leaves the screen.
    func registerStreamStart(app: TemporaryApp, viewController: UIViewController) {
        // A previous session that was never closed out is recorded
        // now rather than silently dropped.
        endStreamSessionIfNeeded()
        guard let host = app.host else {
            return
        }
        activeStreamAppKey = GPStats.appKey(host: host, app: app)
        activeStreamStart = Date()
        activeStreamAccumulated = 0
        activeStreamBitrateKbps = dataManager.getSettings()?.bitrate?.intValue ?? 20000
        activeStreamVC = viewController
    }

    /// Called by the tab bar controller (as navigation delegate) whenever
    /// the visible screen changes — used to notice a stream has ended.
    func noteVisibleViewController(_ viewController: UIViewController) {
        guard activeStreamAppKey != nil else { return }
        if let streamVC = activeStreamVC {
            // The stream screen is still alive: end the session only
            // when a different screen is showing AND the stream screen
            // has actually left the window. A sheet or alert presented
            // over the stream must not end the session early.
            guard viewController !== streamVC, streamVC.view.window == nil else { return }
        }
        // activeStreamVC is nil here when the stream screen was
        // dismissed and deallocated without a final navigation event —
        // the session still gets recorded.
        endStreamSessionIfNeeded()
    }

    private func endStreamSessionIfNeeded() {
        guard let appKey = activeStreamAppKey else { return }
        var duration = activeStreamAccumulated
        if let start = activeStreamStart {
            duration += Date().timeIntervalSince(start)
        }
        // Sanity cap: a stream left "current" across days must not
        // record days of playtime.
        duration = min(duration, 12 * 3600)
        GPStats.shared.recordSession(appKey: appKey, duration: duration, bitrateKbps: activeStreamBitrateKbps)
        activeStreamVC = nil
        activeStreamStart = nil
        activeStreamAccumulated = 0
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

    /// A fingerprint of everything the screens render from the host
    /// list. Compared before every publish (see notifyHostsChanged).
    private func hostsSignature() -> String {
        var parts = hosts.map { host in
            [host.uuid, host.name, "\(host.state.rawValue)", "\(host.pairState.rawValue)",
             host.activeAddress ?? "", "\(host.appList.count)", host.currentGame ?? ""].joined(separator: "|")
        }
        parts.append("sel:" + (selectedHost?.uuid ?? ""))
        if let selected = selectedHost, let ping = ping(for: selected) {
            parts.append("ping:\(ping)")
        }
        return parts.joined(separator: ";")
    }

    /// Publishes a host-list change — but only when something the
    /// screens render actually changed. Discovery polls, rescans and
    /// refreshes used to post unconditionally, and every post rebuilt
    /// every visible screen from scratch: in-flight touches on the PC
    /// card were destroyed mid-tap (the v1.1 "tap does nothing" bug)
    /// and the whole app stuttered. Duplicates now die here, at the
    /// source; screens additionally guard their own rebuilds.
    private func notifyHostsChanged() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.notifyHostsChanged()
            }
            return
        }
        let signature = hostsSignature()
        guard signature != lastHostsSignature else { return }
        lastHostsSignature = signature
        NotificationCenter.default.post(name: .gpHostsChanged, object: nil)
        onHostsChanged?()
    }
}

extension Notification.Name {
    static let gpHostsChanged = Notification.Name("GPHostsChanged")
    static let gpAppListChanged = Notification.Name("GPAppListChanged")
}

// MARK: - DiscoveryCallback

extension GPEngine: DiscoveryCallback {
    func updateAllHosts(_ hosts: [Any]) {
        // compactMap, not an all-or-nothing cast: one unexpected
        // element must not silently wipe the whole host list.
        let discovered = hosts.compactMap { $0 as? TemporaryHost }.sorted { $0.compareName($1) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hosts = discovered
            if let selected = self.selectedHost {
                self.selectedHost = discovered.first { $0.uuid == selected.uuid } ?? discovered.first
            } else {
                self.selectedHost = discovered.first
            }
            // Must go through notifyHostsChanged(): every GameParks screen
            // observes the .gpHostsChanged notification, and onHostsChanged
            // alone is not observed by any screen. Calling only the closure
            // here (as this did before) updated the host list silently and
            // discovered PCs never appeared on screen.
            self.notifyHostsChanged()
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
            // If the user already dismissed the pairing UI, a late PIN
            // must not pop a dialog back up.
            guard let self = self, self.isPairingUIActive() else { return }
            self.onPairingPIN?(pin)
        }
    }

    func pairSuccessful(_ serverCert: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // The result belongs to the host pairing was started for —
            // not to whatever is selected now — and state is mutated,
            // persisted and published BEFORE the result callback, so
            // anything reacting to it reads the paired state.
            let (pairedHost, suppressed) = self.claimPairingCompletion()
            self.discoveryManager?.startDiscovery()
            if let host = pairedHost ?? self.selectedHost {
                host.serverCert = serverCert
                host.pairState = .paired
                self.dataManager.update(host)
                self.refreshAppList(host)
            }
            self.notifyHostsChanged()
            if !suppressed {
                self.onPairingResult?(true, nil)
            }
        }
    }

    func pairFailed(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let (_, suppressed) = self.claimPairingCompletion()
            self.discoveryManager?.startDiscovery()
            self.notifyHostsChanged()
            if !suppressed {
                self.onPairingResult?(false, message)
            }
        }
    }

    func alreadyPaired() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // The host IS paired: say so in state and to the UI,
            // exactly like a fresh success — a screen waiting on the
            // pairing result must not wait forever.
            let (pairedHost, suppressed) = self.claimPairingCompletion()
            if let host = pairedHost ?? self.selectedHost {
                host.pairState = .paired
                self.dataManager.update(host)
                self.refreshAppList(host)
            }
            self.notifyHostsChanged()
            if !suppressed {
                self.onPairingResult?(true, nil)
            }
        }
    }
}
