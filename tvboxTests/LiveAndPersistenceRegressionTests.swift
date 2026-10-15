import Testing
import Foundation
import SwiftData
@testable import TVBox

/// 直播列表、频道身份与持久化业务键的回归测试（对应审计 B05、B17、B31、B32、B35，R05）。
@MainActor
@Suite("直播频道与收藏历史", .serialized)
struct LiveAndPersistenceRegressionTests {

    // MARK: - 直播

    private func makeGroups(firstGroupFirst: Bool = true) -> [LiveChannelGroup] {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 group-title="一组",Channel
        http://a.example/1.m3u8
        #EXTINF:-1 group-title="一组",Other
        http://a.example/2.m3u8
        #EXTINF:-1 group-title="二组",Channel
        http://b.example/1.m3u8
        """
        var groups = ApiConfig.parseLiveContent(m3u)
        if !firstGroupFirst {
            groups.reverse()
        }
        return groups
    }

    @Test("跨分组同名频道身份不同，刷新后仍停留在原分组")
    func channelIdentityIncludesGroup() throws {
        let groups = makeGroups()
        let first = try #require(groups.first?.channels.first)
        let second = try #require(groups.last?.channels.first)
        #expect(first.channelName == second.channelName)
        #expect(first.id != second.id)

        let viewModel = LiveViewModel()
        viewModel.applyChannelGroups(groups)
        viewModel.selectChannel(second)
        #expect(viewModel.currentChannel?.currentUrl == "http://b.example/1.m3u8")

        // 分组顺序变化后刷新：按完整身份恢复选择。
        viewModel.applyChannelGroups(makeGroups(firstGroupFirst: false))
        #expect(viewModel.currentChannel?.groupName == "二组")
        #expect(viewModel.currentChannel?.currentUrl == "http://b.example/1.m3u8")
        #expect(viewModel.selectedGroupIndex == 0)
    }

    @Test("选择频道会同步分组与频道索引，上一台/下一台从新位置计算")
    func selectingChannelSyncsIndexes() throws {
        let viewModel = LiveViewModel()
        viewModel.applyChannelGroups(makeGroups())
        let other = try #require(viewModel.channelGroups.first?.channels[safe: 1])

        viewModel.selectChannel(other)
        #expect(viewModel.selectedGroupIndex == 0)
        #expect(viewModel.selectedChannelIndex == 1)

        viewModel.nextChannel()
        #expect(viewModel.currentChannel?.groupName == "二组")
        viewModel.previousChannel()
        #expect(viewModel.currentChannel?.channelName == "Other")
    }

    @Test("刷新列表时保留用户当前选择的线路")
    func refreshKeepsCurrentSource() throws {
        var group = LiveChannelGroup(groupName: "组", groupIndex: 0)
        var channel = LiveChannelItem(channelName: "台", channelIndex: 0, groupName: "组")
        channel.channelUrls = ["http://x/1.m3u8", "http://x/2.m3u8"]
        group.channels = [channel]

        let viewModel = LiveViewModel()
        viewModel.applyChannelGroups([group])
        viewModel.switchSource()
        #expect(viewModel.currentChannel?.currentUrl == "http://x/2.m3u8")

        viewModel.applyChannelGroups([group])
        #expect(viewModel.currentChannel?.currentUrl == "http://x/2.m3u8")
    }

    @Test("带 BOM 或前导空白的 M3U 也能识别")
    func m3uWithBOMIsRecognised() {
        let body = "#EXTM3U\n#EXTINF:-1,CCTV1\nhttp://a/1.m3u8\n"
        #expect(ApiConfig.parseLiveContent(body).count == 1)
        #expect(ApiConfig.parseLiveContent("\u{FEFF}" + body).count == 1)
        #expect(ApiConfig.parseLiveContent("  \n " + body).count == 1)
    }

    @Test("直播配置的 ua 随频道线路保留，合并后各线路仍使用各自来源的 ua")
    func liveUserAgentIsCarried() throws {
        let m3u = "#EXTM3U\n#EXTINF:-1,CCTV1\nstreams/1.m3u8\n"
        let fromList = ApiConfig.parseLiveContent(m3u, baseURL: "http://host/lists/tv.m3u", userAgent: "audit-agent")
        let channel = try #require(fromList.first?.channels.first)
        // 相对地址按列表的最终地址解析
        #expect(channel.currentUrl == "http://host/lists/streams/1.m3u8")
        #expect(channel.currentUserAgent == "audit-agent")

        let other = ApiConfig.parseLiveContent("#EXTM3U\n#EXTINF:-1,CCTV1\nhttp://cdn/1.m3u8\n")
        var merged: [String: LiveChannelGroup] = [:]
        ApiConfig.mergeLiveGroups(fromList, into: &merged)
        ApiConfig.mergeLiveGroups(other, into: &merged)
        var mergedChannel = try #require(ApiConfig.sortedGroups(from: merged).first?.channels.first)
        #expect(mergedChannel.sourceNum == 2)
        #expect(mergedChannel.currentUserAgent == "audit-agent")
        mergedChannel.nextSource()
        #expect(mergedChannel.currentUrl == "http://cdn/1.m3u8")
        #expect(mergedChannel.currentUserAgent == nil)
    }

    @Test("M3U 中单频道声明的 UA 优先于来源级配置")
    func perChannelUserAgentWins() throws {
        let m3u = "#EXTM3U\n#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=channel-agent\nhttp://a/1.m3u8\n#EXTINF:-1,B\nhttp://a/2.m3u8\n"
        let channels = ApiConfig.parseLiveContent(m3u, userAgent: "source-agent").flatMap(\.channels)
        #expect(channels.first { $0.channelName == "A" }?.currentUserAgent == "channel-agent")
        #expect(channels.first { $0.channelName == "B" }?.currentUserAgent == "source-agent")
    }

    // MARK: - 收藏/历史

    private func makeContext() throws -> ModelContext {
        let schema = Schema([VodCollect.self, VodRecord.self, CacheItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    @Test("含 :: 的来源与视频 ID 不再碰撞")
    func businessKeysAreUnambiguous() throws {
        #expect(makeVodBusinessKey(vodId: "c", sourceKey: "a::b") != makeVodBusinessKey(vodId: "b::c", sourceKey: "a"))

        let context = try makeContext()
        CacheStore.shared.addCollect(Movie.Video(vodId: "c", name: "第一部", sourceKey: "a::b"), context: context)
        CacheStore.shared.addCollect(Movie.Video(vodId: "b::c", name: "第二部", sourceKey: "a"), context: context)

        let collects = try context.fetch(FetchDescriptor<VodCollect>())
        #expect(collects.count == 2)
        #expect(Set(collects.map(\.vodName)) == ["第一部", "第二部"])
    }

    @Test("同名来源指向不同接口时，收藏与历史互不覆盖")
    func differentSourceApisDoNotOverwrite() throws {
        let context = try makeContext()
        let old = Movie.Video(vodId: "1", name: "旧站影片", sourceKey: "site", sourceApi: "http://old/api")
        let new = Movie.Video(vodId: "1", name: "新站影片", sourceKey: "site", sourceApi: "http://new/api")
        CacheStore.shared.addRecord(old, playNote: "第1集", context: context)
        CacheStore.shared.addRecord(new, playNote: "第2集", context: context)

        let records = try context.fetch(FetchDescriptor<VodRecord>())
        #expect(records.count == 2)
        #expect(Set(records.map(\.vodName)) == ["旧站影片", "新站影片"])
    }

    @Test("失效来源的条目不会回退到主页源")
    func missingSourceDoesNotFallBack() {
        let config = ApiConfig.shared
        let previousSources = config.sourceBeanList
        let previousHome = config.homeSourceBean
        defer {
            config.sourceBeanList = previousSources
            config.homeSourceBean = previousHome
        }

        let fallback = SourceBean(key: "fallback", name: "主页源", api: "http://fallback/api")
        config.sourceBeanList = [fallback]
        config.homeSourceBean = fallback

        let removed = Movie.Video(vodId: "1", sourceKey: "removed")
        #expect(DetailViewModel.resolveSource(for: removed, config: config, allowsAPIChange: false) == .sourceMissing)

        let changed = Movie.Video(vodId: "1", sourceKey: "fallback", sourceApi: "http://other/api")
        #expect(DetailViewModel.resolveSource(for: changed, config: config, allowsAPIChange: false) == .apiChanged(fallback))
        #expect(DetailViewModel.resolveSource(for: changed, config: config, allowsAPIChange: true) == .resolved(fallback))

        let sourceless = Movie.Video(vodId: "1", sourceKey: "")
        #expect(DetailViewModel.resolveSource(for: sourceless, config: config, allowsAPIChange: false) == .resolved(fallback))
    }
}
