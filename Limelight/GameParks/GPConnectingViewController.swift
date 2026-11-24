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
//  Steps advance on the host's actual state, not on timers
//  (A-12): after each activateHost the screen waits — via the
//  session's GPHostsChanged notifications plus a polling fallback,
//  against a host re-resolved fresh by UUID at every check — until
//  the host reports online, with an explicit timeout. Every async
//  block carries the run generation it was scheduled in (A-34), so
//  a retry or a disappearance retires the previous run outright.
//

import UIKit
import GameController

/// The host's addresses usable as a secondary identity (D-17):
/// the local and active addresses, as available at capture time.
func gpKnownAddresses(of host: TemporaryHost) -> Set<String> {
    return Set([host.localAddress, host.activeAddress].compactMap { $0 }.filter { !$0.isEmpty })
}

/// D-17: the shared C-23 re-resolution used by the Connecting,
/// Game and Host screens. A UUID match comes first (unchanged);
/// otherwise the name matches are collected — exactly one is the
/// C-23 substitution (unchanged). With more than one same-named
/// host, the matches are filtered by secondary-field agreement
/// with the identity captured at init: MAC where both sides have
/// one, else overlap of the known (local/active) addresses.
/// Exactly one survivor substitutes; zero or several survivors
/// is no substitution at all (nil), never a first-in-list guess.
func gpResolveHost(in hosts: [TemporaryHost], uuid: String, name: String,
                   mac: String?, addresses: Set<String>) -> TemporaryHost? {
    if !uuid.isEmpty, let byUUID = hosts.first(where: { $0.uuid == uuid }) {
        return byUUID
    }
    let nameMatches = hosts.filter { $0.name == name }
    if nameMatches.count == 1 {
        return nameMatches.first
    }
    guard nameMatches.count > 1 else { return nil }
    let survivors = nameMatches.filter { candidate in
        if let capturedMAC = mac, !capturedMAC.isEmpty,
           let candidateMAC = candidate.mac, !candidateMAC.isEmpty {
            return candidateMAC == capturedMAC
        }
        return !gpKnownAddresses(of: candidate).isDisjoint(with: addresses)
    }
    return survivors.count == 1 ? survivors.first : nil
}

final class GPConnectingViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private enum StepState {
        case pending, active, done, warning, failed
    }

    private enum Phase {
        case idle, waking, starting, finished
    }

    private let hostUUID: String
    private let hostName: String
    /// D-17: the secondary identity captured at init, used to
    /// tie-break duplicate-name re-resolution.
    private let hostMAC: String?
    private let hostAddresses: Set<String>
    /// D-17: set when re-resolution found several same-named
    /// hosts and no secondary-field survivor — the launch must
    /// fail rather than stream from the stale host object.
    private var hostAmbiguous = false
    private var host: TemporaryHost
    private let app: TemporaryApp

    private var stepRows: [(icon: UILabel, label: UILabel, spinner: UIActivityIndicatorView)] = []
    private var originalStepTitles: [String] = []
    private let footerStack = UIStackView()
    private var cancelled = false
    private var launched = false
    private var runGeneration = 0
    private var phase: Phase = .idle

    // The in-flight state wait (A-12): one at a time, driven by
    // host-change notifications and a polling fallback.
    private var waitDeadline: Date?
    private var waitOnOnline: (() -> Void)?
    private var waitOnTimeout: (() -> Void)?
    private var lastActivation: Date?
    // B-26: each wait gets its own token, bumped when the wait is
    // installed or cleared — a poll chain from a superseded wait
    // can no longer re-arm against its successor's closures.
    private var waitToken = 0

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
        self.hostUUID = host.uuid ?? ""
        self.hostName = host.name
        self.hostMAC = host.mac
        self.hostAddresses = gpKnownAddresses(of: host)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(
            title: "Connecting…",
            subtitle: "\(app.name ?? "Game") · \(host.name ?? "your PC")",
            showsBack: true))

        let settings = DataManager().getSettings()
        // B-41 (mirrored from GPGame): the height goes through the
        // same label mapping Stream settings uses — 2160 is "4K",
        // not "2160p".
        let settingsHeight = settings?.height?.intValue ?? 1080
        let settingsFps = settings?.framerate?.intValue ?? 60
        let streamSummary = "\(settingsHeight == 2160 ? "4K" : "\(settingsHeight)p")\(settingsFps)"
        // D-23: resume counts only when BOTH ids are non-empty
        // and equal (the A-77 discipline GPGame's isThisApp
        // uses) — an optional-to-optional comparison is true
        // when both ids are nil.
        let runningID = GPSessionController.shared().runningApp(for: host)?.id ?? ""
        let appID = app.id ?? ""
        let resuming = !runningID.isEmpty && !appID.isEmpty && runningID == appID
        let stepTitles = [
            "Waking \(host.name ?? "your PC")",
            resuming ? "Resuming the game" : "Starting the game",
            "Negotiating stream · \(streamSummary)",
            "Controller connected",
        ]
        originalStepTitles = stepTitles
        for title in stepTitles {
            contentStack.addArrangedSubview(makeStepRow(title: title))
        }

        // A-50: an explicit way out, wired to the same cancelled
        // flag as disappearing.
        let cancelButton = gpSecondaryButton("Cancel")
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(cancelButton)

        footerStack.axis = .vertical
        footerStack.spacing = 12
        contentStack.addArrangedSubview(footerStack)

        NotificationCenter.default.addObserver(self, selector: #selector(hostsChanged),
                                               name: .GPHostsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
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
            runGeneration += 1
            clearWait()
        }
    }

    @objc private func cancelTapped() {
        cancelled = true
        runGeneration += 1
        clearWait()
        gpGoBack()
    }

    /// A-50: foregrounding re-validates the current step — if the
    /// wait's state has gone stale, restart the wait for that step.
    @objc private func appWillEnterForeground() {
        guard !launched, !cancelled else { return }
        refreshHost()
        switch phase {
        case .waking, .starting:
            if waitOnOnline == nil {
                // The wait was cleared while backgrounded; restart
                // the current step's wait from scratch.
                if phase == .waking {
                    stepWake()
                } else {
                    stepStart()
                }
            } else {
                checkWait()
            }
        case .idle, .finished:
            break
        }
    }

    @objc private func hostsChanged() {
        // A host-list change may be the state we've been waiting
        // for — re-check immediately instead of waiting for a poll.
        guard waitOnOnline != nil else { return }
        checkWait()
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
        phase = .finished
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
        // A-105: restore the original step titles as well as states.
        for index in stepRows.indices {
            let title = originalStepTitles.indices.contains(index) ? originalStepTitles[index] : nil
            setStep(index, state: .pending, text: title)
        }
        runSequence()
    }

    // MARK: - State waiting (A-12)

    private func clearWait() {
        waitDeadline = nil
        waitOnOnline = nil
        waitOnTimeout = nil
        // B-26: retire any poll chain still carrying this wait's
        // token, so it cannot re-arm against the next wait.
        waitToken += 1
    }

    /// Waits until the freshly re-resolved host reports .online.
    /// `activateHost` is (re-)issued at most every few seconds;
    /// progress is driven by GPHostsChanged plus a 0.5 s polling
    /// fallback, and the wait fails at the absolute deadline.
    private func waitForOnline(timeout: TimeInterval,
                               onOnline: @escaping () -> Void,
                               onTimeout: @escaping () -> Void) {
        let generation = runGeneration
        waitToken += 1
        let token = waitToken
        waitDeadline = Date().addingTimeInterval(timeout)
        waitOnOnline = onOnline
        waitOnTimeout = onTimeout
        lastActivation = nil
        scheduleWaitPoll(generation: generation, token: token)
        checkWait()
    }

    private func scheduleWaitPoll(generation: Int, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // B-26: the token check is what retires this chain when
            // checkWait's synchronous online callback installs the
            // NEXT step's wait under the same run generation — the
            // old chain must not re-arm against the new wait.
            guard let self = self, !self.cancelled, generation == self.runGeneration,
                  token == self.waitToken, self.waitOnOnline != nil else { return }
            self.checkWait()
            if self.waitOnOnline != nil, token == self.waitToken {
                self.scheduleWaitPoll(generation: generation, token: token)
            }
        }
    }

    private func checkWait() {
        guard !cancelled, let onOnline = waitOnOnline, let onTimeout = waitOnTimeout,
              let deadline = waitDeadline else { return }
        refreshHost()
        if host.state == .online {
            clearWait()
            onOnline()
            return
        }
        if Date() >= deadline {
            clearWait()
            onTimeout()
            return
        }
        // Keep the server-info round trips coming, spaced out.
        if lastActivation == nil || Date().timeIntervalSince(lastActivation!) >= 3 {
            lastActivation = Date()
            GPSessionController.shared().activateHost(host, userInitiated: false, skipFastPath: true)
        }
    }

    // MARK: - The sequence

    private func runSequence() {
        runGeneration += 1
        cancelled = false
        clearWait()
        stepWake()
    }

    private func stepWake() {
        guard !cancelled else { return }
        phase = .waking
        refreshHost()
        if host.state == .online {
            setStep(0, state: .done)
            stepStart()
            return
        }
        setStep(0, state: .active)
        GPSessionController.shared().wakeHost(host)
        // A-49: an absolute deadline, not a poll count; the failure
        // copy only blames Wake-on-LAN when a wake could be sent.
        let hostName = host.name ?? "Your PC"
        let hasUsableMAC = !(host.mac ?? "").isEmpty && host.mac != "00:00:00:00:00:00"
        waitForOnline(timeout: 30, onOnline: { [weak self] in
            self?.setStep(0, state: .done)
            self?.stepStart()
        }, onTimeout: { [weak self] in
            guard let self = self else { return }
            self.setStep(0, state: .failed)
            if hasUsableMAC {
                self.showFailure(message: "\(hostName) didn't answer. Check that it's on, Sunshine is running, and Wake-on-LAN is enabled on the PC.")
            } else {
                self.showFailure(message: "\(hostName) didn't answer. Check that it's on and Sunshine is running.")
            }
        })
    }

    private func stepStart() {
        guard !cancelled else { return }
        phase = .starting
        setStep(1, state: .active)
        // One fresh server-info round trip so the running-game
        // state is current before we launch (upstream fetches it
        // in its host-tap flow for the same reason) — and the step
        // advances on the host actually reporting online (A-12),
        // failing only at the explicit timeout. The wait issues
        // the activation itself (see checkWait).
        waitForOnline(timeout: 15, onOnline: { [weak self] in
            guard let self = self else { return }
            self.setStep(1, state: .done)
            self.stepNegotiate()
        }, onTimeout: { [weak self] in
            guard let self = self else { return }
            self.setStep(1, state: .failed)
            self.showFailure(message: "Lost contact with \(self.host.name ?? "your PC") while starting. Check the PC and your Wi-Fi, then try again.")
        })
    }

    private func stepNegotiate() {
        guard !cancelled else { return }
        phase = .finished
        setStep(2, state: .active)
        // A-12: build the stream config from the host as the
        // session holds it *now* — address, cert and codec support
        // all come from app.host at build time.
        refreshHost()
        // D-17: an ambiguous duplicate-name re-resolution never
        // substituted, so `host` is still the stale object —
        // building a config from it could stream the wrong PC.
        // Fail through this step's existing failure path instead.
        if hostAmbiguous {
            setStep(2, state: .failed)
            showFailure(message: "The stream couldn't be set up for \(app.name ?? "this game"). Try again, or restart Sunshine on the PC.")
            return
        }
        app.host = host
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
        let generation = runGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !self.cancelled, generation == self.runGeneration else { return }
            self.launch(streamVC: streamVC)
        }
    }

    private func launch(streamVC: UIViewController) {
        launched = true
        let settings = DataManager().getSettings()
        // A-43: the stats session starts at the last responsible
        // moment — immediately before the stream is handed over —
        // so negotiation time is never counted as playtime.
        GPStats.shared.beginSession(appKey: GPCatalog.appKey(host: host, app: app),
                                    appName: app.name ?? "Game",
                                    bitrateKbps: settings?.bitrate?.intValue ?? 20000)
        GPSessionController.shared().noteStreamStarted()
        navigationController?.pushViewController(streamVC, animated: true)
    }

    private func refreshHost() {
        // B-35: the A-77 fallback GPGame/GPHost already have — a
        // non-empty UUID matches by UUID; an empty UUID falls back
        // to the name captured at init. UUID-only matching made
        // this a permanent no-op for an empty UUID (and froze it
        // the same way if the server ever rewrote the UUID), so
        // the whole launch ran on a stale host object.
        // C-23: the name fallback now engages whenever the UUID
        // match fails, not only when the captured UUID is empty —
        // a server-side UUID rewrite otherwise kept the freeze
        // B-35 described. UUID match still comes first.
        // D-17: the shared helper tie-breaks duplicate names by
        // the secondary identity captured at init and substitutes
        // nothing when the tie-break is itself ambiguous.
        let hosts = GPSessionController.shared().hosts
        if let current = gpResolveHost(in: hosts, uuid: hostUUID, name: hostName,
                                       mac: hostMAC, addresses: hostAddresses) {
            host = current
            hostAmbiguous = false
        } else {
            // No substitution. That is the plain no-match case
            // (the stale host is kept, as before) exactly when
            // there is at most one same-named host; several
            // same-named hosts with no survivor is the ambiguous
            // case stepNegotiate must fail on.
            hostAmbiguous = hosts.filter { $0.name == hostName }.count > 1
        }
    }
}
