import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let behindRegularWindows = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private var window: NSWindow?
    private var isBehindRegularWindows = false
    private var switchedToAccessoryForPanel = false
    private var needsFrontOrderAfterActivation = false

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
        needsFrontOrderAfterActivation = false
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
        needsFrontOrderAfterActivation = true
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
        // On the first accessory -> regular transition, activation may finish
        // after the window is created. Order it above the other app explicitly.
        window?.orderFrontRegardless()
        // The first accessory -> regular policy change can finish on the next
        // run loop. Reassert only this window's order after the shelf is gone.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !self.isBehindRegularWindows else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if NSApp.isActive { self.finishOpeningAfterActivation() }
        }
    }

    func finishOpeningAfterActivation() {
        guard needsFrontOrderAfterActivation, let window,
              window.isVisible, !window.isMiniaturized else { return }
        needsFrontOrderAfterActivation = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              contains(event.window) else { return }
        restoreForInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        needsFrontOrderAfterActivation = false
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
    @State private var didCopySetupAddress = false

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

                    if model.phoneScreenshotReceivingEnabled {
                        HStack(alignment: .center, spacing: 18) {
                            if let code = qrCode(for: model.phoneScreenshotSetupAddress) {
                                Image(nsImage: code)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 154, height: 154)
                                    .padding(10)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("iPhone 安装页二维码")
                            }
                            VStack(alignment: .leading, spacing: 9) {
                                Text("用 iPhone 扫码打开安装页")
                                    .font(.headline)
                                Text("安装页提供 iCloud 模板和这台 Mac 的专属接收地址。扫码时两台设备需在同一局域网。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(didCopySetupAddress ? "已复制安装页地址" : "复制安装页地址") {
                                    model.copyPhoneScreenshotSetupAddress()
                                    didCopySetupAddress = true
                                }
                                Text("安装页地址含私密配对码，请勿公开分享。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        Text("在 iPhone 上设置一次")
                            .font(.headline)
                        guideStep(1, "添加 iCloud 模板",
                                  "开启 Mac 接收后用 iPhone 扫上方二维码，在安装页点“打开 iCloud 模板”并添加。刚添加的副本顶部应有“当我将截屏保存到照片时”。")
                        guideStep(2, "替换模板里的示例地址",
                                  "只点手机安装页里的“复制接收地址”，不要复制安装页网址。打开已添加的模板，把“URL”操作中的 example.invalid 地址完整替换；接收地址的路径应以 /v1/screenshot/ 开头。")
                        guideStep(3, "开启自动化并设为立即运行",
                                  "导入后如果顶部显示“自动化已关闭”，轻点该提示，开启截屏自动化并选“立即运行”（或关闭“运行前询问”）。共享模板无法代替你在 iPhone 上完成这次开启。")
                        guideStep(4, "保存一张新截图验证",
                                  "让 Mac 保持运行且不休眠，两台设备接入同一可信局域网。保存截图到“照片”后，历史里应出现“iPhone 截图”卡片，并按声音设置播放提示音。")
                    }

                    Text("若顶部没有截屏触发条件，请确认添加的是安装页的 iCloud 模板，而不是之前下载的 .shortcut 文件。已添加的旧副本可删除，避免重复触发。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("减少离开 Wi-Fi 后的超时提醒")
                            .font(.headline)
                        Text("可在 iPhone 模板的上传步骤前加入“获取网络详细信息”，选择 Wi-Fi 网络的“网络名称”；再加入“如果”，设为网络名称等于家里或办公室使用的 Wi-Fi 名称。把“获取 URL 内容”放进“如果”分支，“否则”留空。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("这样连接 5G 或其他 Wi-Fi 时会跳过发送，避免因离开指定网络而请求超时。名称相同仍不能保证 Mac 在线；Mac 休眠、地址变化或网络隔离时仍可能超时。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

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

    private func qrCode(for address: String) -> NSImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(address.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
