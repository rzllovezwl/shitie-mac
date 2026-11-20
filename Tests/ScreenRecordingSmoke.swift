import AppKit
import AVFoundation
import Foundation

private enum RecordingTestFailure: Error { case failed(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw RecordingTestFailure.failed(message) }
}

@main
struct ScreenRecordingSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookRecording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try timelineAndPreferences()
        try mixer()
        let movie = try await encodedMovie(in: root)
        try await inspect(movie)
        try await staticFrame(in: root)
        try await emptyRecording(in: root)
        try history(movie, in: root)
        try draftLifecycle(movie, in: root)
        try await trimmedDraft(movie, in: root)
        try await clickAnimation(in: root)
        print("Screen recording checks passed: defaults migration, H.264/AAC, pause timeline, static frame duration, draft recovery, native trim model, retained edit decisions, frame-aligned duration export, retry/cancel safety and click ripple pixels")
    }
    @MainActor static func draftLifecycle(_ movie: ScreenRecordingMovie, in root: URL) throws {
        let directory = root.appendingPathComponent("drafts")
        let store = ScreenRecordingDraftStore(directory: directory)
        let domain = "RecordingReview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let history = ClipboardHistoryStore(directory: root.appendingPathComponent("review-history"), defaults: defaults)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        func makeDraft() throws -> ScreenRecordingDraft {
            let workspace = try store.makeWorkspace()
            let url = workspace.appendingPathComponent("review.mp4")
            try FileManager.default.copyItem(at: movie.url, to: url)
            return try store.stage(movie.at(url), sourceName: "Synthetic", sourceBundleID: nil)
        }
        let draft = try makeDraft()
        try check(history.entries.isEmpty, "stopping/staging must not create clipboard history")
        try check(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty,
            "pending preview must not export to Downloads")
        let reopened = ScreenRecordingDraftStore(directory: directory).pendingDrafts()
        try check(reopened.count == 1 && reopened[0].id == draft.id && reopened[0].movie.duration == movie.duration,
            "closing preview / app restart must retain pending review without committing")
        let unavailable = downloads.appendingPathComponent("missing/subfolder/movie.mp4")
        do { _ = try store.save(draft, to: unavailable); throw RecordingTestFailure.failed("invalid export should fail") }
        catch is RecordingTestFailure { throw RecordingTestFailure.failed("invalid export unexpectedly succeeded") }
        catch { }
        try check(store.pendingDrafts().count == 1 && FileManager.default.fileExists(atPath: draft.movie.url.path),
            "failed confirmation must retain playable draft for retry")
        let destination = downloads.appendingPathComponent("confirmed.mp4")
        try Data("old destination".utf8).write(to: destination)
        let saved = try store.save(draft, to: destination)
        try check(saved.url == destination && (try Data(contentsOf: saved.url)) == Data(contentsOf: movie.url),
            "explicit save commits the encoded movie and safely replaces destination")
        try check(store.pendingDrafts().isEmpty && !FileManager.default.fileExists(atPath: draft.movie.url.path),
            "confirmed export removes internal draft")
        try check(history.entries.isEmpty, "draft store does not insert history before the onSaved handoff")
        _ = try history.addFileReference(saved.url, sourceAppName: "Synthetic", sourceAppBundleID: nil,
            screenRecording: .init(duration: saved.duration, width: saved.width, height: saved.height, frameRate: saved.frameRate))
        try check(history.entries.count == 1, "history can be inserted only after confirmation has produced a real file")
        let discarded = try makeDraft()
        try store.discard(discarded)
        try check(store.pendingDrafts().isEmpty && !FileManager.default.fileExists(atPath: discarded.movie.url.path)
            && FileManager.default.fileExists(atPath: saved.url.path), "discard deletes only its internal draft, never saved movie")
    }
    static func timelineAndPreferences() throws {
        try check(ScreenRecordingPhase.ready.canCancel && ScreenRecordingPhase.countdown(3).canCancel
            && !ScreenRecordingPhase.recording.canCancel && !ScreenRecordingPhase.paused.canCancel,
            "Escape must only cancel selection and countdown")
        var timeline = ScreenRecordingTimeline()
        try check(timeline.time(for: 1) == nil, "no timestamp before first frame")
        timeline.start(at: 100)
        timeline.pause(at: 101)
        try check(timeline.time(for: 102) == nil, "paused samples must be dropped")
        timeline.resume(at: 103)
        try check(timeline.time(for: 103) == 1, "same pause removed from video and audio")
        try check(timeline.time(for: 102.9) == nil, "queued pre-resume audio must be dropped")
        timeline.pause(at: 104); timeline.resume(at: 105)
        try check(timeline.time(for: 106) == 3, "multiple pauses must accumulate")
        try check(ScreenRecordingQuality.compact.dimensions(for: CGSize(width: 2000, height: 1000), scale: 2) == CGSize(width: 1920, height: 960), "compact must use bounded even dimensions")
        try check(ScreenRecordingQuality.original.dimensions(for: CGSize(width: 101, height: 51), scale: 1) == CGSize(width: 100, height: 50), "H264 even dimensions")
        let name = "RecordingPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var p = ScreenRecordingPreferences(defaults: defaults)
        try check(p.frameRate == 30 && p.countdown == 0 && p.quality == .compact && p.highlightsClicks
            && p.systemAudio && !p.microphone && p.showsCursor, "new recording defaults")
        p.scope = .window; p.frameRate = 60; p.microphone = true; p.save(defaults: defaults)
        let reopened = ScreenRecordingPreferences(defaults: defaults)
        try check(reopened.scope == .window && reopened.frameRate == 60 && reopened.microphone, "preference persistence")
        p.countdown = 3; p.highlightsClicks = false; p.quality = .original; p.save(defaults: defaults)
        let custom = ScreenRecordingPreferences(defaults: defaults)
        try check(custom.countdown == 3 && !custom.highlightsClicks && custom.quality == .original,
            "choices made after the defaults upgrade must stay unchanged")
        defaults.removeObject(forKey: ScreenRecordingPreferences.defaultsRevisionKey)
        let migrated = ScreenRecordingPreferences(defaults: defaults)
        try check(migrated.countdown == 0 && migrated.highlightsClicks && migrated.quality == .compact
            && migrated.frameRate == 60 && migrated.microphone, "upgrade legacy factory values once, keep other settings")
        defaults.removeObject(forKey: ScreenRecordingPreferences.defaultsRevisionKey)
        defaults.set(5, forKey: ScreenRecordingPreferences.prefix + "countdown")
        try check(ScreenRecordingPreferences(defaults: defaults).countdown == 5, "custom five-second countdown must survive")
        try check(AppShortcutAction.recordScreen.defaultShortcut.displayName == "⌥R" && AppShortcutAction.pauseScreenRecording.defaultShortcut.displayName == "⌥⇧R", "recording defaults")
        try check(AppShortcutAction.recordScreen.isGlobal && AppShortcutAction.pauseScreenRecording.isGlobal, "global recording shortcuts")
    }

    @MainActor static func trimmedDraft(_ movie: ScreenRecordingMovie, in root: URL) async throws {
        let store = ScreenRecordingDraftStore(directory: root.appendingPathComponent("trim-drafts"))
        func makeDraft() throws -> ScreenRecordingDraft {
            let folder = try store.makeWorkspace()
            let source = folder.appendingPathComponent("source.mp4")
            try FileManager.default.copyItem(at: movie.url, to: source)
            return try store.stage(movie.at(source), sourceName: "Synthetic", sourceBundleID: nil)
        }
        let draft = try makeDraft()
        let sourceData = try Data(contentsOf: draft.movie.url)
        let edited = try store.update(draft, trim: .init(start: 0.4, end: 1.4), quality: .compact)
        let reloaded = try require(store.pendingDrafts().first, "edited draft must reopen")
        try check(reloaded.trim == edited.trim && reloaded.quality == .compact,
            "closing/restarting preview must retain trim range and export quality")
        try check(try Data(contentsOf: reloaded.movie.url) == sourceData, "trimming must not rewrite the original")

        _ = NSApplication.shared
        let player = AVPlayer(url: reloaded.movie.url)
        var latest = reloaded
        let edits = RecordingDraftEdits(draft: reloaded, player: player) { trim, quality in
            latest = try store.update(latest, trim: trim, quality: quality)
        }
        let view = AVPlayerView()
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView = view
        view.player = player; view.controlsStyle = .inline
        edits.attach(view)
        for _ in 0..<100 {
            if edits.isReady && view.canBeginTrimming && abs(player.currentTime().seconds - 0.4) < 0.04 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(edits.canTrim && view.canBeginTrimming, "loaded local MP4 must enable the native trimming controls")
        try check(abs(player.currentTime().seconds - 0.4) < 0.04, "reopened preview must start inside the selected range")
        try check(abs(player.currentItem!.reversePlaybackEndTime.seconds - 0.4) < 0.001
            && abs(player.currentItem!.forwardPlaybackEndTime.seconds - 1.4) < 0.001,
            "restored native player must use the saved in/out points")
        player.isMuted = true
        try await checkPlaybackAdvances(player, edits: edits)
        player.play()
        for _ in 0..<120 {
            if player.rate == 0 && player.currentTime().seconds >= 1.35 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(player.rate == 0 && abs(player.currentTime().seconds - 1.4) < 0.05,
            "native playback must stop at the retained trim end")
        edits.setQuality(.original)
        try check(latest.quality == .original && edits.quality == .original, "preview quality must persist")
        edits.reset()
        try check(latest.trim == nil && edits.trim == nil && !player.currentItem!.forwardPlaybackEndTime.isValid,
            "restore-full must clear the persisted edit and playback limits")
        for _ in 0..<100 {
            if player.currentTime().seconds < 0.04 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await checkPlaybackAdvances(player, edits: edits)
        let failing = RecordingDraftEdits(draft: reloaded, player: player) { _, _ in
            throw RecordingTestFailure.failed("simulated manifest failure")
        }
        failing.setQuality(.original)
        try check(failing.error != nil && failing.quality == .compact && failing.trim == reloaded.trim,
            "failed edit persistence must keep the original export decision")
        edits.pausePreview()
        try await Task.sleep(for: .milliseconds(80))
        try check(player.rate == 0, "closing/pausing must keep the native player stopped")
        host.contentView = nil
        player.pause(); player.replaceCurrentItem(with: nil)

        // Export starts between source keyframes, and both sound and video use
        // the same selected time range. The source remains until commit.
        let output = root.appendingPathComponent("trimmed.mp4")
        try Data("old destination".utf8).write(to: output)
        let saved = try await store.saveReviewed(edited, to: output)
        let asset = AVURLAsset(url: saved.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        let actual = try await asset.load(.duration).seconds
        let dimensions = try await tracks[0].load(.naturalSize)
        let audioRange = try await sounds[0].load(.timeRange)
        try check(abs(actual - 1) < 0.07 && abs(saved.duration - actual) < 0.001,
            "trimmed output and metadata must reflect only the selected second")
        try check(dimensions == CGSize(width: 320, height: 240) && saved.width == 320 && saved.height == 240,
            "compact export must not upscale small recordings")
        try check(tracks.count == 1 && sounds.count == 1 && abs(audioRange.duration.seconds - actual) < 0.08,
            "trim must retain synchronized audio")
        let decoded = try AVAssetReader(asset: asset)
        let outputFrames = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        decoded.add(outputFrames); decoded.startReading()
        var firstSignal: Double?, lastSignal: Double?
        while let sample = outputFrames.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let signal = Double(bytes[1]) - Double(bytes[2])
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            if firstSignal == nil { firstSignal = signal }
            lastSignal = signal
        }
        try check(abs(firstSignal ?? 100) < 15 && (lastSignal ?? 0) > 100,
            "export must start/end at the selected source times, not just shorten the file")
        try check(!FileManager.default.fileExists(atPath: edited.movie.url.path) && store.pendingDrafts().isEmpty,
            "only a committed export may remove the pending source")

        let retry = try store.update(makeDraft(), trim: .init(start: 0.2, end: 0.8), quality: .compact)
        let original = try Data(contentsOf: retry.movie.url)
        try Data("invalid video".utf8).write(to: retry.movie.url)
        let oldOutput = try Data(contentsOf: output)
        do { _ = try await store.saveReviewed(retry, to: output); throw RecordingTestFailure.failed("bad source exported") }
        catch is RecordingTestFailure { throw RecordingTestFailure.failed("bad source unexpectedly exported") }
        catch { }
        try check(try Data(contentsOf: output) == oldOutput, "failed transcode must preserve the existing destination")
        try check(store.pendingDrafts().first?.trim == retry.trim, "failed transcode must preserve edit decisions")
        try original.write(to: retry.movie.url)
        let cancellation = Task { try await store.saveReviewed(retry, to: output) }
        cancellation.cancel()
        do { _ = try await cancellation.value; throw RecordingTestFailure.failed("cancelled export committed") }
        catch is CancellationError { }
        try check(try Data(contentsOf: output) == oldOutput, "cancel must not replace the destination")
        _ = try await store.saveReviewed(retry, to: output)
        try check(store.pendingDrafts().isEmpty, "a retained failed/cancelled edit must be saveable on retry")

        for range in [ScreenRecordingTrim(start: -1, end: 1), .init(start: 1, end: 0.5),
                      .init(start: .nan, end: 1), .init(start: 0, end: 20), .init(start: 0.1, end: 0.101)] {
            do {
                _ = try range.validated(duration: 2, frameRate: 30)
                throw RecordingTestFailure.failed("invalid trim accepted")
            } catch is ScreenRecordingError { }
        }
        let legacy = try makeDraft()
        let manifest = legacy.movie.url.deletingLastPathComponent().appendingPathComponent("draft.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        json.removeValue(forKey: "trim"); json.removeValue(forKey: "quality")
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        try check(store.pendingDrafts().first?.quality == .compact && store.pendingDrafts().first?.trim == nil,
            "old pending drafts without edit fields must remain available")
        try store.discard(legacy)
    }

    @MainActor
    private static func checkPlaybackAdvances(_ player: AVPlayer, edits: RecordingDraftEdits) async throws {
        let start = player.currentTime().seconds
        player.play()
        var mainActorTicks = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            mainActorTicks += 1
            if player.currentTime().seconds >= start + 0.15 { break }
        }
        try check(player.error == nil && player.currentTime().seconds >= start + 0.15 && mainActorTicks > 1,
            "native video/audio playback must advance while the main actor keeps responding")
        edits.pausePreview()
        let stopped = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(80))
        try check(player.rate == 0 && abs(player.currentTime().seconds - stopped) < 0.04,
            "preview pause must stop time advancement")
    }

    static func clickAnimation(in root: URL) async throws {
        let recording = try writer(in: root, name: "clicks")
        let frame = try image()
        for index in 0..<40 {
            let host = 200 + Double(index) / 30
            if index == 3 { recording.showClick(at: CGPoint(x: 0.25, y: 0.25), hostTime: host) }
            if index == 8 { recording.showClick(at: CGPoint(x: 0.75, y: 0.75), hostTime: host) }
            recording.enqueueVideo(frame, hostTime: host)
            try await Task.sleep(for: .milliseconds(5))
        }
        let movie = try await recording.finish()
        let asset = AVURLAsset(url: movie.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); reader.startReading()
        var early: Double?, expanded: Double?, both: (Double, Double)?, clean: Double?
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if abs(time - 4.0 / 30) < 0.01 { early = blueSignal(buffer, x: 97, y: 60) }
            if abs(time - 10.0 / 30) < 0.01 {
                expanded = blueSignal(buffer, x: 97, y: 60)
                both = (blueSignal(buffer, x: 80, y: 60), blueSignal(buffer, x: 240, y: 180))
            }
            if time > 1 { clean = blueSignal(buffer, x: 80, y: 60) }
        }
        try check((expanded ?? -100) > (early ?? 100) + 8, "click ring must visibly expand over time")
        try check((both?.0 ?? 0) > 12 && (both?.1 ?? 0) > 12, "rapid clicks must retain both animated locations")
        try check(abs(clean ?? 100) < 10, "ripple must fade back to the original frame")
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let original = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let unchanged = original[60 * CVPixelBufferGetBytesPerRow(frame) + 80 * 4] == 0x99
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        try check(unchanged, "click effects must not burn into the cached source frame")
    }

    static func blueSignal(_ image: CVPixelBuffer, x: Int, y: Int) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        var total: Double = 0
        for row in (y - 1)...(y + 1) {
            for column in (x - 1)...(x + 1) {
                let offset = row * stride + column * 4
                total += Double(bytes[offset]) - Double(bytes[offset + 2])
            }
        }
        return total / 9
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RecordingTestFailure.failed(message) }
        return value
    }
    static func mixer() throws {
        var mix = ScreenRecordingAudioMixer(systemAudio: true, microphone: true)
        mix.append(.init(start: 0, left: [0.5, 0.5], right: [0.2, 0.2]), source: .system)
        mix.append(.init(start: 0, left: [0.25, 0.25], right: [0.1, 0.1]), source: .microphone)
        let block = mix.take(frames: 2)
        try check(abs(block[0] - 0.525) < 0.0001 && abs(block[1] - 0.21) < 0.0001, "two sources mix in one stereo timeline")
        mix.setMicrophoneEnabled(false)
        mix.append(.init(start: 2, left: [1, 1], right: [1, 1]), source: .microphone)
        try check(mix.take(frames: 2).allSatisfy { $0 == 0 }, "muted samples must not leak")
        for i in 0..<200 {
            mix.append(.init(start: Int64(i * 1024), left: Array(repeating: 0.5, count: 1024), right: Array(repeating: 0.5, count: 1024)), source: .system)
        }
        try check(mix.queuedFrameCount <= ScreenRecordingAudioMixer.maximumQueuedFrames, "audio queue is bounded")
    }
    static func image(green: Bool = false) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess, let image else {
            throw RecordingTestFailure.failed("pixel buffer creation")
        }
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0x99, CVPixelBufferGetBytesPerRow(image) * 240)
        if green {
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(image)
            for row in 0..<240 { for column in 0..<320 {
                let offset = row * stride + column * 4
                bytes[offset] = 20; bytes[offset + 1] = 220; bytes[offset + 2] = 30; bytes[offset + 3] = 255
            } }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }
    static func writer(in root: URL, name: String, realtime: Bool = false) throws -> ScreenRecordingWriter {
        try ScreenRecordingWriter(temporaryURL: root.appendingPathComponent(".\(name).mp4"), finalURL: root.appendingPathComponent("\(name).mp4"),
            dimensions: CGSize(width: 320, height: 240), frameRate: 30, systemAudio: true, microphone: true,
            usesRealtimeClock: realtime, onFirstFrame: {}, onFailure: { error in print("writer reported: \(error)") })
    }
    static func audio(at time: Double, frequency: Double) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        let samples = (0..<1600).flatMap { i -> [Float] in
            let value = Float(sin(Double(i) * frequency * 2 * .pi / 48_000) * 0.2)
            return [value, value]
        }
        guard let description, let sample = ScreenRecordingWriter.makeAudioSample(samples, format: description,
            startFrame: Int64((time * 48_000).rounded())) else { throw RecordingTestFailure.failed("audio sample creation") }
        return sample
    }
    static func encodedMovie(in root: URL) async throws -> ScreenRecordingMovie {
        let writer = try writer(in: root, name: "paused")
        let frame = try image()
        let second = try image(green: true)
        for part in 0..<2 {
            for i in 0..<30 {
                let host = (part == 0 ? 100.0 : 103.0) + Double(i) / 30
                writer.enqueueVideo(part == 0 ? frame : second, hostTime: host)
                writer.enqueueAudio(try audio(at: host, frequency: 480), source: .system)
                writer.enqueueAudio(try audio(at: host, frequency: 960), source: .microphone)
                try await Task.sleep(for: .milliseconds(5))
            }
            if part == 0 {
                await writer.pause(at: 101)
                writer.enqueueVideo(frame, hostTime: 102)
                writer.enqueueAudio(try audio(at: 102, frequency: 1920), source: .system)
                await writer.resume(at: 103)
            }
        }
        return try await writer.finish()
    }
    static func inspect(_ movie: ScreenRecordingMovie) async throws {
        try check(FileManager.default.fileExists(atPath: movie.url.path), "completed MP4 exists")
        let asset = AVURLAsset(url: movie.url)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try check(abs(duration - 2) < 0.08 && abs(movie.duration - 2) < 0.04, "pause must not become a blank gap: \(duration)")
        try check(videos.count == 1 && audios.count == 1, "one H264 video and one mixed AAC track")
        let frameReader = try AVAssetReader(asset: asset)
        let frameOutput = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frameReader.add(frameOutput); frameReader.startReading()
        guard let first = frameOutput.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(first) else {
            throw RecordingTestFailure.failed("encoded video must decode to actual pixels")
        }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let brightness = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)[2]
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        try check(CVPixelBufferGetWidth(pixel) == 320 && CVPixelBufferGetHeight(pixel) == 240 && brightness > 80,
            "output dimensions and visible synthetic pixels")
        frameReader.cancelReading()
        let audioDuration = try await audios[0].load(.timeRange).duration.seconds
        try check(abs(audioDuration - duration) < 0.08, "audio/video durations stay synchronized")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); reader.startReading()
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(buffer) / MemoryLayout<Float>.size
            var values = Array(repeating: Float(0), count: count)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            samples.append(contentsOf: values)
        }
        try check(samples.count > 100_000 && samples.contains(where: { abs($0) > 0.02 }), "mixed encoded audio is audible")
        // The paused-only 1920Hz tone must not enter the movie. Inspect a stable
        // section after codec priming for both independently supplied tones.
        let mono = stride(from: 24_000, to: min(samples.count, 72_000), by: 2).map { Double(samples[$0]) }
        func energy(_ frequency: Double) -> Double {
            let real = mono.enumerated().reduce(0.0) { $0 + $1.element * cos(Double($1.offset) * 2 * .pi * frequency / 48_000) }
            let imaginary = mono.enumerated().reduce(0.0) { $0 + $1.element * sin(Double($1.offset) * 2 * .pi * frequency / 48_000) }
            return hypot(real, imaginary) / Double(mono.count)
        }
        try check(energy(480) > 0.02 && energy(960) > 0.02 && energy(1920) < 0.01, "system/mic mixed; paused audio excluded")
    }
    static func staticFrame(in root: URL) async throws {
        let writer = try writer(in: root, name: "static", realtime: true)
        writer.enqueueVideo(try image(), hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        try await Task.sleep(for: .milliseconds(280))
        let movie = try await writer.finish()
        try check(movie.duration >= 0.2, "static scenes must keep recording without new frames")
    }
    static func emptyRecording(in root: URL) async throws {
        let writer = try writer(in: root, name: "empty")
        do { _ = try await writer.finish(); throw RecordingTestFailure.failed("empty recording must fail") }
        catch ScreenRecordingError.noFrames {}
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("empty.mp4").path), "no empty final video")
    }
    @MainActor static func history(_ movie: ScreenRecordingMovie, in root: URL) throws {
        let name = "RecordingHistory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = root.appendingPathComponent("history")
        let store = ClipboardHistoryStore(directory: directory, defaults: defaults)
        let metadata = ClipboardRecordingMetadata(duration: movie.duration, width: movie.width, height: movie.height, frameRate: movie.frameRate)
        try check(try store.addFileReference(movie.url, sourceAppName: "Test", screenRecording: metadata), "record video reference")
        let entry = store.entries[0]
        try check(entry.isScreenRecording && entry.fileCopyName == nil && entry.screenRecording == metadata, "single file, no copied payload")
        _ = try store.addFileReference(movie.url, sourceAppName: "Test")
        let reopened = ClipboardHistoryStore(directory: directory, defaults: defaults)
        try check(reopened.entries.count == 1 && reopened.entries[0].screenRecording == metadata, "metadata survives recopy and restart")
        try check(reopened.filePreviewAccess(for: reopened.entries[0]) != nil, "playable original video reference")
        try reopened.delete(reopened.entries[0])
        try check(FileManager.default.fileExists(atPath: movie.url.path), "deleting history must not delete saved movie")
    }
}
