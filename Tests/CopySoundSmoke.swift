import AppKit
import AVFoundation

private enum CopySoundTestError: Error {
    case failed(String)
}

@main
struct CopySoundSmoke {
    @MainActor static func main() throws {
        let suite = "ClipHoookCopySoundSmoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try check(CopySoundPreference.selectedEffect(in: defaults) == .shutter,
                  "缺少音效设置时应默认使用双咔嗒")
        defaults.set(false, forKey: CopySoundPreference.enabledKey)
        for effect in CopySoundEffect.allCases {
            defaults.set(effect.rawValue, forKey: CopySoundPreference.effectKey)
            let restored = UserDefaults(suiteName: suite)!
            try check(CopySoundPreference.selectedEffect(in: restored) == effect,
                      "重新读取设置后应保留所选音效")
            try check(!restored.bool(forKey: CopySoundPreference.enabledKey),
                      "切换音效应保留提示音开关的用户设置")
        }
        defaults.set("removed-sound", forKey: CopySoundPreference.effectKey)
        try check(CopySoundPreference.selectedEffect(in: defaults) == .shutter,
                  "无法识别的旧设置应回退到默认音效")

        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let bundle = Bundle(url: appURL) else {
            throw CopySoundTestError.failed("无法读取测试包")
        }
        var resources = Set<Data>()
        for effect in CopySoundEffect.allCases {
            guard let url = bundle.url(forResource: effect.rawValue, withExtension: "wav"),
                  let sound = NSSound(contentsOf: url, byReference: false) else {
                throw CopySoundTestError.failed("测试包缺少可读取的音效 \(effect.rawValue)")
            }
            try check((0.08...0.25).contains(sound.duration), "复制音效应保持短促")
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == 44_100,
                  file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CopySoundTestError.failed("音效格式应为单声道 44.1 kHz")
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?.pointee else {
                throw CopySoundTestError.failed("无法解码音效文件")
            }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            try check(!samples.isEmpty && samples.allSatisfy(\.isFinite), "音效应包含有效采样")
            let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
            try check(peak > 0.1 && peak < 0.8, "音效应有可用信号并留出峰值余量")
            try check(abs(samples.first!) < 0.01 && abs(samples.last!) < 0.01,
                      "音效首尾应平滑收束")
            resources.insert(try Data(contentsOf: url))
        }
        try check(resources.count == CopySoundEffect.allCases.count, "各音效应具有不同的本地资源")
        print("Copy sound checks passed: saved selection, default and invalid-value fallback, preserved mute setting, bundled WAV decoding and signal boundaries")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CopySoundTestError.failed(message) }
    }
}
