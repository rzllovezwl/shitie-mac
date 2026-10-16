# ClipHoook 开发约定

- 日常功能开发进入 `develop`；已提审的构建号 4 安装包和保留分支不要随测试版改动重建或覆盖。
- 每次交付新的可测试版本时，递增 `ClipboardShelf/Info.plist` 的 `CFBundleVersion`；准备新的商店版本时再按发布计划更新 `CFBundleShortVersionString`。
- 同一次更新必须在 `ClipboardShelf/Resources/ReleaseHistory.json` 顶部添加对应版本和构建号，写清用户能感受到的功能与修复。若多个改动合入同一构建，记录应覆盖它们。保持旧记录可查。
- 设置窗口的“版本记录”读取该 JSON；Xcode 构建阶段运行 `Tools/ValidateReleaseHistory.py`。更新项目文件时同步 `project.yml` 与生成的 `ClipboardShelf.xcodeproj`。
- 交付时区分代码编译、应用内功能验证和 App Store Connect 审核状态。用户偏好自行测试桌面界面；优先做构建与代码测试，把仍需人工确认的交互明确指出。
