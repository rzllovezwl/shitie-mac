import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let behindRegularWindows = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var applicationPicker: NSOpenPanel?
    private var isBehindRegularWindows = false
    private var switchedToAccessoryForPanel = false
    private var needsFrontOrderAfterActivation = false
    private var frontOrderDeadline = Date.distantPast
    private var frontOrderGeneration = UUID()

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

    /// Start the app activation while the Settings button's user event is
    /// still being handled. The shelf can then finish its exit animation.
    func prepareToOpen() {
        needsFrontOrderAfterActivation = false
        frontOrderGeneration = UUID()
        showDockIcon()
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate()
    }

    /// A pin can leave this process active after its window closes. Keep an
    /// older Settings window out of AppKit's automatic next-key-window choice.
    func parkForPinnedImageInteraction() {
        needsFrontOrderAfterActivation = false
        frontOrderDeadline = .distantPast
        frontOrderGeneration = UUID()
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        window.level = .normal
        isBehindRegularWindows = false
        switchedToAccessoryForPanel = false
    }

    func open(category: SettingsCategory? = nil, onClose: (() -> Void)? = nil) {
        if let category { UserDefaults.standard.set(category.rawValue, forKey: SettingsCategory.selectionKey) }
        if let onClose { self.onClose = onClose }
        switchedToAccessoryForPanel = false
        needsFrontOrderAfterActivation = true
        frontOrderDeadline = Date().addingTimeInterval(1)
        frontOrderGeneration = UUID()
        let generation = frontOrderGeneration
        showDockIcon()
        restoreForInteraction()

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 810, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipHoook 设置"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 690, height: 500)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = NSHostingView(rootView: SettingsView(model: AppController.shared))
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.deminiaturize(nil)
        window?.orderFrontRegardless()
        bringSettingsForward(generation: generation)
        for delay in [0.08, 0.25, 0.55] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.bringSettingsForward(generation: generation)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.frontOrderGeneration == generation else { return }
            self.needsFrontOrderAfterActivation = false
        }
    }

    func chooseExcludedApplication(_ completion: @escaping (URL) -> Void) {
        guard applicationPicker == nil else { return }
        if window == nil { open(category: .clipboard) }
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.message = "选择不记录剪贴板内容的应用"
        picker.prompt = "添加"
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.treatsFilePackagesAsDirectories = false
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        applicationPicker = picker
        picker.beginSheetModal(for: window) { [weak self, weak picker] response in
            self?.applicationPicker = nil
            guard response == .OK, let url = picker?.url else { return }
            completion(url)
        }
    }

    func finishOpeningAfterActivation() {
        guard needsFrontOrderAfterActivation,
              Date() <= frontOrderDeadline else {
            needsFrontOrderAfterActivation = false
            return
        }
        bringSettingsForward(generation: frontOrderGeneration)
    }

    private func bringSettingsForward(generation: UUID) {
        guard frontOrderGeneration == generation,
              needsFrontOrderAfterActivation,
              Date() <= frontOrderDeadline,
              let window, window.isVisible, !window.isMiniaturized,
              !isBehindRegularWindows else { return }
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
#if DEBUG
        ImageGestureTrace.record("settings promote active=\(NSApp.isActive) key=\(window.isKeyWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) self=\(NSRunningApplication.current.processIdentifier)")
#endif
        guard NSApp.isActive, window.isKeyWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                NSRunningApplication.current.processIdentifier else { return }
        needsFrontOrderAfterActivation = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              contains(event.window) else { return }
        restoreForInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        needsFrontOrderAfterActivation = false
        frontOrderGeneration = UUID()
        switchedToAccessoryForPanel = false
        restoreForInteraction()
        let onClose = self.onClose
        self.onClose = nil
        DispatchQueue.main.async { [weak self] in
            if self?.window?.isVisible == false,
               !PhoneScreenshotGuideWindowController.shared.hasVisibleWindow {
                _ = NSApp.setActivationPolicy(.accessory)
            }
            onClose?()
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
    @AppStorage(PhoneScreenshotDiscovery.completedStepsKey) private var completedSteps = 0

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
                    if model.phoneScreenshotReceivingEnabled {
                        HStack(alignment: .center, spacing: 18) {
                            if let code = qrCode(for: PhoneScreenshotReceiver.templateAddress) {
                                Image(nsImage: code)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 154, height: 154)
                                    .padding(10)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("iCloud 快捷指令模板二维码")
                            }
                            VStack(alignment: .leading, spacing: 9) {
                                Text("用 iPhone 扫码添加模板")
                                    .font(.headline)
                                Text("添加后，点下方“复制接收地址”，把地址完整填入模板的“URL”操作，替换示例文字。")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("扫码添加无需同一 Wi-Fi；截图直传需同一可信局域网。模板链接不含私密地址。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }

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
                        HStack {
                            Text("在 iPhone 上设置一次")
                                .font(.headline)
                            Spacer()
                            Text("已完成 \(completedStepCount)/4 · 手动标记")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        guideStep(1, "添加 iCloud 模板",
                                  "用 iPhone 扫上方二维码，直接打开并添加 iCloud 模板。刚添加的副本顶部应有“当我将截屏保存到照片时”。")
                        guideStep(2, "替换模板里的示例地址",
                                  "在这台 Mac 上点“复制接收地址”，再到 iPhone 模板的“URL”操作中粘贴，完整替换中文占位文字。跨设备粘贴不可用时，可用可信方式把地址传到手机。接收地址应包含 /v1/screenshot/。")
                        guideStep(3, "开启自动化并设为立即运行",
                                  "不同 iOS 版本入口可能不同：轻点顶部“自动化已关闭”，或点触发条件旁的向右箭头进入设置。开启截屏自动化并选“立即运行”（旧版可关闭“运行前询问”）。共享模板无法代替你完成开启。")
                        guideStep(4, "保存一张新截图验证",
                                  "让 Mac 保持运行且不休眠，两台设备接入同一可信局域网。保存截图到“照片”后，历史里应出现“iPhone 截图”卡片，并按声音设置播放提示音。")
                        Text("A、B 设为“任一”只检查 iPhone：两台设备一起切换时不用改条件；若 iPhone 在 A、Mac 在 B，仍可能超时。处理方法见下方“Wi-Fi 切换与超时提醒”。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TappableHelpSection("截图没有送达？查看连接自检",
                                        cardColor: Color.secondary.opacity(0.09)) {
                        PhoneScreenshotDiagnosticsView(model: model)
                            .padding(.top, 10)
                    }

                    TappableHelpSection("Wi-Fi 切换与超时提醒（可选）",
                                        cardColor: Color.accentColor.opacity(0.08)) {
                        PhoneScreenshotWiFiGuideSteps()
                            .padding(.top, 10)
                    }
                    .fixedSize(horizontal: false, vertical: true)

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
        .onChange(of: model.phoneScreenshotEndpoint) { _, _ in
            didCopyAddress = false
        }
    }

    private var completedStepCount: Int {
        (0..<4).filter { completedSteps & (1 << $0) != 0 }.count
    }

    private func guideStep(_ number: Int, _ title: String, _ description: String) -> some View {
        let bit = 1 << (number - 1)
        let isComplete = completedSteps & bit != 0
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isComplete ? "checkmark" : "\(number).circle.fill")
                .font(.system(size: isComplete ? 12 : 24, weight: .bold))
                .foregroundStyle(isComplete ? .white : Color.accentColor)
                .frame(width: 24, height: 24)
                .background(isComplete ? Color.green : Color.clear, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(isComplete ? "撤销" : "完成") {
                if isComplete {
                    completedSteps &= ~bit
                } else {
                    completedSteps |= bit
                }
            }
            .font(.caption)
            .accessibilityLabel(isComplete ? "将第 \(number) 步标记为未完成" : "将第 \(number) 步标记为完成")
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

/// The whole collapsed help row is a button, including its background and
/// whitespace. Expanded content remains interactive without collapsing it.
struct TappableHelpSection<Content: View>: View {
    let title: String
    let cardColor: Color?
    let content: Content
    @State private var isExpanded = false

    init(_ title: String, cardColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.cardColor = cardColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, cardColor == nil ? 0 : 16)
                .padding(.vertical, cardColor == nil ? 8 : 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            if isExpanded {
                content
                    .padding(.leading, cardColor == nil ? 19 : 16)
                    .padding(.trailing, cardColor == nil ? 0 : 16)
                    .padding(.bottom, cardColor == nil ? 0 : 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let cardColor {
                RoundedRectangle(cornerRadius: 12).fill(cardColor)
            }
        }
    }
}

struct PhoneScreenshotWiFiGuideSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前情况：iPhone 在 A、Mac 在 B 时，“A 或 B”依然满足条件，快捷指令会尝试上传。如果两网不能互访，就会弹出超时提示。")
                .fontWeight(.semibold)
            Text("立刻消除提示：让两台设备连到同一可互访的 Wi-Fi；暂时做不到时，关闭这条截图自动化，回到同网再开启。如果 Mac 长期固定在 B，也可把下面的“如果”只保留 B：iPhone 在 A 时会跳过发送。")
                .foregroundStyle(.secondary)
            Text("为什么要设置：未加判断时，每次保存截图都会执行“获取 URL 内容”。离开常用 Wi-Fi 后，这台 Mac 的局域网接收地址通常不可达，快捷指令可能反复弹出连接失败或超时提示。加上判断后，使用蜂窝网络或其他 Wi-Fi 时会跳过上传请求，减少弹窗。")
                .foregroundStyle(.secondary)
            Text("只有在两台设备通常一起切换 A、B 时，才适合同时允许 A 和 B。这项判断不知道 Mac 当前连接哪个 Wi-Fi，不能自动避开 A／B 不同网的情况。")
                .fontWeight(.medium)
            Text("已有的截屏触发器、“获取最新的 1 张截屏”和 URL 地址保持原样。在“URL”后面依次添加网络判断：")
                .foregroundStyle(.secondary)
            step(1, "在 iPhone 的“设置 → 无线局域网”（或“Wi-Fi”）记下常用网络的准确名称，例如 A 和 B。只有 Mac 也能从该网络被访问时，才把它加入允许列表。")
            step(2, "搜索“获取网络的详细信息”，按住并拖到“URL”下方。把蓝色选项设为“无线局域网”和“名称”；完成后动作会显示“获取 无线局域网 网络的 名称”。")
            step(3, "在它下方加入“如果”。先设“网络的详细信息 是 A”。若还常用 B，轻点“如果”中的“＋”添加条件，再设“网络的详细信息 是 B”，并把条件关系改为“任一”。已有 A 条件时直接从“＋”开始。")
            step(4, "把原来的“获取 URL 内容”拖到“如果”和“否则”之间。确认蓝色“URL”仍引用原来的 URL 动作；“否则”留空，保留“结束如果”。")
            Text("最终顺序：URL → 获取无线局域网网络的名称 → 如果“任一：名称是 A／名称是 B” → 获取 URL 内容 → 否则（空）→ 结束如果。只用一个网络时保留单条条件即可。")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Text("验证时要分别让两台设备同在 A、同在 B；这两种情况可尝试送达，蜂窝网络会跳过。若 iPhone 在 A、Mac 在 B，且两网不互通，仍会超时。当前模板无法读取 Mac 的 Wi-Fi 状态；被跳过的截图不会自动补传。")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number).")
                .fontWeight(.semibold)
            Text(description)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PhoneScreenshotDiagnosticsView: View {
    @ObservedObject var model: AppController
    @State private var didCopyTestAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Mac 接收：\(model.phoneScreenshotReceiverStatus)")
            Text("2. 局域网访问：\(setupVisitStatus)")
            Text("3. 截图上传：\(model.phoneScreenshotLastUploadResult)")

            Button(didCopyTestAddress ? "已复制连接测试地址" : "复制连接测试地址") {
                model.copyPhoneScreenshotSetupAddress()
                didCopyTestAddress = true
            }
            .disabled(!model.phoneScreenshotReceivingEnabled)

            Text("让 iPhone 与 Mac 连接同一可信局域网，在 iPhone Safari 中打开复制的测试地址。网页能打开且第 2 项更新，说明请求到达 Mac；然后保存一张新截图，检查第 3 项。测试网页不能证明截屏自动化已开启。地址含私密配对码，请勿分享。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("第 2 项更新而第 3 项没有变化时，请检查截屏自动化是否开启、URL 是否包含 /v1/screenshot/，以及“获取 URL 内容”是否位于允许发送的分支内。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var setupVisitStatus: String {
        guard let date = model.phoneScreenshotLastSetupVisitAt else {
            return "本次运行尚未检测到测试网页访问"
        }
        return "测试请求已到 Mac（\(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))）"
    }
}
