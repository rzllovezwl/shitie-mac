import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppController
    @AppStorage("panelDisplayScreen") private var panelDisplayScreen = "mouse"
    @AppStorage("panelHeight") private var panelHeight = "standard"

    private var historySize: String {
        let bytes = model.entries.reduce(0) { $0 + $1.byteCount }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var pastePermissionStatus: String {
        switch PasteService.availability(requestPermission: false) {
        case .ready: "已允许"
        case .needsPermission: "需要授权"
        case .appStoreBuild: "复制后手动按 ⌘V"
        }
    }

    var body: some View {
        Form {
            Section("记录") {
                Toggle("记录新复制的内容", isOn: Binding(
                    get: { !model.isPaused },
                    set: { model.isPaused = !$0 }
                ))
                Text("关闭设置窗口后，拾贴仍会在菜单栏运行。")
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
                LabeledContent("自动粘贴", value: pastePermissionStatus)
                #if !APP_STORE
                Button("打开键盘事件权限设置…", systemImage: "gearshape") {
                    model.openPastePermissionSettings()
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
    }
}
