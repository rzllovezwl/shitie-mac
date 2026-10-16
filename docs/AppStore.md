# ClipHoook Mac App Store 发布说明

## 名称与身份

| 用途 | 名称 | Bundle ID | Xcode scheme |
| --- | --- | --- | --- |
| 日常测试 | ClipHoook测试版 | `com.renzhenglin.shitie.dev` | ClipHoook测试版 |
| Mac App Store 安装包 | ClipHoook | `com.renzhenglin.shitie` | ClipHoook上架版 |
| App Store Connect 页面目标名称 | ClipHoook-你的⌘C⌘V伴侣 | 对应正式 Bundle ID | App 记录 `6823468334` |

App Store 页面名称与 Mac 桌面上显示的应用名称可以不同。正式 Bundle ID 在第一次上传构建后不能随意更改，因此注册前应确认拼写。

## 当前状态

2026-10-16 已在开发团队 `526XL62KAS` 注册正式 Explicit App ID `com.renzhenglin.shitie`，创建 Apple Distribution 和 Mac Installer Distribution 签名身份，并生成「拾贴 Mac App Store 1.0」配置文件。品牌改名不更换 Bundle ID 或配置文件。App Store Connect 已创建 macOS App 记录 `6823468334`；用户将自行把该记录的中文展示名改为「ClipHoook-你的⌘C⌘V伴侣」，本地改名不会自动修改商店后台。

`AppStore` 配置启用 App Sandbox。2026-10-16 已在本机导出 `dist/ClipHoook-1.0.0-build4-AppStore.pkg`，安装器证书链和包内应用的 Apple Distribution 签名、正式 Bundle ID、沙盒 entitlement、`x86_64`/`arm64` 架构及随包隐私政策均已本机核验。`dist/` 被 Git 忽略。用户反馈构建号 `4` 已提交审核；本机尚未核对 App Store Connect 的实时审核状态，商店沙盒版的跨应用自动粘贴也尚未在真实桌面完成验证。旧 `dist/拾贴-1.0.0-AppStore.pkg` 为构建号 1，不含自动粘贴实现；构建号 2 使用旧品牌名，构建号 3 尚未包含本次窗口焦点修复。

`develop` 已将构建号推进到 `5`，用于后续测试迭代和应用内版本记录。该源码状态尚未生成新的上架包；上方提到的构建号 `4` 安装包及其审核状态不受影响。

App Store Connect 曾提示《Apple Developer Program 许可协议》已更新；提交前由账户持有人检查并在需要时亲自接受。

构建号 4 的商店版在用户授权 `PostEvent` 键盘事件后，双击会复制内容、收起面板、切回原应用并发送一次 `⌘V`。未授权或目标应用无法接收时，内容仍已复制，可手动 `⌘V`。代码与签名验证不等于真实交互验证；务必用构建号 4 在解锁的 Mac 上验证授权、自动粘贴和失败路径。正式版与测试版 Bundle ID 不同，需分别授权。

## 上架前重点风险

| 风险 | 当前事实 | 下一步 |
| --- | --- | --- |
| 自动粘贴审核 | 使用 Core Graphics `PostEvent` 模拟 `⌘V`；Apple DTS 表示技术上兼容沙盒，但同类 App 有按 2.4.5 被拒案例 | 真机验证后，在审核备注如实解释权限用途、手动回退与操作步骤；若被拒，使用 App Review 沟通或准备手动粘贴版。 |
| 沙盒运行结果 | 已核验包内沙盒 entitlement，但尚未在真实桌面验证这份商店包的跨应用粘贴 | 在真实 Mac 上检查自动记录、快捷键、窗口覆盖、图片预览、设置和持久化；记录系统授权弹窗及失败路径。 |
| 版本对应 | 包内版本与 App Store Connect 的 macOS 版本均为 `1.0.0`，最新包构建号为 `4` | 上传前再次核对选用的是构建号 `4`。 |
| 开发者协议 | App Store Connect 显示开发者协议有更新 | 账户持有人亲自查阅并接受更新；未完成前不要安排上传和提交。 |
| 隐私与审核资料 | 剪贴板历史只在本机保存，但会包含用户复制的敏感内容 | 将 `distribution/web/privacy/` 和 `distribution/web/support/` 发布到公开网址，准确填写 App Privacy、截图和审核备注。 |

## 正式 ID 为什么不在下拉菜单里

Xcode 工程之前使用 `com.example.ClipboardShelf`，而正式 `com.renzhenglin.shitie` 当时尚未在开发者账号注册，所以新建 App 的下拉菜单里找不到。现在已在 Apple Developer → Certificates, Identifiers & Profiles → Identifiers 注册，App Store Connect 也已选用它。以后若在其他账号或团队中看不到，先确认登录的是团队 `526XL62KAS`。不要选择截图中其他项目的 `XC …` 标识符。

## 发布步骤

1. 日常开发选择「ClipHoook测试版」；准备发行时选择「ClipHoook上架版」归档。使用 [ExportOptions-AppStore.plist](../distribution/ExportOptions-AppStore.plist) 导出 `.pkg`。手动导出选项引用本机的 Mac App Store 配置文件；证书或配置文件过期后先在 Apple Developer 更新，再修改该文件。
2. 保持 App Store Connect 的版本号与包内 `CFBundleShortVersionString` 一致。两者现均为 `1.0.0`，最新包内构建号为 `4`；上传前再次核对。
3. 在解锁的真实 Mac 上安装构建号 `4`，验证剪贴板读取授权、键盘事件授权、快捷键、历史持久化、Dock 覆盖、面板交互和跨应用粘贴；未授权时还应能复制并收起面板。
4. 由账户持有人检查开发者协议。使用 [商店素材](../distribution/metadata/zh-Hans/README.md) 填写文案并上传截图；把隐私政策和支持页发布到公开网址后，再填写 Privacy Policy URL、Support URL、App Privacy、年龄分级、定价和销售范围、审核联系信息。
5. 后续新构建完成上述检查后再上传并提交审核。构建号 `4` 已由用户反馈提审，是否通过审核以 App Store Connect 为准。

可在锁屏期间做编译、归档、静态检查和本地数据测试。快捷键、窗口层级、触控板捏合、跨应用粘贴与系统权限弹窗必须在解锁的真实桌面验证。

App Store Connect 的“App 沙盒信息”仅用于登记包中实际包含的临时例外 entitlement。当前 `ClipboardShelf/Entitlements/AppStore.entitlements` 只有基础 `com.apple.security.app-sandbox=true`，该区域留空；`PostEvent` 的系统授权不在这里添加。

## 参考

- [Apple：注册 Explicit App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [Apple：在 App Store Connect 新建 App](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [Apple：Mac App Store 需要 App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple：App Sandbox 受限行为](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple：上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple：App 沙盒信息](https://developer.apple.com/cn/help/app-store-connect/reference/app-uploads/app-sandbox-information/)
- [Apple DTS：PostEvent 与沙盒、审核的区别](https://developer.apple.com/forums/thread/820594)
