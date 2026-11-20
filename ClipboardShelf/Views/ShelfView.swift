import AppKit
import Carbon
import SwiftUI

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
        let navigation: ClipboardShelfNavigation
        let pinned: [ClipboardEntry]
        let regular: [ClipboardEntry]
        let pinnedIDs: Set<UUID>

        var count: Int { pinned.count + regular.count }
        var isEmpty: Bool { count == 0 }

        init(navigation: ClipboardShelfNavigation, entries: [ClipboardEntry]) {
            self.navigation = navigation
            pinned = entries.filter { $0.shelfPinOrder != nil }.sorted {
                ($0.shelfPinOrder ?? 0) > ($1.shelfPinOrder ?? 0)
            }
            let scope: ClipboardCardOrderScope = switch navigation.tab {
            case .history: .history
            case .favoriteCategory(let id): .favorite(id)
            }
            regular = ClipboardCardReordering.sorted(entries.filter { $0.shelfPinOrder == nil }, in: scope)
            pinnedIDs = Set(pinned.map(\.id))
        }
    }

    private struct CardScrollTarget: Equatable {
        let key: String?
        let pinnedIDs: Set<UUID>
        let revealsSelection: Bool
    }

    private struct DisplayedCard: Identifiable {
        let id: String
        let entry: ClipboardEntry
    }

    private enum FavoriteCategoryEditorMode: Identifiable {
        case create(entryIDs: [UUID]), edit(ClipboardFavoriteCategory), chooseDestination(entryIDs: [UUID])

        enum ID: Hashable {
            case create, edit(UUID), chooseDestination
        }

        var id: ID {
            switch self {
            case .create: .create
            case .edit(let category): .edit(category.id)
            case .chooseDestination: .chooseDestination
            }
        }
    }

    @ObservedObject var model: AppController
    @AppStorage("panelPlacement") private var panelPlacement = "bottom"
    @AppStorage("panelHeight") private var panelHeight = "standard"
    @AppStorage(CardPreviewPreference.enabledKey)
    private var cardFormattedPreviewEnabled = CardPreviewPreference.defaultEnabled
    @State private var navigation = ClipboardShelfNavigation()
    @State private var showsCalendar = false
    @State private var targetedFavoriteTab: ClipboardShelfNavigation.Tab?
    @State private var isCreateFavoriteTargeted = false
    @State private var favoriteCategoryEditor: FavoriteCategoryEditorMode?
    @State private var filterInventory = ClipboardFilterInventory(entries: [])
    @State private var filterCache = FilterCache(navigation: ClipboardShelfNavigation(), entries: [])
    @State private var selectedID: UUID?
    @State private var selectedCardKey: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var revealsSelection = true
    @State private var expandedGroups: Set<UUID> = []
    @State private var detailID: UUID?
    @State private var detailCardKey: String?
    @State private var detailShowsOCR = false
    @State private var detailShowsTools = false
    @State private var showsLayoutOptions = false
    @State private var resizeScrollTask: Task<Void, Never>?
    @State private var cardFrameTracker = ShelfCardFrameTracker()
    @State private var hasNavigatedHistory = false
    @FocusState private var focusedTarget: FocusTarget?

    private var searchText: String { navigation.filters.query }
    private var selectedFilter: ClipboardFilter { navigation.filters.type }
    private var selectedDate: Date? { navigation.filters.date }
    private var showsFavorites: Bool { navigation.tab != .history }
    private var showsHeaderPopover: Bool { showsCalendar || favoriteCategoryEditor != nil }

    private var imageTextSearchScope: ClipboardImageSearchScope? {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClipboardImageSearchScope(filter: selectedFilter, date: selectedDate, tab: navigation.tab)
    }

    private var isSearchingImageText: Bool {
        guard let scope = imageTextSearchScope else { return false }
        if model.isSearchingImageText { return true }
        guard !model.imageOCRInProgress.isEmpty else { return false }
        return ClipboardFilterInventory.unrecognizedImages(in: model.entries, scope: scope)
            .contains { model.imageOCRInProgress.contains($0.id) }
    }

    private var filteredCards: FilterCache {
        if filterCache.navigation == navigation { return filterCache }
        let entries = filterInventory.matching(model.entries, filter: selectedFilter, query: searchText,
                                               date: selectedDate, tab: navigation.tab)
        return FilterCache(navigation: navigation, entries: entries)
    }

    private var visibleEntries: [DisplayedCard] {
        flattened(filteredCards)
    }

    private var showsPhoneScreenshotFeatureCard: Bool {
        model.showsPhoneScreenshotFeatureCard && selectedDate == nil && !showsFavorites && selectedFilter == .all &&
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func flattened(_ cards: FilterCache) -> [DisplayedCard] {
        (cards.pinned + cards.regular).flatMap { entry -> [DisplayedCard] in
            let root = DisplayedCard(id: "root-\(entry.id)", entry: entry)
            guard entry.kind == .group, expandedGroups.contains(entry.id) else { return [root] }
            return [root] + displayedGroupMembers(of: entry, excluding: cards.pinnedIDs).map { index, member in
                DisplayedCard(id: "group-\(entry.id)-\(index)-\(member.id)", entry: member)
            }
        }
    }

    private func displayedGroupMembers(of entry: ClipboardEntry, excluding pinnedIDs: Set<UUID>)
        -> [(offset: Int, element: ClipboardEntry)] {
        entry.groupMembers.enumerated().filter { _, member in
            !pinnedIDs.contains(member.id) &&
                (navigation.tab.includes(entry) || navigation.tab.includes(member))
        }
    }

    private var selectedEntriesInOrder: [ClipboardEntry] {
        visibleEntries.filter { selectedIDs.contains($0.entry.id) }.map(\.entry)
    }

    private func refreshFilteredEntries() {
        let visible = filterInventory.matching(
            model.entries, filter: selectedFilter, query: searchText, date: selectedDate, tab: navigation.tab
        )
        let cards = FilterCache(navigation: navigation, entries: visible)
        filterCache = cards
        let displayed = flattened(cards)
        if let detailID, !displayed.contains(where: { $0.entry.id == detailID }) {
            closeDetail()
        }
        let visibleIDs = Set(displayed.map { $0.entry.id })
        selectedIDs.formIntersection(visibleIDs)
        expandedGroups.formIntersection(Set(model.entries.filter { $0.kind == .group }.map(\.id)))
        if selectedID.map(visibleIDs.contains) != true {
            revealsSelection = true
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
            let horizontalInset: CGFloat = isVertical ? 16 : 22
            let outline = RoundedRectangle(cornerRadius: ShelfPanelSurface.cornerRadius)
            ZStack {
                VStack(spacing: isVertical ? 10 : 16) {
                    header(width: geometry.size.width - horizontalInset * 2)
                        .zIndex(1)
                    historyStrip
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, isVertical ? 16 : 18)
                .padding(.bottom, isVertical ? 14 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    outline.strokeBorder(.white.opacity(0.32), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .clipShape(outline)

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
                    Label(message, systemImage: message.hasPrefix("历史已占用")
                          ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
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
                ShelfKeyMonitor(editShortcut: selectedEditShortcut, onKeyDown: handlePanelKeyDown)
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
        .onChange(of: navigation) { previous, current in
            revealsSelection = true
            if previous.tab != current.tab {
                filterInventory = ClipboardFilterInventory(entries: model.entries, tab: current.tab)
            }
            refreshFilteredEntries()
        }
        .onChange(of: imageTextSearchScope) { _, scope in
            model.setImageTextSearchScope(scope)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshFilteredEntries()
        }
        .onChange(of: showsHeaderPopover) { _, visible in
            model.setShelfHeaderPopoverVisible(visible)
        }
        .onChange(of: model.entries) { _, _ in
            filterInventory = ClipboardFilterInventory(entries: model.entries, tab: navigation.tab)
            refreshFilteredEntries()
            model.resumeImageTextSearchIfNeeded()
        }
        .onAppear {
            // PanelController creates a fresh hosting view for every show.
            // Reset once here, without discarding card frames measured during
            // the first layout pass.
            resetForPresentation()
        }
        .onDisappear {
            model.setShelfHeaderPopoverVisible(false)
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
        navigation = ClipboardShelfNavigation()
        showsCalendar = false
        targetedFavoriteTab = nil
        isCreateFavoriteTargeted = false
        favoriteCategoryEditor = nil
        filterInventory = ClipboardFilterInventory(entries: model.entries)
        filterCache = FilterCache(navigation: navigation, entries: model.entries)
        detailID = nil
        detailCardKey = nil
        showsLayoutOptions = false
        expandedGroups = []
        hasNavigatedHistory = false
        revealsSelection = true
        selectedID = model.entries.first?.id
        selectedCardKey = selectedID.map { "root-\($0)" }
        selectedIDs = selectedID.map { Set([$0]) } ?? []
        // Start on the selected card so Space opens its preview immediately.
        focusedTarget = nil
        Task { @MainActor in
            focusedTarget = .history
        }
    }

    private func selectTab(_ tab: ClipboardShelfNavigation.Tab) {
        guard tab != navigation.tab else { return }
        if detailID != nil { closeDetail() }
        showsCalendar = false
        showsLayoutOptions = false
        navigation.tab = tab
    }

    private var collectionTabWidth: CGFloat { isVertical ? 50 : 72 }
    private var customCollectionTabWidth: CGFloat { isVertical ? 84 : 100 }
    private let collectionTabSpacing: CGFloat = 2
    private let collectionTabInset: CGFloat = 3
    private let addCollectionButtonWidth: CGFloat = 26
    private static let headerIconSize: CGFloat = 17
    private static let headerDividerWidth: CGFloat = 1
    private var headerActionWidth: CGFloat { isVertical ? 28 : 32 }
    private var headerActionSpacing: CGFloat { isVertical ? 3 : 6 }
    private var trailingHeaderActionsWidth: CGFloat {
        (headerActionWidth + headerActionSpacing) * 2 + Self.headerDividerWidth
    }

    private func header(width: CGFloat) -> some View {
        let spacing: CGFloat = 10
        let categoryCount = model.favoriteCategories.count
        let fixedTabWidth = collectionTabWidth + addCollectionButtonWidth + 2 * collectionTabInset +
            (categoryCount == 0 ? 1 : 2) * collectionTabSpacing
        let minimumTabsWidth = fixedTabWidth + (categoryCount == 0 ? 0 : collectionTabWidth)
        let naturalFavoritesWidth = CGFloat(categoryCount) * customCollectionTabWidth +
            CGFloat(max(0, categoryCount - 1)) * collectionTabSpacing
        let availableSideWidth = (width - minimumTabsWidth) / 2 - spacing
        let actionsWidth = (headerActionWidth + headerActionSpacing) * 4 + trailingHeaderActionsWidth
        let filterWidth: CGFloat = 196
        let compact = isVertical || availableSideWidth < actionsWidth
        let filtersInline = !compact && availableSideWidth >= filterWidth + spacing + actionsWidth
        let reservedSideWidth = compact ? trailingHeaderActionsWidth
            : actionsWidth + (filtersInline ? filterWidth + spacing : 0)
        // Changing the current tab, filter label, or count never shifts the track.
        let favoritesWidth = min(naturalFavoritesWidth, max(1, width - fixedTabWidth - 2 * (reservedSideWidth + spacing)))
        let sideWidth = max(0, (width - fixedTabWidth - favoritesWidth) / 2 - spacing)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: spacing) {
                Group {
                    if compact {
                        HStack(spacing: headerActionSpacing) {
                            layoutButton
                            recordingButton
                        }
                    } else {
                        HStack(spacing: 8) {
                            searchField.frame(maxWidth: 210)
                            if model.isPaused { pausedIndicator.fixedSize() }
                        }
                    }
                }
                .frame(width: sideWidth, alignment: .leading)

                collectionTabs(favoritesWidth: favoritesWidth)

                Group {
                    if compact {
                        trailingHeaderActions
                    } else {
                        HStack(spacing: 0) {
                            if filtersInline {
                                collectionFilters.frame(width: filterWidth, alignment: .leading)
                            }
                            Spacer(minLength: filtersInline ? spacing : 0)
                            headerActions
                        }
                    }
                }
                .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .zIndex(1)

            if compact {
                HStack(spacing: 8) {
                    searchField
                    if model.isPaused { pausedIndicator }
                    calendarButton
                }
            }
            if !filtersInline {
                HStack(spacing: 8) {
                    collectionFilters
                    if compact {
                        Spacer(minLength: 0)
                        clearHistoryButton
                    }
                }
            }
            if let selectedDate { dateFilterBar(selectedDate) }
        }
        .font(.system(size: 15))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            LucideIcon(.search, size: Self.headerIconSize)
                .foregroundStyle(.secondary)
            TextField(showsFavorites ? "搜索收藏" : "搜索历史", text: $navigation.filters.query)
                .textFieldStyle(.plain)
                .focused($focusedTarget, equals: .search)
            if isSearchingImageText && !filteredCards.isEmpty {
                HStack(spacing: 5) {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                    Text("识别中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .fixedSize()
                .help("正在识别图片文字，匹配的图片会陆续显示")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在识别图片文字")
            }
        }
    }

    private var calendarButton: some View {
        Button {
            if detailID != nil { closeDetail() }
            showsLayoutOptions = false
            showsCalendar.toggle()
        } label: {
            LucideIcon(.calendarDays, size: Self.headerIconSize)
                .foregroundStyle(selectedDate != nil || showsCalendar ? Color.accentColor : Color.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按日期查找")
        .accessibilityLabel("按日期查找")
        .popover(isPresented: $showsCalendar, arrowEdge: isVertical ? .leading : .bottom) {
            ClipboardHistoryCalendar(
                counts: filterInventory.dailyCounts(model.entries, filter: selectedFilter, query: searchText,
                                                   tab: navigation.tab),
                selectedDate: selectedDate,
                onSelect: { navigation.filters.date = $0; showsCalendar = false },
                onClose: { showsCalendar = false }
            )
        }
    }

    private func dateFilterBar(_ date: Date) -> some View {
        HStack(spacing: 7) {
            Button { shiftSelectedDate(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 24)
            }.help("前一天")
            Text(date.formatted(.dateTime.year().month().day()))
                .font(.system(size: 12, weight: .medium))
            Button { shiftSelectedDate(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 24)
            }.help("后一天")
            Button { navigation.filters.date = nil } label: {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }.help("取消日期筛选，保留分类和关键词")
        }
        .font(.system(size: 10, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("日期筛选")
    }

    private func shiftSelectedDate(by offset: Int) {
        guard let date = selectedDate,
              let shifted = Calendar.current.date(byAdding: .day, value: offset, to: date) else { return }
        navigation.filters.date = shifted
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

    private func collectionTabs(favoritesWidth: CGFloat) -> some View {
        HStack(spacing: collectionTabSpacing) {
            Button {
                selectTab(.history)
            } label: {
                collectionTabLabel("历史", selected: !showsFavorites, width: collectionTabWidth) {
                    LucideIcon(.clipboardClock, size: 14)
                        .foregroundStyle(showsFavorites ? Color.secondary : Color.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showsFavorites ? [] : .isSelected)

            if favoritesWidth > 0 {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: collectionTabSpacing) {
                            ForEach(model.favoriteCategories) { category in
                                favoriteTab(category, width: min(customCollectionTabWidth, favoritesWidth))
                                    .id(ClipboardShelfNavigation.Tab.favoriteCategory(category.id))
                            }
                        }
                    }
                    .frame(width: favoritesWidth, height: 28)
                    .clipped()
                    .background { FavoriteDropViewport() }
                    .onChange(of: navigation.tab, initial: true) { _, tab in
                        guard tab != .history else { return }
                        // The first category may create the scroll view itself.
                        DispatchQueue.main.async { scroll.scrollTo(tab) }
                    }
                }
            }

            newFavoriteCategoryButton
        }
        .padding(collectionTabInset)
        .background(.primary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("浏览范围")
    }

    private var newFavoriteCategoryButton: some View {
        let help = "点按新建收藏分类，或将卡片拖到这里创建并收藏"
        return Button {
            presentFavoriteCategoryEditor(.create(entryIDs: []))
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: addCollectionButtonWidth, height: 28)
                .foregroundStyle(isCreateFavoriteTargeted ? Color.white : Color.primary)
                .background(isCreateFavoriteTargeted ? Color.accentColor : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("新建收藏分类")
        .accessibilityHint(help)
        .background {
            FavoriteDropRegion(label: "新建收藏分类", help: help,
                               onTargeted: { isCreateFavoriteTargeted = $0 },
                               onDrop: { ids in
                                   presentFavoriteCategoryEditor(.create(entryIDs: ids))
                                   return true
                               }, clipsToFavoriteViewport: false)
        }
        .overlay(alignment: .topTrailing) {
            if isCreateFavoriteTargeted {
                Text("松开新建分类")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: 46)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .popover(item: $favoriteCategoryEditor, arrowEdge: .bottom) { mode in
            switch mode {
            case .create(let ids): favoriteCategoryForm(editing: nil, collecting: Set(ids))
            case .edit(let category): favoriteCategoryForm(editing: category)
            case .chooseDestination(let ids): favoriteDestinationPicker(for: ids)
            }
        }
    }

    private func favoriteCategoryForm(editing category: ClipboardFavoriteCategory?,
                                      collecting ids: Set<UUID> = []) -> some View {
        ShelfFavoriteCategoryEditor(category: category, entryCount: ids.count,
                                    onCancel: { favoriteCategoryEditor = nil }) { name, tint, icon in
            let saved = try model.saveFavoriteCategory(name: name, tint: tint, icon: icon,
                                                       editing: category?.id, collecting: ids)
            favoriteCategoryEditor = nil
            if category == nil { selectTab(.favoriteCategory(saved.id)) }
        }
    }

    private func favoriteDestinationPicker(for ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("收藏到").font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.favoriteCategories) { category in
                        Button {
                            if model.moveFavorites(ids, to: category.id) { favoriteCategoryEditor = nil }
                        } label: {
                            HStack(spacing: 8) {
                                ShelfFavoriteCategoryIcon(icon: category.icon, size: 16)
                                Text(category.name).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .background(category.tint.displayColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(category.name)
                    }
                }
            }
            .frame(height: min(220, CGFloat(max(1, model.favoriteCategories.count)) * 30))
            Button("新建收藏分类…", systemImage: "plus") {
                favoriteCategoryEditor = .create(entryIDs: ids)
            }
        }
        .padding(14)
        .frame(width: 232)
    }

    private func favoriteTab(_ category: ClipboardFavoriteCategory, width: CGFloat) -> some View {
        let tab = ClipboardShelfNavigation.Tab.favoriteCategory(category.id)
        let selected = navigation.tab == tab
        return collectionTabLabel(category.name, selected: selected, width: width, isFavoriteCategory: true) {
            ShelfFavoriteCategoryIcon(icon: category.icon, size: 14)
        }
            .accessibilityHidden(true)
            .overlay {
                if targetedFavoriteTab == tab {
                    Capsule()
                        .strokeBorder(selected ? Color.white : Color.accentColor,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                FavoriteDropRegion(
                    label: category.name, help: "\(category.name) · 点按查看，拖入卡片收藏，右键管理",
                    isSelected: selected,
                    onOpen: { selectTab(tab) },
                    onTargeted: { targeted in
                        if targeted { targetedFavoriteTab = tab }
                        else if targetedFavoriteTab == tab { targetedFavoriteTab = nil }
                    },
                    onDrop: { model.moveFavorites($0, to: category.id) },
                    onEdit: { presentFavoriteCategoryEditor(.edit(category)) },
                    onDelete: {
                        if model.confirmDeleteFavoriteCategory(category) { navigation.removeCategory(category.id) }
                    }
                )
            }
    }

    private func presentFavoriteCategoryEditor(_ mode: FavoriteCategoryEditorMode) {
        showsCalendar = false
        showsLayoutOptions = false
        if detailID != nil { closeDetail() }
        favoriteCategoryEditor = mode
    }

    private func collectionTabLabel<Glyph: View>(_ title: String, selected: Bool, width: CGFloat,
                                               isFavoriteCategory: Bool = false, icon: () -> Glyph) -> some View {
        let idleBackground = isFavoriteCategory ? Color.clear : Color.primary.opacity(0.06)
        return HStack(spacing: 5) {
            if !isVertical || isFavoriteCategory {
                icon().accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 6)
        .frame(width: width, height: 28)
        .background(selected ? Color(nsColor: .systemBlue) : idleBackground, in: Capsule())
        .contentShape(Rectangle())
    }

    private var collectionFilters: some View {
        HStack(spacing: 7) {
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
                filterMenuItem(.screenScreenshot)
                filterMenuItem(.cliphoookScreenshot)
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
                HStack(spacing: 5) {
                    Text(selectedFilter == .all ? "全部类型" : isVertical ? selectedFilter.compactLabel : selectedFilter.label)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("分类筛选，\(selectedFilter.label)")
            .help("按类型筛选")
            if selectedFilter != .all {
                Button {
                    navigation.filters.type = .all
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
            Text("\(filteredCards.count) 项")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("\(filteredCards.count) 条匹配记录")
        }
    }

    private func filterMenuItem(_ filter: ClipboardFilter) -> some View {
        Button {
            navigation.filters.type = filter
        } label: {
            HStack {
                Text("\(filter.label) (\(filterInventory.count(for: filter)))")
                if selectedFilter == filter { Image(systemName: "checkmark") }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: headerActionSpacing) {
            calendarButton
            layoutButton
            recordingButton
            clearHistoryButton
            trailingHeaderActions
        }
    }

    private var trailingHeaderActions: some View {
        HStack(spacing: headerActionSpacing) {
            Rectangle()
                .fill(.primary.opacity(0.16))
                .frame(width: Self.headerDividerWidth, height: 15)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            settingsButton
            closeButton
        }
    }

    private var layoutButton: some View {
        headerAction(symbol: .layoutDashboard, title: "选择面板布局") {
            showsCalendar = false
            showsLayoutOptions.toggle()
        }
    }

    private var recordingButton: some View {
        headerAction(symbol: model.isPaused ? .play : .pause, title: model.isPaused ? "继续记录" : "暂停记录") {
            model.isPaused.toggle()
        }
    }

    private var clearHistoryButton: some View {
        headerAction(symbol: .trash, title: "清空历史记录") {
            model.confirmClearHistory()
        }
        .disabled(model.entries.isEmpty)
    }

    private var settingsButton: some View {
        Button {
            model.openSettings(category: .clipboard)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .frame(width: headerActionWidth, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开设置")
        .help("打开设置")
    }

    private var closeButton: some View {
        headerAction(symbol: .x, title: "收起面板") {
            if detailEntry != nil {
                closeDetail()
            } else {
                model.closePanel()
            }
        }
    }

    private func headerAction(
        symbol: LucideSymbol,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LucideIcon(symbol, size: Self.headerIconSize)
                .frame(width: headerActionWidth, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private var historyStrip: some View {
        let cards = filteredCards
        return Group {
            if cards.isEmpty && isSearchingImageText {
                ScanLoadingOverlay(message: "正在搜索图片文字…")
                    .frame(width: 164, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cards.isEmpty && !showsPhoneScreenshotFeatureCard {
                let emptyFavorites = showsFavorites && selectedDate == nil && selectedFilter == .all &&
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                VStack(spacing: 10) {
                    LucideIcon(showsFavorites ? .star : model.entries.isEmpty ? .clipboard : .scanSearch, size: 34)
                        .foregroundStyle(.secondary)
                    Text(selectedDate != nil ? "这一天没有匹配的记录" : emptyFavorites ? "还没有收藏" : model.entries.isEmpty && !showsFavorites ? "还没有剪贴板记录" : "没有匹配的记录")
                        .font(.headline)
                    Text(selectedDate != nil ? "可切换日期，或取消日期筛选。" : emptyFavorites ? "从「历史」将卡片拖到这个标签，或右键选择「收藏到」。" : model.entries.isEmpty && !showsFavorites ? "复制文字、链接或图片后会出现在这里。" :
                         searchText.isEmpty ? "试试其他分类。" : "试试其他关键词或分类。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !model.entries.isEmpty && selectedFilter != .all {
                        Button("显示全部类型") { navigation.filters.type = .all }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { stripGeometry in
                    historyLanes(cards, size: stripGeometry.size)
                }
            }
        }
    }

    private func historyLanes(_ cards: FilterCache, size: CGSize) -> some View {
        // Follow the presentation size during the window frame animation.
        let cardSize = PanelLayout.cardSize(
            in: size, placement: PanelPlacement(rawValue: panelPlacement) ?? .bottom
        )
        let hasRegularLane = !cards.regular.isEmpty || showsPhoneScreenshotFeatureCard
        let hasBothLanes = !cards.pinned.isEmpty && hasRegularLane
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: (PanelLayout.shelfLaneGap - 1) / 2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: (PanelLayout.shelfLaneGap - 1) / 2))
        let scrollTarget = CardScrollTarget(key: selectedCardKey, pinnedIDs: cards.pinnedIDs,
                                            revealsSelection: revealsSelection)

        return ScrollViewReader { scrollProxy in
            layout {
                if !cards.pinned.isEmpty {
                    let length = hasBothLanes ? pinnedLaneLength(cards, in: size, cardSize: cardSize) : nil
                    cardLane(cards.pinned, cardSize: cardSize, pinnedIDs: cards.pinnedIDs)
                        .frame(width: isVertical ? nil : length, height: isVertical ? length : nil)
                }
                if hasBothLanes {
                    Rectangle()
                        .fill(.primary.opacity(0.12))
                        .frame(width: isVertical ? nil : 1, height: isVertical ? 1 : nil)
                        .padding(isVertical ? .horizontal : .vertical, 8)
                        .accessibilityHidden(true)
                }
                if hasRegularLane {
                    cardLane(cards.regular, cardSize: cardSize, pinnedIDs: cards.pinnedIDs,
                             showIntroduction: showsPhoneScreenshotFeatureCard)
                }
            }
            .id(model.panelPresentationID)
            .focusable()
            .focused($focusedTarget, equals: .history)
            .focusEffectDisabled()
            .onDisappear { resizeScrollTask?.cancel() }
            .onChange(of: scrollTarget) { previous, target in
                guard let key = target.key,
                      target.revealsSelection || previous.pinnedIDs != target.pinnedIDs else { return }
                // Keep the introduction card in view when opening History.
                if showsPhoneScreenshotFeatureCard && !hasNavigatedHistory { return }
                withAnimation(.easeOut(duration: 0.16)) { scrollProxy.scrollTo(key) }
            }
            .onChange(of: size) { _, _ in
                // Wait for the window frame animation to settle before scrolling.
                resizeScrollTask?.cancel()
                // Mouse selection already identifies a visible card. In
                // particular, the multi-selection footer changes card size;
                // this is not a request to scroll either lane back to a card.
                guard revealsSelection else { return }
                resizeScrollTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled, revealsSelection else { return }
                    if showsPhoneScreenshotFeatureCard && !hasNavigatedHistory { return }
                    if let selectedCardKey { scrollProxy.scrollTo(selectedCardKey) }
                }
            }
        }
    }

    private func pinnedLaneLength(_ cards: FilterCache, in size: CGSize, cardSize: CGSize) -> CGFloat {
        let cardLength = isVertical ? cardSize.height : cardSize.width
        var contentLength = cardLength * CGFloat(cards.pinned.count)
            + PanelLayout.shelfCardSpacing * CGFloat(cards.pinned.count - 1)
            + 2 * PanelLayout.shelfLaneInset
        for group in cards.pinned where expandedGroups.contains(group.id) {
            let count = displayedGroupMembers(of: group, excluding: cards.pinnedIDs).count
            if count > 0 { contentLength += CGFloat(count) * (cardLength + Self.groupSpacing) + 2 * Self.groupInset }
        }
        return PanelLayout.pinnedLaneLength(
            available: isVertical ? size.height : size.width, cardLength: cardLength, contentLength: contentLength
        )
    }

    private func cardLane(_ entries: [ClipboardEntry], cardSize: CGSize, pinnedIDs: Set<UUID>,
                          showIntroduction: Bool = false) -> some View {
        GeometryReader { viewport in
            let viewportFrame = viewport.frame(in: .named("shelfPanel"))
            ScrollView(isVertical ? .vertical : .horizontal) {
                if isVertical {
                    LazyVStack(spacing: PanelLayout.shelfCardSpacing) {
                        cardList(entries, cardSize: cardSize, pinnedIDs: pinnedIDs, showIntroduction: showIntroduction)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, PanelLayout.shelfLaneInset)
                } else {
                    LazyHStack(alignment: .top, spacing: PanelLayout.shelfCardSpacing) {
                        cardList(entries, cardSize: cardSize, pinnedIDs: pinnedIDs, showIntroduction: showIntroduction)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, PanelLayout.shelfLaneInset)
                }
            }
            .scrollIndicators(.hidden)
            .background { CardReorderViewport() }
            .transformPreference(ShelfCardFramesKey.self) { frames in
                // A clipped card must not anchor its preview over the neighboring lane.
                frames = frames.compactMapValues { frame in
                    let visible = frame.intersection(viewportFrame)
                    return visible.isEmpty ? nil : visible
                }
            }
        }
    }

    @ViewBuilder
    private func cardList(_ entries: [ClipboardEntry], cardSize: CGSize, pinnedIDs: Set<UUID>,
                          showIntroduction: Bool) -> some View {
        if showIntroduction {
            phoneScreenshotFeatureCard(cardSize: cardSize)
                .id("phoneScreenshotFeatureCard")
        }
        ForEach(entries) { entry in
            if entry.kind == .group {
                groupCluster(entry, cardSize: cardSize, pinnedIDs: pinnedIDs)
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

    private static let groupInset: CGFloat = 7
    private static let groupSpacing: CGFloat = 8

    /// Navigation keeps a flat sequence, but rendering keeps each group's
    /// cover and members inside one visual boundary. The individual card IDs
    /// stay available to ScrollViewReader and the preview frame tracker.
    private func rootReorderScope(for entry: ClipboardEntry) -> ClipboardCardOrderScope {
        if entry.shelfPinOrder != nil { return .pins }
        switch navigation.tab {
        case .history: return .history
        case .favoriteCategory(let id): return .favorite(id)
        }
    }

    private func reorderRegion(for entry: ClipboardEntry, scope: ClipboardCardOrderScope) -> some View {
        CardReorderDropRegion(entryID: entry.id, scope: scope, isVertical: isVertical) { ids, after in
            model.reorderCards(ids, relativeTo: entry.id, after: after, in: scope)
        }
    }

    private func groupCluster(_ entry: ClipboardEntry, cardSize: CGSize, pinnedIDs: Set<UUID>) -> some View {
        let members = displayedGroupMembers(of: entry, excluding: pinnedIDs)
        let expanded = !members.isEmpty && expandedGroups.contains(entry.id)
        let inset = expanded ? Self.groupInset : 0
        let innerSize = CGSize(
            width: max(1, cardSize.width - (isVertical ? 2 * inset : 0)),
            height: max(1, cardSize.height - (isVertical ? 0 : 2 * inset))
        )
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.groupSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Self.groupSpacing))

        return layout {
            ClipboardGroupCardView(
                entry: entry, cardSize: innerSize,
                isSelected: selectedIDs.contains(entry.id),
                isExpanded: expanded, canExpand: !members.isEmpty,
                onSelect: { modifiers in
                    select(entry, cardKey: "root-\(entry.id)", modifiers: modifiers)
                },
                onPaste: { pasteSelection(startingAt: entry) },
                onCopy: { copySelection(startingAt: entry) },
                onDelete: { model.confirmDelete(entry) },
                onContextSelect: {
                    selectForContextMenu(entry, cardKey: "root-\(entry.id)")
                },
                makeContextMenu: { contextMenuSections(for: entry) },
                onBeginDrag: { model.beginDrag(dragSelection(startingAt: entry), reorderingIn: rootReorderScope(for: entry)) },
                onDragStarted: { model.dragSessionBegan() },
                onDragMoved: { model.dragSessionMoved(to: $0) },
                onEndDrag: { model.finishDrag(didDrop: $0) },
                onCancelFavorite: { model.removeFavorites([entry]) },
                favoriteShortcut: model.shortcut(for: .toggleFavorite).displayName,
                onCancelShelfPin: { setShelfPinned([entry], pinned: false) },
                shelfPinShortcut: model.shortcut(for: .toggleShelfPin).displayName
            )
            if expanded {
                ForEach(members, id: \.offset) { index, member in
                    itemCard(
                        DisplayedCard(
                            id: "group-\(entry.id)-\(index)-\(member.id)",
                            entry: member
                        ),
                        cardSize: innerSize,
                        groupMembership: ClipboardGroupMembership(
                            position: index + 1, count: entry.groupMembers.count
                        ), reorderScope: .group(entry.id)
                    )
                    .transition(.opacity.combined(with: .scale(
                        scale: 0.985, anchor: isVertical ? .top : .leading
                    )))
                }
            }
        }
        .padding(inset)
        .background { reorderRegion(for: entry, scope: rootReorderScope(for: entry)) }
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
        groupMembership: ClipboardGroupMembership?, reorderScope: ClipboardCardOrderScope? = nil
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
            onDelete: { model.confirmDelete(entry) },
            canRecognizeImage: model.canRecognizeImage(entry),
            recognizeShortcut: model.shortcut(for: .recognizeImageText).displayName,
            onRecognizeImage: { recognizeImageText(entry, cardKey: card.id) },
            onContextSelect: { selectForContextMenu(entry, cardKey: card.id) },
            makeContextMenu: { contextMenuSections(for: entry) },
            onOpenSource: { model.openSourceApplication(for: entry) },
            onBeginDrag: { model.beginDrag(dragSelection(startingAt: entry), reorderingIn: reorderScope ?? rootReorderScope(for: entry)) },
            onDragStarted: { model.dragSessionBegan() },
            onDragMoved: { model.dragSessionMoved(to: $0) },
            onEndDrag: { model.finishDrag(didDrop: $0) },
            onCancelFavorite: { model.removeFavorites([entry]) },
            favoriteShortcut: model.shortcut(for: .toggleFavorite).displayName,
            onCancelShelfPin: { setShelfPinned([entry], pinned: false) },
            shelfPinShortcut: model.shortcut(for: .toggleShelfPin).displayName
        )
        .background { reorderRegion(for: entry, scope: reorderScope ?? rootReorderScope(for: entry)) }
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
        preservePointerSelectionPosition()
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

    private func preservePointerSelectionPosition() {
        revealsSelection = false
        resizeScrollTask?.cancel()
    }

    private func toggleGroup(_ entry: ClipboardEntry) {
        guard entry.kind == .group else { return }
        let memberIDs = displayedGroupMembers(of: entry, excluding: filteredCards.pinnedIDs).map { $0.element.id }
        guard !memberIDs.isEmpty else { return }
        if detailID != nil { closeDetail() }
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedGroups.contains(entry.id) {
                expandedGroups.remove(entry.id)
                selectedIDs.subtract(memberIDs)
                if selectedID.map(memberIDs.contains) == true {
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

    private func selectForContextMenu(_ entry: ClipboardEntry, cardKey: String) {
        preservePointerSelectionPosition()
        hasNavigatedHistory = true
        if !selectedIDs.contains(entry.id) || selectedIDs.count < 2 {
            selectedIDs = [entry.id]
        }
        selectedID = entry.id
        selectedCardKey = cardKey
        if detailID != nil && detailID != entry.id { closeDetail() }
        focusedTarget = .history
    }

    private func contextSelection(startingAt entry: ClipboardEntry) -> [ClipboardEntry] {
        selectedIDs.count > 1 && selectedIDs.contains(entry.id)
            ? selectedEntriesInOrder : [entry]
    }

    private func setShelfPinned(_ selection: [ClipboardEntry], pinned: Bool) {
        if model.setShelfPinned(selection, pinned: pinned), detailID != nil { closeDetail() }
    }

    private func contextShortcut(_ action: AppShortcutAction) -> String {
        model.shortcut(for: action).displayName.replacingOccurrences(of: "空格", with: "␣")
    }

    private func contextMenuSections(for entry: ClipboardEntry) -> [[CardContextAction]] {
        let selection = contextSelection(startingAt: entry)
        let isMultiple = selection.count > 1
        let canUsePlainText = AppController.canUsePlainText(selection)
        let groups = selection.filter { $0.kind == .group }
        let memberIDs = selection.flatMap { $0.kind == .group ? $0.groupMembers.map(\.id) : [$0.id] }
        let chosenMemberIDs = Set(memberIDs)
        let canGroup = isMultiple && chosenMemberIDs.count > 1 &&
            !groups.contains { Set($0.groupMemberIDs) == chosenMemberIDs }
        var contentActions = [
            CardContextAction(isMultiple ? "复制所选" : entry.kind == .group ? "复制整组" : "复制",
                              shortcut: contextShortcut(.copyOnly)) {
                isMultiple ? model.copySelection(selection) : model.copy(entry)
            },
            CardContextAction(isMultiple ? "复制所选纯文本" : entry.kind == .group ? "复制整组纯文本" : "复制纯文本",
                              shortcut: contextShortcut(.copyPlainText), isEnabled: canUsePlainText) {
                isMultiple ? model.copySelection(selection, plainText: true) : model.copyPlainText(entry)
            },
            CardContextAction(isMultiple ? "粘贴所选" : entry.kind == .group ? "粘贴整组" : "按设置粘贴",
                              shortcut: contextShortcut(.paste)) {
                isMultiple ? model.pasteSelection(selection) : model.paste(entry)
            },
            CardContextAction(isMultiple ? "纯文本粘贴所选" : entry.kind == .group ? "纯文本粘贴整组" : "纯文本粘贴",
                              shortcut: contextShortcut(.pastePlainText), isEnabled: canUsePlainText) {
                isMultiple ? model.pasteSelection(selection, plainText: true) : model.pastePlainText(entry)
            }
        ]
        if !isMultiple && (entry.isImagePreviewable || entry.isScreenRecording) {
            contentActions.append(CardContextAction(
                "保存为…", shortcut: contextShortcut(.saveImageToFile),
                isEnabled: entry.isScreenRecording || model.canAnnotateScreenshot(entry)
            ) { model.saveImageToFile(entry) })
        }
        var organizationActions: [CardContextAction] = []
        let allFavorites = selection.allSatisfy(\.isFavorite)
        let favoriteShortcut = contextShortcut(.toggleFavorite)
        if allFavorites {
            organizationActions.append(CardContextAction(
                isMultiple ? "取消所选收藏" : "取消收藏", shortcut: favoriteShortcut
            ) { model.removeFavorites(selection) })
        }
        let ids = selection.map(\.id)
        let addShortcut = allFavorites ? nil : favoriteShortcut
        let createCategory = CardContextAction("新建分类并收藏…",
            shortcut: model.favoriteCategories.isEmpty ? addShortcut : nil) {
            presentFavoriteCategoryEditor(.create(entryIDs: ids))
        }
        if model.favoriteCategories.isEmpty {
            organizationActions.append(createCategory)
        } else {
            let destinations = model.favoriteCategories.map { category in
                CardContextAction("\(category.icon.presentation.emoji)  \(category.name)") {
                    model.moveFavorites(ids, to: category.id)
                }
            } + [createCategory]
            organizationActions.append(CardContextAction("收藏到", shortcut: addShortcut, children: destinations))
        }
        if selection.contains(where: { $0.shelfPinOrder == nil }) {
            let title = isMultiple ? "将所选卡片钉在面板" : isVertical ? "钉在面板顶部" : "钉在面板左侧"
            organizationActions.append(CardContextAction(title, shortcut: contextShortcut(.toggleShelfPin)) {
                setShelfPinned(selection, pinned: true)
            })
        }
        if selection.contains(where: { $0.shelfPinOrder != nil }) {
            organizationActions.append(CardContextAction(
                isMultiple ? "取消所选卡片的面板钉住" : "取消面板钉住",
                shortcut: selection.allSatisfy({ $0.shelfPinOrder != nil }) ? contextShortcut(.toggleShelfPin) : nil
            ) {
                setShelfPinned(selection, pinned: false)
            })
        }
        if canGroup {
            organizationActions.append(CardContextAction(
                "将所选成组", shortcut: contextShortcut(.groupSelection)
            ) {
                if detailID != nil { closeDetail() }
                if let groupID = model.groupSelection(selection) {
                    selectedID = groupID
                    selectedCardKey = "root-\(groupID)"
                    selectedIDs = [groupID]
                }
            })
        }
        if !groups.isEmpty {
            organizationActions.append(CardContextAction(
                groups.count == 1 ? "取消成组" : "取消所选分组",
                shortcut: contextShortcut(.ungroupSelection)
            ) {
                if detailID != nil { closeDetail() }
                model.ungroupSelection(selection)
                expandedGroups.subtract(groups.map(\.id))
            })
        }
        if !isMultiple && model.canRecognizeImage(entry) {
            organizationActions.append(CardContextAction(
                "识别图片文字", shortcut: contextShortcut(.recognizeImageText)
            ) {
                recognizeImageText(entry)
            })
        }
        if !isMultiple && model.canAnnotateScreenshot(entry) {
            organizationActions.append(CardContextAction("标注图片…", shortcut: contextShortcut(.annotateImage)) {
                model.annotateScreenshot(entry)
            })
        }
        if !isMultiple && (entry.kind == .text || entry.kind == .link) {
            if entry.isEditableText {
                organizationActions.append(CardContextAction("编辑…", shortcut: contextShortcut(.annotateImage)) {
                    model.editText(entry)
                })
            }
            organizationActions.append(CardContextAction(
                entry.kind == .link ? "清理链接…" : "文本工具…"
            ) {
                openDetail(entry, initiallyShowsTools: true)
            })
        }
        if !isMultiple && (entry.kind == .text || model.canRecognizeImage(entry)) {
            organizationActions.append(CardContextAction("翻译", shortcut: contextShortcut(.translateScreenshot)) {
                translate(entry)
            })
        }
        if entry.isImagePreviewable || model.isPinnedImage(entry) {
            let isPinned = model.isPinnedImage(entry)
            organizationActions.append(CardContextAction(
                isMultiple
                    ? (isPinned ? "取消当前图片的桌面钉住" : "将当前图片钉在桌面")
                    : (isPinned ? "取消桌面钉住" : "钉在桌面"),
                shortcut: contextShortcut(.togglePinImage),
                isEnabled: isPinned || model.canPinImage(entry)
            ) {
                if model.togglePinImage(entry), detailID == entry.id { closeDetail() }
            })
        }
        if !isMultiple && (entry.kind != .group ||
            !displayedGroupMembers(of: entry, excluding: filteredCards.pinnedIDs).isEmpty) {
            organizationActions.append(CardContextAction(
                entry.kind == .group
                    ? (expandedGroups.contains(entry.id) ? "收起分组" : "展开分组")
                    : "预览",
                shortcut: contextShortcut(.toggleDetail)
            ) {
                if entry.kind == .group { toggleGroup(entry) }
                else { openDetail(entry) }
            })
        }
        var otherActions: [CardContextAction] = []
        if !isMultiple && (entry.isImagePreviewable || entry.kind == .unavailableImage) {
            otherActions.append(CardContextAction("截图分类", children:
                ClipboardScreenshotOrigin.allCases.map { origin in
                    CardContextAction(origin.label + (entry.resolvedScreenshotOrigin == origin ? "（当前）" : "")) {
                        model.setScreenshotOrigin(origin, for: entry)
                    }
                }
            ))
        }
        if !isMultiple && entry.kind != .group &&
            (entry.sourceAppBundleID != nil || entry.sourceAppName != nil) {
            otherActions.append(CardContextAction("打开来源应用") {
                model.openSourceApplication(for: entry)
            })
        }
        if entry.kind != .group {
            otherActions.append(CardContextAction(
                isMultiple ? "删除当前记录…" : "删除记录…",
                shortcut: contextShortcut(.deleteEntry)
            ) {
                model.confirmDelete(entry)
            })
        }
        return [contentActions, organizationActions, otherActions]
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

    private func openDetail(_ entry: ClipboardEntry, initiallyShowsOCR: Bool = false,
                            initiallyShowsTools: Bool = false) {
        model.clearPreviewAction()
        detailID = entry.id
        detailCardKey = selectedCardKey ?? visibleEntries.first(where: { $0.entry.id == entry.id })?.id
        detailShowsOCR = initiallyShowsOCR
        detailShowsTools = initiallyShowsTools
        showsLayoutOptions = false
        if !presentDetail(entry, cardFrame: detailCardKey.flatMap { cardFrameTracker.frames[$0] }) {
            // A card still scrolling into view has no stable position yet.
            // Wait for its measured frame instead of showing a centered preview.
            if cardFrameTracker.presentedKey != nil { model.closeDetailPreview() }
            cardFrameTracker.presentedKey = nil
        }
        focusedTarget = .detail
    }

    private func recognizeImageText(_ entry: ClipboardEntry, cardKey: String? = nil) {
        guard model.canRecognizeImage(entry) else { return }
        if let cardKey {
            preservePointerSelectionPosition()
            hasNavigatedHistory = true
            selectedID = entry.id
            selectedCardKey = cardKey
            selectedIDs = [entry.id]
        }
        if detailID != entry.id { openDetail(entry, initiallyShowsOCR: true) }
        model.requestPreviewAction(.recognizeImageText, for: entry)
        if entry.ocrText == nil && !model.imageOCRInProgress.contains(entry.id) {
            model.recognizeImageText(entry)
        }
    }

    private func translate(_ entry: ClipboardEntry) {
        guard entry.kind == .text || model.canRecognizeImage(entry) else { return }
        if detailID != entry.id { openDetail(entry, initiallyShowsOCR: entry.isImagePreviewable) }
        model.requestPreviewAction(.translateScreenshot, for: entry)
    }

    @discardableResult
    private func presentDetail(_ entry: ClipboardEntry, cardFrame: CGRect?) -> Bool {
        let shown = model.showDetailPreview(
            entry,
            cardFrame: cardFrame,
            initiallyShowsOCR: detailShowsOCR,
            initiallyShowsTools: detailShowsTools,
            onKeyDown: handlePanelKeyDown,
            onClose: closeDetail
        )
        if shown { cardFrameTracker.presentedKey = detailCardKey }
        return shown
    }

    private func closeDetail() {
        model.clearPreviewAction()
        cardFrameTracker.cancel()
        model.closeDetailPreview()
        cardFrameTracker.presentedKey = nil
        detailID = nil
        detailCardKey = nil
        detailShowsOCR = false
        detailShowsTools = false
        if selectedID != nil {
            focusedTarget = .history
        }
    }

    private var selectedEditShortcut: AppShortcut? {
        guard !showsHeaderPopover, !model.isDraggingCard,
              focusedTarget == .history || focusedTarget == .detail,
              let entry = detailEntry ?? selectedEntry,
              entry.isEditableText || model.canAnnotateScreenshot(entry) else { return nil }
        return model.shortcut(for: .annotateImage)
    }

    private func handlePanelKeyDown(_ event: NSEvent) -> Bool {
#if DEBUG
        if model.shortcut(for: .annotateImage).matches(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            ImageGestureTrace.record("shelf edit received drag=\(model.isDraggingCard) popover=\(showsHeaderPopover) search=\(focusedTarget == .search) selected=\(selectedEntry != nil) preview=\(detailEntry != nil)")
        }
#endif
        if model.isDraggingCard {
            // Cancel an in-shelf drag here. AppKit handles Esc after handoff.
            return event.keyCode == UInt16(kVK_Escape) && model.cancelLocalCardDrag()
        }
        if showsHeaderPopover {
            if event.keyCode == UInt16(kVK_Escape) {
                showsCalendar = false
                favoriteCategoryEditor = nil
                return true
            }
            return false
        }
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if detailEntry?.isImagePreviewable == true,
           event.keyCode == UInt16(kVK_ANSI_C), held == .command,
           let editor = event.window?.firstResponder as? NSTextView {
            let selection = editor.selectedRange()
            let content = editor.string as NSString
            if selection.length > 0, NSMaxRange(selection) <= content.length {
                model.copySelectedPreviewText(content.substring(with: selection))
                return true
            }
        }
        guard let action = ShelfKeyboardAction.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            searchFocused: focusedTarget == .search,
            searchIsEmpty: searchText.isEmpty,
            textEditingAvailable: (detailEntry ?? (selectedIDs.count <= 1 ? selectedEntry : nil))?.isEditableText == true,
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
        case .copyPlainText:
            guard let selectedEntry else { return true }
            if selectedIDs.count > 1 { model.copySelection(selectedEntriesInOrder, plainText: true) }
            else { model.copyPlainText(selectedEntry) }
        case .groupSelection:
            let selection = selectedIDs.count > 1 ? selectedEntriesInOrder : []
            if let groupID = model.groupSelection(selection) {
                if detailID != nil { closeDetail() }
                selectedID = groupID
                selectedCardKey = "root-\(groupID)"
                selectedIDs = [groupID]
            }
        case .ungroupSelection:
            let selection = selectedIDs.count > 1 ? selectedEntriesInOrder : selectedEntry.map { [$0] } ?? []
            if detailID != nil { closeDetail() }
            model.ungroupSelection(selection)
            expandedGroups.subtract(selection.filter { $0.kind == .group }.map(\.id))
        case .togglePinImage:
            guard let entry = detailEntry ?? selectedEntry else { return true }
            if model.togglePinImage(entry), detailID == entry.id { closeDetail() }
        case .toggleShelfPin:
            guard !event.isARepeat else { return true }
            let selection = detailEntry.map { [$0] } ?? selectedEntriesInOrder
            guard !selection.isEmpty else { return true }
            setShelfPinned(selection, pinned: selection.contains { $0.shelfPinOrder == nil })
        case .recognizeImageText:
            guard let entry = detailEntry ?? selectedEntry else { return true }
            recognizeImageText(entry)
        case .annotateImage:
            guard let entry = detailEntry ?? selectedEntry, model.canAnnotateScreenshot(entry) else { return true }
#if DEBUG
            ImageGestureTrace.record("shelf edit annotate dispatch")
#endif
            model.annotateScreenshot(entry)
        case .editText:
            guard !event.isARepeat, let entry = detailEntry ?? selectedEntry,
                  entry.isEditableText else { return true }
            model.editText(entry)
        case .saveImageToFile:
            guard let entry = detailEntry ?? (selectedIDs.count <= 1 ? selectedEntry : nil),
                  entry.isImagePreviewable || entry.isScreenRecording else { return false }
            if !event.isARepeat { model.saveImageToFile(entry) }
        case .toggleFavorite:
            guard !event.isARepeat else { return true }
            let selection = detailEntry.map { [$0] } ?? selectedEntriesInOrder
            let newIDs = selection.filter { !$0.isFavorite }.map(\.id)
            if newIDs.isEmpty {
                model.removeFavorites(selection)
            } else if case .favoriteCategory(let id) = navigation.tab {
                model.moveFavorites(newIDs, to: id)
            } else if model.favoriteCategories.isEmpty {
                presentFavoriteCategoryEditor(.create(entryIDs: newIDs))
            } else {
                presentFavoriteCategoryEditor(.chooseDestination(entryIDs: newIDs))
            }
        case .translate:
            guard let entry = detailEntry ?? selectedEntry else { return true }
            translate(entry)
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
            } else if selectedDate != nil {
                navigation.filters.date = nil
            } else if !searchText.isEmpty {
                navigation.filters.query = ""
            } else if showsFavorites {
                selectTab(.history)
            } else if selectedFilter != .all {
                navigation.filters.type = .all
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
        revealsSelection = true
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

private extension ClipboardFavoriteCategory.Tint {
    var displayColor: Color {
        let color: NSColor = switch self {
        case .blue: .systemBlue
        case .teal: .systemTeal
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .pink: .systemPink
        case .purple: .systemPurple
        case .gray: .systemGray
        }
        return Color(nsColor: color)
    }

}

private struct ShelfFavoriteCategoryIcon: View {
    let icon: ClipboardFavoriteCategory.Icon
    let size: CGFloat

    var body: some View {
        Text(verbatim: icon.presentation.emoji)
            .font(.system(size: size))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

private struct ShelfFavoriteCategoryEditor: View {
    private static let iconColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    let category: ClipboardFavoriteCategory?
    let entryCount: Int
    let onCancel: () -> Void
    let onSave: (String, ClipboardFavoriteCategory.Tint, ClipboardFavoriteCategory.Icon) throws -> Void
    @State private var name: String
    @State private var icon: ClipboardFavoriteCategory.Icon
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(category: ClipboardFavoriteCategory?, entryCount: Int, onCancel: @escaping () -> Void,
         onSave: @escaping (String, ClipboardFavoriteCategory.Tint, ClipboardFavoriteCategory.Icon) throws -> Void) {
        self.category = category
        self.entryCount = entryCount
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _icon = State(initialValue: category?.icon ?? .star)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category == nil ? "新建收藏分类" : "编辑收藏分类")
                .font(.headline)
            if entryCount > 0 {
                Text("将 \(entryCount) 张卡片收藏到新分类")
                    .foregroundStyle(.secondary)
            }
            TextField("分类名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onChange(of: name) { _, _ in errorMessage = nil }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("图标")
                    Spacer()
                    Text(icon.presentation.label)
                }
                .foregroundStyle(.secondary)
                LazyVGrid(columns: Self.iconColumns, alignment: .leading, spacing: 4) {
                    ForEach(ClipboardFavoriteCategory.Icon.allCases, id: \.self) { symbol in
                        choice(symbol.presentation.label, selected: icon == symbol, action: { icon = symbol }) {
                            ShelfFavoriteCategoryIcon(icon: symbol, size: 16)
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(entryCount > 0 ? "创建并收藏" : category == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 288)
        .defaultFocus($nameFocused, true)
    }

    private func choice<Content: View>(_ label: String, selected: Bool, action: @escaping () -> Void,
                                      @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(width: 28, height: 28)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        do { try onSave(name, category?.tint ?? .blue, icon) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// A small date browser, with results kept in the shelf's existing card list.
private struct ClipboardHistoryCalendar: View {
    let counts: [Date: Int]
    let selectedDate: Date?
    let onSelect: (Date) -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedDate = Date()
    private let calendar = Calendar.current

    private var month: ClipboardCalendarMonth { ClipboardCalendarMonth(containing: displayedDate, calendar: calendar) }
    private var years: [Int] {
        let current = calendar.component(.year, from: Date())
        let displayed = calendar.component(.year, from: displayedDate)
        let available = counts.keys.map { calendar.component(.year, from: $0) }
        let first = min(available.min() ?? current, min(current - 10, displayed))
        let last = max(available.max() ?? current, max(current + 1, displayed))
        return Array(first...last)
    }
    private var weekdays: [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["日", "一", "二", "三", "四", "五", "六"]
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(years.reversed(), id: \.self) { year in
                        Menu("\(String(year))年") {
                            ForEach(1...12, id: \.self) { value in
                                Button("\(value)月") {
                                    if let date = calendar.date(from: DateComponents(year: year, month: value, day: 1)) {
                                        displayedDate = date
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(month.start.formatted(.dateTime.year().month(.wide)))
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("选择年月")
                Spacer(minLength: 0)
                Button { displayedDate = month.shifted(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 26)
                }.help("上个月")
                Button { displayedDate = month.shifted(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 26, height: 26)
                }.help("下个月")
            }
            HStack(spacing: 3) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(month.cells.enumerated()), id: \.offset) { _, date in
                    if let date { dayButton(date) }
                    else { Color.clear.frame(height: 41).accessibilityHidden(true) }
                }
            }
            Divider()
            HStack {
                Text("仅显示仍保留的内容")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("今天") { onSelect(calendar.startOfDay(for: Date())) }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 312)
        .onAppear { displayedDate = selectedDate ?? Date() }
        .onExitCommand(perform: onClose)
        .background {
            ShelfKeyMonitor { event in
                guard event.keyCode == UInt16(kVK_Escape) else { return false }
                onClose()
                return true
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let count = counts[calendar.startOfDay(for: date), default: 0]
        let selected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let today = calendar.isDateInToday(date)
        let blue = Color(nsColor: .systemBlue)
        let fill = today ? blue : selected ? blue.opacity(0.12)
            : count > 0 ? Color.primary.opacity(0.045) : .clear
        let foreground = today ? Color.white
            : (count > 0 || selected) ? Color.primary : Color.secondary.opacity(0.55)
        let darkBadge = colorScheme == .dark && !today
        let countColor = darkBadge ? Color(red: 0.57, green: 0.76, blue: 1)
            : Color(red: 0, green: 0.29, blue: 0.67)
        let countBackground = today ? Color.white : darkBadge
            ? Color(red: 0.10, green: 0.17, blue: 0.27)
            : Color(red: 0.93, green: 0.96, blue: 1)
        return Button { onSelect(date) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 13, weight: today ? .bold : .semibold))
                Text(count == 0 ? "" : "\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(countColor)
                    .padding(.horizontal, count >= 1_000 ? 2 : 5)
                    .padding(.vertical, 1)
                    .background(count > 0 ? countBackground : .clear, in: Capsule())
            }
            .frame(maxWidth: .infinity).frame(height: 41)
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected && !today ? blue.opacity(0.7) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .help("\(date.formatted(date: .complete, time: .omitted)) · \(count) 项")
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，\(count) 项")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
