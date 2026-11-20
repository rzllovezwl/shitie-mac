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
            model.toggleQuickSearch()
        } label: {
            Label("快速搜索（\(model.shortcut(for: .quickSearch).displayName)）", systemImage: "magnifyingglass")
        }

        Button {
            model.openStagingShelf()
        } label: {
            Label(model.stagingItemCount > 0 ? "暂存箱（\(model.stagingItemCount)）" : "暂存箱", systemImage: "tray")
        }

        Menu("截图") {
            Button("截图（选窗口或拖区域 · \(model.shortcut(for: .captureRegion).displayName)）") {
                model.beginMacScreenshot(.region)
            }
            Button("整个屏幕截图（\(model.shortcut(for: .captureScreen).displayName)）") {
                model.beginMacScreenshot(.screen)
            }
            Button("长截图（\(model.shortcut(for: .captureLongScreenshot).displayName)）") {
                model.beginMacScreenshot(.long)
            }
            Divider()
            Button("截图并翻译（\(model.shortcut(for: .captureTranslate).displayName)）") {
                model.beginMacScreenshot(.region, startAction: .translate)
            }
            Button("截图并识别文字（\(model.shortcut(for: .captureRecognizeText).displayName)）") {
                model.beginMacScreenshot(.region, startAction: .recognizeText)
            }
        }

        ScreenRecordingMenu(recorder: model.screenRecorder)

        Button {
            model.openSettings(category: .general)
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
        if !model.regionCaptureHotKeyRegistered {
            Text("截图快捷键不可用，可从上方“截图”菜单操作")
        }
        ForEach([AppShortcutAction.captureTranslate, .captureRecognizeText, .captureLongScreenshot], id: \.self) { action in
            if !model.registeredScreenshotHotKeys.contains(action) {
                Text("\(action.title)快捷键不可用，可从“截图”菜单使用")
            }
        }

        Button {
            NSApp.terminate(nil)
        } label: {
            LucideLabel("退出 ClipHoook", symbol: .x)
        }
    }
}
