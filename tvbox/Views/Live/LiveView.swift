import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif

/// 一次直播播放尝试（频道 + 线路 + 令牌）。失败/卡顿回调必须属于当前会话才会被处理，
/// 旧线路的迟到错误不会误伤新线路。
struct LivePlaybackSession: Equatable {
    let id: UUID
    let url: String
    let channelId: LiveChannelItem.Identity
    let sourceIndex: Int
    /// 本会话是否已经处理过终态错误（同一会话只处理一次）。
    var hasFailed = false
}

/// 直播页 - 对应 Android 版 LivePlayActivity
struct LiveView: View {
    /// 退出直播回调（iOS 用于返回首页并显示 TabBar）。
    var onExit: (() -> Void)? = nil
    /// 直播频道与选中状态管理。
    @StateObject private var viewModel = LiveViewModel()
    /// 全局应用状态（用于 macOS 全屏时调整分栏布局）。
    @EnvironmentObject var appState: AppState
    /// 系统播放器实例（仅在选择系统内核时使用）。
    @State private var avPlayer: AVPlayer?
    /// 直播播放器内核配置（新字段）。
    @AppStorage(HawkConfig.PLAY_TYPE_LIVE) private var livePlayTypeRaw = -1
    /// 兼容旧版本单播放器字段。
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    /// 是否展示左侧频道抽屉。
    @State private var showChannelDrawer = true
    #if os(iOS)
    /// iOS 全屏频道覆盖层是否显示。
    @State private var showChannelOverlay = false
    #endif
    /// 当前窗口是否处于全屏。
    @State private var isWindowFullScreen = false
    /// 底部频道信息卡最大宽度。
    private let currentChannelInfoMaxWidth: CGFloat = 600
    /// AVPlayer 状态观察者。
    @State private var itemStatusObserver: NSKeyValueObservation?
    /// 播放失败通知观察者。
    @State private var playbackFailedObserver: NSObjectProtocol?
    /// 播放卡顿通知观察者。
    @State private var playbackStalledObserver: NSObjectProtocol?
    /// 当前频道已失败的线路索引，用于自动切线去重。
    @State private var failedSourceIndices: Set<Int> = []
    /// 当前跟踪的频道 ID（频道切换时重置失败状态）。
    @State private var trackedChannelId: LiveChannelItem.Identity?
    /// 当前播放会话。
    @State private var playbackSession: LivePlaybackSession?
    /// 系统内核播放状态观察者（用于确认出画与卡顿恢复）。
    @State private var timeControlObserver: NSKeyValueObservation?
    /// 卡顿恢复观察期：期满仍未恢复才判定线路失败。
    @State private var stallRecoveryWorkItem: DispatchWorkItem?
    /// 自动切线提示（如“线路 1 无法播放，已切换到线路 2”）。
    @State private var liveStatusMessage: String?
    /// 终态错误（单线路失败或全部线路失败），需要用户重试或切线。
    @State private var liveErrorMessage: String?
    /// 手动重试次数，参与 VLC 视图标识，确保同一地址也能重新拉流。
    @State private var playbackAttempt = 0
    /// 卡顿后等待自动恢复的时长（秒）。
    private let stallRecoveryTimeout: TimeInterval = 8
    /// 底部频道信息是否显示。
    @State private var showCurrentChannelInfo = true
    /// 自动隐藏频道信息的定时器。
    @State private var channelInfoTimer: Timer?
    /// 频道信息自动隐藏延迟（秒）。
    private let channelInfoAutoHideDelay: TimeInterval = 3.0
    /// 用户交互令牌，递增后可通知 VLC 子视图重置自动隐藏逻辑。
    @State private var vlcInteractionToken = 0
    
    /// 当前实际生效的播放器内核。
    /// 优先读取直播专用字段，再回退老字段，最后使用默认值。
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) != nil {
            rawValue = livePlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.isVLCAvailable
                ? PlayerEngine.vlc.rawValue
                : PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if viewModel.channelGroups.isEmpty {
                    emptyState
                    #if os(iOS)
                    // 无频道时也必须保留退出入口，不能依赖只在有频道时出现的覆盖层。
                    VStack {
                        HStack {
                            liveBackButton
                            Spacer()
                        }
                        .padding(.top, 18)
                        .padding(.horizontal, 16)
                        Spacer()
                    }
                    #endif
                } else {
                    // 播放器
                    if selectedEngine == .vlc {
                        if let channel = viewModel.currentChannel,
                           let urlString = channel.currentUrl, !urlString.isEmpty {
                            VLCLivePlayerView(
                                urlString: urlString,
                                userAgent: channel.currentUserAgent,
                                activityToken: vlcInteractionToken,
                                onPlaybackFailed: {
                                    // 回调携带自身地址，只有仍是当前会话的地址才处理。
                                    handlePlaybackFailure(url: urlString, trigger: "vlc_error")
                                },
                                onPlaybackStarted: {
                                    handlePlaybackStarted(url: urlString)
                                },
                                onToggleFullScreen: {
                                    toggleWindowFullScreen()
                                }
                            )
                            .ignoresSafeArea()
                            .id("vlc-live-\(urlString)-\(channel.groupName)-\(channel.channelName)-\(playbackAttempt)")
                        }
                    } else if let player = avPlayer {
                        PlatformVideoPlayer(player: player)
                            .ignoresSafeArea()
                    }
                    
                    // 覆盖 UI
                    overlayUI
                    
                    if let error = liveErrorMessage {
                        playbackErrorPanel(error)
                    }
                }
            }
            .navigationTitle("直播")
            #if os(macOS)
            .toolbar(isWindowFullScreen ? .hidden : .visible, for: .windowToolbar)
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            // 只有确实在播放内容时才隐藏 TabBar；无源/加载中/加载失败时保留常规导航。
            .toolbar(viewModel.channelGroups.isEmpty ? .visible : .hidden, for: .tabBar)
            #endif
            .onAppear {
                // 首次进入/重新进入：频道可能早已就绪（URL 不会变化），必须显式确保播放会话存在。
                viewModel.loadChannels()
                ensurePlayback()
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentChannel?.currentUrl) { _, _ in
                ensurePlayback()
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentChannel?.id) { _, _ in
                // 切台后清空失败线路记录与错误，避免复用上个频道的失败状态。
                resetFailureTracking(for: viewModel.currentChannel)
                liveErrorMessage = nil
                liveStatusMessage = nil
                ensurePlayback()
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: selectedEngine) { _, _ in
                // 切换内核：旧会话作废，按新内核重新建立。
                cleanupPlayer()
                playbackSession = nil
                liveErrorMessage = nil
                ensurePlayback()
            }
            .onDisappear {
                cleanupPlayer()
                playbackSession = nil
                cancelChannelInfoAutoHide()
                #if os(macOS)
                appState.exitPlayerFullScreen()
                isWindowFullScreen = false
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isWindowFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isWindowFullScreen = false
                appState.exitPlayerFullScreen()
            }
            .onExitCommand {
                if showChannelDrawer {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                }
            }
            #endif
        }
    }
    
    // MARK: - 空状态
    
    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isLoading {
            VStack(spacing: 16) {
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(1.3)
                Text("正在加载直播频道…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "tv.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.gray)
                Text(viewModel.loadFailures.isEmpty ? "暂无直播源" : "直播列表加载失败")
                    .font(.headline)
                    .foregroundColor(.gray)
                if viewModel.loadFailures.isEmpty {
                    Text("请在设置中配置包含直播源的接口")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.loadFailures.prefix(3), id: \.self) { failure in
                        Text(failure)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    Button("重新加载") {
                        viewModel.reloadChannels()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                #if os(iOS)
                Button("返回首页") {
                    onExit?()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                #endif
            }
            .padding(.horizontal, 32)
        }
    }
    
    /// 频道播放失败的终态面板：说明原因并提供重试/切线。
    private func playbackErrorPanel(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("重试") {
                    retryCurrentChannel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                
                if let channel = viewModel.currentChannel, channel.sourceNum > 1 {
                    Button("切换线路") {
                        switchSourceManually()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 32)
    }
    
    // MARK: - 覆盖 UI
    
    private var overlayUI: some View {
        ZStack(alignment: .leading) {
            #if os(macOS)
            if showChannelDrawer {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showChannelDrawer = false
                        }
                    }
            }
            #endif
            
            VStack(spacing: 0) {
                HStack {
                    #if os(iOS)
                    liveBackButton
                    #endif
                    channelDrawerToggleButton
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 16)
                
                if let status = liveStatusMessage, liveErrorMessage == nil {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(.top, 10)
                }
                
                if !viewModel.loadFailures.isEmpty || viewModel.isLoading {
                    partialLoadBanner
                        .padding(.top, 8)
                }
                
                Spacer()
                
                // 底部当前频道信息
                if let channel = viewModel.currentChannel, showCurrentChannelInfo {
                    currentChannelInfo(channel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            #if os(macOS)
            if showChannelDrawer {
                channelDrawer
                    .padding(.leading, 12)
                    .padding(.vertical, 20)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: showCurrentChannelInfo)
        #if os(macOS)
        .animation(.easeInOut(duration: 0.2), value: showChannelDrawer)
        #endif
        .simultaneousGesture(
            TapGesture().onEnded {
                reportUserActivity()
            }
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $showChannelOverlay) {
            ChannelOverlayView(
                channelGroups: viewModel.channelGroups,
                selectedGroupIndex: $viewModel.selectedGroupIndex,
                currentChannels: viewModel.currentChannels,
                currentChannel: viewModel.currentChannel,
                onSelectGroup: { viewModel.selectGroup($0) },
                onSelectChannel: { channel in
                    viewModel.selectChannel(channel)
                    HapticManager.shared.mediumImpact()
                    showChannelOverlay = false
                },
                onDismiss: { showChannelOverlay = false }
            )
            .presentationBackground(.clear)
            .transition(.move(edge: .bottom))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showChannelOverlay)
        }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                reportUserActivity()
            case .ended:
                break
            }
        }
        #endif
    }
    
    /// 部分直播列表加载中/失败的提示（已加载的频道照常可播）。
    private var partialLoadBanner: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white)
                Text("仍有直播列表在加载…")
            } else {
                Image(systemName: "exclamationmark.circle")
                Text("\(viewModel.loadFailures.count) 个直播列表加载失败")
                Button("重试") {
                    viewModel.reloadChannels()
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
            }
        }
        .font(.caption)
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
    
    private var channelDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("频道菜单", systemImage: "list.bullet.rectangle.portrait")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            
            HStack(spacing: 0) {
                channelGroupList
                    .frame(width: 150)
                
                Divider()
                    .overlay(Color.white.opacity(0.1))
                
                channelList
                    .frame(width: 240)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 14)
    }
    
    #if os(iOS)
    private var liveBackButton: some View {
        Button {
            HapticManager.shared.lightImpact()
            onExit?()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
    #endif
    
    private var channelDrawerToggleButton: some View {
        Button {
            #if os(iOS)
            HapticManager.shared.lightImpact()
            showChannelOverlay = true
            #else
            withAnimation(.easeInOut(duration: 0.2)) {
                showChannelDrawer.toggle()
            }
            #endif
        } label: {
            HStack(spacing: 8) {
                #if os(iOS)
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                Text("频道")
                    .font(.system(size: 14, weight: .semibold))
                #else
                Image(systemName: showChannelDrawer ? "sidebar.left" : "sidebar.right")
                Text(showChannelDrawer ? "收起菜单" : "频道菜单")
                    .font(.system(size: 13, weight: .semibold))
                #endif
            }
            .foregroundColor(.white.opacity(0.9))
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            #else
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #endif
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .keyboardShortcut("m", modifiers: [.command])
        #endif
    }
    
    private func currentChannelInfo(_ channel: LiveChannelItem) -> some View {
        #if os(iOS)
        // iOS: 紧凑的底部信息栏，适合单手操作
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // 频道名称
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 线路信息
                if channel.sourceNum > 1 {
                    Text("线路 \(channel.sourceIndex + 1)/\(channel.sourceNum)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            // 操作按钮行
            if channel.sourceNum > 1 {
                HStack(spacing: 12) {
                    Button {
                        HapticManager.shared.mediumImpact()
                        wakeUpCurrentChannelInfo()
                        switchSourceManually()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13))
                            Text("切换线路")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(AppTheme.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        #else
        // macOS: 保持原有宽屏布局
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                if channel.sourceNum > 1 {
                    Text("正在播放：线路 \(channel.sourceIndex + 1) / \(channel.sourceNum)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                if channel.sourceNum > 1 {
                    Button {
                        wakeUpCurrentChannelInfo()
                        switchSourceManually()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                            Text("切换线路")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(AppTheme.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    wakeUpCurrentChannelInfo()
                    toggleWindowFullScreen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("全屏")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: AppTheme.glassRadius)
        .frame(maxWidth: currentChannelInfoMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(20)
        #endif
    }
    
    private func wakeUpCurrentChannelInfo() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showCurrentChannelInfo = true
        }
        channelInfoTimer?.invalidate()
        guard viewModel.currentChannel != nil else { return }
        
        channelInfoTimer = Timer.scheduledTimer(withTimeInterval: channelInfoAutoHideDelay, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                showCurrentChannelInfo = false
            }
        }
    }
    
    private func cancelChannelInfoAutoHide() {
        channelInfoTimer?.invalidate()
        channelInfoTimer = nil
    }
    
    private func reportUserActivity() {
        // 任意交互都刷新显示时间，并触发 VLC 子层同步交互状态。
        wakeUpCurrentChannelInfo()
        vlcInteractionToken &+= 1
    }
    
    // MARK: - 频道分组
    
    private var channelGroupList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.channelGroups.enumerated()), id: \.offset) { index, group in
                    Button {
                        withAnimation {
                            viewModel.selectGroup(index)
                        }
                    } label: {
                        Text(group.groupName)
                            .font(.system(size: 14, weight: viewModel.selectedGroupIndex == index ? .bold : .medium))
                            .foregroundColor(viewModel.selectedGroupIndex == index ? .orange : .white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                viewModel.selectedGroupIndex == index
                                    ? Color.white.opacity(0.1)
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 频道列表
    
    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.currentChannels) { channel in
                    Button {
                        withAnimation {
                            // 由 ViewModel 根据频道身份统一同步分组与频道索引。
                            viewModel.selectChannel(channel)
                        }
                    } label: {
                        HStack {
                            Text(channel.channelName)
                                .font(.system(size: 14, weight: viewModel.currentChannel?.id == channel.id ? .bold : .medium))
                                .foregroundColor(viewModel.currentChannel?.id == channel.id ? .orange : .white.opacity(0.8))
                            Spacer()
                            if channel.sourceNum > 1 {
                                Text("\(channel.sourceNum)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.3))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            viewModel.currentChannel?.id == channel.id
                                ? Color.orange.opacity(0.15)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 播放
    
    /// 确保当前频道存在有效的播放会话：首次进入、重新进入、换台、切线路、换内核都走这里。
    /// 同一地址的有效会话直接复用，不重复拉流。
    private func ensurePlayback() {
        guard let channel = viewModel.currentChannel,
              let urlString = channel.currentUrl, !urlString.isEmpty else {
            cleanupPlayer()
            playbackSession = nil
            return
        }
        
        if let session = playbackSession,
           session.url == urlString,
           session.channelId == channel.id,
           !session.hasFailed,
           selectedEngine == .vlc || avPlayer != nil {
            return
        }
        
        let session = LivePlaybackSession(
            id: UUID(),
            url: urlString,
            channelId: channel.id,
            sourceIndex: channel.sourceIndex
        )
        playbackSession = session
        
        guard selectedEngine == .system else {
            // VLC 内核由 VLCLivePlayerView 按地址自行拉流，这里只负责会话归属。
            cleanupPlayer()
            return
        }
        playChannel(channel, session: session)
    }
    
    private func playChannel(_ channel: LiveChannelItem, session: LivePlaybackSession) {
        cleanupPlayer()
        
        guard let url = URL(string: session.url) else {
            handlePlaybackFailure(sessionID: session.id, trigger: "invalid_url")
            return
        }
        
        // 使用配置声明的 UA（未配置时用默认浏览器 UA），部分 CDN 会拒绝没有 UA 的请求。
        let headers: [String: String] = [
            "User-Agent": channel.currentUserAgent ?? NetworkManager.defaultUserAgent
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        // 直播场景优先实时性，避免过多缓冲导致内存上涨
        playerItem.preferredForwardBufferDuration = 3
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        observePlaybackFailure(for: playerItem, sessionID: session.id)
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        observePlaybackProgress(of: newPlayer, sessionID: session.id)
        newPlayer.play()
        avPlayer = newPlayer
    }
    
    private func cleanupPlayer() {
        // 先移除观察者再释放播放器，避免悬空回调。
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }
        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
        itemStatusObserver = nil
        timeControlObserver = nil
        cancelStallRecovery()
        
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
    }
    
    /// 失败回调都捕获会话令牌，只有当前会话的回调才会被处理。
    private func observePlaybackFailure(for item: AVPlayerItem, sessionID: UUID) {
        // KVO 监听 item 状态失败。
        itemStatusObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
            if observedItem.status == .failed {
                DispatchQueue.main.async {
                    handlePlaybackFailure(sessionID: sessionID, trigger: "status_failed")
                }
            }
        }
        
        // 播放到结尾失败回调。
        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            handlePlaybackFailure(sessionID: sessionID, trigger: "item_failed")
        }
        
        // 卡顿不等于线路失效：给出恢复观察期，期满仍未恢复才判定失败。
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            scheduleStallRecovery(sessionID: sessionID)
        }
    }
    
    /// 观察出画状态：开始播放即清除错误、取消卡顿判定。
    private func observePlaybackProgress(of player: AVPlayer, sessionID: UUID) {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            guard observedPlayer.timeControlStatus == .playing else { return }
            DispatchQueue.main.async {
                guard playbackSession?.id == sessionID else { return }
                handlePlaybackStarted(sessionID: sessionID)
            }
        }
    }
    
    private func scheduleStallRecovery(sessionID: UUID) {
        guard playbackSession?.id == sessionID else { return }
        cancelStallRecovery()
        let workItem = DispatchWorkItem {
            guard playbackSession?.id == sessionID else { return }
            if avPlayer?.timeControlStatus == .playing { return }
            handlePlaybackFailure(sessionID: sessionID, trigger: "playback_stalled")
        }
        stallRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + stallRecoveryTimeout, execute: workItem)
    }
    
    private func cancelStallRecovery() {
        stallRecoveryWorkItem?.cancel()
        stallRecoveryWorkItem = nil
    }
    
    private func resetFailureTracking(for channel: LiveChannelItem?) {
        failedSourceIndices = []
        trackedChannelId = channel?.id
    }
    
    private func handlePlaybackStarted(url: String) {
        guard let session = playbackSession, session.url == url else { return }
        handlePlaybackStarted(sessionID: session.id)
    }
    
    private func handlePlaybackStarted(sessionID: UUID) {
        guard playbackSession?.id == sessionID else { return }
        cancelStallRecovery()
        liveErrorMessage = nil
    }
    
    /// VLC 失败回调携带的是该播放视图的地址，只有它仍是当前会话的地址才处理。
    private func handlePlaybackFailure(url: String, trigger: String) {
        guard let session = playbackSession, session.url == url else { return }
        handlePlaybackFailure(sessionID: session.id, trigger: trigger)
    }
    
    private func handlePlaybackFailure(sessionID: UUID, trigger: String) {
        // 只处理当前会话的第一次终态错误。
        guard var session = playbackSession, session.id == sessionID, !session.hasFailed else { return }
        session.hasFailed = true
        playbackSession = session
        cancelStallRecovery()
        
        guard let channel = viewModel.currentChannel, channel.id == session.channelId else { return }
        if trackedChannelId != channel.id {
            resetFailureTracking(for: channel)
        }
        failedSourceIndices.insert(session.sourceIndex)
        
        if channel.sourceNum > 1, switchToNextAvailableSource(totalSources: channel.sourceNum) {
            let nextIndex = (viewModel.currentChannel?.sourceIndex ?? 0) + 1
            let message = "线路 \(session.sourceIndex + 1) 无法播放，已切换到线路 \(nextIndex)"
            liveStatusMessage = message
            // 提示短暂显示即可，避免长期遮挡画面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if liveStatusMessage == message {
                    liveStatusMessage = nil
                }
            }
            return
        }
        
        print("直播线路全部尝试失败: channel=\(channel.channelName), trigger=\(trigger)")
        liveStatusMessage = nil
        liveErrorMessage = channel.sourceNum > 1
            ? "「\(channel.channelName)」的 \(channel.sourceNum) 条线路均无法播放"
            : "「\(channel.channelName)」暂时无法播放"
    }
    
    private func switchToNextAvailableSource(totalSources: Int) -> Bool {
        guard failedSourceIndices.count < totalSources else { return false }
        
        // 最多轮询 `totalSources` 次，找到一条尚未失败的线路即返回。
        for _ in 0..<totalSources {
            viewModel.switchSource()
            guard let nextIndex = viewModel.currentChannel?.sourceIndex else { return false }
            if !failedSourceIndices.contains(nextIndex) {
                return true
            }
        }
        
        return false
    }
    
    /// 用户手动切换线路：视为新一轮尝试。
    private func switchSourceManually() {
        resetFailureTracking(for: viewModel.currentChannel)
        liveErrorMessage = nil
        liveStatusMessage = nil
        viewModel.switchSource()
    }
    
    /// 重试当前频道：清空失败记录并强制重新拉流（地址不变也会重建会话）。
    private func retryCurrentChannel() {
        resetFailureTracking(for: viewModel.currentChannel)
        liveErrorMessage = nil
        liveStatusMessage = nil
        playbackSession = nil
        playbackAttempt &+= 1
        ensurePlayback()
    }
    
    #if os(macOS)
    private func toggleWindowFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let enteringFullScreen = !window.styleMask.contains(.fullScreen)
        if enteringFullScreen {
            isWindowFullScreen = true
            appState.enterPlayerFullScreen()
        }
        window.toggleFullScreen(nil)
    }
    #else
    private func toggleWindowFullScreen() {}
    #endif
}
