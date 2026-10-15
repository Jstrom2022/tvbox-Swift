import SwiftUI
import Darwin

#if canImport(VLCKitSPM)
import VLCKitSPM
#if os(iOS)
import UIKit
#endif

@MainActor
final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let defaultVolume = 100
    static let maxVolume = 200
    private static let drawableSizeChangeThreshold: CGFloat = 24
    private static let drawableRebindMinimumInterval: TimeInterval = 1.2
    // 这些选项在播放器实例级别生效，优先约束 libvlc 的追时钟/丢帧行为。
    private static let stablePlaybackOptions: [String] = [
        "--no-drop-late-frames",
        "--no-skip-frames",
        "--clock-synchro=0",
        "--clock-jitter=0"
    ]
    private static let playerInstanceSelector = NSSelectorFromString("playerInstance")
    private static let libVLCStopAsync: LibVLCStopAsyncFunction? = {
        // RTLD_DEFAULT 在 Swift 中不可直接用常量名，-2 等价于 C 宏 RTLD_DEFAULT。
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        return "libvlc_media_player_stop_async".withCString { symbolName in
            guard let symbol = dlsym(defaultHandle, symbolName) else { return nil }
            return unsafeBitCast(symbol, to: LibVLCStopAsyncFunction.self)
        }
    }()
    private typealias LibVLCStopAsyncFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    
    private var _mediaPlayer: VLCMediaPlayer?
    var mediaPlayer: VLCMediaPlayer {
        if let existing = _mediaPlayer {
            return existing
        }
        let player = VLCMediaPlayer(options: VLCPlayerController.stablePlaybackOptions)
        _mediaPlayer = player
        player.delegate = self
        player.drawable = persistentDrawableView
        return player
    }
    @Published var isPreparing = true
    @Published var isPlaying = false
    @Published var currentTimeSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var volume: Int = defaultVolume
    /// 播放失败原因（供 UI 展示与重试）。空表示当前没有错误。
    @Published var playbackError: String?
    /// 重试时使用的最近一次失败媒体信息。
    private var lastFailedMedia: (url: URL, startPosition: Double, isLive: Bool)?
    #if os(macOS)
    private let persistentDrawableView = NSView(frame: .zero)
    private weak var lastAttachedContainer: NSView?
    #else
    private let persistentDrawableView = UIView(frame: .zero)
    private weak var lastAttachedContainer: UIView?
    #endif
    private var rebindWorkItems: [DispatchWorkItem] = []
    private var lastDrawableContainerIdentifier: ObjectIdentifier?
    private var lastDrawableContainerSize: CGSize = .zero
    private var lastDrawableRebindAt: Date = .distantPast
    
    var hasValidDuration: Bool {
        durationSeconds > 0
    }
    
    private var progressTimer: Timer?
    private var pendingSeekSeconds: Double?
    /// 最近一次定位的目标与时间，用于等待播放器追上目标位置后再上报进度。
    private var seekBaseline: (target: Double, at: Date)?
    /// 当前媒体的选流约束、UA 与请求头，参与“是否需要重建媒体”的判断。
    private var currentMediaConstraint: PlaybackQualityConstraint?
    private var currentMediaUserAgent: String?
    private var currentMediaHTTPHeaders: [String: String] = [:]
    private var isLive = false
    private var isInBufferingState = false
    private var pendingVodBufferingConfirmWorkItem: DispatchWorkItem?
    private var bufferingBaselineSecondsVod: Double = 0
    private var decodeMode: VideoDecodeMode = .auto
    private var decodeModeOverride: VideoDecodeMode?
    private var hasAttemptedSoftDecodeFallback = false
    private var bufferMode: VLCBufferMode = .defaultMode
    private var bufferingFallbackWorkItem: DispatchWorkItem?
    private var delayedPreparingWorkItem: DispatchWorkItem?
    private var currentMediaURLString: String?
    private var currentMediaIsLive = false
    private var currentMediaDecodeMode: VideoDecodeMode = .auto
    private var currentMediaBufferMode: VLCBufferMode = .defaultMode
    private var onProgressChanged: ((Double, Double?) -> Void)?
    private var onPlaybackEnded: (() -> Void)?
    private var onPlaybackFailed: (() -> Void)?
    private let progressUpdateIntervalVod: TimeInterval = 0.5
    private let progressUpdateIntervalLive: TimeInterval = 1.0
    private let bufferingFallbackThresholdLive: TimeInterval = 4.0
    private let bufferingConfirmDelayVod: TimeInterval = 0.35
    private let bufferingIndicatorDelayVod: TimeInterval = 1.2
    private let vodBufferingProgressAdvanceThreshold: Double = 0.25
    private let progressPublishThreshold: Double = 0.25
    private let durationPublishThreshold: Double = 0.5
    private var lastNonZeroVolume = defaultVolume
    /// 用户的播放意图：重绑画面等内部操作不得改变它。
    private var wantsPlayback = false
    /// 需要保留 HLS 主列表时的选流约束。
    private var qualityConstraint: PlaybackQualityConstraint?
    /// 直播来源要求的 User-Agent（来自配置的 `ua`）。
    private var userAgent: String?
    /// 点播来源要求的请求头（T4 play 接口返回）：VLC 媒体选项只能携带其中的 User-Agent 与 Referer。
    private var httpHeaders: [String: String] = [:]
    
    override init() {
        super.init()
        let savedObj = UserDefaults.standard.object(forKey: HawkConfig.PLAY_SPEED)
        let savedRate = savedObj != nil ? Float(UserDefaults.standard.double(forKey: HawkConfig.PLAY_SPEED)) : 1.0
        playbackRate = Self.normalizedPlaybackRate(from: savedRate)
        decodeMode = VideoDecodeMode.fromStoredValue(
            UserDefaults.standard.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        bufferMode = VLCBufferMode.stored()
        let savedVolumeObj = UserDefaults.standard.object(forKey: HawkConfig.PLAY_VOLUME)
        let savedVolume = savedVolumeObj != nil ? UserDefaults.standard.integer(forKey: HawkConfig.PLAY_VOLUME) : Self.defaultVolume
        volume = Self.normalizedVolume(from: savedVolume)
        if volume > 0 {
            lastNonZeroVolume = volume
        }
        #if os(macOS)
        persistentDrawableView.wantsLayer = true
        persistentDrawableView.layer?.backgroundColor = NSColor.black.cgColor
        #else
        persistentDrawableView.backgroundColor = .black
        #endif
    }
    
    deinit {
        if let player = _mediaPlayer {
            _mediaPlayer = nil
            // VLCMediaPlayer 的 dealloc 会阻塞（libvlc_media_player_release 内部 dispatch_sync 到主线程）。
            // 将引用移到后台线程，让 dealloc 在后台发生，避免阻塞主线程。
            nonisolated(unsafe) let p = player
            DispatchQueue.global(qos: .utility).async { [p] in
                _ = p
            }
        }
    }
    
    func play(
        url: URL,
        startPosition: Double,
        isLive: Bool,
        qualityConstraint: PlaybackQualityConstraint? = nil,
        userAgent: String? = nil,
        httpHeaders: [String: String] = [:],
        onProgressChanged: ((Double, Double?) -> Void)?,
        onPlaybackEnded: (() -> Void)?,
        onPlaybackFailed: (() -> Void)?
    ) {
        let targetURLString = url.absoluteString
        let isNewMedia = currentMediaURLString != targetURLString || currentMediaIsLive != isLive
        if isNewMedia {
            resetPlaybackRecoveryState()
        }
        syncDecodeModeFromSettings()
        syncBufferModeFromSettings()
        // 约束、UA 或请求头变化也需要重建媒体，否则选流范围与请求头不会生效。
        let mediaOptionsChanged = currentMediaConstraint != qualityConstraint
            || currentMediaUserAgent != userAgent
            || currentMediaHTTPHeaders != httpHeaders
        self.qualityConstraint = qualityConstraint
        self.userAgent = userAgent
        self.httpHeaders = httpHeaders
        
        // 同一路径/同场景（点播或直播）时复用当前实例，避免切全屏触发重新加载
        if currentMediaURLString == targetURLString,
           currentMediaIsLive == isLive,
           currentMediaDecodeMode == decodeMode,
           currentMediaBufferMode == bufferMode,
           !mediaOptionsChanged,
           mediaPlayer.media != nil {
            self.onProgressChanged = onProgressChanged
            self.onPlaybackEnded = onPlaybackEnded
            self.onPlaybackFailed = onPlaybackFailed
            self.isLive = isLive
            applyPlaybackRate()
            applyVolume()
            refreshPlaybackFlags()
            emitProgress()
            return
        }
        
        stopProgressTimer()
        cancelBufferingFallbackTimer()
        cancelDelayedPreparingIndicator()
        cancelPendingVodBufferingConfirmation()
        isInBufferingState = false
        // 只有开始新媒体才重置播放意图与错误；上面的复用分支（如进出全屏）必须保留用户的暂停意图。
        wantsPlayback = true
        playbackError = nil
        lastFailedMedia = nil
        seekBaseline = nil
        self.onProgressChanged = onProgressChanged
        self.onPlaybackEnded = onPlaybackEnded
        self.onPlaybackFailed = onPlaybackFailed
        self.isLive = isLive
        // 只有确实需要定位时才标记为待应用，否则会永久屏蔽进度上报。
        pendingSeekSeconds = (!isLive && startPosition > 0) ? startPosition : nil
        setPlaybackStatus(preparing: true, playing: false)
        resetProgressState()
        
        mediaPlayer.stop()
        let media = VLCMedia(url: url)
        
        let cacheConfig = Self.cacheConfig(isLive: isLive, bufferMode: bufferMode)
        let enableFrameDrop = isLive ? bufferMode.enableFrameDrop : false
        let enableSkipFrames = isLive && bufferMode.enableFrameDrop
        var mediaOptions: [String: Any] = [
            "network-caching": cacheConfig.network,
            "live-caching": cacheConfig.live,
            "file-caching": cacheConfig.file,
            "http-reconnect": 1,
            "http-user-agent": Self.resolvedUserAgent(Self.headerValue("User-Agent", in: httpHeaders) ?? userAgent)
        ]
        if let referer = Self.headerValue("Referer", in: httpHeaders) {
            mediaOptions["http-referrer"] = referer
        }
        // 依赖 HLS 主列表中带 URI 的外置音轨/字幕组时，保留主列表并按约束选流。
        mediaOptions.merge(Self.adaptiveOptions(for: qualityConstraint)) { _, new in new }
        if !isLive {
            mediaOptions["avcodec-hurry-up"] = 0
            mediaOptions["clock-synchro"] = 0
        }

        if let hwOption = decodeMode.vlcHardwareDecodeOption {
            mediaOptions["avcodec-hw"] = hwOption
        }
        if isLive {
            mediaOptions["avcodec-fast"] = 1
        }
        if url.scheme?.lowercased() == "rtsp" {
            mediaOptions["rtsp-tcp"] = 1
        }
        
        media.addOptions(mediaOptions)
        // 对布尔型选项使用显式 no- 前缀，避免 0/1 在不同 libvlc 版本下解释不一致。
        media.addOption(enableFrameDrop ? "drop-late-frames" : "no-drop-late-frames")
        media.addOption(enableSkipFrames ? "skip-frames" : "no-skip-frames")
        
        mediaPlayer.media = media
        mediaPlayer.play()
        applyPlaybackRate()
        applyVolume()
        startProgressTimer()
        currentMediaURLString = targetURLString
        currentMediaIsLive = isLive
        currentMediaDecodeMode = decodeMode
        currentMediaBufferMode = bufferMode
        currentMediaConstraint = qualityConstraint
        currentMediaUserAgent = userAgent
        currentMediaHTTPHeaders = httpHeaders
    }

    /// 以当前媒体重新播放（播放失败后的重试入口）；返回是否发起了重试。
    @discardableResult
    func retryCurrentMedia() -> Bool {
        let failed: (url: URL, startPosition: Double, isLive: Bool)?
        if let lastFailedMedia {
            failed = lastFailedMedia
        } else if let urlString = currentMediaURLString, let url = URL(string: urlString) {
            failed = (url: url, startPosition: isLive ? 0 : max(currentSeconds(), 0), isLive: isLive)
        } else {
            failed = nil
        }
        guard let failed else { return false }
        // 清除当前媒体标记，确保不会走“同一地址复用”分支而是真正重新拉流。
        currentMediaURLString = nil
        play(
            url: failed.url,
            startPosition: failed.startPosition,
            isLive: failed.isLive,
            qualityConstraint: qualityConstraint,
            userAgent: userAgent,
            httpHeaders: httpHeaders,
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded,
            onPlaybackFailed: onPlaybackFailed
        )
        return true
    }
    
    func stop() {
        stopProgressTimer()
        resetPlaybackRecoveryState()
        cancelScheduledRebinds()
        onProgressChanged = nil
        onPlaybackEnded = nil
        onPlaybackFailed = nil
        pendingSeekSeconds = nil
        setPlaybackStatus(preparing: false, playing: false)
        resetProgressState()
        currentMediaURLString = nil
        currentMediaIsLive = false
        currentMediaDecodeMode = .auto
        currentMediaBufferMode = .defaultMode
        currentMediaConstraint = nil
        currentMediaUserAgent = nil
        currentMediaHTTPHeaders = [:]
        wantsPlayback = false
        qualityConstraint = nil
        userAgent = nil
        httpHeaders = [:]
        playbackError = nil
        lastFailedMedia = nil
        guard let player = _mediaPlayer else { return }
        // 立即静音（audio.volume 是轻量属性设置，不会 dispatch_sync）
        player.audio?.volume = 0
        // 将 mediaPlayer 引用移到后台释放。
        // 不调用 pause/stop/media=nil 等 VLC API — 它们会 dispatch_sync 回主线程导致卡顿。
        // VLCMediaPlayer 的 dealloc 会在后台线程自然完成清理。
        _mediaPlayer = nil
        nonisolated(unsafe) let p = player
        DispatchQueue.global(qos: .utility).async { [p] in
            _ = p
        }
    }
    
    func togglePlayback() {
        // 用播放意图而非瞬时状态判断，避免缓冲中的点击被反转。
        if wantsPlayback {
            wantsPlayback = false
            mediaPlayer.pause()
        } else {
            wantsPlayback = true
            playbackError = nil
            mediaPlayer.play()
            applyPlaybackRate()
        }
    }
    
    func setPlaybackRate(_ rate: Float) {
        let normalized = Self.normalizedPlaybackRate(from: rate)
        playbackRate = normalized
        UserDefaults.standard.set(Double(normalized), forKey: HawkConfig.PLAY_SPEED)
        applyPlaybackRate()
    }
    
    func increasePlaybackRate() {
        guard let index = Self.supportedPlaybackRates.firstIndex(of: playbackRate),
              index + 1 < Self.supportedPlaybackRates.count else { return }
        setPlaybackRate(Self.supportedPlaybackRates[index + 1])
    }
    
    func decreasePlaybackRate() {
        guard let index = Self.supportedPlaybackRates.firstIndex(of: playbackRate),
              index - 1 >= 0 else { return }
        setPlaybackRate(Self.supportedPlaybackRates[index - 1])
    }

    func setVolume(_ value: Int) {
        let normalized = Self.normalizedVolume(from: value)
        if volume != normalized {
            volume = normalized
        }
        if normalized > 0 {
            lastNonZeroVolume = normalized
        }
        UserDefaults.standard.set(normalized, forKey: HawkConfig.PLAY_VOLUME)
        applyVolume()
    }

    func toggleMute() {
        if volume == 0 {
            let restored = lastNonZeroVolume > 0 ? lastNonZeroVolume : Self.defaultVolume
            setVolume(restored)
        } else {
            setVolume(0)
        }
    }
    
    #if os(macOS)
    func attachDrawable(to container: NSView) {
        let containerIdentifier = ObjectIdentifier(container)
        let containerSize = container.bounds.size
        let containerChanged = lastDrawableContainerIdentifier != containerIdentifier
        let sizeChanged = hasSignificantContainerSizeChange(to: containerSize)
        let canRebindForSizeChange = canRebindDrawableForSizeChange()
        lastAttachedContainer = container
        lastDrawableContainerIdentifier = containerIdentifier
        lastDrawableContainerSize = containerSize
        let shouldRebind = containerChanged || (sizeChanged && canRebindForSizeChange) || persistentDrawableView.superview !== container || mediaPlayer.drawable == nil

        if persistentDrawableView.superview !== container {
            persistentDrawableView.removeFromSuperview()
            persistentDrawableView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(persistentDrawableView)
            NSLayoutConstraint.activate([
                persistentDrawableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                persistentDrawableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                persistentDrawableView.topAnchor.constraint(equalTo: container.topAnchor),
                persistentDrawableView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            container.layoutSubtreeIfNeeded()
        }

        guard shouldRebind else { return }

        cancelScheduledRebinds()
        refreshDrawableBinding()
        scheduleDelayedDrawableRebind(for: container)
        resumePlaybackAfterDrawableRebindIfNeeded()
    }
    
    func detachDrawable(from container: NSView) {
        if lastAttachedContainer === container {
            lastAttachedContainer = nil
            lastDrawableContainerIdentifier = nil
            lastDrawableContainerSize = .zero
        }
        cancelScheduledRebinds()
        if persistentDrawableView.superview === container {
            persistentDrawableView.removeFromSuperview()
        }
    }
    #else
    func attachDrawable(to container: UIView) {
        let containerIdentifier = ObjectIdentifier(container)
        let containerSize = container.bounds.size
        let containerChanged = lastDrawableContainerIdentifier != containerIdentifier
        let sizeChanged = hasSignificantContainerSizeChange(to: containerSize)
        let canRebindForSizeChange = canRebindDrawableForSizeChange()
        lastAttachedContainer = container
        lastDrawableContainerIdentifier = containerIdentifier
        lastDrawableContainerSize = containerSize
        let shouldRebind = containerChanged || (sizeChanged && canRebindForSizeChange) || persistentDrawableView.superview !== container || mediaPlayer.drawable == nil

        if persistentDrawableView.superview !== container {
            persistentDrawableView.removeFromSuperview()
            persistentDrawableView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(persistentDrawableView)
            NSLayoutConstraint.activate([
                persistentDrawableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                persistentDrawableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                persistentDrawableView.topAnchor.constraint(equalTo: container.topAnchor),
                persistentDrawableView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            container.layoutIfNeeded()
        }

        guard shouldRebind else { return }

        cancelScheduledRebinds()
        refreshDrawableBinding()
        scheduleDelayedDrawableRebind(for: container)
        resumePlaybackAfterDrawableRebindIfNeeded()
    }
    
    func detachDrawable(from container: UIView) {
        if lastAttachedContainer === container {
            lastAttachedContainer = nil
            lastDrawableContainerIdentifier = nil
            lastDrawableContainerSize = .zero
        }
        cancelScheduledRebinds()
        if persistentDrawableView.superview === container {
            persistentDrawableView.removeFromSuperview()
        }
    }
    #endif

    private func refreshDrawableBinding() {
        #if os(macOS)
        // macOS: 强制重绑视频输出，规避切全屏后偶发“有声音无画面”
        mediaPlayer.drawable = nil
        mediaPlayer.drawable = persistentDrawableView
        #else
        // iOS: 直接赋值，不置空 drawable，避免触发 state change 导致 SwiftUI dismiss 动画中断
        mediaPlayer.drawable = persistentDrawableView
        #endif
        lastDrawableRebindAt = Date()
    }

    private func stopMediaPlayer() {
        // 优先走 libvlc 异步 stop，避免菜单切换时主线程被同步 stop 卡住。
        if let playerPointer = playerInstancePointer(),
           let stopAsync = Self.libVLCStopAsync {
            stopAsync(playerPointer)
            return
        }
        // VLCKit 3.x 没有 async stop API，同步 stop 会阻塞主线程 2-3 秒。
        // 将其放到后台队列执行，避免 UI 卡顿。
        nonisolated(unsafe) let player = mediaPlayer
        DispatchQueue.global(qos: .userInitiated).async {
            player.stop()
        }
    }

    private func playerInstancePointer() -> UnsafeMutableRawPointer? {
        let selector = Self.playerInstanceSelector
        guard mediaPlayer.responds(to: selector) else { return nil }
        typealias PlayerInstanceGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        let imp = mediaPlayer.method(for: selector)
        let getter = unsafeBitCast(imp, to: PlayerInstanceGetter.self)
        return getter(mediaPlayer, selector)
    }

    private func cancelScheduledRebinds() {
        rebindWorkItems.forEach { $0.cancel() }
        rebindWorkItems.removeAll()
    }

    private func hasSignificantContainerSizeChange(to newSize: CGSize) -> Bool {
        let previousSize = lastDrawableContainerSize
        guard previousSize != .zero else { return false }
        let widthChanged = abs(newSize.width - previousSize.width) > Self.drawableSizeChangeThreshold
        let heightChanged = abs(newSize.height - previousSize.height) > Self.drawableSizeChangeThreshold
        return widthChanged || heightChanged
    }

    private func canRebindDrawableForSizeChange() -> Bool {
        Date().timeIntervalSince(lastDrawableRebindAt) >= Self.drawableRebindMinimumInterval
    }

    private func resumePlaybackAfterDrawableRebindIfNeeded() {
        guard mediaPlayer.media != nil else { return }
        // 重绑画面只恢复渲染：用户主动暂停（wantsPlayback == false）时必须保持暂停。
        if wantsPlayback,
           !mediaPlayer.isPlaying,
           mediaPlayer.state != .opening,
           mediaPlayer.state != .buffering {
            mediaPlayer.play()
        }
        applyPlaybackRate()
    }

    #if os(macOS)
    private func scheduleDelayedDrawableRebind(for container: NSView) {
        [0.05, 0.18].forEach { delay in
            let workItem = DispatchWorkItem { [weak self, weak container] in
                guard let self, let container else { return }
                guard self.lastAttachedContainer === container else { return }
                guard self.persistentDrawableView.superview === container else { return }
                self.refreshDrawableBinding()
                self.resumePlaybackAfterDrawableRebindIfNeeded()
            }
            rebindWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
    #else
    private func scheduleDelayedDrawableRebind(for container: UIView) {
        [0.05, 0.18].forEach { delay in
            let workItem = DispatchWorkItem { [weak self, weak container] in
                guard let self, let container else { return }
                guard self.lastAttachedContainer === container else { return }
                guard self.persistentDrawableView.superview === container else { return }
                self.refreshDrawableBinding()
                self.resumePlaybackAfterDrawableRebindIfNeeded()
            }
            rebindWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
    #endif
    
    func seek(by offset: Double) {
        guard !isLive else { return }
        var target = max(currentTimeSeconds + offset, 0)
        if hasValidDuration {
            target = min(target, durationSeconds)
        }
        seek(to: target)
    }
    
    func seek(to seconds: Double) {
        guard !isLive else { return }
        let maxSeconds = min(durationSeconds > 0 ? durationSeconds : Double(Int32.max) / 1000.0, Double(Int32.max) / 1000.0)
        let value = max(0, min(seconds, maxSeconds))
        mediaPlayer.time = VLCTime(int: Int32(value * 1000.0))
        seekBaseline = (target: value, at: Date())
        emitProgress()
    }
    
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            self?.handlePlayerStateChanged()
        }
    }
    
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // 使用定时器统一采样进度，避免 VLC 高频 time 回调带来主线程负载。
    }
    
    private func handlePlayerStateChanged() {
        switch mediaPlayer.state {
        case .opening, .buffering:
            handleBufferingState()
        case .playing:
            handlePlayingState()
        case .paused:
            isInBufferingState = false
            cancelDelayedPreparingIndicator()
            cancelPendingVodBufferingConfirmation()
            setPlaybackStatus(preparing: false, playing: false)
            cancelBufferingFallbackTimer()
        case .ended:
            isInBufferingState = false
            cancelDelayedPreparingIndicator()
            cancelPendingVodBufferingConfirmation()
            setPlaybackStatus(preparing: false, playing: false)
            cancelBufferingFallbackTimer()
            wantsPlayback = false
            onPlaybackEnded?()
        case .error:
            isInBufferingState = false
            cancelDelayedPreparingIndicator()
            cancelPendingVodBufferingConfirmation()
            setPlaybackStatus(preparing: false, playing: false)
            cancelBufferingFallbackTimer()
            wantsPlayback = false
            recordPlaybackFailure()
            onPlaybackFailed?()
        case .stopped:
            isInBufferingState = false
            cancelDelayedPreparingIndicator()
            cancelPendingVodBufferingConfirmation()
            setPlaybackStatus(preparing: false, playing: false)
            cancelBufferingFallbackTimer()
        default:
            break
        }
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        let interval = isLive ? progressUpdateIntervalLive : progressUpdateIntervalVod
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitProgress()
            }
        }
        timer.tolerance = interval * 0.25
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func applyPendingSeekIfNeeded() {
        guard let pendingSeekSeconds, pendingSeekSeconds > 0 else { return }
        seek(to: pendingSeekSeconds)
        self.pendingSeekSeconds = nil
    }
    
    private func emitProgress() {
        refreshPlaybackFlags()
        guard !isLive else { return }
        // 起播定位尚未应用时读到的是旧位置，上报会让上层丢掉续播进度。
        guard pendingSeekSeconds == nil else { return }
        let current = currentSeconds()
        // 定位刚下发时播放器可能仍返回旧位置，等它追上目标后再上报。
        if let baseline = seekBaseline {
            if Date().timeIntervalSince(baseline.at) < 2.0,
               abs(current - baseline.target) > 0.5 {
                return
            }
            seekBaseline = nil
        }
        guard current.isFinite, current >= 0 else { return }
        
        let roundedCurrent = (current / progressPublishThreshold).rounded() * progressPublishThreshold
        let didUpdateCurrent = abs(roundedCurrent - currentTimeSeconds) >= progressPublishThreshold
        if didUpdateCurrent {
            currentTimeSeconds = roundedCurrent
        }
        
        var didUpdateDuration = false
        if let duration = durationSecondsFromMedia() {
            if abs(duration - durationSeconds) >= durationPublishThreshold {
                durationSeconds = duration
                didUpdateDuration = true
            }
        }
        
        guard didUpdateCurrent || didUpdateDuration else { return }
        onProgressChanged?(currentTimeSeconds, hasValidDuration ? durationSeconds : nil)
    }
    
    private func refreshPlaybackFlags() {
        // 部分直播源会长时间停留在 buffering/opening 回调，但实际已开始渲染。
        // 使用底层 isPlaying 兜底，避免“永远加载中”。
        if mediaPlayer.isPlaying {
            isInBufferingState = false
            cancelDelayedPreparingIndicator()
            cancelPendingVodBufferingConfirmation()
            setPlaybackStatus(preparing: false, playing: true)
            playbackError = nil
            cancelBufferingFallbackTimer()
            return
        }
        
        switch mediaPlayer.state {
        case .opening, .buffering:
            setPlaybackStatus(preparing: true, playing: false)
        case .playing:
            setPlaybackStatus(preparing: false, playing: true)
        case .paused, .stopped, .ended, .error:
            setPlaybackStatus(preparing: false, playing: false)
        default:
            break
        }
    }
    
    private func applyPlaybackRate() {
        guard mediaPlayer.rate != playbackRate else { return }
        mediaPlayer.rate = playbackRate
    }

    private func applyVolume() {
        let target = Int32(volume)
        guard mediaPlayer.audio?.volume != target else { return }
        mediaPlayer.audio?.volume = target
    }
    
    private func syncDecodeModeFromSettings() {
        if let decodeModeOverride {
            decodeMode = decodeModeOverride
            return
        }
        decodeMode = VideoDecodeMode.fromStoredValue(
            UserDefaults.standard.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
    }

    private func syncBufferModeFromSettings() {
        bufferMode = VLCBufferMode.fromStoredValue(
            UserDefaults.standard.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )
    }
    
    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private static func normalizedVolume(from raw: Int) -> Int {
        min(max(raw, 0), maxVolume)
    }
    
    private static func cacheConfig(isLive: Bool, bufferMode: VLCBufferMode) -> (network: Int, live: Int, file: Int) {
        bufferMode.cacheConfig(isLive: isLive)
    }

    private func scheduleBufferingFallbackIfNeeded() {
        guard isLive else { return }
        guard bufferingFallbackWorkItem == nil else { return }
        guard !hasAttemptedSoftDecodeFallback else { return }
        guard decodeMode != .software else { return }
        guard mediaPlayer.media != nil else { return }

        let delay = bufferingFallbackThresholdLive
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.attemptSoftDecodeFallbackIfNeeded()
            }
        }
        bufferingFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelBufferingFallbackTimer() {
        bufferingFallbackWorkItem?.cancel()
        bufferingFallbackWorkItem = nil
    }

    private func attemptSoftDecodeFallbackIfNeeded() {
        cancelBufferingFallbackTimer()
        guard !hasAttemptedSoftDecodeFallback else { return }
        guard decodeMode != .software else { return }
        guard let urlString = currentMediaURLString, let url = URL(string: urlString) else { return }
        guard mediaPlayer.media != nil else { return }

        hasAttemptedSoftDecodeFallback = true
        decodeModeOverride = .software
        let resumePosition = isLive ? 0 : max(currentSeconds(), 0)
        // 只改变解码方式：选流约束、UA 与请求头必须沿用，否则回退后的媒体会丢失它们。
        play(
            url: url,
            startPosition: resumePosition,
            isLive: isLive,
            qualityConstraint: qualityConstraint,
            userAgent: userAgent,
            httpHeaders: httpHeaders,
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded,
            onPlaybackFailed: onPlaybackFailed
        )
    }

    private func handleBufferingState() {
        if isLive {
            if !isInBufferingState {
                isInBufferingState = true
            }
            setPlaybackStatus(preparing: true, playing: false)
            scheduleBufferingFallbackIfNeeded()
            return
        }

        if isInBufferingState {
            if isPlaying {
                isPlaying = false
            }
            scheduleDelayedPreparingIndicatorForVod()
            return
        }

        scheduleVodBufferingConfirmationIfNeeded()
    }

    private func handlePlayingState() {
        cancelPendingVodBufferingConfirmation()
        isInBufferingState = false
        cancelDelayedPreparingIndicator()
        setPlaybackStatus(preparing: false, playing: true)
        cancelBufferingFallbackTimer()
        applyPlaybackRate()
        applyVolume()
        applyPendingSeekIfNeeded()
    }

    private func scheduleDelayedPreparingIndicatorForVod() {
        guard !isLive else { return }
        guard delayedPreparingWorkItem == nil else { return }
        guard !isPreparing else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isInBufferingState, !self.mediaPlayer.isPlaying else { return }
            guard self.isStillStalledSinceBufferingStartedVod() else { return }
            self.setPlaybackStatus(preparing: true, playing: false)
        }
        delayedPreparingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferingIndicatorDelayVod, execute: workItem)
    }

    private func cancelDelayedPreparingIndicator() {
        delayedPreparingWorkItem?.cancel()
        delayedPreparingWorkItem = nil
    }

    private func scheduleVodBufferingConfirmationIfNeeded() {
        guard !isLive else { return }
        guard pendingVodBufferingConfirmWorkItem == nil else { return }
        bufferingBaselineSecondsVod = max(currentSeconds(), currentTimeSeconds)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVodBufferingConfirmWorkItem = nil
            guard self.isBufferingLikeState(self.mediaPlayer.state) else { return }
            guard !self.mediaPlayer.isPlaying else { return }
            guard self.isStillStalledSinceBufferingStartedVod() else { return }
            self.enterConfirmedVodBufferingState()
        }
        pendingVodBufferingConfirmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferingConfirmDelayVod, execute: workItem)
    }

    private func cancelPendingVodBufferingConfirmation() {
        pendingVodBufferingConfirmWorkItem?.cancel()
        pendingVodBufferingConfirmWorkItem = nil
    }

    private func enterConfirmedVodBufferingState() {
        guard !isLive else { return }
        guard !mediaPlayer.isPlaying else { return }
        if !isInBufferingState {
            isInBufferingState = true
        }
        if isPlaying {
            isPlaying = false
        }
        scheduleDelayedPreparingIndicatorForVod()
    }

    private func isStillStalledSinceBufferingStartedVod() -> Bool {
        let current = max(currentSeconds(), currentTimeSeconds)
        return (current - bufferingBaselineSecondsVod) < vodBufferingProgressAdvanceThreshold
    }

    private func isBufferingLikeState(_ state: VLCMediaPlayerState) -> Bool {
        switch state {
        case .opening, .buffering:
            return true
        default:
            return false
        }
    }

    private func resetPlaybackRecoveryState() {
        cancelBufferingFallbackTimer()
        cancelDelayedPreparingIndicator()
        cancelPendingVodBufferingConfirmation()
        hasAttemptedSoftDecodeFallback = false
        decodeModeOverride = nil
        isInBufferingState = false
        bufferingBaselineSecondsVod = 0
    }
    
    /// 记录失败信息，供 UI 展示原因并提供重试。
    private func recordPlaybackFailure() {
        if let urlString = currentMediaURLString, let url = URL(string: urlString) {
            lastFailedMedia = (url: url, startPosition: isLive ? 0 : max(currentSeconds(), 0), isLive: isLive)
        }
        if playbackError == nil {
            let unsupportedHeaders = Self.unsupportedHeaderNames(in: httpHeaders)
            if !isLive && !unsupportedHeaders.isEmpty {
                playbackError = "该资源需要携带 \(unsupportedHeaders.joined(separator: "、")) 请求头，VLC 内核目前只支持 User-Agent 与 Referer，请改用系统播放器"
            } else {
                playbackError = isLive
                    ? "直播流无法播放，请重试或切换线路"
                    : "该资源无法播放，可能是地址失效或编码不受支持"
            }
        }
    }

    /// 应用选流约束：在保留主列表的前提下，把自适应选流限制到目标档位。
    /// - 有码率时用固定码率策略，选择不超过目标 BANDWIDTH 的最高档（同分辨率不同码率也能区分）；
    /// - 同时用最大宽高排除更高分辨率的档位。
    private static func adaptiveOptions(for constraint: PlaybackQualityConstraint?) -> [String: Any] {
        guard let constraint else { return [:] }
        var options: [String: Any] = [:]

        if constraint.peakBitRate > 0 {
            options["adaptive-logic"] = "fixedrate"
            // adaptive-bw 单位为 KiB/s（libvlc 内部 ×8192 换算为 bit/s），向上取整避免目标档位被排除。
            options["adaptive-bw"] = max(1, Int((Double(constraint.peakBitRate) / 8192).rounded(.up)))
        } else {
            options["adaptive-logic"] = "highest"
        }
        if let height = constraint.maxHeight, height > 0 {
            options["adaptive-maxheight"] = height
        }
        if let width = constraint.maxWidth, width > 0 {
            options["adaptive-maxwidth"] = width
        }
        return options
    }

    static func resolvedUserAgent(_ configured: String?) -> String {
        guard let configured, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NetworkManager.defaultUserAgent
        }
        return configured
    }

    /// 按名称（不区分大小写）读取请求头。
    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// VLC 媒体选项无法携带的请求头（User-Agent 与 Referer 之外的，如 Cookie）。
    static func unsupportedHeaderNames(in headers: [String: String]) -> [String] {
        headers.keys
            .filter {
                $0.caseInsensitiveCompare("User-Agent") != .orderedSame
                    && $0.caseInsensitiveCompare("Referer") != .orderedSame
            }
            .sorted()
    }

    private func setPlaybackStatus(preparing: Bool, playing: Bool) {
        if isPreparing != preparing {
            isPreparing = preparing
        }
        if isPlaying != playing {
            isPlaying = playing
        }
    }
    
    private func resetProgressState() {
        if currentTimeSeconds != 0 {
            currentTimeSeconds = 0
        }
        if durationSeconds != 0 {
            durationSeconds = 0
        }
    }
    
    private func currentSeconds() -> Double {
        let raw = mediaPlayer.time.intValue
        if raw < 0 { return 0 }
        return Double(raw) / 1000.0
    }
    
    private func durationSecondsFromMedia() -> Double? {
        let raw = mediaPlayer.media?.length.intValue ?? 0
        guard raw > 0 else { return nil }
        return Double(raw) / 1000.0
    }
}

struct VLCVodPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var qualityConstraint: PlaybackQualityConstraint? = nil
    /// 播放请求需要携带的 HTTP 头（VLC 只能携带 User-Agent 与 Referer）。
    var httpHeaders: [String: String] = [:]
    var onProgressChanged: ((Double, Double?, String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: VLCPlayerController? = nil
    @StateObject private var ownedController = VLCPlayerController()
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var startPlaybackTask: Task<Void, Never>?
    /// VLC 画面缩放（捏合手势），换集/进出全屏时随视图重建复位，与系统内核一致。
    @State private var videoZoomScale: CGFloat = 1.0
    
    private var controller: VLCPlayerController {
        sharedController ?? ownedController
    }
    
    var body: some View {
        ZStack {
            VLCDrawableView(controller: controller)
                .background(Color.black)
                #if os(iOS)
                .scaleEffect(videoZoomScale)
                #endif
                .clipped()
            #if !os(iOS)
                .onTapGesture(count: 2) {
                    onToggleFullScreen?()
                }
                .onTapGesture(count: 1) {
                    togglePlaybackWithOSD()
                }
            #endif
            
            if controller.isPreparing {
                ProgressView()
                    .tint(.white)
            }
            
            if let error = controller.playbackError {
                playbackErrorPanel(error)
            }
            
            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            PlayerGestureLayer(
                onSeek: { offset in controller.seek(by: offset) },
                onTogglePlayPause: { togglePlaybackWithOSD() },
                onToggleControls: { wakeUpControls() },
                onZoomChanged: { scale in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        videoZoomScale = scale
                    }
                },
                currentTime: controller.currentTimeSeconds,
                duration: controller.durationSeconds,
                currentVolume: Double(controller.volume) / Double(VLCPlayerController.maxVolume),
                volumePercentScale: Double(VLCPlayerController.maxVolume),
                // VLC 音量范围 0...200，提示百分比与实际音量一致（100% 为原始音量）。
                onVolumeChanged: { normalized in
                    controller.setVolume(Int((normalized * Double(VLCPlayerController.maxVolume)).rounded()))
                    wakeUpControls()
                }
            )
        }
        #endif
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                playbackControls(containerWidth: proxy.size.width)
                    #if os(macOS)
                    .padding(12)
                    #endif
                    .opacity(showControls ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.3), value: showControls)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .overlay {
            KeyboardShortcutCaptureView(
                onLeft: { wakeUpControls(); controller.seek(by: -seekStep); showOSD(icon: "gobackward.\(Int(seekStep))") },
                onRight: { wakeUpControls(); controller.seek(by: seekStep); showOSD(icon: "goforward.\(Int(seekStep))") },
                onTogglePlayPause: { wakeUpControls(); togglePlaybackWithOSD() },
                onToggleFullScreen: { wakeUpControls(); onToggleFullScreen?() },
                onDecreaseSpeed: { wakeUpControls(); controller.decreasePlaybackRate(); showOSD(icon: "tortoise.fill") },
                onIncreaseSpeed: { wakeUpControls(); controller.increasePlaybackRate(); showOSD(icon: "hare.fill") },
                onVolumeDown: {
                    wakeUpControls()
                    controller.setVolume(controller.volume - volumeStep)
                    showOSD(icon: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                },
                onVolumeUp: {
                    wakeUpControls()
                    controller.setVolume(controller.volume + volumeStep)
                    showOSD(icon: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): wakeUpControls()
            case .ended: break
            }
        }
        .onAppear {
            startPlayback()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            startPlayback()
            wakeUpControls()
        }
        .onChange(of: qualityConstraint) { _, newValue in
            // VLC 只能通过媒体选项限制选流，约束变化需要从当前位置重建媒体。
            startPlayback(startPositionOverride: max(controller.currentTimeSeconds, 0), constraint: newValue)
        }
        .onChange(of: controller.currentTimeSeconds) { _, newValue in
            if !isDraggingProgress {
                draggingSeconds = newValue
            }
        }
        .onDisappear {
            startPlaybackTask?.cancel()
            startPlaybackTask = nil
            if sharedController == nil {
                controller.stop()
            }
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }
    
    private func wakeUpControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
    }
    
    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }
    
    private func togglePlaybackWithOSD() {
        controller.togglePlayback()
        showOSD(icon: controller.isPlaying ? "pause.fill" : "play.fill")
    }
    
    /// 播放失败面板：给出可识别的原因与重试/换内核入口，避免无提示黑屏。
    private func playbackErrorPanel(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.yellow)
            Text("播放失败")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button("重试") {
                    controller.retryCurrentMedia()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                
                Button("改用系统播放器") {
                    UserDefaults.standard.set(PlayerEngine.system.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding()
    }
    
    private func startPlayback(
        startPositionOverride: Double? = nil,
        constraint: PlaybackQualityConstraint?? = nil
    ) {
        guard let url = Self.sanitizedURL(from: urlString) else {
            print("[VLC] URL sanitization failed for: \(urlString)")
            return
        }
        let targetStartPosition = max(startPositionOverride ?? startPosition, 0)
        let targetConstraint = constraint ?? qualityConstraint
        let mediaURLString = urlString
        let progressHandler = onProgressChanged
        draggingSeconds = targetStartPosition
        startPlaybackTask?.cancel()
        startPlaybackTask = Task { @MainActor in
            // 先让出一个主线程周期，避免点击瞬间布局与播放器初始化竞争。
            await Task.yield()
            guard !Task.isCancelled else { return }
            controller.play(
                url: url,
                startPosition: targetStartPosition,
                isLive: false,
                qualityConstraint: targetConstraint,
                httpHeaders: httpHeaders,
                onProgressChanged: progressHandler.map { handler in
                    { seconds, duration in handler(seconds, duration, mediaURLString) }
                },
                onPlaybackEnded: onPlaybackEnded,
                onPlaybackFailed: nil
            )
        }
    }
    
    /// 将原始 URL 字符串转换为合法的 URL，处理未编码的特殊字符。
    private static func sanitizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            return url
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
    
    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Int { 10 }
    
    private var progressUpperBound: Double {
        max(controller.durationSeconds, max(controller.currentTimeSeconds, 1))
    }
    
    private var currentDisplaySeconds: Double {
        isDraggingProgress ? draggingSeconds : controller.currentTimeSeconds
    }
    
    private var totalDisplayText: String {
        controller.hasValidDuration ? controller.durationSeconds.durationString : "--:--"
    }
    
    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let controlWidth = containerWidth * 0.7
        #endif

        return VStack(spacing: 0) {
            #if os(iOS)
            // iOS: 紧凑单行布局 — 进度条在上，按钮在下紧贴
            HStack(spacing: 8) {
                Text(currentDisplaySeconds.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : controller.currentTimeSeconds },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            controller.seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(!controller.hasValidDuration)
                
                Text(totalDisplayText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // 控制按钮行 — 紧凑排列
            HStack(spacing: 0) {
                // 左：倍速
                playbackRateMenu
                    .frame(minWidth: 36, alignment: .leading)
                
                Spacer()
                
                // 中间：主控按钮
                HStack(spacing: 20) {
                    Button {
                        wakeUpControls()
                        controller.seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlaybackWithOSD()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        controller.seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                // 右：全屏
                if let onToggleFullScreen {
                    Button {
                        wakeUpControls()
                        onToggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            #else
            // macOS: 保持两行布局
            HStack(spacing: 12) {
                Text(currentDisplaySeconds.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : controller.currentTimeSeconds },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            controller.seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(!controller.hasValidDuration)
                
                Text(totalDisplayText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 0) {
                HStack(spacing: 16) {
                    playbackRateMenu
                }
                .frame(width: 150, alignment: .leading)
                
                Spacer()
                
                HStack(spacing: 24) {
                    Button {
                        wakeUpControls()
                        controller.seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlaybackWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 38, height: 38)
                            
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        controller.seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            controller.toggleMute()
                            showOSD(icon: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: Binding(
                                get: { Double(controller.volume) },
                                set: {
                                    controller.setVolume(Int($0.rounded()))
                                    wakeUpControls()
                                }
                            ),
                            in: 0...200,
                            step: 1
                        )
                        .accentColor(.white.opacity(0.8))
                        .frame(width: 80)
                    }
                    
                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.top, 8)
            #endif
        }
        #if os(iOS)
        .padding(.vertical, 2)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(.bottom, 0)
        .frame(width: controlWidth)
        #else
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .glassCard(cornerRadius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(width: controlWidth)
        #endif
        .environment(\.colorScheme, .dark)
    }
    
    private var playbackRateMenu: some View {
        Menu {
            ForEach(VLCPlayerController.supportedPlaybackRates, id: \.self) { rate in
                Button {
                    wakeUpControls()
                    controller.setPlaybackRate(rate)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text(playbackRateLabel(rate))
                        if rate == controller.playbackRate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(playbackRateLabel(controller.playbackRate))
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func playbackRateLabel(_ rate: Float) -> String {
        PlaybackRateFormatter.label(for: rate)
    }

    private var volumeIconName: String {
        switch controller.volume {
        case ...0:
            return "speaker.slash.fill"
        case 1...66:
            return "speaker.wave.1.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

struct VLCLivePlayerView: View {
    let urlString: String
    /// 来源配置要求的 User-Agent（配置 `ua` 字段），未配置时使用默认值。
    var userAgent: String? = nil
    var activityToken: Int = 0
    var onPlaybackFailed: (() -> Void)? = nil
    /// 开始出画时回调，供上层清除失败状态。
    var onPlaybackStarted: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    @StateObject private var controller = VLCPlayerController()
    private var volumeStep: Int { 10 }
    
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    
    var body: some View {
        ZStack {
            VLCDrawableView(controller: controller)
                .background(Color.black)
            #if !os(iOS)
                .onTapGesture(count: 2) {
                    onToggleFullScreen?()
                }
                .onTapGesture(count: 1) {
                    togglePlaybackWithOSD()
                }
            #endif
            
            if controller.isPreparing {
                ProgressView()
                    .tint(.white)
            }
            
            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            LivePlayerGestureLayer(
                onTogglePlayPause: { togglePlaybackWithOSD() },
                onToggleControls: { wakeUpControls() },
                onVolumeChanged: { delta in
                    let newVol = max(0, min(200, controller.volume + Int(delta * 200)))
                    controller.setVolume(newVol)
                }
            )
        }
        .overlay(alignment: .bottom) {
            liveControlsOverlay
                .opacity(showControls ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.3), value: showControls)
        }
        #endif
        .overlay {
            KeyboardShortcutCaptureView(
                onLeft: { },
                onRight: { },
                onTogglePlayPause: { togglePlaybackWithOSD() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onDecreaseSpeed: { },
                onIncreaseSpeed: { },
                onVolumeDown: {
                    controller.setVolume(controller.volume - volumeStep)
                    showOSD(icon: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                },
                onVolumeUp: {
                    controller.setVolume(controller.volume + volumeStep)
                    showOSD(icon: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onAppear {
            startPlayback()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            startPlayback()
            wakeUpControls()
        }
        .onChange(of: activityToken) { _, _ in
            wakeUpControls()
        }
        .onChange(of: controller.isPlaying) { _, isPlaying in
            if isPlaying {
                onPlaybackStarted?()
            }
        }
        .onDisappear {
            controller.stop()
            osdTimer?.invalidate()
            controlsTimer?.invalidate()
        }
    }
    
    // MARK: - iOS Live Controls Overlay
    
    #if os(iOS)
    private var liveControlsOverlay: some View {
        HStack(spacing: 20) {
            // Play/Pause button
            Button {
                wakeUpControls()
                togglePlaybackWithOSD()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 14)
        .padding(.bottom, 20)
        .padding(.horizontal, 16)
    }
    #endif
    
    // MARK: - Controls Timer
    
    private func wakeUpControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
    }
    
    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }
    
    private func togglePlaybackWithOSD() {
        controller.togglePlayback()
        showOSD(icon: controller.isPlaying ? "pause.fill" : "play.fill")
    }
    
    private func startPlayback() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap({ URL(string: $0) }) else {
            onPlaybackFailed?()
            return
        }
        controller.play(
            url: url,
            startPosition: 0,
            isLive: true,
            userAgent: userAgent,
            onProgressChanged: nil,
            onPlaybackEnded: nil,
            onPlaybackFailed: onPlaybackFailed
        )
    }
}

private struct VLCDrawableView: View {
    let controller: VLCPlayerController
    
    var body: some View {
        #if os(macOS)
        VLCMacDrawableView(controller: controller)
        #else
        VLCIOSDrawableView(controller: controller)
        #endif
    }
}

private struct KeyboardShortcutCaptureView: View {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onDecreaseSpeed: () -> Void
    let onIncreaseSpeed: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    var body: some View {
        #if os(macOS)
        MacKeyboardCaptureView(
            onLeft: onLeft,
            onRight: onRight,
            onTogglePlayPause: onTogglePlayPause,
            onToggleFullScreen: onToggleFullScreen,
            onDecreaseSpeed: onDecreaseSpeed,
            onIncreaseSpeed: onIncreaseSpeed,
            onVolumeDown: onVolumeDown,
            onVolumeUp: onVolumeUp
        )
        #else
        IOSKeyboardCaptureView(
            onLeft: onLeft,
            onRight: onRight,
            onTogglePlayPause: onTogglePlayPause,
            onToggleFullScreen: onToggleFullScreen,
            onDecreaseSpeed: onDecreaseSpeed,
            onIncreaseSpeed: onIncreaseSpeed,
            onVolumeDown: onVolumeDown,
            onVolumeUp: onVolumeUp
        )
        #endif
    }
}

#if os(macOS)
private struct VLCMacDrawableView: NSViewRepresentable {
    let controller: VLCPlayerController
    
    final class Coordinator {
        let controller: VLCPlayerController
        
        init(controller: VLCPlayerController) {
            self.controller = controller
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }
    
    func makeNSView(context: Context) -> VLCOutputNSView {
        let view = VLCOutputNSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.onLifecycle = { container in
            context.coordinator.controller.attachDrawable(to: container)
        }
        view.requestLifecycleUpdate()
        return view
    }
    
    func updateNSView(_ nsView: VLCOutputNSView, context: Context) {
        nsView.onLifecycle = { container in
            context.coordinator.controller.attachDrawable(to: container)
        }
        nsView.requestLifecycleUpdate()
    }
    
    static func dismantleNSView(_ nsView: VLCOutputNSView, coordinator: Coordinator) {
        nsView.onLifecycle = nil
        coordinator.controller.detachDrawable(from: nsView)
    }
}

private final class VLCOutputNSView: NSView {
    var onLifecycle: ((NSView) -> Void)?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestLifecycleUpdate()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        requestLifecycleUpdate()
    }
    
    override func layout() {
        super.layout()
        requestLifecycleUpdate()
    }
    
    func requestLifecycleUpdate() {
        onLifecycle?(self)
    }
}

private struct MacKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onDecreaseSpeed: () -> Void
    let onIncreaseSpeed: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeNSView(context: Context) -> MacKeyCaptureNSView {
        let view = MacKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateNSView(_ nsView: MacKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }
    
    private func applyCallbacks(to view: MacKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onDecreaseSpeed = onDecreaseSpeed
        view.onIncreaseSpeed = onIncreaseSpeed
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class MacKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onDecreaseSpeed: (() -> Void)?
    var onIncreaseSpeed: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate()
    }
    
    func activate() {
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 123: // left
            onLeft?()
            return
        case 124: // right
            onRight?()
            return
        case 125: // down
            onVolumeDown?()
            return
        case 126: // up
            onVolumeUp?()
            return
        case 49: // space
            onTogglePlayPause?()
            return
        default:
            break
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k":
            onTogglePlayPause?()
        case "f":
            onToggleFullScreen?()
        case "[":
            onDecreaseSpeed?()
        case "]":
            onIncreaseSpeed?()
        default:
            super.keyDown(with: event)
        }
    }
}
#else
private struct VLCIOSDrawableView: UIViewRepresentable {
    let controller: VLCPlayerController
    
    final class Coordinator {
        let controller: VLCPlayerController
        
        init(controller: VLCPlayerController) {
            self.controller = controller
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }
    
    func makeUIView(context: Context) -> VLCOutputUIView {
        let view = VLCOutputUIView(frame: .zero)
        view.backgroundColor = .black
        view.onLifecycle = { container in
            context.coordinator.controller.attachDrawable(to: container)
        }
        view.requestLifecycleUpdate()
        return view
    }
    
    func updateUIView(_ uiView: VLCOutputUIView, context: Context) {
        uiView.onLifecycle = { container in
            context.coordinator.controller.attachDrawable(to: container)
        }
        uiView.requestLifecycleUpdate()
    }
    
    static func dismantleUIView(_ uiView: VLCOutputUIView, coordinator: Coordinator) {
        uiView.onLifecycle = nil
        coordinator.controller.detachDrawable(from: uiView)
    }
}

private final class VLCOutputUIView: UIView {
    var onLifecycle: ((UIView) -> Void)?
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestLifecycleUpdate()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        requestLifecycleUpdate()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        requestLifecycleUpdate()
    }
    
    func requestLifecycleUpdate() {
        onLifecycle?(self)
    }
}

private struct IOSKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onDecreaseSpeed: () -> Void
    let onIncreaseSpeed: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeUIView(context: Context) -> IOSKeyCaptureView {
        let view = IOSKeyCaptureView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateUIView(_ uiView: IOSKeyCaptureView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }
    
    private func applyCallbacks(to view: IOSKeyCaptureView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onDecreaseSpeed = onDecreaseSpeed
        view.onIncreaseSpeed = onIncreaseSpeed
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class IOSKeyCaptureView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onDecreaseSpeed: (() -> Void)?
    var onIncreaseSpeed: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var canBecomeFirstResponder: Bool { true }
    
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleVolumeDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleVolumeUp)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "k", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen)),
            UIKeyCommand(input: "[", modifierFlags: [], action: #selector(handleDecreaseSpeed)),
            UIKeyCommand(input: "]", modifierFlags: [], action: #selector(handleIncreaseSpeed))
        ]
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }
    
    func activate() {
        becomeFirstResponder()
    }
    
    @objc private func handleLeft() {
        onLeft?()
    }
    
    @objc private func handleRight() {
        onRight?()
    }
    
    @objc private func handleTogglePlayPause() {
        onTogglePlayPause?()
    }
    
    @objc private func handleToggleFullScreen() {
        onToggleFullScreen?()
    }
    
    @objc private func handleDecreaseSpeed() {
        onDecreaseSpeed?()
    }
    
    @objc private func handleIncreaseSpeed() {
        onIncreaseSpeed?()
    }

    @objc private func handleVolumeDown() {
        onVolumeDown?()
    }

    @objc private func handleVolumeUp() {
        onVolumeUp?()
    }
}
#endif

#else

final class VLCPlayerController: ObservableObject {
    func stop() {}
}

struct VLCVodPlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var qualityConstraint: PlaybackQualityConstraint? = nil
    /// 播放请求需要携带的 HTTP 头（未集成 VLCKit 时原样交给系统播放器）。
    var httpHeaders: [String: String] = [:]
    var onProgressChanged: ((Double, Double?, String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: VLCPlayerController? = nil
    
    var body: some View {
        AVPlayerContentView(
            urlString: urlString,
            startPosition: startPosition,
            qualityConstraint: qualityConstraint,
            httpHeaders: httpHeaders,
            onProgressChanged: onProgressChanged,
            onPlaybackEnded: onPlaybackEnded,
            onToggleFullScreen: onToggleFullScreen,
            canPlayNext: canPlayNext,
            onPlayNext: onPlayNext
        )
    }
}

struct VLCLivePlayerView: View {
    let urlString: String
    var userAgent: String? = nil
    var activityToken: Int = 0
    var onPlaybackFailed: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    
    var body: some View {
        Color.black
    }
}

#endif
