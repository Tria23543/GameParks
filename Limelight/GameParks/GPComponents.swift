//
//  GPComponents.swift
//  GameParks
//
//  Shared building blocks for the GameParks screens. Deliberately
//  plain UIKit: every tappable element is a UIControl or UIButton
//  (their touch handling is the most reliable iOS offers), every
//  screen scrolls a single vertical stack, and every pushed screen
//  carries its own visible back control in its header.
//

import UIKit

// MARK: - Base view controller

class GPBaseViewController: UIViewController, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let contentStack = UIStackView()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GPColor.background
        installScaffold()
    }

    /// Pins the scroll view to the safe area and the stack inside it
    /// with the design's 20pt side padding.
    func installScaffold() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Upstream sets the same on its scroll views: touches must
        // reach controls without the scroll view sitting on them.
        scrollView.delaysContentTouches = false
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    /// The design's screen header: big title, optional subtitle, and
    /// — on pushed screens — a visible Back button in the layout
    /// itself (the navigation bar is hidden in this app).
    func makeHeader(title: String, subtitle: String? = nil, showsBack: Bool = false) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4

        if showsBack {
            let back = GPGuardedButton(type: .system)
            back.setTitle("‹  Back", for: .normal)
            back.setTitleColor(GPColor.accent, for: .normal)
            back.titleLabel?.font = GPFont.body(16, weight: .semibold)
            back.contentHorizontalAlignment = .left
            back.addTarget(self, action: #selector(gpGoBack), for: .touchUpInside)
            var backConstraints: [NSLayoutConstraint] = []
            back.translatesAutoresizingMaskIntoConstraints = false
            backConstraints.append(back.heightAnchor.constraint(greaterThanOrEqualToConstant: 36))
            container.addArrangedSubview(back)
            NSLayoutConstraint.activate(backConstraints)
        }

        container.addArrangedSubview(gpLabel(title, font: GPFont.display(28, weight: .extrabold), color: GPColor.textPrimary, lines: 2))
        if let subtitle = subtitle {
            container.addArrangedSubview(gpLabel(subtitle, font: GPFont.body(14), color: GPColor.textSecondary, lines: 2))
        }
        return container
    }

    @objc func gpGoBack() {
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    func presentAlert(title: String, message: String, buttonTitle: String = "OK") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: .default))
        present(alert, animated: true)
    }

    /// Manual host add, upstream's addHostClicked pattern with
    /// GameParks wording: an address field, then the engine's own
    /// discoverHost does the validation.
    func presentAddByAddress() {
        let alert = UIAlertController(
            title: "Add your PC by address",
            message: "If GameParks doesn't find your PC automatically, enter its IP address here.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "192.168.1.100"
            field.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let address = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                self.presentAlert(title: "Invalid address", message: "Enter the PC's IP address, for example 192.168.1.100.")
                return
            }
            GPSessionController.shared().addHost(atAddress: address) { success, error in
                if !success {
                    self.presentAlert(title: "PC not found",
                                      message: error ?? "No GameStream PC answered at that address. Check the address and that Sunshine is running.")
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Scroll-aware content rebuilds

    private var contentRebuildPending = false
    private var flushRecheckScheduled = false

    /// Screens override this to (re)build their dynamic content.
    /// Notification handlers must not call it directly — they go
    /// through requestContentRebuild() so a background refresh can
    /// never tear the screen down mid-scroll or mid-tap.
    func rebuildContent() {}

    /// Whether scrolling is in progress somewhere beyond the
    /// scaffold's own scroll view (Home's horizontal rails).
    var supplementaryScrollBusy: Bool { false }

    private var scrollBusy: Bool {
        return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
            || supplementaryScrollBusy
    }

    /// The notification-driven refresh entry point. While the user
    /// is dragging, coasting, or even just holding a finger on a
    /// row, the rebuild is held until the interaction fully ends:
    /// rebuilding mid-gesture destroys the view under the finger
    /// (killing or misfiring the tap) and stalls the scroll with a
    /// full teardown-and-layout pass.
    func requestContentRebuild() {
        if scrollBusy {
            contentRebuildPending = true
            scheduleFlushRecheck()
            return
        }
        performContentRebuild()
    }

    /// Rebuilds now, keeping the user's place: the scroll offset is
    /// restored afterwards (clamped to the new content size), so a
    /// background refresh never makes the page jump.
    func performContentRebuild() {
        contentRebuildPending = false
        let offsetY = scrollView.contentOffset.y
        rebuildContent()
        view.layoutIfNeeded()
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height
                       + scrollView.adjustedContentInset.bottom)
        scrollView.contentOffset.y = min(max(offsetY, minY), maxY)
    }

    private func flushPendingContentRebuild() {
        if contentRebuildPending && !scrollBusy {
            performContentRebuild()
        }
    }

    /// A deferred rebuild normally flushes from the scroll-end
    /// delegate callbacks below. A touch that never becomes a drag
    /// (a held finger) produces no such callback, so a deferred
    /// rebuild also re-checks shortly after being held — and keeps
    /// re-checking while the interaction genuinely continues.
    private func scheduleFlushRecheck() {
        guard !flushRecheckScheduled else { return }
        flushRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.flushRecheckScheduled = false
            if self.contentRebuildPending && self.scrollBusy {
                self.scheduleFlushRecheck()
            } else {
                self.flushPendingContentRebuild()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            flushPendingContentRebuild()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushPendingContentRebuild()
    }
}

// MARK: - Scroll-safe controls

/// Remembers where every scroll view above a control stood when a
/// touch began. To a plain UIControl, a tap and the start of a
/// scroll feel identical until the finger moves — and if the touch
/// ends before the scroll view's pan recogniser takes over (a slow
/// drag, or a swipe at the content's edge where the content cannot
/// move), the control sees an ordinary touch-up inside itself and
/// fires, even though the user was scrolling. Comparing the scroll
/// offsets before and after tells the two apart exactly.
final class GPScrollGuard {
    private var snapshots: [(scrollView: UIScrollView, offset: CGPoint)] = []
    private let movementThreshold: CGFloat = 6

    func begin(for view: UIView) {
        snapshots.removeAll()
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                snapshots.append((scrollView, scrollView.contentOffset))
            }
            ancestor = current.superview
        }
    }

    var contentScrolled: Bool {
        return snapshots.contains { entry in
            abs(entry.scrollView.contentOffset.x - entry.offset.x) > movementThreshold
                || abs(entry.scrollView.contentOffset.y - entry.offset.y) > movementThreshold
        }
    }

    func reset() {
        snapshots.removeAll()
    }
}

/// A UIControl that never fires its action for a touch that turned
/// into a scroll drag: if any scroll view above it moved during the
/// touch, the touch ends as a cancellation instead of a touch-up.
/// A genuine tap (no scroll movement) fires exactly as before.
class GPGuardedControl: UIControl {
    private let scrollGuard = GPScrollGuard()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.begin(for: self)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if scrollGuard.contentScrolled {
            super.touchesCancelled(touches, with: event)
        } else {
            super.touchesEnded(touches, with: event)
        }
        scrollGuard.reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.reset()
        super.touchesCancelled(touches, with: event)
    }
}

/// The same scroll-safety for segmented controls (same overrides
/// as GPGuardedControl — Swift gives the UIKit base classes no
/// shared implementation point). A segmented control changes a
/// setting, so a scroll gesture must never be able to move it.
class GPGuardedSegmentedControl: UISegmentedControl {
    private let scrollGuard = GPScrollGuard()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.begin(for: self)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if scrollGuard.contentScrolled {
            super.touchesCancelled(touches, with: event)
        } else {
            super.touchesEnded(touches, with: event)
        }
        scrollGuard.reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.reset()
        super.touchesCancelled(touches, with: event)
    }
}

/// The same scroll-safety for steppers: a resting or dragging
/// finger on the stepper must not be able to change the value.
class GPGuardedStepper: UIStepper {
    private let scrollGuard = GPScrollGuard()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.begin(for: self)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if scrollGuard.contentScrolled {
            super.touchesCancelled(touches, with: event)
        } else {
            super.touchesEnded(touches, with: event)
        }
        scrollGuard.reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.reset()
        super.touchesCancelled(touches, with: event)
    }
}

/// The same scroll-safety for buttons (same overrides as
/// GPGuardedControl — Swift gives the two UIKit base classes no
/// shared implementation point).
class GPGuardedButton: UIButton {
    private let scrollGuard = GPScrollGuard()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.begin(for: self)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if scrollGuard.contentScrolled {
            super.touchesCancelled(touches, with: event)
        } else {
            super.touchesEnded(touches, with: event)
        }
        scrollGuard.reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollGuard.reset()
        super.touchesCancelled(touches, with: event)
    }
}

// MARK: - Buttons

func gpPrimaryButton(_ title: String) -> UIButton {
    let button = GPGuardedButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(GPColor.onAccent, for: .normal)
    button.titleLabel?.font = GPFont.display(16, weight: .bold)
    button.backgroundColor = GPColor.accent
    button.layer.cornerRadius = 14
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: 52).isActive = true
    return button
}

func gpSecondaryButton(_ title: String) -> UIButton {
    let button = GPGuardedButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(GPColor.textPrimary, for: .normal)
    button.titleLabel?.font = GPFont.body(15, weight: .semibold)
    button.backgroundColor = GPColor.panelRaised
    button.layer.cornerRadius = 14
    button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    return button
}

// MARK: - Card button

/// A tappable panel card. Content goes into `stack`.
final class GPCardButton: GPGuardedControl {
    let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 20
        stack.axis = .vertical
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.75 : 1.0 }
    }
}

// MARK: - Rows

/// A tappable settings/list row: title, subtitle, optional value and
/// chevron.
final class GPRow: GPGuardedControl {
    let titleLabel = gpLabel(nil, font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1)
    let subtitleLabel = gpLabel(nil, font: GPFont.body(13), color: GPColor.textSecondary, lines: 2)
    let valueLabel = gpLabel(nil, font: GPFont.body(14, weight: .semibold), color: GPColor.textSecondary, lines: 1)
    private let chevronLabel = gpLabel("›", font: GPFont.display(20, weight: .bold), color: GPColor.textFaint, lines: 1)

    init(showsChevron: Bool = true) {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 16

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.isUserInteractionEnabled = false

        let row = UIStackView(arrangedSubviews: [textStack, valueLabel])
        if showsChevron {
            row.addArrangedSubview(chevronLabel)
        }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        subtitleLabel.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = (subtitle == nil || subtitle!.isEmpty)
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.75 : 1.0 }
    }
}

/// A row with a switch. The whole row is the control; the switch is
/// display-only, so a tap anywhere flips it.
final class GPSwitchRow: GPGuardedControl {
    let titleLabel = gpLabel(nil, font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 1)
    let subtitleLabel = gpLabel(nil, font: GPFont.body(13), color: GPColor.textSecondary, lines: 2)
    let toggle = UISwitch()
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 16

        toggle.onTintColor = GPColor.accent
        toggle.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.isUserInteractionEnabled = false

        let row = UIStackView(arrangedSubviews: [textStack, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        subtitleLabel.isHidden = true
        addTarget(self, action: #selector(rowTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = (subtitle == nil || subtitle!.isEmpty)
        }
    }

    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }

    @objc private func rowTapped() {
        toggle.isOn.toggle()
        onToggle?(toggle.isOn)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : 1.0 }
    }
}

// MARK: - Section header

func gpSectionHeader(_ title: String, subtitle: String? = nil) -> UIView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 2
    stack.addArrangedSubview(gpLabel(title, font: GPFont.display(19, weight: .bold), color: GPColor.textPrimary, lines: 1))
    if let subtitle = subtitle {
        stack.addArrangedSubview(gpLabel(subtitle, font: GPFont.body(13), color: GPColor.textSecondary, lines: 1))
    }
    return stack
}

// MARK: - Poster

/// A game poster: bundled cover art when we have it, otherwise a
/// title tile in the design's panel tone. Fixed 2:3-ish art area.
final class GPPosterView: GPGuardedControl {
    private let artContainer = UIView()
    private let imageView = UIImageView()
    private let tileLabel = gpLabel(nil, font: GPFont.display(15, weight: .bold), color: GPColor.textPrimary, lines: 3)
    let nameLabel = gpLabel(nil, font: GPFont.body(13, weight: .semibold), color: GPColor.textPrimary, lines: 2)
    let subtitleLabel = gpLabel(nil, font: GPFont.body(11), color: GPColor.textSecondary, lines: 1)

    init() {
        super.init(frame: .zero)
        artContainer.backgroundColor = GPColor.panelRaised
        artContainer.layer.cornerRadius = 14
        artContainer.clipsToBounds = true
        artContainer.isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        artContainer.addSubview(imageView)

        tileLabel.textAlignment = .center
        tileLabel.translatesAutoresizingMaskIntoConstraints = false
        artContainer.addSubview(tileLabel)

        let stack = UIStackView(arrangedSubviews: [artContainer, nameLabel, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            artContainer.heightAnchor.constraint(equalTo: artContainer.widthAnchor, multiplier: 1.42),
            imageView.topAnchor.constraint(equalTo: artContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: artContainer.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: artContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: artContainer.trailingAnchor),
            tileLabel.centerYAnchor.constraint(equalTo: artContainer.centerYAnchor),
            tileLabel.leadingAnchor.constraint(equalTo: artContainer.leadingAnchor, constant: 10),
            tileLabel.trailingAnchor.constraint(equalTo: artContainer.trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, subtitle: String?, cover: UIImage?) {
        nameLabel.text = name
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle == nil)
        if let cover = cover {
            imageView.image = cover
            imageView.isHidden = false
            tileLabel.isHidden = true
        } else {
            imageView.image = nil
            imageView.isHidden = true
            tileLabel.text = name
            tileLabel.isHidden = false
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.75 : 1.0 }
    }
}

/// A horizontal app row for lists: small art, name, source line,
/// chevron.
final class GPAppRow: GPGuardedControl {
    private let imageView = UIImageView()
    private let tileView = UIView()
    private let tileLabel = gpLabel(nil, font: GPFont.display(11, weight: .bold), color: GPColor.textPrimary, lines: 2)
    let nameLabel = gpLabel(nil, font: GPFont.body(15, weight: .semibold), color: GPColor.textPrimary, lines: 1)
    let subtitleLabel = gpLabel(nil, font: GPFont.body(12), color: GPColor.textSecondary, lines: 1)

    init() {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 16

        let art = UIView()
        art.layer.cornerRadius = 10
        art.clipsToBounds = true
        art.backgroundColor = GPColor.panelRaised
        art.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        art.addSubview(imageView)
        tileLabel.textAlignment = .center
        tileLabel.translatesAutoresizingMaskIntoConstraints = false
        art.addSubview(tileLabel)

        let textStack = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let chevron = gpLabel("›", font: GPFont.display(20, weight: .bold), color: GPColor.textFaint, lines: 1)

        let row = UIStackView(arrangedSubviews: [art, textStack, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            art.widthAnchor.constraint(equalToConstant: 46),
            art.heightAnchor.constraint(equalToConstant: 62),
            imageView.topAnchor.constraint(equalTo: art.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: art.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: art.trailingAnchor),
            tileLabel.centerYAnchor.constraint(equalTo: art.centerYAnchor),
            tileLabel.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: 3),
            tileLabel.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -3),
        ])
        tileView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, subtitle: String?, cover: UIImage?) {
        nameLabel.text = name
        subtitleLabel.text = subtitle
        if let cover = cover {
            imageView.image = cover
            imageView.isHidden = false
            tileLabel.isHidden = true
        } else {
            imageView.image = nil
            imageView.isHidden = true
            tileLabel.text = name
            tileLabel.isHidden = false
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.75 : 1.0 }
    }
}

// MARK: - Chips

final class GPChipButton: GPGuardedButton {
    var chipSelected: Bool = false {
        didSet { refreshStyle() }
    }

    init(title: String) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = GPFont.body(13, weight: .semibold)
        layer.cornerRadius = 16
        contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        refreshStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshStyle() {
        if chipSelected {
            backgroundColor = GPColor.accent
            setTitleColor(GPColor.onAccent, for: .normal)
        } else {
            backgroundColor = GPColor.panelRaised
            setTitleColor(GPColor.textPrimary, for: .normal)
        }
    }
}

// MARK: - Empty / message state

/// A panel that explains a state and offers the way forward — the
/// app never shows a silent blank screen.
final class GPMessageView: UIView {
    let titleLabel = gpLabel(nil, font: GPFont.display(17, weight: .bold), color: GPColor.textPrimary, lines: 0)
    let messageLabel = gpLabel(nil, font: GPFont.body(14), color: GPColor.textSecondary, lines: 0)
    let actionButton = gpSecondaryButton("Retry")

    init() {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 20
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, message: String, actionTitle: String?) {
        titleLabel.text = title
        messageLabel.text = message
        if let actionTitle = actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }
}
