//
//  GPSettingsViewController.swift
//  GameParks
//
//  Settings in the approved design: stream presets, the Stream
//  section (resolution, bitrate, codec — Auto, never forced — frame
//  rate), the "Why Auto?" explainer, Controls, and Hosts.
//

import UIKit

final class GPSettingsViewController: GPBaseViewController {
    private let stack = UIStackView()

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private struct StreamState {
        var width = 1920
        var height = 1080
        var fps = 60
        var bitrateKbps = 20000
        var codec: UInt32 = 0
        var statsOverlay = true
        var audioChannels = 2
        var onscreenControls = 2
    }
    private var state = StreamState()

    private let presets: [(name: String, detail: String, width: Int, height: Int, fps: Int, bitrate: Int)] = [
        ("Home Wi-Fi", "1080p · 60 fps · 20 Mb/s · Auto codec", 1920, 1080, 60, 20000),
        ("Mobile data saver", "720p · 30 fps · 8 Mb/s", 1280, 720, 30, 8000),
        ("Cloud — best quality", "1080p HQ · 60 fps · 25 Mb/s", 1920, 1080, 60, 25000),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 20, bottom: 28, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .gpHostsChanged, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    private func loadState() {
        // Start from defaults every load: if the stored settings are
        // ever unavailable, the screen must not render (or re-save)
        // stale values from a previous load.
        state = StreamState()
        let engine = GPEngine.shared
        if let settings = engine.currentSettings() {
            state.width = settings.width?.intValue ?? 1920
            state.height = settings.height?.intValue ?? 1080
            state.fps = settings.framerate?.intValue ?? 60
            state.bitrateKbps = settings.bitrate?.intValue ?? 20000
            state.statsOverlay = settings.statsOverlay
            state.audioChannels = settings.audioConfig?.intValue ?? 2
            state.onscreenControls = settings.onscreenControls?.intValue ?? 2
        }
        // Clamp: a corrupt or legacy stored preference must not trap
        // the UInt32 conversion and crash Settings on load.
        state.codec = UInt32(max(0, min(3, engine.currentCodecPref())))
    }

    private func persist() {
        GPEngine.shared.saveStreamSettings(width: state.width, height: state.height, fps: state.fps,
                                           bitrateKbps: state.bitrateKbps, codec: state.codec,
                                           statsOverlay: state.statsOverlay, audioChannels: state.audioChannels,
                                           onscreenControls: state.onscreenControls)
    }

    @objc private func rebuild() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
            return
        }
        guard isViewLoaded else { return }
        loadState()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let engine = GPEngine.shared
        let host = engine.selectedHost

        // Header
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 3
        header.addArrangedSubview(GPLabel("Settings", font: GPTheme.display(26, weight: .extrabold), color: GPTheme.ink))
        let headerSubtitleText: String
        if let host = host {
            headerSubtitleText = host.pairState == .paired ? "GameParks · paired to \(host.name)" : "GameParks · \(host.name) is not paired yet"
        } else {
            headerSubtitleText = "GameParks · no PC paired yet"
        }
        header.addArrangedSubview(GPLabel(headerSubtitleText,
                                          font: GPTheme.body(13, weight: .semibold), color: GPTheme.mut, lines: 2))
        stack.addArrangedSubview(header)

        // Stream presets
        stack.addArrangedSubview(sectionTitle("Stream presets"))
        for (index, preset) in presets.enumerated() {
            stack.addArrangedSubview(makePresetCard(index: index, preset: preset))
        }

        // Stream
        stack.addArrangedSubview(sectionTitle("Stream"))
        let resolutionRow = GPRow(title: "Resolution", subtitle: resolutionSubtitle(), value: resolutionName())
        resolutionRow.addTarget(self, action: #selector(resolutionTapped), for: .touchUpInside)
        stack.addArrangedSubview(resolutionRow)

        let bitrateRow = GPRow(title: "Bitrate", subtitle: "Higher = sharper picture", value: bitrateText())
        bitrateRow.addTarget(self, action: #selector(bitrateTapped), for: .touchUpInside)
        stack.addArrangedSubview(bitrateRow)

        let codecRow = GPRow(title: "Codec", subtitle: "Auto recommended", value: codecName())
        codecRow.addTarget(self, action: #selector(codecTapped), for: .touchUpInside)
        stack.addArrangedSubview(codecRow)

        let fpsRow = GPRow(title: "Frame rate", subtitle: nil, value: "\(state.fps) fps")
        fpsRow.addTarget(self, action: #selector(fpsTapped), for: .touchUpInside)
        stack.addArrangedSubview(fpsRow)

        stack.addArrangedSubview(makeWhyAutoCard())

        let filtersRow = GPRow(title: "Video filters", subtitle: "Sharpen · colour boost")
        filtersRow.showsToggle = true
        filtersRow.toggle.isOn = UserDefaults.standard.bool(forKey: "GPVideoFilters")
        filtersRow.toggle.addTarget(self, action: #selector(filtersToggled(_:)), for: .valueChanged)
        stack.addArrangedSubview(filtersRow)

        let micRow = GPRow(title: "Microphone", subtitle: "Voice chat passthrough")
        micRow.showsToggle = true
        micRow.toggle.isOn = UserDefaults.standard.bool(forKey: "GPMicrophone")
        micRow.toggle.addTarget(self, action: #selector(micToggled(_:)), for: .valueChanged)
        stack.addArrangedSubview(micRow)

        let surroundRow = GPRow(title: "Surround audio", subtitle: "Surround passthrough", value: surroundName())
        surroundRow.addTarget(self, action: #selector(surroundTapped), for: .touchUpInside)
        stack.addArrangedSubview(surroundRow)

        // Controls
        stack.addArrangedSubview(sectionTitle("Controls"))
        let controllerRow = GPRow(title: "Bluetooth controller",
                                  subtitle: engine.bluetoothControllerConnected ? "Connected · Xbox layout" : "Not connected — pair it in iOS Settings",
                                  value: engine.bluetoothControllerConnected ? "Paired" : "")
        controllerRow.showsChevron = false // Status only — nothing to open.
        stack.addArrangedSubview(controllerRow)

        let oscRow = GPRow(title: "On-screen controls", subtitle: "Touch sticks & buttons", value: oscName())
        oscRow.addTarget(self, action: #selector(oscTapped), for: .touchUpInside)
        stack.addArrangedSubview(oscRow)

        let deadzoneRow = GPRow(title: "Anti-deadzone", subtitle: "Fixes loose-stick drift")
        deadzoneRow.showsToggle = true
        deadzoneRow.toggle.isOn = UserDefaults.standard.bool(forKey: "GPAntiDeadzone")
        deadzoneRow.toggle.addTarget(self, action: #selector(deadzoneToggled(_:)), for: .valueChanged)
        stack.addArrangedSubview(deadzoneRow)

        let overlayRow = GPRow(title: "Stats overlay", subtitle: "Ping · fps · bitrate in-game")
        overlayRow.showsToggle = true
        overlayRow.toggle.isOn = state.statsOverlay
        overlayRow.toggle.addTarget(self, action: #selector(overlayToggled(_:)), for: .valueChanged)
        stack.addArrangedSubview(overlayRow)

        // Hosts
        stack.addArrangedSubview(sectionTitle("Hosts"))
        if let host = host {
            let hostSubtitle: String
            // Bind the ping ONCE: samples update asynchronously, and
            // the old code evaluated ping(for:) twice and force-
            // unwrapped the second result — a crash if they cleared
            // in between.
            let ping = engine.ping(for: host)
            switch (host.state, host.pairState) {
            case (.online, .paired):
                hostSubtitle = "Paired · Sunshine\(ping.map { " · \($0) ms" } ?? "")"
            case (.online, _):
                hostSubtitle = "Online · not paired"
            case (.offline, _):
                hostSubtitle = "Asleep · tap to wake"
            default:
                hostSubtitle = "Searching…"
            }
            let hostRow = GPRow(title: host.name,
                                subtitle: hostSubtitle,
                                value: "Manage")
            hostRow.addTarget(self, action: #selector(manageHostTapped), for: .touchUpInside)
            stack.addArrangedSubview(hostRow)
        }
        let cloudRow = GPRow(title: "Cloud PC", subtitle: "Add later — same app, same library", value: "Add")
        cloudRow.addTarget(self, action: #selector(cloudTapped), for: .touchUpInside)
        stack.addArrangedSubview(cloudRow)

        let addRow = GPRow(title: "Add a PC by address", subtitle: "If your PC does not appear automatically")
        addRow.addTarget(self, action: #selector(addByAddressTapped), for: .touchUpInside)
        stack.addArrangedSubview(addRow)
    }

    private func sectionTitle(_ text: String) -> UIView {
        let label = GPLabel(text, font: GPTheme.display(16, weight: .bold), color: GPTheme.ink)
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makePresetCard(index: Int, preset: (name: String, detail: String, width: Int, height: Int, fps: Int, bitrate: Int)) -> UIView {
        var active = state.width == preset.width && state.height == preset.height && state.fps == preset.fps && state.bitrateKbps == preset.bitrate
        if index == 0 {
            // The Home Wi-Fi preset's detail promises "Auto codec":
            // it is only active when the codec really is Auto.
            active = active && state.codec == 0
        }
        let card = UIControl()
        card.tag = index
        card.backgroundColor = GPTheme.panel
        card.round(16)
        card.layer.borderWidth = active ? 1.5 : 0
        card.layer.borderColor = GPTheme.accent.cgColor
        card.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)

        let nameLabel = GPLabel(preset.name, font: GPTheme.body(15, weight: .bold), color: GPTheme.ink)
        let detailLabel = GPLabel(preset.detail, font: GPTheme.body(12.5, weight: .semibold), color: GPTheme.mut)
        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textStack)

        let activeLabel = GPLabel(active ? "Active" : "", font: GPTheme.body(12, weight: .extrabold), color: GPTheme.accent)
        activeLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(activeLabel)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            activeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            activeLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func makeWhyAutoCard() -> UIView {
        let card = UIView()
        card.backgroundColor = GPTheme.accentSoft
        card.round(16)
        let title = GPLabel("Why Auto?", font: GPTheme.body(14, weight: .extrabold), color: GPTheme.accent)
        let body = GPLabel("Forcing H.265 made streams hang on XStreaming. Auto picks the best codec your phone and PC agree on — every time.",
                           font: GPTheme.body(13, weight: .semibold), color: GPTheme.ink, lines: 0)
        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 5
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    // MARK: - Value helpers

    private func resolutionName() -> String {
        switch state.height {
        case 720: return "720p"
        case 1080: return "1080p"
        case 2160: return "4K"
        default: return "\(state.height)p"
        }
    }

    private func resolutionSubtitle() -> String {
        if state.width == 1920 && state.height == 1080 {
            return "1080p HQ — your settled pick"
        }
        return "Stream resolution"
    }

    private func codecName() -> String {
        switch state.codec {
        case 1: return "H.264"
        case 2: return "H.265"
        case 3: return "AV1"
        default: return "Auto"
        }
    }

    private func oscName() -> String {
        switch state.onscreenControls {
        case 0: return "Off"
        case 1: return "On"
        default: return "Auto"
        }
    }

    /// "20 Mb/s" for whole values; a stored non-round bitrate (the
    /// legacy front-end's slider could save one) shows one decimal
    /// instead of being silently truncated by integer division.
    private func bitrateText() -> String {
        if state.bitrateKbps % 1000 == 0 {
            return "\(state.bitrateKbps / 1000) Mb/s"
        }
        return String(format: "%.1f Mb/s", locale: Locale(identifier: "en_US_POSIX"), Double(state.bitrateKbps) / 1000.0)
    }

    private func surroundName() -> String {
        switch state.audioChannels {
        case ..<6: return "Stereo"
        case ..<8: return "5.1"
        default: return "7.1"
        }
    }

    // MARK: - Actions

    @objc private func presetTapped(_ sender: UIControl) {
        guard presets.indices.contains(sender.tag) else { return }
        let preset = presets[sender.tag]
        state.width = preset.width
        state.height = preset.height
        state.fps = preset.fps
        state.bitrateKbps = preset.bitrate
        if sender.tag == 0 {
            state.codec = 0 // Home Wi-Fi preset is the Auto-codec one
        }
        persist()
        rebuild()
    }

    private func pickSheet(title: String, options: [(label: String, apply: () -> Void)]) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for option in options {
            sheet.addAction(UIAlertAction(title: option.label, style: .default) { _ in
                option.apply()
                self.persist()
                self.rebuild()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    @objc private func resolutionTapped() {
        pickSheet(title: "Resolution", options: [
            ("720p", { self.state.width = 1280; self.state.height = 720 }),
            ("1080p", { self.state.width = 1920; self.state.height = 1080 }),
            ("4K", { self.state.width = 3840; self.state.height = 2160 }),
        ])
    }

    @objc private func bitrateTapped() {
        let values = [5, 10, 15, 20, 25, 30, 40, 60, 80, 100]
        pickSheet(title: "Bitrate", options: values.map { value in
            ("\(value) Mb/s", { self.state.bitrateKbps = value * 1000 })
        })
    }

    @objc private func codecTapped() {
        pickSheet(title: "Codec", options: [
            ("Auto (recommended)", { self.state.codec = 0 }),
            ("H.265", { self.state.codec = 2 }),
            ("H.264", { self.state.codec = 1 }),
            ("AV1", { self.state.codec = 3 }),
        ])
    }

    @objc private func fpsTapped() {
        pickSheet(title: "Frame rate", options: [
            ("30 fps", { self.state.fps = 30 }),
            ("60 fps", { self.state.fps = 60 }),
            ("120 fps", { self.state.fps = 120 }),
        ])
    }

    @objc private func surroundTapped() {
        pickSheet(title: "Surround audio", options: [
            ("Stereo", { self.state.audioChannels = 2 }),
            ("5.1 surround", { self.state.audioChannels = 6 }),
            ("7.1 surround", { self.state.audioChannels = 8 }),
        ])
    }

    @objc private func oscTapped() {
        pickSheet(title: "On-screen controls", options: [
            ("Auto — show when no controller is connected", { self.state.onscreenControls = 2 }),
            ("On", { self.state.onscreenControls = 1 }),
            ("Off", { self.state.onscreenControls = 0 }),
        ])
    }

    @objc private func overlayToggled(_ sender: UISwitch) {
        state.statsOverlay = sender.isOn
        persist()
    }

    @objc private func deadzoneToggled(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "GPAntiDeadzone")
    }

    @objc private func filtersToggled(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "GPVideoFilters")
    }

    @objc private func micToggled(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "GPMicrophone")
    }

    @objc private func manageHostTapped() {
        guard let host = GPEngine.shared.selectedHost else { return }
        navigationController?.pushViewController(GPHostViewController(host: host), animated: true)
    }

    @objc private func cloudTapped() {
        showMessage(title: "Cloud PC",
                    message: "When your cloud PC is ready, add it here and it joins as a second host — same app, same library, same posters, same settings.")
    }

    @objc private func addByAddressTapped() {
        presentAddByAddress()
    }
}
