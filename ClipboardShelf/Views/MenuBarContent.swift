import AppKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppController

    var body: some View {
        Button {
            model.togglePanel()
        } label: {
            LucideLabel("打开剪贴板", symbol: .clipboard)
        }

        Button {
            model.openSettings()
        } label: {
            LucideLabel("设置…", symbol: .settings)
        }

        if let status = model.statusMessage {
            Text(status)
        } else {
            Text("已保存 \(model.entries.count) 条记录")
        }

        if model.needsPastePermission {
            Button {
                model.openPastePermissionSettings()
            } label: {
                LucideLabel("打开键盘事件权限设置…", symbol: .keyboard)
            }
        }

        Divider()

        Toggle(isOn: $model.isPaused) {
            LucideLabel("暂停记录", symbol: .pause)
        }

        Button(role: .destructive) {
            model.confirmClearHistory()
        } label: {
            LucideLabel("清空历史记录…", symbol: .trash)
        }
        .disabled(model.entries.isEmpty)

        Divider()

        if !model.hotKeyRegistered {
            Text("⌘⇧V 不可用，请检查快捷键冲突")
        } else {
            Text("⌘⇧V 打开或收起")
        }

        Button {
            NSApp.terminate(nil)
        } label: {
            LucideLabel("退出 ClipHoook", symbol: .x)
        }
    }
}
