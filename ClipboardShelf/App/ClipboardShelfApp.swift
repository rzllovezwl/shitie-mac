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
}

@main
struct ClipboardShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("拾贴", systemImage: "doc.on.clipboard") {
            MenuBarContent(model: AppController.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}
