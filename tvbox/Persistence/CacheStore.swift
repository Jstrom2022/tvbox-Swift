import Foundation
import SwiftData

/// SwiftData 持久化模型 - 对应 Android 版 Room 数据库

/// 收藏/历史的业务唯一键（source + vodId）。
/// 两个字段按 JSON 数组编码，任意字符（含 `::`、空白、Unicode）都能一一对应，不会出现拼接歧义。
func makeVodBusinessKey(vodId: String, sourceKey: String) -> String {
    guard let data = try? JSONEncoder().encode([sourceKey, vodId]) else {
        return "\(sourceKey.utf8.count):\(sourceKey)\(vodId)"
    }
    return String(decoding: data, as: UTF8.self)
}

/// 单部剧的续播状态
struct VodPlaybackState: Codable {
    /// 当前播放线路标识。
    var flag: String
    /// 剧集索引。
    var episodeIndex: Int
    /// 播放进度（秒）。
    var progressSeconds: Double
}

/// 视频收藏
@Model
final class VodCollect {
    /// 业务唯一键（sourceKey + vodId）。
    var bizKey: String = ""
    /// 视频 ID（与 sourceKey 组成唯一语义键）。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 来源站点接口身份（旧记录为空），用于识别同名 key 已指向其他站点的情况。
    var sourceApi: String = ""
    /// 最近更新时间（收藏创建/刷新时间）。
    var updateTime: Date = Date()

    init(vodId: String, vodName: String, vodPic: String, sourceKey: String, sourceApi: String = "") {
        self.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.sourceApi = sourceApi
        self.updateTime = Date()
    }
}

/// 播放历史记录
@Model
final class VodRecord {
    /// 业务唯一键（sourceKey + vodId）。
    var bizKey: String = ""
    /// 视频 ID。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 来源站点接口身份（旧记录为空），用于识别同名 key 已指向其他站点的情况。
    var sourceApi: String = ""
    /// 播放标记，如“第5集 03:45”。
    var playNote: String = ""
    /// 续播状态 JSON（`VodPlaybackState` 编码结果）。
    var dataJson: String = ""
    /// 最近播放时间。
    var updateTime: Date = Date()

    init(vodId: String, vodName: String, vodPic: String, sourceKey: String, sourceApi: String = "", playNote: String = "") {
        self.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.sourceApi = sourceApi
        self.playNote = playNote
        self.updateTime = Date()
    }
}

/// 通用缓存
@Model
final class CacheItem {
    /// 唯一缓存键。
    @Attribute(.unique) var key: String = ""
    /// 缓存值（字符串形式）。
    var value: String = ""
    /// 更新时间。
    var updateTime: Date = Date()

    init(key: String, value: String) {
        self.key = key
        self.value = value
        self.updateTime = Date()
    }
}

/// 缓存管理器
///
/// 收藏/历史按 (sourceKey, vodId) 两个独立字段匹配，不依赖拼接键；
/// 记录了来源接口身份时，接口不同的同名来源视为不同站点，彼此不会覆盖。
actor CacheStore {
    static let shared = CacheStore()
    /// 业务键编码版本，低于该版本的库在启动时重写 bizKey。
    private static let bizKeyVersion = 2
    private static let bizKeyVersionDefaultsKey = "vod_biz_key_version"

    private init() {}

    /// 旧版本使用 `source::vod` 拼接业务键，存在歧义；启动时按记录中原有的 sourceKey/vodId 重写。
    /// 只重写键，不删除或合并任何记录，避免误删不同来源的数据。
    nonisolated static func migrateBusinessKeysIfNeeded(in container: ModelContainer, defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: bizKeyVersionDefaultsKey) < bizKeyVersion else { return }
        let context = ModelContext(container)
        do {
            for record in try context.fetch(FetchDescriptor<VodRecord>()) {
                record.bizKey = makeVodBusinessKey(vodId: record.vodId, sourceKey: record.sourceKey)
            }
            for collect in try context.fetch(FetchDescriptor<VodCollect>()) {
                collect.bizKey = makeVodBusinessKey(vodId: collect.vodId, sourceKey: collect.sourceKey)
            }
            if context.hasChanges {
                try context.save()
            }
            defaults.set(bizKeyVersion, forKey: bizKeyVersionDefaultsKey)
        } catch {
            print("迁移收藏/历史业务键失败: \(error)")
        }
    }

    @MainActor
    func addCollect(_ video: Movie.Video, context: ModelContext) {
        let vodId = video.vodId
        let sourceKey = video.sourceKey
        let sourceApi = video.sourceApi

        do {
            let matched = try fetchCollects(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi, context: context)
            if let first = matched.first {
                first.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
                if !sourceApi.isEmpty {
                    first.sourceApi = sourceApi
                }
                first.vodName = video.name
                first.vodPic = video.pic
                first.updateTime = Date()
                for duplicate in matched.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                let collect = VodCollect(
                    vodId: vodId,
                    vodName: video.name,
                    vodPic: video.pic,
                    sourceKey: sourceKey,
                    sourceApi: sourceApi
                )
                context.insert(collect)
            }
            try context.save()
        } catch {
            print("写入收藏失败: \(error)")
        }
    }

    @MainActor
    func removeCollect(vodId: String, sourceKey: String, sourceApi: String = "", context: ModelContext) {
        do {
            let items = try fetchCollects(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi, context: context)
            guard !items.isEmpty else { return }
            for item in items {
                context.delete(item)
            }
            try context.save()
        } catch {
            print("删除收藏失败: \(error)")
        }
    }

    @MainActor
    func isCollected(vodId: String, sourceKey: String, sourceApi: String = "", context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<VodCollect>(
            predicate: Self.collectPredicate(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi)
        )

        do {
            let count = try context.fetchCount(descriptor)
            return count > 0
        } catch {
            print("查询收藏状态失败: \(error)")
            return false
        }
    }

    @MainActor
    func addRecord(
        _ video: Movie.Video,
        playNote: String,
        playbackState: VodPlaybackState? = nil,
        context: ModelContext
    ) {
        let vodId = video.vodId
        let sourceKey = video.sourceKey
        let sourceApi = video.sourceApi
        let encodedState = Self.encodePlaybackState(playbackState)

        do {
            let matched = try fetchRecords(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi, context: context)

            // 更新或插入
            if let record = matched.first {
                record.bizKey = makeVodBusinessKey(vodId: vodId, sourceKey: sourceKey)
                if !sourceApi.isEmpty {
                    record.sourceApi = sourceApi
                }
                record.playNote = playNote
                if let encodedState {
                    record.dataJson = encodedState
                }
                record.updateTime = Date()
                for duplicate in matched.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                let record = VodRecord(
                    vodId: vodId,
                    vodName: video.name,
                    vodPic: video.pic,
                    sourceKey: sourceKey,
                    sourceApi: sourceApi,
                    playNote: playNote
                )
                if let encodedState {
                    record.dataJson = encodedState
                }
                context.insert(record)
            }

            try context.save()
        } catch {
            print("写入播放记录失败: \(error)")
        }
    }

    /// 读取续播状态（若无记录或 JSON 无法解码则返回 `nil`）。
    @MainActor
    func getPlaybackState(vodId: String, sourceKey: String, sourceApi: String = "", context: ModelContext) -> VodPlaybackState? {
        do {
            guard let record = try fetchRecords(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi, context: context).first else {
                return nil
            }
            return Self.decodePlaybackState(record.dataJson)
        } catch {
            print("读取续播状态失败: \(error)")
            return nil
        }
    }

    /// 用户确认“仍然打开”后，把记录关联到当前的来源接口。
    @MainActor
    func remapSourceApi(vodId: String, sourceKey: String, from oldApi: String, to newApi: String, context: ModelContext) {
        guard !newApi.isEmpty, oldApi != newApi else { return }
        do {
            for record in try fetchRecords(vodId: vodId, sourceKey: sourceKey, sourceApi: oldApi, context: context) {
                record.sourceApi = newApi
            }
            for collect in try fetchCollects(vodId: vodId, sourceKey: sourceKey, sourceApi: oldApi, context: context) {
                collect.sourceApi = newApi
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            print("更新记录来源失败: \(error)")
        }
    }

    @MainActor
    func clearHistory(context: ModelContext) {
        do {
            try context.delete(model: VodRecord.self)
            try context.save()
        } catch {
            print("清空历史记录失败: \(error)")
        }
    }

    @MainActor
    private func fetchRecords(vodId: String, sourceKey: String, sourceApi: String, context: ModelContext) throws -> [VodRecord] {
        let descriptor = FetchDescriptor<VodRecord>(
            predicate: Self.recordPredicate(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi)
        )
        return try context.fetch(descriptor).sorted(by: { $0.updateTime > $1.updateTime })
    }

    @MainActor
    private func fetchCollects(vodId: String, sourceKey: String, sourceApi: String, context: ModelContext) throws -> [VodCollect] {
        let descriptor = FetchDescriptor<VodCollect>(
            predicate: Self.collectPredicate(vodId: vodId, sourceKey: sourceKey, sourceApi: sourceApi)
        )
        return try context.fetch(descriptor).sorted(by: { $0.updateTime > $1.updateTime })
    }

    /// 按 (sourceKey, vodId) 匹配；查询方知道接口身份时，只匹配同一接口或尚未记录接口的旧数据。
    private nonisolated static func recordPredicate(vodId: String, sourceKey: String, sourceApi: String) -> Predicate<VodRecord> {
        if sourceApi.isEmpty {
            return #Predicate<VodRecord> { item in
                item.sourceKey == sourceKey && item.vodId == vodId
            }
        }
        return #Predicate<VodRecord> { item in
            item.sourceKey == sourceKey && item.vodId == vodId
                && (item.sourceApi == "" || item.sourceApi == sourceApi)
        }
    }

    private nonisolated static func collectPredicate(vodId: String, sourceKey: String, sourceApi: String) -> Predicate<VodCollect> {
        if sourceApi.isEmpty {
            return #Predicate<VodCollect> { item in
                item.sourceKey == sourceKey && item.vodId == vodId
            }
        }
        return #Predicate<VodCollect> { item in
            item.sourceKey == sourceKey && item.vodId == vodId
                && (item.sourceApi == "" || item.sourceApi == sourceApi)
        }
    }

    private nonisolated static func encodePlaybackState(_ state: VodPlaybackState?) -> String? {
        guard let state else { return nil }
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 从 JSON 字符串反序列化续播状态。
    private nonisolated static func decodePlaybackState(_ json: String) -> VodPlaybackState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VodPlaybackState.self, from: data)
    }
}
