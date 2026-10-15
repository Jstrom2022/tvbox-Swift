import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var appState: AppState
    @ObservedObject private var subscriptionStore = VodSubscriptionStore.shared
    @State private var categoryScrollAnchorId: String?
    /// 筛选栏是否展开（跨启动记忆）。
    @AppStorage("home_filter_expanded") private var isFilterExpanded = true
    
    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部栏
                headerBar
                
                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }

                // 筛选栏（年份 / 排序 / 源自带筛选）
                if let sort = viewModel.selectedSort, !viewModel.filters(for: sort).isEmpty {
                    filterBar(for: sort)
                }

                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .overlay(alignment: .bottom) {
            if let error = subscriptionStore.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .padding(.bottom, 16)
                    .onTapGesture { subscriptionStore.lastError = nil }
            }
        }
    }
    
    // MARK: - 顶部栏（源选择器）
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
                // 多个点播订阅时可在这里直接切换（对应影视仓多仓）
                if subscriptionStore.subscriptions.count > 1 {
                    Section("点播订阅") {
                        ForEach(subscriptionStore.subscriptions) { subscription in
                            Button {
                                // 新配置加载完成后由 ViewModel 的配置订阅统一刷新
                                Task { await subscriptionStore.activate(subscription, appState: appState) }
                            } label: {
                                HStack {
                                    Text(subscription.name)
                                    if subscriptionStore.isActive(subscription) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                Section("站点") {
                    ForEach(ApiConfig.shared.sourceBeanList.filter { $0.isSupportedInSwift }) { source in
                        Button {
                            Task { await viewModel.switchSource(source) }
                        } label: {
                            HStack {
                                Text(source.name)
                                if source.key == ApiConfig.shared.homeSourceBean?.key {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(ApiConfig.shared.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - 分类标签栏
    
    private func categoryLabel(_ sort: MovieSort.SortData) -> some View {
        let isSelected = viewModel.selectedSort?.id == sort.id
        return VStack(spacing: 6) {
            Text(sort.name)
                .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))

            // 底部指示条
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.orange)
                .frame(width: 20, height: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    #if os(macOS)
    /// macOS：分类较多时自动换行，鼠标不便横向滚动。
    private var categoryTabBar: some View {
        FlowLayout(spacing: 0) {
            ForEach(viewModel.sorts) { sort in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.selectSort(sort)
                    }
                } label: {
                    categoryLabel(sort)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
    #else
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            categoryLabel(sort)
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                guard let newId else { return }
                categoryScrollAnchorId = newId
                scrollCategoryBar(to: newId, proxy: proxy)
            }
        }
        .padding(.bottom, 4)
    }
    #endif
    
    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        
        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }
        
        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }
        
        categoryScrollAnchorId = viewModel.sorts.first?.id
    }
    
    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 筛选栏

    private func filterBar(for sort: MovieSort.SortData) -> some View {
        let filters = viewModel.filters(for: sort)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilterExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.orange)
                    Text(filterSummary(filters, sort: sort))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isFilterExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.white.opacity(0.5))
                }
                .font(.system(size: 12, weight: .medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)

            if isFilterExpanded {
                ForEach(filters, id: \.key) { filter in
                    filterRow(filter, sort: sort)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func filterRow(_ filter: MovieSort.SortFilter, sort: MovieSort.SortData) -> some View {
        let selected = viewModel.selectedValue(for: filter, in: sort)
        #if os(macOS)
        // macOS：标题固定在左侧，选项超出宽度自动换行
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            filterTitle(filter)
            FlowLayout(spacing: 6) {
                filterChips(filter, selected: selected)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterTitle(filter)
                filterChips(filter, selected: selected)
            }
            .padding(.horizontal, 20)
        }
        #endif
    }

    private func filterTitle(_ filter: MovieSort.SortFilter) -> some View {
        Text(filter.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
            .padding(.trailing, 4)
            .padding(.vertical, 5)
    }

    @ViewBuilder
    private func filterChips(_ filter: MovieSort.SortFilter, selected: String) -> some View {
        ForEach(filter.values, id: \.self) { value in
            let isSelected = value.v == selected
            Button {
                viewModel.selectFilter(filter, value: value.v)
            } label: {
                Text(value.n)
                    .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isSelected ? Color.orange.opacity(0.85) : Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    /// 折叠状态下的摘要，例如"2024 · 热门"；全部为默认值时显示"筛选"。
    private func filterSummary(_ filters: [MovieSort.SortFilter], sort: MovieSort.SortData) -> String {
        let parts = filters.compactMap { filter -> String? in
            let value = viewModel.selectedValue(for: filter, in: sort)
            // 豆瓣的类型/排序没有"全部"项，总是展示；其余仅展示非默认值。
            if value == filter.values.first?.v && !sort.isDouban { return nil }
            guard let name = filter.values.first(where: { $0.v == value })?.n, name != "全部" else { return nil }
            return name
        }
        return parts.isEmpty ? "筛选" : parts.joined(separator: " · ")
    }

    // MARK: - 内容区
    
    /// 是否正在展示“推荐”（未选中任何分类时也视为推荐）。
    private var isShowingHome: Bool {
        viewModel.selectedSort == nil || viewModel.selectedSort?.id == "home"
    }
    
    /// 内容区按当前选中的推荐/分类分别呈现加载、错误、空态与内容，互不遮蔽。
    private var contentArea: some View {
        Group {
            if isShowingHome {
                homeContent
            } else {
                categoryContent
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            // 豆瓣条目没有播放地址，按片名全源搜索后再进入详情。
            if video.sourceKey == SourceService.doubanSourceKey {
                DoubanSearchView(title: video.name)
            } else {
                DetailView(video: video)
            }
        }
    }
    @ViewBuilder
    private var homeContent: some View {
        if viewModel.homeVideos.isEmpty {
            if viewModel.isLoadingHome || !viewModel.hasLoadedHome {
                loadingState
            } else if let error = viewModel.homeErrorMessage {
                errorState(error) {
                    Task { await viewModel.refresh() }
                }
            } else {
                emptyState(message: "当前数据源没有推荐内容，可以切换到其他分类看看")
            }
        } else {
            videoGrid(viewModel.homeVideos, banner: viewModel.homeErrorMessage.map { "刷新失败：\($0)" }) {
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private var categoryContent: some View {
        if viewModel.categoryVideos.isEmpty {
            if let error = viewModel.categoryErrorMessage {
                errorState(error) {
                    Task { await viewModel.retryCategory() }
                }
            } else if viewModel.isLoadingCategory || viewModel.isLoadingMore {
                loadingState
            } else if let error = viewModel.loadMoreErrorMessage {
                errorState(error) { Task { await viewModel.retryLoadMore() } }
            } else if viewModel.hasMore {
                VStack(spacing: 12) {
                    Spacer()
                    Text("已加载内容中暂无符合筛选条件的影片")
                        .foregroundColor(.secondary)
                    Button("继续加载") { Task { await viewModel.loadMore() } }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                emptyState(message: "该分类暂无内容")
            }
        } else {
            videoGrid(viewModel.categoryVideos, banner: nil) {
                paginationFooter
            }
        }
    }
    
    /// 分页底部：加载中、失败重试或已到底。
    @ViewBuilder
    private var paginationFooter: some View {
        if let error = viewModel.loadMoreErrorMessage {
            VStack(spacing: 8) {
                Text("加载更多失败：\(error)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await viewModel.retryLoadMore() }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            .padding()
        } else if viewModel.isLoadingMore {
            ProgressView()
                .padding()
        } else if viewModel.hasMore {
            // 列表较短、最后一张卡片已在屏幕内时，靠这里继续触发分页。
            ProgressView()
                .padding()
                .onAppear {
                    Task { await viewModel.loadMore() }
                }
        } else {
            Text("没有更多了")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
    }
    
    private func videoGrid<Footer: View>(
        _ videos: [Movie.Video],
        banner: String?,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        ScrollView {
            if let banner {
                Text(banner)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(videos) { video in
                    NavigationLink(value: video) {
                        VodCardView(video: video)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .onAppear {
                        Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            footer()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
    
    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(.orange)
            Text("加载中...")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func errorState(_ error: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            // 如果是不支持的源类型，显示类型信息
            if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                Text("当前源类型: \(source.typeDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("刷新") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 豆瓣条目 → 全源搜索结果页（对应影视仓点击豆瓣海报后的搜索）。
struct DoubanSearchView: View {
    let title: String
    @StateObject private var viewModel = SearchViewModel()

    #if os(iOS)
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]
    #endif

    var body: some View {
        Group {
            if viewModel.isSearching {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView().tint(.orange)
                    Text("正在各源中搜索「\(title)」…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text(viewModel.errorMessage ?? "未找到相关内容")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("重新搜索") {
                        Task { await viewModel.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.results) { video in
                            NavigationLink(value: video) {
                                VodCardView(video: video)
                            }
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard viewModel.results.isEmpty, !viewModel.isSearching else { return }
            viewModel.keyword = title
            await viewModel.search()
        }
    }
    

}
