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
            Label("设置…", systemImage: "gearshape")
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

        if model.pinnedImageCount > 0 {
            Divider()
            Button("显示全部贴图（\(model.pinnedImageCount)）") {
                model.showPinnedImages()
            }
            Button("取消全部贴图…", role: .destructive) {
                model.confirmUnpinAllImages()
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
            Text("\(model.openPanelShortcut.displayName) 不可用，请检查快捷键冲突")
        } else {
            Text("\(model.openPanelShortcut.displayName) 打开或收起")
        }

        Button {
            NSApp.terminate(nil)
        } label: {
            LucideLabel("退出 ClipHoook", symbol: .x)
        }
    }
}
