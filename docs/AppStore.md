# ClipHoook Mac App Store 发布说明

## 当前开发分支

2026-11-20 的 develop 为 1.0.0（349），完整功能见 [项目首页](../README.md)。本轮同步源码、资源、测试与功能文档，沿用已验证的开发构建号，商店安装包与归档保持原样。

开发版保留自动粘贴，商店候选 2.0.0（12）在基于 338 的独立发布快照中去掉该功能。当前 develop 直接选择 AppStore scheme 只会切换签名与沙盒配置，不能替代发布快照中的功能裁剪。下方各候选与历史记录以其交付时点为准，上传、提审和审核状态需在 App Store Connect 核对。

## 2026-11-19 提审候选 2.0.0（12）

App Store 已发布版本为 1.1.0（6）。本次以开发版 338 为基线，沿用此前被拒的 2.0.0 商店版本号，并使用构建 12。录屏、暂存箱、全局快速搜索和截图标注均包含在内。双击记录或按回车复制，回到目标应用后由用户手动粘贴。

签名安装包为 `dist/ClipHoook-2.0.0-build12-AppStore.pkg`，独立商店源码位于 `build/ClipHoook-store-2.0.0-build12-source`。本机归档、导出、签名、解包和回归已验证。上传与提审待进行。[提审资料](../distribution/metadata/zh-Hans/2.0.0-build12/README.md)

## 2026-11-14：2.2.0（11）候选，基于开发 322

用户确认版本为 2.2.0、构建号 11。功能源码取自加入录屏前的开发 322 备份，独立保存在 `build/ClipHoook-store-2.2.0-build11-source`；55 个 Swift 文件与该备份一致。当前开发 323、录屏实现以及旧商店包未改动。

正式安装包为 `dist/ClipHoook-2.2.0-build11-AppStore.pkg`。本次增加暂存箱、全局快速搜索、卡片排序等 322 以前的功能，保留双击自动粘贴，不带录屏、麦克风权限或小组件。包内政策与交付文稿一致，版本记录共 327 条。

上架文案、隐私政策、审核备注与可选回复见 [2.2.0（11）资料](../distribution/metadata/zh-Hans/2.2.0-build11/README.md)。归档、导出、实际安装包签名与回归检查通过；尚未上传或提审，桌面和 TestFlight 验证由用户进行。冻结截图点击视频窗口可能刷新画面的新问题仍待开发版修复，未混入本次 322 快照。

## 2026-11-11：2.1.0（10）候选

用户指定版本号 2.1.0、构建号 10，基于 `develop` 完整开发版 1.0.0（300）创建 `build/ClipHoook-store-2.1.0-build10-source` 独立发布快照。开发版的 Info.plist 和版本记录不随上架快照改号；旧上架包均保留。

使用 `ClipHoook上架版` Scheme、`AppStore` 配置及 `distribution/ExportOptions-AppStore.plist` 导出正式 Bundle ID `com.renzhenglin.shitie` 的 Mac App Store 包。发布快照顶部增加对应记录，保留完整开发迭代与已有公开版本记录；新包内隐私政策与交付的 2.1.0 文稿一致。

本版保留用户要求的双击自动粘贴，不使用构建 5 的手动粘贴裁剪方案。权限和焦点核对方式在审核备注及政策中如实说明。商店资料见 [2.1.0（10）填写文稿](../distribution/metadata/zh-Hans/2.1.0-build10/App-Store-Connect-简体中文.md)，最终签名、架构、包内资源和回归结果以交付目录中的构建核验报告为准。

本地导出与核验不代表 App Store Connect 已接收、已提审或已通过审核。用户自行使用 Transporter 上传并进行桌面界面测试。既有支持网址不作改动。

---

下方为早期构建的历史说明，构建数字和“当前”均指当时状态。

## 名称与身份

| 用途 | 名称 | Bundle ID | Xcode scheme |
| --- | --- | --- | --- |
| 日常测试 | ClipHoook测试版 | `com.renzhenglin.shitie.dev` | ClipHoook测试版 |
| Mac App Store 安装包 | ClipHoook | `com.renzhenglin.shitie` | ClipHoook上架版 |
| App Store Connect 页面目标名称 | ClipHoook-你的⌘C⌘V伴侣 | 对应正式 Bundle ID | App 记录 `6823468334` |

App Store 页面名称与 Mac 桌面上显示的应用名称可以不同。正式 Bundle ID 在第一次上传构建后不能随意更改，因此注册前应确认拼写。

## 历史状态（开发 132 / 商店构建 4）

2026-10-16 已在开发团队 `526XL62KAS` 注册正式 Explicit App ID `com.renzhenglin.shitie`，创建 Apple Distribution 和 Mac Installer Distribution 签名身份，并生成「拾贴 Mac App Store 1.0」配置文件。品牌改名不更换 Bundle ID 或配置文件。App Store Connect 已创建 macOS App 记录 `6823468334`；用户将自行把该记录的中文展示名改为「ClipHoook-你的⌘C⌘V伴侣」，本地改名不会自动修改商店后台。

`AppStore` 配置启用 App Sandbox。2026-10-16 已在本机导出 `dist/ClipHoook-1.0.0-build4-AppStore.pkg`，安装器证书链和包内应用的 Apple Distribution 签名、正式 Bundle ID、沙盒 entitlement、`x86_64`/`arm64` 架构及随包隐私政策均已本机核验。`dist/` 被 Git 忽略。用户提供的 2026-10-22 审核通知显示：构建号 `4` 因元数据中不恰当使用 Mac 用语，按准则 5.2.5 被拒；本轮未核对 App Store Connect 的最新处理状态。商店沙盒版的跨应用自动粘贴也尚未在真实桌面完成验证。旧 `dist/拾贴-1.0.0-AppStore.pkg` 为构建号 1，不含自动粘贴实现；构建号 2 使用旧品牌名，构建号 3 尚未包含本次窗口焦点修复。

`develop` 当前测试构建号为 `132`，用于功能迭代和应用内版本记录；该源码状态尚未生成新的上架包。构建号 `4` 的安装包保持原样，不随测试版重建。

App Store Connect 曾提示《Apple Developer Program 许可协议》已更新；提交前由账户持有人检查并在需要时亲自接受。

构建号 4 的商店版在用户授权 `PostEvent` 键盘事件后，双击会复制内容、收起面板、切回原应用并发送一次 `⌘V`。未授权或目标应用无法接收时，内容仍已复制，可手动 `⌘V`。代码与签名验证不等于真实交互验证；务必用构建号 4 在解锁的 Mac 上验证授权、自动粘贴和失败路径。正式版与测试版 Bundle ID 不同，需分别授权。

## 上架前重点风险

| 风险 | 当前事实 | 下一步 |
| --- | --- | --- |
| 自动粘贴审核 | 使用 Core Graphics `PostEvent` 模拟 `⌘V`；Apple DTS 表示技术上兼容沙盒，但同类 App 有按 2.4.5 被拒案例 | 真机验证后，在审核备注如实解释权限用途、手动回退与操作步骤；若被拒，使用 App Review 沟通或准备手动粘贴版。 |
| 沙盒运行结果 | 已核验包内沙盒 entitlement，但尚未在真实桌面验证这份商店包的跨应用粘贴 | 在真实 Mac 上检查自动记录、快捷键、窗口覆盖、图片预览、设置和持久化；记录系统授权弹窗及失败路径。 |
| 版本对应 | 已保留的上架包为 `1.0.0 (4)`；测试版已推进到更高构建号 | 新的上架候选需另行归档、使用新构建号，并核对包内版本与 App Store Connect 对应。 |
| 名称与元数据 | 用户提供的审核通知指出构建号 `4` 的元数据不恰当使用 Mac 用语 | 检查 App Store Connect 的名称、副标题、描述、关键词、截图和图标；移除会让人误以为 Apple 产品或服务的表达，再按实际修改情况重新提交。 |
| 开发者协议 | App Store Connect 显示开发者协议有更新 | 账户持有人亲自查阅并接受更新；未完成前不要安排上传和提交。 |
| 隐私与审核资料 | 剪贴板历史只在本机保存，但会包含用户复制的敏感内容 | 将 `distribution/web/privacy/` 和 `distribution/web/support/` 发布到公开网址，准确填写 App Privacy、截图和审核备注。 |

## 正式 ID 为什么不在下拉菜单里

Xcode 工程之前使用 `com.example.ClipboardShelf`，而正式 `com.renzhenglin.shitie` 当时尚未在开发者账号注册，所以新建 App 的下拉菜单里找不到。现在已在 Apple Developer → Certificates, Identifiers & Profiles → Identifiers 注册，App Store Connect 也已选用它。以后若在其他账号或团队中看不到，先确认登录的是团队 `526XL62KAS`。不要选择截图中其他项目的 `XC …` 标识符。

## 发布步骤

1. 日常开发选择「ClipHoook测试版」；准备发行时选择「ClipHoook上架版」归档。使用 [ExportOptions-AppStore.plist](../distribution/ExportOptions-AppStore.plist) 导出 `.pkg`。手动导出选项引用本机的 Mac App Store 配置文件；证书或配置文件过期后先在 Apple Developer 更新，再修改该文件。
2. 保持 App Store Connect 的版本号与包内 `CFBundleShortVersionString` 一致；新候选使用新的 `CFBundleVersion`，确认版本记录与候选包完全对应。不要用当前测试版应用包替代商店沙盒构建，也不要覆盖保留的构建号 `4`。
3. 在解锁的真实 Mac 上安装新的商店候选包，验证剪贴板读取授权、键盘事件授权、快捷键、历史持久化、Dock 覆盖、面板交互和跨应用粘贴；未授权时还应能复制并收起面板。再检查 iPhone 截图接收、OCR、贴图和成组粘贴在沙盒版中的行为。
4. 由账户持有人检查开发者协议。使用 [商店素材](../distribution/metadata/zh-Hans/README.md) 填写文案并上传截图；把隐私政策和支持页发布到公开网址后，再填写 Privacy Policy URL、Support URL、App Privacy、年龄分级、定价和销售范围、审核联系信息。
5. 核对商店元数据，处理此前 5.2.5 审核意见；在审核备注说明剪贴板授权、自动粘贴回退与 iPhone 截图同网配置，并提供可复现的测试步骤。新候选完成上述检查后再上传并提交审核；状态以 App Store Connect 为准。

`Tools/VerifyTestBuild.sh` 仅验证开发签名的测试包及定向代码测试。它不验证 App Store 沙盒包的真实授权、网络权限、跨应用焦点，也不代表审核通过。

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
