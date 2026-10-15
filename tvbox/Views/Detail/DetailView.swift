import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// 详情页 - 对应 Android 版 DetailActivity
struct DetailView: View {
    let video: Movie.Video
    @StateObject private var viewModel = DetailViewModel()
    @StateObject private var sharedSystemController = SystemPlayerSessionController()
    @StateObject private var sharedVLCController = VLCPlayerController()
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    /// 用于来源提示中的“返回”按钮。
    @Environment(\.dismiss) private var dismiss
    @State private var showFullScreen = false
    /// VLC 全屏退出动画期间为 true，防止内联播放器与全屏播放器同时争抢 drawable
    @State private var isFullScreenDismissing = false
    #if os(macOS)
    @State private var pendingMacWindowFullScreen = false
    #endif
    @State private var lastPersistedProgress: Double = 0
    @State private var isCollected = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 播放器区域
                if !showFullScreen, !isFullScreenDismissing, viewModel.isPlaying, let url = viewModel.playUrl {
                    PlayerView(
                        urlString: url,
                        startPosition: viewModel.currentPlaybackSeconds(),
                        qualityConstraint: viewModel.playbackConstraint,
                        httpHeaders: viewModel.playHeaders,
                        onProgressChanged: handlePlaybackProgress,
                        onPlaybackEnded: playNextEpisodeIfNeeded,
                        onToggleFullScreen: {
                            openFullScreenPlayer()
                        },
                        canPlayNext: canPlayNextEpisode,
                        onPlayNext: playNextEpisodeIfNeeded,
                        systemController: sharedSystemController,
                        vlcController: sharedVLCController
                    )
                        .id("\(viewModel.selectedFlag)-\(viewModel.selectedEpisodeIndex)-\(url)")
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                        .onTapGesture(count: 2) {
                            openFullScreenPlayer()
                        }
                } else if viewModel.isResolvingPlayback || viewModel.isPreparingPlayback {
                    resolvingPlaybackPlaceholder
                }

                if let note = viewModel.adFilterNote, viewModel.isPlaying {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.checkered")
                        Text(note)
                    }
                    .font(.caption)
                    .foregroundColor(.green.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                // 视频信息
                videoInfoSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                
                // 详情状态：加载中、加载失败、原数据源失效、来源接口变化
                statusSection
                
                // 线路选择
                if viewModel.flags.count > 1 {
                    flagSelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 清晰度选择
                if viewModel.hasQualityChoices {
                    qualitySelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 剧集列表
                if !viewModel.currentEpisodes.isEmpty {
                    episodeSection
                        .padding(.top, 16)
                }
                
                // 简介
                if let info = viewModel.vodInfo, !info.des.isEmpty {
                    descriptionSection(info.des)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle(video.name)
        #if os(macOS)
        .toolbar((showFullScreen || pendingMacWindowFullScreen) ? .hidden : .visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: video.id) {
            await loadDetailAndRestore()
        }
        .onChange(of: viewModel.isPlaying) { _, isPlaying in
            // 播放会话结束（如切到没有剧集的线路）时必须停止共享播放器，否则会继续出声。
            if !isPlaying {
                sharedSystemController.stop()
                sharedVLCController.stop()
            }
        }
        .onDisappear {
            viewModel.cancelPlaybackResolution()
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
            showFullScreen = false
            sharedSystemController.stop()
            sharedVLCController.stop()
            #if os(macOS)
            pendingMacWindowFullScreen = false
            appState.exitPlayerFullScreen()
            #endif
        }
        #if os(macOS)
        .overlay {
            if showFullScreen, let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    qualityConstraint: viewModel.playbackConstraint,
                    httpHeaders: viewModel.playHeaders,
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: closeMacFullScreenOverlay
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard pendingMacWindowFullScreen else { return }
            pendingMacWindowFullScreen = false
            showFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            pendingMacWindowFullScreen = false
            if showFullScreen {
                showFullScreen = false
            }
            appState.exitPlayerFullScreen()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            isFullScreenDismissing = false
        }) {
            if let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    qualityConstraint: viewModel.playbackConstraint,
                    httpHeaders: viewModel.playHeaders,
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: {
                        isFullScreenDismissing = true
                        showFullScreen = false
                    }
                )
            }
        }
        #endif
    }
    
    /// 正在向源请求真实播放地址时的占位（T4 源播放前需要先调用 play 接口）。
    private var resolvingPlaybackPlaceholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("正在获取播放地址…")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }
    
    // MARK: - 详情状态
    
    @ViewBuilder
    private var statusSection: some View {
        if let notice = viewModel.playbackNotice {
            statusCard(icon: "exclamationmark.triangle.fill", tint: .yellow, message: notice)
        }
        
        if viewModel.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.orange)
                Text("正在加载影片详情…")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(15)
            .glassCard(cornerRadius: AppTheme.glassRadius)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        } else if let error = viewModel.errorMessage {
            statusCard(
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                message: error,
                retry: { Task { await loadDetailAndRestore() } }
            )
        } else if let error = viewModel.sourceErrorMessage {
            // 原来源已失效时重试没有意义，引导用户重新搜索选择来源。
            statusCard(icon: "questionmark.folder", tint: .orange, message: error)
        }
        
        if let mismatch = viewModel.sourceMismatchMessage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.orange)
                    Text(mismatch)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.85))
                }
                
                HStack(spacing: 12) {
                    Button("仍然打开") {
                        openDespiteSourceMismatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    
                    Button("返回") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(15)
            .glassCard(cornerRadius: AppTheme.glassRadius)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }
    
    private func statusCard(
        icon: String,
        tint: Color,
        message: String,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
    
    // MARK: - 视频信息
    
    #if os(iOS)
    @ViewBuilder
    private var videoInfoSection: some View {
        VStack(spacing: 16) {
            // Poster centered, height capped to 30% of screen
            let posterHeight = UIScreen.main.bounds.height * 0.30
            CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                image.resizable().aspectRatio(2/3, contentMode: .fit)
            } placeholder: {
                Color.white.opacity(0.05)
                    .aspectRatio(2/3, contentMode: .fit)
            }
            .frame(maxHeight: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))

            // Info below poster
            videoDetails

            // Action buttons with 48pt height
            HStack(spacing: 12) {
                playButton
                collectButton
            }
            .frame(minHeight: 48)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #else
    @ViewBuilder
    private var videoInfoSection: some View {
        HStack(alignment: .top, spacing: 20) {
            videoPoster
            
            videoDetails
            
            Spacer()
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #endif

    @ViewBuilder
    private var videoPoster: some View {
        CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
            image.resizable().aspectRatio(2/3, contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.05)
                Image(systemName: "film.fill").foregroundColor(.white.opacity(0.2))
            }
            .aspectRatio(2/3, contentMode: .fill)
        }
        .frame(width: 130)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var videoDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.vodInfo?.name ?? video.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            if let info = viewModel.vodInfo {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("年份", info.year)
                    infoRow("地区", info.area)
                    infoRow("类型", info.typeName)
                    infoRow("导演", info.director)
                    infoRow("演员", info.actor)
                }
            }
            
            #if os(macOS)
            Spacer(minLength: 10)
            
            HStack(spacing: 10) {
                playButton
                collectButton
            }
            #endif
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if !viewModel.isPlaying && !viewModel.isResolvingPlayback && viewModel.vodInfo != nil {
            Button {
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("立即播放")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(AppTheme.accentGradient)
                .clipShape(Capsule())
                .shadow(color: .red.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var collectButton: some View {
        Button {
            toggleCollect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollected ? "heart.fill" : "heart")
                Text(isCollected ? "已收藏" : "收藏")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isCollected {
                        AppTheme.accentGradient
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isCollected ? 0 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
    }
    
    // MARK: - 线路选择
    
    @ViewBuilder
    private var flagSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放线路")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            flagScrollView
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    @ViewBuilder
    private var flagScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.flags, id: \.self) { flag in
                    flagButton(flag)
                }
            }
        }
    }

    @ViewBuilder
    private func flagButton(_ flag: String) -> some View {
        Button {
            withAnimation {
                viewModel.selectFlag(flag)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(flag)
                .font(.system(size: 14, weight: viewModel.selectedFlag == flag ? .bold : .medium))
                .foregroundColor(viewModel.selectedFlag == flag ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedFlag == flag {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 清晰度选择
    
    @ViewBuilder
    private var qualitySelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频清晰度")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.qualityOptions) { option in
                        qualityButton(option)
                    }
                }
            }
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    
    @ViewBuilder
    private func qualityButton(_ option: PlaybackQualityOption) -> some View {
        Button {
            withAnimation {
                viewModel.selectQuality(option)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(option.name)
                .font(.system(size: 14, weight: viewModel.selectedQualityId == option.id ? .bold : .medium))
                .foregroundColor(viewModel.selectedQualityId == option.id ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedQualityId == option.id {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 剧集列表
    
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选集播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            EpisodeListView(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            )
        }
    }
    
    // MARK: - 简介
    
    private func descriptionSection(_ des: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("影片简介")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            Text(des)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .lineSpacing(4)
                .lineLimit(nil)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    private var canPlayNextEpisode: Bool {
        viewModel.selectedEpisodeIndex + 1 < viewModel.currentEpisodes.count
    }
    
    /// 写入收藏/历史使用的视频对象：带上真实来源，避免回退主页源时把记录写到错误的来源下。
    private var recordVideo: Movie.Video {
        var copy = video
        if let key = viewModel.resolvedSourceKey, !key.isEmpty {
            copy.sourceKey = key
        }
        if let api = viewModel.resolvedSourceApi, !api.isEmpty {
            copy.sourceApi = api
        }
        if let info = viewModel.vodInfo {
            if copy.name.isEmpty { copy.name = info.name }
            if copy.pic.isEmpty { copy.pic = info.pic }
        }
        return copy
    }
    
    private func loadDetailAndRestore() async {
        await viewModel.loadDetail(video: video)
        restorePlaybackFromHistory()
        refreshCollectState()
    }
    
    /// 用户确认接口变化后继续打开：先把旧记录迁移到当前接口，再正常加载。
    private func openDespiteSourceMismatch() {
        guard let sourceKey = viewModel.pendingSourceKey,
              let newApi = viewModel.pendingSourceApi else { return }
        Task { @MainActor in
            CacheStore.shared.remapSourceApi(
                vodId: video.vodId,
                sourceKey: sourceKey,
                from: video.sourceApi,
                to: newApi,
                context: modelContext
            )
            await viewModel.loadDetail(video: video, allowsSourceAPIChange: true)
            restorePlaybackFromHistory()
            refreshCollectState()
        }
    }
    
    private func saveHistoryForCurrentEpisode(progressOverride: Double? = nil) {
        let episodeName = viewModel.vodInfo?.currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel = episodeName.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : episodeName
        let progress = max(progressOverride ?? viewModel.currentPlaybackSeconds(), 0)
        let timeLabel = progress > 0 ? Int(progress).durationString : ""
        let playNote = timeLabel.isEmpty ? episodeLabel : "\(episodeLabel) \(timeLabel)"
        
        let playbackState = VodPlaybackState(
            flag: viewModel.selectedFlag,
            episodeIndex: viewModel.selectedEpisodeIndex,
            progressSeconds: progress
        )
        
        Task { @MainActor in
            CacheStore.shared.addRecord(
                recordVideo,
                playNote: playNote,
                playbackState: playbackState,
                context: modelContext
            )
        }
    }
    
    private func handlePlaybackProgress(_ seconds: Double, _: Double?, mediaURL: String) {
        // 只接受当前播放地址的回调，切集/切线路后仍在途的旧回调会被忽略。
        guard viewModel.updatePlaybackProgress(seconds: seconds, mediaURL: mediaURL) else { return }
        persistHistoryIfNeeded(force: false, currentProgress: seconds)
    }
    
    private func persistHistoryIfNeeded(force: Bool, currentProgress: Double? = nil) {
        // 播放会话已结束时不再写入进度（例如切到没有剧集的线路）。
        guard viewModel.isPlaying else { return }
        let progress = max(currentProgress ?? viewModel.currentPlaybackSeconds(), 0)
        guard progress.isFinite else { return }
        
        if !force && abs(progress - lastPersistedProgress) < 20 {
            return
        }
        
        lastPersistedProgress = progress
        saveHistoryForCurrentEpisode(progressOverride: progress)
    }
    
    private func restorePlaybackFromHistory() {
        guard viewModel.vodInfo != nil else { return }
        let record = recordVideo
        var playbackState = CacheStore.shared.getPlaybackState(
            vodId: record.vodId,
            sourceKey: record.sourceKey,
            sourceApi: record.sourceApi,
            context: modelContext
        )
        if playbackState == nil, video.sourceKey.isEmpty {
            // 极旧版本留下的无来源记录：按原始身份再查一次。
            playbackState = CacheStore.shared.getPlaybackState(
                vodId: video.vodId,
                sourceKey: video.sourceKey,
                context: modelContext
            )
        }
        guard let playbackState else { return }
        
        viewModel.applyPlaybackState(playbackState)
        lastPersistedProgress = max(playbackState.progressSeconds, 0)
    }
    
    private func refreshCollectState() {
        guard viewModel.vodInfo != nil else { return }
        let record = recordVideo
        isCollected = CacheStore.shared.isCollected(
            vodId: record.vodId,
            sourceKey: record.sourceKey,
            sourceApi: record.sourceApi,
            context: modelContext
        )
    }
    
    private func toggleCollect() {
        let record = recordVideo
        if isCollected {
            CacheStore.shared.removeCollect(
                vodId: record.vodId,
                sourceKey: record.sourceKey,
                sourceApi: record.sourceApi,
                context: modelContext
            )
        } else {
            CacheStore.shared.addCollect(record, context: modelContext)
        }
        refreshCollectState()
    }
    
    private func playNextEpisodeIfNeeded() {
        var moved = false
        withAnimation {
            moved = viewModel.playNext()
        }
        
        if moved {
            saveHistoryForCurrentEpisode()
        }
    }
    
    private func openFullScreenPlayer() {
        #if os(iOS)
        showFullScreen = true
        #else
        guard viewModel.playUrl != nil else { return }
        appState.enterPlayerFullScreen()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            showFullScreen = true
            return
        }
        
        pendingMacWindowFullScreen = requestMacWindowFullScreen(enter: true)
        if !pendingMacWindowFullScreen {
            showFullScreen = true
        }
        #endif
    }
    
    #if os(macOS)
    @discardableResult
    private func requestMacWindowFullScreen(enter: Bool) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard enter != isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }
    
    private func closeMacFullScreenOverlay() {
        pendingMacWindowFullScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if window?.styleMask.contains(.fullScreen) == true {
            requestMacWindowFullScreen(enter: false)
            return
        }
        showFullScreen = false
        appState.exitPlayerFullScreen()
    }
    #endif
}

/// 全屏播放器
struct FullScreenPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var qualityConstraint: PlaybackQualityConstraint? = nil
    var httpHeaders: [String: String] = [:]
    var onProgressChanged: ((Double, Double?, String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            PlayerView(
                urlString: urlString,
                startPosition: startPosition,
                qualityConstraint: qualityConstraint,
                httpHeaders: httpHeaders,
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onToggleFullScreen: {
                    if let onCloseRequested {
                        onCloseRequested()
                    } else {
                        dismiss()
                    }
                },
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                systemController: systemController,
                vlcController: vlcController
            )
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Button {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
    }
}
