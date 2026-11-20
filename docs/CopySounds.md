# 复制提示音

开发版 1.0.0（349）内置十种本地复制提示音，默认“双咔嗒”。进入“设置 → 通用 → 声音”选择，变更后立即播放并保存偏好，也可点击旁边的“试听”重播。关闭“播放提示音”后日常复制保持静音，设置中的主动试听继续可用。

| 名称 | 本地 WAV 资源 |
| --- | --- |
| 双咔嗒（默认） | CopyShutter.wav |
| 轻扣 | CopySoftClick.wav |
| 木叩 | CopyWood.wav |
| 气泡 | CopyBubble.wav |
| 金属轻敲 | CopyMetalTap.wav |
| 金属双击 | CopyMetalDouble.wav |
| 金属弹片 | CopyMetalSpring.wav |
| 纸张翻页 | CopyPaperFlip.wav |
| 纸张轻揉 | CopyPaperCrumple.wav |
| 原提示音 | CopyChime.wav |

资源位于 ClipboardShelf/Resources，用 Tools/GenerateCopyChime.py 本地合成，固定参数与随机种子，无运行时下载。349 将播放音量从 50% 提高到 85%，实际响度仍受 macOS 音量、静音和输出设备影响。快速连续触发时先停止上一声再重播，避免多声叠加。

系统剪贴板变化和应用内明确复制均可触发，重复复制相同内容也有反馈，与“暂停记录”独立。收到 iPhone 截图或完成桌面贴图使用原提示音。菜单栏的两张卡片交错动画独立于声音开关，时长 0.35 秒，系统启用“减少动态效果”时跳过位移动画。

Tests/CopySoundSmoke.swift 检查全部资源随应用打包、WAV 格式、时长、峰值、偏好切换与回退，并由 Tools/VerifyTestBuild.sh 执行。检查只读取本地数据，不播放或回传音频。声音的质感与音量由用户在应用中试听确认。
