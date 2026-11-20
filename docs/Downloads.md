# 下载与分发

## 两个下载入口

[App Store 正式版](https://apps.apple.com/cn/app/id6823468334) 由商店提供安装与更新。2026-11-20 通过 Apple 公开查询接口核对，当前版本为 1.1.0，Bundle ID 为 com.renzhenglin.shitie。

[GitHub Releases](https://github.com/rzllovezwl/shitie-mac/releases) 用于提供独立下载附件和对应更新说明。当前 349 的 Apple 芯片与 Intel 双架构 Release 归档已完成，完整代码回归通过，待完成 Developer ID 签名、公证与安装核验后再上传安装附件。当前发布页尚无安装包。

正式版与开发功能的版本记录分别维护，请在下载前查看对应发布说明。仓库中的 Source code ZIP 是源码，安装附件会明确标注为 DMG 或应用压缩包。

## 独立下载包的发布过程

1. 使用 develop 中确定的功能基线，以 Release 配置归档，包含 arm64 与 x86_64，并核对 macOS 14 最低系统要求。
2. 使用 Developer ID Application 导出站外分发包，保留 hardened runtime 和录屏麦克风所需的实际权限。Apple Development 测试签名与 App Store 签名分别用于各自的分发方式。
3. 向 Apple 公证服务提交并检查结果，附加公证票据，再验证签名和 Gatekeeper 接受情况。
4. 创建便于拖入“应用程序”的 DMG，验证挂载、复制和签名，生成 SHA-256 校验值。所有证书私钥和公证凭据只保存在本机。
5. 以准确的源码提交创建对应 Git tag 和 GitHub Release，上传安装包、校验值与更新说明。开发预览版本标为 Pre-release，下载链接指向实际已上传的附件。
6. 核对公开下载地址与附件大小后更新首页的直达链接。真实首次安装、屏幕录制授权、自动粘贴授权与跨应用操作由用户另行确认。

开发版 349 的源码、Info.plist 和完整版本记录保持一致。本轮为相同功能基线准备另一种分发方式，原有测试包和商店候选包保留。

[GitHub Releases 说明](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) · [Apple Developer ID 与公证](https://developer.apple.com/developer-id/)
