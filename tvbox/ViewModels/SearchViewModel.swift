import Foundation
import SwiftUI

/// 搜索 ViewModel
@MainActor
class SearchViewModel: ObservableObject {
    /// 搜索关键词输入。
    @Published var keyword: String = ""
    /// 当前结果列表。
    @Published var results: [Movie.Video] = []
    /// 搜索加载状态，用于控制进度指示器。
    @Published private(set) var isSearching = false
    /// 本地搜索历史（最近在前）。
    @Published var searchHistory: [String] = []
    /// 搜索失败或空结果提示。
    @Published var errorMessage: String?
    /// 部分来源失败时的提示（保留已有结果）。
    @Published var partialFailureMessage: String?
    /// 本次失败是否可重试（全部来源失败时为 true）。
    @Published private(set) var canRetry = false

    /// 源数据服务（负责多源并发搜索）。
    private let sourceService = SourceService.shared
    /// 搜索请求序号（用于丢弃过期异步结果）。
    private var latestSearchRequestId: UUID = UUID()
    /// 当前搜索任务，清空或重新搜索时用于取消在途请求。
    private var searchTask: Task<Void, Never>?

    /// 初始化时同步加载本地历史记录，确保搜索页首次渲染即可展示。
    init() {
        loadSearchHistory()
    }

    // MARK: - 搜索

    /// 执行搜索
    func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }
        beginSearch()
        let requestId = latestSearchRequestId
        // 搜索一旦触发就先落历史，保持行为与移动端常见搜索体验一致。
        addToHistory(trimmed)

        let task = Task { [weak self] in
            guard let self else { return }
            // 走多源并发搜索，返回聚合后的影片列表与各来源状态。
            let aggregate = await self.sourceService.searchAll(keyword: trimmed)
            self.applySearchOutcome(aggregate, requestId: requestId)
        }
        searchTask = task
        await task.value
    }

    /// 在指定源搜索
    func searchInSource(_ source: SourceBean) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }
        beginSearch()

        let requestId = latestSearchRequestId
        do {
            let videos = try await sourceService.search(sourceBean: source, keyword: trimmed)
            guard requestId == latestSearchRequestId else { return }
            self.results = videos
            if videos.isEmpty {
                errorMessage = "未找到相关内容"
            }
        } catch {
            guard requestId == latestSearchRequestId else { return }
            canRetry = true
            errorMessage = error.localizedDescription
        }

        guard requestId == latestSearchRequestId else { return }
        isSearching = false
        searchTask = nil
    }

    /// 清空关键词与结果，并让在途请求失效（旧结果不得再回填）。
    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        latestSearchRequestId = UUID()
        keyword = ""
        results = []
        errorMessage = nil
        partialFailureMessage = nil
        canRetry = false
        isSearching = false
    }

    /// 离开页面时取消在途搜索，避免后台任务继续占用网络与内存。
    func cancelSearch() {
        guard isSearching else { return }
        searchTask?.cancel()
        searchTask = nil
        latestSearchRequestId = UUID()
        isSearching = false
        // 回到页面时给出明确状态与重试入口，而不是空白。
        errorMessage = "搜索已取消"
        canRetry = true
    }

    private func beginSearch() {
        searchTask?.cancel()
        searchTask = nil
        latestSearchRequestId = UUID()
        isSearching = true
        errorMessage = nil
        partialFailureMessage = nil
        canRetry = false
        results = []
    }

    private func applySearchOutcome(_ aggregate: SourceService.SearchAggregate, requestId: UUID) {
        // 已取消或被新请求/清空取代的结果一律丢弃，不得回填。
        guard !Task.isCancelled, requestId == latestSearchRequestId else { return }
        defer {
            isSearching = false
            searchTask = nil
        }

        results = Self.deduplicated(aggregate.videos)

        if aggregate.candidateSourceCount == 0 {
            canRetry = false
            errorMessage = "没有可用的搜索源，请检查接口配置"
            return
        }

        if aggregate.allSourcesFailed {
            // 全部来源失败与“没有匹配内容”是两种状态，需要给出原因与重试入口。
            canRetry = true
            let firstReason = aggregate.failures.first.map { "（\($0.sourceName)：\($0.message)）" } ?? ""
            errorMessage = "搜索失败：\(aggregate.failures.count) 个数据源均未返回结果\(firstReason)"
            return
        }

        canRetry = false
        partialFailureMessage = aggregate.hasPartialFailure
            ? "\(aggregate.failures.count) 个数据源搜索失败（\(aggregate.failedSources.prefix(3).joined(separator: "、"))），结果可能不完整"
            : nil

        if aggregate.videos.isEmpty {
            errorMessage = aggregate.hasPartialFailure
                ? "已搜索的数据源中未找到相关内容"
                : "未找到相关内容"
            canRetry = aggregate.hasPartialFailure
        }
    }

    /// 按业务身份（来源 + 视频 ID）去重并保持原有顺序。
    private static func deduplicated(_ videos: [Movie.Video]) -> [Movie.Video] {
        var seen: Set<Movie.Video.Identity> = []
        return videos.filter { seen.insert($0.id).inserted }
    }

    // MARK: - 搜索历史

    /// 从本地读取历史。
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: HawkConfig.SEARCH_HISTORY) ?? []
    }

    /// 新增历史项并去重，最多保留 20 条。
    private func addToHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }

    /// 清空历史。
    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: HawkConfig.SEARCH_HISTORY)
    }

    /// 删除单条历史。
    func removeFromHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
}
