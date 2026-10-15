import Foundation

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()

    /// 单个分类页的完整结果（含分页元数据，供上层判断是否还有下一页）。
    struct VideoPage {
        let videos: [Movie.Video]
        let page: Int
        let pageCount: Int?
        let total: Int?
        let limit: Int?

        var isEmpty: Bool { videos.isEmpty }
    }

    /// 多源搜索聚合结果（保留每个来源的成功/失败状态，避免把失败伪装成“没有结果”）。
    struct SearchAggregate {
        /// 单个来源的失败信息。
        struct Failure {
            let sourceName: String
            let message: String
        }

        let videos: [Movie.Video]
        let succeededSourceCount: Int
        let failures: [Failure]
        let candidateSourceCount: Int

        var failedSources: [String] { failures.map(\.sourceName) }
        var allSourcesFailed: Bool { succeededSourceCount == 0 && !failures.isEmpty }
        var hasPartialFailure: Bool { succeededSourceCount > 0 && !failures.isEmpty }
    }

    /// 单个来源的搜索结果。
    private enum SourceSearchOutcome {
        case success([Movie.Video])
        case failure(String)
        case cancelled
    }

    private let network = NetworkManager.shared
    private let extendCache = ExtendCache()

    private init() {}

    // MARK: - 获取分类列表

    /// 获取指定源的分类列表和首页推荐
    func getSort(sourceBean: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let api = try validatedAPI(of: sourceBean)

        let jsonStr: String
        if sourceBean.type == 0 {
            // XML 接口
            jsonStr = try await network.getString(from: api)
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 filter 与 extend 参数
            let extendItems = await extendQueryItems(for: sourceBean)
            let queryItems = [URLQueryItem(name: "filter", value: "true")] + extendItems
            let url = try buildURL(base: api, queryItems: queryItems)
            jsonStr = try await fetchText(url, for: sourceBean)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            jsonStr = try await fetchText(url, for: sourceBean)
        }

        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)

        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 额外请求列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2

        if needsFallback {
            let fallbackPage = try? await fetchHomeFallback(sourceBean: sourceBean, api: api)
            if let fallbackPage, !fallbackPage.videos.isEmpty {
                homeVideos = fallbackPage.videos
            }
        }

        return (sorts, homeVideos)
    }

    /// 首页推荐回退请求（列表协议第一页）。type=4 与其他入口一样附加 extend，
    /// 否则强制校验 extend 的远程接口会拒绝请求，导致分类可见而推荐为空。
    private func fetchHomeFallback(sourceBean: SourceBean, api: String) async throws -> VideoPage {
        let url: String
        if sourceBean.type == 4 {
            let ext = Data("{}".utf8).base64EncodedString()
            let extendItems = await extendQueryItems(for: sourceBean)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "filter", value: "true"),
                    URLQueryItem(name: "pg", value: "1"),
                    URLQueryItem(name: "ext", value: ext)
                ] + extendItems
            )
        } else {
            // XML（type=0）与 JSON（type=1）均使用 videolist 拉取带海报的列表
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "pg", value: "1")
                ]
            )
        }
        let text = try await fetchText(url, for: sourceBean)
        return try parseVideoList(text, sourceKey: sourceBean.key, type: sourceBean.type, sourceName: sourceBean.name)
    }

    /// 解析首页分类响应（内部可见，便于回归测试直接校验协议解析）。
    func parseSort(_ jsonStr: String, sourceBean: SourceBean) throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        if sourceBean.type == 0 {
            let root = try parseXMLDocument(jsonStr, sourceName: sourceBean.name)
            let sorts = SourceXMLParser.categories(from: root)
            let videos = SourceXMLParser.videoList(from: root).videos.map { video in
                var copy = video
                copy.sourceKey = sourceBean.key
                return copy
            }
            return (sorts, videos)
        }

        let json = try parseJSONObject(jsonStr, sourceName: sourceBean.name)

        var sorts: [MovieSort.SortData] = []
        if let classList = json["class"] as? [[String: Any]] {
            for cls in classList {
                let id = Self.stringValue(cls["type_id"])
                guard !id.isEmpty else { continue }
                let name = cls["type_name"] as? String ?? ""
                sorts.append(MovieSort.SortData(id: id, name: name))
            }
        }

        if let filterMap = json["filters"] as? [String: Any] {
            for index in sorts.indices {
                if let rawFilters = filterMap[sorts[index].id] as? [[String: Any]] {
                    sorts[index].filters = parseFilters(rawFilters)
                }
            }
        }

        // 首页响应以分类为主，list 只是附带的推荐：有分类时 list 缺失或格式异常都不影响分类展示，
        // 既没有分类也没有合法 list 才视为无效响应（HTML、业务错误对象等）。
        var homeVideos: [Movie.Video] = []
        let rawList = json["list"]
        if let list = rawList as? [[String: Any]] {
            homeVideos = Self.decodeVideos(list, sourceKey: sourceBean.key, sourceName: sourceBean.name)
        } else if sorts.isEmpty && !(rawList is NSNull) {
            throw SourceError.parseError(
                rawList == nil
                    ? Self.describeInvalidResponse(json, sourceName: sourceBean.name)
                    : "\(sourceBean.name) 返回的 list 字段格式不正确"
            )
        }

        return (sorts, homeVideos)
    }

    private func parseFilters(_ rawFilters: [[String: Any]]) -> [MovieSort.SortFilter] {
        rawFilters.compactMap { raw in
            guard let key = raw["key"] as? String, !key.isEmpty,
                  let rawValues = raw["value"] as? [[String: Any]] else { return nil }
            let values = rawValues.map { item in
                MovieSort.SortFilter.SortFilterValue(
                    n: Self.lossyString(item["n"]),
                    v: Self.lossyString(item["v"])
                )
            }
            guard !values.isEmpty else { return nil }
            return MovieSort.SortFilter(key: key, name: Self.lossyString(raw["name"]), values: values)
        }
    }

    private static func lossyString(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    // MARK: - 获取分类视频列表

    /// 获取分类下的视频列表
    func getList(
        sourceBean: SourceBean,
        sortData: MovieSort.SortData,
        page: Int = 1,
        filters: [String: String]? = nil
    ) async throws -> VideoPage {
        let api = try validatedAPI(of: sourceBean)
        let filters = filters?.filter { key, value in
            !key.hasPrefix(MovieSort.SortFilter.localKeyPrefix) && !value.isEmpty
        }

        let url: String
        switch sourceBean.type {
        case 0:
            // XML 接口
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "t", value: sortData.id),
                    URLQueryItem(name: "pg", value: String(page))
                ]
            )
        case 4:
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "filter", value: "true"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数（base64 编码）
            if let filters, !filters.isEmpty,
               let filterData = try? JSONSerialization.data(withJSONObject: filters),
               let filterStr = String(data: filterData, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "ext", value: Data(filterStr.utf8).base64EncodedString()))
            } else {
                queryItems.append(URLQueryItem(name: "ext", value: Data("{}".utf8).base64EncodedString()))
            }
            queryItems.append(contentsOf: await extendQueryItems(for: sourceBean))
            url = try buildURL(base: api, queryItems: queryItems)
        default:
            // JSON 接口 (type=1)
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "videolist"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]

            // 附加筛选参数
            if let filters {
                for (key, value) in filters.sorted(by: { $0.key < $1.key }) {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        }

        let jsonStr = try await fetchText(url, for: sourceBean)
        return try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type, sourceName: sourceBean.name)
    }

    /// 解析列表/搜索响应（内部可见，便于回归测试直接校验协议解析）。
    func parseVideoList(_ jsonStr: String, sourceKey: String, type: Int, sourceName: String? = nil) throws -> VideoPage {
        let sourceName = sourceName ?? sourceKey
        if type == 0 {
            let root = try parseXMLDocument(jsonStr, sourceName: sourceName)
            let parsed = SourceXMLParser.videoList(from: root)
            let videos = parsed.videos.map { video in
                var copy = video
                copy.sourceKey = sourceKey
                return copy
            }
            return VideoPage(
                videos: videos,
                page: parsed.page ?? 1,
                pageCount: parsed.pageCount,
                total: parsed.total,
                limit: parsed.pageSize
            )
        }

        let json = try parseJSONObject(jsonStr, sourceName: sourceName)
        let items = try Self.decodeListField(json, sourceKey: sourceKey, sourceName: sourceName)
        let videos = Self.decodeVideos(items, sourceKey: sourceKey, sourceName: sourceName)

        return VideoPage(
            videos: videos,
            page: Self.intValue(json["page"]) ?? 1,
            pageCount: Self.intValue(json["pagecount"]),
            total: Self.intValue(json["total"]),
            limit: Self.intValue(json["limit"])
        )
    }

    // MARK: - 获取详情

    /// 获取视频详情
    func getDetail(sourceBean: SourceBean, vodId: String) async throws -> VodInfo? {
        let api = try validatedAPI(of: sourceBean)

        let url: String
        switch sourceBean.type {
        case 0:
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        case 4:
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "ids", value: vodId)
            ]
            queryItems.append(contentsOf: await extendQueryItems(for: sourceBean))
            url = try buildURL(base: api, queryItems: queryItems)
        default:
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        }

        let jsonStr = try await fetchText(url, for: sourceBean)
        return try parseDetail(jsonStr, sourceKey: sourceBean.key, sourceName: sourceBean.name, type: sourceBean.type, requestedId: vodId)
    }

    /// 解析详情响应（内部可见，便于回归测试直接校验协议解析）。
    func parseDetail(
        _ jsonStr: String,
        sourceKey: String,
        sourceName: String,
        type: Int,
        requestedId: String
    ) throws -> VodInfo? {
        if type == 0 {
            let root = try parseXMLDocument(jsonStr, sourceName: sourceName)
            let parsed = SourceXMLParser.videoList(from: root)
            guard let matched = Self.matchRequestedVideo(parsed.videos, requestedId: requestedId) else {
                return nil
            }
            var video = matched
            video.sourceKey = sourceKey
            let detail = SourceXMLParser.playInfo(for: matched, in: root)
            return VodInfo.from(video: video, playFrom: detail.playFrom, playUrl: detail.playUrl)
        }

        let json = try parseJSONObject(jsonStr, sourceName: sourceName)
        let items = try Self.decodeListField(json, sourceKey: sourceKey, sourceName: sourceName)
        guard let first = Self.matchRequestedVideo(items, requestedId: requestedId) else {
            return nil
        }

        let playFrom = first["vod_play_from"] as? String ?? ""
        let playUrl = first["vod_play_url"] as? String ?? ""
        guard let video = Self.decodeVideo(first, sourceKey: sourceKey) else {
            throw SourceError.parseError("\(sourceName) 返回的详情数据无法解析")
        }

        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }

    /// 详情接口有时会忽略 ids 参数返回整个列表，这里优先匹配请求的 ID，避免打开无关影片。
    private static func matchRequestedVideo(_ items: [[String: Any]], requestedId: String) -> [String: Any]? {
        let target = requestedId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty,
           let matched = items.first(where: { stringValue($0["vod_id"]) == target }) {
            return matched
        }
        return items.count == 1 ? items.first : nil
    }

    private static func matchRequestedVideo(_ videos: [Movie.Video], requestedId: String) -> Movie.Video? {
        let target = requestedId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty,
           let matched = videos.first(where: { $0.vodId == target }) {
            return matched
        }
        return videos.count == 1 ? videos.first : nil
    }

    // MARK: - 搜索

    /// 在指定源中搜索
    func search(sourceBean: SourceBean, keyword: String) async throws -> [Movie.Video] {
        let api = try validatedAPI(of: sourceBean)

        let url: String
        switch sourceBean.type {
        case 0:
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        case 4:
            // Type 4: 远程接口
            let quickValue = sourceBean.isQuickSearchEnabled ? "true" : "false"
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "wd", value: keyword),
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "quick", value: quickValue)
            ]
            queryItems.append(contentsOf: await extendQueryItems(for: sourceBean))
            url = try buildURL(base: api, queryItems: queryItems)
        default:
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        }

        let jsonStr = try await fetchText(url, for: sourceBean)
        let page = try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type, sourceName: sourceBean.name)
        return filterSearchResults(page.videos, keyword: keyword)
    }

    /// 多源并发搜索：返回聚合结果与每个来源的成功/失败状态，保留配置顺序。
    func searchAll(keyword: String) async -> SearchAggregate {
        let sources = await ApiConfig.shared.getSearchableSources()
            .filter { $0.isSupportedInSwift && $0.isHttpApi }

        guard !sources.isEmpty else {
            return SearchAggregate(videos: [], succeededSourceCount: 0, failures: [], candidateSourceCount: 0)
        }

        // 子任务继承外层取消：清空/重新搜索时在途请求会一并取消。
        let outcomes = await withTaskGroup(of: (Int, SourceSearchOutcome).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { [self] in
                    do {
                        return (index, .success(try await self.search(sourceBean: source, keyword: keyword)))
                    } catch {
                        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                            return (index, .cancelled)
                        }
                        return (index, .failure(error.localizedDescription))
                    }
                }
            }

            var collected: [Int: SourceSearchOutcome] = [:]
            for await (index, outcome) in group {
                collected[index] = outcome
            }
            return collected
        }

        // 按配置顺序合并，结果稳定。
        var videos: [Movie.Video] = []
        var failures: [SearchAggregate.Failure] = []
        var succeeded = 0
        for (index, source) in sources.enumerated() {
            switch outcomes[index] {
            case .success(let items):
                succeeded += 1
                videos.append(contentsOf: items)
            case .failure(let message):
                failures.append(SearchAggregate.Failure(sourceName: source.name, message: message))
            case .cancelled, nil:
                break
            }
        }

        return SearchAggregate(
            videos: videos,
            succeededSourceCount: succeeded,
            failures: failures,
            candidateSourceCount: sources.count
        )
    }

    /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容。
    private func filterSearchResults(_ videos: [Movie.Video], keyword: String) -> [Movie.Video] {
        let tokens = keyword
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeSearchText(String($0)) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return videos }

        return videos.filter { video in
            let searchableText = normalizeSearchText([
                video.name,
                video.note,
                video.actor,
                video.director,
                video.type,
                video.area,
                video.year
            ].joined(separator: " "))
            guard !searchableText.isEmpty else { return false }
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }

    private func normalizeSearchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    // MARK: - 豆瓣片库

    /// 豆瓣条目的 sourceKey 标记：这类条目不能直接播放，需按片名全源搜索。
    static let doubanSourceKey = "douban"

    private static let doubanHeaders = [
        "Referer": "https://movie.douban.com/",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ]

    /// 获取豆瓣片库列表（m.douban.com rexxar 推荐接口，支持排序与年份/地区标签）。
    /// - Parameters:
    ///   - kind: movie 电影 / tv 电视剧 / show 综艺
    ///   - sort: T 综合 / U 近期热度 / S 高分优先 / R 首映时间
    ///   - tags: 年份、地区等标签，如 ["2024", "华语"]
    func getDoubanList(kind: String, sort: String, tags: [String], page: Int, pageSize: Int = 30) async throws -> [Movie.Video] {
        let path: String
        var categories: [String: String] = [:]
        switch kind {
        case "tv":
            path = "tv"
            categories["形式"] = "电视剧"
        case "show":
            path = "tv"
            categories["形式"] = "综艺"
        default:
            path = "movie"
        }

        let categoryData = try JSONSerialization.data(withJSONObject: categories, options: [.sortedKeys])
        let categoryJSON = String(data: categoryData, encoding: .utf8) ?? "{}"
        var queryItems = [
            URLQueryItem(name: "refresh", value: "0"),
            URLQueryItem(name: "start", value: String(max(0, page - 1) * pageSize)),
            URLQueryItem(name: "count", value: String(pageSize)),
            URLQueryItem(name: "selected_categories", value: categoryJSON),
            URLQueryItem(name: "uncollect", value: "false"),
            URLQueryItem(name: "sort", value: sort.isEmpty ? "T" : sort)
        ]
        let tagValue = tags.filter { !$0.isEmpty }.joined(separator: ",")
        if !tagValue.isEmpty {
            queryItems.append(URLQueryItem(name: "tags", value: tagValue))
        }

        let url = try buildURL(base: "https://m.douban.com/rexxar/api/v2/\(path)/recommend", queryItems: queryItems)
        let jsonStr = try await network.getString(from: url, headers: Self.doubanHeaders)
        return try parseDoubanList(jsonStr)
    }

    private func parseDoubanList(_ jsonStr: String) throws -> [Movie.Video] {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parseError("豆瓣数据格式异常")
        }
        guard let items = json["items"] as? [[String: Any]] else {
            // 豆瓣风控时会返回 {"msg": ..., "code": ...}
            let message = json["localized_message"] as? String ?? json["msg"] as? String ?? "豆瓣数据格式异常"
            throw SourceError.parseError(message)
        }

        return items.compactMap { item in
            // 列表中夹杂广告/专题卡片，只保留影视条目
            let itemType = item["type"] as? String ?? ""
            guard itemType == "movie" || itemType == "tv",
                  let doubanId = item["id"] as? String,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }

            var video = Movie.Video(vodId: "douban_\(doubanId)", name: title, sourceKey: Self.doubanSourceKey)
            if let pic = item["pic"] as? [String: Any] {
                video.pic = pic["normal"] as? String ?? pic["large"] as? String ?? ""
            }
            if let rating = item["rating"] as? [String: Any],
               let value = (rating["value"] as? NSNumber)?.doubleValue, value > 0 {
                video.score = value
                video.note = String(format: "豆瓣 %.1f", value)
            } else {
                video.note = item["episodes_info"] as? String ?? ""
            }
            // card_subtitle 形如 "2024 / 中国大陆 / 剧情 古装 / 导演 / 主演"
            let subtitle = (item["card_subtitle"] as? String ?? "")
                .components(separatedBy: " / ")
            video.year = subtitle.first ?? ""
            video.area = subtitle.count > 1 ? subtitle[1] : ""
            video.type = [video.year, video.area].filter { !$0.isEmpty }.joined(separator: " · ")
            return video
        }
    }

    // MARK: - 播放地址

    /// 播放接口（TVBox playerContent）的解析结果。
    enum PlayResult: Equatable {
        /// 可以直接播放：地址已拼接 `playUrl` 前缀，`headers` 需原样交给播放器。
        case direct(url: String, headers: [String: String])
        /// 需要解析或嗅探（parse=1 / jx=1 / video://）才能拿到媒体地址，Swift 版尚未接入解析链路。
        case needsParse(url: String)
    }

    /// 向源换取剧集的真实播放地址（对应 Android 端 getPlay 的 type=4 分支）。
    /// T4 剧集列表里的地址多是网页地址或编码过的 ID，要由服务端执行免嗅逻辑才能得到媒体地址；
    /// 其他类型的剧集地址本身就是播放地址，原样返回。
    func getPlay(sourceBean: SourceBean, flag: String, id: String) async throws -> PlayResult {
        guard sourceBean.requiresPlayResolution else {
            return .direct(url: id, headers: [:])
        }
        let api = try validatedAPI(of: sourceBean)
        var queryItems = [
            URLQueryItem(name: "play", value: id),
            URLQueryItem(name: "flag", value: flag)
        ]
        queryItems.append(contentsOf: await extendQueryItems(for: sourceBean))
        let url = try buildURL(base: api, queryItems: queryItems)
        let text = try await fetchText(url, for: sourceBean)
        return try parsePlay(text, sourceName: sourceBean.name)
    }

    /// 解析 play 接口响应（内部可见，便于回归测试直接校验协议解析）。规则与 Android 端一致：
    /// - 缺省的 `parse` 视为需要解析，`jx=1` 表示要走解析接口；
    /// - `url` 为数组（`[名称, 地址, …]`）时取第一个 http 地址直接播放，`video://` 前缀表示需要嗅探；
    /// - 请求头来自 `header` / `headers`（对象或 JSON 字符串），直接播放时地址为 `playUrl + url`。
    /// 与 Android 不同的是 `msg` 只在没有地址时才当作失败原因：部分服务端会在成功结果里附带 success 之类的提示。
    func parsePlay(_ text: String, sourceName: String) throws -> PlayResult {
        let json = try parseJSONObject(text, sourceName: sourceName)

        let prefix = Self.stringValue(json["playUrl"])
        var needsParse = Self.flagValue(json["parse"]) ?? true
        var url: String
        if let candidates = Self.playURLCandidates(json["url"]) {
            url = candidates.first { $0.contains("http") } ?? ""
            needsParse = false
        } else {
            url = Self.stringValue(json["url"])
        }

        if url.hasPrefix("video://") {
            url = String(url.dropFirst("video://".count))
            needsParse = true
        } else if url.hasPrefix("proxy://") {
            throw SourceError.playFailed("该剧集需要通过本地代理（proxy://）播放，当前版本暂不支持")
        }
        guard !url.isEmpty else {
            let message = (json["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty {
                throw SourceError.playFailed(message)
            }
            throw SourceError.parseError("\(sourceName) 的播放接口没有返回播放地址")
        }

        let headers = Self.headerFields(json["header"])
            .merging(Self.headerFields(json["headers"])) { _, new in new }
        if needsParse || Self.flagValue(json["jx"]) == true {
            // 还没有解析/嗅探链路：地址本身就是媒体直链时直接播放（Android 的嗅探最终也会命中这个地址）。
            if prefix.isEmpty && Self.looksLikeMediaURL(url) {
                return .direct(url: url, headers: headers)
            }
            return .needsParse(url: url)
        }
        return .direct(url: prefix + url, headers: headers)
    }

    /// 地址是否像可直接播放的媒体直链（参考 Android 端 isVideoFormat）：解析接口与网页地址不算。
    static func looksLikeMediaURL(_ url: String) -> Bool {
        let lowercased = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return false }
        if lowercased.contains("url=http") || lowercased.contains(".html") { return false }
        return lowercased.range(
            of: #"\.(m3u8|mp4|mkv|flv|mp3|m4a|aac)(\?|#|&|$)"#,
            options: .regularExpression
        ) != nil
    }

    /// 读取 parse / jx 这类 0/1 标志；字段缺失或无法识别时返回 nil。
    private static func flagValue(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.intValue == 1
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `url` 字段为数组（或数组形式的 JSON 字符串）时返回其中的字符串项，否则返回 nil。
    private static func playURLCandidates(_ value: Any?) -> [String]? {
        var array = value as? [Any]
        if array == nil, let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let data = trimmed.data(using: .utf8) {
                array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            }
        }
        return array?.compactMap { item in
            guard let string = item as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("video://") ? String(trimmed.dropFirst("video://".count)) : trimmed
        }
    }

    /// 读取请求头字段：支持 JSON 对象与 JSON 字符串两种写法，忽略空键与空值。
    private static func headerFields(_ value: Any?) -> [String: String] {
        var object = value as? [String: Any]
        if object == nil, let text = value as? String,
           let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        var headers: [String: String] = [:]
        for (rawKey, rawValue) in object ?? [:] {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stringValue(rawValue)
            guard !key.isEmpty, !value.isEmpty else { continue }
            headers[key] = value
        }
        return headers
    }

    // MARK: - Extend 解析

    /// 短期缓存 extend 下载结果，避免同一源在多个入口重复下载。
    private actor ExtendCache {
        private struct Entry {
            let value: String
            let fetchedAt: Date
        }

        private var entries: [String: Entry] = [:]
        private let ttl: TimeInterval = 300

        func value(for key: String) -> String? {
            guard let entry = entries[key] else { return nil }
            guard Date().timeIntervalSince(entry.fetchedAt) <= ttl else {
                entries[key] = nil
                return nil
            }
            return entry.value
        }

        func store(_ value: String, for key: String) {
            entries[key] = Entry(value: value, fetchedAt: Date())
        }
    }

    /// 解析 extend 参数（对应 Android 端 getFixUrl）：
    /// 如果 extend 是 HTTP URL，则下载其内容作为 extend 值；否则直接返回原值。
    private func resolveExtend(_ extend: String) async -> String {
        let trimmed = extend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 非 HTTP URL 直接返回
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return trimmed
        }

        if let cached = await extendCache.value(for: trimmed) {
            return cached
        }

        do {
            let content = try await network.getString(from: trimmed)
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            let resolved = value.count > 2500 ? trimmed : value
            await extendCache.store(resolved, for: trimmed)
            return resolved
        } catch {
            // 下载失败保留原地址，由服务端按 URL 处理；不缓存失败结果，下次仍会重试。
            print("加载 extend 失败: \(trimmed), error: \(error)")
            return trimmed
        }
    }

    /// type=4 需要追加的 extend 参数。
    private func extendQueryItems(for sourceBean: SourceBean) async -> [URLQueryItem] {
        guard let ext = sourceBean.ext, !ext.isEmpty else { return [] }
        let extend = await resolveExtend(ext)
        guard !extend.isEmpty else { return [] }
        return [URLQueryItem(name: "extend", value: extend)]
    }

    // MARK: - 公共工具

    /// T4 服务端（如 drpy-node）默认 20 秒超时：客户端要等得比它久，才能拿到服务端的错误提示，而不是自己先超时。
    private static let remoteRequestTimeout: TimeInterval = 25

    /// 按来源类型选择请求策略：T4 接口由服务端现场执行爬虫规则，耗时长且失败多为确定性错误，只重试连接错误。
    private func fetchText(_ url: String, for sourceBean: SourceBean) async throws -> String {
        guard sourceBean.type == 4 else {
            return try await network.getString(from: url)
        }
        return try await network.getString(
            from: url,
            timeout: Self.remoteRequestTimeout,
            retryPolicy: .connectionOnly
        )
    }

    private func validatedAPI(of sourceBean: SourceBean) throws -> String {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        return api
    }

    /// 把响应文本解析为 XML 文档；无法解析或既没有分类也没有列表节点时视为无效响应。
    private func parseXMLDocument(_ text: String, sourceName: String) throws -> SourceXMLParser.Node {
        guard let root = SourceXMLParser.parse(text) else {
            throw SourceError.parseError("\(sourceName) 返回的数据不是合法的 XML")
        }
        guard root.name == "list" || root.name == "class"
                || root.firstDescendant("list") != nil
                || root.firstDescendant("class") != nil else {
            throw SourceError.parseError("\(sourceName) 返回的 XML 缺少分类或列表节点")
        }
        return root
    }

    /// 把响应文本解析为 JSON 对象；HTML、损坏 JSON 等不是“空列表”，必须显式报错。
    private func parseJSONObject(_ text: String, sourceName: String) throws -> [String: Any] {
        var content = text
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        guard let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SourceError.parseError("\(sourceName) 返回的数据不是合法的 JSON")
        }
        return json
    }

    /// 读取列表字段：合法空列表返回空数组，字段缺失或类型错误抛出解析错误。
    private static func decodeListField(
        _ json: [String: Any],
        sourceKey: String,
        sourceName: String
    ) throws -> [[String: Any]] {
        guard let rawList = json["list"] else {
            throw SourceError.parseError(describeInvalidResponse(json, sourceName: sourceName))
        }
        if rawList is NSNull {
            return []
        }
        guard let list = rawList as? [[String: Any]] else {
            throw SourceError.parseError("\(sourceName) 返回的 list 字段格式不正确")
        }
        return list
    }

    /// 生成可读的失败原因，优先使用服务端返回的业务提示。
    private static func describeInvalidResponse(_ json: [String: Any], sourceName: String) -> String {
        let message = (json["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty {
            return "\(sourceName) 返回错误: \(message)"
        }
        return "\(sourceName) 返回的数据缺少列表字段"
    }

    private static func decodeVideos(_ items: [[String: Any]], sourceKey: String, sourceName: String) -> [Movie.Video] {
        var videos: [Movie.Video] = []
        var dropped = 0
        for item in items {
            if let video = decodeVideo(item, sourceKey: sourceKey) {
                videos.append(video)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 {
            print("\(sourceName) 有 \(dropped) 条数据解码失败已跳过")
        }
        return videos
    }

    private static func decodeVideo(_ item: [String: Any], sourceKey: String) -> Movie.Video? {
        let decoder = JSONDecoder()
        guard let itemData = try? JSONSerialization.data(withJSONObject: item),
              var video = try? decoder.decode(Movie.Video.self, from: itemData),
              !video.vodId.isEmpty else {
            return nil
        }
        video.sourceKey = sourceKey
        return video
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let int as Int:
            return String(int)
        case let double as Double:
            return double == double.rounded() ? String(Int(double)) : String(double)
        default:
            return ""
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// 构造请求地址：
    /// 1) 客户端控制的参数名先移除旧值再写入，避免同一参数出现两次（如基础地址里已有 ac=class）；
    /// 2) 查询项按 RFC 3986 逐项编码，字面 `+` 编码为 `%2B`，避免被按“空格”解析；
    /// 3) 不改动基础地址中既有的其他查询项与百分号编码。
    func buildURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }

        let newNames = Set(queryItems.map(\.name))
        var pairs: [String] = []

        // 既有参数按原始编码逐字保留（签名/鉴权参数不能被重新编码），只剔除将被覆盖的同名参数。
        let existingPairs = (components.percentEncodedQuery ?? "")
            .split(separator: "&", omittingEmptySubsequences: true)
            .map(String.init)
        for pair in existingPairs {
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? pair
            let name = rawName.removingPercentEncoding ?? rawName
            if !newNames.contains(name) {
                pairs.append(pair)
            }
        }
        for item in queryItems {
            pairs.append(Self.percentEncodedQueryItem(name: item.name, value: item.value))
        }

        components.percentEncodedQuery = pairs.isEmpty ? nil : pairs.joined(separator: "&")

        guard let url = components.url else {
            throw SourceError.invalidApiUrl(base)
        }
        return url.absoluteString
    }

    /// RFC 3986 未保留字符（仅 ASCII）。`CharacterSet.alphanumerics` 含非 ASCII 字母，不能直接使用。
    private static let queryUnreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncodedQueryItem(name: String, value: String?) -> String {
        let allowed = queryUnreservedCharacters
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let rawValue = value ?? ""
        let encodedValue = rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
        return "\(encodedName)=\(encodedValue)"
    }
}

enum SourceError: LocalizedError {
    case emptyApi
    case parseError(String)
    case unsupportedType(String)
    case invalidApiUrl(String)
    /// 播放接口明确无法播放（服务端 msg 或不支持的地址形式）。
    case playFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyApi: return "接口地址为空"
        case .parseError(let msg): return "数据解析错误: \(msg)"
        case .unsupportedType(let type): return "暂不支持 \(type) 类型的数据源，请切换其他源"
        case .invalidApiUrl(let url): return "无效的接口地址: \(url)"
        case .playFailed(let msg): return msg
        }
    }
}
