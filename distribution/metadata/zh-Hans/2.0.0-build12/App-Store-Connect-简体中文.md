# App Store Connect 填写稿

ClipHoook macOS 版 **2.0.0（12）**，以已发布的 **1.1.0（6）** 为更新基线。构建 12 纳入开发版 338 的截图、录屏、暂存箱、快速搜索及面板更新。

## 重新提审

1. 用 Transporter 上传 `ClipHoook-2.0.0-build12-AppStore.pkg`。等待 App Store Connect 处理后，检查 macOS 构建号显示为 12。[Apple 构建上传指南](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
2. 在 ClipHoook 的 macOS **2.0.0** 版本页或待解决的审核提交中编辑该版本，在「构建版本」选择 **12**。有需要时先把旧构建 9 从该版本的选择中移除。[Apple 选择构建指南](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/)
3. 将下方商店字段和英文审核备注填入对应位置。更新 [公开隐私政策](https://www.kdocs.cn/l/ctnEjGO8RqCZ) 后确认未登录也可访问，沿用现有的支持网址。核对当前版本的 Mac 截图、审核联系方式和现有年龄分级。
4. 按 [人工验证清单](人工验证清单.md) 复测。针对 2.4.5，可在 App 审核消息中粘贴下方中文或英文回复，说明已经更换为构建 12。
5. 确认提交页已选择 12 并保存后，从审核提交详情页重新提交。[Apple 处理未解决审核问题的指南](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/manage-a-submission-with-unresolved-issues/)

原提交编号 `a4cddb33-c86a-4082-90c4-c7e5a124bc69`。

## 名称

```text
ClipHoook-剪贴板历史与截图
```

## 副标题

```text
快速搜索、侧边暂存与录屏
```

## 推广文本

```text
快速找回复制过的文字、图片和文件，或拖到侧边暂存箱后跨应用使用。用截图标注讲清细节，用录屏记录操作过程，裁剪后再保存。
```

## 关键词

```text
分类收藏,全局搜索,文件暂存,长截图,图片标注,文字识别,桌面贴图,OCR
```

## 描述

```text
ClipHoook 是一款菜单栏剪贴板、截图和录屏工具。复制过的文字、链接、富文本、图片和文件位置可以在本机查找、整理与再次使用。

快速找到复制过的内容
• 默认按 ⌘⇧V 打开历史面板，按 ⌘⇧空格唤起独立搜索。
• 搜索文字、链接、文件名、来源应用和图片中的文字。搜索浮窗在未输入时显示最近 10 条记录。
• 双击卡片或按回车可复制选中内容并收起面板。回到目标应用后，按 ⌘V 粘贴。
• 文字卡片可直接编辑，支持多选复制、纯文本复制和成组整理。

收藏与跨应用暂存
• 为常用内容创建带 Emoji 的收藏分类，把卡片钉在面板前端，或拖动调整卡片顺序。
• 按内容类型和日期筛选，查看每天仍保留的记录。
• 将文件、图片、文字或链接拖入侧边暂存箱，切换应用后继续拖出。
• 按空格预览暂存内容。向屏幕侧边横滑收起暂存箱，点击边缘标签后展开。

截图、标注与贴图
• 截取区域、窗口或整个屏幕，支持冻结画面和手动滚动长截图。
• 使用箭头、文字、马赛克、画笔、钢笔、贴图和放大镜等工具编辑截图。
• 裁剪已有图片，复制或移动标注元素，识别图片中的文字。将图片钉在桌面后可调整缩放和透明度。
• 可在同一局域网内接收由 iPhone 快捷指令主动发送的截图。

录屏与裁剪
• 录制区域、窗口或显示器，支持暂停、继续和鼠标点击提示。系统声音与麦克风可分别设置。
• 录制结束后先预览，可裁剪视频时长并选择画质。确认保存后导出 MP4，并在历史中添加视频记录。

历史、暂存内容和录屏草稿在本机保存。可在设置中调整快捷键、历史保留时间和存储上限，也可暂停记录或排除指定应用。适用于 macOS 14.0 或更新版本，部分翻译功能因系统版本而异。
```

## 此版本的新增内容

```text
• 新增区域、窗口和显示器录屏。支持暂停继续、鼠标点击提示、可选系统声音和麦克风，录制结束后可裁剪时长并确认保存。
• 新增侧边暂存箱与全局快速搜索。文件、图片和文字可跨应用拖放，剪贴板历史可按文字、来源和图片文字搜索。
• 支持自定义收藏分类、卡片钉住和拖动排序，并更新面板标签栏和工具图标。
• 优化冻结截图和图片编辑，支持裁剪图片、复制标注元素及 Option 拖动复制。
• 双击剪贴板卡片或按回车现在会复制内容并收起面板。请在目标应用中按 ⌘V 粘贴。
```

## App 审核备注（英文）

```text
ClipHoook 2.0.0 (build 12) is a sandboxed macOS menu-bar utility for clipboard history, screenshots, and screen recording. You can test the features below without an account. Minimum system version is macOS 14.0.

Guideline 2.4.5
This build removes cross-app automatic paste, synthetic keyboard-event posting, and Accessibility queries for the focused UI element of another app. The related permission prompt and settings link have been removed. To verify the change, leave Accessibility access off for ClipHoook, copy a short line in TextEdit, and open the clipboard panel with Command-Shift-V or the menu-bar icon. Double-click the history card. This copies the item to the system clipboard and dismisses the panel. ClipHoook returns to the previous app when available. Press Command-V yourself to paste. Return in the panel or in Quick Search also copies the selection for manual paste. The card context menu offers Copy and Copy Plain Text for supported items.

Clipboard and staging
Copy text and an image in another app to populate history. Press Command-Shift-Space to open Quick Search. It shows up to 10 recent items with an empty query. Type to search and press Command-Return to preview. Use the plus button in the history tab bar to create a collection, or drag to an existing collection to add the card. Drag a local file towards the side staging shelf to store it, then drag it to a destination that accepts files. Space previews a selected staging item. The menu-bar Staging Shelf item opens it manually.

Screenshots and annotation
Press Option-A, drag a region or click a window, and use the annotation toolbar to mark or copy the result. Option-W captures the display and Command-Shift-D opens manual scrolling capture. Command-E on an image card opens annotation and cropping. Command-E on an editable text card opens the text editor.

Screen recording
Press Option-R, select a region, window, or display, then click Start. Press Option-Shift-R to pause or resume. Press Option-R again or click Stop to open the recording preview. Use Trim Duration to select the retained interval and Save to choose the MP4 destination. A completed recording appears in history after the save is confirmed. Closing the preview retains a local draft that can be reopened from the menu bar.

Permissions and storage
macOS screen capture permission is used for screenshots and screen recording. System audio can be disabled before recording. The microphone is off by default and is requested only when microphone recording is enabled. Recording drafts and content history stay on the Mac. Exported videos are saved to the user-selected destination. The optional iPhone screenshot receiver is off by default and accepts user-configured Shortcuts uploads from the same local network through a paired address. The bundled privacy policy is available in Settings.
```

## 2.4.5 审核回复（中文）

```text
App 审核团队您好，

感谢您就 ClipHoook 2.0.0（9）提出的准则 2.4.5 审核意见。本次提供 2.0.0（12）供审核。

我们已移除跨应用自动粘贴、模拟键盘事件、对其他应用的辅助功能焦点查询，以及相关权限提示和设置入口。双击剪贴板卡片或按回车会将选中的内容复制到系统剪贴板并收起面板。用户在目标应用中亲自按 ⌘V 完成粘贴。

可在 ClipHoook 的辅助功能权限关闭时验证。先在文本编辑中复制一行内容，按 ⌘⇧V 打开 ClipHoook，双击该历史卡片，再在文本编辑中按 ⌘V。审核备注也提供了截图和录屏的测试步骤，以及屏幕录制与麦克风权限的用途。

谢谢。
```

## 2.4.5 审核回复（英文）

```text
Hello App Review Team,

Thank you for the feedback on ClipHoook 2.0.0 (build 9) under Guideline 2.4.5. We are providing build 12 for review.

We removed cross-app automatic paste, synthetic keyboard-event posting, and Accessibility queries for the focused UI element of another app. We also removed the related permission prompt, settings link, and UI copy. Double-clicking a clipboard card or pressing Return copies the selected item to the system clipboard and closes the panel. The user presses Command-V in the destination app to paste.

To verify, leave Accessibility access off for ClipHoook, copy a line in TextEdit, open ClipHoook with Command-Shift-V, and double-click the history card. Then press Command-V in TextEdit. The Review Notes include the test steps and describe the separate screen capture and microphone permissions.

Thank you.
```

## 隐私与出口合规

- 公开隐私政策使用 [构建 12 政策纯文本](隐私政策.txt)。商店包内已随附同一份政策的 Markdown 版本，涵盖录屏草稿、系统声音、麦克风、暂存箱和手动粘贴。
- 依据此构建的实现，剪贴板历史、截图、暂存、录屏和文字识别在用户的 Mac 上处理。可选的 iPhone 截图接收由用户配置，通过同一局域网传到用户自己的 Mac。提交时可按此实现选择「不收集数据」。[Apple App 隐私详情](https://developer.apple.com/app-store/app-privacy-details/)
- 此包声明 `ITSAppUsesNonExemptEncryption = NO`。源码使用系统框架和本机 SHA-256 去重，iPhone 截图连接使用局域网 HTTP。出口合规字段按 App Store Connect 实际提示填写。[Apple 加密文稿指南](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)

## 商店截图

首页可展示历史面板与收藏分类，其余截图可覆盖暂存箱、快速搜索、截图标注和录屏预览。使用实际候选界面与测试数据，移除仍显示旧自动粘贴入口的截图。尺寸以 Apple 的 macOS 一栏为准。[Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
