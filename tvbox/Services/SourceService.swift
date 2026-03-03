import Foundation

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()
    
    private let network = NetworkManager.shared
    
    private init() {}
    
    // MARK: - 获取分类列表
    
    /// 获取指定源的分类列表和首页推荐
    func getSort(sourceBean: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let api = sourceBean.api
        guard !api.isEmpty else {
            throw SourceError.emptyApi
        }
        
        // type=3 (JAR/Spider) 暂不支持
        guard sourceBean.isSupportedInSwift else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }
        
        // 确保 api 是有效的 HTTP URL
        guard sourceBean.isHttpApi else {
            throw SourceError.invalidApiUrl(api)
        }
        
        let jsonStr: String
        if sourceBean.type == 0 {
            // XML 接口
            jsonStr = try await network.getString(from: api)
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 extend 和 filter 参数
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "filter", value: "true")
            ]
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            let url = try buildURL(base: api, queryItems: queryItems)
            jsonStr = try await network.getString(from: url)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            jsonStr = try await network.getString(from: url)
        }
        
        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)
        
        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 额外请求列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2
        
        if needsFallback && (sourceBean.type == 1 || sourceBean.type == 4) {
            let listUrl: String
            if sourceBean.type == 4 {
                // type=4 用 ac=detail 格式，与 getList 保持一致
                let ext = Data("{}".utf8).base64EncodedString()
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "detail"),
                        URLQueryItem(name: "filter", value: "true"),
                        URLQueryItem(name: "pg", value: "1"),
                        URLQueryItem(name: "ext", value: ext)
                    ]
                )
            } else {
                // type=1 用 ac=videolist 格式
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "videolist"),
                        URLQueryItem(name: "pg", value: "1")
                    ]
                )
            }
            if let listStr = try? await network.getString(from: listUrl) {
                let fallback = (try? parseVideoList(listStr, sourceKey: sourceBean.key, type: sourceBean.type)) ?? []
                if !fallback.isEmpty {
                    homeVideos = fallback
                }
            }
        }
        
        return (sorts, homeVideos)
    }
    
    private func parseSort(_ jsonStr: String, sourceBean: SourceBean) throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        var sorts: [MovieSort.SortData] = []
        var homeVideos: [Movie.Video] = []
        
        if sourceBean.type == 0 {
            // XML 格式
            sorts = parseXMLCategories(from: jsonStr)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 解析分类
                if let classList = json["class"] as? [[String: Any]] {
                    for cls in classList {
                        let id: String
                        if let intId = cls["type_id"] as? Int {
                            id = String(intId)
                        } else {
                            id = cls["type_id"] as? String ?? ""
                        }
                        let name = cls["type_name"] as? String ?? ""
                        sorts.append(MovieSort.SortData(id: id, name: name))
                    }
                }
                
                // 解析首页推荐视频
                if let list = json["list"] as? [[String: Any]] {
                    for item in list {
                        let decoder = JSONDecoder()
                        if let itemData = try? JSONSerialization.data(withJSONObject: item),
                           var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                            video.sourceKey = sourceBean.key
                            homeVideos.append(video)
                        }
                    }
                }
            }
        }
        
        return (sorts, homeVideos)
    }
    
    private func parseXMLCategories(from xml: String) -> [MovieSort.SortData] {
        // 简化的 XML 分类解析
        var sorts: [MovieSort.SortData] = []
        let pattern = "<ty id=\"(\\d+)\"[^>]*>([^<]+)</ty>"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xml),
                   let nameRange = Range(match.range(at: 2), in: xml) {
                    let id = String(xml[idRange])
                    let name = String(xml[nameRange])
                    sorts.append(MovieSort.SortData(id: id, name: name))
                }
            }
        }
        return sorts
    }
    
    // MARK: - 获取分类视频列表
    
    /// 获取分类下的视频列表
    func getList(sourceBean: SourceBean, sortData: MovieSort.SortData, page: Int = 1, filters: [String: String]? = nil) async throws -> [Movie.Video] {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            // XML 接口
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "t", value: sortData.id),
                    URLQueryItem(name: "pg", value: String(page))
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "filter", value: "true"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]
            
            // 附加筛选参数（base64 编码）
            if let filters = filters, !filters.isEmpty {
                if let filterData = try? JSONSerialization.data(withJSONObject: filters),
                   let filterStr = String(data: filterData, encoding: .utf8) {
                    let ext = Data(filterStr.utf8).base64EncodedString()
                    queryItems.append(URLQueryItem(name: "ext", value: ext))
                }
            } else {
                let ext = Data("{}".utf8).base64EncodedString()
                queryItems.append(URLQueryItem(name: "ext", value: ext))
            }
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "videolist"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]
            
            // 附加筛选参数
            if let filters = filters {
                for (key, value) in filters {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        }
        
        let jsonStr = try await network.getString(from: url)
        return try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
    }
    
    private func parseVideoList(_ jsonStr: String, sourceKey: String, type: Int) throws -> [Movie.Video] {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        var videos: [Movie.Video] = []
        
        if type == 0 {
            videos = parseXMLVideoList(from: jsonStr, sourceKey: sourceKey)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]] {
                let decoder = JSONDecoder()
                for item in list {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                        video.sourceKey = sourceKey
                        videos.append(video)
                    }
                }
            }
        }
        
        return videos
    }
    
    private func parseXMLVideoList(from xml: String, sourceKey: String) -> [Movie.Video] {
        // 简化 XML 视频列表解析
        var videos: [Movie.Video] = []
        let pattern = "<video>.*?<id>(\\d+)</id>.*?<name><!\\[CDATA\\[(.+?)\\]\\]></name>.*?<pic>(.*?)</pic>.*?<note><!\\[CDATA\\[(.*?)\\]\\]></note>.*?</video>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                var video = Movie.Video()
                if let r = Range(match.range(at: 1), in: xml) { video.id = String(xml[r]) }
                if let r = Range(match.range(at: 2), in: xml) { video.name = String(xml[r]) }
                if let r = Range(match.range(at: 3), in: xml) { video.pic = String(xml[r]) }
                if let r = Range(match.range(at: 4), in: xml) { video.note = String(xml[r]) }
                video.sourceKey = sourceKey
                videos.append(video)
            }
        }
        return videos
    }
    
    // MARK: - 获取详情
    
    /// 获取视频详情
    func getDetail(sourceBean: SourceBean, vodId: String) async throws -> VodInfo? {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "ids", value: vodId)
            ]
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        }
        
        let jsonStr = try await network.getString(from: url)
        return try parseDetail(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
    }
    
    private func parseDetail(_ jsonStr: String, sourceKey: String, type: Int) throws -> VodInfo? {
        if type == 0 {
            return parseXMLDetail(jsonStr, sourceKey: sourceKey)
        }
        
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]],
           let first = list.first {
            
            let decoder = JSONDecoder()
            if let itemData = try? JSONSerialization.data(withJSONObject: first),
               var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                video.sourceKey = sourceKey
                
                let playFrom = first["vod_play_from"] as? String ?? ""
                let playUrl = first["vod_play_url"] as? String ?? ""
                
                return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
            }
        }
        
        return nil
    }
    
    // MARK: - 搜索
    
    /// 在指定源中搜索
    func search(sourceBean: SourceBean, keyword: String) async throws -> [Movie.Video] {
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            let quickValue = sourceBean.isQuickSearchEnabled ? "true" : "false"
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "wd", value: keyword),
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "quick", value: quickValue)
            ]
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        }
        
        let jsonStr = try await network.getString(from: url)
        let videos = try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
        return filterSearchResults(videos, keyword: keyword)
    }
    
    /// 多源并发搜索
    func searchAll(keyword: String) async -> [Movie.Video] {
        let sources = await ApiConfig.shared.getSearchableSources()
        
        return await withTaskGroup(of: [Movie.Video].self) { group in
            for source in sources {
                // 跳过不支持的源类型
                guard source.isSupportedInSwift && source.isHttpApi else { continue }
                
                group.addTask { [self] in
                    do {
                        return try await self.search(sourceBean: source, keyword: keyword)
                    } catch {
                        return []
                    }
                }
            }
            
            var allResults: [Movie.Video] = []
            for await results in group {
                allResults.append(contentsOf: results)
            }
            return allResults
        }
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
    
    // MARK: - Extend 解析
    
    /// 解析 extend 参数（对应 Android 端 getFixUrl）
    /// 如果 extend 是 HTTP URL，则下载其内容作为 extend 值
    /// 如果 extend 是普通字符串，则直接返回
    private func resolveExtend(_ extend: String) async -> String {
        guard !extend.isEmpty else { return "" }
        
        // 非 HTTP URL 直接返回
        guard extend.hasPrefix("http://") || extend.hasPrefix("https://") else {
            return extend
        }
        
        // 从 HTTP URL 加载 extend 内容
        do {
            let content = try await network.getString(from: extend)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            if trimmed.count > 2500 { return extend }
            return trimmed
        } catch {
            return extend
        }
    }

    private func parseXMLDetail(_ xml: String, sourceKey: String) -> VodInfo? {
        guard let videoBlock = firstMatch(
            pattern: #"<video[\s\S]*?</video>"#,
            in: xml
        ) else {
            return nil
        }
        
        let vodId = extractXMLTag("id", in: videoBlock)
        guard !vodId.isEmpty else { return nil }
        
        var video = Movie.Video(id: vodId)
        video.name = extractXMLTag("name", in: videoBlock)
        video.pic = extractXMLTag("pic", in: videoBlock)
        video.note = extractXMLTag("note", in: videoBlock)
        video.year = extractXMLTag("year", in: videoBlock)
        video.area = extractXMLTag("area", in: videoBlock)
        video.type = extractXMLTag("type", in: videoBlock)
        video.director = extractXMLTag("director", in: videoBlock)
        video.actor = extractXMLTag("actor", in: videoBlock)
        video.des = extractXMLTag("des", in: videoBlock)
        video.sourceKey = sourceKey
        
        let ddNodes = extractXMLDDNodes(from: videoBlock)
        let playFrom: String
        let playUrl: String
        
        if ddNodes.isEmpty {
            playFrom = "默认"
            playUrl = ""
        } else {
            playFrom = ddNodes.map { $0.flag }.joined(separator: "$$$")
            playUrl = ddNodes.map { $0.url }.joined(separator: "$$$")
        }
        
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }
    
    private func extractXMLDDNodes(from block: String) -> [(flag: String, url: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<dd([^>]*)>([\s\S]*?)</dd>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        
        let nsRange = NSRange(block.startIndex..<block.endIndex, in: block)
        let matches = regex.matches(in: block, range: nsRange)
        var result: [(flag: String, url: String)] = []
        
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            guard let attrRange = Range(match.range(at: 1), in: block),
                  let valueRange = Range(match.range(at: 2), in: block) else {
                continue
            }
            
            let attrs = String(block[attrRange])
            let rawUrl = decodeXMLText(String(block[valueRange]))
            guard !rawUrl.isEmpty else { continue }
            
            let flag = firstMatch(
                pattern: #"flag\s*=\s*["']([^"']+)["']"#,
                in: attrs,
                captureGroup: 1
            ) ?? "线路\(index + 1)"
            result.append((flag: decodeXMLText(flag), url: rawUrl))
        }
        
        return result
    }
    
    private func extractXMLTag(_ tag: String, in content: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)>\\s*([\\s\\S]*?)\\s*</\(escapedTag)>"
        let value = firstMatch(pattern: pattern, in: content, captureGroup: 1) ?? ""
        return decodeXMLText(value)
    }
    
    private func firstMatch(pattern: String, in content: String, captureGroup: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > captureGroup,
              let subRange = Range(match.range(at: captureGroup), in: content) else {
            return nil
        }
        return String(content[subRange])
    }
    
    private func decodeXMLText(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>"), value.count >= 12 {
            value.removeFirst(9)
            value.removeLast(3)
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func buildURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }
        
        var mergedQueryItems = components.queryItems ?? []
        mergedQueryItems.append(contentsOf: queryItems)
        components.queryItems = mergedQueryItems
        
        guard let url = components.url else {
            throw SourceError.invalidApiUrl(base)
        }
        return url.absoluteString
    }
}

enum SourceError: LocalizedError {
    case emptyApi
    case parseError(String)
    case unsupportedType(String)
    case invalidApiUrl(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyApi: return "接口地址为空"
        case .parseError(let msg): return "数据解析错误: \(msg)"
        case .unsupportedType(let type): return "暂不支持 \(type) 类型的数据源，请切换其他源"
        case .invalidApiUrl(let url): return "无效的接口地址: \(url)"
        }
    }
}
