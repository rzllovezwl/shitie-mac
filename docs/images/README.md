# GitHub 首页配图

配图 JPEG 使用开发版 1.0.0（349）的实际 SwiftUI / AppKit 视图生成，背景、标题和留白为文档排版。Logo 直接复制当前 AppIcon 资源。

| 文件 | 展示内容 |
| --- | --- |
| overview.jpg | 剪贴板面板、卡片、收藏状态、来源与快捷键提示 |
| search-staging.jpg | 当前快速搜索与单列暂存箱 |
| annotations.jpg | 当前标注工具条、箭头＋矩形、划除与数字标记 |
| iphone-transfer.jpg | 手机截图示意、局域网流转与真实的 iPhone 来源卡片 |
| iphone-setup.jpg | 当前 Mac 功能指南与四步配置说明 |
| app-icon.png | 当前 B 方案叠卡 Logo |

所有文字、链接和图片均为虚构演示数据。渲染使用一次性数据目录与独立应用身份，不启动剪贴板轮询，不注册全局快捷键，不进行屏幕录制，不读取用户历史，也不播放声音。标注使用应用自身的文档格式、几何与绘制代码。iPhone 画面是流程示意，Mac 卡片与设置指南使用真实视图；地址固定为 demo-mac.local 和全零演示码，二维码指向公开 iCloud 模板，不使用当前用户的配对地址。

先构建当前开发版，再在项目根目录运行 zsh Tools/GenerateReadmeImages.sh。工具会读取同版 Assets.car，在临时目录编译独立渲染程序，生成这组配图。原始代码见 [生成脚本](../../Tools/GenerateReadmeImages.sh) 和 [页面排版](../../Tools/RepositoryScreenshots/main.swift)。仅生成 iPhone 配图可运行 zsh Tools/GenerateReadmeImages.sh --iphone-only。重新导出需要可使用图形会话的 Mac 与本机 Xcode。

配图用于功能说明，不能据此认定全局快捷键、真实拖放、权限、音视频设备或多屏交互已经完成桌面验收。商店旧截图保留在 distribution/screenshots，功能对应其当时版本。
