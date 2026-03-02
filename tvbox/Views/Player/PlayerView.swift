import SwiftUI
import AVKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 跨平台播放器：macOS 使用 AVPlayerView，避免 SwiftUI.VideoPlayer 在 macOS 的崩溃问题
struct PlatformVideoPlayer: View {
    let player: AVPlayer
    
    var body: some View {
        #if os(macOS)
        MacOSPlayerView(player: player)
        #else
        VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
private struct MacOSPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none // 禁用系统默认控制栏
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
#endif

/// 系统播放器会话控制器：用于在页面内联与全屏视图间复用同一 AVPlayer，避免重复拉流
@MainActor
final class SystemPlayerSessionController: ObservableObject {
    fileprivate var player: AVPlayer?
    fileprivate var mediaURLString: String?
    
    func setPlayer(_ newPlayer: AVPlayer, urlString: String) {
        if player !== newPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
        player = newPlayer
        mediaURLString = urlString
    }
    
    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        mediaURLString = nil
    }
}

/// 视频播放器组件 - 对应 Android 版 PlayFragment
struct PlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) != nil {
            rawValue = vodPlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }
    
    var body: some View {
        Group {
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: vlcController
                )
            }
        }
        .id(selectedEngine.rawValue)
        .onAppear {
            if selectedEngine != .system {
                systemController?.stop()
            }
            if selectedEngine != .vlc {
                vlcController?.stop()
            }
        }
        .onChange(of: selectedEngine) { _, newValue in
            if newValue != .system {
                systemController?.stop()
            }
            if newValue != .vlc {
                vlcController?.stop()
            }
        }
    }
}

/// 基于系统 AVPlayer 的点播播放器实现
struct AVPlayerContentView: View {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: SystemPlayerSessionController? = nil
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?
    
    // UI 状态
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 1.0
    @State private var rate: Float = 1.0
    @State private var isPreparing = true
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var playerObservers: [NSKeyValueObservation] = []
    
    var body: some View {
        ZStack {
            Group {
                if let player = player {
                    PlatformVideoPlayer(player: player)
                } else {
                    ZStack {
                        Color.black
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .onTapGesture(count: 2) {
                onToggleFullScreen?()
            }
            .onTapGesture(count: 1) {
                togglePlayPauseWithOSD()
            }

            if isPreparing {
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
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                if player != nil {
                    playbackControls(containerWidth: proxy.size.width)
                        .opacity(showControls ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.3), value: showControls)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay {
            SystemPlayerKeyboardCaptureView(
                onLeft: { seek(by: -seekStep) },
                onRight: { seek(by: seekStep) },
                onTogglePlayPause: { togglePlayPause() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onVolumeDown: { wakeUpControls(); adjustVolume(by: -volumeStep) },
                onVolumeUp: { wakeUpControls(); adjustVolume(by: volumeStep) }
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
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }
    
    private func setupPlayer() {
        guard let url = URL(string: urlString) else { return }
        let targetURLString = url.absoluteString
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        
        if let sharedController,
           sharedController.mediaURLString == targetURLString,
           let sharedPlayer = sharedController.player {
            cleanupPlayer(keepSharedPlayer: true)
            player = sharedPlayer
            applyPreferredPlaybackRate(to: sharedPlayer)
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }
        
        // 清理旧播放器
        cleanupPlayer()
        
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetURLString)
        }
        
        player = newPlayer
        bindPlayerObservers(for: newPlayer)
        startPlayback(for: newPlayer)
    }
    
    private func bindPlayerObservers(for player: AVPlayer) {
        playerObservers = [
            player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                let status = p.timeControlStatus
                DispatchQueue.main.async { isPlaying = status == .playing }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { p, _ in
                let reason = p.reasonForWaitingToPlay
                DispatchQueue.main.async { isPreparing = reason != nil }
            },
            player.observe(\.volume, options: [.new]) { p, _ in
                let vol = Double(p.volume)
                DispatchQueue.main.async { volume = vol }
            },
            player.observe(\.rate, options: [.new]) { p, _ in
                let currentRate = p.rate
                guard currentRate > 0 else { return }
                let normalized = Self.normalizedPlaybackRate(from: currentRate)
                DispatchQueue.main.async {
                    rate = normalized
                    if abs(savedPlaybackRate - Double(normalized)) > 0.001 {
                        savedPlaybackRate = Double(normalized)
                    }
                }
            }
        ]
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        isPlaying = player.timeControlStatus == .playing
        isPreparing = player.reasonForWaitingToPlay != nil
        volume = Double(player.volume)
        rate = normalizedSavedPlaybackRate
    }
    
    private func detachPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }
    
    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
        
        guard let currentPlayer else { return }
        if keepSharedPlayer, sharedController?.player === currentPlayer {
            player = nil
            return
        }
        
        currentPlayer.pause()
        currentPlayer.replaceCurrentItem(with: nil)
        if sharedController?.player === currentPlayer {
            sharedController?.player = nil
            sharedController?.mediaURLString = nil
        }
        player = nil
    }
    
    private func startPlayback(for player: AVPlayer) {
        let target = max(startPosition, 0)
        
        if target > 0 {
            let seekTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                reportProgress(for: player)
                playAtPreferredRate(player)
            }
        } else {
            playAtPreferredRate(player)
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            playAtPreferredRate(player)
        } else {
            player.pause()
        }
    }
    
    private func togglePlayPauseWithOSD() {
        togglePlayPause()
        showOSD(icon: isPlaying ? "pause.fill" : "play.fill")
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
    
    private func observePlaybackEnd(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onPlaybackEnded?()
        }
    }
    
    private func observePlaybackProgress(for player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            reportProgress(for: player)
        }
    }
    
    private func reportProgress(for player: AVPlayer?) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite, current >= 0 else { return }
        
        if !isDraggingProgress {
            self.currentTime = current
            self.draggingSeconds = current
        }
        
        let rawDuration = player.currentItem?.duration.seconds
        if let rawDuration, rawDuration.isFinite, rawDuration >= 0 {
            self.duration = rawDuration
        }
        onProgressChanged?(current, duration > 0 ? duration : nil)
    }
    
    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Double { 0.1 }
    
    private var progressUpperBound: Double {
        max(duration, max(currentTime, 1))
    }

    private func playbackControls(containerWidth: CGFloat) -> some View {
        VStack(spacing: 8) {
            // 第一行：进度条和时间
            HStack(spacing: 12) {
                Text(currentTime.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
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
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            
            // 第二行：控制按钮
            HStack(spacing: 0) {
                // 左侧区：倍速
                HStack(spacing: 16) {
                    playbackRateMenu
                }
                .frame(width: 150, alignment: .leading)
                
                Spacer()
                
                // 中间区：主控 (这里集成了您原本右下角的快进快退和下一集按钮)
                HStack(spacing: 24) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 38, height: 38)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
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
                
                // 右侧区：音量和全屏
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            let newVolume = volume > 0 ? 0.0 : 1.0
                            player?.volume = Float(newVolume)
                            showOSD(icon: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            in: 0...1.0
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
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .glassCard(cornerRadius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(width: containerWidth * 0.7)
        .environment(\.colorScheme, .dark)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.supportedPlaybackRates, id: \.self) { r in
                Button {
                    wakeUpControls()
                    setPlaybackRate(r)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text("\(String(format: "%.1f", r))x")
                        if r == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", rate))x")
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

    private var volumeIconName: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var normalizedSavedPlaybackRate: Float {
        Self.normalizedPlaybackRate(from: Float(savedPlaybackRate))
    }

    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private func syncRateFromSettings() {
        rate = normalizedSavedPlaybackRate
    }

    private func setPlaybackRate(_ value: Float) {
        let normalized = Self.normalizedPlaybackRate(from: value)
        rate = normalized
        savedPlaybackRate = Double(normalized)
        guard let player else { return }
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func applyPreferredPlaybackRate(to player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func seek(by offset: Double) {
        guard let player else { return }
        
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let wasPlaying = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        
        var target = max(current + offset, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }
        
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            reportProgress(for: player)
            if wasPlaying {
                playAtPreferredRate(player)
            }
        }
    }

    private func adjustVolume(by delta: Double) {
        guard let player else { return }
        let current = Double(player.volume)
        let target = min(max(current + delta, 0), 1)
        player.volume = Float(target)
        showOSD(icon: target <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
}

#if os(macOS)
private struct SystemPlayerKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeNSView(context: Context) -> SystemPlayerKeyCaptureNSView {
        let view = SystemPlayerKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateNSView(_ nsView: SystemPlayerKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
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
        default: break
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k": onTogglePlayPause?()
        case "f": onToggleFullScreen?()
        default: super.keyDown(with: event)
        }
    }
}
#else
private struct SystemPlayerKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeUIView(context: Context) -> SystemPlayerKeyCaptureUIView {
        let view = SystemPlayerKeyCaptureUIView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateUIView(_ uiView: SystemPlayerKeyCaptureUIView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureUIView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureUIView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
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
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen))
        ]
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }
    
    func activate() {
        becomeFirstResponder()
    }
    
    @objc private func handleLeft() { onLeft?() }
    @objc private func handleRight() { onRight?() }
    @objc private func handleVolumeDown() { onVolumeDown?() }
    @objc private func handleVolumeUp() { onVolumeUp?() }
    @objc private func handleTogglePlayPause() { onTogglePlayPause?() }
    @objc private func handleToggleFullScreen() { onToggleFullScreen?() }
}
#endif
