# App Review 测试说明草稿

下面是给 App Store Connect“审核备注”的草稿。使用前需用实际上传的 **1.0.0 (4)** 包完成对应操作验证，再复制。

## English

ClipHoook is a local clipboard history app for macOS. It stores supported copied text, HTTP(S) links, PNG and TIFF images only in its App Sandbox container. It has no account, analytics SDK, advertising SDK or clipboard-history upload.

To test: Copy a short piece of text in TextEdit. If macOS asks for clipboard access, allow the app to access the clipboard for ongoing history recording. Place the insertion point in TextEdit and press Command-Shift-V. Double-click the saved text card. The panel closes, ClipHoook reactivates the previous app, and sends one Command-V event to paste the selected item. The user must grant the system permission for posting keyboard events; the button in ClipHoook Settings > Keyboard Shortcut & Permissions opens the relevant macOS privacy settings. If permission is declined, double-click still copies the item and closes the panel, so the user can paste manually with Command-V.

This feature uses the public Core Graphics `CGPreflightPostEventAccess`, `CGRequestPostEventAccess`, and `CGEvent.postToPid` APIs. It does not use `AXUIElement`, Apple Events automation, or temporary App Sandbox exception entitlements. The user initiates each paste by double-clicking a card. Clipboard history can be paused or cleared in Settings. The privacy policy is available in Settings > Privacy Policy.

## 中文核对

- 在文本编辑等输入框复制一段演示文字，允许 ClipHoook 持续读取剪贴板。
- 将光标放回输入框，按 `⌘⇧V`，双击文字卡片；首次使用按系统提示授予发送键盘事件权限，必要时重启应用。
- 验证面板收起、原应用回到前台、文字自动粘贴。
- 撤销权限后再次双击，验证内容已复制、面板已收起，手动 `⌘V` 仍可粘贴。
- 在设置中核查暂停记录、清空历史、隐私政策入口。

若上述步骤尚未在提交包上完成，不要把草稿原样提交。Apple 对此类模拟粘贴行为有独立审核判断；遇到 2.4.5 拒绝时需根据具体审核意见沟通或调整实现。
