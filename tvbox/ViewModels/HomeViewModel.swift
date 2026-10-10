import Foundation
import SwiftUI
import Combine

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐""豆瓣"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（已按本地年份/排序处理，直接用于展示）。
    @Published private(set) var categoryVideos: [Movie.Video] = []
    /// 当前分类的筛选选择（key -> 取值），按分类分别记忆。
    @Published private(set) var filterSelections: [String: [String: String]] = [:]
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?

    /// 本地筛选生效时，单次加载最多连续追加的页数（避免筛选结果稀疏时请求过多）。
    private static let maxAutoFillPages = 5
    /// 本地年份筛选生效时，首屏至少凑够的条目数。
    private static let minFilteredCount = 18

    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    /// 接口返回的原始列表（未经本地筛选/排序）。
    private var rawCategoryVideos: [Movie.Video] = []
    /// 加载代次：切换分类/筛选时递增，用于丢弃过期请求结果。
    private var loadGeneration = 0
    /// 正在进行中的分页加载所属代次。
    private var inFlightGeneration: Int?
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?

    init() {
        setupNetworkRestoredAutoRetry()
    }

    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        errorMessage = nil

        do {
            let result = try await sourceService.getSort(sourceBean: source)

            // 插入本地"推荐""豆瓣"分类，保持 UI 与 Android 版本 / 影视仓习惯一致。
            var allSorts = [MovieSort.SortData.home(), MovieSort.SortData.douban()]
            allSorts.append(contentsOf: result.sorts)

            self.sorts = allSorts
            self.homeVideos = result.homeVideos
            lastLoadFailedDueToNetwork = false

            if selectedSort == nil {
                selectedSort = allSorts.first
            }
        } catch {
            errorMessage = error.localizedDescription
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }

        isLoading = false
    }

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
            Task { await fillFilteredResultsIfNeeded(sort: sort) }
        } else {
            reloadCurrentSort()
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

    // MARK: - 分类与分页

    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        reloadCurrentSort()
    }

    /// 清空当前分类数据并重新加载第一页。
    private func reloadCurrentSort() {
        loadGeneration += 1
        errorMessage = nil
        rawCategoryVideos = []
        categoryVideos = []
        currentPage = 1
        hasMore = true

        guard let sort = selectedSort, !sort.isHome else { return }
        Task {
            await loadPages(startingAt: 1, sort: sort)
        }
    }

    /// 加载分类视频列表。本地年份筛选生效时，若新增可展示条目不足会自动续拉后续页。
    private func loadPages(startingAt page: Int, sort: MovieSort.SortData) async {
        guard !sort.isHome else { return }
        let generation = loadGeneration
        // 同一代次内防重复并发加载，避免分页错序；切换分类/筛选后允许立即发起新请求，
        // 旧请求结束时也不会误清新请求的 loading 状态。
        guard inFlightGeneration != generation else { return }

        inFlightGeneration = generation
        isLoading = true
        defer {
            if inFlightGeneration == generation {
                inFlightGeneration = nil
                isLoading = false
            }
        }

        var nextPage = page
        var extraPages = 0
        let displayedBefore = categoryVideos.count

        while true {
            do {
                let videos = try await fetchPage(nextPage, sort: sort)
                // 分类或筛选切换过程中，丢弃旧请求结果
                guard generation == loadGeneration else { return }

                if nextPage == 1 {
                    rawCategoryVideos = videos
                } else {
                    rawCategoryVideos.append(contentsOf: videos)
                }
                applyLocalFilters()
                // 以"返回非空"作为是否继续分页的轻量判断。
                currentPage = nextPage
                hasMore = !videos.isEmpty
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
                return
            }

            guard hasMore, isLocalYearFilterActive(for: sort), extraPages < Self.maxAutoFillPages else { return }
            let gained = categoryVideos.count - displayedBefore
            // 首屏凑够最少条数；翻页时至少要带来一条新内容，否则底部触发器不会再次出现。
            let needsMore = categoryVideos.count < Self.minFilteredCount || gained == 0
            guard needsMore else { return }
            extraPages += 1
            nextPage += 1
        }
    }

    /// 切换本地年份后，已加载数据过滤得太少时补拉几页。
    private func fillFilteredResultsIfNeeded(sort: MovieSort.SortData) async {
        guard isLocalYearFilterActive(for: sort), hasMore,
              categoryVideos.count < Self.minFilteredCount else { return }
        await loadPages(startingAt: currentPage + 1, sort: sort)
    }

    /// 按分类类型请求单页数据。
    private func fetchPage(_ page: Int, sort: MovieSort.SortData) async throws -> [Movie.Video] {
        let selections = effectiveSelections(for: sort)
        if sort.isDouban {
            typealias Key = MovieSort.SortFilter
            return try await sourceService.getDoubanList(
                kind: selections[Key.doubanKindKey] ?? "movie",
                sort: selections[Key.doubanSortKey] ?? "T",
                tags: [selections[Key.doubanYearKey] ?? "", selections[Key.doubanAreaKey] ?? ""],
                page: page
            )
        }
        guard let source = ApiConfig.shared.homeSourceBean else { return [] }
        return try await sourceService.getList(sourceBean: source, sortData: sort, page: page, filters: selections)
    }

    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }

    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard let sort = selectedSort, !sort.isHome else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }

        await loadPages(startingAt: currentPage + 1, sort: sort)
    }

    /// 刷新
    func refresh() async {
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容（保留筛选选择）。
        loadGeneration += 1
        currentPage = 1
        hasMore = true
        rawCategoryVideos = []
        categoryVideos = []
        errorMessage = nil
        await loadSorts()

        guard let sort = selectedSort else { return }
        if sort.isHome { return }

        if let matchedSort = sorts.first(where: { $0.id == sort.id }) {
            selectedSort = matchedSort
        } else if let firstCategory = sorts.first(where: { !$0.isHome && !$0.isDouban }) {
            selectedSort = firstCategory
        } else {
            return
        }
        if let current = selectedSort {
            await loadPages(startingAt: 1, sort: current)
        }
    }
}
