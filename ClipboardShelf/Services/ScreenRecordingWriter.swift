import AVFoundation
import CoreImage
import ScreenCaptureKit
import VideoToolbox

struct ScreenRecordingMovie: Codable {
    let url: URL
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Int

    func at(_ url: URL) -> Self {
        Self(url: url, duration: duration, width: width, height: height, frameRate: frameRate)
    }
}

/// A single serial queue owns the writer, timeline, converters and mixer.
/// Capture callbacks never retain a growing list of video frames or file data.
final class ScreenRecordingWriter: NSObject, SCStreamOutput,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.cliphoook.recording.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let temporaryURL: URL
    private let finalURL: URL
    private let width: Int
    private let height: Int
    private let frameRate: Int
    private var timeline = ScreenRecordingTimeline()
    private var mixer: ScreenRecordingAudioMixer
    private var converters: [ScreenRecordingAudioMixer.Source: AVAudioConverter] = [:]
    private var lastVideoTime = -Double.infinity
    private var acceptedFrames = 0
    private var finishing = false
    private var finished = false
    private var closingInputs = false
    private var failureReported = false
    private var finishCompletion: ((Result<ScreenRecordingMovie, Error>) -> Void)?
    private var finishWatchdog: DispatchWorkItem?
    private var clicks: [ScreenRecordingClickAnimation] = []
    private var latestImage: CVPixelBuffer?
    private var heartbeat: DispatchSourceTimer?
    private let onFirstFrame: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(temporaryURL: URL, finalURL: URL, dimensions: CGSize, frameRate: Int,
         systemAudio: Bool, microphone: Bool,
         usesRealtimeClock: Bool = true,
         onFirstFrame: @escaping @Sendable () -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        width = Int(dimensions.width)
        height = Int(dimensions.height)
        self.frameRate = frameRate
        self.onFirstFrame = onFirstFrame
        self.onFailure = onFailure
        mixer = ScreenRecordingAudioMixer(systemAudio: systemAudio, microphone: microphone)
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let bitrate = max(2_000_000, min(50_000_000, width * height * frameRate / 9))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ScreenRecordingError.failed("当前尺寸无法编码为 MP4。请在录屏选项中选择“省空间”，或缩小录制范围。")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw ScreenRecordingError.failed("无法准备录屏声音格式。")
        }
        audioFormat = format
        // Keep one AAC track so enabling the mic later never needs a second
        // video copy or an expensive post-recording audio export.
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ], sourceFormatHint: format)
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw ScreenRecordingError.failed("无法创建录屏文件。请检查保存位置和磁盘空间。")
        }
        writer.add(video)
        writer.add(audio)
        super.init()
        guard writer.startWriting() else { throw writer.error ?? ScreenRecordingError.failed("无法开始写入录屏文件。") }
        writer.startSession(atSourceTime: .zero)
        if usesRealtimeClock {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1 / Double(frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, !self.finishing, !self.finished, let image = self.latestImage else { return }
                self.appendVideo(image, hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            }
            heartbeat = timer
            timer.resume()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !finishing, !finished, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let status = attachments.first?[.status] as? Int,
               status != SCFrameStatus.complete.rawValue { return }
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            appendVideo(image, hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        case .audio: appendAudio(sampleBuffer, source: .system)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finishing, !finished else { return }
        appendAudio(sampleBuffer, source: .microphone)
    }

    func pause(at hostTime: Double) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timeline.pause(at: hostTime)
                self.clicks.removeAll()
                continuation.resume()
            }
        }
    }
    func resume(at hostTime: Double) async {
        await withCheckedContinuation { continuation in
            queue.async { self.timeline.resume(at: hostTime); continuation.resume() }
        }
    }
    func setMicrophoneEnabled(_ enabled: Bool) {
        queue.async { self.mixer.setMicrophoneEnabled(enabled) }
    }
    func showClick(at normalizedPoint: CGPoint, hostTime: Double) {
        queue.async {
            guard !self.finishing, !self.finished, self.timeline.pausedAt == nil,
                  hostTime.isFinite, normalizedPoint.x.isFinite, normalizedPoint.y.isFinite,
                  (0...1).contains(normalizedPoint.x), (0...1).contains(normalizedPoint.y) else { return }
            self.clicks.removeAll { hostTime - $0.time >= ScreenRecordingClickAnimation.duration }
            self.clicks.append(.init(point: normalizedPoint, time: hostTime))
            if self.clicks.count > 12 { self.clicks.removeFirst(self.clicks.count - 12) }
        }
    }

    // These entry points use exactly the production append path, allowing an
    // offscreen encoded-file regression without capturing anyone's desktop.
    func enqueueVideo(_ image: CVPixelBuffer, hostTime: Double) {
        queue.async { if !self.finishing && !self.finished { self.appendVideo(image, hostTime: hostTime) } }
    }
    func enqueueAudio(_ sample: CMSampleBuffer, source: ScreenRecordingAudioMixer.Source) {
        queue.async { if !self.finishing && !self.finished { self.appendAudio(sample, source: source) } }
    }

    private func appendVideo(_ image: CVPixelBuffer, hostTime: Double) {
        guard hostTime.isFinite else { return }
        latestImage = image
        timeline.start(at: hostTime)
        guard let pts = timeline.time(for: hostTime), pts - lastVideoTime >= 0.9 / Double(frameRate) else { return }
        guard video.isReadyForMoreMediaData else {
            if writer.status == .failed { reportFailure(writer.error) }
            return
        }
        guard CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else {
            reportFailure(ScreenRecordingError.failed("录制画面尺寸发生变化，请结束后重新选择录制范围。"))
            return
        }
        let frame = decoratedFrame(image, at: hostTime)
        guard adaptor.append(frame, withPresentationTime: CMTime(seconds: pts, preferredTimescale: 60_000)) else {
            reportFailure(writer.error)
            return
        }
        lastVideoTime = pts
        acceptedFrames += 1
        if acceptedFrames == 1 { onFirstFrame() }
        drainAudio(until: max(0, Int64((pts - 0.12) * 48_000)))
    }

    private func decoratedFrame(_ original: CVPixelBuffer, at hostTime: Double) -> CVPixelBuffer {
        clicks.removeAll { hostTime - $0.time >= ScreenRecordingClickAnimation.duration }
        let active = clicks.compactMap { click -> (ScreenRecordingClickAnimation, Double)? in
            click.progress(at: hostTime).map { (click, $0) }
        }
        guard !active.isEmpty, let pool = adaptor.pixelBufferPool else { return original }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return original }
        CVPixelBufferLockBaseAddress(original, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(original, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let source = CVPixelBufferGetBaseAddress(original),
              let target = CVPixelBufferGetBaseAddress(destination) else { return original }
        let sourceStride = CVPixelBufferGetBytesPerRow(original), targetStride = CVPixelBufferGetBytesPerRow(destination)
        for row in 0..<height { memcpy(target + row * targetStride, source + row * sourceStride, width * 4) }
        guard let context = CGContext(data: target, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: targetStride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return original }
        let scale = max(0.75, CGFloat(min(width, height)) / 1080)
        for (click, progress) in active {
            let expansion = 1 - pow(1 - progress, 3)
            let radius = CGFloat(10 + expansion * 22) * scale
            let alpha = CGFloat(pow(1 - progress, 1.4))
            let center = CGPoint(x: click.point.x * CGFloat(width), y: (1 - click.point.y) * CGFloat(height))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 0.13 * alpha))
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(red: 0.02, green: 0.56, blue: 1, alpha: 0.95 * alpha))
            context.setLineWidth(2.2 * scale)
            context.strokeEllipse(in: rect)
            let core = CGFloat(4 - expansion * 2) * scale
            context.setFillColor(CGColor(red: 0.02, green: 0.56, blue: 1, alpha: 0.8 * alpha))
            context.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core,
                                          width: core * 2, height: core * 2))
        }
        return destination
    }

    private func appendAudio(_ sample: CMSampleBuffer, source: ScreenRecordingAudioMixer.Source) {
        guard mixer.enabled.contains(source),
              let pts = timeline.time(for: CMSampleBufferGetPresentationTimeStamp(sample).seconds),
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count <= 192_000 else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 2, interleaved: false) else { return }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
            into: input.mutableAudioBufferList) == noErr else { return }
        let converter: AVAudioConverter
        if let existing = converters[source], existing.inputFormat == sourceFormat { converter = existing }
        else {
            guard let next = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return }
            converters[source] = next
            converter = next
        }
        let capacity = AVAudioFrameCount(ceil(Double(count) * 48_000 / sourceFormat.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0,
              let channels = output.floatChannelData else { return }
        let frames = Int(output.frameLength)
        mixer.append(.init(start: Int64((pts * 48_000).rounded()),
            left: Array(UnsafeBufferPointer(start: channels[0], count: frames)),
            right: Array(UnsafeBufferPointer(start: channels[1], count: frames))), source: source)
    }

    private func drainAudio(until limit: Int64) {
        while mixer.cursor < limit, audio.isReadyForMoreMediaData, writer.status == .writing {
            let count = Int(min(1_024, limit - mixer.cursor)), start = mixer.cursor
            let data = mixer.take(frames: count)
            guard let sample = Self.makeAudioSample(data, format: audioFormat, startFrame: start),
                  audio.append(sample) else { reportFailure(writer.error); return }
        }
    }

    static func makeAudioSample(_ interleaved: [Float], format: CMAudioFormatDescription,
                                startFrame: Int64) -> CMSampleBuffer? {
        guard !interleaved.isEmpty, interleaved.count % 2 == 0 else { return nil }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = interleaved.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 8
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: interleaved.count / 2,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func reportFailure(_ error: Error?) {
        guard !failureReported else { return }
        failureReported = true
        onFailure(error ?? ScreenRecordingError.failed("无法继续写入录屏，请检查磁盘空间。"))
    }

    func finish() async throws -> ScreenRecordingMovie {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScreenRecordingMovie, Error>) in
            queue.async { [self] in
                guard !self.finishing, !self.finished else {
                    continuation.resume(throwing: ScreenRecordingError.failed("录屏正在保存，请稍候。")); return
                }
                self.finishing = true
                self.heartbeat?.cancel()
                self.heartbeat = nil
                guard self.writer.status == .writing else {
                    self.finished = true
                    self.latestImage = nil
                    continuation.resume(throwing: self.writer.error ?? ScreenRecordingError.failed("录屏写入已中断，未完成文件保留在应用内临时目录。"))
                    return
                }
                guard self.acceptedFrames > 0 else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.temporaryURL)
                    self.finished = true
                    continuation.resume(throwing: ScreenRecordingError.noFrames)
                    return
                }
                self.finishCompletion = { continuation.resume(with: $0) }
                self.video.markAsFinished()
                let finalTime = self.lastVideoTime + 1 / Double(self.frameRate)
                let limit = Int64((finalTime * 48_000).rounded(.up))
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, !self.finished else { return }
                    self.writer.cancelWriting()
                    self.complete(.failure(ScreenRecordingError.failed("结束录屏超时。未完成文件保留在应用内临时目录。")))
                }
                self.finishWatchdog = timeout
                self.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
                self.audio.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                    guard let self, !self.finished, !self.closingInputs else { return }
                    self.drainAudio(until: limit)
                    guard self.writer.status == .writing else {
                        self.closingInputs = true
                        self.complete(.failure(self.writer.error ?? ScreenRecordingError.failed("录屏写入已中断，未完成文件保留在应用内临时目录。")))
                        return
                    }
                    guard self.mixer.cursor >= limit else { return }
                    self.closingInputs = true
                    self.audio.markAsFinished()
                    self.writer.endSession(atSourceTime: CMTime(seconds: finalTime, preferredTimescale: 60_000))
                    self.writer.finishWriting { [weak self] in
                        guard let self else { return }
                        self.queue.async {
                            guard !self.finished else { return }
                            do {
                                guard self.writer.status == .completed else {
                                    throw self.writer.error ?? ScreenRecordingError.failed("录屏文件未能完成，已保留临时文件。")
                                }
                                try FileManager.default.moveItem(at: self.temporaryURL, to: self.finalURL)
                                self.complete(.success(.init(url: self.finalURL, duration: finalTime,
                                    width: self.width, height: self.height, frameRate: self.frameRate)))
                            } catch { self.complete(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    private func complete(_ result: Result<ScreenRecordingMovie, Error>) {
        guard !finished else { return }
        finished = true
        latestImage = nil
        finishWatchdog?.cancel()
        finishWatchdog = nil
        let callback = finishCompletion
        finishCompletion = nil
        callback?(result)
    }

    func discard() {
        queue.async {
            guard !self.finishing, !self.finished else { return }
            self.finished = true
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.latestImage = nil
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.temporaryURL)
        }
    }
}

/// AVCapture supplies the microphone on macOS 14 as well as newer systems.
/// It is only created after the user enables and authorizes the microphone.
final class ScreenRecordingMicrophone: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.cliphoook.recording.microphone")
    func start(deviceID: String?, writer: ScreenRecordingWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let device: AVCaptureDevice?
                    if let deviceID {
                        device = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                            position: .unspecified).devices.first { $0.uniqueID == deviceID }
                        if device == nil { throw ScreenRecordingError.failed("所选麦克风已不可用，请重新选择输入设备。") }
                    }
                    else { device = AVCaptureDevice.default(for: .audio) }
                    guard let device else { throw ScreenRecordingError.failed("所选麦克风不可用，请重新选择设备。") }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(writer, queue: writer.queue)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw ScreenRecordingError.failed("无法使用所选麦克风。")
                    }
                    self.session.addInput(input)
                    self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw ScreenRecordingError.failed("麦克风未能开始采集。") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.session.stopRunning(); continuation.resume() }
        }
    }
}
