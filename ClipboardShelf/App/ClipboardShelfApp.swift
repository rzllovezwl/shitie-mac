import AppKit
import SwiftUI

@MainActor
private enum MenuBarArtwork {
    static let clipboard: NSImage = {
        let source = NSImage(named: NSImage.Name(LucideSymbol.clipboard.assetName))
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 17, height: 17)
        image.isTemplate = true
        return image
    }()
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
            Image(nsImage: MenuBarArtwork.clipboard)
                .accessibilityLabel("ClipHoook")
        }
        .menuBarExtraStyle(.menu)
    }
}
