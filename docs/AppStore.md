# 拾贴 Mac App Store 发布说明

## 名称与身份

| 用途 | 名称 | Bundle ID | Xcode scheme |
| --- | --- | --- | --- |
| 日常测试 | 拾贴测试版 | `com.renzhenglin.shitie.dev` | 拾贴测试版 |
| Mac App Store 安装包 | 拾贴 | `com.renzhenglin.shitie` | 拾贴上架版 |
| App Store Connect 页面 | 拾贴 - Mac 剪贴板增强工具 | 对应正式 Bundle ID | App 记录 `6823468334` |

App Store 页面名称与 Mac 桌面上显示的应用名称可以不同。正式 Bundle ID 在第一次上传构建后不能随意更改，因此注册前应确认拼写。

## 当前状态

2026-10-16 已在开发团队 `526XL62KAS` 注册正式 Explicit App ID `com.renzhenglin.shitie`，创建 Apple Distribution 和 Mac Installer Distribution 签名身份，并生成「拾贴 Mac App Store 1.0」配置文件。App Store Connect 已创建 macOS App 记录 `6823468334`，中文名称为「拾贴 - Mac 剪贴板增强工具」。

`AppStore` 配置启用 App Sandbox。Xcode 已导出 [拾贴-1.0.0-AppStore.pkg](../dist/拾贴-1.0.0-AppStore.pkg)；安装器证书链和包内应用的 Apple Distribution 签名、正式 Bundle ID、沙盒 entitlement、`x86_64`/`arm64` 架构均已本机核验。此包尚未上传或提交审核，商店沙盒版的交互也尚未在真实桌面验证。

App Store Connect 目前提示《Apple Developer Program 许可协议》已更新，账户持有人需亲自查阅并接受后才能提交新 App。此操作涉及法律协议，不由开发流程代签。

商店构建的双击行为目前是复制内容并收起面板，用户仍需在原应用按 `⌘V`。本机测试版可自动粘贴，但不能据此推断沙盒版可用。正式提交前要在真实 Mac 上验证符合沙盒规则的自动粘贴实现；如无法实现，则商店页面、截图、审核说明都必须如实展示手动粘贴交互。

## 正式 ID 为什么不在下拉菜单里

Xcode 工程之前使用 `com.example.ClipboardShelf`，而正式 `com.renzhenglin.shitie` 当时尚未在开发者账号注册，所以新建 App 的下拉菜单里找不到。现在已在 Apple Developer → Certificates, Identifiers & Profiles → Identifiers 注册，App Store Connect 也已选用它。以后若在其他账号或团队中看不到，先确认登录的是团队 `526XL62KAS`。不要选择截图中其他项目的 `XC …` 标识符。

## 发布步骤

1. 日常开发选择「拾贴测试版」；准备发行时选择「拾贴上架版」归档。使用 [ExportOptions-AppStore.plist](../distribution/ExportOptions-AppStore.plist) 导出 `.pkg`。手动导出选项引用本机的 Mac App Store 配置文件；证书或配置文件过期后先在 Apple Developer 更新，再修改该文件。
2. 保持 App Store Connect 的版本号与包内 `CFBundleShortVersionString` 一致。本包为 `1.0.0`、构建号 `1`。上传前核对版本字段。
3. 在解锁的真实 Mac 上验证剪贴板读取授权、快捷键、历史持久化、Dock 覆盖、面板交互和商店沙盒版的复制／粘贴流程；按实际行为准备截图和审核备注。
4. 由账户持有人处理更新的开发者协议。准备隐私政策 URL、产品截图、App Privacy 表单、年龄分级、定价和销售范围、审核联系信息及准确功能描述。
5. 完成上述检查后再上传构建并提交审核。当前包只是签名导出的候选包，不代表已通过 Apple 验证或真实交互测试。

可在锁屏期间做编译、归档、静态检查和本地数据测试。快捷键、窗口层级、触控板捏合、跨应用粘贴与系统权限弹窗必须在解锁的真实桌面验证。

## 参考

- [Apple：注册 Explicit App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [Apple：在 App Store Connect 新建 App](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [Apple：Mac App Store 需要 App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple：App Sandbox 受限行为](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple：上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
