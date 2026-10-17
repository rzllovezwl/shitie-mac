import AppKit
import SwiftUI

struct SourceAppIconView: View {
    let bundleID: String?
    let name: String?
    let size: CGFloat

    @State private var icon: NSImage?

    private var lookupKey: String { "\(bundleID ?? "")|\(name ?? "")" }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
                    .accessibilityHidden(true)
            }
        }
        .task(id: lookupKey) {
            icon = await SourceAppIconResolver.shared.icon(bundleID: bundleID, name: name)
        }
    }
}

@MainActor
private final class SourceAppIconResolver {
    static let shared = SourceAppIconResolver()

    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(bundleID: String?, name: String?) async -> NSImage? {
        let key = "\(bundleID ?? "")|\(name ?? "")"
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }

        let workspace = NSWorkspace.shared
        var appURL = bundleID.flatMap(workspace.urlForApplication(withBundleIdentifier:))
        if appURL == nil, let name {
            let running = workspace.runningApplications.first {
                $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            appURL = running?.bundleURL
        }
        if appURL == nil, let name,
           name == Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            appURL = Bundle.main.bundleURL
        }
        if appURL == nil, let name {
            let lookupName = name == "微信" ? "WeChat" : name
            let path = await Task.detached(priority: .utility) {
                Self.findInstalledApplication(named: lookupName)
            }.value
            appURL = path.map { URL(fileURLWithPath: $0) }
        }
        guard let appURL else {
            missing.insert(key)
            return nil
        }
        let image = workspace.icon(forFile: appURL.path)
        cache[key] = image
        return image
    }

    nonisolated private static func findInstalledApplication(named name: String) -> String? {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications")
        ]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                enumerator.skipDescendants()
                let bundle = Bundle(url: url)
                let candidates = [
                    url.deletingPathExtension().lastPathComponent,
                    bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ].compactMap { $0 }
                if candidates.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    return url.path
                }
            }
        }
        return nil
    }
}
