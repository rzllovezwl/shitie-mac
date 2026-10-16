# 拾贴版本管理

本地仓库使用 `main` 和 `develop` 两条长期分支：

- `develop`：Xcode「拾贴测试版」日常开发和验证。
- `main`：准备上架的稳定基线；只有完成沙盒实测、签名、隐私资料检查后才从 `develop` 合并。

每项改动从 `develop` 建短期分支，提交代码、XcodeGen 的 `project.yml` 与生成的 `.xcodeproj`。`build/`、`dist/`、归档、证书与配置文件受 `.gitignore` 排除。仓库应设为 GitHub 私有仓库，并开启双重认证。不要把用户剪贴板历史、钥匙串、签名私钥或 App Store Connect API Key 提交进去。

如远端已创建，可从项目目录运行：

```sh
git remote add origin git@github.com:rzllovezwl/shitie-mac.git
git push -u origin main
git push -u origin develop
```

首次连接前核对 GitHub 用户名、仓库归属和仓库地址；不要把上述示例当作已创建的远端。
