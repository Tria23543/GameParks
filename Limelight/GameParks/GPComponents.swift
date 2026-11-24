//
//  GPComponents.swift
//  GameParks
//
//  Shared building blocks in the approved design's language:
//  poster cells, section headers, filter chips, list rows, play button.
//

import UIKit

// MARK: - Poster cell

final class GPPosterCell: UICollectionViewCell {
    static let reuseID = "GPPosterCell"

    let imageView = UIImageView()
    let titleLabel = GPLabel("", font: GPTheme.body(13, weight: .bold), color: GPTheme.ink, lines: 2)
    let subtitleLabel = GPLabel("", font: GPTheme.body(11, weight: .semibold), color: GPTheme.mut)
    let badgeLabel = GPLabel("", font: GPTheme.body(10, weight: .extrabold), color: GPTheme.accentInk)
    private let badgeView = UIView()
    private let placeholderLabel = GPLabel("", font: GPTheme.display(28, weight: .extrabold), color: GPTheme.dim)
    private let miniPlay = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.round(14)
        imageView.backgroundColor = GPTheme.panel2
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        placeholderLabel.textAlignment = .center
        contentView.addSubview(placeholderLabel)

        miniPlay.text = "▶"
        miniPlay.font = GPTheme.body(9, weight: .extrabold)
        miniPlay.textColor = GPTheme.accentInk
        miniPlay.textAlignment = .center
        miniPlay.backgroundColor = GPTheme.accent
        miniPlay.round(11)
        miniPlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(miniPlay)

        badgeView.backgroundColor = GPTheme.accent
        badgeView.round(6)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1.42),

            placeholderLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            miniPlay.widthAnchor.constraint(equalToConstant: 22),
            miniPlay.heightAnchor.constraint(equalToConstant: 22),
            miniPlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -7),
            miniPlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -7),

            badgeView.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            badgeView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -2),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -6),

            textStack.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 7),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(app: TemporaryApp, subtitle: String, badge: String?) {
        titleLabel.text = app.name
        subtitleLabel.text = subtitle
        if let image = GPCoverArt.cover(for: app) {
            imageView.image = image
            placeholderLabel.text = nil
        } else {
            imageView.image = nil
            placeholderLabel.text = String((app.name ?? "?").prefix(1)).uppercased()
        }
        if let badge = badge, !badge.isEmpty {
            badgeView.isHidden = false
            badgeLabel.text = badge
        } else {
            badgeView.isHidden = true
        }
    }
}

// MARK: - Section header

final class GPSectionHeader: UIView {
    init(title: String, subtitle: String? = nil) {
        super.init(frame: .zero)
        let titleLabel = GPLabel(title, font: GPTheme.display(19, weight: .bold), color: GPTheme.ink)
        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .vertical
        stack.spacing = 2
        if let subtitle = subtitle {
            stack.addArrangedSubview(GPLabel(subtitle, font: GPTheme.body(12, weight: .semibold), color: GPTheme.dim))
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Filter chip

final class GPChip: UIButton {
    var chipSelected: Bool = false {
        didSet { refreshStyle() }
    }

    init(title: String) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = GPTheme.body(13, weight: .bold)
        contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        round(99)
        refreshStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refreshStyle() {
        if chipSelected {
            backgroundColor = GPTheme.accent
            setTitleColor(GPTheme.accentInk, for: .normal)
            layer.borderWidth = 0
        } else {
            backgroundColor = GPTheme.panel
            setTitleColor(GPTheme.mut, for: .normal)
            layer.borderWidth = 1
            layer.borderColor = GPTheme.line.cgColor
        }
    }
}

// MARK: - List row (settings / host actions)

final class GPRow: UIControl {
    let titleLabel = GPLabel("", font: GPTheme.body(15, weight: .semibold), color: GPTheme.ink, lines: 2)
    let subtitleLabel = GPLabel("", font: GPTheme.body(12, weight: .semibold), color: GPTheme.mut, lines: 2)
    let valueLabel = GPLabel("", font: GPTheme.body(13, weight: .bold), color: GPTheme.accent)
    let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    let toggle = UISwitch()

    var showsToggle: Bool = false {
        didSet {
            toggle.isHidden = !showsToggle
            refreshChevronVisibility()
            valueLabel.isHidden = showsToggle
        }
    }

    /// Non-interactive status rows (e.g. Bluetooth controller state)
    /// set this false: a chevron promises navigation that isn't there.
    var showsChevron: Bool = true {
        didSet { refreshChevronVisibility() }
    }

    private func refreshChevronVisibility() {
        chevron.isHidden = showsToggle || !showsChevron
    }

    init(title: String, subtitle: String? = nil, value: String? = nil) {
        super.init(frame: .zero)
        backgroundColor = GPTheme.panel
        round(14)

        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle == nil
        valueLabel.text = value
        chevron.tintColor = GPTheme.dim
        chevron.contentMode = .scaleAspectFit
        toggle.onTintColor = GPTheme.accent
        toggle.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        let trailingStack = UIStackView(arrangedSubviews: [valueLabel, chevron, toggle])
        trailingStack.axis = .horizontal
        trailingStack.spacing = 8
        trailingStack.alignment = .center
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])

        // Tapping anywhere on a toggle row flips its switch — the
        // normal iOS Settings gesture. Previously only the small
        // switch itself responded, and row taps did nothing.
        addTarget(self, action: #selector(rowTapped), for: .touchUpInside)
    }

    @objc private func rowTapped() {
        guard showsToggle else { return }
        toggle.setOn(!toggle.isOn, animated: true)
        toggle.sendActions(for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Play button

final class GPPlayButton: UIButton {
    init(title: String) {
        super.init(frame: .zero)
        setTitle("▶  \(title)", for: .normal)
        setTitleColor(GPTheme.accentInk, for: .normal)
        titleLabel?.font = GPTheme.display(17, weight: .extrabold)
        backgroundColor = GPTheme.accent
        round(16)
        contentEdgeInsets = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Base view controller

class GPBaseViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GPTheme.bg
    }

    // GameParks screens are portrait-only (the approved design is a
    // portrait phone UI). Only the stream screen is landscape; the app
    // delegate asks the top view controller for its mask, so returning
    // .portrait here locks every GameParks screen to portrait.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }

    func showMessage(title: String, message: String, button: String = "OK") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: button, style: .default))
        present(alert, animated: true)
    }

    /// Add a PC by typing its address — a primary way to connect, not a
    /// fallback. It probes the PC directly over HTTP
    /// (DiscoveryManager.discoverHost), so it never depends on Bonjour.
    /// That matters because GameParks runs inside LiveContainer: Bonjour
    /// browsing there is governed by the container app's own Info.plist,
    /// not GameParks', so automatic discovery is not guaranteed to work.
    func presentAddByAddress() {
        let alert = UIAlertController(title: "Add a PC by address",
                                      message: "Enter your PC's IP address on your home network (find it in Sunshine on the PC).",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "192.168.1.50"
            field.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            // Trim first: a whitespace-only "address" used to sail
            // through to a misleading "PC not found" error.
            let address = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                self?.showMessage(title: "Invalid address", message: "Enter your PC's IP address on your home network, like 192.168.1.50 — you can find it in Sunshine on the PC.")
                return
            }
            GPEngine.shared.addHost(address: address) { [weak self] success, error in
                if !success {
                    self?.showMessage(title: "PC not found", message: error ?? "No PC answered at that address. Check the address and that Sunshine is running.")
                }
            }
        })
        present(alert, animated: true)
    }
}
