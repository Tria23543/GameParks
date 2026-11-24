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

// MARK: - Scroll view

/// The scroll view every GameParks screen uses. Scroll-safety for
/// the controls inside it is decided HERE, at touch-delivery level
/// — the way Apple's own list UIs do it — not inside the controls:
///
/// 1. `delaysContentTouches` is left at the iOS default (true):
///    the scroll view withholds a touch from the content while it
///    determines whether the gesture is a pan. A gesture that
///    becomes a pan is never delivered to a control at all.
/// 2. `touchesShouldCancel(in:)` returns true for EVERY content
///    view. UIKit's default returns false for UIControl instances,
///    which is why a scroll view normally lets a tracking control
///    keep its touch through a whole scroll and fire on touch-up.
///    With true, the moment the pan recogniser wins, the scroll
///    view cancels the touch inside the control: the control runs
///    its cancellation path, its tracking ends, and no
///    .touchUpInside can ever be dispatched for that touch.
///
/// Together: a scroll gesture either never reaches a control, or
/// is cancelled inside it before the finger lifts. A stationary
/// tap is delivered whole and fires exactly as it always did.
final class GPScrollView: UIScrollView {
    // A-28: the delay/cancel half of the scroll-safety guarantee is a
    // property of this class, set in its initialisers — call sites no
    // longer have to remember it.
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = true
        canCancelContentTouches = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delaysContentTouches = true
        canCancelContentTouches = true
    }

    override func touchesShouldCancel(in contentView: UIView) -> Bool {
        return true
    }
}

// MARK: - Base view controller

class GPBaseViewController: UIViewController, UIScrollViewDelegate {
    let scrollView = GPScrollView()
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
        // iOS default, deliberately: while the scroll view decides
        // whether a touch is a scroll or a tap, the touch is
        // withheld from the rows — a scroll therefore never reaches
        // a row as a press. See GPScrollView above.
        scrollView.delaysContentTouches = true
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
            backConstraints.append(back.heightAnchor.constraint(greaterThanOrEqualToConstant: 44))
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
            GPSessionController.shared().addHost(atAddress: address) { [weak self] success, error in
                guard let self = self else { return }
                if !success {
                    self.presentAlert(title: "PC not found",
                                      message: error ?? "No PC answered at that address. Check the address and that Sunshine is running.")
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Scroll-aware content rebuilds

    private var contentRebuildPending = false
    private var flushRecheckScheduled = false
    /// A-30: when the current deferral began; a rebuild deferred
    /// continuously for ~3 s flushes unconditionally.
    private var deferralBeganAt: Date?
    /// A-89: an offset restore is outstanding until the deferred
    /// re-clamp has run.
    private var restoreOutstanding = false
    /// B-32: generation of the latest rebuild; a deferred re-clamp
    /// may only act while its own rebuild is still the latest.
    private var rebuildGeneration = 0

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
            if deferralBeganAt == nil { deferralBeganAt = Date() }
            contentRebuildPending = true
            scheduleFlushRecheck()
            return
        }
        performContentRebuild()
    }

    /// Rebuilds now, keeping the user's place: the scroll offset is
    /// restored afterwards (clamped to the new content size), so a
    /// background refresh never makes the page jump.
    /// The deliberate-action path: callers that are NOT responding to
    /// a background notification (an explicit user action, a deliberate
    /// refresh) may call this directly. Notification handlers and
    /// viewWillAppear go through requestContentRebuild() instead
    /// (A-31), so a pending deferred rebuild is never discarded and a
    /// rebuild never lands mid-gesture.
    func performContentRebuild() {
        contentRebuildPending = false
        deferralBeganAt = nil
        let offsetY = scrollView.contentOffset.y
        rebuildContent()
        view.layoutIfNeeded()
        // A-89: never fight a pull-to-refresh for the offset.
        if scrollView.refreshControl?.isRefreshing == true { return }
        clampScrollOffset(to: offsetY)
        // A-89: content height can settle after this first pass
        // (covers decoding into posters, labels re-wrapping), so
        // schedule one deferred re-clamp while this restore is
        // outstanding.
        restoreOutstanding = true
        rebuildGeneration += 1
        let generation = rebuildGeneration
        DispatchQueue.main.async { [weak self] in
            // B-32: if a newer rebuild has run since this one was
            // scheduled, its re-clamp supersedes this one — do not
            // clear its outstanding flag or clamp to this stale offset.
            guard let self = self, self.restoreOutstanding,
                  self.rebuildGeneration == generation else { return }
            self.restoreOutstanding = false
            self.view.layoutIfNeeded()
            self.clampScrollOffset(to: offsetY)
        }
    }

    private func clampScrollOffset(to offsetY: CGFloat) {
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
            // A-30: a deferral deadline — after ~3 s of continuous
            // deferral, flush unconditionally rather than polling
            // (and showing stale content) forever.
            let deadlinePassed = self.deferralBeganAt.map { Date().timeIntervalSince($0) >= 3.0 } ?? false
            if self.contentRebuildPending && self.scrollBusy && !deadlinePassed {
                self.scheduleFlushRecheck()
            } else if deadlinePassed {
                self.performContentRebuild()
            } else {
                self.flushPendingContentRebuild()
            }
        }
    }

    // A-88: deliberate coupling — these callbacks intentionally do
    // NOT check which scroll view ended. Home assigns its horizontal
    // rails' delegate to the same controller, and a rail ending is
    // exactly what must flush a rail-deferred rebuild. Safety does
    // not rest on the identity check: flushPendingContentRebuild()
    // re-checks scrollBusy (page + supplementary rails) before
    // rebuilding.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            flushPendingContentRebuild()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushPendingContentRebuild()
    }
}

// MARK: - Control base classes

/// Plain UIKit controls. These classes carry no touch logic of
/// their own — scroll-safety is not, and cannot be, a control's
/// job: by the time a control sees a touch, UIKit has already
/// decided to deliver it. The guarantee that a scroll never fires
/// a control lives in GPScrollView (delaysContentTouches at the
/// iOS default + touches cancelled in content views when a pan
/// wins). The names are kept from the release that tried to guard
/// inside the controls, so every call site stays untouched.
class GPGuardedControl: UIControl {
}

/// A segmented control changes a setting, so it matters that it
/// is a plain control inside a GPScrollView: a scroll gesture is
/// withheld from it, or cancelled inside it, before it can act.
class GPGuardedSegmentedControl: UISegmentedControl {
}

/// The same reasoning for steppers: their value changes are
/// dispatched while a touch is being tracked, so the only safe
/// place to stop a scroll from reaching one is before delivery —
/// which is what GPScrollView does.
class GPGuardedStepper: UIStepper {
    // A-29: non-continuous, so a value change is dispatched only on
    // touch-up — which a scroll-cancelled touch never reaches. This
    // closes the rest-then-scroll window GPScrollView alone leaves.
    override init(frame: CGRect) {
        super.init(frame: frame)
        isContinuous = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isContinuous = false
    }
}

/// Buttons: plain UIButton inside a GPScrollView.
class GPGuardedButton: UIButton {
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
    /// A-27: dedicated tap identity, so it no longer rides on
    /// accessibilityIdentifier.
    var appKey: String?

    /// A-27: spoken label assembled from the card's visible labels.
    override var accessibilityLabel: String? {
        get {
            let texts = Self.labelTexts(in: stack)
            return texts.isEmpty ? nil : texts.joined(separator: ", ")
        }
        set { }
    }

    private static func labelTexts(in view: UIView) -> [String] {
        var out: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty { out.append(text) }
        for sub in view.subviews { out += labelTexts(in: sub) }
        return out
    }

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
    let titleLabel = gpLabel(nil, font: GPFont.body(16, weight: .semibold), color: GPColor.textPrimary, lines: 2)
    let subtitleLabel = gpLabel(nil, font: GPFont.body(13), color: GPColor.textSecondary, lines: 2)
    let valueLabel = gpLabel(nil, font: GPFont.body(14, weight: .semibold), color: GPColor.textSecondary, lines: 1)
    private let chevronLabel = gpLabel("›", font: GPFont.display(20, weight: .bold), color: GPColor.textFaint, lines: 1)
    /// A-27: dedicated tap identity where a row represents an app.
    var appKey: String?
    /// A-27: dedicated tap identity where a row represents a host
    /// (Settings host rows) — identity never rides on
    /// accessibilityIdentifier.
    var hostUUID: String?

    /// A-27: spoken label/value from the visible title, subtitle
    /// and value.
    override var accessibilityLabel: String? {
        get { [titleLabel.text, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
        set { }
    }
    override var accessibilityValue: String? {
        get { valueLabel.text }
        set { }
    }

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
        // A-82: the value wins truncation fights against the title.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle?.isEmpty ?? true
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

    /// A-27: the row itself is the accessibility element; the
    /// display-only switch's state is spoken as the row's value.
    override var accessibilityLabel: String? {
        get { [titleLabel.text, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
        set { }
    }
    override var accessibilityValue: String? {
        get { isOn ? "On" : "Off" }
        set { }
    }

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
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        addTarget(self, action: #selector(rowTapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle?.isEmpty ?? true
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
    /// A-27: dedicated tap identity (accessibilityIdentifier is
    /// still set by callers for compatibility, but handlers read this).
    var appKey: String?
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
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        accessibilityLabel = [name, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = [.button]
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
    /// A-27: dedicated tap identity (see GPPosterView).
    var appKey: String?
    private let imageView = UIImageView()
    private let tileLabel = gpLabel(nil, font: GPFont.display(11, weight: .bold), color: GPColor.textPrimary, lines: 2)
    let nameLabel = gpLabel(nil, font: GPFont.body(15, weight: .semibold), color: GPColor.textPrimary, lines: 2)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, subtitle: String?, cover: UIImage?) {
        nameLabel.text = name
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        accessibilityLabel = [name, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = [.button]
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
        layer.cornerRadius = 22
        contentEdgeInsets = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        refreshStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshStyle() {
        // A-27: selection is state, not just colour.
        isSelected = chipSelected
        if chipSelected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
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
    // A-110: no default action title — a caller that wants a button
    // passes an explicit title to configure(...); with none, the
    // button stays hidden instead of offering a misleading "Retry".
    let actionButton = gpSecondaryButton("")

    init() {
        super.init(frame: .zero)
        backgroundColor = GPColor.panel
        layer.cornerRadius = 20
        actionButton.isHidden = true
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
