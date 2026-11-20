# ClipHoook 版本管理

本地仓库使用 `main` 和 `develop` 两条长期分支：

- `develop`：Xcode「ClipHoook测试版」日常开发和验证。
- `main`：准备上架的稳定基线；只有完成沙盒实测、签名、隐私资料检查后才从 `develop` 合并。

每项改动从 `develop` 建短期分支，提交代码、XcodeGen 的 `project.yml` 与生成的 `.xcodeproj`。`build/`、`dist/`、归档、证书与配置文件受 `.gitignore` 排除。GitHub 当前为公开仓库，应用内数据和签名材料仅保存在本机。不要把用户剪贴板历史、钥匙串、签名私钥或 App Store Connect API Key 提交进去。

每次准备更新都要递增 `ClipboardShelf/Info.plist` 的构建号，并在 `ClipboardShelf/Resources/ReleaseHistory.json` 顶部写明本次用户可见的功能或修复。Xcode 构建阶段会校验当前版本与记录一致；设置窗口中的“版本记录”直接读取打包后的同一份文件。提审前核对商店更新说明与应用内记录一致。

GitHub 仓库：[rzllovezwl/shitie-mac](https://github.com/rzllovezwl/shitie-mac)。本地使用 SSH 远端：

```sh
git remote -v
git push -u origin main
git push -u origin develop
```

发布归档留在本机 `dist/`，不会随 `git push` 上传。

## 2026-11-20 开发版同步

本轮同步以 1.0.0（349）为基线，包含剪贴板与排序、暂存箱、全局快速搜索、截图标注、录屏、新 Logo、菜单栏动画和十种复制提示音。README 使用当前界面和隔离演示数据展示功能，并链接各功能操作说明。验证工具、图标源文件、本地音效和历史商店文稿一并保存，旧的构建与诊断记录保留各自时间背景。

文档与首页配图更新沿用已验证的开发构建号。只有准备交付新的应用测试包时才递增构建号及应用内版本记录。推送开发分支不会自动合并 main、部署支持网站或提交 App Store 审核。

GitHub 默认首页使用 main 的 README，本轮只将首页及其配图同步至 main，功能实现与完整文档保留在 develop。首页链接显式指向 develop，main 的应用源码和发布基线保持原样。
