import Testing
import Foundation
@testable import TVBox

/// 配置词法与结构的回归测试（对应审计 B01–B03）。
@Suite("配置清洗、多仓判别与地址身份")
struct ConfigParsingRegressionTests {

    private struct SitesAndLives: Decodable {
        let sites: [String]
        let lives: [[String: String]]
    }

    @Test("行内注释不会吞掉字段之间必需的逗号")
    func inlineCommentKeepsSeparatorComma() throws {
        let raw = """
        {
            "sites": [], // 站点
            "lives": [{}]
        }
        """
        let cleaned = ApiConfig.stripJsonComments(raw)
        let decoded = try JSONDecoder().decode(SitesAndLives.self, from: Data(cleaned.utf8))
        #expect(decoded.sites.isEmpty)
        #expect(decoded.lives.count == 1)
    }

    @Test("字符串中的 `,}` `,]` `//` 与转义引号逐字保留")
    func stringContentIsPreservedVerbatim() throws {
        let raw = #"""
        {
            "url": "https://example.invalid/?x=,}&y=,]",
            "path": "http://host//a//b",
            "quote": "he said \"hi\", ok", // 注释
            "list": [1, 2, ], // 真正的尾逗号
        }
        """#
        let cleaned = ApiConfig.stripJsonComments(raw)
        let object = try #require(JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        #expect(object["url"] as? String == "https://example.invalid/?x=,}&y=,]")
        #expect(object["path"] as? String == "http://host//a//b")
        #expect(object["quote"] as? String == #"he said "hi", ok"#)
        #expect(object["list"] as? [Int] == [1, 2])
    }

    @Test("对象字段间、数组元素间的整行注释与块注释被移除")
    func commentsBetweenElementsAreRemoved() throws {
        let raw = """
        // 文件头注释
        {
            "a": 1,
            // 中间注释
            "b": [ /* 块注释 */ 1, // 行尾
                2
            ],
        }
        """
        let cleaned = ApiConfig.stripJsonComments(raw)
        let object = try #require(JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any])
        #expect(object["a"] as? Int == 1)
        #expect(object["b"] as? [Int] == [1, 2])
    }

    @Test("只有存在类型正确的 urls 数组才视为多仓库入口")
    func multiRepoRequiresUrlsArray() {
        let pointer = Data(#"{"url":"http://127.0.0.1:8080/config.json"}"#.utf8)
        #expect(ApiConfig.decodeMultiRepoIndex(data: pointer) == nil)

        let empty = Data("{}".utf8)
        #expect(ApiConfig.decodeMultiRepoIndex(data: empty) == nil)

        let wrongType = Data(#"{"urls":"http://a/b.json"}"#.utf8)
        #expect(ApiConfig.decodeMultiRepoIndex(data: wrongType) == nil)

        let multi = Data(#"{"urls":[{"name":"A","url":"http://a/a.json"}]}"#.utf8)
        #expect(ApiConfig.decodeMultiRepoIndex(data: multi)?.candidateUrls == ["http://a/a.json"])
    }

    @Test("地址身份只规范 scheme/host/默认端口，路径与查询大小写保持区分")
    func urlIdentityKeepsCaseSensitiveParts() {
        #expect(ApiConfig.urlIdentity("http://h/Config.json") != ApiConfig.urlIdentity("http://h/config.json"))
        #expect(ApiConfig.urlIdentity("http://h/c.json?token=AbC") != ApiConfig.urlIdentity("http://h/c.json?token=abc"))
        #expect(ApiConfig.urlIdentity("HTTP://Example.COM/c.json") == ApiConfig.urlIdentity("http://example.com/c.json"))
        #expect(ApiConfig.urlIdentity("https://example.com:443/c.json") == ApiConfig.urlIdentity("https://example.com/c.json"))
        #expect(ApiConfig.urlIdentity("http://example.com:8080/c.json") != ApiConfig.urlIdentity("http://example.com/c.json"))
    }

    @Test("多仓选项 ID 不会因为路径大小写不同而碰撞")
    func multiRepoOptionIdsAreDistinct() {
        let upper = ApiConfig.MultiRepoOption(name: "A", url: "http://h/Config.json")
        let lower = ApiConfig.MultiRepoOption(name: "B", url: "http://h/config.json")
        #expect(upper.id != lower.id)
    }
}
