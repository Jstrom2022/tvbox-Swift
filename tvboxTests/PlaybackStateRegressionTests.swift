import Testing
import Foundation
@testable import TVBox

/// 记录详情页发出的 play 请求（线路与剧集地址）。
private final class PlayRequestRecorder {
    var calls: [(flag: String, id: String)] = []
}

/// 详情播放状态与 HLS 清晰度的回归测试（对应审计 B18、B19、B27、B28、B36、B37）。
@MainActor
@Suite("续播进度、线路切换与清晰度")
struct PlaybackStateRegressionTests {

    @Test("准备网页播放地址时切集，旧任务不会覆盖新地址或进度")
    func preparationCannotOverwriteNextEpisode() async throws {
        let viewModel = makeViewModel()
        viewModel.vodInfo?.playUrlMap["A"]?[0] = VodInfo.Episode(name: "第1集", url: "https://example.invalid/share/first")
        viewModel.selectEpisode(index: 0)
        #expect(viewModel.isPreparingPlayback)
        let oldTask = viewModel.playbackPrepareTask

        viewModel.selectEpisode(index: 1)
        let currentURL = try #require(viewModel.playUrl)
        #expect(!viewModel.isPreparingPlayback)
        #expect(viewModel.updatePlaybackProgress(seconds: 25, mediaURL: currentURL))
        await oldTask?.value
        #expect(viewModel.playUrl == currentURL)
        #expect(viewModel.currentPlaybackSeconds() == 25)
    }

    @Test("HLS 过滤保留正片并按最终地址补全相对切片路径")
    func adFilterPreservesContentURLs() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:150
        #EXTINF:150,
        content/first.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:10,
        ads/ad.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:150,
        content/last.ts
        #EXT-X-ENDLIST
        """
        let url = try #require(URL(string: "https://example.invalid/redirected/index.m3u8"))
        let result = try #require(HLSAdFilter.filter(playlist, playlistURL: url))
        #expect(result.removedGroups == 1)
        #expect(result.removedSeconds == 10)
        #expect(result.playlist.contains("https://example.invalid/redirected/content/first.ts"))
        #expect(result.playlist.contains("https://example.invalid/redirected/content/last.ts"))
        #expect(!result.playlist.contains("ads/ad.ts"))
    }

    private func makeViewModel() -> DetailViewModel {
        let viewModel = DetailViewModel()
        var video = Movie.Video(vodId: "1", name: "测试", sourceKey: "s")
        video.des = ""
        let info = VodInfo.from(
            video: video,
            playFrom: "A$$$B",
            playUrl: "第1集$https://example.invalid/a1.mp4#第2集$https://example.invalid/a2.mp4$$$第1集$https://example.invalid/b1.mp4"
        )
        viewModel.vodInfo = info
        viewModel.selectedFlag = info.playFlag
        return viewModel
    }

    @Test("向后拖动后切清晰度，从实时位置继续而不是回跳到旧续播点")
    func backwardSeekSurvivesQualitySwitch() throws {
        let viewModel = makeViewModel()
        viewModel.applyPlaybackState(VodPlaybackState(flag: "A", episodeIndex: 0, progressSeconds: 600))
        #expect(viewModel.currentPlaybackSeconds() == 600)

        let playURL = try #require(viewModel.playUrl)
        // 用户把进度拖回 100 秒。
        #expect(viewModel.updatePlaybackProgress(seconds: 100, mediaURL: playURL))
        #expect(viewModel.currentPlaybackSeconds() == 100)

        let alternate = PlaybackQualityOption(id: "hd", name: "HD", url: "https://example.invalid/a1-hd.mp4")
        viewModel.qualityOptions = [PlaybackQualityOption.auto(url: playURL), alternate]
        viewModel.selectQuality(alternate)

        #expect(viewModel.playUrl == alternate.url)
        #expect(viewModel.resumeSeconds == 100)
        #expect(viewModel.currentPlaybackSeconds() == 100)

        // 拖到 0 秒同样不会被旧快照抬高。
        #expect(viewModel.updatePlaybackProgress(seconds: 0, mediaURL: alternate.url))
        #expect(viewModel.currentPlaybackSeconds() == 0)
    }

    @Test("切集后迟到的旧地址进度回调被忽略")
    func staleProgressCallbacksAreIgnored() throws {
        let viewModel = makeViewModel()
        viewModel.selectEpisode(index: 0)
        let first = try #require(viewModel.playUrl)
        viewModel.selectEpisode(index: 1)

        #expect(!viewModel.updatePlaybackProgress(seconds: 1500, mediaURL: first))
        #expect(viewModel.currentPlaybackSeconds() == 0)
    }

    @Test("切到没有剧集的线路会结束旧播放会话")
    func emptyLineStopsPlayback() {
        let viewModel = makeViewModel()
        viewModel.vodInfo?.playFlags.append("空线路")
        viewModel.vodInfo?.playUrlMap["空线路"] = []
        viewModel.selectEpisode(index: 0)
        #expect(viewModel.isPlaying)

        viewModel.selectFlag("空线路")
        #expect(!viewModel.isPlaying)
        #expect(viewModel.playUrl == nil)
        #expect(viewModel.playbackNotice != nil)
    }

    @Test("重定向后的主列表按最终地址解析相对子流")
    func relativeVariantsUseFinalURL() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/video-only.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        high/video-only.m3u8
        """
        let requested = try #require(URL(string: "http://127.0.0.1/entry.m3u8"))
        let final = try #require(URL(string: "http://127.0.0.1/cdn/path/master.m3u8"))
        let options = DetailViewModel.parseMasterPlaylist(master, masterURL: requested, baseURL: final)

        #expect(options.first?.isAuto == true)
        #expect(options.first?.url == requested.absoluteString)
        let variantURLs = Set(options.dropFirst().map(\.url))
        #expect(variantURLs == [
            "http://127.0.0.1/cdn/path/low/video-only.m3u8",
            "http://127.0.0.1/cdn/path/high/video-only.m3u8"
        ])
    }

    @Test("依赖外置音轨组的变体保留主列表，只附加选流约束")
    func externalAudioKeepsMasterPlaylist() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="中文",DEFAULT=YES,URI="audio/zh.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aac"
        v360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,AUDIO="aac"
        v720.m3u8
        """
        let masterURL = try #require(URL(string: "https://example.invalid/master.m3u8"))
        let options = DetailViewModel.parseMasterPlaylist(master, masterURL: masterURL)
        let manual = options.filter { !$0.isAuto }

        #expect(manual.count == 2)
        #expect(manual.allSatisfy { $0.url == masterURL.absoluteString })
        #expect(manual.compactMap(\.constraint?.maxHeight).sorted() == [360, 720])
        #expect(manual.first { $0.constraint?.maxHeight == 720 }?.constraint?.peakBitRate == 2_800_000)
    }

    @Test("未保存过缓冲策略时使用声明的默认值“均衡”")
    func bufferModeDefaultsToBalanced() throws {
        let suiteName = "tvbox.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(VLCBufferMode.stored(in: defaults) == .balanced)
        defaults.set(VLCBufferMode.lowLatency.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        #expect(VLCBufferMode.stored(in: defaults) == .lowLatency)
        defaults.set(99, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        #expect(VLCBufferMode.stored(in: defaults) == .balanced)
    }

    @Test("倍速文案与实际倍速一致")
    func playbackRateLabelsAreExact() {
        #expect(PlaybackRateFormatter.label(for: 0.75) == "0.75x")
        #expect(PlaybackRateFormatter.label(for: 1.25) == "1.25x")
        #expect(PlaybackRateFormatter.label(for: 1.5) == "1.5x")
        #expect(PlaybackRateFormatter.label(for: 2.0) == "2x")
    }

    // MARK: - T4 播放地址

    private func makeRemoteViewModel(
        resolver: @escaping (SourceBean, String, String) async throws -> SourceService.PlayResult
    ) -> DetailViewModel {
        let viewModel = DetailViewModel()
        viewModel.resolvePlay = resolver
        let info = VodInfo.from(
            video: Movie.Video(vodId: "r1", name: "远程", sourceKey: "t4"),
            playFrom: "线路A$$$线路B",
            playUrl: "第1集$/play/1-1.html#第2集$/play/1-2.html$$$第1集$https://cdn.invalid/b1.mp4"
        )
        viewModel.applyDetail(info, source: SourceBean(key: "t4", name: "T4", api: "http://127.0.0.1:5757/api/demo", type: 4))
        return viewModel
    }

    @Test("T4 源先请求 play 接口，再用返回的地址与请求头播放")
    func remoteSourceResolvesPlayURL() async {
        let recorder = PlayRequestRecorder()
        let viewModel = makeRemoteViewModel { _, flag, id in
            recorder.calls.append((flag, id))
            return .direct(url: "https://cdn.invalid/1-1.mp4", headers: ["Referer": "https://site.invalid/"])
        }
        viewModel.selectEpisode(index: 0)
        #expect(viewModel.isResolvingPlayback)
        #expect(!viewModel.isPlaying)
        await viewModel.playResolveTask?.value

        #expect(recorder.calls.map(\.flag) == ["线路A"])
        #expect(recorder.calls.map(\.id) == ["/play/1-1.html"])
        #expect(!viewModel.isResolvingPlayback)
        #expect(viewModel.isPlaying)
        #expect(viewModel.playUrl == "https://cdn.invalid/1-1.mp4")
        #expect(viewModel.playHeaders == ["Referer": "https://site.invalid/"])
        #expect(viewModel.updatePlaybackProgress(seconds: 5, mediaURL: "https://cdn.invalid/1-1.mp4"))
    }

    @Test("需要解析或嗅探的剧集不开始播放，并给出明确提示")
    func remoteSourceNeedingParseShowsNotice() async {
        let viewModel = makeRemoteViewModel { _, _, id in .needsParse(url: "https://site.invalid\(id)") }
        viewModel.selectEpisode(index: 0)
        await viewModel.playResolveTask?.value

        #expect(!viewModel.isPlaying)
        #expect(viewModel.playUrl == nil)
        #expect(viewModel.playbackNotice?.contains("解析") == true)
    }

    @Test("play 接口失败时直链剧集按原地址播放，网页地址给出失败原因")
    func remotePlayFailureFallsBackToDirectLinks() async {
        let viewModel = makeRemoteViewModel { _, _, _ in throw NetworkError.httpError(500, message: "boom") }
        viewModel.selectFlag("线路B")
        viewModel.selectEpisode(index: 0)
        await viewModel.playResolveTask?.value
        #expect(viewModel.isPlaying)
        #expect(viewModel.playUrl == "https://cdn.invalid/b1.mp4")
        #expect(viewModel.playbackNotice?.contains("boom") == true)

        viewModel.selectFlag("线路A")
        await viewModel.playResolveTask?.value
        #expect(!viewModel.isPlaying)
        #expect(viewModel.playUrl == nil)
        #expect(viewModel.playbackNotice?.hasPrefix("获取播放地址失败：") == true)
    }

    @Test("切集后，上一集迟到的 play 结果不会覆盖当前剧集")
    func staleRemotePlayResultIsDropped() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let viewModel = makeRemoteViewModel { _, _, id in
            if id == "/play/1-1.html" {
                for await _ in gate { break }
            }
            return .direct(url: "https://cdn.invalid\(id).mp4", headers: [:])
        }
        viewModel.selectEpisode(index: 0)
        let stale = viewModel.playResolveTask
        viewModel.selectEpisode(index: 1)
        await viewModel.playResolveTask?.value
        open.yield()
        open.finish()
        await stale?.value

        #expect(viewModel.selectedEpisodeIndex == 1)
        #expect(viewModel.isPlaying)
        #expect(viewModel.playUrl == "https://cdn.invalid/play/1-2.html.mp4")
    }

    @Test("非 T4 来源不请求 play 接口，选集后立即播放")
    func directSourcesSkipPlayResolution() {
        let recorder = PlayRequestRecorder()
        let viewModel = DetailViewModel()
        viewModel.resolvePlay = { _, flag, id in
            recorder.calls.append((flag, id))
            return .direct(url: id, headers: [:])
        }
        let info = VodInfo.from(
            video: Movie.Video(vodId: "1", name: "测试", sourceKey: "s"),
            playFrom: "A",
            playUrl: "第1集$https://example.invalid/a1.mp4#第2集$https://example.invalid/a2.mp4"
        )
        viewModel.applyDetail(info, source: SourceBean(key: "s", name: "S", api: "http://h/api.php", type: 1))
        viewModel.selectEpisode(index: 1)

        #expect(viewModel.isPlaying)
        #expect(viewModel.playUrl == "https://example.invalid/a2.mp4")
        #expect(viewModel.playResolveTask == nil)
        #expect(recorder.calls.isEmpty)
    }

    #if canImport(VLCKitSPM)
    @Test("VLC 只携带 UA 与 Referer，其余请求头在失败提示中列出")
    func vlcHeaderSupport() {
        let headers = ["referer": "https://site.invalid/", "User-Agent": "UA", "Cookie": "a=1", "Origin": "https://site.invalid"]
        #expect(VLCPlayerController.headerValue("Referer", in: headers) == "https://site.invalid/")
        #expect(VLCPlayerController.headerValue("user-agent", in: headers) == "UA")
        #expect(VLCPlayerController.unsupportedHeaderNames(in: headers) == ["Cookie", "Origin"])
    }
    #endif
}
