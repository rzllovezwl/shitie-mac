# ClipHoook 版本管理

本地仓库使用 `main` 和 `develop` 两条长期分支：

- `develop`：Xcode「ClipHoook测试版」日常开发和验证。
- `main`：准备上架的稳定基线；只有完成沙盒实测、签名、隐私资料检查后才从 `develop` 合并。

每项改动从 `develop` 建短期分支，提交代码、XcodeGen 的 `project.yml` 与生成的 `.xcodeproj`。`build/`、`dist/`、归档、证书与配置文件受 `.gitignore` 排除。仓库应设为 GitHub 私有仓库，并开启双重认证。不要把用户剪贴板历史、钥匙串、签名私钥或 App Store Connect API Key 提交进去。

GitHub 私有仓库：[rzllovezwl/shitie-mac](https://github.com/rzllovezwl/shitie-mac)。本地使用 SSH 远端：

```sh
git remote -v
git push -u origin main
git push -u origin develop
```

发布归档留在本机 `dist/`，不会随 `git push` 上传。
