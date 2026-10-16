import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppController
    @AppStorage("panelDisplayScreen") private var panelDisplayScreen = "mouse"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(CopySoundPreference.enabledKey) private var copySoundEnabled = true
    @State private var showsPrivacyPolicy = false

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
                Picker("面板高度", selection: $panelHeight) {
                    Text("紧凑").tag("compact")
                    Text("标准").tag("standard")
                    Text("宽敞").tag("large")
                }
                Text("面板设置在下次打开时生效。")
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
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}
