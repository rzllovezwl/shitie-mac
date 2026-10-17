import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        closeOlderInstances()
        Task { @MainActor in
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
            SettingsWindowController.shared.open()
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
            Image(LucideSymbol.clipboard.assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 18, height: 18)
                .accessibilityLabel("ClipHoook")
        }
        .menuBarExtraStyle(.menu)
    }
}
