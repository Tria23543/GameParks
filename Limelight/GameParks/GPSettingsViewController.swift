//
//  GPSettingsViewController.swift
//  GameParks
//
//  The design's Settings: stream presets, the stream knobs, the
//  controls, and the hosts list. Every value lives in the engine's
//  own settings store (DataManager), because that is what the
//  stream configuration is built from — GPSettingsStore writes
//  through it, preserving the fields GameParks doesn't manage.
//  The three design toggles that have no engine setting behind
//  them (Video filters, Microphone, Anti-deadzone) persist as
//  GameParks preferences, as they did in earlier versions.
//

import UIKit
import GameController

enum GPSettingsStore {
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
        guard let cur = current() else { return }
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
    }

    static let presets: [Preset] = [
        Preset(title: "Home Wi-Fi", detail: "1080p · 60 fps · 20 Mb/s · Auto codec",
               width: 1920, height: 1080, fps: 60, bitrateKbps: 20000),
        Preset(title: "Mobile data saver", detail: "720p · 30 fps · 8 Mb/s",
               width: 1280, height: 720, fps: 30, bitrateKbps: 8000),
        Preset(title: "Cloud — best quality", detail: "1080p HQ · 60 fps · 25 Mb/s",
               width: 1920, height: 1080, fps: 60, bitrateKbps: 25000),
    ]

    static func activePresetIndex() -> Int? {
        guard let cur = current() else { return nil }
        for (index, preset) in presets.enumerated() {
            if cur.width?.intValue == preset.width && cur.height?.intValue == preset.height
                && cur.framerate?.intValue == preset.fps && cur.bitrate?.intValue == preset.bitrateKbps {
                return index
            }
        }
        return nil
    }

    static func applyPreset(_ index: Int) {
        let preset = presets[index]
        save(width: preset.width, height: preset.height, fps: preset.fps, bitrateKbps: preset.bitrateKbps)
    }
}

final class GPSettingsViewController: GPBaseViewController {
    private var session: GPSessionController { GPSessionController.shared() }

    private let dynamicStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .GPHostsChanged, object: nil)
        rebuildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        performContentRebuild()
    }

    @objc private func stateChanged() {
        requestContentRebuild()
    }

    override func rebuildContent() {
        // The header carries the pairing state, so rebuild it too:
        // it is the scaffold's first arranged view.
        if let first = contentStack.arrangedSubviews.first, first !== dynamicStack {
            first.removeFromSuperview()
        }
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let session = GPSessionController.shared()
        let host = session.selectedHost ?? session.hosts.first
        let subtitle = host != nil && host!.pairState == .paired
            ? "GameParks · paired to \(host!.name ?? "your PC")"
            : "GameParks"
        contentStack.insertArrangedSubview(makeHeader(title: "Settings", subtitle: subtitle), at: 0)

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
            ("Resolution", cur?.height?.intValue == 1080 ? "1080p HQ — your settled pick" : nil,
             resolutionText.replacingOccurrences(of: "×", with: "×")),
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

        let oscRow = GPSwitchRow()
        oscRow.titleLabel.text = "On-screen controls"
        oscRow.subtitle = "Auto — hides when a controller is connected"
        oscRow.isOn = (cur?.onscreenControls?.intValue ?? 0) != 0
        oscRow.onToggle = { isOn in GPSettingsStore.save(onscreenControls: isOn ? 1 : 0) }
        dynamicStack.addArrangedSubview(oscRow)

        let deadzoneRow = GPSwitchRow()
        deadzoneRow.titleLabel.text = "Anti-deadzone"
        deadzoneRow.subtitle = "Fixes loose-stick drift"
        deadzoneRow.isOn = UserDefaults.standard.bool(forKey: "GPAntiDeadzone")
        deadzoneRow.onToggle = { isOn in UserDefaults.standard.set(isOn, forKey: "GPAntiDeadzone") }
        dynamicStack.addArrangedSubview(deadzoneRow)

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
            row.accessibilityIdentifier = knownHost.uuid
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
        cloudRow.subtitle = "Add later — same app, same library"
        cloudRow.valueLabel.text = "Add"
        cloudRow.addTarget(self, action: #selector(cloudTapped), for: .touchUpInside)
        dynamicStack.addArrangedSubview(cloudRow)
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
        guard let uuid = sender.accessibilityIdentifier,
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

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(makeHeader(title: "Stream settings",
                                                   subtitle: "Picture & sound", showsBack: true))
        dynamicStack.axis = .vertical
        dynamicStack.spacing = 16
        contentStack.addArrangedSubview(dynamicStack)
        rebuildContent()
    }

    override func rebuildContent() {
        dynamicStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cur = GPSettingsStore.current()

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

        let resolution = gpSegmented(items: ["720p", "1080p", "4K"])
        resolution.selectedSegmentIndex = (cur?.height?.intValue ?? 1080) >= 2160 ? 2
            : ((cur?.height?.intValue ?? 1080) >= 1080 ? 1 : 0)
        resolution.addTarget(self, action: #selector(resolutionChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Resolution", control: resolution))

        let frameRate = gpSegmented(items: ["30", "60", "120"])
        frameRate.selectedSegmentIndex = [30, 60, 120].firstIndex(of: cur?.framerate?.intValue ?? 60) ?? 1
        frameRate.addTarget(self, action: #selector(frameRateChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Frame rate", control: frameRate))

        let codec = gpSegmented(items: ["Auto", "H.265", "H.264"])
        let codecPref = cur != nil ? GPSettingsStore.codecPref(of: cur!) : 0
        codec.selectedSegmentIndex = codecPref == 2 ? 1 : (codecPref == 1 ? 2 : 0)
        codec.addTarget(self, action: #selector(codecChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Codec", control: codec))

        // Bitrate stepper card
        let bitrateCard = UIView()
        bitrateCard.backgroundColor = GPColor.panel
        bitrateCard.layer.cornerRadius = 16
        let bitrateValue = gpLabel("\(Int((Double(cur?.bitrate?.intValue ?? 20000) / 1000.0).rounded())) Mb/s",
                                   font: GPFont.body(15, weight: .semibold), color: GPColor.textPrimary, lines: 1)
        bitrateValue.tag = 77
        let stepper = GPGuardedStepper()
        stepper.minimumValue = 5
        stepper.maximumValue = 40
        stepper.stepValue = 1
        stepper.value = Double(cur?.bitrate?.intValue ?? 20000) / 1000.0
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

        let filtersRow = GPSwitchRow()
        filtersRow.titleLabel.text = "Video filters"
        filtersRow.subtitle = "Sharpen · colour boost"
        filtersRow.isOn = UserDefaults.standard.bool(forKey: "GPVideoFilters")
        filtersRow.onToggle = { isOn in UserDefaults.standard.set(isOn, forKey: "GPVideoFilters") }
        dynamicStack.addArrangedSubview(filtersRow)

        let micRow = GPSwitchRow()
        micRow.titleLabel.text = "Microphone"
        micRow.subtitle = "Voice chat passthrough"
        micRow.isOn = UserDefaults.standard.bool(forKey: "GPMicrophone")
        micRow.onToggle = { isOn in UserDefaults.standard.set(isOn, forKey: "GPMicrophone") }
        dynamicStack.addArrangedSubview(micRow)

        let surround = gpSegmented(items: ["Stereo", "5.1", "7.1"])
        surround.selectedSegmentIndex = (cur?.audioConfig?.intValue ?? 2) >= 8 ? 2
            : ((cur?.audioConfig?.intValue ?? 2) >= 6 ? 1 : 0)
        surround.addTarget(self, action: #selector(surroundChanged(_:)), for: .valueChanged)
        dynamicStack.addArrangedSubview(controlCard(title: "Surround audio", control: surround))

        // Why Auto — the design's own explanation, verbatim.
        let whyCard = UIView()
        whyCard.backgroundColor = GPColor.panel
        whyCard.layer.cornerRadius = 16
        let whyStack = UIStackView(arrangedSubviews: [
            gpLabel("Why Auto?", font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1),
            gpLabel("Forcing H.265 made streams hang on XStreaming. Auto picks the best codec your phone and PC agree on — every time.",
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
        switch sender.selectedSegmentIndex {
        case 0: GPSettingsStore.save(width: 1280, height: 720)
        case 2: GPSettingsStore.save(width: 3840, height: 2160)
        default: GPSettingsStore.save(width: 1920, height: 1080)
        }
    }

    @objc private func frameRateChanged(_ sender: UISegmentedControl) {
        GPSettingsStore.save(fps: [30, 60, 120][sender.selectedSegmentIndex])
    }

    @objc private func codecChanged(_ sender: UISegmentedControl) {
        let prefs: [UInt32] = [0, 2, 1] // Auto, H.265 (HEVC), H.264
        GPSettingsStore.save(codec: prefs[sender.selectedSegmentIndex])
    }

    @objc private func bitrateChanged(_ sender: UIStepper) {
        GPSettingsStore.save(bitrateKbps: Int(sender.value) * 1000)
        if let card = sender.superview, let value = card.viewWithTag(77) as? UILabel {
            value.text = "\(Int(sender.value)) Mb/s"
        }
    }

    @objc private func surroundChanged(_ sender: UISegmentedControl) {
        GPSettingsStore.save(audioChannels: [2, 6, 8][sender.selectedSegmentIndex])
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
