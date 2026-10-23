import AppKit
import SwiftUI

private enum ShelfFilterArtwork {
    static let clipboardClock: NSImage = {
        let source = NSImage(named: NSImage.Name(LucideSymbol.clipboardClock.assetName))
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let image = (source.copy() as? NSImage) ?? source
        // Menu bridges its label to AppKit and can use the source image's
        // intrinsic 24 pt PDF size, ignoring a SwiftUI frame on LucideIcon.
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()
}

private struct ShelfCardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

@MainActor
private final class ShelfCardFrameTracker {
    private(set) var frames: [String: CGRect] = [:]
    var presentedKey: String?
    private var pendingUpdate: Task<Void, Never>?

    func receive(
        _ newFrames: [String: CGRect],
        previewedKey: String?,
        onSettled: @escaping (String, CGRect) -> Void
    ) {
        guard newFrames != frames else { return }
        frames = newFrames
        cancel()
        guard let previewedKey, newFrames[previewedKey] != nil else { return }
        // Geometry can change on every scroll frame. Keep it outside SwiftUI
        // @State so scrolling does not redraw the entire shelf repeatedly.
        pendingUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self,
                  let frame = self.frames[previewedKey] else { return }
            self.pendingUpdate = nil
            onSettled(previewedKey, frame)
        }
    }

    func cancel() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
    }
}

struct ShelfView: View {
    private enum FocusTarget: Hashable {
        case search
        case history
        case detail
    }

    private struct FilterCache {
        let query: String
        let filter: ClipboardFilter
        let entries: [ClipboardEntry]
    }

    private struct DisplayedCard: Identifiable {
        let id: String
        let entry: ClipboardEntry
    }

    @ObservedObject var model: AppController
    @AppStorage("panelPlacement") private var panelPlacement = "bottom"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(CardPreviewPreference.enabledKey)
    private var cardFormattedPreviewEnabled = CardPreviewPreference.defaultEnabled
    @State private var searchText = ""
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var filterInventory = ClipboardFilterInventory(entries: [])
    @State private var filterCache = FilterCache(query: "", filter: .all, entries: [])
    @State private var selectedID: UUID?
    @State private var selectedCardKey: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var expandedGroups: Set<UUID> = []
    @State private var detailID: UUID?
    @State private var detailCardKey: String?
    @State private var showsLayoutOptions = false
    @State private var resizeScrollTask: Task<Void, Never>?
    @State private var cardFrameTracker = ShelfCardFrameTracker()
    @State private var hasNavigatedHistory = false
    @FocusState private var focusedTarget: FocusTarget?

    private var filteredEntries: [ClipboardEntry] {
        if filterCache.query == searchText && filterCache.filter == selectedFilter {
            return filterCache.entries
        }
        return filterInventory.matching(model.entries, filter: selectedFilter, query: searchText)
    }

    private var visibleEntries: [DisplayedCard] {
        flattened(filteredEntries)
    }

    private var showsPhoneScreenshotFeatureCard: Bool {
        model.showsPhoneScreenshotFeatureCard && selectedFilter == .all &&
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func flattened(_ roots: [ClipboardEntry]) -> [DisplayedCard] {
        roots.flatMap { entry -> [DisplayedCard] in
            let root = DisplayedCard(id: "root-\(entry.id)", entry: entry)
            guard entry.kind == .group, expandedGroups.contains(entry.id) else { return [root] }
            return [root] + entry.groupMembers.enumerated().map { index, member in
                DisplayedCard(id: "group-\(entry.id)-\(index)-\(member.id)", entry: member)
            }
        }
    }

    private var selectedEntriesInOrder: [ClipboardEntry] {
        visibleEntries.filter { selectedIDs.contains($0.entry.id) }.map(\.entry)
    }

    private func refreshFilteredEntries() {
        let visible = filterInventory.matching(
            model.entries, filter: selectedFilter, query: searchText
        )
        filterCache = FilterCache(query: searchText, filter: selectedFilter, entries: visible)
        let displayed = flattened(visible)
        if let detailID, !displayed.contains(where: { $0.entry.id == detailID }) {
            closeDetail()
        }
        let visibleIDs = Set(displayed.map { $0.entry.id })
        selectedIDs.formIntersection(visibleIDs)
        expandedGroups.formIntersection(Set(model.entries.filter { $0.kind == .group }.map(\.id)))
        if selectedID.map(visibleIDs.contains) != true {
            selectedID = displayed.first?.entry.id
            selectedCardKey = displayed.first?.id
            selectedIDs = selectedID.map { Set([$0]) } ?? []
        } else if !displayed.contains(where: { $0.id == selectedCardKey }) {
            selectedCardKey = displayed.first(where: { $0.entry.id == selectedID })?.id
        }
    }

    private var selectedEntry: ClipboardEntry? {
        visibleEntries.first(where: { $0.entry.id == selectedID })?.entry
    }

    private var detailEntry: ClipboardEntry? {
        visibleEntries.first(where: { $0.entry.id == detailID })?.entry
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

                if showsLayoutOptions && detailEntry == nil {
                    Color.black.opacity(0.08)
                        .contentShape(Rectangle())
                        .onTapGesture { showsLayoutOptions = false }

                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            PanelLayoutQuickPicker(
                                placement: PanelPlacement(rawValue: panelPlacement) ?? .bottom,
                                heightChoice: panelHeight,
                                choosePlacement: { choice in
                                    showsLayoutOptions = false
                                    panelPlacement = choice.rawValue
                                    model.updatePanelLayout()
                                },
                                chooseHeight: { choice in
                                    showsLayoutOptions = false
                                    panelHeight = choice.rawValue
                                    model.updatePanelLayout()
                                },
                                close: { showsLayoutOptions = false }
                            )
                            .frame(width: min(420, geometry.size.width - 32))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, isVertical ? 58 : 60)
                }

                if let message = model.toastMessage {
                    Label(message, systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.bottom, isVertical ? 58 : 42)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "shelfPanel")
            .background {
                ShelfKeyMonitor(onKeyDown: handlePanelKeyDown)
                    .frame(width: 0, height: 0)
            }
            .animation(.easeOut(duration: 0.18), value: model.toastMessage)
        }
        .onPreferenceChange(ShelfCardFramesKey.self) { frames in
            cardFrameTracker.receive(frames, previewedKey: detailCardKey) { key, frame in
                guard detailCardKey == key, let detailID else { return }
                if cardFrameTracker.presentedKey == key {
                    model.updateDetailPreviewAnchor(for: detailID, cardFrame: frame)
                } else if let entry = detailEntry {
                    presentDetail(entry, cardFrame: frame)
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            refreshFilteredEntries()
        }
        .onChange(of: selectedFilter) { _, _ in
            refreshFilteredEntries()
        }
        .onChange(of: model.entries) { _, _ in
            filterInventory = ClipboardFilterInventory(entries: model.entries)
            refreshFilteredEntries()
        }
        .onAppear {
            // PanelController creates a fresh hosting view for every show.
            // Reset once here, without discarding card frames measured during
            // the first layout pass.
            resetForPresentation()
        }
        .onDisappear {
            resizeScrollTask?.cancel()
            cardFrameTracker.cancel()
        }
        .onChange(of: panelPlacement) { _, _ in resizeScrollTask?.cancel() }
    }

    private func resetForPresentation() {
        resizeScrollTask?.cancel()
        cardFrameTracker.cancel()
        cardFrameTracker.presentedKey = nil
        model.closeDetailPreview()
        searchText = ""
        selectedFilter = .all
        filterInventory = ClipboardFilterInventory(entries: model.entries)
        filterCache = FilterCache(query: "", filter: .all, entries: model.entries)
        detailID = nil
        detailCardKey = nil
        showsLayoutOptions = false
        expandedGroups = []
        hasNavigatedHistory = false
        selectedID = model.entries.first?.id
        selectedCardKey = selectedID.map { "root-\($0)" }
        selectedIDs = selectedID.map { Set([$0]) } ?? []
        // Start on the selected card so Space opens its preview immediately.
        focusedTarget = nil
        Task { @MainActor in
            focusedTarget = .history
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
                    HStack(spacing: 8) {
                        searchField
                        if model.isPaused { pausedIndicator }
                    }
                }
            } else {
                HStack(spacing: 14) {
                    searchField
                        .frame(width: 210)
                    Spacer()
                    titleAndCount
                    Spacer()
                    if model.isPaused { pausedIndicator }
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

    private var pausedIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text("已暂停记录")
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.red)
        .accessibilityElement(children: .combine)
    }

    private var titleAndCount: some View {
        HStack(spacing: 8) {
            Menu {
                filterMenuItem(.all)
                Divider()
                filterMenuItem(.plainText)
                filterMenuItem(.richText)
                filterMenuItem(.markdown)
                Menu {
                    filterMenuItem(.code)
                    if filterInventory.count(for: .code) > 0 { Divider() }
                    ForEach(ClipboardFilter.codeLanguages, id: \.self) { language in
                        if filterInventory.count(for: .codeLanguage(language)) > 0 {
                            filterMenuItem(.codeLanguage(language))
                        }
                    }
                } label: {
                    Label("代码 (\(filterInventory.count(for: .code)))", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                filterMenuItem(.link)
                filterMenuItem(.image)
                filterMenuItem(.phoneScreenshot)
                Menu {
                    filterMenuItem(.files)
                    if filterInventory.count(for: .files) > 0 { Divider() }
                    ForEach(ClipboardFilter.fileKinds, id: \.self) { kind in
                        if filterInventory.count(for: .fileKind(kind)) > 0 {
                            filterMenuItem(.fileKind(kind))
                        }
                    }
                } label: {
                    Label("文件 (\(filterInventory.count(for: .files)))", systemImage: "doc")
                }
            } label: {
                HStack(spacing: isVertical ? 3 : 6) {
                    if !isVertical {
                        Image(nsImage: ShelfFilterArtwork.clipboardClock)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                    }
                    Text(isVertical ? selectedFilter.compactLabel : "剪贴板 · \(selectedFilter.label)")
                        .lineLimit(1)
                        .frame(maxWidth: isVertical ? 44 : 180)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, isVertical ? 6 : 12)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.07), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("分类筛选：\(selectedFilter.label)")
            .help("分类筛选：\(selectedFilter.label)")
            if selectedFilter != .all {
                Button {
                    selectedFilter = .all
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消分类筛选")
                .help("取消分类筛选，显示全部")
            }
            if !isVertical {
                Text("\(filteredEntries.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func filterMenuItem(_ filter: ClipboardFilter) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack {
                Text("\(filter.label) (\(filterInventory.count(for: filter)))")
                if selectedFilter == filter { Image(systemName: "checkmark") }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            headerAction(symbol: .layoutDashboard, title: "选择面板布局") {
                showsLayoutOptions.toggle()
            }

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

            headerAction(systemImage: "gearshape", title: "打开设置") {
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

    private func headerAction(
        systemImage: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private var historyStrip: some View {
        Group {
            if filteredEntries.isEmpty && !showsPhoneScreenshotFeatureCard {
                VStack(spacing: 10) {
                    LucideIcon(model.entries.isEmpty ? .clipboard : .scanSearch, size: 34)
                        .foregroundStyle(.secondary)
                    Text(model.entries.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录")
                        .font(.headline)
                    Text(model.entries.isEmpty ? "复制文字、链接或图片后会出现在这里。" :
                         searchText.isEmpty ? "试试其他分类。" : "试试其他关键词或分类。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !model.entries.isEmpty && selectedFilter != .all {
                        Button("显示全部") { selectedFilter = .all }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { stripGeometry in
                    let measuredCardSize = PanelLayout.cardSize(
                        in: stripGeometry.size,
                        placement: PanelPlacement(rawValue: panelPlacement) ?? .bottom
                    )
                    // Follow the window's presentation size during the native
                    // frame animation. Deferring this until the end made every
                    // card visibly jump to its final size.
                    let cardSize = measuredCardSize

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
                        .onDisappear { resizeScrollTask?.cancel() }
                        .onChange(of: selectedID) { _, newID in
                            guard let newID else { return }
                            // Keep the introduction card in view when the
                            // history selection is initialized on opening.
                            if showsPhoneScreenshotFeatureCard && !hasNavigatedHistory { return }
                            withAnimation(.easeOut(duration: 0.16)) {
                                scrollProxy.scrollTo(selectedCardKey ?? "root-\(newID)")
                            }
                        }
                        .onChange(of: stripGeometry.size) { _, _ in
                            // Only scroll after resizing has settled. Repeated
                            // scrollTo calls while AppKit animates the frame
                            // caused the visible motion to stutter.
                            resizeScrollTask?.cancel()
                            resizeScrollTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(90))
                                guard !Task.isCancelled else { return }
                                if showsPhoneScreenshotFeatureCard && !hasNavigatedHistory { return }
                                if let selectedCardKey { scrollProxy.scrollTo(selectedCardKey) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardList(cardSize: CGSize) -> some View {
        if showsPhoneScreenshotFeatureCard {
            phoneScreenshotFeatureCard(cardSize: cardSize)
                .id("phoneScreenshotFeatureCard")
        }
        ForEach(filteredEntries) { entry in
            if entry.kind == .group {
                groupCluster(entry, cardSize: cardSize)
                    .id("root-\(entry.id)")
            } else {
                itemCard(
                    DisplayedCard(id: "root-\(entry.id)", entry: entry),
                    cardSize: cardSize, groupMembership: nil
                )
            }
        }
    }

    private func phoneScreenshotFeatureCard(cardSize: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.openPhoneScreenshotGuide()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                        Text("新功能")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)

                    Spacer(minLength: 12)
                    Image(systemName: "iphone")
                        .font(.system(size: 37, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                    Text("iPhone 截图直达")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("保存到照片后，自动出现在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 7)
                    Spacer(minLength: 10)
                    HStack(spacing: 5) {
                        Text("了解如何设置")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(18)
                .frame(width: cardSize.width, height: cardSize.height)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("了解 iPhone 截图直达功能")

            Button {
                model.dismissPhoneScreenshotFeatureCard()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("不再显示 iPhone 截图介绍卡片")
            .help("不再显示介绍卡片；仍可在设置中打开指南")
            .padding(9)
        }
        .frame(width: cardSize.width, height: cardSize.height)
    }

    /// Navigation keeps a flat sequence, but rendering keeps each group's
    /// cover and members inside one visual boundary. The individual card IDs
    /// stay available to ScrollViewReader and the preview frame tracker.
    private func groupCluster(_ entry: ClipboardEntry, cardSize: CGSize) -> some View {
        let expanded = expandedGroups.contains(entry.id)
        let inset: CGFloat = expanded ? 7 : 0
        let innerSize = CGSize(
            width: max(1, cardSize.width - (isVertical ? 2 * inset : 0)),
            height: max(1, cardSize.height - (isVertical ? 0 : 2 * inset))
        )
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))

        return layout {
            ClipboardGroupCardView(
                entry: entry, cardSize: innerSize,
                isSelected: selectedIDs.contains(entry.id),
                isExpanded: expanded,
                onSelect: { modifiers in
                    select(entry, cardKey: "root-\(entry.id)", modifiers: modifiers)
                },
                onPaste: { pasteSelection(startingAt: entry) },
                onCopy: { copySelection(startingAt: entry) },
                onDelete: { model.confirmDelete(entry) },
                onBeginDrag: { model.beginDrag(dragSelection(startingAt: entry)) },
                onDragStarted: { model.dragSessionBegan() },
                onEndDrag: { model.finishDrag(didDrop: $0) }
            )
            if expanded {
                ForEach(Array(entry.groupMembers.enumerated()), id: \.offset) { index, member in
                    itemCard(
                        DisplayedCard(
                            id: "group-\(entry.id)-\(index)-\(member.id)",
                            entry: member
                        ),
                        cardSize: innerSize,
                        groupMembership: ClipboardGroupMembership(
                            position: index + 1, count: entry.groupMembers.count
                        )
                    )
                    .transition(.opacity.combined(with: .scale(
                        scale: 0.985, anchor: isVertical ? .top : .leading
                    )))
                }
            }
        }
        .padding(inset)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.primary.opacity(0.085))
                .opacity(expanded ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private func itemCard(
        _ card: DisplayedCard, cardSize: CGSize,
        groupMembership: ClipboardGroupMembership?
    ) -> some View {
        let entry = card.entry
        return ClipboardCardView(
            entry: entry,
            imageURL: model.imageURL(for: entry),
            thumbnailURL: model.thumbnailURL(for: entry),
            fileHasSavedCopy: model.fileHasSavedCopy(entry),
            richTextFiles: cardFormattedPreviewEnabled && entry.hasRichText
                ? model.richTextSourceFiles(for: entry)
                : RichTextSourceFiles(rtf: nil, html: nil, rtfd: nil),
            formattedPreviewEnabled: cardFormattedPreviewEnabled,
            cardSize: cardSize,
            isSelected: selectedIDs.contains(entry.id),
            groupMembership: groupMembership,
            onSelect: { modifiers in select(entry, cardKey: card.id, modifiers: modifiers) },
            onPaste: { pasteSelection(startingAt: entry) },
            onCopy: { copySelection(startingAt: entry) },
            canPin: model.canPinImage(entry),
            isPinned: model.isPinnedImage(entry),
            onPin: { model.pinImage(entry) },
            onDelete: { model.confirmDelete(entry) },
            onOpenSource: { model.openSourceApplication(for: entry) },
            onBeginDrag: { model.beginDrag(dragSelection(startingAt: entry)) },
            onDragStarted: { model.dragSessionBegan() },
            onEndDrag: { model.finishDrag(didDrop: $0) }
        )
        .background {
            GeometryReader { cardGeometry in
                Color.clear.preference(
                    key: ShelfCardFramesKey.self,
                    value: [card.id: cardGeometry.frame(in: .named("shelfPanel"))]
                )
            }
        }
        .id(card.id)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if selectedIDs.count > 1 {
                HStack(spacing: 10) {
                    Text("已选 \(selectedIDs.count) 项")
                        .fontWeight(.semibold)
                    Button("复制所选") { model.copySelection(selectedEntriesInOrder) }
                    Button("粘贴所选") { model.pasteSelection(selectedEntriesInOrder) }
                    Spacer(minLength: 0)
                    Button("取消多选") {
                        selectedIDs = selectedID.map { Set([$0]) } ?? []
                    }
                }
                .buttonStyle(.link)
            }
            if let message = model.statusMessage {
                Text(message)
                    .lineLimit(isVertical ? 2 : 1)
                    .foregroundStyle(message.contains("请手动") ? Color.orange : Color.secondary)
            }
            HStack(spacing: 8) {
                Text(shortcutHints)
                    .lineLimit(isVertical ? 2 : 1)
                Spacer()
                Text(model.openPanelShortcut.displayName)
                    .fontWeight(.medium)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var shortcutHints: String {
        let previous = model.shortcut(for: .previous)
        let next = model.shortcut(for: .next)
        let navigation = isVertical && previous == AppShortcutAction.previous.defaultShortcut
            && next == AppShortcutAction.next.defaultShortcut
            ? "↑↓" : "\(previous.displayName) / \(next.displayName)"
        return [
            "\(model.shortcut(for: .deleteEntry).displayName) 删除",
            "\(model.shortcut(for: .focusSearch).displayName) 搜索",
            "\(navigation) 切换",
            "\(model.shortcut(for: .toggleDetail).displayName) 预览",
            "\(model.shortcut(for: .paste).displayName) 按设置粘贴",
            "\(model.shortcut(for: .pastePlainText).displayName) 纯文本",
            "\(model.shortcut(for: .copyOnly).displayName) 仅复制"
        ].joined(separator: " · ")
    }

    private func select(
        _ entry: ClipboardEntry, cardKey: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        hasNavigatedHistory = true
        let held = modifiers.intersection([.command, .shift])
        if !held.isEmpty && detailID != nil { closeDetail() }
        let anchorIndex = visibleEntries.firstIndex(where: { $0.id == selectedCardKey })
            ?? visibleEntries.firstIndex(where: { $0.entry.id == selectedID })
        if held.contains(.shift), selectedID != nil,
           let start = anchorIndex,
           let end = visibleEntries.firstIndex(where: { $0.id == cardKey }) {
            selectedIDs.formUnion(visibleEntries[min(start, end)...max(start, end)].map { $0.entry.id })
            selectedID = entry.id
            selectedCardKey = cardKey
        } else if held.contains(.command) {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
                if selectedID == entry.id {
                    selectedID = selectedIDs.first
                    selectedCardKey = visibleEntries.first(where: { $0.entry.id == selectedID })?.id
                }
            } else {
                selectedIDs.insert(entry.id)
                selectedID = entry.id
                selectedCardKey = cardKey
            }
        } else {
            selectedID = entry.id
            selectedCardKey = cardKey
            selectedIDs = [entry.id]
            if entry.kind == .group {
                toggleGroup(entry)
            } else if detailID != nil && detailID != entry.id {
                openDetail(entry)
            }
        }
        focusedTarget = .history
    }

    private func toggleGroup(_ entry: ClipboardEntry) {
        guard entry.kind == .group else { return }
        if detailID != nil { closeDetail() }
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedGroups.contains(entry.id) {
                expandedGroups.remove(entry.id)
                selectedIDs.subtract(entry.groupMemberIDs)
                if selectedID.map(entry.groupMemberIDs.contains) == true {
                    selectedID = entry.id
                    selectedCardKey = "root-\(entry.id)"
                    selectedIDs.insert(entry.id)
                }
            } else {
                expandedGroups.insert(entry.id)
            }
        }
    }

    private func copySelection(startingAt entry: ClipboardEntry) {
        if selectedIDs.count > 1 && selectedIDs.contains(entry.id) {
            model.copySelection(selectedEntriesInOrder)
        } else {
            model.copy(entry)
        }
    }

    private func dragSelection(startingAt entry: ClipboardEntry) -> [ClipboardEntry] {
        selectedIDs.count > 1 && selectedIDs.contains(entry.id)
            ? selectedEntriesInOrder : [entry]
    }

    private func pasteSelection(startingAt entry: ClipboardEntry) {
        if selectedIDs.count > 1 && selectedIDs.contains(entry.id) {
            model.pasteSelection(selectedEntriesInOrder)
        } else {
            model.paste(entry)
        }
    }

    private func openDetail(_ entry: ClipboardEntry) {
        detailID = entry.id
        detailCardKey = selectedCardKey ?? visibleEntries.first(where: { $0.entry.id == entry.id })?.id
        showsLayoutOptions = false
        if !presentDetail(entry, cardFrame: detailCardKey.flatMap { cardFrameTracker.frames[$0] }) {
            // A card still scrolling into view has no stable position yet.
            // Wait for its measured frame instead of showing a centered preview.
            if cardFrameTracker.presentedKey != nil { model.closeDetailPreview() }
            cardFrameTracker.presentedKey = nil
        }
        focusedTarget = .detail
    }

    @discardableResult
    private func presentDetail(_ entry: ClipboardEntry, cardFrame: CGRect?) -> Bool {
        let shown = model.showDetailPreview(
            entry,
            cardFrame: cardFrame,
            onKeyDown: handlePanelKeyDown,
            onClose: closeDetail
        )
        if shown { cardFrameTracker.presentedKey = detailCardKey }
        return shown
    }

    private func closeDetail() {
        cardFrameTracker.cancel()
        model.closeDetailPreview()
        cardFrameTracker.presentedKey = nil
        detailID = nil
        detailCardKey = nil
        if selectedID != nil {
            focusedTarget = .history
        }
    }

    private func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        guard let action = ShelfKeyboardAction.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            searchFocused: focusedTarget == .search,
            searchIsEmpty: searchText.isEmpty,
            shortcuts: model.shortcuts
        ) else { return false }

        switch action {
        case .previous:
            moveSelection(by: -1)
        case .next:
            moveSelection(by: 1)
        case .paste:
            guard let selectedEntry else { return true }
            if selectedIDs.count > 1 { model.pasteSelection(selectedEntriesInOrder) }
            else { model.paste(selectedEntry) }
        case .pastePlainText:
            guard let selectedEntry else { return true }
            if selectedIDs.count > 1 { model.pasteSelection(selectedEntriesInOrder, plainText: true) }
            else { model.pastePlainText(selectedEntry) }
        case .copyOnly:
            guard let selectedEntry else { return true }
            if selectedIDs.count > 1 { model.copySelection(selectedEntriesInOrder) }
            else { model.copy(selectedEntry) }
        case .deleteSelected:
            guard let entry = detailEntry ?? selectedEntry else { return true }
            model.confirmDelete(entry)
        case .toggleDetail:
            if detailID == nil {
                guard let entry = selectedEntry else { return true }
                if entry.kind == .group { toggleGroup(entry) }
                else { openDetail(entry) }
            } else {
                closeDetail()
            }
        case .dismiss:
            if showsLayoutOptions {
                showsLayoutOptions = false
            } else if detailID != nil {
                closeDetail()
            } else if !searchText.isEmpty {
                searchText = ""
            } else if selectedFilter != .all {
                selectedFilter = .all
            } else {
                model.closePanel()
            }
        case .focusSearch:
            showsLayoutOptions = false
            if detailID != nil { closeDetail() }
            focusedTarget = .search
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard !visibleEntries.isEmpty else { return }
        hasNavigatedHistory = true
        let currentIndex = visibleEntries.firstIndex(where: { $0.id == selectedCardKey }) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), visibleEntries.count - 1)
        let card = visibleEntries[nextIndex]
        let entry = card.entry
        selectedID = entry.id
        selectedCardKey = card.id
        selectedIDs = [entry.id]
        if detailID != nil && detailID != entry.id {
            if entry.kind == .group { closeDetail() }
            else { openDetail(entry) }
        }
    }
}
