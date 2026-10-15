import Foundation

/// 核心配置管理器 - 对应 Android 版 ApiConfig.java
/// 负责加载和解析远程 JSON 配置，管理视频源列表
@MainActor
class ApiConfig: ObservableObject {
    static let shared = ApiConfig()
    nonisolated private static let maxConfigResolveDepth = 6
    nonisolated private static let maxRedirectCandidates = 20
    nonisolated private static let rawConfigCacheTTL: TimeInterval = 20
    nonisolated private static let maxRawConfigCacheEntries = 24
    nonisolated private static let maxConcurrentLiveDownloads = 4

    struct MultiRepoOption: Identifiable, Equatable {
        let name: String
        let url: String

        var id: String { urlIdentity(url) }
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
    /// 已成功解析的配置版本号，每次提交配置后自增，供页面判断是否需要重新加载。
    @Published private(set) var configVersion: Int = 0
    /// 是否有直播列表正在下载/解析。
    @Published private(set) var isLoadingLives: Bool = false
    /// 最近一次直播列表加载中失败或没有频道的来源（用于展示部分失败与重试）。
    @Published private(set) var liveLoadFailures: [String] = []

    private let network = NetworkManager.shared
    private var activeLoadToken = UUID()
    /// 正在进行的配置加载令牌（加载结束后清空）。
    private var inFlightLoadToken: UUID?
    private var liveParseTask: Task<Void, Never>?
    private var activeLiveToken = UUID()
    private var liveConfig: AppConfigData?
    private var liveConfigBaseUrl: String = ""
    private struct RawConfigCacheEntry {
        let content: String
        let finalURL: String
        let fetchedAt: Date
    }
    private var rawConfigCache: [String: RawConfigCacheEntry] = [:]
    private struct LiveDownloadTarget: Sendable {
        let order: Int
        let url: String
        let userAgent: String?
    }
    private struct LiveDownloadResult: Sendable {
        let order: Int
        let url: String
        let groups: [LiveChannelGroup]
        let failure: String?
    }
    private struct LiveListParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init() {}

    /// 加载远程配置
    func loadConfig(from apiUrl: String) async throws {
        try await loadConfigs(vodApiUrl: apiUrl, liveApiUrl: apiUrl)
    }

    /// 分别加载点播配置和直播配置。
    /// 被更晚的请求取代时会抛出 `CancellationError`，调用方不得据此更新“成功”状态。
    func loadConfigs(vodApiUrl: String, liveApiUrl: String) async throws {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            throw ConfigError.parseError("点播接口地址不能为空")
        }
        let loadToken = UUID()
        activeLoadToken = loadToken
        inFlightLoadToken = loadToken
        defer {
            if inFlightLoadToken == loadToken {
                inFlightLoadToken = nil
            }
        }

        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive

        let vodResult: (config: AppConfigData, loadedFrom: String)
        let liveResult: (config: AppConfigData, loadedFrom: String)
        do {
            if Self.urlIdentity(trimmedVod) == Self.urlIdentity(resolvedLive) {
                let result = try await fetchConfig(from: trimmedVod)
                vodResult = result
                liveResult = result
            } else {
                async let vodConfigTask = fetchConfig(from: trimmedVod)
                async let liveConfigTask = fetchConfig(from: resolvedLive)
                let (vodConfig, liveConfig) = try await (vodConfigTask, liveConfigTask)
                vodResult = vodConfig
                liveResult = liveConfig
            }
        } catch {
            // 已被更新请求取代时，旧请求的失败同样不应展示给用户。
            try ensureStillCurrent(loadToken)
            throw error
        }

        // 提交阶段：只有当前请求可以写入配置状态，过期请求不得留下“已应用”的痕迹。
        try ensureStillCurrent(loadToken)
        configUrl = trimmedVod
        liveConfigUrl = resolvedLive
        applySources(config: vodResult.config)
        isLoaded = true
        configVersion &+= 1
        scheduleLiveParsing(
            config: liveResult.config,
            apiUrl: liveResult.loadedFrom,
            loadToken: loadToken
        )
    }

    /// 是否有配置加载正在进行（自动重试等后台入口应避免覆盖用户发起的加载）。
    var hasLoadInFlight: Bool {
        inFlightLoadToken != nil
    }

    /// 过期请求统一以取消处理，避免上层把它当成正常成功。
    private func ensureStillCurrent(_ loadToken: UUID) throws {
        guard activeLoadToken == loadToken else { throw CancellationError() }
    }

    /// 直播分组改为后台解析，避免阻塞首页首屏进入。
    private func scheduleLiveParsing(config: AppConfigData, apiUrl: String, loadToken: UUID) {
        guard activeLoadToken == loadToken else { return }
        liveParseTask?.cancel()
        let liveToken = UUID()
        activeLiveToken = liveToken
        liveConfig = config
        liveConfigBaseUrl = apiUrl
        isLoadingLives = true
        liveParseTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLives(config: config, apiUrl: apiUrl, liveToken: liveToken)
        }
    }

    /// 重新加载直播列表（用于部分失败后的重试），不重新拉取配置。
    func reloadLiveChannels() {
        guard let config = liveConfig else { return }
        scheduleLiveParsing(config: config, apiUrl: liveConfigBaseUrl, loadToken: activeLoadToken)
    }

    // MARK: - 配置获取

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

        let visitKey = Self.urlIdentity(normalizedUrl)
        guard !visitedUrls.contains(visitKey) else {
            throw ConfigError.parseError("检测到循环引用的配置地址: \(normalizedUrl)")
        }

        var nextVisited = visitedUrls
        nextVisited.insert(visitKey)

        let fetched = try await fetchConfigText(from: normalizedUrl)
        // 配置跳转后相对地址应以最终地址为基准。
        let resolvedUrl = fetched.finalURL.isEmpty ? normalizedUrl : fetched.finalURL
        nextVisited.insert(Self.urlIdentity(resolvedUrl))

        // 清理非标准 JSON（Android 端 Gson 默认支持注释，Swift 需要手动处理）
        let cleanedJson = Self.stripJsonComments(fetched.content)

        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }

        let decoder = JSONDecoder()
        let decodedConfig = try? decoder.decode(AppConfigData.self, from: data)
        if let config = decodedConfig, config.hasUsableContent {
            return (config, resolvedUrl)
        }

        // 只有确实存在 urls 数组的才是多仓库索引入口。
        if let multiRepo = Self.decodeMultiRepoIndex(data: data) {
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }

            if let lastError {
                throw ConfigError.parseError("多仓库配置中没有可用地址，最后错误: \(lastError.localizedDescription)")
            }
            throw ConfigError.parseError("多仓库配置中没有可用地址")
        }

        // 顶层对象的 url 字段是明确的地址指针，优先于启发式提取的候选地址。
        let explicitPointers = Self.extractExplicitConfigPointer(from: data, baseURL: resolvedUrl)
        let redirectCandidates = Self.uniqueUrlsInOrder(
            explicitPointers + Self.extractConfigRedirectCandidates(from: cleanedJson)
        )
            .filter { !nextVisited.contains(Self.urlIdentity($0)) }

        if !redirectCandidates.isEmpty {
            var lastError: Error?
            for candidate in redirectCandidates {
                do {
                    return try await fetchConfig(
                        from: candidate,
                        visitedUrls: nextVisited,
                        depth: depth + 1
                    )
                } catch is CancellationError {
                    throw CancellationError()
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
    /// 返回值同时带上重定向后的最终地址，供相对资源解析使用。
    private func fetchConfigText(from normalizedUrl: String) async throws -> (content: String, finalURL: String) {
        let key = Self.urlIdentity(normalizedUrl)
        let now = Date()

        if let entry = rawConfigCache[key] {
            if now.timeIntervalSince(entry.fetchedAt) <= Self.rawConfigCacheTTL {
                return (entry.content, entry.finalURL)
            }
            rawConfigCache.removeValue(forKey: key)
        }

        let response = try await network.getTextResponse(from: normalizedUrl)
        let finalURL = response.finalURL.absoluteString
        rawConfigCache[key] = RawConfigCacheEntry(content: response.text, finalURL: finalURL, fetchedAt: now)
        trimRawConfigCacheIfNeeded()
        return (response.text, finalURL)
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

    // MARK: - URL 身份与规范化

    /// 统一的地址身份：只规范大小写不敏感的 scheme、host 以及确定等价的默认端口，
    /// 路径、查询值与百分号编码保持原样（路径和 token 可能区分大小写）。
    /// 缓存、循环检测、去重与多仓选项 ID 共用这一实现。
    nonisolated static func urlIdentity(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return trimmed
        }
        components.scheme = scheme
        if let host = components.percentEncodedHost {
            components.percentEncodedHost = host.lowercased()
        }
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string ?? trimmed
    }

    nonisolated private static func uniqueUrlsInOrder(_ urls: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = urlIdentity(trimmed)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }

        return result
    }

    /// 读取顶层 JSON 对象中的 `url` 字段（形如 `{"url": "https://.../config.json"}` 的地址指针）。
    nonisolated private static func extractExplicitConfigPointer(from data: Data, baseURL: String) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["url"] as? String else {
            return []
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let absolute: String
        if let url = URL(string: trimmed), url.scheme != nil {
            absolute = trimmed
        } else if let base = URL(string: baseURL),
                  let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            absolute = resolved.absoluteString
        } else {
            return []
        }

        let normalized = normalizeConfigUrl(absolute)
        guard normalized.hasPrefix("http://") || normalized.hasPrefix("https://") else { return [] }
        return [normalized]
    }

    /// 从网页/文本中提取可能的配置地址：
    /// - 明文 URL 文本
    /// - data-clipboard-text（常见导航页“点击复制”）
    /// - JSON 片段中的 url 字段
    nonisolated private static func extractConfigRedirectCandidates(from content: String) -> [String] {
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

    nonisolated private static func matchCaptureGroup(pattern: String, in content: String) -> [String] {
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

    nonisolated private static func sanitizeExtractedUrl(_ value: String) -> String {
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

    nonisolated private static func isLikelyBinaryAssetUrl(_ urlString: String) -> Bool {
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

    nonisolated private static func isLikelyConfigPointerUrl(_ urlString: String) -> Bool {
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
    nonisolated static func normalizeConfigUrl(_ rawUrl: String) -> String {
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

    nonisolated private static func fixMalformedSchemeIfNeeded(_ urlString: String) -> String {
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

    nonisolated private static func normalizeGhProxyWrappedUrl(_ urlString: String) -> String? {
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

    nonisolated private static func convertGitHubBlobUrlToRaw(_ urlString: String) -> String? {
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

    // MARK: - JSON 清洗

    /// 去除 JSON 中的注释与尾逗号，兼容 TVBox 配置文件格式。
    /// Android 端 Gson 原生支持注释，Swift 的 JSONDecoder 不支持。
    ///
    /// 实现要点（不能使用无上下文的全局正则，否则会破坏字符串内容）：
    /// 1) 单次扫描同时维护字符串、转义与注释状态，字符串内部的 `//`、`,}`、`,]` 原样保留；
    /// 2) 只删除字符串之外、真正紧邻 `]` / `}` 的尾逗号；
    /// 3) 注释内容用空格替换，避免删掉注释后把前后两个 token 粘在一起。
    nonisolated static func stripJsonComments(_ json: String) -> String {
        var bytes = Array(json.utf8)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }

        let quote: UInt8 = 0x22
        let backslash: UInt8 = 0x5C
        let slash: UInt8 = 0x2F
        let comma: UInt8 = 0x2C
        let closeBracket: UInt8 = 0x5D
        let closeBrace: UInt8 = 0x7D
        let star: UInt8 = 0x2A
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        // 最近一次输出的、可能成为尾逗号的结构性逗号，及其在 output 中的位置。
        var pendingCommaIndex: Int?

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                output.append(byte)
                pendingCommaIndex = nil
                index += 1
                continue
            }

            switch byte {
            case quote:
                inString = true
                output.append(byte)
                pendingCommaIndex = nil
                index += 1
            case slash where index + 1 < bytes.count && bytes[index + 1] == slash:
                // 行注释：整行截断（换行由外层的换行处理保留）
                index += 2
                while index < bytes.count, bytes[index] != newline, bytes[index] != carriageReturn {
                    index += 1
                }
            case slash where index + 1 < bytes.count && bytes[index + 1] == star:
                // 块注释：整体删除，内部换行保留，避免行号与日志错乱
                index += 2
                var replacedWithSpace = false
                while index < bytes.count {
                    if bytes[index] == star, index + 1 < bytes.count, bytes[index + 1] == slash {
                        index += 2
                        break
                    }
                    if bytes[index] == newline || bytes[index] == carriageReturn {
                        output.append(bytes[index])
                    } else if !replacedWithSpace {
                        output.append(0x20)
                        replacedWithSpace = true
                    }
                    index += 1
                }
            case comma:
                if let previous = pendingCommaIndex {
                    output[previous] = 0x20
                }
                pendingCommaIndex = output.count
                output.append(byte)
                index += 1
            case closeBracket, closeBrace:
                if let previous = pendingCommaIndex {
                    output[previous] = 0x20
                }
                pendingCommaIndex = nil
                output.append(byte)
                index += 1
            case newline, carriageReturn, 0x20, 0x09:
                // 字符串之外的空白原样保留，不改动尾逗号状态
                output.append(byte)
                index += 1
            default:
                pendingCommaIndex = nil
                output.append(byte)
                index += 1
            }
        }

        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - 多仓库索引

    /// 解码多仓库索引。`MultiRepoConfigData` 字段全部可选，任意 JSON 对象都能“解码成功”，
    /// 因此只有确实存在 `urls` 数组时才认定为多仓库入口，否则返回 nil 交给其他分支处理。
    nonisolated static func decodeMultiRepoIndex(data: Data) -> MultiRepoConfigData? {
        guard let decoded = try? JSONDecoder().decode(MultiRepoConfigData.self, from: data),
              decoded.urls != nil else {
            return nil
        }
        return decoded
    }

    /// 仅探测“多仓库入口”并返回可选项。
    /// 返回 nil 表示不是多仓库入口；返回数组表示是多仓库入口（数组可能为空）。
    func fetchMultiRepoOptions(from apiUrl: String) async throws -> [MultiRepoOption]? {
        let normalizedUrl = Self.normalizeConfigUrl(apiUrl)
        let fetched = try await fetchConfigText(from: normalizedUrl)
        let cleanedJson = Self.stripJsonComments(fetched.content)

        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }

        let decoder = JSONDecoder()
        if let config = try? decoder.decode(AppConfigData.self, from: data), config.hasUsableContent {
            return nil
        }

        guard let multiRepo = Self.decodeMultiRepoIndex(data: data) else {
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

    // MARK: - 配置解析

    /// 写入点播侧解析结果（纯状态赋值，可直接测试）。
    func applySources(config: AppConfigData) {
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

    /// 读取远程直播列表。解析放到后台任务中执行，避免大列表占用主线程。
    nonisolated private static func downloadLiveList(
        url: String,
        userAgent: String?
    ) async throws -> [LiveChannelGroup] {
        var headers: [String: String]?
        if let userAgent, !userAgent.isEmpty {
            headers = ["User-Agent": userAgent]
        }
        let response = try await NetworkManager.shared.getTextResponse(from: url, headers: headers)
        // 列表要求的 UA 同样要用于播放，随频道线路一起保存。
        let groups = parseLiveContent(
            response.text,
            baseURL: response.finalURL.absoluteString,
            userAgent: userAgent
        )
        guard !groups.isEmpty else {
            throw LiveListParseError(message: "直播列表中没有可用频道")
        }
        return groups
    }

    /// 解析直播列表：每个来源完成即发布，慢来源不阻塞已就绪的列表。
    private func loadLives(config: AppConfigData, apiUrl: String, liveToken: UUID) async {
        var mergedGroups: [String: LiveChannelGroup] = [:]
        var remoteTargets: [LiveDownloadTarget] = []

        for (index, live) in (config.lives ?? []).enumerated() {
            guard activeLiveToken == liveToken else { return }

            if let channels = live.channels {
                let userAgent = live.ua?.trimmingCharacters(in: .whitespacesAndNewlines)
                Self.mergeLiveGroups(
                    Self.parseInlineLiveChannels(channels, userAgent: userAgent),
                    into: &mergedGroups
                )
            }

            if let liveUrl = live.url, !liveUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remoteTargets.append(LiveDownloadTarget(
                    order: index,
                    url: Self.resolveLiveUrl(liveUrl, baseConfigUrl: apiUrl),
                    userAgent: live.ua?.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        if !mergedGroups.isEmpty {
            liveChannelGroupList = Self.sortedGroups(from: mergedGroups)
        }
        liveLoadFailures = []

        guard !remoteTargets.isEmpty else {
            guard activeLiveToken == liveToken else { return }
            liveChannelGroupList = Self.sortedGroups(from: mergedGroups)
            isLoadingLives = false
            return
        }

        // 并发下载但限制并发数，结果按配置顺序合并，保证最终排序稳定。
        await withTaskGroup(of: LiveDownloadResult.self) { group in
            var nextTargetIndex = 0
            var inFlight = 0
            var orderedResults: [Int: [LiveChannelGroup]] = [:]
            var failures: [Int: String] = [:]

            func addNext() {
                guard nextTargetIndex < remoteTargets.count else { return }
                let target = remoteTargets[nextTargetIndex]
                nextTargetIndex += 1
                inFlight += 1
                group.addTask {
                    do {
                        let groups = try await Self.downloadLiveList(url: target.url, userAgent: target.userAgent)
                        return LiveDownloadResult(order: target.order, url: target.url, groups: groups, failure: nil)
                    } catch {
                        return LiveDownloadResult(order: target.order, url: target.url, groups: [], failure: Self.describeLiveFailure(error))
                    }
                }
            }

            while inFlight < Self.maxConcurrentLiveDownloads, nextTargetIndex < remoteTargets.count {
                addNext()
            }

            while let result = await group.next() {
                inFlight -= 1
                guard activeLiveToken == liveToken, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let failure = result.failure {
                    let label = URL(string: result.url)?.host ?? result.url
                    failures[result.order] = "\(label)：\(failure)"
                } else {
                    orderedResults[result.order] = result.groups
                }
                liveLoadFailures = failures
                    .sorted { $0.key < $1.key }
                    .map(\.value)

                // 每收到一个结果就按顺序重建快照并发布
                var published = mergedGroups
                for order in orderedResults.keys.sorted() {
                    Self.mergeLiveGroups(orderedResults[order] ?? [], into: &published)
                }
                liveChannelGroupList = Self.sortedGroups(from: published)

                addNext()
            }
        }

        guard activeLiveToken == liveToken else { return }
        isLoadingLives = false
    }

    nonisolated private static func describeLiveFailure(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    // MARK: - 直播列表解析

    /// 解析 m3u / txt 格式的直播内容。
    /// - Parameters:
    ///   - baseURL: 实际响应地址（重定向之后），用于解析相对地址。
    ///   - userAgent: 来源配置声明的 UA；M3U 中 `#EXTVLCOPT:http-user-agent` 指定的单频道 UA 优先。
    nonisolated static func parseLiveContent(
        _ rawContent: String,
        baseURL: String? = nil,
        userAgent: String? = nil
    ) -> [LiveChannelGroup] {
        var content = rawContent
        // 部分 IPTV 列表带 UTF-8 BOM 或前导空白，先清理再做格式识别。
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        var groups: [String: LiveChannelGroup] = [:]
        var currentGroupName = "默认"

        let lines = content.components(separatedBy: .newlines)
        let firstNonEmptyLine = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isM3U = firstNonEmptyLine?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasPrefix("#EXTM3U") == true

        if isM3U {
            var currentName = ""
            var currentGroup = "默认"
            var currentUserAgent: String?

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
                } else if trimmed.uppercased().hasPrefix("#EXTVLCOPT:"),
                          let agentRange = trimmed.range(of: "http-user-agent=", options: .caseInsensitive) {
                    // 列表自带单频道 UA，优先于来源级配置
                    let value = String(trimmed[agentRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentUserAgent = value.isEmpty ? nil : value
                } else if trimmed.hasPrefix("#") {
                    continue
                } else if let resolved = resolveStreamURL(trimmed, baseURL: baseURL) {
                    if !currentName.isEmpty {
                        appendChannel(
                            named: currentName,
                            urls: [resolved],
                            userAgent: currentUserAgent ?? userAgent,
                            logo: "",
                            to: currentGroup,
                            groups: &groups
                        )
                        currentName = ""
                        currentUserAgent = nil
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

                    if !name.isEmpty && isLiveStreamUrl(url) {
                        appendChannel(
                            named: name,
                            urls: [url],
                            userAgent: userAgent,
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

    /// 相对地址按响应最终地址解析；无法解析为受支持协议时返回 nil。
    nonisolated private static func resolveStreamURL(_ raw: String, baseURL: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isLiveStreamUrl(trimmed) {
            return trimmed
        }
        guard let baseURL, let base = URL(string: baseURL),
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              isLiveStreamUrl(resolved.absoluteString) else {
            return nil
        }
        return resolved.absoluteString
    }

    nonisolated static func parseInlineLiveChannels(
        _ channels: [AppConfigData.LiveConfig.LiveChannelConfig],
        userAgent: String? = nil
    ) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        for channel in channels {
            appendChannel(
                named: channel.name ?? "",
                urls: channel.urls ?? [],
                userAgent: userAgent,
                logo: channel.logo ?? "",
                to: channel.group ?? "其他",
                groups: &groups
            )
        }
        return sortedGroups(from: groups)
    }

    nonisolated static func mergeLiveGroups(_ incomingGroups: [LiveChannelGroup], into groups: inout [String: LiveChannelGroup]) {
        for group in incomingGroups {
            for channel in group.channels {
                appendChannel(
                    named: channel.channelName,
                    urls: channel.channelUrls,
                    userAgents: channel.userAgents,
                    logo: channel.logo,
                    to: group.groupName,
                    groups: &groups
                )
            }
        }
    }

    /// 追加频道（同一 UA 适用于全部线路）。
    nonisolated static func appendChannel(
        named channelName: String,
        urls: [String],
        userAgent: String?,
        logo: String,
        to groupName: String,
        groups: inout [String: LiveChannelGroup]
    ) {
        var userAgents: [String: String] = [:]
        if let userAgent, !userAgent.isEmpty {
            for url in urls {
                userAgents[normalizeLiveUrl(url)] = userAgent
            }
        }
        appendChannel(
            named: channelName,
            urls: urls,
            userAgents: userAgents,
            logo: logo,
            to: groupName,
            groups: &groups
        )
    }

    /// 追加频道：同组同名频道合并线路，每条线路保留各自来源要求的 UA。
    nonisolated static func appendChannel(
        named channelName: String,
        urls: [String],
        userAgents: [String: String],
        logo: String,
        to groupName: String,
        groups: inout [String: LiveChannelGroup]
    ) {
        let normalizedName = normalizeChannelName(channelName)
        guard !normalizedName.isEmpty else { return }

        let validUrls = uniqueLiveUrls(urls)
        guard !validUrls.isEmpty else { return }

        let normalizedGroupName = normalizeGroupName(groupName)
        if groups[normalizedGroupName] == nil {
            groups[normalizedGroupName] = LiveChannelGroup(
                groupName: normalizedGroupName,
                groupIndex: groups.count
            )
        }

        guard var group = groups[normalizedGroupName] else { return }

        if let existingIndex = group.channels.firstIndex(where: {
            normalizeChannelName($0.channelName) == normalizedName
        }) {
            var existing = group.channels[existingIndex]
            var existingUrls = Set(existing.channelUrls.map(normalizeLiveUrl))
            for url in validUrls {
                let normalizedUrl = normalizeLiveUrl(url)
                if !existingUrls.contains(normalizedUrl) {
                    existing.channelUrls.append(url)
                    existingUrls.insert(normalizedUrl)
                    if let userAgent = userAgents[normalizedUrl], !userAgent.isEmpty {
                        existing.userAgents[url] = userAgent
                    }
                }
            }
            let trimmedLogo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.logo.isEmpty && !trimmedLogo.isEmpty {
                existing.logo = trimmedLogo
            }
            group.channels[existingIndex] = existing
        } else {
            var item = LiveChannelItem(
                channelName: normalizedName,
                channelIndex: group.channels.count,
                groupName: normalizedGroupName
            )
            item.channelUrls = validUrls
            item.logo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            for url in validUrls {
                if let userAgent = userAgents[normalizeLiveUrl(url)], !userAgent.isEmpty {
                    item.userAgents[url] = userAgent
                }
            }
            group.channels.append(item)
        }

        groups[normalizedGroupName] = group
    }

    nonisolated static func sortedGroups(from groups: [String: LiveChannelGroup]) -> [LiveChannelGroup] {
        groups.values
            .sorted { lhs, rhs in
                if lhs.groupIndex != rhs.groupIndex { return lhs.groupIndex < rhs.groupIndex }
                return lhs.groupName < rhs.groupName
            }
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

    nonisolated private static func resolveLiveUrl(_ urlString: String, baseConfigUrl: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil {
            return normalizeConfigUrl(trimmed)
        }
        guard let baseUrl = URL(string: baseConfigUrl),
              let resolved = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL else {
            return trimmed
        }
        return normalizeConfigUrl(resolved.absoluteString)
    }

    nonisolated private static func uniqueLiveUrls(_ urls: [String]) -> [String] {
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

    nonisolated private static func normalizeGroupName(_ groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "默认" : trimmed
    }

    nonisolated private static func normalizeChannelName(_ channelName: String) -> String {
        channelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizeLiveUrl(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isLiveStreamUrl(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("rtmp://")
            || lowercased.hasPrefix("rtsp://")
    }

    // MARK: - 查询

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
        guard homeSourceBean?.key != source.key else { return }
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
