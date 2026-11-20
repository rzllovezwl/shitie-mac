import AppKit
import SwiftUI

@MainActor
private enum MenuBarArtwork {
    static let appIcon = icon(offset: .zero, tilt: 0)
    static let copyFrames: [NSImage] = {
        let frameCount = 21
        return [appIcon] + (1..<frameCount).map { frame in
            let phase = CGFloat(frame) / CGFloat(frameCount)
            let pass = sin(.pi * phase)
            let travel = pass * pass
            let turn = sin(2 * .pi * phase)
            // Opposing arcs let both cards read clearly as they cross the center.
            let sidestep = travel * turn
            let offset = CGPoint(x: 3.35 * travel + sidestep,
                                 y: 3.25 * travel - sidestep)
            return icon(offset: offset, tilt: turn * 0.13)
        }
    }()

    private static func cardTransform(_ card: CGRect, offset: CGPoint, tilt: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: card.midX + offset.x, y: card.midY + offset.y)
            .rotated(by: tilt)
            .translatedBy(x: -card.midX, y: -card.midY)
    }

    private static func icon(offset: CGPoint, tilt: CGFloat) -> NSImage {
        // A menu-bar-sized version of the B identity: two content cards and
        // matching capture corners. Template alpha adapts to the system tint.
        let front = CGRect(x: 1.25, y: 1.25, width: 12.5, height: 12.5)
        let back = CGRect(x: 4.75, y: 4.5, width: 12.25, height: 12.5)
        let frontTransform = cardTransform(front, offset: offset, tilt: tilt)
        let backTransform = cardTransform(back, offset: CGPoint(x: -offset.x, y: -offset.y), tilt: -tilt)
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }

            context.saveGState()
            context.concatenate(backTransform)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: back, xRadius: 2.7, yRadius: 2.7).fill()
            context.restoreGState()

            // Separate the overlapping silhouettes, including at 1x scale.
            context.concatenate(frontTransform)
            context.setBlendMode(.clear)
            NSBezierPath(roundedRect: front.insetBy(dx: -0.8, dy: -0.8),
                         xRadius: 3.5, yRadius: 3.5).fill()
            context.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front, xRadius: 2.7, yRadius: 2.7).fill()

            let corners = NSBezierPath()
            corners.move(to: CGPoint(x: 3.9, y: 8.1))
            corners.line(to: CGPoint(x: 3.9, y: 9.6))
            corners.curve(to: CGPoint(x: 5.0, y: 10.7),
                          controlPoint1: CGPoint(x: 3.9, y: 10.3),
                          controlPoint2: CGPoint(x: 4.3, y: 10.7))
            corners.line(to: CGPoint(x: 6.8, y: 10.7))
            corners.move(to: CGPoint(x: 11.1, y: 6.9))
            corners.line(to: CGPoint(x: 11.1, y: 5.4))
            corners.curve(to: CGPoint(x: 10.0, y: 4.3),
                          controlPoint1: CGPoint(x: 11.1, y: 4.7),
                          controlPoint2: CGPoint(x: 10.7, y: 4.3))
            corners.line(to: CGPoint(x: 8.2, y: 4.3))
            corners.lineWidth = 1.5
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            context.setBlendMode(.clear)
            corners.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class MenuBarCopyAnimation: ObservableObject {
    private static let duration: Duration = .milliseconds(350)
    @Published private(set) var image = MenuBarArtwork.appIcon
    private var animationTask: Task<Void, Never>?

    func play() {
        animationTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            image = MenuBarArtwork.appIcon
            animationTask = nil
            return
        }

        let frames = MenuBarArtwork.copyFrames
        image = frames[0]
        animationTask = Task { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            for (index, frame) in frames.enumerated().dropFirst() {
                let deadline = started + Self.duration * index / frames.count
                do { try await clock.sleep(until: deadline) } catch { return }
                self?.image = frame
            }
            do { try await clock.sleep(until: started + Self.duration) } catch { return }
            self?.image = MenuBarArtwork.appIcon
            self?.animationTask = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        closeOlderInstances()
        Task { @MainActor in
            _ = NSApp.setActivationPolicy(.accessory)
            AppController.shared.start()
        }
    }

    private func closeOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let currentLaunchDate = current.launchDate ?? .now

        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != current.processIdentifier
            && (application.launchDate ?? .distantPast) <= currentLaunchDate {
            application.terminate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppController.shared.openSettings()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.flushPinnedImageFrames()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let recorder = AppController.shared.screenRecorder
            guard recorder.phase.isActive else { return .terminateNow }
            Task { @MainActor in
                await recorder.stop(openPreview: false)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindowController.shared.finishOpeningAfterActivation()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindowController.shared.restoreAfterAppDeactivates()
        }
    }
}

@main
struct ClipboardShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: AppController.shared)
        } label: {
            RecordingMenuBarLabel(recorder: AppController.shared.screenRecorder,
                                  copyAnimation: AppController.shared.menuBarCopyAnimation)
        }
        .menuBarExtraStyle(.menu)
    }
}
