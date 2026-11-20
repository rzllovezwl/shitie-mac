# ClipHoook 2.2.0（11）交付说明

基于开发版 322 的独立发布快照。当前开发版 323 及其录屏实现保留；本次商店安装包不包含录屏、小组件或麦克风权限。未上传 Transporter、未提交审核、未发送任何邮件或审核回复。

## 文件用途

- `ClipHoook-2.2.0-build11-AppStore.pkg`：交给 Transporter 上传的商店分发包。不要把商店分发包当成普通开发版安装包验证；本机交互测试继续用开发 322，商店签名环境可在上传后通过 TestFlight 验证。
- `App-Store-Connect-简体中文.md`：集中填写名称、副标题、推广文本、关键词、描述、更新说明和审核备注。各字段另有同名 `.txt`。
- `隐私政策.txt`：可直接复制到公开隐私政策文档；`.md` 与包内政策一致。
- `review-reply-en.txt`：可选的审核消息草稿，并非已经发送的回复。
- `构建核验.md`、`build-verification.json`、`签名与安装包.txt`：最终构建与签名证据，以实际核验结果为准。
- `ReleaseHistory.json`：包内版本记录，含新的商店版本与完整开发迭代记录。
- `source-manifest.json`：322 源码与发布快照的对应摘要。
- `人工验证清单.md`：你在真实桌面和 TestFlight 中验证的步骤；自动测试不替代这些结果。

## 建议提交顺序

1. 使用本次 `.pkg` 在 Transporter 交付，等待 App Store Connect 处理完成。
2. 如通过 TestFlight 测试，核对显示 2.2.0（11），再按人工清单验证新增入口及权限。Mac App Store 分发签名与开发签名的权限记录可能不同。
3. 在版本 2.2.0 选择构建 11，填写本次文案与审核备注，隐私政策公开内容同步到新文件。
4. 截图应取自本包功能范围，体现暂存箱、快速搜索、历史整理及截图标注；不展示录屏或已移除的小组件。本资料没有生成新的商店截图，不要误用开发 323 的录屏页面。
5. 核对 App 隐私、版权、价格和发布方式；支持网址沿用现有设置。最后由你提交审核。

## 验证范围与已知待核对事项

本次发布按要求保留 322 行为，不混入 323 的新功能。你新报告的“冻结开启时点击窗口可能取到后续视频帧”仍待开发版修复，不能将本次打包视为已修复；先用视频画面做一次点击选窗对照。323 的“录屏结束后先预览，确认才保存”另行开发，本包没有录屏。

历史开发版中关于拖动取消的真实测试发现 QQ 的“拖拽文件时打开闪传悬浮窗”可干扰系统 Esc；你已确认关闭该功能后 316 正常。若再遇到同样情况，先关闭该浮窗功能做对照，不把重启 Dock 当作稳定修复。

## 填写依据

- [Apple：平台版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)：名称/副标题、推广文本、描述和关键词字段规则；关键词按 100 UTF-8 字节检查。
- [Apple：App 隐私详情](https://developer.apple.com/app-store/app-privacy-details/)：只在设备上处理的数据不属于其定义的“收集”；结论仍须与你实际发布的行为一致。
- [Apple：加密文稿](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)：使用 Info.plist 声明豁免状态；未来功能变化需重新评估。

这些资料是本次实现核对结果，不代表 App Store 审核已经通过。
