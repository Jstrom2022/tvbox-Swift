import Foundation

/// 核心配置管理器 - 对应 Android 版 ApiConfig.java
/// 负责加载和解析远程 JSON 配置，管理视频源列表
@MainActor
class ApiConfig: ObservableObject {
    static let shared = ApiConfig()
    private static let maxConfigResolveDepth = 6
    private static let maxRedirectCandidates = 20
    private static let rawConfigCacheTTL: TimeInterval = 20
    private static let maxRawConfigCacheEntries = 24
    
    struct MultiRepoOption: Identifiable, Equatable {
        let name: String
        let url: String
        
        var id: String { url.lowercased() }
    }
    
    @Published var sourceBeanList: [SourceBean] = []
    @Published var homeSourceBean: SourceBean?
    @Published var parseBeanList: [ParseBean] = []
    @Published var liveChannelGroupList: [LiveChannelGroup] = []
    @Published var dohList: [(name: String, url: String)] = []
    @Published var isLoaded: Bool = false
    @Published var configUrl: String = ""
    @Published var liveConfigUrl: String = ""
    @Published var wallpaper: String = ""
    
    private let network = NetworkManager.shared
    private var activeLoadToken = UUID()
    private var liveParseTask: Task<Void, Never>?
    private struct RawConfigCacheEntry {
        let content: String
        let fetchedAt: Date
    }
    private var rawConfigCache: [String: RawConfigCacheEntry] = [:]
    
    private init() {}
    
    /// 加载远程配置
    func loadConfig(from apiUrl: String) async throws {
        try await loadConfigs(vodApiUrl: apiUrl, liveApiUrl: apiUrl)
    }
    
    /// 分别加载点播配置和直播配置
    func loadConfigs(vodApiUrl: String, liveApiUrl: String) async throws {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            throw ConfigError.parseError("点播接口地址不能为空")
        }
        let loadToken = UUID()
        activeLoadToken = loadToken
        liveParseTask?.cancel()
        liveParseTask = nil
        
        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
        self.configUrl = trimmedVod
        self.liveConfigUrl = resolvedLive
        
        if trimmedVod == resolvedLive {
            let configResult = try await fetchConfig(from: trimmedVod)
            guard activeLoadToken == loadToken else { return }
            await parseConfig(
                configResult.config,
                apiUrl: configResult.loadedFrom,
                includeSources: true,
                includeLive: false,
                loadToken: loadToken
            )
            scheduleLiveParsing(
                config: configResult.config,
                apiUrl: configResult.loadedFrom,
                loadToken: loadToken
            )
        } else {
            async let vodConfigTask = fetchConfig(from: trimmedVod)
            async let liveConfigTask = fetchConfig(from: resolvedLive)
            let (vodConfig, liveConfig) = try await (vodConfigTask, liveConfigTask)
            guard activeLoadToken == loadToken else { return }
            await parseConfig(
                vodConfig.config,
                apiUrl: vodConfig.loadedFrom,
                includeSources: true,
                includeLive: false,
                loadToken: loadToken
            )
            scheduleLiveParsing(
                config: liveConfig.config,
                apiUrl: liveConfig.loadedFrom,
                loadToken: loadToken
            )
        }
        guard activeLoadToken == loadToken else { return }
        
        self.isLoaded = true
    }

    /// 直播分组改为后台解析，避免阻塞首页首屏进入。
    private func scheduleLiveParsing(config: AppConfigData, apiUrl: String, loadToken: UUID) {
        liveParseTask?.cancel()
        liveParseTask = Task { [config, apiUrl] in
            await parseConfig(
                config,
                apiUrl: apiUrl,
                includeSources: false,
                includeLive: true,
                loadToken: loadToken
            )
        }
    }
    
    private func fetchConfig(from apiUrl: String) async throws -> (config: AppConfigData, loadedFrom: String) {
        try await fetchConfig(
            from: apiUrl,
            visitedUrls: Set<String>(),
            depth: 0
        )
    }
    
    private func fetchConfig(
        from apiUrl: String,
        visitedUrls: Set<String>,
        depth: Int
    ) async throws -> (config: AppConfigData, loadedFrom: String) {
        guard depth <= Self.maxConfigResolveDepth else {
            throw ConfigError.parseError("配置跳转层级过深（超过 \(Self.maxConfigResolveDepth) 层）")
        }
        
        let normalizedUrl = Self.normalizeConfigUrl(apiUrl)
        guard !normalizedUrl.isEmpty else {
            throw ConfigError.parseError("配置地址为空")
        }
        
        let visitKey = normalizedUrl.lowercased()
        guard !visitedUrls.contains(visitKey) else {
            throw ConfigError.parseError("检测到循环引用的配置地址: \(normalizedUrl)")
        }
        
        var nextVisited = visitedUrls
        nextVisited.insert(visitKey)
        
        let jsonStr = try await fetchConfigText(from: normalizedUrl)
        
        // 清理非标准 JSON（Android 端 Gson 默认支持注释，Swift 需要手动处理）
        let cleanedJson = Self.stripJsonComments(jsonStr)
        
        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }
        
        let decoder = JSONDecoder()
        let decodedConfig = try? decoder.decode(AppConfigData.self, from: data)
        if let config = decodedConfig, config.hasUsableContent {
            return (config, normalizedUrl)
        }
        
        if let multiRepo = try? decoder.decode(MultiRepoConfigData.self, from: data) {
            let candidateUrls = Self.uniqueUrlsInOrder(
                multiRepo.candidateUrls.map(Self.normalizeConfigUrl)
            )
            
            var lastError: Error?
            for candidateUrl in candidateUrls {
                do {
                    return try await fetchConfig(
                        from: candidateUrl,
                        visitedUrls: nextVisited,
                        depth: depth + 1
                    )
                } catch {
                    lastError = error
                }
            }
            
            if let lastError {
                throw ConfigError.parseError("多仓库配置中没有可用地址，最后错误: \(lastError.localizedDescription)")
            }
            throw ConfigError.parseError("多仓库配置中没有可用地址")
        }
        
        let redirectCandidates = Self.extractConfigRedirectCandidates(from: cleanedJson)
            .filter { $0.lowercased() != visitKey && !nextVisited.contains($0.lowercased()) }
        
        if !redirectCandidates.isEmpty {
            var lastError: Error?
            for candidate in redirectCandidates {
                do {
                    return try await fetchConfig(
                        from: candidate,
                        visitedUrls: nextVisited,
                        depth: depth + 1
                    )
                } catch {
                    lastError = error
                }
            }
            
            if let lastError {
                throw ConfigError.parseError("页面跳转配置解析失败，最后错误: \(lastError.localizedDescription)")
            }
        }
        
        if decodedConfig != nil {
            throw ConfigError.parseError("配置缺少可用站点（sites / lives / parses）")
        }
        
        throw ConfigError.parseError("配置格式不受支持")
    }
    
    /// 读取配置文本并做短时缓存，避免“多仓探测 + 正式加载”重复请求同一地址。
    private func fetchConfigText(from normalizedUrl: String) async throws -> String {
        let key = normalizedUrl.lowercased()
        let now = Date()
        
        if let entry = rawConfigCache[key] {
            if now.timeIntervalSince(entry.fetchedAt) <= Self.rawConfigCacheTTL {
                return entry.content
            }
            rawConfigCache.removeValue(forKey: key)
        }
        
        let content = try await network.getString(from: normalizedUrl)
        rawConfigCache[key] = RawConfigCacheEntry(content: content, fetchedAt: now)
        trimRawConfigCacheIfNeeded()
        return content
    }
    
    private func trimRawConfigCacheIfNeeded() {
        guard rawConfigCache.count > Self.maxRawConfigCacheEntries else { return }
        let overflow = rawConfigCache.count - Self.maxRawConfigCacheEntries
        let staleKeys = rawConfigCache
            .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(overflow)
            .map(\.key)
        staleKeys.forEach { rawConfigCache.removeValue(forKey: $0) }
    }
    
    private static func uniqueUrlsInOrder(_ urls: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        
        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        
        return result
    }
    
    /// 从网页/文本中提取可能的配置地址：
    /// - 明文 URL 文本
    /// - data-clipboard-text（常见导航页“点击复制”）
    /// - JSON 片段中的 url 字段
    private static func extractConfigRedirectCandidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawCandidates: [String] = []
        
        if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !trimmed.contains("\n") {
            rawCandidates.append(trimmed)
        }
        
        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #"data-clipboard-text\s*=\s*["']([^"']+)["']"#,
            in: content
        ))
        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #""url"\s*:\s*"([^"]+)""#,
            in: content
        ))
        rawCandidates.append(contentsOf: matchCaptureGroup(
            pattern: #"(https?://[^\s"'<>\\]+)"#,
            in: content
        ))
        
        let normalized = rawCandidates
            .map(sanitizeExtractedUrl)
            .map(normalizeConfigUrl)
            .filter { !$0.isEmpty }
            .filter(isLikelyConfigPointerUrl)
            .filter { !isLikelyBinaryAssetUrl($0) }
        
        return Array(uniqueUrlsInOrder(normalized).prefix(maxRedirectCandidates))
    }
    
    private static func matchCaptureGroup(pattern: String, in content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        
        return matches.compactMap { match in
            guard match.numberOfRanges >= 2,
                  let subRange = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[subRange])
        }
    }
    
    private static func sanitizeExtractedUrl(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "\\/", with: "/")
        
        while let last = result.last, [".", ",", ";", ")", "]", "}", "\"", "'"].contains(last) {
            result.removeLast()
        }
        while let first = result.first, ["\"", "'", "(", "[", "{"].contains(first) {
            result.removeFirst()
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func isLikelyBinaryAssetUrl(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        let path = components.path.lowercased()
        return path.hasSuffix(".png")
            || path.hasSuffix(".jpg")
            || path.hasSuffix(".jpeg")
            || path.hasSuffix(".webp")
            || path.hasSuffix(".gif")
            || path.hasSuffix(".svg")
            || path.hasSuffix(".ico")
            || path.hasSuffix(".css")
            || path.hasSuffix(".woff")
            || path.hasSuffix(".woff2")
            || path.hasSuffix(".ttf")
    }
    
    private static func isLikelyConfigPointerUrl(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else { return false }
        
        let host = (components.host ?? "").lowercased()
        let path = components.path.lowercased()
        let query = (components.percentEncodedQuery ?? "").lowercased()
        
        if host.contains("raw.githubusercontent.com") || host.contains("githubusercontent.com") {
            return true
        }
        
        if path.contains(".json")
            || path.hasSuffix("/tv")
            || path.hasSuffix("/tv/")
            || path.hasSuffix("/m")
            || path.hasSuffix("/m/")
            || path.contains("tvbox")
            || path.contains("box")
            || query.contains("json")
            || query.contains("config")
            || query.contains("url=") {
            return true
        }
        
        return false
    }
    
    /// 统一规范配置 URL：
    /// 1) 修正 https:/xxx 之类的单斜杠写法；
    /// 2) 将 github.com/.../blob/... 转为 raw.githubusercontent.com/...；
    /// 3) 兼容 gh-proxy + github/blob 的嵌套代理地址。
    static func normalizeConfigUrl(_ rawUrl: String) -> String {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        
        let fixedScheme = fixMalformedSchemeIfNeeded(trimmed)
        
        if let normalizedProxy = normalizeGhProxyWrappedUrl(fixedScheme) {
            return normalizedProxy
        }
        
        if let githubRaw = convertGitHubBlobUrlToRaw(fixedScheme) {
            return githubRaw
        }
        
        return fixedScheme
    }
    
    private static func fixMalformedSchemeIfNeeded(_ urlString: String) -> String {
        let fixedHttps = urlString.replacingOccurrences(
            of: #"^https:/(?!/)"#,
            with: "https://",
            options: .regularExpression
        )
        return fixedHttps.replacingOccurrences(
            of: #"^http:/(?!/)"#,
            with: "http://",
            options: .regularExpression
        )
    }
    
    private static func normalizeGhProxyWrappedUrl(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host.contains("gh-proxy") else {
            return nil
        }
        
        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        
        let decodedPath = path.removingPercentEncoding ?? path
        let fixedEmbedded = fixMalformedSchemeIfNeeded(decodedPath)
        guard fixedEmbedded.hasPrefix("http://") || fixedEmbedded.hasPrefix("https://") else {
            return nil
        }
        
        let normalizedEmbedded = convertGitHubBlobUrlToRaw(fixedEmbedded) ?? fixedEmbedded
        let scheme = components.scheme ?? "https"
        let portSuffix = components.port.map { ":\($0)" } ?? ""
        
        var rebuilt = "\(scheme)://\(host)\(portSuffix)/\(normalizedEmbedded)"
        if let query = components.percentEncodedQuery, !query.isEmpty {
            rebuilt += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            rebuilt += "#\(fragment)"
        }
        return rebuilt
    }
    
    private static func convertGitHubBlobUrlToRaw(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[2] == "blob" else {
            return nil
        }
        
        let owner = String(parts[0])
        let repo = String(parts[1])
        let branch = String(parts[3])
        let filePath = parts.dropFirst(4).joined(separator: "/")
        guard !filePath.isEmpty else {
            return nil
        }
        
        var rawUrl = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(filePath)"
        if let query = components.percentEncodedQuery, !query.isEmpty {
            rawUrl += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            rawUrl += "#\(fragment)"
        }
        return rawUrl
    }
    
    /// 去除 JSON 中的 // 行注释，兼容 TVBox 配置文件格式
    /// Android 端 Gson 原生支持注释，Swift 的 JSONDecoder 不支持
    static func stripJsonComments(_ json: String) -> String {
        let lines = json.components(separatedBy: "\n")
        var result: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过纯注释行（以 // 开头）
            if trimmed.hasPrefix("//") {
                continue
            }
            // 处理行尾注释：只在引号外的 // 才是注释
            let cleaned = removeInlineComment(from: line)
            result.append(cleaned)
        }
        
        var joined = result.joined(separator: "\n")
        
        // 修复尾部逗号问题：,] 或 ,} （注释行被删除后可能产生）
        // 使用正则替换 , 后面跟着空白和 ] 或 } 的情况
        joined = joined.replacingOccurrences(
            of: ",\\s*([\\]\\}])",
            with: "$1",
            options: .regularExpression
        )
        
        return joined
    }
    
    /// 移除行内注释（只处理不在字符串内的 //）
    private static func removeInlineComment(from line: String) -> String {
        var inString = false
        var escape = false
        let chars = Array(line)
        
        for i in 0..<chars.count {
            let c = chars[i]
            if escape {
                escape = false
                continue
            }
            if c == "\\" && inString {
                escape = true
                continue
            }
            if c == "\"" {
                inString.toggle()
                continue
            }
            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                // 找到行内注释，截断
                return String(chars[0..<i]).trimmingCharacters(in: .whitespaces).hasSuffix(",")
                    ? String(String(chars[0..<i]).trimmingCharacters(in: .whitespaces).dropLast())
                    : String(chars[0..<i])
            }
        }
        return line
    }
    
    /// 仅探测“多仓库入口”并返回可选项。
    /// 返回 nil 表示不是多仓库入口；返回数组表示是多仓库入口（数组可能为空）。
    func fetchMultiRepoOptions(from apiUrl: String) async throws -> [MultiRepoOption]? {
        let normalizedUrl = Self.normalizeConfigUrl(apiUrl)
        let jsonStr = try await fetchConfigText(from: normalizedUrl)
        let cleanedJson = Self.stripJsonComments(jsonStr)
        
        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }
        
        let decoder = JSONDecoder()
        if let config = try? decoder.decode(AppConfigData.self, from: data), config.hasUsableContent {
            return nil
        }
        
        guard let multiRepo = try? decoder.decode(MultiRepoConfigData.self, from: data) else {
            return nil
        }
        
        let normalizedCandidates = Self.uniqueUrlsInOrder(
            multiRepo.candidateUrls.map(Self.normalizeConfigUrl)
        )
        
        var options: [MultiRepoOption] = []
        for candidate in normalizedCandidates {
            let matchedEntry = multiRepo.urls?.first(where: {
                Self.normalizeConfigUrl($0.url ?? "") == candidate
            })
            let displayName = matchedEntry?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = URL(string: candidate)?.host ?? candidate
            let resolvedName: String
            if let displayName, !displayName.isEmpty {
                resolvedName = displayName
            } else {
                resolvedName = fallbackName
            }
            options.append(
                MultiRepoOption(
                    name: resolvedName,
                    url: candidate
                )
            )
        }
        
        return options
    }
    
    /// 解析配置数据
    private func parseConfig(
        _ config: AppConfigData,
        apiUrl: String,
        includeSources: Bool,
        includeLive: Bool,
        loadToken: UUID
    ) async {
        guard activeLoadToken == loadToken else { return }
        
        if includeSources {
            // 解析站点列表
            var sources: [SourceBean] = []
            if let sites = config.sites {
                for site in sites {
                    let bean = SourceBean(
                        key: site.key ?? UUID().uuidString,
                        name: site.name ?? "未命名",
                        api: site.api ?? "",
                        searchable: site.searchable?.value ?? 1,
                        filterable: site.filterable?.value ?? 1,
                        quickSearch: site.quickSearch?.value ?? 0,
                        playerType: site.playerType?.value ?? 0,
                        type: site.type?.value ?? 1,
                        ext: site.ext?.stringValue
                    )
                    sources.append(bean)
                }
            }
            self.sourceBeanList = sources
            
            // 设置默认主页源：优先选择 Swift 支持的源
            if let saved = UserDefaults.standard.string(forKey: HawkConfig.HOME_API),
               let found = sources.first(where: { $0.key == saved }) {
                self.homeSourceBean = found
            } else {
                // 优先选择支持的源（type 0/1/4），跳过 type=3 (JAR)
                self.homeSourceBean = sources.first(where: { $0.isSupportedInSwift }) ?? sources.first
            }
            
            // 解析解析器列表
            if let parses = config.parses {
                self.parseBeanList = parses.map { p in
                    ParseBean(name: p.name ?? "", url: p.url ?? "", type: p.type?.value ?? 0)
                }
            } else {
                self.parseBeanList = []
            }
            
            // 解析 DoH 列表
            if let dohs = config.doh {
                self.dohList = dohs.compactMap { d in
                    guard let name = d.name, let url = d.url else { return nil }
                    return (name: name, url: url)
                }
            } else {
                self.dohList = []
            }
            
            // 壁纸
            self.wallpaper = config.wallpaper ?? ""
        }
        
        if includeLive {
            if let lives = config.lives {
                let parsedGroups = await parseLives(lives, apiUrl: apiUrl, loadToken: loadToken)
                guard activeLoadToken == loadToken else { return }
                liveChannelGroupList = parsedGroups
            } else {
                liveChannelGroupList = []
            }
        }
    }
    
    /// 解析直播列表
    private func parseLives(
        _ lives: [AppConfigData.LiveConfig],
        apiUrl: String,
        loadToken: UUID
    ) async -> [LiveChannelGroup] {
        var mergedGroups: [String: LiveChannelGroup] = [:]
        var remoteLiveTargets: [(order: Int, url: String)] = []
        
        for (index, live) in lives.enumerated() {
            guard activeLoadToken == loadToken else { return [] }
            
            // 如果有 url，从远程加载
            if let liveUrl = live.url, !liveUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let resolvedUrl = resolveLiveUrl(liveUrl, baseConfigUrl: apiUrl)
                remoteLiveTargets.append((order: index, url: resolvedUrl))
            }
            
            // 如果有内嵌频道
            if let channels = live.channels {
                let inlineGroups = parseInlineLiveChannels(channels)
                mergeLiveGroups(inlineGroups, into: &mergedGroups)
            }
        }
        
        if !remoteLiveTargets.isEmpty {
            let fetchedContents = await withTaskGroup(
                of: (Int, String?).self,
                returning: [(Int, String)].self
            ) { group in
                for target in remoteLiveTargets {
                    group.addTask {
                        do {
                            let content = try await NetworkManager.shared.getString(from: target.url)
                            return (target.order, content)
                        } catch {
                            print("加载直播源失败: \(target.url), error: \(error)")
                            return (target.order, nil)
                        }
                    }
                }
                
                var results: [(Int, String)] = []
                for await (order, content) in group {
                    if let content {
                        results.append((order, content))
                    }
                }
                return results
            }
            
            for (_, content) in fetchedContents.sorted(by: { $0.0 < $1.0 }) {
                guard activeLoadToken == loadToken else { return [] }
                let groups = parseLiveContent(content)
                mergeLiveGroups(groups, into: &mergedGroups)
                liveChannelGroupList = sortedGroups(from: mergedGroups)
            }
        }
        
        return sortedGroups(from: mergedGroups)
    }
    
    /// 解析 m3u / txt 格式的直播内容
    private func parseLiveContent(_ content: String) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        var currentGroupName = "默认"
        
        let lines = content.components(separatedBy: .newlines)
        let firstNonEmptyLine = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isM3U = firstNonEmptyLine?.uppercased().hasPrefix("#EXTM3U") == true
        
        // 检测是否为 M3U 格式
        if isM3U {
            var currentName = ""
            var currentGroup = "默认"
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#EXTINF:") {
                    // 解析频道名和分组
                    if let nameRange = trimmed.range(of: ",", options: .backwards) {
                        currentName = String(trimmed[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    currentGroup = "默认"
                    if let groupMatch = trimmed.range(of: "group-title=\"") {
                        let afterGroup = trimmed[groupMatch.upperBound...]
                        if let endQuote = afterGroup.firstIndex(of: "\"") {
                            currentGroup = String(afterGroup[..<endQuote])
                        }
                    }
                } else if Self.isLiveStreamUrl(trimmed) {
                    if !currentName.isEmpty {
                        appendChannel(
                            named: currentName,
                            urls: [trimmed],
                            logo: "",
                            to: currentGroup,
                            groups: &groups
                        )
                        currentName = ""
                    }
                }
            }
        } else {
            // TXT 格式: 分组名,#genre#  或  频道名,url
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                
                if trimmed.hasSuffix(",#genre#") || trimmed.hasSuffix("，#genre#") {
                    currentGroupName = trimmed
                        .replacingOccurrences(of: ",#genre#", with: "")
                        .replacingOccurrences(of: "，#genre#", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                
                let parts = trimmed.components(separatedBy: ",")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    let url = parts[1...].joined(separator: ",").trimmingCharacters(in: .whitespaces)
                    
                    if !name.isEmpty && Self.isLiveStreamUrl(url) {
                        appendChannel(
                            named: name,
                            urls: [url],
                            logo: "",
                            to: currentGroupName,
                            groups: &groups
                        )
                    }
                }
            }
        }
        
        return sortedGroups(from: groups)
    }
    
    private func parseInlineLiveChannels(_ channels: [AppConfigData.LiveConfig.LiveChannelConfig]) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        for channel in channels {
            appendChannel(
                named: channel.name ?? "",
                urls: channel.urls ?? [],
                logo: channel.logo ?? "",
                to: channel.group ?? "其他",
                groups: &groups
            )
        }
        return sortedGroups(from: groups)
    }
    
    private func mergeLiveGroups(_ incomingGroups: [LiveChannelGroup], into groups: inout [String: LiveChannelGroup]) {
        for group in incomingGroups {
            for channel in group.channels {
                appendChannel(
                    named: channel.channelName,
                    urls: channel.channelUrls,
                    logo: channel.logo,
                    to: group.groupName,
                    groups: &groups
                )
            }
        }
    }
    
    private func appendChannel(
        named channelName: String,
        urls: [String],
        logo: String,
        to groupName: String,
        groups: inout [String: LiveChannelGroup]
    ) {
        let normalizedName = Self.normalizeChannelName(channelName)
        guard !normalizedName.isEmpty else { return }
        
        let validUrls = Self.uniqueLiveUrls(urls)
        guard !validUrls.isEmpty else { return }
        
        let normalizedGroupName = Self.normalizeGroupName(groupName)
        if groups[normalizedGroupName] == nil {
            groups[normalizedGroupName] = LiveChannelGroup(
                groupName: normalizedGroupName,
                groupIndex: groups.count
            )
        }
        
        guard var group = groups[normalizedGroupName] else { return }
        
        if let existingIndex = group.channels.firstIndex(where: {
            Self.normalizeChannelName($0.channelName) == normalizedName
        }) {
            var existing = group.channels[existingIndex]
            var existingUrls = Set(existing.channelUrls.map(Self.normalizeLiveUrl))
            for url in validUrls {
                let normalizedUrl = Self.normalizeLiveUrl(url)
                if !existingUrls.contains(normalizedUrl) {
                    existing.channelUrls.append(url)
                    existingUrls.insert(normalizedUrl)
                }
            }
            let trimmedLogo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.logo.isEmpty && !trimmedLogo.isEmpty {
                existing.logo = trimmedLogo
            }
            group.channels[existingIndex] = existing
        } else {
            var item = LiveChannelItem(channelName: normalizedName, channelIndex: group.channels.count)
            item.channelUrls = validUrls
            item.logo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            group.channels.append(item)
        }
        
        groups[normalizedGroupName] = group
    }
    
    private func sortedGroups(from groups: [String: LiveChannelGroup]) -> [LiveChannelGroup] {
        groups.values
            .sorted { $0.groupIndex < $1.groupIndex }
            .map { group in
                var reindexedGroup = group
                reindexedGroup.channels = group.channels.enumerated().map { index, channel in
                    var reindexedChannel = channel
                    reindexedChannel.channelIndex = index
                    return reindexedChannel
                }
                return reindexedGroup
            }
    }
    
    private func resolveLiveUrl(_ urlString: String, baseConfigUrl: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil {
            return Self.normalizeConfigUrl(trimmed)
        }
        guard let baseUrl = URL(string: baseConfigUrl),
              let resolved = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL else {
            return trimmed
        }
        return Self.normalizeConfigUrl(resolved.absoluteString)
    }
    
    private static func uniqueLiveUrls(_ urls: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        
        for url in urls {
            let normalized = normalizeLiveUrl(url)
            guard !normalized.isEmpty, isLiveStreamUrl(normalized), !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        
        return result
    }
    
    private static func normalizeGroupName(_ groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "默认" : trimmed
    }
    
    private static func normalizeChannelName(_ channelName: String) -> String {
        channelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func normalizeLiveUrl(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func isLiveStreamUrl(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("rtmp://")
            || lowercased.hasPrefix("rtsp://")
    }
    
    /// 获取指定 key 的源
    func getSource(key: String) -> SourceBean? {
        sourceBeanList.first(where: { $0.key == key })
    }
    
    /// 获取可搜索的源列表
    func getSearchableSources() -> [SourceBean] {
        sourceBeanList.filter { $0.isSearchable }
    }
    
    /// 设置主页源
    func setHomeSource(_ source: SourceBean) {
        self.homeSourceBean = source
        UserDefaults.standard.set(source.key, forKey: HawkConfig.HOME_API)
    }
}

enum ConfigError: LocalizedError {
    case parseError(String)
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "配置解析错误: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}
