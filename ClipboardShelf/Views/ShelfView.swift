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
                .background {
                    ShelfKeyMonitor(onKeyDown: handlePanelKeyDown)
                        .frame(width: 0, height: 0)
                }

                if let entry = detailEntry {
                    Color.black.opacity(0.18)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .onTapGesture { closeDetail() }

                    ClipboardDetailView(
                        entry: entry,
                        imageURL: model.imageURL(for: entry),
                        thumbnailURL: model.thumbnailURL(for: entry),
                        fileHasSavedCopy: model.fileHasSavedCopy(entry),
                        savedCopyName: model.savedCopyDisplayName(for: entry),
                        fileReferenceAvailable: model.fileReferenceIsAvailable(entry),
                        onCopy: { model.copy(entry) },
                        onSaveFileCopy: { model.saveFileCopy(entry) },
                        onDelete: { model.confirmDelete(entry) },
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: searchText) { _, _ in
            selectedID = filteredEntries.first?.id
            detailID = nil
        }
        .onChange(of: model.entries) { _, _ in
            if selectedEntry == nil {
                selectedID = filteredEntries.first?.id
                detailID = nil
            }
        }
        .onChange(of: model.panelPresentationID) { _, _ in
            searchText = ""
            detailID = nil
            selectedID = model.entries.first?.id
            // Start on the selected card so Space opens its preview immediately.
            focusedTarget = nil
            Task { @MainActor in
                focusedTarget = .history
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
            LucideIcon(.scanSearch, size: 16)
                .foregroundStyle(.secondary)
            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .focused($focusedTarget, equals: .search)
        }
    }

    private var titleAndCount: some View {
        HStack(spacing: 8) {
            LucideLabel("剪贴板", symbol: .clipboardClock, iconSize: 15)
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
                    LucideIcon(searchText.isEmpty ? .clipboard : .scanSearch, size: 34)
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
                        // Reopening begins with the newest card fully visible,
                        // even when the previous session scrolled far away.
                        .id(model.panelPresentationID)
                        .scrollIndicators(.hidden)
                        .focusable()
                        .focused($focusedTarget, equals: .history)
                        .focusEffectDisabled()
                        .onChange(of: selectedID) { _, newID in
                            guard let newID else { return }
                            withAnimation(.easeOut(duration: 0.16)) {
                                scrollProxy.scrollTo(newID)
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
                thumbnailURL: model.thumbnailURL(for: entry),
                cardSize: cardSize,
                isSelected: selectedID == entry.id,
                onSelect: { select(entry) },
                onPaste: { model.paste(entry) },
                onCopy: { model.copy(entry) },
                onDelete: { model.confirmDelete(entry) }
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.statusMessage ?? (model.isPaused ? "已暂停记录" : nil) {
                Text(message)
                    .lineLimit(isVertical ? 2 : 1)
                    .foregroundStyle(message.contains("请手动") ? Color.orange : Color.secondary)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(isVertical
                     ? "⌘F 搜索 · ↑↓ 切换 · 空格预览 · ↩ 粘贴 · ⌥↩ 纯文本 · ⌘↩ 只复制"
                     : "⌘F 搜索 · ←→ 切换 · 空格预览 · ↩ 粘贴 · ⌥↩ 纯文本 · ⌘↩ 只复制")
                    .lineLimit(isVertical ? 2 : 1)
                Spacer()
                Text("⌘⇧V")
                    .fontWeight(.medium)
            }
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

    private func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        guard let action = ShelfKeyboardAction.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            searchFocused: focusedTarget == .search,
            searchIsEmpty: searchText.isEmpty
        ) else { return false }

        switch action {
        case .previous:
            moveSelection(by: -1)
        case .next:
            moveSelection(by: 1)
        case .paste:
            guard let selectedEntry else { return true }
            model.paste(selectedEntry)
        case .pastePlainText:
            guard let selectedEntry else { return true }
            model.pastePlainText(selectedEntry)
        case .copyOnly:
            guard let selectedEntry else { return true }
            model.copy(selectedEntry)
        case .toggleDetail:
            if detailID == nil {
                guard let entry = selectedEntry else { return true }
                detailID = entry.id
                focusedTarget = .detail
            } else {
                closeDetail()
            }
        case .dismiss:
            if detailID != nil {
                closeDetail()
            } else if !searchText.isEmpty {
                searchText = ""
            } else {
                model.closePanel()
            }
        case .focusSearch:
            if detailID != nil { closeDetail() }
            focusedTarget = .search
        }
        return true
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
        }
    }
}
