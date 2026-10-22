import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let behindRegularWindows = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private var window: NSWindow?
    private var isBehindRegularWindows = false
    private var switchedToAccessoryForPanel = false

    private override init() {}

    var hasVisibleWindow: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    func showDockIcon() {
        _ = NSApp.setActivationPolicy(.regular)
    }

    func contains(_ eventWindow: NSWindow?) -> Bool {
        guard let window, let eventWindow else { return false }
        return eventWindow === window || eventWindow.sheetParent === window
    }

    func prepareForPanelPresentation() {
        guard let window, window.isVisible || window.isMiniaturized else {
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        // Keep Settings ordered in its own Space. The panel needs accessory
        // policy to appear over another app's full-screen Space, but ordering
        // Settings out here would make an open window appear to have closed.
        if window.isMiniaturized || !window.isOnActiveSpace {
            if NSApp.activationPolicy() == .regular {
                switchedToAccessoryForPanel = true
            }
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        // If Settings was the active window, leave it visible behind the
        // shelf. Only lower it when another app was already frontmost, so an
        // image-preview activation cannot unexpectedly raise Settings.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier !=
                NSRunningApplication.current.processIdentifier else {
            return
        }
        window.level = Self.behindRegularWindows
        isBehindRegularWindows = true
    }

    func restoreAfterPanelPresentation() {
        guard let window else { return }
        if switchedToAccessoryForPanel {
            switchedToAccessoryForPanel = false
            showDockIcon()
            // Some macOS versions hide regular windows during a policy switch.
            // Restore visibility only if that happened; never close Settings.
            if !window.isVisible && !window.isMiniaturized {
                window.orderBack(nil)
            }
        }
        if isBehindRegularWindows {
            window.level = .normal
            isBehindRegularWindows = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier !=
                NSRunningApplication.current.processIdentifier {
                window.orderBack(nil)
            }
        }
    }

    func restoreForInteraction() {
        showDockIcon()
        guard isBehindRegularWindows else { return }
        window?.level = .normal
        isBehindRegularWindows = false
    }

    func restoreAfterAppDeactivates() {
        guard isBehindRegularWindows else { return }
        window?.level = .normal
        isBehindRegularWindows = false
        // The user has switched to another app. Restoring the normal level
        // must not raise Settings over that app.
        window?.orderBack(nil)
    }

    func open() {
        switchedToAccessoryForPanel = false
        showDockIcon()
        restoreForInteraction()

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipHoook 设置"
            window.minSize = NSSize(width: 520, height: 480)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: AppController.shared))
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // The first accessory -> regular policy change can finish on the next
        // run loop. Reassert only this window's order then, after the shelf is
        // already gone, so the Dock icon never appears without Settings.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !self.isBehindRegularWindows else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              contains(event.window) else { return }
        restoreForInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        switchedToAccessoryForPanel = false
        restoreForInteraction()
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false,
                  !PhoneScreenshotGuideWindowController.shared.hasVisibleWindow else { return }
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class PhoneScreenshotGuideWindowController: NSObject, NSWindowDelegate {
    static let shared = PhoneScreenshotGuideWindowController()

    private var window: NSWindow?

    private override init() {}

    var hasVisibleWindow: Bool { window?.isVisible == true }

    func open() {
        _ = NSApp.setActivationPolicy(.regular)
        if window == nil {
            let guide = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            guide.title = "iPhone 截图直达 ClipHoook"
            guide.minSize = NSSize(width: 560, height: 560)
            guide.isReleasedWhenClosed = false
            guide.contentView = NSHostingView(rootView: PhoneScreenshotGuideView(
                model: AppController.shared,
                close: { [weak self] in self?.window?.close() }
            ))
            guide.delegate = self
            guide.center()
            window = guide
        }
        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            guard !Self.shared.hasVisibleWindow,
                  !SettingsWindowController.shared.hasVisibleWindow else { return }
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct PhoneScreenshotGuideView: View {
    @ObservedObject var model: AppController
    let close: () -> Void
    @State private var didCopyAddress = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "iphone")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPhone 截图，自动到 Mac")
                        .font(.system(size: 23, weight: .semibold))
                    Text("保存到照片后，截图会出现在 ClipHoook 历史中。无需安装 iPhone App，也无需等待照片云同步。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.phoneScreenshotReceivingEnabled
                              ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(model.phoneScreenshotReceivingEnabled
                                             ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.phoneScreenshotReceivingEnabled ? "Mac 接收已开启" : "先开启 Mac 接收")
                                .font(.headline)
                            Text(model.phoneScreenshotReceiverStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.phoneScreenshotReceivingEnabled {
                            Button(didCopyAddress ? "已复制地址" : "复制接收地址") {
                                model.copyPhoneScreenshotEndpoint()
                                didCopyAddress = true
                            }
                        } else {
                            Button("开启接收") {
                                model.setPhoneScreenshotReceivingEnabled(true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 13) {
                        Text("在 iPhone 上设置一次")
                            .font(.headline)
                        guideStep(1, "新建截屏自动化",
                                  "打开“快捷指令 → 自动化”，选择“截屏 → 已保存截屏时”；保存位置选“照片”，开启自动运行。")
                        guideStep(2, "添加三个操作",
                                  "依次添加“获取最新截屏”“URL”“获取 URL 内容”。将 Mac 上复制的完整接收地址填入“URL”。")
                        guideStep(3, "发送截图文件",
                                  "在“获取 URL 内容”中选 POST，请求体选“文件”，文件变量选“获取最新截屏”的结果。保存自动化。")
                        guideStep(4, "保存一张新截图验证",
                                  "让 Mac 保持运行且不休眠，两台设备接入同一可信局域网。成功后历史里会出现“iPhone 截图”卡片，并按声音设置播放提示音。")
                    }

                    Text("目前只支持同一可信局域网直传；使用 5G 或离开该网络时不会自动送达，也没有离线补传。接收地址含私密配对码，当前 HTTP 传输不加密，请勿公开分享。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(24)
            }

            Divider()
            HStack {
                Text("之后可在“设置 → iPhone 截图”再次打开本指南。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    private func guideStep(_ number: Int, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
