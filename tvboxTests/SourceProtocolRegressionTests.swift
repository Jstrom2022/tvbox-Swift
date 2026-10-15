import Testing
import Foundation
@testable import TVBox

/// 源协议、播放列表与分页的回归测试（对应审计 B07–B12、B20）。
@Suite("源协议解析、查询参数与分页")
struct SourceProtocolRegressionTests {

    private let service = SourceService.shared

    @Test("分类筛选与原有分页协议兼容，数字筛选值转为字符串")
    func categoryFiltersSurviveProtocolParsing() throws {
        let json = #"{"class":[{"type_id":1,"type_name":"电影"}],"filters":{"1":[{"key":"year","name":"年份","value":[{"n":"全部","v":""},{"n":2026,"v":2026}]}]},"list":[]}"#
        let source = SourceBean(key: "s", name: "S", api: "http://h/api.php", type: 4)
        let result = try service.parseSort(json, sourceBean: source)
        let filter = try #require(result.sorts.first?.filters.first)
        #expect(filter.key == "year")
        #expect(filter.values.map(\.v) == ["", "2026"])
        #expect(result.homeVideos.isEmpty)
    }

    @Test("豆瓣评分与热度编码往返保留跨源视频身份")
    func ratingsPreserveVideoIdentity() throws {
        let data = Data(#"{"vod_id":42,"vod_name":"测试","vod_score":"7.1","vod_douban_score":"8.8","vod_hits":"123","sourceKey":"s","sourceApi":"https://example.invalid/api"}"#.utf8)
        let video = try JSONDecoder().decode(Movie.Video.self, from: data)
        #expect(video.vodId == "42")
        #expect(video.score == 8.8)
        #expect(video.hits == 123)
        let restored = try JSONDecoder().decode(Movie.Video.self, from: JSONEncoder().encode(video))
        #expect(restored == video)
        #expect(restored.id != Movie.Video(vodId: "42", sourceKey: "other").id)
    }

    // MARK: - 查询参数（B09）

    @Test("客户端参数覆盖基础地址里的同名参数，鉴权参数原样保留")
    func queryItemsReplaceExistingNames() throws {
        let url = try service.buildURL(
            base: "http://h/api.php?ac=class&token=Ab%2BC",
            queryItems: [URLQueryItem(name: "ac", value: "detail"), URLQueryItem(name: "ids", value: "1")]
        )
        let components = try #require(URLComponents(string: url))
        let items = components.queryItems ?? []
        #expect(items.filter { $0.name == "ac" }.map(\.value) == ["detail"])
        #expect(items.first { $0.name == "token" }?.value == "Ab+C")
        #expect(items.first { $0.name == "ids" }?.value == "1")
    }

    @Test("关键词与 base64 中的 + & = % 及中文按字面往返")
    func queryValuesRoundTripLiterally() throws {
        let values = ["A+B", "a&b=c", "100%", "中文 空格", "eyJhIjoiYiJ9+/="]
        for value in values {
            let url = try service.buildURL(base: "http://h/api.php", queryItems: [URLQueryItem(name: "wd", value: value)])
            #expect(!url.contains("wd=A+B"))
            // 按常见服务端的 form 解析：先把 + 当空格，再做百分号解码。
            let encoded = try #require(url.components(separatedBy: "wd=").last)
            let decoded = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            #expect(decoded == value)
        }
    }

    // MARK: - XML（B07）

    @Test("XML 列表支持普通文本、标签乱序、缺字段、字符串 ID 与实体")
    func xmlListIsParsedStructurally() throws {
        let xml = """
        <?xml version="1.0" encoding="gbk"?>
        <rss version="5.1">
        <list page="1" pagecount="3" pagesize="2" recordcount="5">
          <video><name>Demo</name><id>abc-1</id><note>HD</note></video>
          <video><id>2</id><pic>http://img/2.jpg?a=1&amp;b=2</pic><name><![CDATA[Tom & Jerry]]></name></video>
        </list>
        </rss>
        """
        let page = try service.parseVideoList(xml, sourceKey: "xml", type: 0)
        #expect(page.videos.map(\.vodId) == ["abc-1", "2"])
        #expect(page.videos[0].name == "Demo")
        #expect(page.videos[0].note == "HD")
        #expect(page.videos[1].name == "Tom & Jerry")
        #expect(page.videos[1].pic == "http://img/2.jpg?a=1&b=2")
        #expect(page.pageCount == 3)
        #expect(page.videos.allSatisfy { $0.sourceKey == "xml" })
    }

    @Test("XML 首页同时解析分类与首页视频")
    func xmlHomeIncludesVideos() throws {
        let xml = """
        <rss><list page="1" pagecount="1"><video><id>9</id><name>首页影片</name></video></list>
        <class><ty id="1">电影</ty><ty id="tv">剧集</ty></class></rss>
        """
        let source = SourceBean(key: "xml", name: "XML 源", api: "http://h/api.php", type: 0)
        let result = try service.parseSort(xml, sourceBean: source)
        #expect(result.sorts.map(\.id) == ["1", "tv"])
        #expect(result.homeVideos.map(\.vodId) == ["9"])
    }

    @Test("XML 详情读取 dl/dd 线路")
    func xmlDetailReadsPlayLines() throws {
        let xml = """
        <rss><list><video><id>5</id><name>剧</name>
        <dl><dd flag="m3u8"><![CDATA[第1集$http://a/1.m3u8#第2集$http://a/2.m3u8]]></dd><dd flag="mp4">正片$http://b/1.mp4</dd></dl>
        </video></list></rss>
        """
        let info = try #require(try service.parseDetail(xml, sourceKey: "xml", sourceName: "XML", type: 0, requestedId: "5"))
        #expect(info.playFlags == ["m3u8", "mp4"])
        #expect(info.playUrlMap["m3u8"]?.count == 2)
        #expect(info.playUrlMap["mp4"]?.first?.url == "http://b/1.mp4")
    }

    // MARK: - 无效响应（B08）

    @Test("HTML、损坏 JSON、业务错误都抛出解析错误，合法空列表返回空")
    func invalidResponsesThrow() throws {
        #expect(throws: SourceError.self) { try service.parseVideoList("<html>error</html>", sourceKey: "s", type: 1) }
        #expect(throws: SourceError.self) { try service.parseVideoList("{\"list\": [", sourceKey: "s", type: 1) }
        #expect(throws: SourceError.self) { try service.parseVideoList(#"{"code":0,"msg":"参数错误"}"#, sourceKey: "s", type: 1) }
        #expect(throws: SourceError.self) { try service.parseVideoList(#"{"list":"oops"}"#, sourceKey: "s", type: 1) }
        #expect(throws: SourceError.self) { try service.parseVideoList("<html>error</html>", sourceKey: "s", type: 0) }

        let empty = try service.parseVideoList(#"{"code":1,"page":1,"pagecount":0,"list":[]}"#, sourceKey: "s", type: 1)
        #expect(empty.videos.isEmpty)
    }

    @Test("详情接口忽略 ids 返回整页列表时不会误打开第一条")
    func detailDoesNotPickUnrelatedItem() throws {
        let json = #"{"list":[{"vod_id":1,"vod_name":"A"},{"vod_id":2,"vod_name":"B"}]}"#
        let matched = try service.parseDetail(json, sourceKey: "s", sourceName: "S", type: 1, requestedId: "2")
        #expect(matched?.name == "B")
        let missing = try service.parseDetail(json, sourceKey: "s", sourceName: "S", type: 1, requestedId: "3")
        #expect(missing == nil)
    }

    // MARK: - 播放列表（B20）

    @Test("剧集地址只按第一个 $ 拆分，地址中的 $ 保留")
    func episodeUrlKeepsDollar() {
        let episodes = VodInfo.parseEpisodes("E1$https://example.invalid/a$token.mp4#$http://x/2.mp4#http://x/3.mp4")
        #expect(episodes.map(\.url) == [
            "https://example.invalid/a$token.mp4",
            "http://x/2.mp4",
            "http://x/3.mp4"
        ])
        #expect(episodes[0].name == "E1")
        #expect(episodes[1].name == "第2集")
    }

    @Test("空线路不会让后续线路与地址错位，重名线路不会互相覆盖")
    func playLinesStayAligned() {
        let lines = VodInfo.parsePlayLines(
            playFrom: "a$$$$$$c$$$c",
            playUrl: "1$http://a.mp4$$$2$http://b.mp4$$$3$http://c.mp4$$$4$http://d.mp4"
        )
        #expect(lines.map(\.flag) == ["a", "线路2", "c", "c 2"])
        #expect(lines[2].episodes.first?.url == "http://c.mp4")
        #expect(lines[3].episodes.first?.url == "http://d.mp4")

        let emptyLine = VodInfo.parsePlayLines(playFrom: "a$$$b", playUrl: "1$http://a.mp4$$$")
        #expect(emptyLine.map(\.flag) == ["a"])
    }

    // MARK: - 分页（B12）

    @Test("服务端声明的分页边界会结束分页，重复末页不会继续")
    func paginationStopsAtServerBoundary() {
        let video = Movie.Video(vodId: "1", sourceKey: "s")
        let lastPage = SourceService.VideoPage(videos: [video], page: 1, pageCount: 1, total: 1, limit: 20)
        #expect(!HomeViewModel.hasMorePages(after: lastPage, newItemCount: 1))

        let middle = SourceService.VideoPage(videos: [video], page: 1, pageCount: 3, total: nil, limit: nil)
        #expect(HomeViewModel.hasMorePages(after: middle, newItemCount: 1))

        let repeated = SourceService.VideoPage(videos: [video], page: 2, pageCount: nil, total: nil, limit: nil)
        #expect(!HomeViewModel.hasMorePages(after: repeated, newItemCount: 0))

        let byTotal = SourceService.VideoPage(videos: [video], page: 2, pageCount: nil, total: 40, limit: 20)
        #expect(!HomeViewModel.hasMorePages(after: byTotal, newItemCount: 1))
    }

    // MARK: - 业务身份（B14）

    @Test("不同来源的相同 vod_id 拥有不同的列表身份")
    func videoIdentityIncludesSource() {
        let a = Movie.Video(vodId: "1", sourceKey: "A")
        let b = Movie.Video(vodId: "1", sourceKey: "B")
        #expect(a.id != b.id)
        #expect(Set([a.id, b.id]).count == 2)
    }

    // MARK: - T4 播放接口

    @Test("play 直链结果拼接 playUrl 前缀，header 对象与 headers 字符串合并")
    func t4PlayDirectResult() throws {
        let json = #"{"parse":0,"jx":0,"playUrl":"","url":"https://cdn.invalid/v/index.m3u8","header":{"Referer":"https://site.invalid/","User-Agent":"UA/1.0"},"headers":"{\"Cookie\":\"a=1\"}"}"#
        #expect(try service.parsePlay(json, sourceName: "T4") == .direct(
            url: "https://cdn.invalid/v/index.m3u8",
            headers: ["Referer": "https://site.invalid/", "User-Agent": "UA/1.0", "Cookie": "a=1"]
        ))

        let prefixed = #"{"parse":"0","playUrl":"https://proxy.invalid/?url=","url":"https://cdn.invalid/1.mp4"}"#
        #expect(try service.parsePlay(prefixed, sourceName: "T4") == .direct(
            url: "https://proxy.invalid/?url=https://cdn.invalid/1.mp4",
            headers: [:]
        ))
    }

    @Test("缺省 parse、parse=1、jx=1 的网页地址需要解析，媒体直链直接播放")
    func t4PlayParseFlags() throws {
        #expect(try service.parsePlay(#"{"url":"https://cdn.invalid/a.mp4?t=1"}"#, sourceName: "T4")
            == .direct(url: "https://cdn.invalid/a.mp4?t=1", headers: [:]))
        #expect(try service.parsePlay(#"{"url":"https://site.invalid/play/1.html"}"#, sourceName: "T4")
            == .needsParse(url: "https://site.invalid/play/1.html"))
        #expect(try service.parsePlay(#"{"parse":1,"jx":0,"url":"https://site.invalid/vod/1-1-1"}"#, sourceName: "T4")
            == .needsParse(url: "https://site.invalid/vod/1-1-1"))
        #expect(try service.parsePlay(#"{"parse":0,"jx":1,"url":"https://v.invalid/x/cover/1.html"}"#, sourceName: "T4")
            == .needsParse(url: "https://v.invalid/x/cover/1.html"))
        #expect(try service.parsePlay(#"{"parse":1,"url":"https://cdn.invalid/b.m3u8"}"#, sourceName: "T4")
            == .direct(url: "https://cdn.invalid/b.m3u8", headers: [:]))
        #expect(try service.parsePlay(#"{"parse":0,"url":"video://https://site.invalid/p/2"}"#, sourceName: "T4")
            == .needsParse(url: "https://site.invalid/p/2"))
    }

    @Test("多地址数组（含 JSON 字符串形式）取第一个 http 地址直接播放")
    func t4PlayURLArray() throws {
        let array = #"{"parse":1,"url":["原画","https://cdn.invalid/hd.m3u8","标清","https://cdn.invalid/sd.m3u8"]}"#
        #expect(try service.parsePlay(array, sourceName: "T4") == .direct(url: "https://cdn.invalid/hd.m3u8", headers: [:]))
        let stringified = #"{"url":"[\"线路\",\"https://cdn.invalid/x.mp4\"]"}"#
        #expect(try service.parsePlay(stringified, sourceName: "T4") == .direct(url: "https://cdn.invalid/x.mp4", headers: [:]))
    }

    @Test("没有地址时以 msg 为失败原因，proxy:// 与非 JSON 明确报错，有地址时忽略 msg")
    func t4PlayFailures() throws {
        #expect(throws: SourceError.self) { try service.parsePlay(#"{"parse":0,"url":"proxy://do=js&url=x"}"#, sourceName: "T4") }
        #expect(throws: SourceError.self) { try service.parsePlay(#"{"parse":0}"#, sourceName: "T4") }
        #expect(throws: SourceError.self) { try service.parsePlay("<html>502</html>", sourceName: "T4") }
        #expect(try service.parsePlay(#"{"msg":"success","parse":0,"url":"https://cdn.invalid/ok.mp4"}"#, sourceName: "T4")
            == .direct(url: "https://cdn.invalid/ok.mp4", headers: [:]))

        do {
            _ = try service.parsePlay(#"{"msg":"该资源已下架","url":""}"#, sourceName: "T4")
            Issue.record("没有播放地址时应当抛出错误")
        } catch {
            #expect(error.localizedDescription == "该资源已下架")
        }
    }

    @Test("媒体直链判定排除网页、解析接口与相对地址")
    func mediaURLHeuristics() {
        #expect(SourceService.looksLikeMediaURL("https://cdn.invalid/a/index.m3u8"))
        #expect(SourceService.looksLikeMediaURL("HTTP://cdn.invalid/a.MP4?token=1"))
        #expect(!SourceService.looksLikeMediaURL("https://jx.invalid/?url=https://cdn.invalid/a.m3u8"))
        #expect(!SourceService.looksLikeMediaURL("https://site.invalid/mp4/play.html"))
        #expect(!SourceService.looksLikeMediaURL("/relative/a.mp4"))
        #expect(!SourceService.looksLikeMediaURL("https://site.invalid/a.mp4abc"))
    }

    @Test("play 参数里的完整地址按字面传递，中文与方括号模块名、pwd 参数保持可用")
    func playQueryKeepsRawId() throws {
        let id = "https://site.invalid/play?id=1&ep=2#t=3"
        let url = try service.buildURL(
            base: "http://h:5757/api/腾云驾雾[官]?pwd=abc",
            queryItems: [URLQueryItem(name: "play", value: id), URLQueryItem(name: "flag", value: "线路 1")]
        )
        #expect(url.hasPrefix("http://h:5757/api/%E8%85%BE%E4%BA%91%E9%A9%BE%E9%9B%BE%5B%E5%AE%98%5D?"))
        let items = try #require(URLComponents(string: url)?.queryItems)
        #expect(items.first { $0.name == "play" }?.value == id)
        #expect(items.first { $0.name == "flag" }?.value == "线路 1")
        #expect(items.first { $0.name == "pwd" }?.value == "abc")
    }

    // MARK: - 来源标志与类型

    @Test("searchable / quickSearch 非 0 即开启（drpy 规则常用 2）")
    func searchFlagsMatchAndroid() {
        #expect(SourceBean(searchable: 2).isSearchable)
        #expect(SourceBean(searchable: 1).isSearchable)
        #expect(!SourceBean(searchable: 0).isSearchable)
        #expect(SourceBean(quickSearch: 2).isQuickSearchEnabled)
        #expect(!SourceBean(quickSearch: 0).isQuickSearchEnabled)
    }

    @Test("type=3 按 api 区分 JS / PY / PHP / JAR，仍不受支持；只有 T4 需要 play 接口")
    func spiderTypeLabels() {
        #expect(SourceBean(api: "http://h/public/drpy/drpy2.min.js", type: 3).typeDescription == "JS")
        #expect(SourceBean(api: "./js/demo.JS?v=2", type: 3).typeDescription == "JS")
        #expect(SourceBean(api: "http://h/py/demo.py", type: 3).typeDescription == "PY")
        #expect(SourceBean(api: "http://h/php/demo.php?pwd=1", type: 3).typeDescription == "PHP")
        #expect(SourceBean(api: "csp_XBPQ", type: 3).typeDescription == "JAR")
        #expect(!SourceBean(api: "http://h/demo.js", type: 3).isSupportedInSwift)
        #expect(SourceBean(api: "http://h/api/demo", type: 4).requiresPlayResolution)
        #expect(!SourceBean(api: "http://h/api.php", type: 1).requiresPlayResolution)
    }

    // MARK: - 远程接口的重试与错误提示

    @Test("T4 请求只重试连接错误：5xx 与超时不重试，默认策略保持原样")
    func remoteRetryPolicy() {
        let serverError = NetworkError.httpError(500)
        #expect(NetworkManager.isRetryableError(serverError))
        #expect(!NetworkManager.isRetryableError(serverError, policy: .connectionOnly))
        #expect(NetworkManager.isRetryableError(URLError(.timedOut)))
        #expect(!NetworkManager.isRetryableError(URLError(.timedOut), policy: .connectionOnly))
        #expect(NetworkManager.isRetryableError(URLError(.cannotConnectToHost), policy: .connectionOnly))
        #expect(!NetworkManager.isRetryableHTTPStatus(503, policy: .connectionOnly))
    }

    @Test("错误响应体里的服务端提示会出现在错误描述中")
    func serverMessageIsSurfaced() {
        let body = Data(#"{"error":"Failed to process module demo: boom"}"#.utf8)
        #expect(NetworkManager.serverMessage(from: body) == "Failed to process module demo: boom")
        #expect(NetworkManager.serverMessage(from: Data(#"{"code":500,"msg":"规则错误"}"#.utf8)) == "规则错误")
        #expect(NetworkManager.serverMessage(from: Data("<html>502 Bad Gateway</html>".utf8)) == nil)
        #expect(NetworkManager.serverMessage(from: Data(#"{"error":"  "}"#.utf8)) == nil)
        #expect(NetworkError.httpError(500, message: "boom").localizedDescription.contains("boom"))
        #expect(NetworkError.httpError(404).localizedDescription == "HTTP 错误: 404")
    }
}
