import Foundation

/// 直播相关模型 - 对应 Android 版 LiveChannel*.java / Epginfo.java

/// 直播频道分组
struct LiveChannelGroup: Codable, Identifiable, Hashable {
    /// 以分组名作为稳定标识，便于 SwiftUI 列表 diff。
    var id: String { groupName }
    /// 分组名称（如“央视”“卫视”）。
    var groupName: String = ""
    /// 分组在列表中的顺序索引。
    var groupIndex: Int = 0
    /// 分组下频道列表。
    var channels: [LiveChannelItem] = []
    /// 是否为加密分组（当前实现仅保留字段，未启用密码校验）。
    var isPassword: Bool = false
    
    init(groupName: String = "", groupIndex: Int = 0) {
        self.groupName = groupName
        self.groupIndex = groupIndex
    }
}

/// 直播频道
struct LiveChannelItem: Codable, Identifiable, Hashable {
    /// 频道稳定身份：分组 + 频道名。同一分组内的同名频道会合并为一个频道，因此该组合唯一；
    /// 不使用数组下标，避免列表重排或增量加入后身份漂移、跨分组同名频道碰撞。
    struct Identity: Hashable {
        let groupName: String
        let channelName: String
    }

    var id: Identity { Identity(groupName: groupName, channelName: channelName) }
    /// 所属分组名。
    var groupName: String = ""
    /// 频道名。
    var channelName: String = ""
    /// 频道在分组内的顺序索引。
    var channelIndex: Int = 0
    /// 多线路播放地址。
    var channelUrls: [String] = []
    /// 各线路要求的 User-Agent（来自直播配置的 `ua` 字段），key 为线路地址。
    var userAgents: [String: String] = [:]
    /// 当前选中的线路索引。
    var sourceIndex: Int = 0
    /// 可用线路总数。
    var sourceNum: Int { channelUrls.count }
    /// 台标地址（预留）。
    var logo: String = ""

    init(channelName: String = "", channelIndex: Int = 0, groupName: String = "") {
        self.channelName = channelName
        self.channelIndex = channelIndex
        self.groupName = groupName
    }

    /// 当前线路对应的播放地址。
    /// 当索引越界时兜底返回第一条线路，避免直接播放失败。
    var currentUrl: String? {
        guard sourceIndex >= 0, sourceIndex < channelUrls.count else { return channelUrls.first }
        return channelUrls[sourceIndex]
    }

    /// 当前线路要求的 User-Agent；未配置时返回 nil，由播放器使用默认值。
    var currentUserAgent: String? {
        guard let url = currentUrl, let userAgent = userAgents[url], !userAgent.isEmpty else { return nil }
        return userAgent
    }
    
    /// 轮换到下一条线路。
    mutating func nextSource() {
        if channelUrls.count > 0 {
            sourceIndex = (sourceIndex + 1) % channelUrls.count
        }
    }
}

/// EPG 节目信息
struct Epginfo: Codable, Identifiable, Hashable {
    var id: String { "\(title)_\(startTime)" }
    var title: String = ""
    var startTime: String = ""
    var endTime: String = ""
    var index: Int = 0
    
    /// 根据 `HH:mm` 时间段判断节目是否正在播出。
    var isLive: Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let start = formatter.date(from: startTime),
              let end = formatter.date(from: endTime) else { return false }
        
        let now = formatter.date(from: formatter.string(from: Date()))!
        return now >= start && now < end
    }
}

/// EPG 日期分组
struct LiveEpgDate: Codable, Identifiable, Hashable {
    var id: String { datePresent }
    /// 供 UI 展示的日期文案。
    var datePresent: String = ""
    /// 供接口查询的原始日期值。
    var date: String = ""
    /// 在日期列表中的位置索引。
    var index: Int = 0
    /// 是否被当前 UI 选中。
    var isSelected: Bool = false
}
