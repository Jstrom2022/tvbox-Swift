import Foundation

/// 分类排序模型 - 对应 Android 版 MovieSort.java
struct MovieSort: Codable {
    /// 分类列表（包含首页推荐、影视分类等）。
    var sortList: [SortData] = []
    
    /// 单个分类数据
    struct SortData: Codable, Identifiable, Hashable {
        /// 分类唯一标识（接口字段通常为 type_id）。
        var id: String
        /// 分类显示名。
        var name: String = ""
        /// 标记位（不同源可定义不同语义，常用于首页/推荐标识）。
        var flag: String = ""
        /// 分类下可选筛选项（年份、地区、类型等）。
        var filters: [SortFilter] = []
        
        init(id: String = "", name: String = "", flag: String = "") {
            self.id = id
            self.name = name
            self.flag = flag
        }
        
        /// 生成首页推荐占位分类。
        /// 该分类不走常规分类接口，直接渲染首页推荐列表。
        static func home() -> SortData {
            SortData(id: "home", name: "推荐", flag: "1")
        }

        /// 生成豆瓣片库占位分类（对应影视仓首页的豆瓣推荐）。
        /// 数据来自豆瓣，点击条目后按片名全源搜索。
        static func douban() -> SortData {
            SortData(id: "douban", name: "豆瓣", flag: "douban")
        }

        var isHome: Bool { id == "home" }
        var isDouban: Bool { id == "douban" }
    }
    
    /// 筛选条件
    struct SortFilter: Codable, Hashable {
        /// 接口参数键，例如 `year`、`area`。
        var key: String = ""
        /// UI 展示名称。
        var name: String = ""
        /// 可选值集合。
        var values: [SortFilterValue] = []
        
        struct SortFilterValue: Codable, Hashable {
            /// 展示名。
            var n: String = ""
            /// 真实参数值。
            var v: String = ""
        }

        /// 本地筛选项的 key 前缀：这类条件不会传给源接口，只在客户端过滤/排序。
        static let localKeyPrefix = "__"

        var isLocal: Bool { key.hasPrefix(Self.localKeyPrefix) }
    }
}

// MARK: - 内置筛选条件

extension MovieSort.SortFilter {
    /// 本地年份筛选 key（源未提供 year 筛选时使用）。
    static let localYearKey = "__year"
    /// 本地排序 key。
    static let localSortKey = "__sort"
    /// 本地年份"更早"取值。
    static let olderYearValue = "older"
    /// 本地年份筛选覆盖的年数（含当年）。
    static let recentYearSpan = 10

    /// 豆瓣：影视类型（movie / tv / show）。
    static let doubanKindKey = "__douban_kind"
    /// 豆瓣：排序（T 综合 / U 近期热度 / S 高分优先 / R 首映时间）。
    static let doubanSortKey = "__douban_sort"
    /// 豆瓣：年份标签（如 2024、2010年代）。
    static let doubanYearKey = "__douban_year"
    /// 豆瓣：地区标签（如 华语、欧美）。
    static let doubanAreaKey = "__douban_area"

    static var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    /// 本地年份筛选：全部 / 近十年逐年 / 更早。
    static func localYearFilter() -> MovieSort.SortFilter {
        let year = currentYear
        var values = [SortFilterValue(n: "全部", v: "")]
        values += (0..<recentYearSpan).map { SortFilterValue(n: String(year - $0), v: String(year - $0)) }
        values.append(SortFilterValue(n: "更早", v: olderYearValue))
        return MovieSort.SortFilter(key: localYearKey, name: "年份", values: values)
    }

    /// 本地排序：默认（源返回顺序）/ 最新 / 热门 / 评分。
    static func localSortFilter() -> MovieSort.SortFilter {
        MovieSort.SortFilter(key: localSortKey, name: "排序", values: [
            SortFilterValue(n: "默认", v: ""),
            SortFilterValue(n: "最新", v: "time"),
            SortFilterValue(n: "热门", v: "hits"),
            SortFilterValue(n: "豆瓣评分", v: "score")
        ])
    }

    /// 豆瓣分类下的筛选条件。
    static func doubanFilters() -> [MovieSort.SortFilter] {
        let year = currentYear
        var years = [SortFilterValue(n: "全部", v: "")]
        years += (0..<6).map { SortFilterValue(n: String(year - $0), v: String(year - $0)) }
        years += ["2020年代", "2010年代", "2000年代", "90年代", "80年代"].map { SortFilterValue(n: $0, v: $0) }

        return [
            MovieSort.SortFilter(key: doubanKindKey, name: "类型", values: [
                SortFilterValue(n: "电影", v: "movie"),
                SortFilterValue(n: "电视剧", v: "tv"),
                SortFilterValue(n: "综艺", v: "show")
            ]),
            MovieSort.SortFilter(key: doubanSortKey, name: "排序", values: [
                SortFilterValue(n: "综合", v: "T"),
                SortFilterValue(n: "近期热度", v: "U"),
                SortFilterValue(n: "高分优先", v: "S"),
                SortFilterValue(n: "首映时间", v: "R")
            ]),
            MovieSort.SortFilter(key: doubanYearKey, name: "年份", values: years),
            MovieSort.SortFilter(key: doubanAreaKey, name: "地区", values: [
                SortFilterValue(n: "全部", v: ""),
                SortFilterValue(n: "华语", v: "华语"),
                SortFilterValue(n: "欧美", v: "欧美"),
                SortFilterValue(n: "韩国", v: "韩国"),
                SortFilterValue(n: "日本", v: "日本")
            ])
        ]
    }
}
