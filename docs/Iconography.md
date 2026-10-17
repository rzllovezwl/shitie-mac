# 界面图标

应用内界面图标取自 `lucide-static@1.59.0`。源文件通过 `Tools/GenerateLucideAssets.swift` 转为路径 PDF，放在 `ClipboardShelf/Assets.xcassets` 中；运行时无需加载图标字体。图标按模板图像渲染，随浅色和深色模式变色。Dock 和访达中的 RZL 应用图标单独保留。

上游：[Lucide Icons](https://lucide.dev/icons)。许可文本随应用打包在 `ClipboardShelf/Resources/Lucide-LICENSE.txt`。

添加图标时，在生成脚本的 `iconNames` 和 `ClipboardShelf/Views/LucideIcon.swift` 中同时登记。下载固定版本的 `lucide-static` 包后运行：

```sh
swift Tools/GenerateLucideAssets.swift /path/to/lucide-static/package ClipboardShelf/Assets.xcassets
xcodegen generate
```
