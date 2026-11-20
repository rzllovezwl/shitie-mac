import Foundation
import CoreGraphics

enum StagingShelfPreference {
    static let autoRevealKey = "stagingShelf.autoReveal"
    static func autoReveal(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoRevealKey) as? Bool ?? true
    }
}

struct StagingShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, image, text, link }
    let id: UUID
    let kind: Kind
    let name: String
    let createdAt: Date
    let identity: String
    var filePath: String?
    var bookmark: Data?
    var bookmarkIsFolder = false
    var assetName: String?
    var text: String?
    var ownedBytes: Int
}

/// A fresh supported pasteboard or a native drag image starts presentation.
/// Dock stacks may use a private drag pasteboard and swallow mouse-down events.
struct StagingDragGate {
    private var idleChangeCount: Int
    private(set) var isDragging = false
    private var suppressed = false
    var needsNativeDragDetection: Bool { !isDragging && !suppressed }

    init(changeCount: Int) { idleChangeCount = changeCount }
    mutating func mouseDown(changeCount: Int) {
        idleChangeCount = changeCount
        isDragging = false
        suppressed = false
    }
    mutating func suppressUntilRelease() { suppressed = true; isDragging = false }
    mutating func update(buttonDown: Bool, changeCount: Int, supported: Bool, blocked: Bool,
                         nativeDragDetected: Bool = false) -> Bool {
        guard buttonDown else {
            idleChangeCount = changeCount
            isDragging = false
            suppressed = false
            return false
        }
        guard !suppressed, !blocked else { return false }
        if (changeCount != idleChangeCount && supported) || nativeDragDetected { isDragging = true }
        return isDragging
    }
}

enum StagingNativeDragDetection {
    static func quartzPointer(_ pointer: CGPoint, primaryScreenTop: CGFloat) -> CGPoint {
        CGPoint(x: pointer.x, y: primaryScreenTop - pointer.y)
    }

    /// Inspect window metadata only. No window names, images or file contents
    /// are requested. Ordinary windows, menus and invisible drag remnants fail.
    static func hasDragImage(in windows: [[String: Any]], pointer: CGPoint) -> Bool {
        windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == Int(CGWindowLevelForKey(.draggingWindow)),
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let value = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: value as CFDictionary),
                  !rect.isEmpty, !rect.isInfinite, !rect.isNull else { return false }
            return rect.insetBy(dx: -72, dy: -72).contains(pointer)
        }
    }
}

enum StagingShelfPlacement {
    enum Edge { case left, right }
    static let defaultSize = CGSize(width: 156, height: 360)

    static func edge(for frame: CGRect, in visibleFrame: CGRect) -> Edge {
        frame.midX < visibleFrame.midX ? .left : .right
    }

    static func collapsedFrame(for frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let width = min(18, visibleFrame.width), height = min(84, visibleFrame.height)
        return CGRect(x: edge(for: frame, in: visibleFrame) == .left
                        ? visibleFrame.minX : visibleFrame.maxX - width,
                      y: min(max(frame.midY - height / 2, visibleFrame.minY), visibleFrame.maxY - height),
                      width: width, height: height)
    }
    static func frame(pointer: CGPoint, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let inset: CGFloat = 18
        let width = min(size.width, max(1, visibleFrame.width - 2 * inset))
        let height = min(size.height, max(1, visibleFrame.height - 2 * inset))
        let x = pointer.x < visibleFrame.midX ? visibleFrame.minX + inset : visibleFrame.maxX - inset - width
        let y = min(max(pointer.y - height / 2, visibleFrame.minY + inset), visibleFrame.maxY - inset - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

}

/// Keep the file list at its full size throughout a transition. Only switch
/// between the full panel and edge-tab layouts while completely transparent.
struct StagingShelfAppearancePose: Equatable {
    let frame: CGRect
    let opacity: CGFloat
    let collapsed: Bool
}

struct StagingShelfAppearanceMotion {
    let from: StagingShelfAppearancePose
    let expandedFrame: CGRect
    let tabFrame: CGRect
    let targetCollapsed: Bool
    let reducedMotion: Bool

    var duration: TimeInterval {
        if reducedMotion { return 0.12 }
        return from.collapsed == targetCollapsed ? 0.20 : 0.28
    }

    var finalPose: StagingShelfAppearancePose {
        StagingShelfAppearancePose(frame: targetCollapsed ? tabFrame : expandedFrame,
                                  opacity: 1, collapsed: targetCollapsed)
    }

    func pose(at elapsed: TimeInterval) -> StagingShelfAppearancePose {
        let progress = CGFloat(min(1, max(0, elapsed / duration)))
        if progress == 0 { return from }
        if progress == 1 { return finalPose }
        if from.collapsed == targetCollapsed {
            // A reversed gesture continues from the last visible pose rather
            // than replaying a whole collapse/expand or snapping to an endpoint.
            return interpolate(from, to: finalPose, progress: progress)
        }
        let handoff: CGFloat = targetCollapsed ? 0.72 : 0.22
        let outgoing = StagingShelfAppearancePose(frame: from.collapsed ? tabFrame : shiftedExpandedFrame,
                                                 opacity: 0, collapsed: from.collapsed)
        if progress < handoff {
            return interpolate(from, to: outgoing, progress: progress / handoff)
        }
        let incoming = StagingShelfAppearancePose(frame: targetCollapsed ? tabFrame : shiftedExpandedFrame,
                                                 opacity: 0, collapsed: targetCollapsed)
        return interpolate(incoming, to: finalPose, progress: (progress - handoff) / (1 - handoff))
    }

    private var shiftedExpandedFrame: CGRect {
        guard !reducedMotion else { return expandedFrame }
        // Slide toward the edge, stopping flush with it. Do not expose content
        // on an adjacent display or move it behind the Dock/menu bar.
        let left = tabFrame.midX < expandedFrame.midX
        let distance = left ? max(0, expandedFrame.minX - tabFrame.minX)
                            : max(0, tabFrame.maxX - expandedFrame.maxX)
        return expandedFrame.offsetBy(dx: min(22, distance) * (left ? -1 : 1), dy: 0)
    }

    private func interpolate(_ start: StagingShelfAppearancePose, to end: StagingShelfAppearancePose,
                             progress: CGFloat) -> StagingShelfAppearancePose {
        let eased = progress * progress * (3 - 2 * progress)
        return StagingShelfAppearancePose(
            frame: CGRect(x: start.frame.minX + (end.frame.minX - start.frame.minX) * eased,
                          y: start.frame.minY + (end.frame.minY - start.frame.minY) * eased,
                          width: start.frame.width, height: start.frame.height),
            opacity: start.opacity + (end.opacity - start.opacity) * eased,
            collapsed: start.collapsed)
    }
}

/// Accumulate only a deliberate horizontal trackpad gesture. Device-space
/// deltas are independent of the system's natural-scrolling preference.
struct StagingShelfEdgeSwipe {
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var consumed = false

    mutating func reset() { horizontal = 0; vertical = 0; consumed = false }

    mutating func update(x: CGFloat, y: CGFloat, inverted: Bool,
                         edge: StagingShelfPlacement.Edge) -> Bool {
        guard !consumed else { return false }
        horizontal += x * (inverted ? -1 : 1)
        vertical += y * (inverted ? -1 : 1)
        let outward = edge == .left ? horizontal : -horizontal
        guard outward >= 38, abs(horizontal) > abs(vertical) * 1.5 else { return false }
        consumed = true
        return true
    }
}

enum StagingShelfGridLayout {
    static let columns = 1
    static let gap: CGFloat = 6
    static let itemHeight: CGFloat = 104
    static let thumbnailSize: CGFloat = 64

    static func frames(count: Int, width: CGFloat) -> [CGRect] {
        let itemWidth = max(1, floor((width - CGFloat(columns - 1) * gap) / CGFloat(columns)))
        return (0..<max(0, count)).map { index in
            CGRect(x: CGFloat(index % columns) * (itemWidth + gap),
                   y: CGFloat(index / columns) * (itemHeight + gap), width: itemWidth, height: itemHeight)
        }
    }

    static func contentHeight(count: Int, viewportHeight: CGFloat) -> CGFloat {
        let rows = (max(0, count) + columns - 1) / columns
        return max(viewportHeight, CGFloat(rows) * (itemHeight + gap) - (rows > 0 ? gap : 0))
    }
}
