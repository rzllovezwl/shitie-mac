import AppKit
import SwiftUI

struct ShelfView: View {
    private enum FocusTarget: Hashable {
        case search
        case history
        case detail
    }

    @ObservedObject var model: AppController
    @AppStorage("panelPlacement") private var panelPlacement = "bottom"
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var detailID: UUID?
    @FocusState private var focusedTarget: FocusTarget?

    private var filteredEntries: [ClipboardEntry] {
        guard !searchText.isEmpty else { return model.entries }
        return model.entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(searchText)
                || (entry.text?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (entry.sourceAppName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var selectedEntry: ClipboardEntry? {
        filteredEntries.first(where: { $0.id == selectedID })
    }

    private var detailEntry: ClipboardEntry? {
        filteredEntries.first(where: { $0.id == detailID })
    }

    private var isVertical: Bool {
        (PanelPlacement(rawValue: panelPlacement) ?? .bottom).isVertical
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: isVertical ? 10 : 16) {
                    header
                    historyStrip
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
                .padding(.horizontal, isVertical ? 16 : 22)
                .padding(.top, isVertical ? 16 : 18)
                .padding(.bottom, isVertical ? 14 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(.white.opacity(0.32), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 28))

                if let entry = detailEntry {
                    Color.black.opacity(0.18)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .onTapGesture { closeDetail() }

                    ClipboardDetailView(
                        entry: entry,
                        imageURL: model.imageURL(for: entry),
                        onCopy: { model.copy(entry) },
                        onClose: { closeDetail() }
                    )
                    .frame(
                        width: min(640, geometry.size.width - (isVertical ? 20 : 48)),
                        height: min(440, geometry.size.height - 24)
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    .accessibilityAddTraits(.isModal)
                    .focusable()
                    .focused($focusedTarget, equals: .detail)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .upArrow, .downArrow], action: handleKeyPress)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: searchText) { _, _ in
            if selectedEntry == nil {
                selectedID = nil
                detailID = nil
            }
        }
        .onChange(of: model.entries) { _, _ in
            if selectedEntry == nil {
                selectedID = nil
                detailID = nil
            }
        }
        .onChange(of: model.panelPresentationID) { _, _ in
            detailID = nil
            if selectedEntry == nil {
                selectedID = filteredEntries.first?.id
            }
            // Reassert focus after the panel becomes key, including on reopen.
            focusedTarget = nil
            Task { @MainActor in
                if selectedID != nil {
                    focusedTarget = .history
                }
            }
        }
    }

    private var header: some View {
        Group {
            if isVertical {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        titleAndCount
                        Spacer(minLength: 0)
                        headerActions
                    }
                    searchField
                }
            } else {
                HStack(spacing: 14) {
                    searchField
                        .frame(width: 210)
                    Spacer()
                    titleAndCount
                    Spacer()
                    headerActions
                }
            }
        }
        .font(.system(size: 15))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            LucideIcon(.search, size: 16)
                .foregroundStyle(.secondary)
            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .focused($focusedTarget, equals: .search)
        }
    }

    private var titleAndCount: some View {
        HStack(spacing: 8) {
            LucideLabel("剪贴板", symbol: .history, iconSize: 15)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, isVertical ? 8 : 12)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.07), in: Capsule())
            Text("\(filteredEntries.count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            headerAction(
                symbol: model.isPaused ? .play : .pause,
                title: model.isPaused ? "继续记录" : "暂停记录"
            ) {
                model.isPaused.toggle()
            }

            headerAction(symbol: .trash, title: "清空历史记录") {
                model.confirmClearHistory()
            }
            .disabled(model.entries.isEmpty)

            headerAction(symbol: .settings, title: "打开设置") {
                model.openSettings()
            }

            headerAction(symbol: .x, title: "收起面板") {
                if detailEntry != nil {
                    closeDetail()
                } else {
                    model.closePanel()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private func headerAction(
        symbol: LucideSymbol,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LucideIcon(symbol, size: 17)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private var historyStrip: some View {
        Group {
            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    LucideIcon(searchText.isEmpty ? .clipboard : .search, size: 34)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录")
                        .font(.headline)
                    Text(searchText.isEmpty ? "复制文字、链接或图片后会出现在这里。" : "试试其他关键词。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { stripGeometry in
                    let cardSize = PanelLayout.cardSize(
                        in: stripGeometry.size,
                        placement: PanelPlacement(rawValue: panelPlacement) ?? .bottom
                    )

                    ScrollViewReader { scrollProxy in
                        ScrollView(isVertical ? .vertical : .horizontal) {
                            Group {
                                if isVertical {
                                    LazyVStack(spacing: 12) {
                                        cardList(cardSize: cardSize)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                } else {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        cardList(cardSize: cardSize)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 2)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .focusable()
                        .focused($focusedTarget, equals: .history)
                        .focusEffectDisabled()
                        .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .upArrow, .downArrow], action: handleKeyPress)
                        .onChange(of: selectedID) { _, newID in
                            guard let newID else { return }
                            withAnimation(.easeOut(duration: 0.16)) {
                                scrollProxy.scrollTo(newID)
                            }
                        }
                        .onChange(of: model.panelPresentationID) { _, _ in
                            if let selectedID {
                                scrollProxy.scrollTo(selectedID)
                            }
                        }
                        .onChange(of: stripGeometry.size) { _, _ in
                            if let selectedID {
                                scrollProxy.scrollTo(selectedID)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cardList(cardSize: CGSize) -> some View {
        ForEach(filteredEntries) { entry in
            ClipboardCardView(
                entry: entry,
                imageURL: model.imageURL(for: entry),
                cardSize: cardSize,
                isSelected: selectedID == entry.id,
                onSelect: { select(entry) },
                onPaste: { model.paste(entry) },
                onCopy: { model.copy(entry) }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isPaused ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(model.statusMessage ?? (model.isPaused
                ? "已暂停记录"
                : isVertical
                    ? "空格详情 · 方向键切换 · 双击粘贴"
                    : "单击选中 · 空格查看详情 · ← → 切换 · 双击粘贴 · 右键复制"))
                .lineLimit(isVertical ? 2 : 1)
            Spacer()
            Text("⌘⇧V")
                .fontWeight(.medium)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func select(_ entry: ClipboardEntry) {
        selectedID = entry.id
        detailID = nil
        focusedTarget = .history
    }

    private func closeDetail() {
        detailID = nil
        if selectedID != nil {
            focusedTarget = .history
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // macOS can tag arrow keys with implicit modifiers such as numericPad.
        // Only user-held shortcut modifiers should prevent shelf navigation.
        guard !press.modifiers.contains(.command),
              !press.modifiers.contains(.control),
              !press.modifiers.contains(.option),
              !press.modifiers.contains(.shift) else { return .ignored }
        switch press.key {
        case .space:
            if detailID == nil {
                guard let entry = selectedEntry else { return .ignored }
                detailID = entry.id
                focusedTarget = .detail
            } else {
                closeDetail()
            }
            return .handled
        case .leftArrow:
            moveSelection(by: -1)
            return .handled
        case .rightArrow:
            moveSelection(by: 1)
            return .handled
        case .upArrow where isVertical:
            moveSelection(by: -1)
            return .handled
        case .downArrow where isVertical:
            moveSelection(by: 1)
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSelection(by offset: Int) {
        guard !filteredEntries.isEmpty else { return }
        let currentIndex = filteredEntries.firstIndex(where: { $0.id == selectedID }) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), filteredEntries.count - 1)
        let entry = filteredEntries[nextIndex]
        selectedID = entry.id
        if detailID != nil {
            detailID = entry.id
            focusedTarget = .detail
        } else {
            focusedTarget = .history
        }
    }
}
