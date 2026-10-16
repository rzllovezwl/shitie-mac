import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppController
    @AppStorage("panelDisplayScreen") private var panelDisplayScreen = "mouse"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(CopySoundPreference.enabledKey) private var copySoundEnabled = true
    @State private var showsPrivacyPolicy = false
    @State private var showsReleaseHistory = false

    private var currentVersion: String {
        let version = ReleaseHistory.currentVersion()
        return "\(version.version)（\(version.build)）"
    }

    private var historySize: String {
        let bytes = model.entries.reduce(0) { $0 + $1.byteCount }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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

            Section("声音") {
                Toggle("复制后播放提示音", isOn: $copySoundEnabled)
                Button("试听提示音", systemImage: "play.circle") {
                    CopySoundPlayer.shared.playPreview()
                }
                Text("每次剪贴板内容变化时播放；关闭录制也不会关闭提示音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("面板") {
                Picker("显示屏幕", selection: $panelDisplayScreen) {
                    Text("鼠标所在屏幕").tag("mouse")
                    Text("主屏幕").tag("main")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("面板高度")
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(PanelHeightChoice.allCases) { choice in
                            PanelHeightOption(
                                choice: choice,
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
                Text("显示屏幕在下次打开面板时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("历史记录") {
                LabeledContent("已保存", value: "\(model.entries.count) 条")
                LabeledContent("内容大小", value: historySize)
                Button("清空历史记录…", systemImage: "trash", role: .destructive) {
                    model.confirmClearHistory()
                }
                .disabled(model.entries.isEmpty)
            }

            Section("快捷键与权限") {
                LabeledContent("打开面板", value: "⌘⇧V")
                LabeledContent("双击自动粘贴", value: pastePermissionStatus)
                Button("打开键盘事件权限设置…", systemImage: "gearshape") {
                    model.openPastePermissionSettings()
                }
                Text("授权后，双击记录会收起面板并向原应用发送 ⌘V。未授权时仍可复制后手动粘贴。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("关于与隐私") {
                LabeledContent("当前版本", value: currentVersion)
                Button("版本记录…", systemImage: "clock.arrow.circlepath") {
                    showsReleaseHistory = true
                }
                Button("隐私政策…", systemImage: "hand.raised") {
                    showsPrivacyPolicy = true
                }
                Text("联系开发者：584772541@qq.com")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .onChange(of: panelHeight) { _, newValue in
            model.updatePanelHeight(newValue)
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showsReleaseHistory) {
            ReleaseHistoryView()
        }
    }
}

private enum PanelHeightChoice: String, CaseIterable, Identifiable {
    case compact, standard, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "宽敞"
        }
    }

    var exampleHeight: CGFloat {
        PanelLayout.frame(
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            heightPreference: rawValue
        ).height
    }
}

private struct PanelHeightOption: View {
    let choice: PanelHeightChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let panelHeight = geometry.size.height * choice.exampleHeight / 900
                    let cardHeight = max(8, panelHeight - 14)
                    let cardWidth = min((geometry.size.width - 30) / 3, cardHeight * 0.75)

                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.secondary.opacity(0.45), lineWidth: 1)
                            }

                        VStack {
                            HStack(spacing: 2) {
                                ForEach(0..<3) { _ in
                                    Circle()
                                        .fill(.secondary.opacity(0.45))
                                        .frame(width: 3, height: 3)
                                }
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(6)

                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.primary.opacity(0.35))
                                .frame(width: 20, height: 2)
                            HStack(alignment: .top, spacing: 3) {
                                ForEach(0..<3) { index in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(index == 0 ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.18))
                                        .frame(width: cardWidth, height: cardHeight)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: panelHeight)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                        }
                        .padding(3)
                    }
                }
                .aspectRatio(1.6, contentMode: .fit)

                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    Text(choice.title)
                }
                .font(.subheadline.weight(isSelected ? .semibold : .regular))

                Text("\(Int(choice.exampleHeight)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("面板高度：\(choice.title)，示意高度 \(Int(choice.exampleHeight)) 点")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}
