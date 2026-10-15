import Foundation

/// 视频源站点配置 - 对应 Android 版 SourceBean.java
struct SourceBean: Codable, Identifiable, Hashable {
    /// 以源 key 作为稳定标识。
    var id: String { key }
    
    /// 源唯一键。
    let key: String
    /// 源显示名。
    let name: String
    /// 源接口地址。
    let api: String
    /// 搜索开关：0 关闭，非 0 开启（drpy 规则常用 2）。
    let searchable: Int
    /// 是否允许出现在首页分类：0 不可选，1 可选。
    let filterable: Int
    /// 快速搜索开关：0 关闭，非 0 开启（主要用于 remote 源 quick 参数）。
    let quickSearch: Int
    /// 源声明的播放器类型（历史字段，Swift 端目前主要走统一播放器策略）。
    let playerType: Int
    /// 源协议类型：0 XML，1 JSON，3 Spider（JAR/JS/PY 等端上执行的爬虫），4 Remote。
    let type: Int
    /// 扩展参数（remote 源常用）。
    let ext: String?
    
    init(key: String = "", name: String = "", api: String = "",
         searchable: Int = 1, filterable: Int = 1, quickSearch: Int = 0,
         playerType: Int = 0, type: Int = 1, ext: String? = nil) {
        self.key = key
        self.name = name
        self.api = api
        self.searchable = searchable
        self.filterable = filterable
        self.quickSearch = quickSearch
        self.playerType = playerType
        self.type = type
        self.ext = ext
    }
    
    /// 与 Android 端一致：searchable / quickSearch 非 0 即开启。
    var isSearchable: Bool { searchable != 0 }
    var isFilterable: Bool { filterable == 1 }
    var isQuickSearchEnabled: Bool { quickSearch != 0 }
    
    /// 是否在 Swift 版中受支持（type=3 为端上执行的爬虫，需要 JAR/JS/Python 等脚本运行时，暂不支持）
    var isSupportedInSwift: Bool {
        return type == 0 || type == 1 || type == 4
    }

    /// 播放前是否需要先调用源的 play 接口换取真实播放地址（T4 的剧集地址多为网页地址或编码 ID）。
    var requiresPlayResolution: Bool {
        type == 4
    }
    
    /// 类型描述
    var typeDescription: String {
        switch type {
        case 0: return "XML"
        case 1: return "JSON"
        case 3: return spiderKindDescription
        case 4: return "Remote"
        default: return "未知"
        }
    }

    /// type=3 爬虫的实现形式：按 api 后缀区分 JS / PY / PHP 脚本，其余（csp_ 类名）为 JAR。
    private var spiderKindDescription: String {
        var path = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<end])
        }
        if path.hasSuffix(".js") { return "JS" }
        if path.hasSuffix(".py") { return "PY" }
        if path.hasSuffix(".php") { return "PHP" }
        return "JAR"
    }
    
    /// api 字段是否为有效 HTTP URL
    var isHttpApi: Bool {
        return api.hasPrefix("http://") || api.hasPrefix("https://")
    }
}
