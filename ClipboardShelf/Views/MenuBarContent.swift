import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppController

    var body: some View {
        Button("打开剪贴板", systemImage: "rectangle.on.rectangle") {
            model.togglePanel()
        }

        Button("设置…", systemImage: "gearshape") {
            model.openSettings()
        }

        if let status = model.statusMessage {
            Text(status)
        } else {
            Text("已保存 \(model.entries.count) 条记录")
        }

        if model.needsPastePermission {
            Button("打开键盘事件权限设置…", systemImage: "gearshape") {
                model.openPastePermissionSettings()
            }
        }

        Divider()

        Toggle("暂停记录", isOn: $model.isPaused)

        Button("清空历史记录…", systemImage: "trash", role: .destructive) {
            model.confirmClearHistory()
        }
        .disabled(model.entries.isEmpty)

        Divider()

        if !model.hotKeyRegistered {
            Text("⌘⇧V 不可用，请检查快捷键冲突")
        } else {
            Text("⌘⇧V 打开或收起")
        }

        Button("退出拾贴") {
            NSApp.terminate(nil)
        }
    }
}
