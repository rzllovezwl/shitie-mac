import AppKit
import AVFoundation
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, clipboard, screenshots, screenRecording, phone, shortcuts, about

    static let selectionKey = "settings.selectedCategory"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .clipboard: "剪贴板"
        case .screenshots: "截图与贴图"
        case .screenRecording: "录屏"
        case .phone: "iPhone 传图"
        case .shortcuts: "快捷键与权限"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clipboard: "list.clipboard"
        case .screenshots: "camera.viewfinder"
        case .screenRecording: "record.circle"
        case .phone: "iphone"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .clipboard: Color(nsColor: .systemTeal)
        case .screenshots: Color(nsColor: .systemBlue)
        case .screenRecording: Color(nsColor: .systemRed)
        case .phone: Color(nsColor: .systemIndigo)
        case .shortcuts: Color(nsColor: .systemPurple)
        case .about: Color(nsColor: .systemGray)
        }
    }
}

private struct SettingsLayout<Content: View>: View {
    @Binding var selection: SettingsCategory
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .frame(height: 56)

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        content
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 26)
                    .padding(.top, 13)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .id(selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClipHoook")
                        .font(.headline)
                    Text("设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 53)
            .padding(.bottom, 21)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsCategory.allCases.filter { $0 != .about }) { item in
                        sidebarRow(item)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollBounceBehavior(.basedOnSize)

            sidebarRow(.about)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.065))
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分类")
    }

    private func sidebarRow(_ item: SettingsCategory) -> some View {
        let isSelected = item == selection
        return Button {
            selection = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 25, height: 25)
                    .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 38)
            .background(isSelected ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String?
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title).accessibilityAddTraits(.isHeader)
            }
            .font(.headline)
            .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 0) {
                if #available(macOS 15.0, *) {
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            if row.id != rows.first?.id {
                                Divider().opacity(0.65)
                            }
                            row
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .padding(.vertical, 9)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12)
            .labeledContentStyle(SettingsControlRowStyle())
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

private struct SettingsControlRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

private struct SettingsShortcutKeycap: ButtonStyle {
    let recording: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .font(.body.weight(recording ? .medium : .semibold))
            .foregroundStyle(recording ? Color.accentColor : Color.primary)
            .frame(width: 174, height: 29)
            .background {
                shape.fill(Color(nsColor: .textBackgroundColor))
                if recording || configuration.isPressed {
                    shape.fill(Color.accentColor.opacity(recording ? 0.10 : 0.06))
                }
            }
            .overlay {
                shape.strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.08),
                                   lineWidth: 1)
            }
            .shadow(color: .black.opacity(recording ? 0 : 0.09), radius: 2, y: 1)
            .contentShape(shape)
    }
}

private struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        LabeledContent(title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsPicker<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let options: Options

    init(_ title: String, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
        }
    }
}

private struct ScreenshotToolDefaultRows: View {
    let tool: ScreenshotAnnotationTool
    @AppStorage private var color: Int
    @AppStorage private var storedWidth: Double?

    init(tool: ScreenshotAnnotationTool) {
        self.tool = tool
        _color = AppStorage(wrappedValue: ScreenshotAnnotationColor.red.rawValue,
                            ScreenshotAnnotationPreferences.colorKey(for: tool))
        _storedWidth = AppStorage(ScreenshotAnnotationPreferences.defaultWidthKey(for: tool))
    }

    private var width: Binding<Double> {
        Binding(get: { storedWidth ?? ScreenshotAnnotationPreferences.defaultWidth(for: tool) },
                set: { storedWidth = $0 })
    }

    var body: some View {
        SettingsPicker("默认颜色", selection: $color) {
            ForEach(ScreenshotAnnotationColor.allCases, id: \.rawValue) { color in
                Label {
                    Text(color.title)
                } icon: {
                    Image(nsImage: color.swatch).renderingMode(.original)
                }
                .tag(color.rawValue)
            }
        }
        LabeledContent(tool.widthLabel) {
            HStack(spacing: 8) {
                let value = width.wrappedValue
                Text(value == 0 ? "自动" : "\(value.formatted(.number.precision(.fractionLength(0...1)))) 点")
                    .monospacedDigit()
                Stepper(tool.widthLabel, value: width, in: tool.widthRange)
                    .labelsHidden()
            }
        }
        if tool == .text {
            Text("文字线宽用于「描边」样式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppController
    @AppStorage(AppAppearanceMode.preferenceKey) private var appAppearanceMode = AppAppearanceMode.system.rawValue
    @AppStorage("panelDisplayScreen") private var panelDisplayScreen = "mouse"
    @AppStorage("panelPlacement") private var panelPlacement = "bottom"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(StagingShelfPreference.autoRevealKey) private var stagingAutoReveal = true
    @AppStorage(HistoryStoragePolicy.retentionKey) private var historyRetention = HistoryRetention.sevenDays.rawValue
    @AppStorage(HistoryStoragePolicy.maximumMegabytesKey) private var historyMaximumStorageMB = 0
    @AppStorage(CopySoundPreference.enabledKey) private var copySoundEnabled = true
    @AppStorage(CopySoundPreference.effectKey) private var copySoundEffect = CopySoundPreference.defaultEffect
    @AppStorage(ClipboardCopyFormat.preferenceKey) private var defaultCopyFormat = ClipboardCopyFormat.original.rawValue
    @AppStorage(ClipboardGroupingPreference.key) private var automaticallyGroupMultipleCopies = true
    @AppStorage(CardPreviewPreference.enabledKey)
    private var cardFormattedPreviewEnabled = CardPreviewPreference.defaultEnabled
    @AppStorage(ScreenshotFreezePreference.enabledKey)
    private var freezeDesktopDuringScreenshot = true
    @AppStorage(ScreenshotWindowShadowPreference.enabledKey)
    private var includeWindowShadowInScreenshot = false
    @AppStorage(ScreenshotAnnotationPreferences.remembersToolAndStyleKey)
    private var remembersScreenshotAnnotationStyle = true
    @AppStorage(ScreenshotAnnotationPreferences.startupToolKey)
    private var screenshotStartupTool = ScreenshotAnnotationTool.rectangle.rawValue
    @State private var annotationDefaultsTool = ScreenshotAnnotationTool.rectangle
    @State private var showsPrivacyPolicy = false
    @State private var showsReleaseHistory = false
    @State private var showsForeverWarning = false
    @State private var showsPairingResetConfirmation = false
    @State private var recordingShortcut: AppShortcutAction?
    @State private var shortcutError: String?
    @State private var shortcutErrorAction: AppShortcutAction?

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

    @AppStorage(SettingsCategory.selectionKey) private var selectedCategory = SettingsCategory.general.rawValue

    private var category: SettingsCategory {
        SettingsCategory(rawValue: selectedCategory) ?? .general
    }

    var body: some View {
        SettingsLayout(selection: Binding(
            get: { category },
            set: { selectedCategory = $0.rawValue }
        )) {
            switch category {
            case .general:
                appearanceSettings
                soundSettings
                panelSettings
                stagingShelfSettings
            case .clipboard:
                recordingSettings
                copySettings
                quickSearchSettings
                excludedAppsSettings
                historySettings
            case .screenshots:
                captureSettings
                annotationDefaultsSettings
                pinnedSettings
            case .screenRecording:
                ScreenRecordingSettingsPane(controller: model.screenRecorder)
            case .phone:
                phoneSettings
            case .shortcuts:
                shortcutSettings
            case .about:
                aboutSettings
            }
        }
        .frame(minWidth: 690, minHeight: 500)
        .onChange(of: category) { _, _ in stopShortcutRecording() }
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
        .confirmationDialog("重置 iPhone 接收配对码？", isPresented: $showsPairingResetConfirmation) {
            Button("重置配对码") {
                model.resetPhoneScreenshotPairingCode()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧接收地址会立即失效。请把新地址完整替换进每台 iPhone 快捷指令的 URL 操作，再保存新截图验证。历史记录和现有截图不会删除。")
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showsReleaseHistory) {
            ReleaseHistoryView()
        }
    }

    private let panelShortcutActions: [AppShortcutAction] = [
        .focusSearch, .previous, .next, .toggleDetail
    ]
    private let globalShortcutActions: [AppShortcutAction] = [.openPanel, .quickSearch]

    private func isScreenshotShortcut(_ action: AppShortcutAction) -> Bool {
        action.isScreenshotCapture || [.togglePinImage, .recognizeImageText,
                                       .annotateImage, .saveImageToFile, .translateScreenshot].contains(action)
    }

    @ViewBuilder private var recordingSettings: some View {
        SettingsCard("记录") {
            SettingsSwitch("记录新复制的内容", isOn: Binding(
                get: { !model.isPaused },
                set: { model.isPaused = !$0 }
            ))
            Text("关闭设置窗口后，ClipHoook 仍会在菜单栏运行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var phoneSettings: some View {
        SettingsCard("iPhone 截图") {
            Button("查看功能介绍与设置步骤…") {
                model.openPhoneScreenshotGuide()
            }
            SettingsSwitch("接收 iPhone 截图", isOn: Binding(
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
            }
            Text("按上方指南完成 4 步。地址含私密配对码，请勿分享；发送时 iPhone 和 Mac 需在同一可信局域网。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("重置接收配对码…") {
                showsPairingResetConfirmation = true
            }
            Text("仅当地址泄露或需要断开旧 iPhone 时重置。重置后旧地址立即失效，需要重新复制新地址并替换 iPhone 模板中的 URL。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TappableHelpSection("连接自检（截图未送达时）") {
                PhoneScreenshotDiagnosticsView(model: model)
                    .padding(.top, 8)
            }
            TappableHelpSection("Wi-Fi 切换与超时提醒（可选）") {
                PhoneScreenshotWiFiGuideSteps()
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var excludedAppsSettings: some View {
        SettingsCard("不记录的应用") {
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
    }

    @ViewBuilder private var appearanceSettings: some View {
        SettingsCard("外观") {
            SettingsPicker("显示模式", selection: $appAppearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .help("切换后面板和设置窗口立即更新")
        }
    }

    @ViewBuilder private var soundSettings: some View {
        SettingsCard("声音") {
            SettingsSwitch("播放提示音", isOn: $copySoundEnabled)
            LabeledContent("复制音效") {
                HStack(spacing: 8) {
                    Picker("复制音效", selection: $copySoundEffect) {
                        ForEach(CopySoundEffect.allCases, id: \.self) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: copySoundEffect) { _, effect in
                        CopySoundPlayer.shared.playPreview(effect)
                    }
                    Button {
                        CopySoundPlayer.shared.playPreview(copySoundEffect)
                    } label: {
                        LucideLabel("试听", symbol: .play)
                    }
                }
            }
            Text("收到新 iPhone 截图或完成贴图时播放原提示音。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stagingShelfSettings: some View {
        SettingsCard("暂存箱") {
            SettingsSwitch("拖动内容时自动显示", isOn: $stagingAutoReveal)
                .onChange(of: stagingAutoReveal) { _, _ in model.updateStagingShelfPreferences() }
            Text("拖动文件、图片、文字或链接时，在鼠标所在屏幕的一侧显示暂存箱。内容以单列缩略图展示，上下滚动查看；鼠标悬停文件时显示移除按钮。选中后按空格打开剪贴板同款预览，可多选并拖到其他应用。截图时保持显示。成功拖入其他应用后移除对应项目，Esc 取消或拒收则保留。两指向屏幕侧边横滑可收起为小标签，点击展开；取出最后一项或清空后自动隐藏，也可从菜单栏手动打开。")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("已暂存") { Text("\(model.stagingItemCount) 项") }
            HStack {
                Button("打开暂存箱") { model.openStagingShelf() }
                Button("清空暂存箱…") { model.clearStagingShelf() }
                    .disabled(model.stagingItemCount == 0)
            }
            Text("文件只记录位置，不复制原文件；独立图片与文字保存在本机。最多 100 项，图片和文字合计上限 128 MB。关闭或重启应用不会清空，移除暂存不会删除原文件。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var copySettings: some View {
        SettingsCard("复制与粘贴") {
            SettingsSwitch("外部多项复制自动成组", isOn: $automaticallyGroupMultipleCopies)
            TappableHelpSection("自动成组说明") {
                Text("从访达等外部应用一次复制多个项目时，可自动保存为可展开的分组。关闭后会分别显示。在 ClipHoook 面板中多选复制只复制所选内容，不会自动成组；需要成组时可右键选择“将所选成组”或按 ⌘G。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsPicker("默认复制格式", selection: $defaultCopyFormat) {
                ForEach(ClipboardCopyFormat.allCases) { format in
                    Text(format.title).tag(format.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("普通复制、双击和 \(model.shortcut(for: .paste).displayName) 粘贴使用所选格式。纯文本只对文字与链接生效；图片和文件仍保留原内容。\(model.shortcut(for: .pastePlainText).displayName) 可单次使用纯文本粘贴。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var quickSearchSettings: some View {
        SettingsCard("快速搜索", symbol: "magnifyingglass") {
            LabeledContent("全局唤起", value: model.shortcut(for: .quickSearch).displayName)
            Text("随时唤起独立搜索浮窗，搜索文字、链接、文件名、来源应用和图片中的文字。未输入时显示最近 10 条；↑↓ 选择，回车按设置粘贴到原应用，⌘↩ 打开预览。Esc 先关闭预览，再关闭搜索。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("图片文字会在后台识别并陆续显示结果。快捷键可在“快捷键与权限 → 全局快捷键”中修改。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("打开快速搜索") { model.toggleQuickSearch() }
        }
    }

    @ViewBuilder private var panelSettings: some View {
        SettingsCard("面板") {
            SettingsSwitch("卡片展示格式预览", isOn: $cardFormattedPreviewEnabled)
                .help("在卡片中预览富文本、Markdown 和代码格式")
            SettingsPicker("显示屏幕", selection: $panelDisplayScreen) {
                Text("鼠标所在屏幕").tag("mouse")
                Text("主屏幕").tag("main")
            }
            SettingsPicker("弹出位置", selection: $panelPlacement) {
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
    }

    @ViewBuilder private var historySettings: some View {
        SettingsCard("历史记录") {
            SettingsPicker("保存时间", selection: Binding(
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
            SettingsPicker("最大存储量", selection: $historyMaximumStorageMB) {
                Text("不限制").tag(0)
                Text("100 MB").tag(100)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1_024)
                Text("5 GB").tag(5_120)
                Text("10 GB").tag(10_240)
            }
            TappableHelpSection("收藏、钉住与自动清理") {
                Text("选中卡片可按 \(model.shortcut(for: .toggleFavorite).displayName) 收藏，也可拖到面板顶部的收藏分类。点击星标可取消收藏。按 \(model.shortcut(for: .toggleShelfPin).displayName) 或右键可钉住卡片，将它固定在面板前端。再次按快捷键或点击蓝色图钉可取消钉住。快捷键可在“快捷键与权限”中修改。收藏和钉住的卡片会长期保留，容量超过上限时也会跳过它们。普通历史到期后会自动删除，超过容量上限时优先清理最早的普通记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if HistoryStorageReminder.shouldExplainUncappedGrowth(
                actualBytes: model.historyStorageBytes,
                maximumBytes: HistoryStoragePolicy(defaults: .standard).maximumBytes
            ) {
                Text("当前未设置存储上限，历史已占用 \(historySize)。如需控制空间，可在上方选择最大存储量；应用不会因为这条提醒自行删除记录。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            historyStat("已保存", value: "\(model.entries.count) 条", help: .savedCount)
            historyStat("实际占用", value: historySize, help: .activeStorage)
            TappableHelpSection("存储管理") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.migrationBackupBytes > 0 {
                        HistoryStorageActionRow(
                            title: "旧历史备份",
                            details: "用于迁移后的回退，不计入历史存储上限。",
                            size: model.migrationBackupBytes,
                            help: .oldBackup,
                            buttonTitle: "删除备份…"
                        ) { model.confirmRemoveMigrationBackup() }
                        Divider()
                    }
                    if model.recoveryBytes > 0 {
                        HistoryStorageActionRow(
                            title: "未关联的恢复文件",
                            details: "这些文件单独存放，不计入历史存储上限。",
                            size: model.recoveryBytes,
                            help: .recoveryFiles,
                            buttonTitle: "删除恢复文件…"
                        ) { model.confirmRemoveRecoveryFiles() }
                        Divider()
                    }
                    HistoryStorageActionRow(
                        title: "剪贴板历史",
                        details: "清空会一并删除收藏和历史对应的贴图副本。",
                        buttonTitle: "清空历史记录…",
                        isEnabled: !model.entries.isEmpty
                    ) { model.confirmClearHistory() }
                }
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private var pinnedSettings: some View {
        SettingsCard("桌面贴图") {
            historyStat("已钉住", value: "\(model.pinnedImageCount) 张", help: .pinnedStorage)
            LabeledContent("贴图副本占用", value: ByteCountFormatter.string(
                fromByteCount: model.pinnedStorageBytes, countStyle: .file
            ))
            DisclosureGroup("贴图操作方法") {
                Text("右键图片卡片或在预览中选择“钉在桌面”。点击贴图或按 Esc 可收起剪贴板面板。拖动贴图可移动，双指捏合可缩放，双指上下滑动可调整透明度，最低 10%。降低透明度时会隐藏系统阴影。鼠标悬停时，工具条会显示在图片外侧。点击缩放或透明度图标可打开滑杆，点 1:1 恢复原始大小。铺满屏幕时，可右键贴图调整。双击贴图或点叉号取消钉住。贴图副本不计入历史存储上限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if model.pinnedImageCount > 0 {
                Button("显示全部贴图") { model.showPinnedImages() }
                Button("取消全部贴图…", role: .destructive) {
                    model.confirmUnpinAllImages()
                }
            }
        }
    }

    @ViewBuilder private var shortcutSettings: some View {
        SettingsCard("全局快捷键", symbol: "command") {
            ForEach(globalShortcutActions, id: \.self) { shortcutRow($0) }
            Text("在其他应用中也可使用。点击按键录制，按 Esc 取消；与已有功能或系统注册冲突时保留原设置。")
                .font(.footnote).foregroundStyle(.secondary)
            if !model.quickSearchHotKeyRegistered {
                Text("快速搜索快捷键未注册成功，请更换组合键；仍可从菜单栏打开。")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        SettingsCard("面板快捷键", symbol: "rectangle.bottomthird.inset.filled") {
            ForEach(panelShortcutActions, id: \.self) { shortcutRow($0) }
            Text("点击右侧按键开始录制，按 Esc 取消。仅在剪贴板面板中生效，可使用功能单键。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        SettingsCard("剪贴板快捷键", symbol: "clipboard") {
            ForEach(AppShortcutAction.allCases.filter {
                !panelShortcutActions.contains($0) && !globalShortcutActions.contains($0) && !isScreenshotShortcut($0) && !$0.isAnnotationTool && !$0.isScreenRecording
            }, id: \.self) { shortcutRow($0) }
        }
        SettingsCard("截图与贴图快捷键", symbol: "camera.fill") {
            ForEach(AppShortcutAction.allCases.filter(isScreenshotShortcut), id: \.self) {
                shortcutRow($0)
            }
        }
        SettingsCard("标注工具快捷键", symbol: "pencil.and.outline") {
            ForEach(AppShortcutAction.allCases.filter(\.isAnnotationTool), id: \.self) {
                shortcutRow($0)
            }
            Text("仅在截图标注或图片标注时切换工具。输入文字、选择文件或查看识别结果时，字母键用于正常输入。回车完成钢笔路径，Esc 取消当前路径。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        SettingsCard("录屏快捷键", symbol: "record.circle") {
            ForEach(AppShortcutAction.allCases.filter(\.isScreenRecording), id: \.self) { shortcutRow($0) }
            Text("开始录屏先选择范围；录制时再次按开始键将结束并预览，确认保存后才加入历史。Esc 仅取消选区和倒计时。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        SettingsCard("系统权限", symbol: "lock.shield") {
            LabeledContent("自动粘贴", value: pastePermissionStatus)
            Button {
                model.openPastePermissionSettings()
            } label: {
                LucideLabel("打开键盘事件权限设置…", symbol: .keyboard)
            }
            Text("授权后，双击记录或按 \(model.shortcut(for: .paste).displayName) 会在核对原输入位置后发送 ⌘V。无法核对或未授权时会提示手动粘贴。若系统设置已允许，但这里仍显示“需要授权”，请从菜单栏退出 ClipHoook 后重新打开。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("屏幕录制权限", value: CGPreflightScreenCaptureAccess()
                           ? "已允许" : "需要授权")
            Button("打开屏幕录制权限设置…") {
                model.openScreenRecordingSettings()
            }
        }
    }

    @ViewBuilder private var captureSettings: some View {
        SettingsCard("Mac 截图") {
            SettingsSwitch("截图时冻结屏幕画面", isOn: $freezeDesktopDuringScreenshot)
            TappableHelpSection("冻结画面说明") {
                Text("默认开启。按截图快捷键时先固定可截取的屏幕画面；之后选择、移动和调整区域都使用这一帧。视频仍在后台播放，不会被暂停。若屏幕上有应用禁止系统截取，该屏幕沿用实时选区并在截取受限内容时提示。关闭后按当前实时画面截图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSwitch("窗口截图保留阴影", isOn: $includeWindowShadowInScreenshot)
            TappableHelpSection("窗口阴影说明") {
                Text("默认关闭。单击窗口截图时只截取选中的窗口；开启后同时保留系统绘制的窗口阴影。此设置不影响拖选区域或整个屏幕截图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsPicker("打开标注时", selection: $screenshotStartupTool) {
                ForEach(ScreenshotAnnotationTool.allCases, id: \.rawValue) { tool in
                    Text("默认为\(tool.title)工具").tag(tool.rawValue)
                }
                Text("记住上次选择").tag(ScreenshotAnnotationPreferences.rememberLastTool)
            }
            SettingsSwitch("记住标注样式和线宽", isOn: $remembersScreenshotAnnotationStyle)
            TappableHelpSection("标注偏好说明") {
                Text("截图和图片标注会应用各工具的默认颜色与线宽。开启样式记忆后，图形和文字样式、荧光笔不透明度及画布上调整过的线宽可以沿用到下次。你在设置中指定的默认线宽优先。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TappableHelpSection("识别与翻译说明") {
                Text("截图翻译和截图识别均在选好窗口或区域后自动开始，不用再点工具按钮。处理中显示扫描动画；翻译默认中英互译，译文直接覆盖到图片，识别结果可复制。完成或钉住前不会新增图片记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TappableHelpSection("截图快捷键说明") {
                Text("截图工具打开时，可按 \(model.shortcut(for: .recognizeImageText).displayName) 识别文字、\(model.shortcut(for: .translateScreenshot).displayName) 翻译、\(model.shortcut(for: .togglePinImage).displayName) 钉住。按 \(model.shortcut(for: .saveImageToFile).displayName) 或在高级工具中点“保存为…”，可将当前画面保存为 PNG。卡片、预览和截图工具共享这些按键，可在“快捷键与权限”中修改。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TappableHelpSection("长截图操作说明") {
                Text("按 \(model.shortcut(for: .captureLongScreenshot).displayName) 或从菜单栏的“截图”选择“长截图”。框选滚动内容区域后慢慢向下滚动，每次保留约三分之一重叠。也可在普通截图的工具栏点“长截图”，用当前选区开始。点“完成”可预览、裁剪、标注或导出 PNG。快捷键可在“快捷键与权限”中修改。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TappableHelpSection("截图操作说明") {
                Text("按 \(model.shortcut(for: .captureRegion).displayName) 进入截图；可在“快捷键与权限”修改。鼠标移到窗口上会高亮，单击截取整个窗口；按住拖动可自由选择区域，Shift 锁定单轴，Option 固定按下点、沿拖动方向等宽高选择。准星旁的玻璃放大面板显示局部像素和色值，操作提示位于面板内，按 ⌘C 可复制色值。松手后随时可拖动选区边框移动，或拖动四角和四边的八个锚点调整大小；已有标注不会被拉伸，工具栏会跟随选区。选区内部的空白处用于绘制当前标注，已有标注可直接拖动编辑。点击“完成并复制”或双击截图区域可保存并复制，按 Esc 或点击“取消”不会保存。截图卡片会显示所截内容的来源应用。首次使用需允许屏幕录制权限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TappableHelpSection("标注工具说明") {
                Text("工具栏提供矩形、椭圆、箭头、文字、放大镜、遮盖、荧光笔、画笔、钢笔、贴图、数字标记和区域高亮；首次默认圆角空心矩形。绘制矩形或椭圆时按住 Shift 可锁定单轴；按住 Option 则固定按下点，沿鼠标拖动方向绘制正方形或正圆；拖动已有形状锚点时按住 Option，固定对侧锚点等宽高调整。画笔默认 4 点，自由拖动绘制，按住 Shift 可从落笔点画直线。钢笔单击添加折点，拖动拉出贝塞尔手柄，回车或双击完成路径，点击首节点可闭合，Esc 取消当前路径；完成后可拖动节点与手柄编辑。贴图可从剪贴板或选择 PNG、SVG、JPEG 等图片文件导入，拖动放置或单击使用适合大小，默认按原比例调整，Option 可自由调整宽高；图片嵌入标注记录，重开仍可编辑。矩形 R、椭圆 O、文字 T、画笔 L、箭头 E、遮盖 M、钢笔 P，均可在“快捷键与权限”修改。数字标记连续点击即可依次添加 1、2、3…，撤销后编号回退；荧光笔按住 Shift 可画直线，默认不透明度为 50%，可在旁边的下拉菜单调整。区域高亮保留框内原亮度，压暗框外。放大镜默认放大 2 倍，拖动绘制椭圆，按住 Shift 绘制正圆；放置后拖八个锚点调整大小，上下拖动旁边蓝色菱形调整 1–8 倍，倍率和尺寸可撤销并随图片保存。鼠标悬停在箭头、空心矩形、空心椭圆或画笔笔迹上，两指上下滑动可调线宽，之后绘制的同类标注会使用该线宽。点识别文字可查看和复制结果，按 Esc 先关闭识别窗口，再按一次才取消截图。点翻译会自动识别主要语言，英文译中文、中文译英文，并把译文直接覆盖到截图中的原文位置；点旁边的下拉箭头可选择原文和译文语言，首次使用其他语言时按 macOS 提示下载语言包。再次点翻译或撤销可恢复原文。点钉住会保存最终图片并贴在截图选区原位置。识别和翻译不会先保存截图；只有完成或钉住才会新增图片卡片。历史中的图片也能通过右键或预览再次标注，再次保存会新增图片卡片并保留原图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var annotationDefaultsSettings: some View {
        SettingsCard("标注工具默认样式") {
            SettingsPicker("工具", selection: $annotationDefaultsTool) {
                ForEach(ScreenshotAnnotationTool.toolsWithDefaultAppearance, id: \.rawValue) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            ScreenshotToolDefaultRows(tool: annotationDefaultsTool).id(annotationDefaultsTool)
        }
    }

    @ViewBuilder private var aboutSettings: some View {
        SettingsCard("关于与隐私") {
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

    @ViewBuilder private func shortcutRow(_ action: AppShortcutAction) -> some View {
        let shortcut = model.shortcut(for: action)
        let isRecording = recordingShortcut == action
        LabeledContent(action.title) {
            HStack(spacing: 8) {
                if shortcut != action.defaultShortcut {
                    Button {
                        applyShortcut(action.defaultShortcut, action: action)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("恢复默认（\(action.defaultShortcut.displayName)）")
                    .accessibilityLabel("恢复\(action.title)的默认快捷键")
                }

                Button {
                    if isRecording {
                        stopShortcutRecording()
                    } else {
                        model.beginShortcutRecording()
                        shortcutError = nil
                        recordingShortcut = action
                    }
                } label: {
                    Text(isRecording ? "请按新快捷键…" : shortcut.displayName)
                        .tracking(isRecording ? 0 : 0.8)
                }
                .buttonStyle(SettingsShortcutKeycap(recording: isRecording))
                .help(isRecording ? "按 Esc 取消录制" : "点击后按下新的快捷键")
                .accessibilityLabel("\(action.title)快捷键")
                .accessibilityValue(isRecording ? "正在录制" : shortcut.displayName)
            }
        }
        if shortcutErrorAction == action, let shortcutError {
            Text(shortcutError)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func captureShortcut(_ event: NSEvent) {
        guard let action = recordingShortcut else { return }
        guard let shortcut = AppShortcut(event: event, requiresModifier: action.requiresModifier,
                                        allowsPrintableKey: action.isAnnotationTool) else {
            shortcutErrorAction = action
            shortcutError = action.isAnnotationTool
                ? "请选择字母、数字或组合键；Esc、回车、方向键及常用编辑快捷键保留用于编辑。"
                : "请选择有效按键；截图与全局快捷键需要修饰键，面板操作也可以使用方向键、空格或 Return 等单键。"
            return
        }
        applyShortcut(shortcut, action: action)
    }

    private func applyShortcut(_ shortcut: AppShortcut, action: AppShortcutAction) {
        let error = model.setShortcut(shortcut, for: action)
        shortcutErrorAction = error == nil ? nil : action
        shortcutError = error
        if error == nil { stopShortcutRecording() }
    }

    private func stopShortcutRecording() {
        recordingShortcut = nil
        shortcutErrorAction = nil
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

private struct HistoryStorageActionRow: View {
    let title: String
    let details: String
    var size: Int64? = nil
    var help: HistoryStorageHelp? = nil
    let buttonTitle: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(title).fontWeight(.medium)
                    if let help { HistoryHelpButton(item: help) }
                }
                .frame(minHeight: 20, alignment: .leading)
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 20)
                }
                Button(buttonTitle, role: .destructive, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isEnabled)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum HistoryStorageHelp {
    case savedCount, activeStorage, pinnedStorage, oldBackup, recoveryFiles

    var title: String {
        switch self {
        case .savedCount: "已保存"
        case .activeStorage: "实际占用"
        case .pinnedStorage: "已钉住"
        case .oldBackup: "旧历史备份"
        case .recoveryFiles: "未关联的恢复文件"
        }
    }

    var explanation: String {
        switch self {
        case .savedCount:
            "当前能在面板里搜索和使用的历史记录数量。重复复制同一内容通常会合并成一条，并更新最近复制时间，所以它不是你总共按过多少次复制。"
        case .activeStorage:
            "当前历史记录和它们的文字、图片、富文本、缩略图、文件副本及数据库在本机占用的空间。桌面贴图副本、旧历史备份和恢复文件另算。"
        case .pinnedStorage:
            "钉在桌面的图片有独立副本。历史自动到期后仍保留贴图；主动删除对应历史记录或清空历史时，会同时取消贴图。关闭贴图窗口只取消钉住，不删除仍存在的历史记录。"
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

private struct ScreenRecordingSettingsPane: View {
    @ObservedObject var controller: ScreenRecordingController
    @State private var folder = ScreenRecordingDestination.label
    var body: some View {
        Group {
            SettingsCard("画面", symbol: "display") {
                Picker("默认录制范围", selection: preference(\.scope)) {
                    ForEach(ScreenRecordingScope.allCases) { Text($0.title).tag($0) }
                }
                Picker("清晰度", selection: preference(\.quality)) {
                    ForEach(ScreenRecordingQuality.allCases) { Text($0.title).tag($0) }
                }
                Picker("帧率", selection: preference(\.frameRate)) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                Picker("开始前倒计时", selection: preference(\.countdown)) {
                    Text("不倒计时").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5)
                }
                SettingsSwitch("显示鼠标指针", isOn: preference(\.showsCursor))
                SettingsSwitch("突出鼠标点击", isOn: preference(\.highlightsClicks))
            }
            SettingsCard("声音", symbol: "waveform") {
                SettingsSwitch("录制系统声音", isOn: preference(\.systemAudio))
                SettingsSwitch("录制麦克风", isOn: preference(\.microphone))
                Picker("麦克风设备", selection: preference(\.microphoneDeviceID)) {
                    Text("系统默认").tag(String?.none)
                    ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) {
                        Text($0.localizedName).tag(Optional($0.uniqueID))
                    }
                }
                Text("仅在开启麦克风并开始录屏时请求麦克风权限。播放受保护内容的应用可能不允许录制画面或声音。")
                    .font(.footnote).foregroundStyle(.secondary)
                if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    Button("打开麦克风权限设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            SettingsCard("录制与保存", symbol: "folder") {
                SettingsSwitch("录制时显示控制条", isOn: preference(\.showsControls))
                LabeledContent("保存位置") {
                    Text(folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("选择…") { ScreenRecordingDestination.chooseDirectory() }
                }
                Text("结束后先预览，可裁剪时长并选择画质。点击“保存…”确认位置后才导出 MP4 并加入历史，默认位置为“下载 / ClipHoook”。取消保存可继续预览，关闭窗口保留待保存片段和裁剪范围，点击“放弃”才删除。历史只引用已确认保存的视频。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsCard("操作方法", symbol: "questionmark.circle") {
                Text("从菜单栏点击“录屏…”，或使用录屏快捷键。拖选区域或点击窗口，调整范围和声音后点绿色播放按钮开始，点红色方块结束。整个屏幕录制使用鼠标所在屏幕。")
                Text("录制中可暂停、继续或开关麦克风；隐藏控制条后可从菜单栏恢复。预览中点击“裁剪时长”，拖动首尾选择保留片段，再确认保存。关闭预览后可从菜单栏“查看待保存录屏…”重新打开。")
                Text("录屏使用实时画面，与截图的冻结选项独立。锁屏、休眠或退出时会结束录制并暂存片段，重开后由你确认保存。未完成的异常片段不保证可恢复。快捷键可在“快捷键与权限”中修改。")
            }.font(.callout)
        }
        .disabled(controller.phase.isActive)
        .onAppear { if controller.phase == .idle { controller.preferences = ScreenRecordingPreferences() } }
        .onReceive(NotificationCenter.default.publisher(for: .recordingDestinationChanged)) { _ in folder = ScreenRecordingDestination.label }
    }
    private func preference<T>(_ key: WritableKeyPath<ScreenRecordingPreferences, T>) -> Binding<T> {
        Binding(get: { controller.preferences[keyPath: key] }, set: { value in controller.update { $0[keyPath: key] = value } })
    }
}
