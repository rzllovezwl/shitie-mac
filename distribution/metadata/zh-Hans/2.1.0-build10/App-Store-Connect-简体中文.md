# ClipHoook 2.1.0（10）上架资料

资料日期：2026-11-11。基于 develop 的完整功能开发版 300 制作独立商店快照；保留双击自动粘贴。本文件供 App Store Connect 填写，不表示已上传、已提审或已获审核通过。

正式 Bundle ID：`com.renzhenglin.shitie`。最低系统：macOS 14。上传文件：`ClipHoook-2.1.0-build10-AppStore.pkg`。

App 名称可沿用当前后台名称；下面为与现有品牌一致的填写建议。本次不修改既有支持网址。

## App 名称（延续现有品牌）

17 characters / 上限 30。独立文件：[name.txt](name.txt)。

```text
ClipHoook-剪贴板增强工具
```

## 副标题

14 characters / 上限 30。独立文件：[subtitle.txt](subtitle.txt)。

```text
截图标注、文字识别与分类收藏
```

## 推广文本

84 characters / 上限 170。独立文件：[promotional-text.txt](promotional-text.txt)。

```text
复制过的内容，按自己的习惯整理。创建带 Emoji 的收藏分类，把常用卡片钉在面板前端，按日期或图片中的文字找回内容。截图、长图、标注、翻译与桌面贴图，也在同一处完成。
```

## 关键词

94 UTF-8 bytes / 上限 100。独立文件：[keywords.txt](keywords.txt)。

```text
长截图,图片转文字,桌面贴图,历史搜索,分类收藏,文本编辑,链接清理,OCR
```

## 描述

1433 characters / 上限 4000。独立文件：[description.txt](description.txt)。

```text
ClipHoook 是常驻菜单栏的剪贴板与截图工具。复制过的文字、链接、图片和文件，可以在历史面板中查找、整理并再次使用。默认按 ⌘⇧V 打开面板，历史保存在你的 Mac 上。

按自己的习惯整理
• 创建自定义收藏分类，设置名称并从 40 个 Emoji 中选择标识。
• 收藏分类与历史并列显示，分类较多时可横向滚动，历史入口始终保留。
• 拖动卡片到分类即可收藏，拖到加号可创建分类并一起收藏。
• 把常用卡片钉在面板前端，支持单张、多选和分组；默认快捷键 ⌘⇧T。
• 收藏和面板钉住的内容跳过自动到期与容量清理，仍可手动删除。

不只搜索文字卡片
• 按关键词、类型或日期查找，使用日历查看每天仍保留的记录数量。
• 搜索词也能匹配图片中的文字。未识别的图片在本机逐张处理，结果陆续补充，已有识别结果可复用。
• 区分屏幕截屏、ClipHoook 截图等来源，查看来源应用和复制时间。

编辑与再次使用
• 编辑文字和链接卡片；修改富文本后按纯文本保存。
• 去除空格、多余空行、转换大小写，格式化 JSON，进行 Base64、URL 和 HTML 实体编码转换。
• 清理链接前预览并选择要删除的参数，保留需要的参数和片段。
• 复制所选内容、复制纯文本或拖放到支持的应用；多选复制后仍保持独立卡片。
• 双击卡片可尝试返回原应用并自动粘贴。需要系统键盘事件权限，目标应用须支持粘贴；也可仅复制后手动按 ⌘V。

截图后直接处理
• 同一截图入口支持拖选区域或点击窗口，另有整个屏幕截图与滚动长截图。
• 默认冻结取景画面；可移动选区、调整八个锚点，使用局部放大和取色辅助精确选择。
• 矩形、椭圆、箭头、文字、画笔、荧光笔、序号、区域高亮、钢笔和贴图等标注工具。
• 支持背景模糊、马赛克、椭圆或圆角矩形放大镜，可调节效果和颜色。
• 标注可移动、缩放，文字可重新编辑；保存后的可编辑记录也可再次打开。
• 图片卡片、预览、截图和标注均可保存为文件，默认 ⌘S，并记住上次选择的文件夹。

识别、翻译与桌面贴图
• 图片预览和截图中直接识别文字、复制结果或翻译。
• 支持的系统上默认中译英、英译中，也可选择其他语言；截图译文可覆盖到图片上。
• 将图片钉在桌面，拖动摆放、捏合缩放，调整到最低 10% 的不透明度；右键可复制。
• 多张贴图可叠放，点击置顶；双击或点击关闭按钮取消钉住。
• 可选开启 iPhone 截图接收，使用快捷指令经可互访的局域网发送到 Mac。

由你控制
• 设置历史保留时间、存储上限、排除记录的应用和常用快捷键。
• 文件默认保存引用，访问受限时可授权对应文件或文件夹；保存完整文件副本需主动选择。
• 无需注册，无广告或第三方分析 SDK，不向开发者上传历史内容。

系统与使用说明
支持 macOS 14 及更新系统。截图需要屏幕捕捉权限；部分文件操作需要选择文件或文件夹授权。翻译在 macOS 15 及更新系统使用本机接口，首次可能需要下载 Apple 语言资源；macOS 14.4–14.x 使用系统翻译弹窗，截图内覆盖翻译需要 macOS 15 及更新系统。macOS 14.0–14.3 不提供系统翻译。

滚动长截图需要你手动滚动并保留重叠画面。受系统或应用限制的窗口可能无法截取。可编辑标注会保留原始底图；分享遮盖后的内容时，请使用合并后的导出图片。

联系邮箱：584772541@qq.com
```

## 此版本的新增内容

390 characters / 上限 4000。独立文件：[whats-new.txt](whats-new.txt)。

```text
新增自定义收藏分类
• 收藏分类与历史并列显示，支持名称及 40 个 Emoji 标识。
• 拖入卡片收藏，拖到加号可新建分类并收藏；历史入口在横向滚动时保持固定。

常用卡片固定在前
• 单张、多选和分组可钉在面板前端，默认 ⌘⇧T，支持修改。
• 点击蓝色图钉即可取消；重启后恢复状态和顺序，钉住内容不参与自动清理。

搜索、预览和导出
• 搜索词可直接匹配图片中的文字，在本机逐张识别并陆续补充结果。
• 日历突出今天，提高记录数量的可读性。
• 图片右键、预览、截图高级工具及标注中可保存文件，默认 ⌘S，并记住上次选择的文件夹。

可靠性与外观
• 改善卡片拖放、收藏、Esc 取消时的面板外观及圆角裁切。
• 标注底图和编辑数据完整保存，保存失败时保留上一版。
• 减少历史自动清理的重复扫描，继续保护收藏、面板钉住及所需分组成员。
• 更新应用内隐私说明与版本记录。
```

## 审核备注（英文，可直接粘贴）

3564 characters / 上限 4000。独立文件：[review-notes-en.txt](review-notes-en.txt)。

```text
ClipHoook 2.1.0 (10) is a menu-bar clipboard and screenshot utility. No account or login is required. The app runs in the App Sandbox. This submission includes the current complete feature set, including user-initiated double-click paste.

Main entry: click the ClipHoook menu-bar icon or press Command-Shift-V. Copy a short text and an image in another app to create test history.

Changes since the previous 2.0.0 (9) export:
- Custom favorite categories with names and 40 Emoji choices, shown beside History. Click + to create one; drag a card onto its tab, or drag to + to create a category and collect it. There is no separate default Favorites tab. History stays fixed when category tabs scroll.
- Pin cards or groups at the front of the panel: use the context menu or Command-Shift-T. Click the blue pin to unpin. State survives restart and pinned cards are excluded from automatic cleanup.
- Search can find text inside images. Unprocessed images in the current scope are recognized locally in sequence; results appear progressively and are cached. A loading indicator is shown while recognition is pending.
- Save images using Command-S from a card or preview, or Save in screenshot Advanced Tools. The system save panel starts in Downloads and remembers the last selected folder.
- Improvements to calendar readability, drag cancellation, panel material/clipping, editable annotation persistence and cleanup performance.

Existing screenshot workflow:
Option-A selects a region or window; Option-W captures a screen; Command-Shift-D starts manual scrolling capture. After selection, annotate and choose the completion icon to save/copy, or Esc to cancel. The app offers OCR (Command-W), translation (Command-B), pin to desktop (Command-T) and export. Shortcuts can be changed in settings. A desktop pin and a card pinned to the panel are different features.

Permissions and data:
Screen capture permission is used only when the user invokes screen-related features. File access is user-selected; history normally references original files rather than automatically duplicating their full contents. iPhone screenshot receiving is off by default; when enabled, the paired iPhone sends images over the local network directly to the Mac.

Automatic paste is optional and user-initiated. It writes the chosen content to NSPasteboard, restores the target app, then sends Command-V with Core Graphics event-posting APIs after permission. When available, AXUIElement APIs compare the focused element identity; otherwise a window identity check is used. The app does not read text from the focused field. If permission or focus validation fails, users can paste manually with Command-V. If permission has just been enabled but is not yet effective, quit and reopen ClipHoook as the in-app message explains. No general-purpose automation, script execution or keystroke logging is provided.

macOS 14+ is supported. On macOS 15+, translation uses Apple's on-device Translation framework and may request language downloads. macOS 14.4–14.x uses the system text translation popover; translation overlays require macOS 15+. macOS 14.0–14.3 does not offer translation. Clipboard, screenshot and OCR features remain available.

History, categories, OCR and editable annotations remain on the device. Editable annotations retain their original image; exported images flatten the effects. No advertising or third-party analytics SDK is included, and no content is uploaded to a developer server. The bundled privacy policy describes this build.

Contact: 584772541@qq.com
```

## 审核团队回复（英文，需要回复时使用）

1232 characters。独立文件：[review-reply-en.txt](review-reply-en.txt)。

```text
Hello App Review Team,

We have prepared ClipHoook 2.1.0 (build 10) for review. This update adds custom favorite categories, cards pinned at the front of the clipboard panel, local image-text search, and image export improvements. It also improves calendar readability, drag cancellation and editable annotation storage.

The app requires no account. Review notes include entry points, default shortcuts and testing steps. The in-app privacy policy and product description have been updated to match this build, including local processing, Apple translation services, file access, optional local-network screenshot receiving, and user-initiated automatic paste.

Double-click paste remains in this build. It writes the selected content to the system clipboard and sends Command-V only after the required keyboard-event permission and target-focus checks. It can compare Accessibility element identities without reading the focused field's text. Manual copy and paste remain available without this permission. We have described the implementation in the review notes rather than representing it as a disability-specific feature.

Please let us know if you need any additional steps or information to reproduce a behavior.

Thank you.
```

## 隐私政策与后台隐私信息

公开文稿使用同目录 [隐私政策.md](隐私政策.md)，与新包内文稿保持一致。把全文更新到你原有公开地址：https://www.kdocs.cn/l/ctnEjGO8RqCZ 。本次仅准备文稿，没有修改金山文档；更新后请用未登录窗口确认可读。隐私政策链接需要公开可访问，见 [Apple 的隐私详情要求](https://developer.apple.com/app-store/app-privacy-details/)。

根据这份构建的代码和依赖，应用不向开发者或所集成的第三方 SDK 传输、留存用户历史，没有广告、分析或账号服务。App Privacy 可按“不收集数据”填写；这指 Apple 定义下的开发者或第三方收集，不表示应用不读取或不在本机保存剪贴板。Apple 对收集的定义及本机处理规则见 [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)。

系统翻译、语言下载、你主动打开的网页或发送的支持邮件分别按相应服务处理。隐私政策已具体说明，不能将宣传文案写成“任何功能都不联网”。收藏中的密码、账号仅为分类，没有额外加密保险箱功能。

## 出口合规

本构建未加入自有或非豁免加密实现；使用系统哈希去重、随机配对码及局域网 HTTP 接收。发布 Info.plist 中设置 `ITSAppUsesNonExemptEncryption = false`，表示未使用非豁免加密，含义见 [Apple 属性说明](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)。若后台仍出现先前截图中的加密算法四选一，按此构建选择“不属于上述的任意一种算法”。这项设置不表示局域网 HTTP 有传输加密。

## 上传与填写

1. 在 Transporter 中选择本次 `ClipHoook-2.1.0-build10-AppStore.pkg` 并交付；不使用旧的 2.0.0（9）包。
2. 等待 App Store Connect 处理完成后，在 macOS 版本页创建或选择 **2.1.0**，关联构建 **10**。
3. 填写上面的副标题、推广文本、描述、关键词、新增内容及审核备注。审核回复为备用文本，不代替版本页备注，也不要把“已准备”改成“已通过”。
4. 更新公开隐私政策，并核对后台 App Privacy。支持网址沿用原有配置。
5. 截图应展示当前界面：自建收藏分类、固定历史入口、面板图钉、图片搜索与保存入口。本次没有重新制作商店截图；旧默认收藏入口的图片不宜直接沿用。
6. 完成测试和后台检查后由你提交审核。本次不会自动上传、发送回复或发布。

字段长度已按 [Apple 版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) 和 [App 信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) 核对；关键词按 UTF-8 字节计数。
