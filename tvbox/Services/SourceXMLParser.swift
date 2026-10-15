import Foundation

/// MacCMS 风格 XML 数据源的解析器。
///
/// 用 `XMLParser` 构建统一的中间模型，替代原先的窄正则匹配：
/// 普通文本与 CDATA、标签顺序变化、可选字段、非数字 ID、XML 实体均可正确解析。
/// 首页、列表、详情入口共用同一套解析结果。
enum SourceXMLParser {

    /// 轻量 XML 节点树。
    final class Node {
        let name: String
        let attributes: [String: String]
        var text: String = ""
        var children: [Node] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// 按标签名查找第一个直接子节点。
        func firstChild(_ childName: String) -> Node? {
            children.first { $0.name == childName }
        }

        /// 深度优先查找第一个匹配标签名的节点。
        func firstDescendant(_ descendantName: String) -> Node? {
            for child in children {
                if child.name == descendantName { return child }
                if let found = child.firstDescendant(descendantName) { return found }
            }
            return nil
        }

        /// 直接子节点中指定标签名的文本值。
        func text(of childName: String) -> String {
            firstChild(childName)?.trimmedText ?? ""
        }
    }

    /// 列表解析结果（含分页元数据）。
    struct VideoListResult {
        let videos: [Movie.Video]
        let page: Int?
        let pageCount: Int?
        let pageSize: Int?
        let total: Int?
    }

    /// 详情播放信息。
    struct PlayInfo {
        let playFrom: String
        let playUrl: String
    }

    private struct ParseError: Error {}

    // MARK: - 入口

    /// 解析 XML 文本；无法解析时返回 nil，由调用方转换为“响应不是合法数据”的错误。
    static func parse(_ xml: String) -> Node? {
        let sanitized = prepare(xml)
        if let root = runParser(sanitized) {
            return root
        }
        // 部分源的 XML 含有未转义的 `&`，转义后重试一次。
        return runParser(escapeBareAmpersands(sanitized))
    }

    /// 分类列表：`<class><ty id="1">电影</ty></class>`
    static func categories(from root: Node?) -> [MovieSort.SortData] {
        guard let root, let classNode = root.name == "class" ? root : root.firstDescendant("class") else { return [] }
        return classNode.children
            .filter { $0.name == "ty" }
            .compactMap { node in
                let id = node.attributes["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = node.trimmedText
                guard !id.isEmpty, !name.isEmpty else { return nil }
                return MovieSort.SortData(id: id, name: name)
            }
    }

    /// 视频列表：优先取 `<list>` 节点，并读取分页属性。
    static func videoList(from root: Node?) -> VideoListResult {
        guard let root else {
            return VideoListResult(videos: [], page: nil, pageCount: nil, pageSize: nil, total: nil)
        }

        let listNode = root.name == "list" ? root : root.firstDescendant("list")
        let videoNodes = (listNode ?? root).children.filter { $0.name == "video" }

        let videos = videoNodes.compactMap { makeVideo(from: $0) }
        let attributes = listNode?.attributes ?? [:]

        return VideoListResult(
            videos: videos,
            page: intValue(attributes["page"]),
            pageCount: intValue(attributes["pagecount"]),
            pageSize: intValue(attributes["pagesize"]),
            total: intValue(attributes["recordcount"])
        )
    }

    /// 详情播放线路：`<dl><dd flag="m3u8">第1集$url#第2集$url</dd></dl>`
    static func playInfo(for video: Movie.Video, in root: Node?) -> PlayInfo {
        guard let root,
              let block = videoNode(withId: video.vodId, in: root) else {
            return PlayInfo(playFrom: "", playUrl: "")
        }

        let ddNodes = block
            .firstChild("dl")?
            .children
            .filter { $0.name == "dd" } ?? []

        var flags: [String] = []
        var urls: [String] = []
        for (index, node) in ddNodes.enumerated() {
            let url = node.trimmedText
            guard !url.isEmpty else { continue }
            let flag = node.attributes["flag"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            flags.append(flag.isEmpty ? "线路\(index + 1)" : flag)
            urls.append(url)
        }

        return PlayInfo(playFrom: flags.joined(separator: "$$$"), playUrl: urls.joined(separator: "$$$"))
    }

    // MARK: - 节点映射

    private static func videoNode(withId vodId: String, in root: Node) -> Node? {
        guard let listNode = root.name == "list" ? root : root.firstDescendant("list") else { return nil }
        return listNode.children.first { node in
            node.name == "video" && node.text(of: "id") == vodId
        }
    }

    private static func makeVideo(from node: Node) -> Movie.Video? {
        let vodId = node.text(of: "id")
        guard !vodId.isEmpty else { return nil }

        var video = Movie.Video(vodId: vodId)
        video.name = node.text(of: "name")
        video.pic = node.text(of: "pic")
        video.note = node.text(of: "note")
        video.year = node.text(of: "year")
        video.area = node.text(of: "area")
        video.type = node.text(of: "type")
        video.director = node.text(of: "director")
        video.actor = node.text(of: "actor")
        video.des = node.text(of: "des")
        video.last = node.text(of: "last")
        return video
    }

    private static func intValue(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Int(raw)
    }

    // MARK: - 解析基础设施

    private static func runParser(_ xml: String) -> Node? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // 外部实体与网络加载一律关闭，避免解析远程响应时发起额外请求。
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let success = parser.parse()
        guard success, let root = delegate.root else { return nil }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        private(set) var root: Node?
        private var stack: [Node] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let normalized = elementName.lowercased()
            let attributes = Dictionary(
                uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) }
            )
            let node = Node(name: normalized, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
            stack.last?.text += text
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if !stack.isEmpty {
                stack.removeLast()
            }
        }
    }

    /// 把非 UTF-8 的编码声明改为 UTF-8：文本已在网络层按正确编码解码为 Swift String。
    private static func prepare(_ xml: String) -> String {
        var content = xml
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        guard let range = content.range(of: #"encoding\s*=\s*["'][^"']*["']"#, options: .regularExpression) else {
            return content
        }
        content.replaceSubrange(range, with: #"encoding="UTF-8""#)
        return content
    }

    /// 转义 CDATA 之外未转义的 `&`，兼容常见的非严格 XML。
    private static func escapeBareAmpersands(_ xml: String) -> String {
        var result = ""
        result.reserveCapacity(xml.count)

        var remaining = Substring(xml)
        while let cdataStart = remaining.range(of: "<![CDATA[") {
            let head = remaining[remaining.startIndex..<cdataStart.lowerBound]
            result += escapeAmpersands(outsideCDATA: String(head))

            guard let cdataEnd = remaining.range(of: "]]>", range: cdataStart.upperBound..<remaining.endIndex) else {
                result += remaining[cdataStart.lowerBound...]
                return result
            }
            result += remaining[cdataStart.lowerBound..<cdataEnd.upperBound]
            remaining = remaining[cdataEnd.upperBound...]
        }

        result += escapeAmpersands(outsideCDATA: String(remaining))
        return result
    }

    private static func escapeAmpersands(outsideCDATA text: String) -> String {
        text.replacingOccurrences(
            of: #"&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);)"#,
            with: "&amp;",
            options: .regularExpression
        )
    }
}

extension SourceXMLParser.Node {
    /// 去掉首尾空白的文本值。
    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
