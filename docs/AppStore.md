# 拾贴 Mac App Store 发布说明

## 名称与身份

| 用途 | 名称 | Bundle ID | Xcode scheme |
| --- | --- | --- | --- |
| 日常测试 | 拾贴测试版 | `com.renzhenglin.shitie.dev` | 拾贴测试版 |
| Mac App Store 安装包 | 拾贴 | `com.renzhenglin.shitie` | 拾贴上架版 |
| App Store Connect 页面 | 拾贴 - Mac 剪贴板增强工具 | 对应正式 Bundle ID | 在 App Store Connect 填写 |

App Store 页面名称与 Mac 桌面上显示的应用名称可以不同。正式 Bundle ID 在第一次上传构建后不能随意更改，因此注册前应确认拼写。

## 当前状态

`AppStore` 配置已启用 App Sandbox，代码可编译、可生成未签名归档。它尚不是可直接上传的发行包：当前 Mac 只检测到 Apple Development 证书；正式 App ID、商店分发签名和配置文件尚未完成。自动注册正式 ID 的操作被自动审批拒绝，需用户针对 `com.renzhenglin.shitie` 明确授权后再执行。

商店构建的双击行为目前是复制内容并收起面板，用户仍需在原应用按 `⌘V`。本机测试版可自动粘贴，但不能据此推断沙盒版可用。正式提交前要在真实 Mac 上验证符合沙盒规则的自动粘贴实现；如无法实现，则商店页面、截图、审核说明都必须如实展示手动粘贴交互。

## 正式 ID 为什么不在下拉菜单里

Xcode 工程之前使用 `com.example.ClipboardShelf`，开发者账号里也尚未确认注册 `com.renzhenglin.shitie`。先到 Apple Developer → Certificates, Identifiers & Profiles → Identifiers → `+` → App IDs，选择 **Explicit App ID**，输入 `com.renzhenglin.shitie` 并注册。再回 App Store Connect 新建 macOS App，Bundle ID 下拉菜单才会出现它。若仍没有，检查是否选了同一开发团队、账号角色及协议状态。不要把截图中其他项目的 `XC …` 标识符用于拾贴。

## 发布步骤

1. 在 Apple Developer 注册正式 Explicit App ID `com.renzhenglin.shitie`。
2. 在 App Store Connect 建立 macOS App 记录，名称填「拾贴 - Mac 剪贴板增强工具」，Bundle ID 选上述 ID。
3. 为该团队配置可用的商店分发签名及配置文件。在 Xcode 选择「拾贴上架版」→ Product → Archive → Distribute App → App Store Connect。
4. 用该归档在真实 Mac 上验证剪贴板读取授权、快捷键、历史持久化、Dock 覆盖、面板交互、沙盒行为及粘贴流程。
5. 准备隐私政策 URL、产品截图、App Privacy 表单、审核备注和准确功能描述；完成后上传并提交审核。

可在锁屏期间做编译、归档、静态检查和本地数据测试。快捷键、窗口层级、触控板捏合、跨应用粘贴与系统权限弹窗必须在解锁的真实桌面验证。

## 参考

- [Apple：注册 Explicit App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [Apple：在 App Store Connect 新建 App](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [Apple：Mac App Store 需要 App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple：App Sandbox 受限行为](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple：上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
