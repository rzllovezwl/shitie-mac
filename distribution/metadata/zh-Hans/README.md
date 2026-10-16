# ClipHoook 1.0.0 商店素材（简体中文）

本目录面向构建号 **4**（Bundle ID `com.renzhenglin.shitie`）。请在 App Store Connect 的 macOS 1.0.0 版本页填写，提交前以最终上传的构建为准。

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

公开页面已生成在 [隐私政策](../../web/privacy/index.html) 和 [支持页](../../web/support/index.html)，原始 Markdown 分别为 [PrivacyPolicy.md](../../../ClipboardShelf/Resources/PrivacyPolicy.md) 和 [support.md](../../web/support.md)。运营者为任政霖，联系邮箱为 584772541@qq.com。

**还需将这两个目录部署到可公开访问的 HTTPS 网站**，取得实际 URL 后填写 App Store Connect 的 Privacy Policy URL 和 Support URL。本机文件路径、私有 GitHub 仓库链接不能代替公开网址。若页面地址改变，请保持两页之间的相对链接可用。

当前应用代码不传输剪贴板历史，没有账号、广告或分析 SDK。填写 App Privacy 时，根据最终上传构建再次核对 Apple 对“收集”的定义；本机保存且不传给开发者的数据一般不属于“收集”。用户主动发送支持邮件属于单独的联系行为，隐私政策已有说明。

## 审核备注

可使用 [审核测试说明](review-notes.md) 向 Apple 说明剪贴板访问和双击粘贴的操作步骤。`PostEvent` 功能已有同类审核争议，技术兼容沙盒不代表审核保证通过。正式包需在真实桌面验证后再提交。
