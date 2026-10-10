import Foundation
import SwiftUI

// MARK: - 点播订阅（多点播地址）

/// 一条点播订阅：名称 + 配置地址。
struct VodSubscription: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String

    /// 未命名时用地址的域名作为默认名称。
    static func defaultName(for url: String) -> String {
        let host = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        return (host?.isEmpty == false ? host : nil) ?? "未命名订阅"
    }
}

/// 点播订阅管理：保存多个点播配置地址，并在它们之间切换（对应影视仓的多仓订阅）。
/// 设置页与首页共用同一份数据。
@MainActor
final class VodSubscriptionStore: ObservableObject {
    static let shared = VodSubscriptionStore()

    private static let storageKey = "vod_subscriptions"

    /// 全部订阅（按添加顺序）。
    @Published private(set) var subscriptions: [VodSubscription] = []
    /// 正在切换中的订阅 id（用于 UI 显示加载状态）。
    @Published private(set) var switchingId: String?
    /// 最近一次切换失败的提示。
    @Published var lastError: String?

    private init() {
        load()
    }

    /// 当前生效的订阅：以已保存的点播地址为准。
    var active: VodSubscription? {
        let current = ApiConfig.normalizeConfigUrl(UserDefaults.standard.string(forKey: HawkConfig.API_URL) ?? "")
        guard !current.isEmpty else { return nil }
        return subscriptions.first { ApiConfig.normalizeConfigUrl($0.url) == current }
    }

    func isActive(_ subscription: VodSubscription) -> Bool {
        active?.id == subscription.id
    }

    /// 新增或更新订阅（同一地址只保留一条）。name 为空时保留原名或用域名。
    @discardableResult
    func upsert(url: String, name: String? = nil) -> VodSubscription {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = ApiConfig.normalizeConfigUrl(trimmedUrl)
        // active 依赖已保存的点播地址，命中已有订阅时也通知 UI 刷新勾选状态
        objectWillChange.send()

        if let index = subscriptions.firstIndex(where: { ApiConfig.normalizeConfigUrl($0.url) == normalized }) {
            if !trimmedName.isEmpty {
                subscriptions[index].name = trimmedName
                save()
            }
            return subscriptions[index]
        }

        let subscription = VodSubscription(
            name: trimmedName.isEmpty ? VodSubscription.defaultName(for: trimmedUrl) : trimmedName,
            url: trimmedUrl
        )
        subscriptions.append(subscription)
        save()
        return subscription
    }

    func rename(_ subscription: VodSubscription, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].name = trimmed
        save()
    }

    /// 删除订阅（不影响当前已加载的配置）。
    func remove(_ subscription: VodSubscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        save()
    }

    /// 添加地址：多仓库入口会展开为多条订阅，普通地址添加为一条。
    /// - Returns: 新增/命中的订阅列表（第一条可用于立即切换）。
    func add(url: String, name: String?) async throws -> [VodSubscription] {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigError.parseError("请输入点播接口地址") }

        if let options = try await ApiConfig.shared.fetchMultiRepoOptions(from: trimmed) {
            guard !options.isEmpty else { throw ConfigError.parseError("多仓库配置中没有可用地址") }
            return options.map { upsert(url: $0.url, name: $0.name) }
        }
        return [upsert(url: trimmed, name: name)]
    }

    /// 切换到指定订阅：加载配置成功后才保存为当前点播地址。
    /// 直播地址若未单独设置则跟随点播。
    func activate(_ subscription: VodSubscription, appState: AppState) async -> Bool {
        switchingId = subscription.id
        lastError = nil
        defer { switchingId = nil }

        let defaults = UserDefaults.standard
        let savedLive = (defaults.string(forKey: HawkConfig.LIVE_API_URL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await ApiConfig.shared.loadConfigs(
                vodApiUrl: subscription.url,
                liveApiUrl: savedLive.isEmpty ? subscription.url : savedLive
            )
            defaults.set(subscription.url, forKey: HawkConfig.API_URL)
            appState.applyLoadedConfigState()
            objectWillChange.send()
            return true
        } catch {
            if !(error is CancellationError) {
                lastError = "切换「\(subscription.name)」失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([VodSubscription].self, from: data) {
            subscriptions = decoded
        }
        // 兼容旧版本：只保存过单个点播地址时，迁移为第一条订阅。
        let legacy = (defaults.string(forKey: HawkConfig.API_URL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            upsert(url: legacy)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// 设置 ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    /// 当输入地址是“多仓库入口”时，先弹出候选仓库供用户确认。
    struct PendingMultiRepoSelection: Identifiable {
        /// 当前待选择的是点播仓库还是直播仓库。
        enum Target {
            case vod
            case live
            
            var title: String {
                switch self {
                case .vod: return "点播"
                case .live: return "直播"
                }
            }
        }
        
        let id = UUID()
        /// 目标类型。
        let target: Target
        /// 用户原始输入地址（用于后续“是否联动 live 地址”判断）。
        let sourceUrl: String
        /// 可选仓库列表。
        let options: [ApiConfig.MultiRepoOption]
    }
    
    /// 点播配置地址。
    @Published var vodApiUrl: String = ""
    /// 直播配置地址。
    @Published var liveApiUrl: String = ""
    /// 配置加载中状态。
    @Published var isLoadingConfig = false
    /// 配置错误提示。
    @Published var configError: String?
    /// 配置是否加载成功（供 UI 执行后续跳转/收起流程）。
    @Published var configSuccess = false
    /// 多仓库待选状态，为 nil 表示无需弹窗。
    @Published var pendingMultiRepoSelection: PendingMultiRepoSelection?
    /// 最近输入过的 API 历史。
    @Published var apiHistory: [String] = []
    /// 点播播放器内核选择。
    @Published var vodPlayerEngine: PlayerEngine = .system
    /// 直播播放器内核选择。
    @Published var livePlayerEngine: PlayerEngine = .system
    /// 解码模式选择。
    @Published var decodeMode: VideoDecodeMode = .auto
    /// VLC 缓冲策略。
    @Published var vlcBufferMode: VLCBufferMode = .defaultMode
    /// 快进/快退步长（秒）。
    @Published var playTimeStep: Int = 10
    /// 缓存占用展示文本。
    @Published var cacheSizeString: String = "0 KB"
    
    /// 快进步长候选项。
    let playTimeStepOptions: [Int] = [5, 10, 15, 30, 60]
    /// 当前构建可用播放器列表。
    let playerEngineOptions: [PlayerEngine] = PlayerEngine.availableEngines
    /// 解码模式候选。
    let decodeModeOptions: [VideoDecodeMode] = VideoDecodeMode.allCases
    /// VLC 缓冲模式候选。
    let vlcBufferModeOptions: [VLCBufferMode] = VLCBufferMode.allCases
    
    /// 初始化时完成三件事：
    /// 1) 回填已保存的配置地址
    /// 2) 兼容老版本单一播放器字段到新字段
    /// 3) 回填播放/缓存相关设置
    init() {
        let defaults = UserDefaults.standard
        let savedVod = defaults.string(forKey: HawkConfig.API_URL) ?? ""
        vodApiUrl = savedVod
        if let savedLive = defaults.string(forKey: HawkConfig.LIVE_API_URL) {
            liveApiUrl = savedLive
        } else {
            liveApiUrl = savedVod
        }
        loadApiHistory()
        let hasLegacyPlayer = defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil
        let legacyPlayerRaw = defaults.integer(forKey: HawkConfig.PLAY_TYPE)
        let defaultVodRaw = PlayerEngine.system.rawValue
        let defaultLiveRaw = PlayerEngine.isVLCAvailable
            ? PlayerEngine.vlc.rawValue
            : PlayerEngine.system.rawValue
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultVodRaw, forKey: HawkConfig.PLAY_TYPE_VOD)
        }
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultLiveRaw, forKey: HawkConfig.PLAY_TYPE_LIVE)
        }
        vodPlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_VOD)
        )
        livePlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_LIVE)
        )
        decodeMode = VideoDecodeMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        vlcBufferMode = VLCBufferMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )
        
        let savedStep = defaults.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        playTimeStep = savedStep > 0 ? savedStep : 10
        refreshCacheSize()
    }
    
    /// 加载配置
    func loadConfig() async {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            configError = "请输入点播接口地址"
            return
        }
        
        isLoadingConfig = true
        configError = nil
        configSuccess = false
        pendingMultiRepoSelection = nil
        
        do {
            let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
            
            // 若探测到多仓库入口，先中断加载并弹出候选，让用户显式选定目标仓库。
            if let pending = try await detectPendingMultiRepoSelection(
                vodUrl: trimmedVod,
                liveUrl: resolvedLive
            ) {
                pendingMultiRepoSelection = pending
                isLoadingConfig = false
                return
            }
            
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            // 保存用户输入（live 允许空值，表示跟随点播地址）。
            UserDefaults.standard.set(trimmedVod, forKey: HawkConfig.API_URL)
            UserDefaults.standard.set(trimmedLive, forKey: HawkConfig.LIVE_API_URL)
            vodApiUrl = trimmedVod
            liveApiUrl = trimmedLive
            // 手动输入并加载成功的点播地址同步进订阅列表
            VodSubscriptionStore.shared.upsert(url: trimmedVod)
            addToApiHistory(trimmedVod)
            addToApiHistory(resolvedLive)
            configSuccess = true
        } catch {
            configError = error.localizedDescription
        }
        
        isLoadingConfig = false
    }
    
    /// 从持久化重新读取点播/直播地址（订阅在别处切换后保持一致，避免编辑直播地址时把点播地址改回旧值）。
    func syncSavedUrls() {
        let defaults = UserDefaults.standard
        vodApiUrl = defaults.string(forKey: HawkConfig.API_URL) ?? ""
        liveApiUrl = defaults.string(forKey: HawkConfig.LIVE_API_URL) ?? ""
    }

    /// 处理多仓库弹窗选择结果，并继续走统一加载流程。
    func selectPendingMultiRepoOption(_ option: ApiConfig.MultiRepoOption) async {
        guard let pending = pendingMultiRepoSelection else { return }
        let normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl)
        
        switch pending.target {
        case .vod:
            let normalizedLive = ApiConfig.normalizeConfigUrl(liveApiUrl)
            // 若 live 输入与原始 vod 相同，说明用户希望两者共用，选择后同步更新。
            let shouldSyncLive = !liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalizedLive == normalizedSource
            vodApiUrl = option.url
            if shouldSyncLive {
                liveApiUrl = option.url
            }
        case .live:
            liveApiUrl = option.url
        }
        
        pendingMultiRepoSelection = nil
        await loadConfig()
    }
    
    /// 取消多仓库选择，恢复到普通待输入状态。
    func cancelPendingMultiRepoSelection() {
        pendingMultiRepoSelection = nil
        isLoadingConfig = false
    }
    
    /// 尝试识别输入地址是否为多仓库入口。
    /// - Returns: 需要弹窗选择时返回待选对象，否则返回 `nil`。
    private func detectPendingMultiRepoSelection(
        vodUrl: String,
        liveUrl: String
    ) async throws -> PendingMultiRepoSelection? {
        if let vodOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: vodUrl) {
            guard !vodOptions.isEmpty else {
                throw ConfigError.parseError("点播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .vod,
                sourceUrl: vodUrl,
                options: vodOptions
            )
        }
        
        let normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl)
        let normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl)
        guard normalizedLive != normalizedVod else {
            return nil
        }
        
        if let liveOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: liveUrl) {
            guard !liveOptions.isEmpty else {
                throw ConfigError.parseError("直播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .live,
                sourceUrl: liveUrl,
                options: liveOptions
            )
        }
        
        return nil
    }
    
    // MARK: - API 历史
    
    /// 读取 API 历史。
    private func loadApiHistory() {
        apiHistory = UserDefaults.standard.stringArray(forKey: "api_history") ?? []
    }
    
    /// 新增历史并去重，最多保留 10 条。
    private func addToApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        apiHistory.insert(url, at: 0)
        if apiHistory.count > 10 {
            apiHistory = Array(apiHistory.prefix(10))
        }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 删除单条 API 历史。
    func removeApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 清除所有缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        ImageLoader.shared.clearCache()
        ImageCache.shared.clear()
        refreshCacheSize()
    }
    
    /// 设置快进步长
    func setPlayTimeStep(_ step: Int) {
        guard step > 0 else { return }
        playTimeStep = step
        UserDefaults.standard.set(step, forKey: HawkConfig.PLAY_TIME_STEP)
    }
    
    /// 设置点播播放器内核
    func setVodPlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        vodPlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
    }
    
    /// 设置直播播放器内核
    func setLivePlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        livePlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_LIVE)
    }
    
    /// 设置视频解码模式
    func setDecodeMode(_ mode: VideoDecodeMode) {
        guard decodeModeOptions.contains(mode) else { return }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_DECODE_MODE)
    }

    /// 设置 VLC 缓冲策略
    func setVLCBufferMode(_ mode: VLCBufferMode) {
        guard vlcBufferModeOptions.contains(mode) else { return }
        vlcBufferMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
    }
    
    /// 统计并刷新缓存占用展示（网络缓存 + 图片缓存磁盘占用）。
    private func refreshCacheSize() {
        let sharedDisk = URLCache.shared.currentDiskUsage
        let imageDisk = ImageLoader.shared.cacheUsage.disk
        cacheSizeString = Self.formatSize(bytes: sharedDisk + imageDisk)
    }
    
    /// 格式化字节大小。
    private static func formatSize(bytes: Int) -> String {
        let size = max(0, bytes)
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        }
        return String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
    }
}
