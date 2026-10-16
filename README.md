# ClipHoook

一个面向 macOS 26 及以上系统的原生剪贴板历史 MVP。使用 SwiftUI 绘制菜单栏和面板，AppKit 管理浮动窗口及系统剪贴板。

## 已实现

- 常驻菜单栏，自动记录新复制的文字、网页链接和 PNG/TIFF 图片。
- 每次剪贴板变化播放短促的原创提示音，同样内容再次复制也会响；应用内复制立即提示。声音默认开启，可在设置中关闭或试听，且与“暂停记录”独立。
- 本地持久化最近 100 条记录，最多占用 100 MB；单张图片上限 15 MB，单条文字上限 1 MB。
- `⌘⇧V` 呼出或收起面板。面板在鼠标所在屏幕底部弹出，距完整屏幕边界左右及下方各 10 pt，并覆盖 Dock。
- 在设置中切换面板高度会立即调整已打开的面板，卡片和图片预览随之适配；“显示屏幕”仍在下次打开面板时生效。
- 单击记录只选中，按空格弹出或收起详情；左右方向键切换记录，切到可视区外时自动横向滚动；双击尝试回到原应用直接粘贴；右键选择“复制”。卡片随紧凑、标准、宽敞面板高度调整尺寸，图片详情初始完整适配预览区，支持触控板双指捏合缩放及滚动查看。详情可按 `Esc` 关闭，点击面板外或再次按 `Esc` 收起面板。
- 菜单栏可暂停记录及清空本机历史；面板右上角“…”菜单可打开设置。缺少双击粘贴所需的键盘事件权限时，可点“打开键盘事件权限设置…”直达系统设置。
- 已配置参考图风格的 macOS 应用图标。启动后 Dock 显示图标，点击可打开设置；关闭设置窗口后应用继续留在菜单栏，Dock 图标收起。可从菜单栏“设置…”再次打开。
- 设置中可控制是否继续记录、复制提示音、面板出现的屏幕与高度，并查看历史记录数量、清空历史或打开权限设置。

## 构建与运行

使用 Xcode 27 打开 [ClipboardShelf.xcodeproj](ClipboardShelf.xcodeproj)，日常测试选择「ClipHoook测试版」scheme 和“我的 Mac”，按 `⌘R` 构建并运行。`⌘B` 只构建，不会重启正在运行的应用。Debug 产物固定在 `build/ClipHoook测试版.app`，Bundle ID 为 `com.renzhenglin.shitie.dev`。仓库同时包含 [project.yml](project.yml)，可用 XcodeGen 重新生成工程。

归档商店版选择「ClipHoook上架版」scheme。桌面名称为「ClipHoook」，Bundle ID 保持 `com.renzhenglin.shitie`；App Store Connect 的目标展示名为「ClipHoook-你的⌘C⌘V伴侣」，由账户持有人在商店后台修改。两版可分别安装，历史和系统授权也需分别检查。本机最新上架候选安装包位于 `dist/ClipHoook-1.0.0-build4-AppStore.pkg`，不上传 GitHub；发布步骤与待办见 [上架说明](docs/AppStore.md)。

Debug 和 Release 是本地功能构建，不启用 App Sandbox。第一次双击粘贴时，系统可能要求允许发送键盘事件；拒绝后仍可复制记录，再自行按 `⌘V`。macOS 也可能要求允许应用持续读取剪贴板；请在系统设置中选择“始终允许”，否则自动记录会暂停。

本机验证自动粘贴时，只运行 Xcode Debug 产出的 `build/ClipHoook测试版.app`。此次测试版 Bundle ID 和产物路径均已改变，macOS 可能要求重新授权一次“设备控制和数据访问”；此后普通代码改动直接按 `⌘R` 即可。如果以后更换开发证书、Bundle ID 或应用路径，也可能需要重新授权。同名的旧 DerivedData 或临时目录构建可能占用另一条权限记录；菜单栏出现权限提示时，可在系统设置中用“在访达中显示”核对授权记录的应用位置。

复制提示音保存在 `ClipboardShelf/Resources/CopyChime.wav`，可用 `python3 Tools/GenerateCopyChime.py` 重新生成。相关变更状态测试可用 `swiftc -module-cache-path /tmp/ClipHoookSwiftModuleCache ClipboardShelf/Services/ClipboardChangeTracker.swift Tests/ClipboardChangeTrackerSmoke.swift -o /tmp/ClipboardChangeTrackerSmoke` 编译，再运行 `/tmp/ClipboardChangeTrackerSmoke`。

如果其他应用正在使用 `⌘⇧V`，面板仍可从菜单栏打开。本应用每 5 秒重试注册；退出占用快捷键的应用后，无需重启本应用。

`AppStore` 配置启用了 App Sandbox。测试版与商店版均在获得系统键盘事件授权后支持双击自动粘贴；未授权时双击会复制并收起面板，仍可手动按 `⌘V`。商店版已编译和签名，提交前仍须安装并实测正式 Bundle ID 的授权与跨应用粘贴。详见 [上架说明](docs/AppStore.md)。

## Git 分支

`main` 保存可发布基线，`develop` 用于日常开发和测试；功能从 `codex/` 或其他功能分支合并到 `develop`，通过上架检查后再合并到 `main`。构建产物、证书、配置文件和本机历史数据不提交。GitHub 仓库配置见 [版本管理说明](docs/Git.md)。

## 数据与隐私

历史仅保存在本机 Application Support 的 `ClipboardShelf` 目录，不使用网络或云同步。品牌改名时保留原来的 Bundle ID 和数据目录，因此已有历史不会因改名丢失。系统剪贴板由 macOS 管理；复制或粘贴历史记录会把选中内容留在系统剪贴板。清空历史只删除本应用保存的记录，不清空当前系统剪贴板。

首版不保留富文本格式、不记录 Finder 文件引用，也不支持跨设备同步。正式 Bundle ID、发布签名和隐私说明已配置；上架前仍需验证商店沙盒版的真实交互，并将隐私与支持页面发布到公开网址。
