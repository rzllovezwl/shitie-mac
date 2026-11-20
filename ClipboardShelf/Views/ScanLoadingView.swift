import AppKit
import QuartzCore
import SwiftUI

/// A display-only overlay. It never becomes part of exported image pixels or
/// consumes the pointer events used to cancel/adjust a screenshot.
final class ScanLoadingView: NSView {
    var message = "正在识别文字…" {
        didSet { label.stringValue = message; setAccessibilityLabel(message); needsLayout = true }
    }
    private let sweep = CAGradientLayer()
    private let line = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var accessibilityObserver: NSObjectProtocol?
    private var lastSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        sweep.startPoint = CGPoint(x: 0.5, y: 0)
        sweep.endPoint = CGPoint(x: 0.5, y: 1)
        sweep.locations = [0, 0.45, 0.75, 1]
        sweep.addSublayer(line)
        layer?.addSublayer(sweep)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.cornerRadius = 7
        label.layer?.masksToBounds = true
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(message)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAnimation() }
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimation()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let accent = NSColor.controlAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = accent.withAlphaComponent(0.045).cgColor
        sweep.colors = [accent.withAlphaComponent(0).cgColor,
                        accent.withAlphaComponent(0.04).cgColor,
                        accent.withAlphaComponent(0.24).cgColor,
                        accent.withAlphaComponent(0).cgColor]
        let band = min(90, max(26, bounds.height * 0.22))
        sweep.frame = CGRect(x: 0, y: 0, width: bounds.width, height: band)
        line.backgroundColor = accent.withAlphaComponent(0.8).cgColor
        line.frame = CGRect(x: 0, y: band * 0.75, width: bounds.width, height: 1.5)
        label.stringValue = message
        label.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        let width = min(max(0, bounds.width - 16), label.fittingSize.width + 24)
        label.frame = CGRect(x: (bounds.width - width) / 2,
                             y: max(4, bounds.height - 38), width: width, height: 26)
        label.isHidden = bounds.width < 80 || bounds.height < 46
        CATransaction.commit()
        if lastSize != bounds.size || sweep.animation(forKey: "scan") == nil {
            lastSize = bounds.size
            refreshAnimation()
        }
    }
    private func refreshAnimation() {
        sweep.removeAnimation(forKey: "scan")
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sweep.isHidden = reduced || window == nil
        guard !reduced, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let motion = CABasicAnimation(keyPath: "transform.translation.y")
        motion.fromValue = -max(26, sweep.bounds.height)
        motion.toValue = bounds.height
        motion.duration = 1.65
        motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.add(motion, forKey: "scan")
    }
    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }
}

struct ScanLoadingOverlay: NSViewRepresentable {
    let message: String
    func makeNSView(context: Context) -> ScanLoadingView { ScanLoadingView(frame: .zero) }
    func updateNSView(_ view: ScanLoadingView, context: Context) { view.message = message }
}
