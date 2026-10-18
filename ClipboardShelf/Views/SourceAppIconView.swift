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
            } else {
                LucideIcon(.file, size: size * 0.75)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: lookupKey) {
            icon = nil
            icon = await SourceAppIconResolver.shared.icon(bundleID: bundleID, name: name)
        }
    }
}

@MainActor
final class SourceAppIconResolver {
    static let shared = SourceAppIconResolver()

    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var pending: [String: Task<String?, Never>] = [:]

    func icon(bundleID: String?, name: String?) async -> NSImage? {
        let key = "\(bundleID ?? "")|\(name ?? "")"
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }

        let workspace = NSWorkspace.shared
        var appURL = bundleID.flatMap(workspace.urlForApplication(withBundleIdentifier:))
        if appURL == nil {
            let running = workspace.runningApplications.first { application in
                let matchesBundle = bundleID != nil && application.bundleIdentifier == bundleID
                let matchesName = name.map { requestedName in
                    application.localizedName?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
                } ?? false
                return matchesBundle || matchesName
            }
            appURL = running?.bundleURL
        }
        let isOwnBundle = bundleID != nil && bundleID == Bundle.main.bundleIdentifier
        let isOwnName = name != nil && name == Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        if appURL == nil, isOwnBundle || isOwnName {
            appURL = Bundle.main.bundleURL
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
        guard let appURL else {
            missing.insert(key)
            return nil
        }
        let image = Self.bundledIcon(at: appURL) ?? workspace.icon(forFile: appURL.path)
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

    nonisolated private static func findInstalledApplication(bundleID: String?, named name: String?) -> String? {
        let aliases = [
            "微信": "WeChat", "Safari浏览器": "Safari", "系统设置": "System Settings",
            "文本编辑": "TextEdit", "访达": "Finder"
        ]
        let lookupName = name.map { aliases[$0] ?? $0 }
        if bundleID == "com.apple.finder" || lookupName == "Finder" {
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
            while !directories.isEmpty {
                let (directory, depth) = directories.removeFirst()
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
                    let matchesName = lookupName.map { requestedName in
                        candidates.contains { $0.localizedCaseInsensitiveCompare(requestedName) == .orderedSame }
                    } ?? false
                    if matchesBundle || matchesName {
                        return url.path
                    }
                }
            }
        }
        return nil
    }
}
