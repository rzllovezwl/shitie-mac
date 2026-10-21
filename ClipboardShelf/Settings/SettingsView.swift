import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppController
    @AppStorage(AppAppearanceMode.preferenceKey) private var appAppearanceMode = AppAppearanceMode.system.rawValue
    @AppStorage("panelDisplayScreen") private var panelDisplayScreen = "mouse"
    @AppStorage("panelPlacement") private var panelPlacement = "bottom"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(HistoryStoragePolicy.retentionKey) private var historyRetention = HistoryRetention.sevenDays.rawValue
    @AppStorage(HistoryStoragePolicy.maximumMegabytesKey) private var historyMaximumStorageMB = 0
    @AppStorage(CopySoundPreference.enabledKey) private var copySoundEnabled = true
    @AppStorage(ClipboardCopyFormat.preferenceKey) private var defaultCopyFormat = ClipboardCopyFormat.original.rawValue
    @AppStorage(ClipboardGroupingPreference.key) private var automaticallyGroupMultipleCopies = true
    @AppStorage(CardPreviewPreference.enabledKey)
    private var cardFormattedPreviewEnabled = CardPreviewPreference.defaultEnabled
    @State private var showsPrivacyPolicy = false
    @State private var showsReleaseHistory = false
    @State private var showsForeverWarning = false
    @State private var recordingShortcut: AppShortcutAction?
    @State private var shortcutError: String?

    private var placement: PanelPlacement {
        PanelPlacement(rawValue: panelPlacement) ?? .bottom
    }

    private var currentVersion: String {
        let version = ReleaseHistory.currentVersion()
        return "\(version.version)（\(version.build)）"
    }

    private var historySize: String {
        ByteCountFormatter.string(fromByteCount: model.historyStorageBytes, countStyle: .file)
    }

    private var pastePermissionStatus: String {
        switch PasteService.availability(requestPermission: false) {
        case .ready: "已允许"
        case .needsPermission: "需要授权"
        }
    }

    var body: some View {
        Form {
            Section("记录") {
                Toggle("记录新复制的内容", isOn: Binding(
                    get: { !model.isPaused },
                    set: { model.isPaused = !$0 }
                ))
                Text("关闭设置窗口后，ClipHoook 仍会在菜单栏运行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("iPhone 截图") {
                Toggle("接收 iPhone 截图", isOn: Binding(
                    get: { model.phoneScreenshotReceivingEnabled },
                    set: { model.setPhoneScreenshotReceivingEnabled($0) }
                ))
                LabeledContent("状态", value: model.phoneScreenshotReceiverStatus)
                if model.phoneScreenshotReceivingEnabled {
                    Text(model.phoneScreenshotEndpoint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制接收地址") {
                        model.copyPhoneScreenshotEndpoint()
                    }
                    Text("在 iPhone 快捷指令中，用“获取 URL 内容”向此地址 POST 截图文件。手机和 Mac 需连接同一可信局域网；HTTP 传输不加密，地址包含私密配对码，请勿分享。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("不记录的应用") {
                if !RecordingExclusionPolicy.configurationIsValid(in: .standard) {
                    Text("排除设置无法读取，当前已停止保存新记录。")
                        .foregroundStyle(.orange)
                    Button("重置排除设置") { model.resetExcludedApplications() }
                }
                ForEach(model.excludedApplications) { application in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(application.name)
                            Text(application.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除") { model.removeExcludedApplication(application) }
                            .help("允许再次记录此应用")
                    }
                }
                Button("添加应用…") { model.addExcludedApplication() }
                Text("复制来源由当前前台应用推断。设置排除后，切换应用期间来源不明确的内容也会跳过记录；后台应用复制的来源无法保证识别。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("显示模式", selection: $appAppearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Text("默认为跟随系统；切换后面板和设置窗口立即更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("声音") {
                Toggle("复制或收到 iPhone 截图时播放提示音", isOn: $copySoundEnabled)
                Button {
                    CopySoundPlayer.shared.playPreview()
                } label: {
                    LucideLabel("试听提示音", symbol: .play)
                }
                Text("剪贴板内容变化或成功收到新 iPhone 截图时播放；重复截图不会再次播放。关闭录制也不会关闭复制提示音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("复制与粘贴") {
                Toggle("多项复制自动成组", isOn: $automaticallyGroupMultipleCopies)
                Text("一次从外部应用复制多个项目，或在面板中多选复制时，默认保存为可展开的分组。关闭后仍会记录和复制全部项目，但分别显示在历史中。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("默认复制格式", selection: $defaultCopyFormat) {
                    ForEach(ClipboardCopyFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("普通复制、双击和 \(model.shortcut(for: .paste).displayName) 粘贴使用所选格式。纯文本只对文字与链接生效；图片和文件仍保留原内容。\(model.shortcut(for: .pastePlainText).displayName) 可单次使用纯文本粘贴。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Toggle("卡片展示格式预览", isOn: $cardFormattedPreviewEnabled)
                Text("开启后，富文本卡片展示保存的字体和颜色，Markdown 与代码展示排版或高亮。卡片仅显示内容片段，详情中可查看完整内容；复制内容不变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("显示屏幕", selection: $panelDisplayScreen) {
                    Text("鼠标所在屏幕").tag("mouse")
                    Text("主屏幕").tag("main")
                }
                Picker("弹出位置", selection: $panelPlacement) {
                    ForEach(PanelPlacement.allCases) { placement in
                        Text(placement.title).tag(placement.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("面板尺寸")
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(PanelHeightChoice.allCases) { choice in
                            PanelHeightOption(
                                choice: choice,
                                placement: placement,
                                isSelected: panelHeight == choice.rawValue
                            ) {
                                panelHeight = choice.rawValue
                            }
                        }
                    }
                    Text("示意图以 1440 × 900 屏幕为例；点击即应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("弹出位置和尺寸点击后即应用；显示屏幕在下次打开面板时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("历史记录") {
                Picker("保存时间", selection: Binding(
                    get: { historyRetention },
                    set: { newValue in
                        if newValue == HistoryRetention.forever.rawValue,
                           historyRetention != newValue {
                            showsForeverWarning = true
                        } else {
                            historyRetention = newValue
                        }
                    }
                )) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention.rawValue)
                    }
                }
                Picker("最大存储量", selection: $historyMaximumStorageMB) {
                    Text("不限制").tag(0)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1_024)
                    Text("5 GB").tag(5_120)
                    Text("10 GB").tag(10_240)
                }
                Text("到期记录会自动删除；超过存储上限时，从最早的记录开始删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                historyStat("已保存", value: "\(model.entries.count) 条", help: .savedCount)
                historyStat("实际占用", value: historySize, help: .activeStorage)
                if model.migrationBackupBytes > 0 {
                    historyStat("旧历史备份", value: ByteCountFormatter.string(
                        fromByteCount: model.migrationBackupBytes, countStyle: .file
                    ), help: .oldBackup)
                    Text("迁移备份独立保存，不计入历史存储上限。确认新历史完整后可手动删除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("删除旧历史备份…", role: .destructive) {
                        model.confirmRemoveMigrationBackup()
                    }
                }
                if model.recoveryBytes > 0 {
                    historyStat("未关联的恢复文件", value: ByteCountFormatter.string(
                        fromByteCount: model.recoveryBytes, countStyle: .file
                    ), help: .recoveryFiles)
                    Text("这些文件未对应当前历史记录，已移到恢复目录，不计入当前历史上限。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("删除恢复文件…", role: .destructive) {
                        model.confirmRemoveRecoveryFiles()
                    }
                }
                Button(role: .destructive) {
                    model.confirmClearHistory()
                } label: {
                    LucideLabel("清空历史记录…", symbol: .trash)
                }
                .disabled(model.entries.isEmpty)
            }

            Section("快捷键与权限") {
                ForEach(AppShortcutAction.allCases, id: \.self) { action in
                    shortcutRow(action)
                }
                if let shortcutError {
                    Text(shortcutError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("点击快捷键后按新的组合键，按 Esc 取消。面板操作可用功能单键；唤起面板需组合键。冲突时保留原设置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("自动粘贴", value: pastePermissionStatus)
                Button {
                    model.openPastePermissionSettings()
                } label: {
                    LucideLabel("打开键盘事件权限设置…", symbol: .keyboard)
                }
                Text("授权后，双击记录或按 \(model.shortcut(for: .paste).displayName) 会在核对原输入位置后发送 ⌘V。无法核对或未授权时会提示手动粘贴。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("关于与隐私") {
                LabeledContent("当前版本", value: currentVersion)
                Button {
                    showsReleaseHistory = true
                } label: {
                    LucideLabel("版本记录…", symbol: .history)
                }
                Button {
                    showsPrivacyPolicy = true
                } label: {
                    LucideLabel("隐私政策…", symbol: .shieldCheck)
                }
                Text("联系开发者：584772541@qq.com")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .background {
            ShortcutKeyCapture(
                active: recordingShortcut != nil,
                onKeyDown: captureShortcut,
                onCancel: stopShortcutRecording
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
        .onDisappear { stopShortcutRecording() }
        .onChange(of: appAppearanceMode) { _, newValue in
            model.updateAppearance(newValue)
        }
        .onChange(of: panelHeight) { _, newValue in
            model.updatePanelLayout()
        }
        .onChange(of: panelPlacement) { _, _ in
            model.updatePanelLayout()
        }
        .onChange(of: historyRetention) { _, _ in
            model.applyHistoryStorageSettings()
        }
        .onChange(of: historyMaximumStorageMB) { _, _ in
            model.applyHistoryStorageSettings()
        }
        .alert("永久保存可能占用大量存储空间", isPresented: $showsForeverWarning) {
            Button("永久保存") {
                historyRetention = HistoryRetention.forever.rawValue
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史记录将不会按时间自动删除。如果最大存储量也选择“不限制”，本机占用空间可能持续增加。")
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showsReleaseHistory) {
            ReleaseHistoryView()
        }
    }

    private func shortcutRow(_ action: AppShortcutAction) -> some View {
        let shortcut = model.shortcut(for: action)
        return LabeledContent(action.title) {
            HStack(spacing: 8) {
                Button(recordingShortcut == action ? "请按新按键…" : shortcut.displayName) {
                    if recordingShortcut == action {
                        stopShortcutRecording()
                    } else {
                        model.beginShortcutRecording()
                        shortcutError = nil
                        recordingShortcut = action
                    }
                }
                .buttonStyle(.bordered)
                .help("点击后按下新的快捷键")

                if shortcut != action.defaultShortcut {
                    Button("恢复默认") {
                        applyShortcut(action.defaultShortcut, action: action)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func captureShortcut(_ event: NSEvent) {
        guard let action = recordingShortcut else { return }
        guard let shortcut = AppShortcut(event: event, requiresModifier: action == .openPanel) else {
            shortcutError = "请选择有效按键；唤起面板需要修饰键，面板操作也可以使用方向键、空格或 Return 等单键。"
            return
        }
        applyShortcut(shortcut, action: action)
    }

    private func applyShortcut(_ shortcut: AppShortcut, action: AppShortcutAction) {
        let error = model.setShortcut(shortcut, for: action)
        shortcutError = error
        if error == nil { stopShortcutRecording() }
    }

    private func stopShortcutRecording() {
        recordingShortcut = nil
        shortcutError = nil
        model.endShortcutRecording()
    }

    private func historyStat(_ title: String, value: String, help: HistoryStorageHelp) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                HistoryHelpButton(item: help)
            }
        }
    }
}

private enum HistoryStorageHelp {
    case savedCount, activeStorage, oldBackup, recoveryFiles

    var title: String {
        switch self {
        case .savedCount: "已保存"
        case .activeStorage: "实际占用"
        case .oldBackup: "旧历史备份"
        case .recoveryFiles: "未关联的恢复文件"
        }
    }

    var explanation: String {
        switch self {
        case .savedCount:
            "当前能在面板里搜索和使用的历史记录数量。重复复制同一内容通常会合并成一条，并更新最近复制时间，所以它不是你总共按过多少次复制。"
        case .activeStorage:
            "当前历史记录和它们的文字、图片、富文本、缩略图、文件副本及数据库在本机占用的空间。只记录文件位置时，原文件本身不算在这里；旧历史备份和恢复文件也另算。"
        case .oldBackup:
            "升级历史存储方式时保留的旧数据，就像迁移前的保险副本。它不出现在面板里，也不计入当前历史的存储上限。确认旧记录已完整迁入后再删除；删除后不能靠这份备份回退。"
        case .recoveryFiles:
            "磁盘上还存在这些内容文件，但它们现在没有对应的历史卡片。应用先把它们移到恢复目录，避免误删。它们不能直接从面板使用，也不计入当前历史上限；删除后无法再手动找回其中的内容。"
        }
    }
}

private struct HistoryHelpButton: View {
    let item: HistoryStorageHelp
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            LucideIcon(.circleHelp, size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("了解\(item.title)")
        .help("了解\(item.title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.headline)
                Text(item.explanation)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 330, alignment: .leading)
        }
    }
}
