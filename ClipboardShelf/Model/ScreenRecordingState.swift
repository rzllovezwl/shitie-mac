import Foundation
import CoreGraphics

enum ScreenRecordingError: LocalizedError {
    case cancelled, permissionRequired, microphoneDenied, noFrames, unavailableSource
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: "录屏已取消。"
        case .permissionRequired: "请允许屏幕录制权限后再试。若已经允许，请退出并重新打开 ClipHoook。"
        case .microphoneDenied: "麦克风权限未允许。可在系统设置中允许，或关闭麦克风后开始录屏。"
        case .noFrames: "没有收到可录制的画面。请检查屏幕录制权限，或重新选择窗口。"
        case .unavailableSource: "录制的窗口或显示器已不可用，请重新选择。"
        case .failed(let message): message
        }
    }
}

enum ScreenRecordingScope: String, CaseIterable, Identifiable {
    case region, window, screen
    var id: String { rawValue }
    var title: String {
        switch self { case .region: "区域"; case .window: "窗口"; case .screen: "整个屏幕" }
    }
    var symbol: String {
        switch self { case .region: "viewfinder"; case .window: "macwindow"; case .screen: "display" }
    }
}

enum ScreenRecordingQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case original, compact
    var id: String { rawValue }
    var title: String { self == .original ? "原始清晰度" : "省空间（最高 1080p）" }

    func dimensions(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        let pixelWidth = max(2, pointSize.width * max(1, scale))
        let pixelHeight = max(2, pointSize.height * max(1, scale))
        let factor = self == .compact ? min(1, 1_920 / max(pixelWidth, pixelHeight)) : 1
        // H.264 requires even dimensions. Pad/scale by at most one pixel.
        return CGSize(width: max(2, (pixelWidth * factor / 2).rounded(.down) * 2),
                      height: max(2, (pixelHeight * factor / 2).rounded(.down) * 2))
    }
}

enum ScreenRecordingPhase: Equatable {
    case idle, selecting, ready, countdown(Int), starting, recording, paused, finishing, awaitingSave, saving
    var isActive: Bool { self != .idle }
    var isCapturing: Bool { self == .recording || self == .paused || self == .starting }
    var canCancel: Bool {
        switch self { case .selecting, .ready, .countdown: true; default: false }
    }
    var title: String {
        switch self {
        case .idle: "录屏"
        case .selecting, .ready: "选择录制范围"
        case .countdown(let value): "\(value)"
        case .starting: "正在开始录制"
        case .recording: "正在录制"
        case .paused: "已暂停"
        case .finishing: "正在结束录制"
        case .awaitingSave: "录屏待保存"
        case .saving: "正在保存录屏"
        }
    }
}

struct ScreenRecordingPreferences {
    static let prefix = "screenRecording."
    static let defaultsRevisionKey = prefix + "defaultsRevision"
    var scope: ScreenRecordingScope
    var quality: ScreenRecordingQuality
    var frameRate: Int
    var countdown: Int
    var systemAudio: Bool
    var microphone: Bool
    var microphoneDeviceID: String?
    var showsCursor: Bool
    var highlightsClicks: Bool
    var showsControls: Bool

    init(defaults: UserDefaults = .standard) {
        Self.upgradeDefaults(in: defaults)
        scope = ScreenRecordingScope(rawValue: defaults.string(forKey: Self.prefix + "scope") ?? "") ?? .region
        quality = ScreenRecordingQuality(rawValue: defaults.string(forKey: Self.prefix + "quality") ?? "") ?? .compact
        frameRate = defaults.integer(forKey: Self.prefix + "fps") == 60 ? 60 : 30
        let countdown = defaults.object(forKey: Self.prefix + "countdown") as? Int ?? 0
        self.countdown = [0, 3, 5].contains(countdown) ? countdown : 0
        systemAudio = defaults.object(forKey: Self.prefix + "systemAudio") as? Bool ?? true
        microphone = defaults.bool(forKey: Self.prefix + "microphone")
        microphoneDeviceID = defaults.string(forKey: Self.prefix + "microphoneDeviceID").flatMap { $0.isEmpty ? nil : $0 }
        showsCursor = defaults.object(forKey: Self.prefix + "showsCursor") as? Bool ?? true
        highlightsClicks = defaults.object(forKey: Self.prefix + "highlightsClicks") as? Bool ?? true
        showsControls = defaults.object(forKey: Self.prefix + "showsControls") as? Bool ?? true
    }

    private static func upgradeDefaults(in defaults: UserDefaults) {
        guard defaults.integer(forKey: defaultsRevisionKey) < 2 else { return }
        // Earlier builds persisted all fields together, including untouched
        // factory values. Migrate those once; subsequent choices stay intact.
        if defaults.string(forKey: prefix + "quality") == ScreenRecordingQuality.original.rawValue {
            defaults.set(ScreenRecordingQuality.compact.rawValue, forKey: prefix + "quality")
        }
        if defaults.object(forKey: prefix + "countdown") as? Int == 3 {
            defaults.set(0, forKey: prefix + "countdown")
        }
        if defaults.object(forKey: prefix + "highlightsClicks") as? Bool == false {
            defaults.set(true, forKey: prefix + "highlightsClicks")
        }
        defaults.set(2, forKey: defaultsRevisionKey)
    }

    func save(defaults: UserDefaults = .standard) {
        let values: [String: Any] = ["scope": scope.rawValue, "quality": quality.rawValue,
            "fps": frameRate, "countdown": countdown, "systemAudio": systemAudio,
            "microphone": microphone, "microphoneDeviceID": microphoneDeviceID ?? "",
            "showsCursor": showsCursor, "highlightsClicks": highlightsClicks,
            "showsControls": showsControls]
        for (key, value) in values { defaults.set(value, forKey: Self.prefix + key) }
    }
}

struct ScreenRecordingTrim: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    var duration: Double { end - start }

    func validated(duration: Double, frameRate: Int) throws -> Self {
        let fps = Double(max(1, frameRate))
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= duration + 1 / fps else {
            throw ScreenRecordingError.failed("裁剪范围无效，请重新选择开始和结束位置。")
        }
        let lower = max(0, (start * fps).rounded() / fps)
        let upper = min(duration, (end * fps).rounded() / fps)
        guard upper - lower >= min(duration, 1 / fps) - 0.000_001 else {
            throw ScreenRecordingError.failed("请至少保留一帧视频。")
        }
        return Self(start: lower, end: upper)
    }

    func isFullRange(duration: Double, frameRate: Int) -> Bool {
        let tolerance = 0.5 / Double(max(1, frameRate))
        return start <= tolerance && end >= duration - tolerance
    }
}

struct ScreenRecordingClickAnimation: Sendable {
    static let duration = 0.55
    let point: CGPoint
    let time: Double

    func progress(at hostTime: Double) -> Double? {
        let progress = (hostTime - time) / Self.duration
        return progress.isFinite && progress >= 0 && progress < 1 ? progress : nil
    }
}

/// All media timestamps share host time. Removing the same pauses from video,
/// system audio and microphone keeps the final movie continuous and in sync.
struct ScreenRecordingTimeline {
    private(set) var origin: Double?
    private(set) var pausedAt: Double?
    private(set) var removedTime: Double = 0
    private var resumesAt: Double?

    mutating func start(at hostTime: Double) {
        guard origin == nil, hostTime.isFinite else { return }
        origin = hostTime
    }
    mutating func pause(at hostTime: Double) {
        guard origin != nil, pausedAt == nil, hostTime.isFinite else { return }
        pausedAt = hostTime
    }
    mutating func resume(at hostTime: Double) {
        guard let pausedAt, hostTime.isFinite, hostTime >= pausedAt else { return }
        removedTime += hostTime - pausedAt
        self.pausedAt = nil
        resumesAt = hostTime
    }
    func time(for hostTime: Double) -> Double? {
        guard let origin, pausedAt == nil, hostTime.isFinite, hostTime >= origin,
              resumesAt.map({ hostTime >= $0 }) ?? true else { return nil }
        return max(0, hostTime - origin - removedTime)
    }
}

/// A bounded two-source PCM mixer. Missing/muted blocks become silence; audio
/// arriving after its output range has been committed is never replayed later.
struct ScreenRecordingAudioMixer {
    enum Source: CaseIterable { case system, microphone }
    struct Block {
        let start: Int64
        let left: [Float]
        let right: [Float]
        var end: Int64 { start + Int64(min(left.count, right.count)) }
    }
    static let sampleRate = 48_000
    static let maximumQueuedFrames = sampleRate * 2
    private(set) var cursor: Int64 = 0
    private var blocks: [Source: [Block]] = [:]
    private(set) var enabled: Set<Source>

    init(systemAudio: Bool, microphone: Bool) {
        enabled = Set(([systemAudio ? Source.system : nil, microphone ? Source.microphone : nil]).compactMap { $0 })
    }
    mutating func setMicrophoneEnabled(_ enabled: Bool) {
        if enabled { self.enabled.insert(.microphone) }
        else { self.enabled.remove(.microphone); blocks[.microphone] = [] }
    }
    mutating func append(_ block: Block, source: Source) {
        guard enabled.contains(source), block.end > cursor, block.start >= 0,
              block.left.count == block.right.count,
              block.left.count <= Self.maximumQueuedFrames else { return }
        let boundary = cursor + Int64(Self.maximumQueuedFrames)
        guard block.start < boundary else { return }
        blocks[source, default: []].removeAll { $0.end <= cursor }
        // Audio callbacks may overlap slightly. Replace an identical range,
        // rather than summing duplicate samples into a louder signal.
        blocks[source, default: []].removeAll { $0.start == block.start }
        blocks[source, default: []].append(block)
        while (blocks[source]?.reduce(0, { $0 + $1.left.count }) ?? 0) > Self.maximumQueuedFrames {
            blocks[source]?.removeFirst()
        }
    }
    mutating func take(frames: Int) -> [Float] {
        let count = max(0, min(4_096, frames))
        let end = cursor + Int64(count)
        var samples = [Float](repeating: 0, count: count * 2)
        let gain: Float = enabled.count > 1 ? 0.7 : 1
        for source in Source.allCases where enabled.contains(source) {
            for block in blocks[source] ?? [] {
                let lower = max(cursor, block.start), upper = min(end, block.end)
                guard lower < upper else { continue }
                for frame in lower..<upper {
                    let src = Int(frame - block.start), dst = Int(frame - cursor) * 2
                    samples[dst] += block.left[src] * gain
                    samples[dst + 1] += block.right[src] * gain
                }
            }
        }
        for index in samples.indices {
            samples[index] = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
        }
        cursor = end
        for source in Source.allCases { blocks[source]?.removeAll { $0.end <= cursor } }
        return samples
    }
    var queuedFrameCount: Int { blocks.values.flatMap { $0 }.reduce(0) { $0 + $1.left.count } }
}
