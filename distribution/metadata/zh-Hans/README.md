# ClipHoook 商店素材（简体中文）

当前开发分支已到 1.0.0（349），功能总览见 [项目首页](../../../README.md)。本目录按商店候选分别保留文案、隐私政策和构建核验，候选名称与状态按当时记录保留，不能据此判断 App Store Connect 的实时审核状态。

## 当前提审候选 2.0.0（12）

基于开发版 338，包含录屏、暂存箱、全局快速搜索和最新截图标注。双击和回车复制后由用户手动粘贴。安装包与资料压缩包位于 `dist/`。[构建 12 提审资料](2.0.0-build12/README.md)

## 历史候选 2.2.0（11），基于开发 322

资料见 [2.2.0-build11/README.md](2.2.0-build11/README.md) 和 [集中填写文稿](2.2.0-build11/App-Store-Connect-简体中文.md)。包括暂存箱、全局快速搜索、卡片排序及已有截图、OCR、翻译等功能，不含录屏或小组件；公开隐私政策请使用 [本次政策](2.2.0-build11/隐私政策.md)。安装包和资料压缩包位于 `dist/`，未上传、未提审。

## 历史候选：2.1.0（10）

当前资料见 [2.1.0-build10/App-Store-Connect-简体中文.md](2.1.0-build10/App-Store-Connect-简体中文.md)，包含名称、副标题、关键词、推广文本、描述、新增内容、审核备注、备用回复、隐私政策及上传步骤。该版本基于完整开发版 300 的独立源码快照，保留双击自动粘贴、自定义收藏分类、面板卡片钉住、图片文字搜索及截图标注等功能。

公开隐私文稿使用 [2.1.0 构建 10 隐私政策](2.1.0-build10/隐私政策.md)。构建 5 文稿和下方内容仅适用于对应历史包，不应覆盖这次候选的政策。

## 历史资料：1.0.0（4 / 5）

本目录面向构建号 **4**（Bundle ID `com.renzhenglin.shitie`）。请在 App Store Connect 的 macOS 1.0.0 版本页填写，提交前以最终上传的构建为准。

**构建 5 的公开隐私政策使用 [privacy-policy-build5.md](privacy-policy-build5.md)。** 该文稿按 1.0.0（5）的实际数据处理方式整理，双击后由用户手动按 ⌘V。下方构建 4 的其他素材为历史保留资料。

| App Store Connect 字段 | 可复制内容 | 核验 |
| --- | --- | --- |
| App 名称 | [name.txt](name.txt) | 18 字符；桌面应用叫“ClipHoook” |
| 推广文本 | [promotional-text.txt](promotional-text.txt) | 74 字符；上限 170 字符 |
| 描述 | [description.txt](description.txt) | 595 字符；上限 4,000 字符 |
| 关键词 | [keywords.txt](keywords.txt) | 97 UTF-8 字节；上限 100 字节 |

## Mac 截图

依次上传以下四张 JPEG，均为 **2880 × 1800**、16:10、无透明通道：

1. [剪贴板历史](../../screenshots/zh-Hans/01-history.jpg)
2. [文字详情](../../screenshots/zh-Hans/02-text-detail.jpg)
3. [图片详情](../../screenshots/zh-Hans/03-image-detail.jpg)
4. [设置与权限](../../screenshots/zh-Hans/04-settings.jpg)

截图使用虚构的演示内容渲染真实 SwiftUI 页面，未读取或展示个人剪贴板历史。App 预览视频为可选项，这一版没有制作。

## 隐私政策和支持网址

公开页面已生成在 [隐私政策](../../web/privacy/index.html) 和 [支持页](../../web/support/index.html)，原始 Markdown 分别为 [构建 5 隐私政策](privacy-policy-build5.md) 和 [support.md](../../web/support.md)。公开隐私页固定从构建 5 文稿生成，避免与开发版应用内政策混用。运营者为任政霖，联系邮箱为 584772541@qq.com。

**还需将这两个目录部署到可公开访问的 HTTPS 网站**，取得实际 URL 后填写 App Store Connect 的 Privacy Policy URL 和 Support URL。本机文件路径、私有 GitHub 仓库链接不能代替公开网址。若页面地址改变，请保持两页之间的相对链接可用。

当前应用代码不传输剪贴板历史，没有账号、广告或分析 SDK。填写 App Privacy 时，根据最终上传构建再次核对 Apple 对“收集”的定义；本机保存且不传给开发者的数据一般不属于“收集”。用户主动发送支持邮件属于单独的联系行为，隐私政策已有说明。

## 审核备注

可使用 [审核测试说明](review-notes.md) 向 Apple 说明剪贴板访问和双击粘贴的操作步骤。`PostEvent` 功能已有同类审核争议，技术兼容沙盒不代表审核保证通过。正式包需在真实桌面验证后再提交。
