import Foundation

/// 电影/视频数据模型 - 对应 Android 版 Movie.java
struct Movie: Codable {
    /// 列表数据主体。
    var videoList: [Video] = []
    /// 总页数。
    var pagecount: Int = 0
    /// 当前页码。
    var page: Int = 0
    /// 总条数。
    var total: Int = 0
    /// 每页条数。
    var limit: Int = 0
    
    /// 单个视频条目
    struct Video: Codable, Identifiable, Hashable {
        /// 视频唯一 ID（接口可能返回 Int 或 String，见自定义解码）。
        var id: String
        /// 片名。
        var name: String = ""
        /// 海报地址。
        var pic: String = ""
        /// 备注（如“更新至第20集”）。
        var note: String = ""
        /// 年份。
        var year: String = ""
        /// 地区。
        var area: String = ""
        /// 类型/分类名。
        var type: String = ""
        /// 导演。
        var director: String = ""
        /// 演员。
        var actor: String = ""
        /// 简介。
        var des: String = ""
        /// 来源站点 key，用于跨源隔离收藏与历史。
        var sourceKey: String = ""
        /// 分类 ID。
        var tid: String = ""
        /// 最后更新时间。
        var last: String = ""
        /// 播放来源信息（部分接口会复用该字段）。
        var dt: String = ""
        /// 评分（优先豆瓣评分 `vod_douban_score`，其次站内评分 `vod_score`），用于排序。
        var score: Double = 0
        /// 热度/点击数（`vod_hits`），用于"热门"排序。
        var hits: Int = 0

        init(id: String = UUID().uuidString, name: String = "", pic: String = "",
             note: String = "", sourceKey: String = "") {
            self.id = id
            self.name = name
            self.pic = pic
            self.note = note
            self.sourceKey = sourceKey
        }
        
        enum CodingKeys: String, CodingKey {
            case id = "vod_id"
            case name = "vod_name"
            case pic = "vod_pic"
            case note = "vod_remarks"
            case year = "vod_year"
            case area = "vod_area"
            case type = "type_name"
            case director = "vod_director"
            case actor = "vod_actor"
            case des = "vod_content"
            case tid = "type_id"
            case last = "vod_time"
            case dt = "vod_play_from"
            case sourceKey
            case score = "vod_score"
            case doubanScore = "vod_douban_score"
            case hits = "vod_hits"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(pic, forKey: .pic)
            try container.encode(note, forKey: .note)
            try container.encode(year, forKey: .year)
            try container.encode(area, forKey: .area)
            try container.encode(type, forKey: .type)
            try container.encode(director, forKey: .director)
            try container.encode(actor, forKey: .actor)
            try container.encode(des, forKey: .des)
            try container.encode(tid, forKey: .tid)
            try container.encode(last, forKey: .last)
            try container.encode(dt, forKey: .dt)
            try container.encode(sourceKey, forKey: .sourceKey)
            try container.encode(score, forKey: .score)
            try container.encode(hits, forKey: .hits)
        }

        /// 兼容数字/字符串两种形态的数值字段（如 `"8.5"`、`8.5`、`"1234"`）。
        private static func decodeLossyDouble(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Double(text.trimmingCharacters(in: .whitespaces)) {
                return value
            }
            return 0
        }
        
        /// 自定义解码以兼容多源字段类型差异（如 `vod_id` / `type_id` 可能是 Int 或 String）。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // 支持 String 或 Int 类型的 id
            if let intId = try? container.decode(Int.self, forKey: .id) {
                self.id = String(intId)
            } else {
                self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            }
            self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
            self.pic = (try? container.decode(String.self, forKey: .pic)) ?? ""
            self.note = (try? container.decode(String.self, forKey: .note)) ?? ""
            self.year = (try? container.decode(String.self, forKey: .year)) ?? ""
            self.area = (try? container.decode(String.self, forKey: .area)) ?? ""
            self.type = (try? container.decode(String.self, forKey: .type)) ?? ""
            self.director = (try? container.decode(String.self, forKey: .director)) ?? ""
            self.actor = (try? container.decode(String.self, forKey: .actor)) ?? ""
            self.des = (try? container.decode(String.self, forKey: .des)) ?? ""
            self.tid = {
                if let intTid = try? container.decode(Int.self, forKey: .tid) {
                    return String(intTid)
                }
                return (try? container.decode(String.self, forKey: .tid)) ?? ""
            }()
            self.last = (try? container.decode(String.self, forKey: .last)) ?? ""
            self.dt = (try? container.decode(String.self, forKey: .dt)) ?? ""
            self.sourceKey = (try? container.decode(String.self, forKey: .sourceKey)) ?? ""
            let doubanScore = Self.decodeLossyDouble(container, .doubanScore)
            self.score = doubanScore > 0 ? doubanScore : Self.decodeLossyDouble(container, .score)
            self.hits = Int(Self.decodeLossyDouble(container, .hits))
        }
    }
}
