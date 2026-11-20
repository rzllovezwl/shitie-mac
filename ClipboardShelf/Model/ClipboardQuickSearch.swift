import AppKit
import Carbon
import Foundation

struct ClipboardQuickSearchResult: Identifiable {
    let entry: ClipboardEntry
    let summary: String
    let source: String
    let score: Int
    var id: UUID { entry.id }
}

enum ClipboardQuickSearch {
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func results(in entries: [ClipboardEntry], query: String) -> [ClipboardQuickSearchResult] {
        let words = terms(in: query)
        var seen = Set<UUID>()
        var matches: [ClipboardQuickSearchResult] = []
        for root in entries {
            if Task.isCancelled { return [] }
            // A group remains a single recent item; a search can find and use
            // a matching member without accidentally copying the whole group.
            let members = words.isEmpty || root.kind != .group ? [root] : root.groupMembers
            for item in members where seen.insert(item.id).inserted {
                let fields = ClipboardFilterInventory.searchableStrings(of: item, in: root)
                guard words.allSatisfy({ word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }) else { continue }
                let title = item.title
                let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let score: Int
                if words.isEmpty { score = 0 }
                else if title.compare(phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { score = 400 }
                else if title.range(of: phrase, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { score = 300 }
                else if words.allSatisfy({ title.localizedCaseInsensitiveContains($0) }) { score = 200 }
                else { score = 100 }
                let searchableBody = item.text ?? item.ocrText ?? item.fileName ?? title
                let summary = snippet(searchableBody, words: words)
                let source = [item.sourceAppName, root.id != item.id ? root.title : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                matches.append(ClipboardQuickSearchResult(entry: item, summary: summary.isEmpty ? title : summary,
                    source: source, score: score))
            }
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.createdAt != $1.entry.createdAt { return $0.entry.createdAt > $1.entry.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return words.isEmpty ? Array(matches.prefix(10)) : matches
    }

    static func snippet(_ text: String, words: [String], limit: Int = 160) -> String {
        let first = words.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        let start = first.map { text.index($0.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex }
            ?? text.startIndex
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let value = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start != text.startIndex ? "…" : "") + value + (end != text.endIndex ? "…" : "")
    }

    static func selection(after results: [ClipboardQuickSearchResult], previous: UUID?, preserve: Bool) -> UUID? {
        if preserve, let previous, results.contains(where: { $0.id == previous }) { return previous }
        return results.first?.id
    }

    static func moving(_ selected: UUID?, by delta: Int, in results: [ClipboardQuickSearchResult]) -> UUID? {
        guard !results.isEmpty else { return nil }
        let current = selected.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        return results[min(results.count - 1, max(0, current + delta))].id
    }
}

enum QuickSearchKeyAction: Equatable {
    case previous, next, paste, preview, dismiss, focusSearch, switchFocus, copy, copyPlainText

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        inputFocused: Bool, hasMarkedText: Bool) -> Self? {
        guard !hasMarkedText else { return nil }
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if held.isEmpty {
            switch Int(keyCode) {
            case kVK_Escape: return .dismiss
            case kVK_UpArrow: return .previous
            case kVK_DownArrow: return .next
            case kVK_Return, kVK_ANSI_KeypadEnter: return .paste
            case kVK_Tab: return .switchFocus
            case kVK_Space: return inputFocused ? nil : .preview
            default: return nil
            }
        }
        if held == [.shift], keyCode == UInt16(kVK_Tab) { return .switchFocus }
        if held == [.command] {
            if keyCode == UInt16(kVK_Return) { return .preview }
            if keyCode == UInt16(kVK_ANSI_F) { return .focusSearch }
            if keyCode == UInt16(kVK_ANSI_C), !inputFocused { return .copy }
        }
        if held == [.command, .shift], keyCode == UInt16(kVK_ANSI_C), !inputFocused { return .copyPlainText }
        return nil
    }
}

/// Each opening owns its paste destination, even if the regular shelf was last
/// used with another app. The closure dismisses the actual search windows.
@MainActor
struct QuickSearchPasteContext {
    let application: NSRunningApplication?
    let target: PasteTargetSnapshot?
    let dismiss: (@escaping (Bool) -> Void) -> Void
}
