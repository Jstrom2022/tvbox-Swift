import Foundation
import SwiftUI
import Combine

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published private(set) var categoryVideos: [Movie.Video] = []
    /// 按分类记忆筛选选择；换源时清空，避免沿用其他源的参数。
    @Published private(set) var filterSelections: [String: [String: String]] = [:]
    private var rawCategoryVideos: [Movie.Video] = []
    private static let maxAutoFillPages = 5
    private static let minFilteredCount = 18
    /// 推荐分类加载中。
    @Published private(set) var isLoadingHome = false
    /// 当前分类首屏加载中。
    @Published private(set) var isLoadingCategory = false
    /// 当前分类分页加载中。
    @Published private(set) var isLoadingMore = false
    /// 当前分类的分页页码。
    @Published private(set) var currentPage = 1
    /// 是否还有下一页。
    @Published private(set) var hasMore = true
    /// 推荐分类的错误提示。
    @Published var homeErrorMessage: String?
    /// 当前分类首屏的错误提示。
    @Published var categoryErrorMessage: String?
    /// 当前分类分页的错误提示。
    @Published var loadMoreErrorMessage: String?
    /// 是否已经完成过一次推荐加载（用于区分“尚未加载”与“确实为空”）。
    @Published private(set) var hasLoadedHome = false

    /// 页面整体加载状态（推荐或当前分类任一在加载）。
    var isLoading: Bool { isLoadingHome || isLoadingCategory || isLoadingMore }

    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    private var configChangeCancellable: AnyCancellable?

    /// 首页与分类任务各自持有令牌，互不干扰：切换选择时取消对应旧任务。
    private var homeTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var homeGeneration = 0
    private var categoryGeneration = 0
    /// 当前推荐数据所属的来源 key 与配置版本，用于判断是否可以跳过重复加载。
    private var loadedSourceKey: String?
    private var loadedConfigVersion = -1
    /// 最近一次加载所针对的来源与配置版本，用于合并重复的刷新触发。
    private var requestedSourceKey: String?
    private var requestedConfigVersion = -1
    /// 当前分类已收录的视频身份，用于分页去重。
    private var categoryVideoIds: Set<Movie.Video.Identity> = []

    init() {
        setupNetworkRestoredAutoRetry()
        setupConfigChangeReload()
    }

    // MARK: - 生命周期

    /// 页面出现时按需加载：来源或配置发生变化、或尚无数据时重新加载。
    func loadIfNeeded() async {
        let sourceKey = ApiConfig.shared.homeSourceBean?.key
        let version = ApiConfig.shared.configVersion
        if loadedSourceKey == sourceKey, loadedConfigVersion == version, !sorts.isEmpty {
            return
        }
        // 同一来源与配置的加载已经在进行中，等待它完成即可。
        if let homeTask, requestedSourceKey == sourceKey, requestedConfigVersion == version {
            await homeTask.value
            return
        }
        await reload(clearContent: loadedSourceKey != nil && loadedSourceKey != sourceKey)
    }

    /// 刷新（下拉刷新、重试）。
    func refresh() async {
        await reload(clearContent: false)
    }

    /// 切换主页数据源：立即清空旧源内容并加载新源，旧源的迟到结果会被丢弃。
    func switchSource(_ source: SourceBean) async {
        guard ApiConfig.shared.homeSourceBean?.key != source.key else { return }
        ApiConfig.shared.setHomeSource(source)
        await reload(clearContent: true)
    }

    /// 全量重新加载分类与当前分类内容。
    private func reload(clearContent: Bool) async {
        homeTask?.cancel()
        categoryTask?.cancel()
        homeGeneration &+= 1
        categoryGeneration &+= 1
        homeTask = nil
        categoryTask = nil

        isLoadingHome = false
        isLoadingCategory = false
        isLoadingMore = false
        homeErrorMessage = nil
        categoryErrorMessage = nil
        loadMoreErrorMessage = nil
        if clearContent {
            // 换源或配置变化：旧源的分类、选中项与内容都不再适用。
            filterSelections = [:]
            rawCategoryVideos = []
            sorts = []
            selectedSort = nil
            homeVideos = []
            categoryVideos = []
            categoryVideoIds = []
            hasLoadedHome = false
        }
        currentPage = 1
        hasMore = true
        requestedSourceKey = ApiConfig.shared.homeSourceBean?.key
        requestedConfigVersion = ApiConfig.shared.configVersion

        let homeGeneration = self.homeGeneration
        homeTask = Task { [weak self] in
            await self?.loadHome(generation: homeGeneration)
        }
        await homeTask?.value
    }

    // MARK: - 推荐分类

    private func loadHome(generation: Int) async {
        guard let source = ApiConfig.shared.homeSourceBean else {
            homeErrorMessage = "尚未配置可用的数据源"
            hasLoadedHome = true
            isLoadingHome = false
            return
        }

        let sourceKey = source.key
        let version = ApiConfig.shared.configVersion
        isLoadingHome = true

        do {
            let result = try await sourceService.getSort(sourceBean: source)
            guard isHomeResultCurrent(generation: generation, sourceKey: sourceKey) else { return }

            var allSorts = [MovieSort.SortData.home(), MovieSort.SortData.douban()]
            allSorts.append(contentsOf: result.sorts)
            self.sorts = allSorts
            self.homeVideos = Self.deduplicated(result.homeVideos)
            self.homeErrorMessage = nil
            self.hasLoadedHome = true
            self.lastLoadFailedDueToNetwork = false
            self.loadedSourceKey = sourceKey
            self.loadedConfigVersion = version

            applySelectionAfterReload()
        } catch {
            guard isHomeResultCurrent(generation: generation, sourceKey: sourceKey) else { return }
            self.homeErrorMessage = error.localizedDescription
            self.hasLoadedHome = true
            if loadedSourceKey != sourceKey {
                // 换了数据源却加载失败时，旧源的分类已不再适用。
                self.sorts = []
                self.homeVideos = []
                self.rawCategoryVideos = []
                self.categoryVideos = []
                self.categoryVideoIds = []
                self.selectedSort = nil
            }
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }

        guard isHomeResultCurrent(generation: generation, sourceKey: sourceKey) else { return }
        isLoadingHome = false
        homeTask = nil
    }

    private func isHomeResultCurrent(generation: Int, sourceKey: String) -> Bool {
        guard !Task.isCancelled, generation == homeGeneration else { return false }
        return ApiConfig.shared.homeSourceBean?.key == sourceKey
    }

    /// 推荐加载完成后校正当前选中的分类：优先保留原分类，分类已不存在时回退到第一个分类，
    /// 尚未选择时选中“推荐”。
    private func applySelectionAfterReload() {
        if let previousId = selectedSort?.id {
            if let matched = sorts.first(where: { $0.id == previousId }) {
                selectSort(matched)
                return
            }
            if let firstCategory = sorts.first(where: { !$0.isHome && !$0.isDouban }) {
                selectSort(firstCategory)
                return
            }
        }
        if let home = sorts.first {
            selectSort(home)
        }
    }

    // MARK: - 筛选

    /// 分类可用的筛选条件：
    /// - 豆瓣分类：类型 / 排序 / 年份 / 地区；
    /// - 普通分类：源自带筛选（服务端生效）+ 年份兜底（源无 year 时）+ 本地排序。
    func filters(for sort: MovieSort.SortData) -> [MovieSort.SortFilter] {
        if sort.isHome { return [] }
        if sort.isDouban { return MovieSort.SortFilter.doubanFilters() }

        var result = sort.filters
        if !result.contains(where: { $0.key == "year" }) {
            result.append(.localYearFilter())
        }
        result.append(.localSortFilter())
        return result
    }

    /// 当前选中值；未选择时取该筛选项的第一个值（通常为"全部"/默认）。
    func selectedValue(for filter: MovieSort.SortFilter, in sort: MovieSort.SortData) -> String {
        filterSelections[sort.id]?[filter.key] ?? filter.values.first?.v ?? ""
    }

    /// 切换某个筛选值。纯本地条件只重排已加载数据，其余条件重新请求第一页。
    func selectFilter(_ filter: MovieSort.SortFilter, value: String) {
        guard let sort = selectedSort else { return }
        guard selectedValue(for: filter, in: sort) != value else { return }
        filterSelections[sort.id, default: [:]][filter.key] = value

        if filter.isLocal && !sort.isDouban {
            applyLocalFilters()
            fillFilteredResultsIfNeeded(sort: sort)
        } else {
            selectSort(sort)
        }
    }

    /// 当前分类已生效的筛选值（含默认值），用于请求参数与本地处理。
    private func effectiveSelections(for sort: MovieSort.SortData) -> [String: String] {
        var result: [String: String] = [:]
        for filter in filters(for: sort) {
            result[filter.key] = selectedValue(for: filter, in: sort)
        }
        return result
    }

    /// 对已加载的原始列表应用本地年份筛选与排序。
    private func applyLocalFilters() {
        guard let sort = selectedSort, !sort.isDouban else {
            categoryVideos = rawCategoryVideos
            return
        }
        let selections = effectiveSelections(for: sort)
        var videos = rawCategoryVideos

        if let year = selections[MovieSort.SortFilter.localYearKey], !year.isEmpty {
            let oldestRecent = MovieSort.SortFilter.currentYear - MovieSort.SortFilter.recentYearSpan + 1
            videos = videos.filter { video in
                guard let videoYear = Self.parseYear(video.year) else { return false }
                if year == MovieSort.SortFilter.olderYearValue {
                    return videoYear < oldestRecent
                }
                return String(videoYear) == year
            }
        }

        switch selections[MovieSort.SortFilter.localSortKey] ?? "" {
        case "time":
            videos = Self.stableSorted(videos) { lhs, rhs in
                if lhs.last != rhs.last { return lhs.last > rhs.last }
                return (Self.parseYear(lhs.year) ?? 0) > (Self.parseYear(rhs.year) ?? 0)
            }
        case "hits":
            videos = Self.stableSorted(videos) { $0.hits > $1.hits }
        case "score":
            videos = Self.stableSorted(videos) { $0.score > $1.score }
        default:
            break
        }

        categoryVideos = videos
    }

    /// 本地年份筛选是否生效（生效时分页结果可能变稀疏，需要自动多拉几页）。
    private func isLocalYearFilterActive(for sort: MovieSort.SortData) -> Bool {
        guard !sort.isDouban else { return false }
        return !(effectiveSelections(for: sort)[MovieSort.SortFilter.localYearKey] ?? "").isEmpty
    }

    /// 从 "2024" / "2024-05-01" / "2024年" 等写法中提取四位年份。
    private static func parseYear(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix(4)
        guard digits.count == 4, let year = Int(digits), year > 1800 else { return nil }
        return year
    }

    /// 稳定排序：相同排序键时保持接口原始顺序。
    private static func stableSorted(_ videos: [Movie.Video], by areInIncreasingOrder: (Movie.Video, Movie.Video) -> Bool) -> [Movie.Video] {
        videos.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func fillFilteredResultsIfNeeded(sort: MovieSort.SortData) {
        guard selectedSort?.id == sort.id, isLocalYearFilterActive(for: sort), hasMore,
              categoryVideos.count < Self.minFilteredCount,
              !isLoadingCategory, !isLoadingMore, loadMoreErrorMessage == nil else { return }
        startCategoryLoad(page: currentPage + 1, sort: sort, sourceKey: ApiConfig.shared.homeSourceBean?.key)
    }

    // MARK: - 分类选择

    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        selectSort(sort, skipHomeReload: sort.id == "home")
    }

    private func selectSort(_ sort: MovieSort.SortData, skipHomeReload: Bool) {
        categoryTask?.cancel()
        categoryTask = nil
        categoryGeneration &+= 1

        selectedSort = sort
        categoryErrorMessage = nil
        loadMoreErrorMessage = nil
        isLoadingCategory = false
        isLoadingMore = false
        rawCategoryVideos = []
        categoryVideos = []
        categoryVideoIds = []
        currentPage = 1
        hasMore = true

        guard !skipHomeReload else { return }
        startCategoryLoad(page: 1, sort: sort, sourceKey: ApiConfig.shared.homeSourceBean?.key)
    }

    /// 启动分类加载任务，任务内部再次校验令牌后才提交结果。
    private func startCategoryLoad(page: Int, sort: MovieSort.SortData, sourceKey: String?) {
        guard let sourceKey, let source = ApiConfig.shared.homeSourceBean, source.key == sourceKey else {
            // 无法发起请求时给出明确结果，不能停留在“加载中”。
            if page <= 1 {
                categoryErrorMessage = "尚未配置可用的数据源"
            } else {
                loadMoreErrorMessage = "尚未配置可用的数据源"
            }
            return
        }

        let generation = categoryGeneration
        let selections = effectiveSelections(for: sort)
        let token = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCategoryResultCurrent(generation: generation, sortId: sort.id, sourceKey: sourceKey) {
                    self.isLoadingCategory = false
                    self.isLoadingMore = false
                    self.categoryTask = nil
                }
            }
            var nextPage = page
            var extraPages = 0
            let displayedBefore = self.categoryVideos.count
            while true {
                let result = await self.fetchCategoryPage(source: source, sort: sort, page: nextPage, selections: selections)
                guard self.isCategoryResultCurrent(generation: generation, sortId: sort.id, sourceKey: sourceKey) else { return }
                await self.commitCategoryResult(result, page: nextPage, sort: sort, sourceKey: sourceKey, generation: generation)
                guard case .success = result, self.hasMore, self.isLocalYearFilterActive(for: sort),
                      extraPages < Self.maxAutoFillPages else { return }
                guard self.categoryVideos.count < Self.minFilteredCount || self.categoryVideos.count == displayedBefore else { return }
                nextPage += 1
                extraPages += 1
            }
        }
        categoryTask?.cancel()
        categoryTask = token

        if page == 1 {
            isLoadingCategory = true
        } else {
            isLoadingMore = true
        }
    }

    private func fetchCategoryPage(
        source: SourceBean,
        sort: MovieSort.SortData,
        page: Int,
        selections: [String: String]
    ) async -> Result<SourceService.VideoPage, Error> {
        do {
            if sort.isDouban {
                typealias Key = MovieSort.SortFilter
                let videos = try await sourceService.getDoubanList(
                    kind: selections[Key.doubanKindKey] ?? "movie",
                    sort: selections[Key.doubanSortKey] ?? "T",
                    tags: [selections[Key.doubanYearKey] ?? "", selections[Key.doubanAreaKey] ?? ""],
                    page: page
                )
                return .success(SourceService.VideoPage(videos: videos, page: page, pageCount: nil, total: nil, limit: nil))
            }
            let result = try await sourceService.getList(sourceBean: source, sortData: sort, page: page, filters: selections)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func commitCategoryResult(
        _ result: Result<SourceService.VideoPage, Error>,
        page: Int,
        sort: MovieSort.SortData,
        sourceKey: String,
        generation: Int
    ) async {
        guard isCategoryResultCurrent(generation: generation, sortId: sort.id, sourceKey: sourceKey) else { return }

        switch result {
        case .success(let videoPage):
            if page <= 1 {
                categoryVideoIds = []
                rawCategoryVideos = []
                categoryVideos = []
            }
            // 按来源 + 视频 ID 去重，保持服务端顺序；重复的末页不会带来新条目。
            let uniqueVideos = videoPage.videos.filter { categoryVideoIds.insert($0.id).inserted }
            rawCategoryVideos.append(contentsOf: uniqueVideos)
            applyLocalFilters()
            hasMore = Self.hasMorePages(after: videoPage, newItemCount: uniqueVideos.count)
            currentPage = page
            categoryErrorMessage = nil
            loadMoreErrorMessage = nil
            lastLoadFailedDueToNetwork = false
        case .failure(let error):
            if page <= 1 {
                categoryErrorMessage = error.localizedDescription
                hasMore = true
            } else {
                loadMoreErrorMessage = error.localizedDescription
            }
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }

    }

    private func isCategoryResultCurrent(generation: Int, sortId: String, sourceKey: String) -> Bool {
        guard !Task.isCancelled, generation == categoryGeneration else { return false }
        guard selectedSort?.id == sortId else { return false }
        return ApiConfig.shared.homeSourceBean?.key == sourceKey
    }

    /// 判断服务端是否还有下一页：优先用分页元数据，其次用“本页是否带来新内容”兜底，
    /// 避免服务端在末页之后仍返回最后一页内容时无限分页。
    nonisolated static func hasMorePages(after page: SourceService.VideoPage, newItemCount: Int) -> Bool {
        guard newItemCount > 0 else { return false }
        if let pageCount = page.pageCount, pageCount > 0 {
            return page.page < pageCount
        }
        if let total = page.total, let limit = page.limit, total > 0, limit > 0 {
            return page.page * limit < total
        }
        if let limit = page.limit, limit > 0, page.videos.count < limit {
            return false
        }
        return true
    }

    // MARK: - 分页

    /// 加载下一页
    func loadMore() async {
        guard selectedSort?.id != "home" else { return }
        guard let sort = selectedSort, hasMore, loadMoreErrorMessage == nil else { return }
        guard !isLoadingCategory, !isLoadingMore else { return }
        startCategoryLoad(page: currentPage + 1, sort: sort, sourceKey: ApiConfig.shared.homeSourceBean?.key)
    }

    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard categoryVideos.last?.id == currentItem.id else { return }
        await loadMore()
    }

    /// 分页失败后重试当前页。
    func retryLoadMore() async {
        loadMoreErrorMessage = nil
        await loadMore()
    }

    /// 分类首屏失败后重试。
    func retryCategory() async {
        categoryErrorMessage = nil
        guard let sort = selectedSort, sort.id != "home" else { return }
        startCategoryLoad(page: 1, sort: sort, sourceKey: ApiConfig.shared.homeSourceBean?.key)
    }

    // MARK: - 网络恢复与配置变更

    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }

    /// 配置重新加载或主页源变化（含设置页切换数据源）时自动刷新，避免页面停留在旧源的数据上。
    /// 两个信号在一次配置加载中会先后到达，合并后只刷新一次。
    private func setupConfigChangeReload() {
        configChangeCancellable = Publishers.CombineLatest(
            ApiConfig.shared.$configVersion,
            ApiConfig.shared.$homeSourceBean.map { $0?.key }
        )
        .dropFirst()
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .sink { [weak self] version, sourceKey in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 已经在为同一来源与配置加载（如首页菜单切源时已主动刷新）就不再重复。
                guard version != self.requestedConfigVersion || sourceKey != self.requestedSourceKey else { return }
                await self.reload(clearContent: true)
            }
        }
    }

    /// 按业务身份去重并保持原有顺序。
    private static func deduplicated(_ videos: [Movie.Video]) -> [Movie.Video] {
        var seen: Set<Movie.Video.Identity> = []
        return videos.filter { seen.insert($0.id).inserted }
    }
}
