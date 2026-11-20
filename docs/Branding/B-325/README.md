# ClipHoook B 方案 · 叠卡图标

2026-11-14，接入开发版 325。用户从三个初稿中选定 B，并要求进一步细化。

`ClipHoook-B-master.png` 是 1254×1254 的透明 PNG 母版，由内置图像生成工具基于 B 初稿细化。两张白色／冰蓝卡片配合蓝色取景角，统一圆角和留白，减轻厚度、塑料感及投影。不再使用 RZL 字样。

应用使用现有 `AppIcon.appiconset` 的全部 10 个槽位，涵盖 16–1024 px；设置页面读取应用自身的图标。开发版 327 起，菜单栏改用 B 方案的单色叠卡与取景角标识，由 `MenuBarArtwork.appIcon` 绘制 18 点矢量模板，适配系统明暗外观；录屏时仍显示录制状态和时长。旧 RZL 素材仍在 `docs/AppIcon-*`，之前导出的商店包未重建。

开发版 347 起，菜单栏叠卡在复制时沿相反方向交错，再分开归位，总时长 0.35 秒。声音开关独立，系统启用“减少动态效果”时跳过位移动画。仓库首页使用应用资源中的同一 Logo。

导出仅作尺寸转换，保留完整画布和透明通道，不重绘或裁切图形：

```sh
swift Tools/ExportAppIcon.swift docs/Branding/B-325/ClipHoook-B-master.png ClipboardShelf/Assets.xcassets/AppIcon.appiconset
```

生成时的主要提示词（内置图像生成，非外部 API）：

> Use the middle B icon from the comparison board as the chosen identity. Deliver one final square macOS application icon with genuine transparency outside the blue tile. Preserve the two overlapping rounded content cards, ivory front card with identical blue upper-left/lower-right capture corners, translucent ice-blue rear card offset up/right, and blue continuous-corner background. Refine card proportions, edge thickness, optical centering and contact shadows. Less puffy beveling and plastic gloss, sharper small-size silhouette, consistent corner widths/radii/insets. Front-on, no perspective. Preserve macOS safe margins. No labels, lettering, RZL, wordmark, extra feature symbols, watermark or presentation layout.

编译和资源尺寸检查不能替代 Finder、Dock 和设置页面的实际观感验收；这部分由用户测试。
