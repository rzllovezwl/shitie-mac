import AppKit
import SwiftUI

struct SourceAppIconView: View {
    let bundleID: String?
    let name: String?
    let size: CGFloat

    @State private var icon: NSImage?

    private var lookupKey: String { "\(bundleID ?? "")|\(name ?? "")" }

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else if name == "iPhone 截图" {
                Image(systemName: "iphone")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            } else {
                LucideIcon(.file, size: size * 0.75)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: lookupKey) {
            icon = nil
            if name == "iPhone 截图" { return }
            icon = await SourceAppIconResolver.shared.icon(bundleID: bundleID, name: name)
        }
    }
}

@MainActor
final class SourceAppIconResolver {
    static let shared = SourceAppIconResolver()

    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(bundleID: String?, name: String?) async -> NSImage? {
        let key = "\(bundleID ?? "")|\(name ?? "")"
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }

        // An old entry may retain a stale Bundle ID. Its icon can still be
        // matched by name, but launching must never use that weaker match.
        let resolver = SourceApplicationResolver.shared
        var appURL = await resolver.applicationURL(bundleID: bundleID, name: name)
        if appURL == nil, bundleID != nil {
            appURL = await resolver.applicationURL(bundleID: nil, name: name)
        }
        guard let appURL else {
            missing.insert(key)
            return nil
        }
        let image = Self.bundledIcon(at: appURL) ?? NSWorkspace.shared.icon(forFile: appURL.path)
        cache[key] = image
        return image
    }

    private static func bundledIcon(at appURL: URL) -> NSImage? {
        guard let iconFile = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !iconFile.isEmpty else { return nil }
        let fileName = iconFile.hasSuffix(".icns") ? iconFile : "\(iconFile).icns"
        let iconURL = appURL.appendingPathComponent("Contents/Resources").appendingPathComponent(fileName)
        return NSImage(contentsOf: iconURL)
    }
}

@MainActor
final class SourceApplicationResolver {
    static let shared = SourceApplicationResolver()

    private var applicationURLs: [String: URL] = [:]
    private var unresolvedAt: [String: Date] = [:]
    private var pending: [String: Task<String?, Never>] = [:]

    func runningApplication(bundleID: String?, name: String?) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { application in
            if let bundleID, !bundleID.isEmpty {
                return application.bundleIdentifier == bundleID
            }
            guard let name, !name.isEmpty else { return false }
            return application.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    func applicationURL(bundleID: String?, name: String?) async -> URL? {
        guard (bundleID?.isEmpty == false) || (name?.isEmpty == false) else { return nil }
        let key = "\(bundleID ?? "")|\(name ?? "")"
        if let cached = applicationURLs[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if let lastFailure = unresolvedAt[key], Date().timeIntervalSince(lastFailure) < 60 {
            return nil
        }

        let workspace = NSWorkspace.shared
        var appURL = runningApplication(bundleID: bundleID, name: name)?.bundleURL
        if appURL == nil, let bundleID, !bundleID.isEmpty {
            appURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
        }
        if appURL == nil {
            let matchesOwnBundle = bundleID != nil && bundleID == Bundle.main.bundleIdentifier
            let matchesOwnName = bundleID == nil && name == Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            if matchesOwnBundle || matchesOwnName { appURL = Bundle.main.bundleURL }
        }
        if appURL == nil {
            let search: Task<String?, Never>
            if let existing = pending[key] {
                search = existing
            } else {
                search = Task.detached(priority: .utility) {
                    Self.findInstalledApplication(bundleID: bundleID, named: name)
                }
                pending[key] = search
            }
            let path = await search.value
            pending[key] = nil
            appURL = path.map { URL(fileURLWithPath: $0) }
        }
        if let appURL {
            applicationURLs[key] = appURL
            unresolvedAt[key] = nil
        } else {
            unresolvedAt[key] = .now
        }
        return appURL
    }

    nonisolated private static func findInstalledApplication(bundleID: String?, named name: String?) -> String? {
        let aliases = [
            "微信": "WeChat", "Safari浏览器": "Safari", "系统设置": "System Settings",
            "文本编辑": "TextEdit", "访达": "Finder"
        ]
        let lookupName = name.map { aliases[$0] ?? $0 }
        if bundleID == "com.apple.finder" || (bundleID == nil && lookupName == "Finder") {
            return "/System/Library/CoreServices/Finder.app"
        }
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")
        ]
        for root in roots {
            var directories: [(URL, Int)] = [(root, 0)]
            var nextDirectory = 0
            while nextDirectory < directories.count {
                let (directory, depth) = directories[nextDirectory]
                nextDirectory += 1
                guard let children = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for url in children {
                    guard url.pathExtension == "app" else {
                        if depth < 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            directories.append((url, depth + 1))
                        }
                        continue
                    }
                    let bundle = Bundle(url: url)
                    let candidates = [
                        url.deletingPathExtension().lastPathComponent,
                        bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                        bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ].compactMap { $0 }
                    let matchesBundle = bundleID != nil && bundle?.bundleIdentifier == bundleID
                    let matchesName = bundleID == nil && lookupName.map { requestedName in
                        candidates.contains { $0.localizedCaseInsensitiveCompare(requestedName) == .orderedSame }
                    } == true
                    if matchesBundle || matchesName {
                        return url.path
                    }
                }
            }
        }
        return nil
    }
}
