import Foundation

/// 视频详情模型 - 对应 Android 版 VodInfo.java
struct VodInfo: Codable, Identifiable {
    /// 视频唯一 ID。
    var id: String
    /// 标题。
    var name: String = ""
    /// 海报地址。
    var pic: String = ""
    /// 备注（更新状态等）。
    var note: String = ""
    /// 年份。
    var year: String = ""
    /// 地区。
    var area: String = ""
    /// 类型名。
    var typeName: String = ""
    /// 导演。
    var director: String = ""
    /// 演员。
    var actor: String = ""
    /// 简介。
    var des: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    
    /// 播放来源（线路）列表
    var playFlags: [String] = []
    /// key: flag名称, value: 剧集列表
    var playUrlMap: [String: [Episode]] = [:]
    
    /// 当前选中线路。
    var playFlag: String = ""
    /// 当前播放剧集索引。
    var playIndex: Int = 0
    
    /// 单集信息
    struct Episode: Codable, Identifiable, Hashable {
        var id: String { name }
        /// 集标题。
        let name: String
        /// 集播放地址。
        let url: String
        
        init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }
    
    /// 从 Movie.Video 和详情数据构建
    static func from(video: Movie.Video, playFrom: String, playUrl: String) -> VodInfo {
        var info = VodInfo(id: video.vodId)
        info.name = video.name
        info.pic = video.pic
        info.note = video.note
        info.year = video.year
        info.area = video.area
        info.typeName = video.type
        info.director = video.director
        info.actor = video.actor
        info.des = video.des.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        info.sourceKey = video.sourceKey
        
        let lines = parsePlayLines(playFrom: playFrom, playUrl: playUrl)
        info.playFlags = lines.map(\.flag)
        for line in lines {
            info.playUrlMap[line.flag] = line.episodes
        }

        if let first = lines.first {
            info.playFlag = first.flag
        }

        return info
    }

    /// 解析播放列表：
    /// - playFrom 格式: "线路1$$$线路2$$$线路3"
    /// - playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
    ///
    /// 线路名与剧集组先按原始位置一一配对，再过滤没有剧集的线路，空槽不会让后续线路错位；
    /// 空线路名、多出来的剧集组生成“线路N”，重名线路追加序号，避免字典后写覆盖前写。
    static func parsePlayLines(playFrom: String, playUrl: String) -> [(flag: String, episodes: [Episode])] {
        let rawFlags = playFrom.components(separatedBy: "$$$")
        let rawGroups = playUrl.components(separatedBy: "$$$")
        var lines: [(flag: String, episodes: [Episode])] = []
        var usedFlags: Set<String> = []

        for (index, group) in rawGroups.enumerated() {
            let episodes = parseEpisodes(group)
            guard !episodes.isEmpty else { continue }

            let rawFlag = index < rawFlags.count
                ? rawFlags[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let baseFlag = rawFlag.isEmpty ? "线路\(index + 1)" : rawFlag
            var flag = baseFlag
            var duplicateIndex = 2
            while usedFlags.contains(flag) {
                flag = "\(baseFlag) \(duplicateIndex)"
                duplicateIndex += 1
            }
            usedFlags.insert(flag)
            lines.append((flag: flag, episodes: episodes))
        }

        return lines
    }

    /// 解析单条线路的剧集：每集只按第一个 `$` 拆分名称与地址，地址中的 `$` 原样保留。
    /// 只有地址没有集名的条目（部分源的写法）按顺序生成“第N集”。
    static func parseEpisodes(_ group: String) -> [Episode] {
        var episodes: [Episode] = []
        for item in group.components(separatedBy: "#") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let name: String
            let url: String
            if let separator = trimmed.firstIndex(of: "$") {
                name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                url = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.contains("://") {
                name = ""
                url = trimmed
            } else {
                continue
            }
            guard !url.isEmpty else { continue }
            episodes.append(Episode(name: name.isEmpty ? "第\(episodes.count + 1)集" : name, url: url))
        }
        return episodes
    }
    
    /// 当前线路下的剧集。
    var currentEpisodes: [Episode] {
        playUrlMap[playFlag] ?? []
    }
    
    /// 当前线路 + 当前索引对应的剧集对象。
    var currentEpisode: Episode? {
        let eps = currentEpisodes
        guard playIndex >= 0, playIndex < eps.count else { return nil }
        return eps[playIndex]
    }
}
