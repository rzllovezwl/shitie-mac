# 下载与分发

## 两个下载入口

[App Store 正式版](https://apps.apple.com/cn/app/id6823468334) 由商店提供安装与更新。2026-11-20 通过 Apple 公开查询接口核对，当前版本为 1.1.0，Bundle ID 为 com.renzhenglin.shitie。

[GitHub 开发预览版 349](https://github.com/rzllovezwl/shitie-mac/releases/tag/v1.0.0-dev.349) 已公开发布。应用版本为 1.0.0（349），支持 macOS 14 及以上，Apple 芯片与 Intel 通用。双架构 Release 归档、完整代码回归、Developer ID Application 签名与 Apple 公证已完成，应用附带公证票据。

**[下载 ClipHoook-dev-349-universal.zip](https://github.com/rzllovezwl/shitie-mac/releases/download/v1.0.0-dev.349/ClipHoook-dev-349-universal.zip)**（6,852,976 字节，约 6.9 MB）。双击解压，将「ClipHoook测试版.app」拖入“应用程序”后打开。首次使用在菜单栏打开面板；默认快捷键为 ⌘⇧V，全局搜索为 ⌘⇧空格。

[SHA-256 校验值](https://github.com/rzllovezwl/shitie-mac/releases/download/v1.0.0-dev.349/SHA256SUMS.txt) · [功能与安装说明](../distribution/github/349/ReleaseNotes.md) · [iPhone 传图图文指南](iPhoneScreenshots.md)

正式版与开发功能的版本记录分别维护，请在下载前查看对应发布说明。仓库自动生成的 Source code ZIP 是源码，请选择名称为 ClipHoook-dev-349-universal.zip 的应用附件。

## 本次分发验证

| 项目 | 结果 |
| --- | --- |
| 双架构归档、最低系统与代码回归 | 已通过，macOS 14+，arm64 与 x86_64 |
| 签名 | Developer ID Application，团队 526XL62KAS，强化运行时与安全时间戳，无调试权限 |
| 公证票据 | 已附加，原应用及 ZIP 解压后的应用校验通过 |
| 系统安全检查 | Gatekeeper 接受，来源为 Notarized Developer ID |
| 公开发布 | v1.0.0-dev.349，标记为 Pre-release，含应用 ZIP、校验值与发布说明 |
| 公开下载复核 | 三个附件已重新下载，大小与内容均与本地分发文件一致；下载后的应用通过签名、票据及系统安全校验 |

应用压缩包的 SHA-256 为：

```text
a2135e48d5bad5e381eeeeb574b6c48e740e941da84c7c9a9506f2271a61d9e7
```

首次启动与系统权限、多屏、跨应用拖放、iPhone 连通性和声音效果仍需实机确认。Apple 公证为站外分发校验，不代表 App Store 审核通过。本次没有替用户启动应用或改动已有历史数据。

## 独立下载包的发布过程

1. 使用 develop 中确定的功能基线，以 Release 配置归档，包含 arm64 与 x86_64，并核对 macOS 14 最低系统要求。
2. 使用 Developer ID Application 导出站外分发包，保留 hardened runtime 和录屏麦克风所需的实际权限。Apple Development 测试签名与 App Store 签名分别用于各自的分发方式。
3. 向 Apple 公证服务提交并检查结果，附加公证票据，再验证签名和 Gatekeeper 接受情况。
4. 将已附加票据的应用打成 ZIP，验证解压后的签名、公证票据和 Gatekeeper 接受情况，生成 SHA-256 校验值。所有证书私钥和公证凭据只保存在本机。
5. 以准确的源码提交创建对应 Git tag 和 GitHub Release，上传安装包、校验值与更新说明。开发预览版本标为 Pre-release，下载链接指向实际已上传的附件。
6. 核对公开下载地址与附件大小后更新首页的直达链接。真实首次安装、屏幕录制授权、自动粘贴授权与跨应用操作由用户另行确认。

开发版 349 的源码、Info.plist 和完整版本记录保持一致。本轮为相同功能基线准备另一种分发方式，原有测试包和商店候选包保留。

维护者可先通过 Xcode 的 Developer ID 分发流程完成公证，再运行 [PackageGitHubBuild.sh](../Tools/PackageGitHubBuild.sh)。脚本检查双架构、版本、签名、强化运行时、权限与票据，验证 ZIP 解压后的应用，并生成压缩包和 SHA256SUMS.txt；已有输出目录会保留，不会覆盖。

```sh
zsh Tools/PackageGitHubBuild.sh '/path/to/已公证的应用.app'
```

[GitHub Releases 说明](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) · [Apple Developer ID 与公证](https://developer.apple.com/developer-id/)
