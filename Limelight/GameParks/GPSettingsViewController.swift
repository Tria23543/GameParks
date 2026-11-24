//
//  GPSettingsViewController.swift
//  GameParks
//
//  The design's Settings: stream presets, the stream knobs, the
//  controls, and the hosts list. Every value lives in the engine's
//  own settings store (DataManager), because that is what the
//  stream configuration is built from — GPSettingsStore writes
//  through it, preserving the fields GameParks doesn't manage.
//  Every control on these screens writes a real engine setting:
//  the old Video filters / Microphone / Anti-deadzone rows were
//  removed in v2.5 (A-01) because nothing in the engine ever read
//  their GameParks preference keys. Their stored values are left
//  untouched in UserDefaults, just no longer shown.
//

import UIKit
import GameController

enum GPSettingsStore {
    /// Posted when a save finds no settings record (A-18), so the
    /// failure is never silent.
    static let saveFailedNotification = Notification.Name("GPSettingsSaveFailed")

    static func current() -> TemporarySettings? {
        return DataManager().getSettings()
    }

    static func codecPref(of settings: TemporarySettings) -> UInt32 {
        return (settings.value(forKey: "preferredCodec") as? NSNumber)?.uint32Value ?? 0
    }

    static func codecName(_ pref: UInt32) -> String {
        switch pref {
        case 1: return "H.264"
        case 2: return "H.265"
        case 3: return "AV1"
        default: return "Auto"
        }
    }

    static func save(width: Int? = nil, height: Int? = nil, fps: Int? = nil,
                     bitrateKbps: Int? = nil, codec: UInt32? = nil,
                     audioChannels: Int? = nil, onscreenControls: Int? = nil,
                     statsOverlay: Bool? = nil) {
        guard let cur = current() else {
            // A-18: never no-op silently — log and notify.
            NSLog("GPSettingsStore.save: no settings record; save dropped")
            NotificationCenter.default.post(name: saveFailedNotification, object: nil)
            return
        }
        DataManager().saveSettings(
            withBitrate: bitrateKbps ?? cur.bitrate?.intValue ?? 20000,
            framerate: fps ?? cur.framerate?.intValue ?? 60,
            height: height ?? cur.height?.intValue ?? 1080,
            width: width ?? cur.width?.intValue ?? 1920,
            audioConfig: audioChannels ?? cur.audioConfig?.intValue ?? 2,
            onscreenControls: onscreenControls ?? cur.onscreenControls?.intValue ?? 1,
            optimizeGames: cur.optimizeGames,
            multiController: cur.multiController,
            swapABXYButtons: cur.swapABXYButtons,
            audioOnPC: cur.playAudioOnPC,
            preferredCodec: codec ?? codecPref(of: cur),
            useFramePacing: cur.useFramePacing,
            enableHdr: cur.enableHdr,
            btMouseSupport: cur.btMouseSupport,
            absoluteTouchMode: cur.absoluteTouchMode,
            statsOverlay: statsOverlay ?? cur.statsOverlay)
    }

    struct Preset {
        let title: String
        let detail: String
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int
        let codec: UInt32
    }

    static let presets: [Preset] = [
        Preset(title: "Home Wi-Fi", detail: "1080p HQ · 60 fps · 20 Mb/s · Auto codec",
               width: 1920, height: 1080, fps: 60, bitrateKbps: 20000, codec: 0),
        // B-38: every preset applies codec 0 (Auto), so every
        // detail string discloses it — not just Home Wi-Fi's.
        Preset(title: "Mobile data saver", detail: "720p · 30 fps · 8 Mb/s · Auto codec",
               width: 1280, height: 720, fps: 30, bitrateKbps: 8000, codec: 0),
        Preset(title: "Cloud — best quality", detail: "1080p HQ · 60 fps · 25 Mb/s · Auto codec",
               width: 1920, height: 1080, fps: 60, bitrateKbps: 25000, codec: 0),
    ]

    static func activePresetIndex() -> Int? {
        guard let cur = current() else { return nil }
        for (index, preset) in presets.enumerated() {
            if cur.width?.intValue == preset.width && cur.height?.intValue == preset.height
                && cur.framerate?.intValue == preset.fps && cur.bitrate?.intValue == preset.bitrateKbps
                && codecPref(of: cur) == preset.codec {
                return index
            }
        }
        return nil
    }

    static func applyPreset(_ index: Int) {
        let preset = presets[index]
        save(width: preset.width, height: preset.height, fps: preset.fps,
             bitrateKbps: preset.bitrateKbps, codec: preset.codec)
    }

    /// A-18: the explicit row shown when there is no settings record.
    static func settingsUnavailableView() -> UIView {
        let view = GPMessageView()
        view.configure(title: "Settings unavailable — restart the app",
                       message: "Your stream settings couldn't be loaded, so changes can't be saved right now. Restarting the app should bring them back.",
                       actionTitle: nil)
        return view
    }
}

final class GPSettingsViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private let dynamicStack = UIStackView()
    // A-53: the header is tracked by reference, not by position.
    private var headerView: UIView?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        // B-15: the A-18 save-failure signal finally gets an
        // observer — a failed save rebuilds immediately, and the
        // rebuild surfaces the "Settings unavailable" state at the
        // moment of the tap instead of staying silent.
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: GPSettingsStore.saveFailedNotification, object: nil)
        rebuildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // B-17 (A-31 residual): appearance goes through the
        // scroll-safe path like the other tab roots.
        requestContentRebuild()
    }

    @objc private func stateChanged() {
        requestContentRebuild()
    }

    override func rebuildContent() {
        // The header carries the pairing state, so rebuild it too.
        headerView?.removeFromSuperview()
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let session = GPSessionController.shared()
        let host = session.selectedHost ?? session.hosts.first
        let subtitle = host != nil && host!.pairState == .paired
            ? "GameParks · paired to \(host!.name ?? "your PC")"
            : "GameParks"
        let header = makeHeader(title: "Settings", subtitle: subtitle)
        headerView = header
        contentStack.insertArrangedSubview(header, at: 0)

        // A-18: say so plainly when saves cannot land.
        if GPSettingsStore.current() == nil {
            dynamicStack.addArrangedSubview(GPSettingsStore.settingsUnavailableView())
        }

        // Stream presets
        dynamicStack.addArrangedSubview(gpSectionHeader("Stream presets"))
        let activePreset = GPSettingsStore.activePresetIndex()
        for (index, preset) in GPSettingsStore.presets.enumerated() {
            let row = GPRow(showsChevron: false)
            row.titleLabel.text = preset.title
            row.subtitle = preset.detail
            if index == activePreset {
                row.valueLabel.text = "Active"
                row.valueLabel.textColor = GPColor.accent
            }
            row.tag = index
            row.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }

        // Stream summary rows → the detail screen
        dynamicStack.addArrangedSubview(gpSectionHeader("Stream"))
        let cur = GPSettingsStore.current()
        let resolutionText = "\(cur?.width?.intValue ?? 1920)×\(cur?.height?.intValue ?? 1080)"
        let rows: [(String, String?, String)] = [
            ("Resolution", (cur?.width?.intValue == 1920 && cur?.height?.intValue == 1080) ? "1080p HQ — your settled pick" : nil,
             resolutionText),
            ("Bitrate", "Higher = sharper picture", gpFormatBitrate(cur?.bitrate?.intValue ?? 20000)),
            ("Codec", "Auto recommended", GPSettingsStore.codecName(cur != nil ? GPSettingsStore.codecPref(of: cur!) : 0)),
            ("Frame rate", nil, "\(cur?.framerate?.intValue ?? 60) fps"),
        ]
        for (title, subtitle, value) in rows {
            let row = GPRow()
            row.titleLabel.text = title
            row.subtitle = subtitle
            row.valueLabel.text = value
            row.addTarget(self, action: #selector(streamSettingsTapped), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }

        // Controls
        dynamicStack.addArrangedSubview(gpSectionHeader("Controls"))
        let controllerRow = GPRow(showsChevron: false)
        controllerRow.titleLabel.text = "Bluetooth controller"
        let controllerConnected = !GCController.controllers().isEmpty
        controllerRow.subtitle = controllerConnected ? "Connected" : "Connect one to play with a gamepad"
        controllerRow.valueLabel.text = controllerConnected ? "Paired" : "Not connected"
        dynamicStack.addArrangedSubview(controllerRow)

        // A-37: the toggle reflects the actual engine level and
        // turning it back on restores the level it had before.
        let oscLevel = cur?.onscreenControls?.intValue ?? 0
        let oscRow = GPSwitchRow()
        oscRow.titleLabel.text = "On-screen controls"
        oscRow.subtitle = Self.oscSubtitle(level: oscLevel)
        oscRow.isOn = oscLevel != 0
        oscRow.onToggle = { isOn in
            if isOn {
                let stored = UserDefaults.standard.integer(forKey: "GPOscPreviousLevel")
                GPSettingsStore.save(onscreenControls: stored != 0 ? stored : 1)
            } else {
                let current = GPSettingsStore.current()?.onscreenControls?.intValue ?? 0
                if current != 0 {
                    UserDefaults.standard.set(current, forKey: "GPOscPreviousLevel")
                }
                GPSettingsStore.save(onscreenControls: 0)
            }
        }
        dynamicStack.addArrangedSubview(oscRow)

        let statsRow = GPSwitchRow()
        statsRow.titleLabel.text = "Stats overlay"
        statsRow.subtitle = "Ping · fps · bitrate in-game"
        statsRow.isOn = cur?.statsOverlay ?? true
        statsRow.onToggle = { isOn in GPSettingsStore.save(statsOverlay: isOn) }
        dynamicStack.addArrangedSubview(statsRow)

        // Hosts
        dynamicStack.addArrangedSubview(gpSectionHeader("Hosts"))
        for knownHost in session.hosts {
            let row = GPRow()
            row.titleLabel.text = knownHost.name
            let ping = session.lastPingMs(for: knownHost)
            switch (knownHost.state, knownHost.pairState) {
            case (.online, .paired):
                row.subtitle = "Paired · Sunshine" + (ping >= 0 ? " · \(ping) ms" : "")
            case (.online, _):
                row.subtitle = "Online · not paired"
            case (.offline, _):
                row.subtitle = "Offline"
            default:
                row.subtitle = "Connecting…"
            }
            row.valueLabel.text = "Manage"
            // A-27 completed: tap identity rides on the row's
            // dedicated hostUUID, never accessibilityIdentifier.
            row.hostUUID = knownHost.uuid
            row.addTarget(self, action: #selector(hostRowTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }

        let addRow = GPRow()
        addRow.titleLabel.text = "Add a PC by address"
        addRow.subtitle = "If yours doesn't appear by itself"
        addRow.addTarget(self, action: #selector(addHostTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(addRow)

        let cloudRow = GPRow(showsChevron: false)
        cloudRow.titleLabel.text = "Cloud PC"
        cloudRow.subtitle = "Not set up yet — joins as a second host when one is ready"
        cloudRow.addTarget(self, action: #selector(cloudTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(cloudRow)
    }

    /// Engine level names (OnScreenControlsLevel): Off 0, Auto 1,
    /// Simple 2, Full 3, plus Auto-with-gamepad variants.
    static func oscSubtitle(level: Int) -> String {
        switch level {
        // A-37 completed: level 0 is Off and must say so — it
        // previously fell into the Auto default while the switch
        // was off. Levels 4–6 are the engine's Auto-with-gamepad
        // variants, for which the Auto wording is truthful.
        case 0: return "Off"
        case 2: return "Simple — basic buttons, always shown"
        case 3: return "Full — full controls, always shown"
        default: return "Auto — hides when a controller is connected"
        }
    }

    // MARK: - Actions

    @objc private func presetTapped(_ sender: GPRow) {
        GPSettingsStore.applyPreset(sender.tag)
        performContentRebuild()
    }

    @objc private func streamSettingsTapped() {
        navigationController?.pushViewController(GPStreamSettingsViewController(), animated: true)
    }

    @objc private func hostRowTapped(_ sender: GPRow) {
        guard let uuid = sender.hostUUID,
              let host = GPSessionController.shared().hosts.first(where: { $0.uuid == uuid }) else { return }
        GPSessionController.shared().selectHost(host)
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func addHostTapped() {
        presentAddByAddress()
    }

    @objc private func cloudTapped() {
        presentAlert(title: "Cloud PC",
                     message: "When a cloud PC is ready, it joins here as a second host — same app, same library, same settings. There's nothing to set up yet.")
    }
}

// MARK: - Stream settings detail

final class GPStreamSettingsViewController: GPBaseViewController {
    private let dynamicStack = UIStackView()
    // Segment tables built in rebuildContent (A-40): they include
    // an exotic stored value as its own segment when one exists.
    private var resolutionSizes: [(width: Int, height: Int)] = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]
    private var frameRates: [Int] = [30, 60, 90, 120]
    /// B-18: surround channel counts are a table like the other
    /// knobs, so an out-of-list stored count gets its own segment.
    private var surroundCounts: [Int] = [2, 6, 8]
    private let codecPrefs: [UInt32] = [0, 2, 1, 3] // Auto, H.265 (HEVC), H.264, AV1

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(title: "Stream settings",
                                                   subtitle: "Picture & sound", showsBack: true))
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)
        // B-15: observe the save-failure signal here too — this is
        // the screen whose controls save most often.
        NotificationCenter.default.addObserver(self, selector: #selector(saveFailed),
                                               name: GPSettingsStore.saveFailedNotification, object: nil)
        rebuildContent()
    }

    @objc private func saveFailed() {
        // The rebuild surfaces the "Settings unavailable" state.
        requestContentRebuild()
    }

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cur = GPSettingsStore.current()

        // A-18: say so plainly when saves cannot land.
        if cur == nil {
            dynamicStack.addArrangedSubview(GPSettingsStore.settingsUnavailableView())
        }

        dynamicStack.addArrangedSubview(gpSectionHeader("Presets"))
        let activePreset = GPSettingsStore.activePresetIndex()
        for (index, preset) in GPSettingsStore.presets.enumerated() {
            let row = GPRow(showsChevron: false)
            row.titleLabel.text = preset.title
            row.subtitle = preset.detail
            if index == activePreset {
                row.valueLabel.text = "Active"
                row.valueLabel.textColor = GPColor.accent
            }
            row.tag = index
            row.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
            dynamicStack.addArrangedSubview(row)
        }

        dynamicStack.addArrangedSubview(gpSectionHeader("Fine tuning"))

        // A-40 completed: matching is by the exact (width, height)
        // pair, never height alone — v2.5 keyed on height only, so
        // a stored 2560×1080 displayed as "1080p" and the first tap
        // silently rewrote its width to 1920. A stored size outside
        // the list gets its own segment labelled with its exact
        // dimensions, and selecting it writes the same pair back:
        // the value round-trips honestly.
        resolutionSizes = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]
        let storedWidth = cur?.width?.intValue ?? 1920
        let storedHeight = cur?.height?.intValue ?? 1080
        let standardSizes = resolutionSizes
        if !resolutionSizes.contains(where: { $0.width == storedWidth && $0.height == storedHeight }) {
            resolutionSizes.append((storedWidth, storedHeight))
        }
        let resolutionItems = resolutionSizes.map { size -> String in
            if standardSizes.contains(where: { $0.width == size.width && $0.height == size.height }) {
                switch size.height {
                case 2160: return "4K"
                default: return "\(size.height)p"
                }
            }
            return "\(size.width)×\(size.height)"
        }
        let resolution = gpSegmented(items: resolutionItems)
        resolution.selectedSegmentIndex = resolutionSizes.firstIndex(where: { $0.width == storedWidth && $0.height == storedHeight }) ?? 1
        resolution.addTarget(self, action: #selector(resolutionChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Resolution", control: resolution))

        frameRates = [30, 60, 90, 120]
        let storedFps = cur?.framerate?.intValue ?? 60
        if !frameRates.contains(storedFps) {
            frameRates.append(storedFps)
        }
        let frameRate = gpSegmented(items: frameRates.map { "\($0)" })
        frameRate.selectedSegmentIndex = frameRates.firstIndex(of: storedFps) ?? 1
        frameRate.addTarget(self, action: #selector(frameRateChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Frame rate", control: frameRate))

        // A-36: AV1 is a real segment, mapped to pref 3 both ways.
        let codec = gpSegmented(items: ["Auto", "H.265", "H.264", "AV1"])
        let codecPref = cur != nil ? GPSettingsStore.codecPref(of: cur!) : 0
        codec.selectedSegmentIndex = codecPrefs.firstIndex(of: codecPref) ?? 0
        codec.addTarget(self, action: #selector(codecChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Codec", control: codec))

        // Bitrate stepper card
        let bitrateCard = UIView()
        bitrateCard.backgroundColor = GPColor.panel
        bitrateCard.layer.cornerRadius = 16
        let stepper = GPGuardedStepper()
        stepper.minimumValue = 1
        stepper.maximumValue = 200
        stepper.stepValue = 1
        stepper.value = Double(cur?.bitrate?.intValue ?? 20000) / 1000.0
        // A-39: the label is built from the stepper's (clamped)
        // value, so the two can never disagree; an out-of-range
        // stored value is only written back clamped on first save.
        let bitrateValue = gpLabel("\(Int(stepper.value)) Mb/s",
                                   font: GPFont.body(15, weight: .semibold), color: GPColor.textPrimary, lines: 1)
        bitrateValue.tag = 77
        stepper.tintColor = GPColor.accent
        stepper.addTarget(self, action: #selector(bitrateChanged(_:)), for: .valueChanged)
        let bitrateText = UIStackView(arrangedSubviews: [
            gpLabel("Bitrate", font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1),
            gpLabel("Higher = sharper picture", font: GPFont.body(13), color: GPColor.textSecondary, lines: 1),
        ])
        bitrateText.axis = .vertical
        bitrateText.spacing = 2
        let bitrateRow = UIStackView(arrangedSubviews: [bitrateText, bitrateValue, stepper])
        bitrateRow.axis = .horizontal
        bitrateRow.alignment = .center
        bitrateRow.spacing = 10
        bitrateRow.translatesAutoresizingMaskIntoConstraints = false
        bitrateCard.addSubview(bitrateRow)
        NSLayoutConstraint.activate([
            bitrateRow.topAnchor.constraint(equalTo: bitrateCard.topAnchor, constant: 12),
            bitrateRow.bottomAnchor.constraint(equalTo: bitrateCard.bottomAnchor, constant: -12),
            bitrateRow.leadingAnchor.constraint(equalTo: bitrateCard.leadingAnchor, constant: 16),
            bitrateRow.trailingAnchor.constraint(equalTo: bitrateCard.trailingAnchor, constant: -16),
        ])
        dynamicStack.addArrangedSubview(bitrateCard)

        // B-18: exact-count matching, like resolution/fps — an
        // out-of-list stored count (e.g. 4 or 7) gets its own
        // segment instead of displaying as a listed value and being
        // silently rewritten on first touch.
        surroundCounts = [2, 6, 8]
        let storedChannels = cur?.audioConfig?.intValue ?? 2
        if !surroundCounts.contains(storedChannels) {
            surroundCounts.append(storedChannels)
        }
        let surroundItems = surroundCounts.map { count -> String in
            switch count {
            case 2: return "Stereo"
            case 6: return "5.1"
            case 8: return "7.1"
            default: return "\(count) ch"
            }
        }
        let surround = gpSegmented(items: surroundItems)
        surround.selectedSegmentIndex = surroundCounts.firstIndex(of: storedChannels) ?? 0
        surround.addTarget(self, action: #selector(surroundChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Surround audio", control: surround))
        // A-41: the engine clamps to the phone's physical output.
        dynamicStack.addArrangedSubview(gpLabel("Limited by your phone's audio output.",
                                                font: GPFont.body(13), color: GPColor.textSecondary, lines: 0))

        // Why Auto — why forcing a codec is a bad idea (A-92).
        let whyCard = UIView()
        whyCard.backgroundColor = GPColor.panel
        whyCard.layer.cornerRadius = 16
        let whyStack = UIStackView(arrangedSubviews: [
            gpLabel("Why Auto?", font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1),
            gpLabel("Forcing H.265 made streams hang. Auto picks the best codec your phone and PC agree on — every time.",
                    font: GPFont.body(13), color: GPColor.textSecondary, lines: 0),
        ])
        whyStack.axis = .vertical
        whyStack.spacing = 4
        whyStack.translatesAutoresizingMaskIntoConstraints = false
        whyCard.addSubview(whyStack)
        NSLayoutConstraint.activate([
            whyStack.topAnchor.constraint(equalTo: whyCard.topAnchor, constant: 14),
            whyStack.bottomAnchor.constraint(equalTo: whyCard.bottomAnchor, constant: -14),
            whyStack.leadingAnchor.constraint(equalTo: whyCard.leadingAnchor, constant: 16),
            whyStack.trailingAnchor.constraint(equalTo: whyCard.trailingAnchor, constant: -16),
        ])
        dynamicStack.addArrangedSubview(whyCard)
    }

    private func controlCard(title: String, control: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = GPColor.panel
        card.layer.cornerRadius = 16
        let stack = UIStackView(arrangedSubviews: [
            gpLabel(title, font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1),
            control,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }

    // MARK: - Actions

    @objc private func presetTapped(_ sender: GPRow) {
        GPSettingsStore.applyPreset(sender.tag)
        performContentRebuild()
    }

    @objc private func resolutionChanged(_ sender: UISegmentedControl) {
        guard resolutionSizes.indices.contains(sender.selectedSegmentIndex) else { return }
        let size = resolutionSizes[sender.selectedSegmentIndex]
        GPSettingsStore.save(width: size.width, height: size.height)
    }

    @objc private func frameRateChanged(_ sender: UISegmentedControl) {
        guard frameRates.indices.contains(sender.selectedSegmentIndex) else { return }
        GPSettingsStore.save(fps: frameRates[sender.selectedSegmentIndex])
    }

    @objc private func codecChanged(_ sender: UISegmentedControl) {
        guard codecPrefs.indices.contains(sender.selectedSegmentIndex) else { return }
        GPSettingsStore.save(codec: codecPrefs[sender.selectedSegmentIndex])
    }

    @objc private func bitrateChanged(_ sender: UIStepper) {
        GPSettingsStore.save(bitrateKbps: Int(sender.value) * 1000)
        if let card = sender.superview, let value = card.viewWithTag(77) as? UILabel {
            value.text = "\(Int(sender.value)) Mb/s"
        }
    }

    @objc private func surroundChanged(_ sender: UISegmentedControl) {
        // B-18: bounds-guarded like its sibling handlers, and reads
        // the table (which may carry an exotic stored count).
        guard surroundCounts.indices.contains(sender.selectedSegmentIndex) else { return }
        GPSettingsStore.save(audioChannels: surroundCounts[sender.selectedSegmentIndex])
    }
}

/// "20 Mb/s" / "5.5 Mb/s" — whole numbers without a decimal.
func gpFormatBitrate(_ kbps: Int) -> String {
    let mbps = Double(kbps) / 1000.0
    if mbps == mbps.rounded() {
        return "\(Int(mbps)) Mb/s"
    }
    return String(format: "%.1f Mb/s", mbps)
}

func gpSegmented(items: [String]) -> UISegmentedControl {    let segmented = GPGuardedSegmentedControl(items: items)
    segmented.selectedSegmentTintColor = GPColor.accent
    segmented.backgroundColor = GPColor.panelRaised
    segmented.setTitleTextAttributes([.foregroundColor: GPColor.textPrimary,
                                      .font: GPFont.body(13, weight: .semibold)], for: .normal)
    segmented.setTitleTextAttributes([.foregroundColor: GPColor.onAccent,
                                      .font: GPFont.body(13, weight: .bold)], for: .selected)
    return segmented
}
