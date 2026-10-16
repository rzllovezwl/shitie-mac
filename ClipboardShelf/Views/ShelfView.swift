import AppKit
import SwiftUI

struct ShelfView: View {
    private enum FocusTarget: Hashable {
        case search
        case history
        case detail
    }

    @ObservedObject var model: AppController
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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 16) {
                    header
                    historyStrip
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 16)
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
                        width: min(640, geometry.size.width - 48),
                        height: min(440, geometry.size.height - 24)
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                    .accessibilityAddTraits(.isModal)
                    .focusable()
                    .focused($focusedTarget, equals: .detail)
                    .focusEffectDisabled()
                    .onKeyPress(keys: [.space, .leftArrow, .rightArrow], action: handleKeyPress)
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
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 190)
                .focused($focusedTarget, equals: .search)

            Spacer()

            Label("剪贴板", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.07), in: Capsule())

            Text("\(filteredEntries.count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Toggle("暂停记录", isOn: $model.isPaused)
                Button("清空历史记录…", role: .destructive) {
                    model.confirmClearHistory()
                }
                .disabled(model.entries.isEmpty)
                Divider()
                Button("设置…", systemImage: "gearshape") {
                    model.openSettings()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多操作")

            Button {
                if detailEntry != nil {
                    closeDetail()
                } else {
                    model.closePanel()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起面板")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .font(.system(size: 15))
    }

    private var historyStrip: some View {
        Group {
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录",
                    systemImage: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "复制文字、链接或图片后会出现在这里。" : "试试其他关键词。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { stripGeometry in
                    let cardHeight = max(1, stripGeometry.size.height - 8)
                    let cardWidth = min(340, max(128, cardHeight * 190 / 252))

                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(filteredEntries) { entry in
                                    ClipboardCardView(
                                        entry: entry,
                                        imageURL: model.imageURL(for: entry),
                                        cardSize: CGSize(width: cardWidth, height: cardHeight),
                                        isSelected: selectedID == entry.id,
                                        onSelect: { select(entry) },
                                        onPaste: { model.paste(entry) },
                                        onCopy: { model.copy(entry) }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 2)
                        }
                        .scrollIndicators(.hidden)
                        .focusable()
                        .focused($focusedTarget, equals: .history)
                        .focusEffectDisabled()
                        .onKeyPress(keys: [.space, .leftArrow, .rightArrow], action: handleKeyPress)
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

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isPaused ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(model.statusMessage ?? (model.isPaused ? "已暂停记录" : "单击选中 · 空格查看详情 · ← → 切换 · 双击粘贴 · 右键复制"))
                .lineLimit(1)
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
