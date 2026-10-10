import Foundation
import SwiftUI
import Network

struct PlaybackQualityOption: Identifiable, Hashable {
    /// “自动”选项固定标识。
    static let autoIdentifier = "auto"
    /// 选项唯一标识（这里直接使用播放地址或固定 auto id）。
    let id: String
    /// UI 展示名（如 1080p / 720p / 自动）。
    let name: String
    /// 对应播放地址。
    let url: String
    
    var isAuto: Bool {
        id == Self.autoIdentifier
    }
    
    static func auto(url: String) -> PlaybackQualityOption {
        PlaybackQualityOption(id: autoIdentifier, name: "自动", url: url)
    }
}

/// 详情页 ViewModel
@MainActor
class DetailViewModel: ObservableObject {
    /// 详情信息主体。
    @Published var vodInfo: VodInfo?
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    /// 当前选中线路。
    @Published var selectedFlag: String = ""
    /// 当前选中剧集索引。
    @Published var selectedEpisodeIndex: Int = 0
    /// 是否处于播放态。
    @Published var isPlaying = false
    /// 当前实际播放地址（可能是原始地址、清晰度子流地址，或去广告后的本地地址）。
    @Published var playUrl: String?
    /// 去广告结果提示（如"已过滤 2 段广告（约 30 秒）"），未过滤时为 nil。
    @Published var adFilterNote: String?
    /// 正在准备播放地址（去广告处理中），期间旧播放器的进度回调需忽略。
    @Published private(set) var isPreparingPlayback = false
    /// 续播起始位置（秒）。
    @Published var resumeSeconds: Double = 0
    /// 当前可选清晰度列表。
    @Published var qualityOptions: [PlaybackQualityOption] = []
    /// 当前选中的清晰度 id。
    @Published var selectedQualityId: String = PlaybackQualityOption.autoIdentifier
    /// 播放器高频回调进度，不直接绑定 UI，避免高频刷新引发性能问题。
    private var realtimeProgressSeconds: Double = 0
    
    /// 数据服务与网络服务。
    private let sourceService = SourceService.shared
    private let network = NetworkManager.shared
    /// 当前清晰度列表对应的基础剧集地址。
    private var qualityBaseEpisodeURL: String = ""
    /// 清晰度解析缓存，key 为原始剧集 URL。
    private var qualityOptionCache: [String: [PlaybackQualityOption]] = [:]
    /// 清晰度解析任务，用于取消旧请求。
    private var qualityResolveTask: Task<Void, Never>?
    /// 解析令牌，防止异步结果回写到过期状态。
    private var qualityResolveToken = UUID()
    /// 请求播放的原始地址（去广告后 playUrl 会变成本地地址，比较时以此为准）。
    private var requestedPlayURL: String?
    /// 播放地址准备令牌，防止快速切集时旧结果覆盖新地址。
    private var playbackPrepareToken = UUID()

    /// 加载视频详情
    func loadDetail(video: Movie.Video) async {
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey)
                ?? ApiConfig.shared.homeSourceBean else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            if var info = try await sourceService.getDetail(sourceBean: source, vodId: video.id) {
                info.playFlag = Self.preferredFlag(in: info)
                self.vodInfo = info
                self.selectedFlag = info.playFlag
                self.selectedEpisodeIndex = info.playIndex
                self.resumeSeconds = 0
                self.realtimeProgressSeconds = 0
                if let episode = info.currentEpisode {
                    updateQualityOptions(for: episode.url, resetSelection: true)
                } else {
                    resetQualityState()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    /// 选择线路
    func selectFlag(_ flag: String) {
        guard selectedFlag != flag else { return }
        let currentIndex = selectedEpisodeIndex
        
        selectedFlag = flag
        vodInfo?.playFlag = flag
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        let episodes = vodInfo?.playUrlMap[flag] ?? []
        guard !episodes.isEmpty else {
            selectedEpisodeIndex = 0
            vodInfo?.playIndex = 0
            resetQualityState()
            return
        }
        
        let targetIndex = min(max(currentIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        let episodeURL = episodes[targetIndex].url
        updateQualityOptions(for: episodeURL, resetSelection: true)
        
        // 播放中切线路时，立即切换到新线路对应剧集
        if isPlaying {
            setPlaybackURL(selectedPlayableURL(fallback: episodeURL))
        }
    }
    
    /// 选择剧集并播放
    func selectEpisode(index: Int) {
        guard selectedEpisodeIndex != index || !isPlaying else { return }
        selectedEpisodeIndex = index
        vodInfo?.playIndex = index
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        if let episode = vodInfo?.currentEpisode {
            // 仅当剧集 URL 变化时重置清晰度选择。
            let shouldResetQuality = qualityBaseEpisodeURL != episode.url
            updateQualityOptions(for: episode.url, resetSelection: shouldResetQuality)
            setPlaybackURL(selectedPlayableURL(fallback: episode.url))
            isPlaying = true
        }
    }
    
    /// 应用历史续播状态并自动继续播放
    func applyPlaybackState(_ state: VodPlaybackState) {
        guard let info = vodInfo, !info.playFlags.isEmpty else { return }
        
        let fallbackFlag = info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag
        let targetFlag = info.playFlags.contains(state.flag) ? state.flag : fallbackFlag
        
        selectedFlag = targetFlag
        vodInfo?.playFlag = targetFlag
        
        let episodes = vodInfo?.playUrlMap[targetFlag] ?? []
        guard !episodes.isEmpty else { return }
        
        let targetIndex = min(max(state.episodeIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        
        let progress = max(0, state.progressSeconds)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        let episodeURL = episodes[targetIndex].url
        updateQualityOptions(for: episodeURL, resetSelection: true)
        setPlaybackURL(selectedPlayableURL(fallback: episodeURL))
        isPlaying = true
    }
    
    /// 选择清晰度
    func selectQuality(_ option: PlaybackQualityOption) {
        guard qualityOptions.contains(option) else { return }
        selectedQualityId = option.id
        guard isPlaying else { return }
        
        // “自动”使用基础剧集地址；其他选项使用对应变体地址。
        let targetURL = option.url.isEmpty ? qualityBaseEpisodeURL : option.url
        guard !targetURL.isEmpty, requestedPlayURL != targetURL else { return }

        let progress = max(currentPlaybackSeconds(), 0)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        setPlaybackURL(targetURL)
    }
    
    /// 播放器时间回调
    func updatePlaybackProgress(seconds: Double) {
        // 准备新地址期间旧播放器仍在走，它的进度不属于新剧集
        guard seconds.isFinite, !isPreparingPlayback else { return }
        realtimeProgressSeconds = max(seconds, 0)
    }
    
    /// 当前实时进度（不触发 UI 高频刷新）
    func currentPlaybackSeconds() -> Double {
        max(realtimeProgressSeconds, resumeSeconds)
    }
    
    /// 仅在必要时同步快照到可观察状态
    func commitPlaybackProgressSnapshot() {
        let snapshot = max(realtimeProgressSeconds, 0)
        if abs(snapshot - resumeSeconds) >= 1 {
            resumeSeconds = snapshot
        }
    }
    
    /// 播放下一集
    func playNext() -> Bool {
        guard let info = vodInfo else { return false }
        let episodes = info.currentEpisodes
        if selectedEpisodeIndex + 1 < episodes.count {
            selectEpisode(index: selectedEpisodeIndex + 1)
            return true
        }
        return false
    }
    
    /// 播放上一集
    func playPrevious() -> Bool {
        if selectedEpisodeIndex > 0 {
            selectEpisode(index: selectedEpisodeIndex - 1)
            return true
        }
        return false
    }
    
    /// 当前剧集列表
    var currentEpisodes: [VodInfo.Episode] {
        vodInfo?.playUrlMap[selectedFlag] ?? []
    }
    
    /// 可选线路列表
    var flags: [String] {
        vodInfo?.playFlags ?? []
    }
    
    /// 是否存在可选清晰度
    var hasQualityChoices: Bool {
        qualityOptions.count > 1
    }
    
    /// 设置播放地址：
    /// 1) 网页播放页（如 /share/xxx）先嗅探出真实的 m3u8/mp4 地址；
    /// 2) 开启广告过滤且为 HLS 时去广告，失败或未发现广告则用原地址。
    /// 处理期间保持旧地址不变，避免全屏播放器因 playUrl 置空而被关闭。
    private func setPlaybackURL(_ url: String) {
        requestedPlayURL = url
        adFilterNote = nil
        let token = UUID()
        playbackPrepareToken = token

        let needsSniff = MediaURLResolver.needsResolve(url)
        let isHLS = URL(string: url).map(Self.looksLikeHLSURL) ?? false
        guard needsSniff || (HLSAdFilter.isEnabled && isHLS) else {
            isPreparingPlayback = false
            playUrl = url
            return
        }

        isPreparingPlayback = true
        Task {
            var target = url
            if needsSniff, let sniffed = await MediaURLResolver.resolve(pageURL: url) {
                target = sniffed
            }
            guard token == playbackPrepareToken else { return }

            if HLSAdFilter.isEnabled, let parsed = URL(string: target), Self.looksLikeHLSURL(parsed),
               let prepared = await HLSAdFilter.prepare(url: target) {
                guard token == playbackPrepareToken else { return }
                playUrl = prepared.localURL
                adFilterNote = "已过滤 \(prepared.removedGroups) 段广告（约 \(Int(prepared.removedSeconds.rounded())) 秒）"
            } else {
                guard token == playbackPrepareToken else { return }
                playUrl = target
            }
            isPreparingPlayback = false
        }
    }

    /// 默认线路：优先选剧集地址是视频文件（m3u8/mp4 等）的线路，
    /// 避免默认落到需要网页解析的线路（如非凡资源的 feifan 是 /share/ 播放页）。
    private static func preferredFlag(in info: VodInfo) -> String {
        info.playFlags.first { flag in
            guard let first = info.playUrlMap[flag]?.first else { return false }
            return MediaURLResolver.isDirectMedia(first.url)
        } ?? info.playFlag
    }

    private func selectedPlayableURL(fallback: String) -> String {
        // 若当前清晰度存在有效 URL，则优先使用；否则回退剧集原始地址。
        let selected = qualityOptions.first(where: { $0.id == selectedQualityId })?.url
        if let selected, !selected.isEmpty {
            return selected
        }
        return fallback
    }
    
    /// 重置清晰度解析与选择状态。
    private func resetQualityState() {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityBaseEpisodeURL = ""
        qualityOptions = []
        selectedQualityId = PlaybackQualityOption.autoIdentifier
        qualityResolveToken = UUID()
    }
    
    private func updateQualityOptions(for episodeURL: String, resetSelection: Bool) {
        let trimmedEpisodeURL = episodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEpisodeURL.isEmpty else {
            resetQualityState()
            return
        }
        
        // 切换剧集时先取消旧任务，避免异步回写错位。
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        
        let autoOption = PlaybackQualityOption.auto(url: trimmedEpisodeURL)
        let previousSelected = selectedQualityId
        
        qualityBaseEpisodeURL = trimmedEpisodeURL
        if resetSelection {
            selectedQualityId = PlaybackQualityOption.autoIdentifier
        }
        
        qualityOptions = [autoOption]
        
        if let cached = qualityOptionCache[trimmedEpisodeURL] {
            // 缓存命中时直接复用，避免重复网络解析。
            qualityOptions = cached
            if resetSelection || !cached.contains(where: { $0.id == selectedQualityId }) {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if previousSelected != selectedQualityId && cached.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            }
            return
        }
        
        let token = UUID()
        qualityResolveToken = token
        qualityResolveTask = Task { [trimmedEpisodeURL, resetSelection, previousSelected] in
            let resolved = await resolveQualityOptions(for: trimmedEpisodeURL)
            guard !Task.isCancelled else { return }
            guard qualityResolveToken == token, qualityBaseEpisodeURL == trimmedEpisodeURL else { return }
            guard !resolved.isEmpty else { return }
            
            qualityOptionCache[trimmedEpisodeURL] = resolved
            qualityOptions = resolved
            
            if resetSelection {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if resolved.contains(where: { $0.id == selectedQualityId }) {
                // 当前选择仍有效，保持不变
            } else if resolved.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            } else {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            }
        }
    }
    
    /// 尝试从 HLS 主播放列表解析多清晰度选项。
    private func resolveQualityOptions(for episodeURL: String) async -> [PlaybackQualityOption] {
        guard let url = URL(string: episodeURL), Self.looksLikeHLSURL(url) else { return [] }
        guard let playlist = try? await network.getString(from: episodeURL) else { return [] }
        return Self.parseMasterPlaylist(playlist, masterURL: url)
    }
    
    /// HLS 变体流中间模型。
    private struct HLSVariant {
        let url: String
        let name: String?
        let height: Int?
        let bandwidth: Int?
    }
    
    /// 轻量判断 URL 是否可能是 HLS 播放列表。
    private static func looksLikeHLSURL(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        if lowercased.contains(".m3u8") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }
    
    /// 解析 HLS 主播放列表并生成清晰度选项。
    /// 仅当解析出 2 个及以上有效变体时才返回（否则不显示清晰度切换）。
    private static func parseMasterPlaylist(_ content: String, masterURL: URL) -> [PlaybackQualityOption] {
        guard content.localizedCaseInsensitiveContains("#EXT-X-STREAM-INF") else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var index = 0
        
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            
            let attributeString = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let attributes = parseAttributeMap(attributeString)
            
            var uri: String?
            var nextIndex = index + 1
            while nextIndex < lines.count {
                let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    nextIndex += 1
                    continue
                }
                if candidate.hasPrefix("#") {
                    nextIndex += 1
                    continue
                }
                uri = candidate
                break
            }
            
            if let uri, !uri.isEmpty {
                let resolvedURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL.absoluteString ?? uri
                let name = attributes["NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init)
                let height: Int?
                if let resolution = attributes["RESOLUTION"] {
                    let parts = resolution.split(separator: "x")
                    if parts.count == 2 {
                        height = Int(parts[1])
                    } else {
                        height = nil
                    }
                } else {
                    height = nil
                }
                
                variants.append(HLSVariant(
                    url: resolvedURL,
                    name: name?.isEmpty == true ? nil : name,
                    height: height,
                    bandwidth: bandwidth
                ))
            }
            
            index = nextIndex + 1
        }
        
        guard !variants.isEmpty else { return [] }
        
        var seenURLs = Set<String>()
        let deduped = variants.filter { variant in
            let inserted = seenURLs.insert(variant.url).inserted
            return inserted
        }
        
        let sorted = deduped.sorted { lhs, rhs in
            let lhsHeight = lhs.height ?? -1
            let rhsHeight = rhs.height ?? -1
            if lhsHeight != rhsHeight {
                return lhsHeight > rhsHeight
            }
            let lhsBandwidth = lhs.bandwidth ?? -1
            let rhsBandwidth = rhs.bandwidth ?? -1
            if lhsBandwidth != rhsBandwidth {
                return lhsBandwidth > rhsBandwidth
            }
            return lhs.url < rhs.url
        }
        
        let masterURLString = masterURL.absoluteString
        var displayNameCount: [String: Int] = [:]
        let options = sorted.enumerated().map { offset, variant -> PlaybackQualityOption in
            let baseName: String
            if let name = variant.name, !name.isEmpty {
                baseName = name
            } else if let height = variant.height {
                baseName = "\(height)p"
            } else if let bandwidth = variant.bandwidth, bandwidth > 0 {
                baseName = "\(bandwidth / 1000)K"
            } else {
                baseName = "清晰度\(offset + 1)"
            }
            
            let newCount = (displayNameCount[baseName] ?? 0) + 1
            displayNameCount[baseName] = newCount
            let finalName = newCount > 1 ? "\(baseName) \(newCount)" : baseName
            
            return PlaybackQualityOption(id: variant.url, name: finalName, url: variant.url)
        }.filter { !$0.url.isEmpty && $0.url != masterURLString }
        
        guard options.count >= 2 else { return [] }
        
        var merged = [PlaybackQualityOption.auto(url: masterURLString)]
        merged.append(contentsOf: options)
        return merged
    }
    
    /// 解析 `EXT-X-STREAM-INF` 的属性串为键值字典。
    private static func parseAttributeMap(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = splitAttributes(raw)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
    
    /// 按逗号分隔属性，但保留引号内逗号。
    private static func splitAttributes(_ raw: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var inQuotes = false
        
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                buffer.append(char)
                continue
            }
            
            if char == "," && !inQuotes {
                let item = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty {
                    parts.append(item)
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            
            buffer.append(char)
        }
        
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }
}

// MARK: - HLS 广告过滤

/// m3u8 去广告（对应影视仓的"去广告"）。
///
/// 资源站常在正片切片之间插入广告，并用 `#EXT-X-DISCONTINUITY` 隔开。
/// 识别规则（按 DISCONTINUITY 切段）：
/// 1. 目录与正片不同、且总时长较短的段；
/// 2. 夹在两段长正片之间的短段（广告与正片同目录的站点）。
/// 识别结果可疑（删除占比过高）时宁可不删。
enum HLSAdFilter {
    /// 设置开关的持久化 key，默认开启。
    static let enabledKey = "ad_filter_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 单段广告的最长时长（秒），超过视为正片的一部分。
    private static let maxAdGroupSeconds: Double = 120
    /// 同目录插播广告：短段时长上限（秒）。
    private static let maxSandwichedAdSeconds: Double = 45
    /// 同目录插播广告：前后两段都至少这么长才算"夹在正片中间"（秒）。
    private static let minContentNeighborSeconds: Double = 120
    /// 删除总时长占比上限，超过说明识别不可靠，放弃过滤。
    private static let maxRemovedRatio: Double = 0.3

    struct Result {
        let playlist: String
        let removedGroups: Int
        let removedSeconds: Double
    }

    struct Prepared {
        let localURL: String
        let removedGroups: Int
        let removedSeconds: Double
    }

    /// 下载并过滤播放地址；未识别到广告、非 HLS 或任何一步失败都返回 nil（调用方按原地址播放）。
    static func prepare(url: String) async -> Prepared? {
        let network = NetworkManager.shared
        guard var (text, mediaURL) = try? await network.getStringWithFinalURL(from: url, maxRetries: 0),
              text.hasPrefix("#EXTM3U") || text.contains("#EXTINF") else { return nil }

        // 主播放列表：选码率最高的子列表再过滤（去广告需要逐切片分析）
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariant(in: text, masterURL: mediaURL),
                  let fetched = try? await network.getStringWithFinalURL(from: variant.absoluteString, maxRetries: 0),
                  !fetched.text.contains("#EXT-X-STREAM-INF") else { return nil }
            (text, mediaURL) = fetched
        }

        guard let result = filter(text, playlistURL: mediaURL),
              let localURL = try? await LocalPlaylistServer.shared.publish(result.playlist) else { return nil }
        return Prepared(localURL: localURL.absoluteString, removedGroups: result.removedGroups, removedSeconds: result.removedSeconds)
    }

    // MARK: 解析

    private struct Segment {
        var tags: [String] = []
        var extinf = ""
        var duration: Double = 0
        var uri = ""
        var keyLine: String?
        var mapLine: String?

        /// 切片所在目录（host + 父路径），正片切片通常共享同一目录。
        var directory: String {
            guard let url = URL(string: uri) else { return uri }
            return (url.host ?? "") + url.deletingLastPathComponent().path
        }
    }

    /// 过滤媒体播放列表；未发现广告返回 nil。
    static func filter(_ content: String, playlistURL: URL) -> Result? {
        var header: [String] = []
        var groups: [[Segment]] = [[]]
        var pending = Segment()
        var currentKey: String?
        var currentMap: String?
        var hasEndList = false
        var seenFirstSegmentTag = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
                seenFirstSegmentTag = true
            } else if line.hasPrefix("#EXT-X-KEY") {
                currentKey = absolutizeURIAttribute(line, base: playlistURL)
                if currentKey?.contains("METHOD=NONE") == true { currentKey = nil }
                seenFirstSegmentTag = true
            } else if line.hasPrefix("#EXT-X-MAP") {
                currentMap = absolutizeURIAttribute(line, base: playlistURL)
                seenFirstSegmentTag = true
            } else if line.hasPrefix("#EXTINF") {
                pending.extinf = line
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pending.duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                seenFirstSegmentTag = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if line.hasPrefix("#") {
                if seenFirstSegmentTag || isSegmentTag(line) {
                    pending.tags.append(line)
                    seenFirstSegmentTag = true
                } else {
                    header.append(line)
                }
            } else {
                // 切片 URI
                pending.uri = URL(string: line, relativeTo: playlistURL)?.absoluteString ?? line
                pending.keyLine = currentKey
                pending.mapLine = currentMap
                groups[groups.count - 1].append(pending)
                pending = Segment()
            }
        }

        groups.removeAll { $0.isEmpty }
        guard groups.count >= 2 else { return nil }

        // 正片目录：累计时长最长的目录
        var durationByDirectory: [String: Double] = [:]
        for segment in groups.joined() {
            durationByDirectory[segment.directory, default: 0] += segment.duration
        }
        guard let mainDirectory = durationByDirectory.max(by: { $0.value < $1.value })?.key else { return nil }

        let totalSeconds = groups.joined().reduce(0) { $0 + $1.duration }
        let groupDurations = groups.map { group in group.reduce(0) { $0 + $1.duration } }
        var kept: [[Segment]] = []
        var removedGroups = 0
        var removedSeconds: Double = 0

        for (index, group) in groups.enumerated() {
            let groupSeconds = groupDurations[index]
            let mainCount = group.filter { $0.directory == mainDirectory }.count
            // 规则一：整段都不在正片目录、且时长短 → 广告
            let isForeignShortGroup = mainCount == 0 && groupSeconds <= maxAdGroupSeconds
            // 规则二：夹在两段长正片之间的短段 → 插播广告
            // （如非凡资源：广告与正片同目录、同样的哈希文件名，只能靠"短段夹在长段中间"识别）
            let isSandwichedShortGroup = index > 0 && index < groups.count - 1
                && groupSeconds <= maxSandwichedAdSeconds
                && groupDurations[index - 1] >= minContentNeighborSeconds
                && groupDurations[index + 1] >= minContentNeighborSeconds
            if isForeignShortGroup || isSandwichedShortGroup {
                removedGroups += 1
                removedSeconds += groupSeconds
            } else {
                kept.append(group)
            }
        }

        guard removedGroups > 0, !kept.isEmpty,
              totalSeconds <= 0 || removedSeconds / totalSeconds <= maxRemovedRatio else { return nil }

        // 重建播放列表：保留段之间仍用 DISCONTINUITY 分隔（时间戳可能不连续），并补齐加密/初始化信息
        var output = header.isEmpty ? ["#EXTM3U"] : header
        if !output.contains(where: { $0.hasPrefix("#EXTM3U") }) { output.insert("#EXTM3U", at: 0) }
        var emittedKey: String?
        var emittedMap: String?
        for (index, group) in kept.enumerated() {
            if index > 0 { output.append("#EXT-X-DISCONTINUITY") }
            for segment in group {
                if segment.keyLine != emittedKey {
                    output.append(segment.keyLine ?? "#EXT-X-KEY:METHOD=NONE")
                    emittedKey = segment.keyLine
                }
                if let map = segment.mapLine, map != emittedMap {
                    output.append(map)
                    emittedMap = map
                }
                output.append(contentsOf: segment.tags)
                output.append(segment.extinf.isEmpty ? "#EXTINF:\(segment.duration)," : segment.extinf)
                output.append(segment.uri)
            }
        }
        if hasEndList { output.append("#EXT-X-ENDLIST") }

        return Result(playlist: output.joined(separator: "\n") + "\n", removedGroups: removedGroups, removedSeconds: removedSeconds)
    }

    /// 属于单个切片的标签（出现在头部之后）。
    private static func isSegmentTag(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-BYTERANGE") || line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME") || line.hasPrefix("#EXT-X-GAP")
    }

    /// 把标签里的 URI="相对路径" 改成绝对地址（列表改由本地服务提供后，相对路径会解析错）。
    private static func absolutizeURIAttribute(_ line: String, base: URL) -> String {
        guard let range = line.range(of: #"URI="([^"]*)""#, options: .regularExpression) else { return line }
        let raw = String(line[range]).dropFirst("URI=\"".count).dropLast()
        let absolute = URL(string: String(raw), relativeTo: base)?.absoluteString ?? String(raw)
        return line.replacingCharacters(in: range, with: "URI=\"\(absolute)\"")
    }

    /// 主播放列表中码率最高的子列表地址。
    private static func bestVariant(in master: String, masterURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth: Int?
        for rawLine in master.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let match = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression)
                pendingBandwidth = match.flatMap { Int(line[$0].dropFirst("BANDWIDTH=".count)) } ?? 0
            } else if let bandwidth = pendingBandwidth, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: masterURL)?.absoluteURL,
                   best == nil || bandwidth > best!.bandwidth {
                    best = (bandwidth, url)
                }
                pendingBandwidth = nil
            }
        }
        return best?.url
    }
}

// MARK: - 本地播放列表服务

/// 只监听 127.0.0.1 的极简 HTTP 服务，向播放器提供去广告后的 m3u8。
/// 系统播放器不支持本地文件形式的 HLS 列表，因此统一走 http；切片仍直连原 CDN。
final class LocalPlaylistServer: @unchecked Sendable {
    static let shared = LocalPlaylistServer()

    /// 最多保留的播放列表数量（按发布顺序淘汰）。
    private static let capacity = 30

    private let queue = DispatchQueue(label: "tvbox.local-playlist-server")
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var waiters: [CheckedContinuation<NWEndpoint.Port, Error>] = []
    private var playlists: [String: Data] = [:]
    private var order: [String] = []

    private init() {}

    /// 发布一份播放列表，返回可供播放器访问的本地地址。
    func publish(_ playlist: String) async throws -> URL {
        let port = try await ensureStarted()
        let id = UUID().uuidString
        queue.sync {
            playlists[id] = Data(playlist.utf8)
            order.append(id)
            while order.count > Self.capacity {
                playlists.removeValue(forKey: order.removeFirst())
            }
        }
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(id).m3u8") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func ensureStarted() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let port = self.port {
                    continuation.resume(returning: port)
                    return
                }
                self.waiters.append(continuation)
                if self.listener == nil {
                    self.startListener()
                }
            }
        }
    }

    /// 在 queue 上调用。
    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    if let port = listener.port {
                        self.resumeWaiters(.success(port))
                    }
                case .failed(let error):
                    // 例如 iOS 进入后台后套接字失效：重置，下次发布时重新启动
                    self.reset()
                    self.resumeWaiters(.failure(error))
                case .cancelled:
                    self.reset()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            reset()
            resumeWaiters(.failure(error))
        }
    }

    private func reset() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func resumeWaiters(_ result: Result<NWEndpoint.Port, Error>) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(with: result) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 请求行形如 "GET /<id>.m3u8 HTTP/1.1"
            let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]) : ""
            let id = path.split(separator: "?").first.map { String($0.dropFirst()) }?
                .replacingOccurrences(of: ".m3u8", with: "") ?? ""

            var response: Data
            if let body = self.playlists[id] {
                let head = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: application/vnd.apple.mpegurl\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Cache-Control: no-cache\r\n"
                    + "Access-Control-Allow-Origin: *\r\n"
                    + "Connection: close\r\n\r\n"
                response = Data(head.utf8)
                if method != "HEAD" { response.append(body) }
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

// MARK: - 网页播放页嗅探

/// 部分线路给的是网页播放页（如 `https://xxx/share/<id>`）而非视频地址，
/// 播放器直接打开会报 "Cannot Open"。这里读取网页，从中找出真实的 m3u8/mp4 地址。
enum MediaURLResolver {
    /// 可由播放器直接播放的扩展名。
    private static let mediaExtensions: Set<String> = [
        "m3u8", "m3u", "mp4", "m4v", "mov", "flv", "mkv", "avi", "ts", "webm", "mpd", "mp3", "aac"
    ]
    /// 读取网页的上限，播放页通常只有几 KB。
    private static let maxPageBytes = 512 * 1024

    /// 地址是否像视频文件（扩展名或路径中含 .m3u8/.mp4）。
    static func isDirectMedia(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        if lowercased.contains(".m3u8") || lowercased.contains(".mp4") { return true }
        guard let url = URL(string: urlString) else { return false }
        return mediaExtensions.contains(url.pathExtension.lowercased())
    }

    /// 是否需要先嗅探：http(s) 地址且看起来不是视频文件。
    static func needsResolve(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return false }
        return !isDirectMedia(urlString)
    }

    /// 打开网页并提取视频地址；不是网页或没找到时返回 nil（调用方按原地址播放）。
    static func resolve(pageURL: String) async -> String? {
        guard let url = URL(string: pageURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            // 只读网页：没有扩展名的地址也可能直接就是视频流，不能整个下载下来
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  (http.mimeType ?? "").lowercased().contains("html") else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxPageBytes { break }
            }
            bytes.task.cancel()
            let html = String(decoding: data, as: UTF8.self)
            return extractMediaURL(from: html, pageURL: http.url ?? url)
        } catch {
            return nil
        }
    }

    /// 从网页文本中找出视频地址（优先 m3u8），相对路径按网页地址补全。
    static func extractMediaURL(from html: String, pageURL: URL) -> String? {
        // 兼容 JSON 转义的斜杠，如 https:\/\/host\/a.m3u8
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        for ext in ["m3u8", "mp4"] {
            let pattern = #"["'(]((?:https?:)?/[^"'()\s<>]*?\."# + ext + #"(?:\?[^"'()\s<>]*)?)["')]"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                let candidate = String(text[captured])
                if let resolved = URL(string: candidate, relativeTo: pageURL)?.absoluteURL,
                   resolved.scheme?.hasPrefix("http") == true {
                    return resolved.absoluteString
                }
            }
        }
        return nil
    }
}
