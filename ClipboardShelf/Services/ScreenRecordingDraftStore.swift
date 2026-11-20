import Foundation
import AVFoundation

struct ScreenRecordingDraft {
    let id: UUID
    let movie: ScreenRecordingMovie
    let sourceName: String
    let sourceBundleID: String?
    let trim: ScreenRecordingTrim?
    let quality: ScreenRecordingQuality

    init(id: UUID, movie: ScreenRecordingMovie, sourceName: String, sourceBundleID: String?,
         trim: ScreenRecordingTrim? = nil, quality: ScreenRecordingQuality = .compact) {
        self.id = id
        self.movie = movie
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.trim = trim
        self.quality = quality
    }
}

/// Encoded media stays in app-owned storage until the user confirms a file
/// destination. This store does not write to the clipboard history.
struct ScreenRecordingDraftStore: Sendable {
    let directory: URL
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipHoook/RecordingDrafts", isDirectory: true)
    }
    private struct Manifest: Codable {
        let id: UUID
        let fileName: String
        let duration: Double
        let width: Int
        let height: Int
        let frameRate: Int
        let sourceName: String
        let sourceBundleID: String?
        let trim: ScreenRecordingTrim?
        let quality: ScreenRecordingQuality?
    }

    func makeWorkspace() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func stage(_ movie: ScreenRecordingMovie, sourceName: String, sourceBundleID: String?) throws -> ScreenRecordingDraft {
        let folder = movie.url.deletingLastPathComponent()
        guard let id = UUID(uuidString: folder.lastPathComponent),
              folder.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              FileManager.default.fileExists(atPath: movie.url.path), movie.duration.isFinite,
              movie.duration > 0, movie.width > 0, movie.height > 0 else {
            throw ScreenRecordingError.failed("录屏临时文件不可用，请重新录制。")
        }
        let draft = ScreenRecordingDraft(id: id, movie: movie, sourceName: sourceName, sourceBundleID: sourceBundleID)
        try writeManifest(draft, in: folder)
        return draft
    }

    func pendingDrafts() -> [ScreenRecordingDraft] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("draft.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.id == id,
                  manifest.fileName == URL(fileURLWithPath: manifest.fileName).lastPathComponent,
                  manifest.duration.isFinite, manifest.duration > 0, manifest.width > 0, manifest.height > 0 else { return nil }
            let url = folder.appendingPathComponent(manifest.fileName)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
            return ScreenRecordingDraft(id: id, movie: .init(url: url, duration: manifest.duration,
                width: manifest.width, height: manifest.height, frameRate: manifest.frameRate),
                sourceName: manifest.sourceName, sourceBundleID: manifest.sourceBundleID,
                trim: manifest.trim.flatMap { try? $0.validated(duration: manifest.duration, frameRate: manifest.frameRate) },
                quality: manifest.quality ?? .compact)
        }
    }

    /// Persist only the edit decision; the encoded original remains untouched.
    func update(_ draft: ScreenRecordingDraft, trim: ScreenRecordingTrim?,
                quality: ScreenRecordingQuality) throws -> ScreenRecordingDraft {
        let folder = try workspace(for: draft)
        let range = try trim?.validated(duration: draft.movie.duration, frameRate: draft.movie.frameRate)
        let full = range?.isFullRange(duration: draft.movie.duration, frameRate: draft.movie.frameRate) == true
        let updated = ScreenRecordingDraft(id: draft.id, movie: draft.movie, sourceName: draft.sourceName,
            sourceBundleID: draft.sourceBundleID, trim: full ? nil : range, quality: quality)
        try writeManifest(updated, in: folder)
        return updated
    }

    private func writeManifest(_ draft: ScreenRecordingDraft, in folder: URL) throws {
        let movie = draft.movie
        let manifest = Manifest(id: draft.id, fileName: movie.url.lastPathComponent, duration: movie.duration,
            width: movie.width, height: movie.height, frameRate: movie.frameRate,
            sourceName: draft.sourceName, sourceBundleID: draft.sourceBundleID,
            trim: draft.trim, quality: draft.quality)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
    }

    /// Called only after save confirmation. Transcode into a sibling temporary
    /// file first, so failure/cancellation preserves both source and destination.
    func saveReviewed(_ draft: ScreenRecordingDraft, to destination: URL) async throws -> ScreenRecordingMovie {
        let folder = try workspace(for: draft)
        let range = try draft.trim?.validated(duration: draft.movie.duration, frameRate: draft.movie.frameRate)
        let outputSize = draft.quality.dimensions(
            for: CGSize(width: draft.movie.width, height: draft.movie.height), scale: 1)
        if range == nil, outputSize == CGSize(width: draft.movie.width, height: draft.movie.height) {
            try Task.checkCancellation()
            return try save(draft, to: destination)
        }
        let target = try exportDestination(destination)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let movie = try await ScreenRecordingVideoExport.export(draft.movie, to: temporary,
            trim: range, quality: draft.quality)
        try Task.checkCancellation()
        try commit(temporary, to: target)
        try? FileManager.default.removeItem(at: folder)
        return movie.at(target)
    }

    /// Only called after the system save panel returns OK. A failed copy keeps
    /// the draft and any previous destination intact so the user can retry.
    func save(_ draft: ScreenRecordingDraft, to destination: URL) throws -> ScreenRecordingMovie {
        let folder = try workspace(for: draft)
        let target = try exportDestination(destination)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: draft.movie.url, to: temporary)
        try commit(temporary, to: target)
        // The destination is now committed; cleanup failure must not report
        // the successful save as failed or delete the exported movie.
        try? FileManager.default.removeItem(at: folder)
        return draft.movie.at(target)
    }

    func discard(_ draft: ScreenRecordingDraft) throws {
        try FileManager.default.removeItem(at: workspace(for: draft))
    }

    private func exportDestination(_ destination: URL) throws -> URL {
        let target = destination.standardizedFileURL
        guard target != directory.standardizedFileURL,
              !target.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw ScreenRecordingError.failed("请选择临时录屏目录之外的保存位置。")
        }
        return target
    }

    private func commit(_ temporary: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    private func workspace(for draft: ScreenRecordingDraft) throws -> URL {
        let folder = directory.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        guard draft.movie.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              FileManager.default.fileExists(atPath: draft.movie.url.path) else {
            throw ScreenRecordingError.failed("待保存的录屏文件不可用。")
        }
        return folder
    }
}

enum ScreenRecordingVideoExport {
    static func export(_ movie: ScreenRecordingMovie, to destination: URL,
                       trim: ScreenRecordingTrim?, quality: ScreenRecordingQuality) async throws -> ScreenRecordingMovie {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: movie.url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first, duration.seconds.isFinite, duration.seconds > 0 else {
            throw ScreenRecordingError.failed("录屏文件没有可导出的视频画面。")
        }
        let range = try (trim ?? .init(start: 0, end: movie.duration)).validated(
            duration: min(duration.seconds, movie.duration), frameRate: movie.frameRate)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
        guard oriented.width > 0, oriented.height > 0 else {
            throw ScreenRecordingError.failed("无法读取录屏画面尺寸。")
        }
        let dimensions = quality.dimensions(for: oriented.size, scale: 1)
        let composition = AVMutableVideoComposition()
        composition.renderSize = dimensions
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, movie.frameRate)))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: dimensions.width / oriented.width,
                                          y: dimensions.height / oriented.height))
        layer.setTransform(normalized, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else {
            throw ScreenRecordingError.failed("当前录屏无法导出为 MP4。")
        }
        session.videoComposition = composition
        session.outputFileType = .mp4
        session.outputURL = destination
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60_000),
            duration: CMTime(seconds: range.duration, preferredTimescale: 60_000))
        try await ExportOperation(session).run()
        let exported = AVURLAsset(url: destination)
        let actualDuration = try await exported.load(.duration).seconds
        guard actualDuration.isFinite, actualDuration > 0 else {
            throw ScreenRecordingError.failed("导出的视频为空，请重新选择裁剪范围。")
        }
        return ScreenRecordingMovie(url: destination, duration: actualDuration,
            width: Int(dimensions.width), height: Int(dimensions.height), frameRate: movie.frameRate)
    }

    private final class ExportOperation: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func run() async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously { [self] in
                        switch session.status {
                        case .completed: continuation.resume()
                        case .cancelled: continuation.resume(throwing: CancellationError())
                        default: continuation.resume(throwing: session.error
                            ?? ScreenRecordingError.failed("导出录屏失败，原片段已保留，可重试。"))
                        }
                    }
                }
            } onCancel: { self.session.cancelExport() }
        }
    }
}
