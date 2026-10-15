#if os(iOS)
import SwiftUI

// MARK: - Gesture Mode Enum

/// 手势模式枚举 - 表示当前激活的手势类型
enum PlayerGestureMode: Equatable {
    case none
    case seeking(offset: Double)
    case adjustingBrightness(delta: CGFloat)
    case adjustingVolume(delta: CGFloat)
}

// MARK: - PlayerGestureLayer

/// 播放器手势交互层 - 覆盖在播放器上方的透明手势识别层
/// 支持水平滑动快进快退、左侧垂直滑动调节亮度、右侧垂直滑动调节音量、
/// 双击暂停/播放、捏合缩放
struct PlayerGestureLayer: View {
    // MARK: - Callbacks
    let onSeek: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleControls: () -> Void
    let onZoomChanged: (CGFloat) -> Void

    // MARK: - Properties
    let currentTime: Double
    let duration: Double
    /// 播放器当前音量（归一化到 0...1）。
    var currentVolume: Double = 1.0
    /// 提示百分比与归一化音量的换算倍数（系统内核 100，VLC 内核 200 即最高 200%）。
    var volumePercentScale: Double = 100
    /// 音量调节回调，参数为目标音量（归一化 0...1）。
    var onVolumeChanged: ((Double) -> Void)? = nil

    // MARK: - State
    @State private var gestureMode: PlayerGestureMode = .none
    @State private var zoomScale: CGFloat = 1.0
    @State private var showIndicator = false
    @State private var dragStartX: CGFloat = 0
    /// 拖动开始时的亮度/音量，后续调节都以起点为基准，避免累加完整位移。
    @State private var brightnessAtGestureStart: CGFloat = 0
    @State private var volumeAtGestureStart: Double = 0
    /// 当前提示中展示的实际亮度/音量（来自真实控制结果）。
    @State private var displayedBrightness: CGFloat = 0
    @State private var displayedVolume: Double = 0

    // MARK: - Pure Computation Functions

    /// 水平滑满一个屏幕宽度对应的快进秒数。
    private static let seekSecondsPerScreenWidth = 120.0
    /// 垂直滑动多少点对应亮度/音量的完整范围。
    private static let adjustmentDistance: CGFloat = 300.0

    /// 根据起始位置和滑动方向确定手势类型
    static func classifyGesture(
        startX: CGFloat,
        containerWidth: CGFloat,
        translation: CGSize,
        threshold: CGFloat = 10
    ) -> PlayerGestureMode {
        let absH = abs(translation.width)
        let absV = abs(translation.height)

        // 水平优先判定（快进快退）
        if absH > absV && absH > threshold {
            // 根据滑动距离动态调整快进幅度，短距离精细，长距离快速
            let normalizedOffset = translation.width / containerWidth
            let offset = Double(normalizedOffset) * seekSecondsPerScreenWidth // 滑满屏幕 = 120秒
            return .seeking(offset: offset)
        }

        // 垂直判定：左半区域 = 亮度，右半区域 = 音量
        if absV > threshold {
            let isLeftHalf = startX < containerWidth / 2
            let delta = -translation.height / adjustmentDistance // 向上为正
            if isLeftHalf {
                return .adjustingBrightness(delta: delta)
            } else {
                return .adjustingVolume(delta: delta)
            }
        }

        return .none
    }

    /// 计算快进快退目标时间（带边界钳制）
    static func computeSeekTarget(
        currentTime: Double,
        offset: Double,
        duration: Double
    ) -> Double {
        let target = currentTime + offset
        return max(0, min(target, duration))
    }

    /// 钳制调节值到 [0, 1] 范围
    static func clampAdjustment(
        currentValue: CGFloat,
        delta: CGFloat
    ) -> CGFloat {
        return max(0.0, min(1.0, currentValue + delta))
    }

    /// 钳制缩放值到 [minZoom, maxZoom] 范围
    static func clampZoom(
        scale: CGFloat,
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 3.0
    ) -> CGFloat {
        return max(minZoom, min(maxZoom, scale))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geometry))
                .gesture(pinchGesture)
                .onTapGesture(count: 2) {
                    HapticManager.shared.lightImpact()
                    onTogglePlayPause()
                }
                .onTapGesture(count: 1) {
                    onToggleControls()
                }
                .overlay { gestureIndicatorOverlay }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let isNewGesture = gestureMode == .none
                if isNewGesture {
                    dragStartX = value.startLocation.x
                }

                let classified = Self.classifyGesture(
                    startX: dragStartX,
                    containerWidth: geometry.size.width,
                    translation: value.translation
                )
                // 一次拖动只锁定一种手势，避免中途在快进与亮度/音量之间来回切换。
                let mode = isNewGesture ? classified : Self.continueGesture(gestureMode, translation: value.translation, containerWidth: geometry.size.width)
                guard mode != .none else { return }

                if isNewGesture {
                    HapticManager.shared.lightImpact()
                    brightnessAtGestureStart = UIScreen.main.brightness
                    volumeAtGestureStart = min(max(currentVolume, 0), 1)
                }

                gestureMode = mode
                applyAdjustment(for: mode)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = true
                }
            }
            .onEnded { value in
                switch gestureMode {
                case .seeking(let offset):
                    let target = Self.computeSeekTarget(
                        currentTime: currentTime,
                        offset: offset,
                        duration: duration
                    )
                    onSeek(target - currentTime)
                case .adjustingBrightness, .adjustingVolume:
                    break
                case .none:
                    break
                }

                gestureMode = .none
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    /// 已锁定手势类型后，按当前位移计算同类型手势的新值。
    static func continueGesture(
        _ mode: PlayerGestureMode,
        translation: CGSize,
        containerWidth: CGFloat
    ) -> PlayerGestureMode {
        switch mode {
        case .seeking:
            let normalizedOffset = translation.width / max(containerWidth, 1)
            return .seeking(offset: Double(normalizedOffset) * seekSecondsPerScreenWidth)
        case .adjustingBrightness:
            return .adjustingBrightness(delta: -translation.height / adjustmentDistance)
        case .adjustingVolume:
            return .adjustingVolume(delta: -translation.height / adjustmentDistance)
        case .none:
            return .none
        }
    }

    /// 把亮度/音量手势真正作用到屏幕与播放器上，提示值取实际结果。
    private func applyAdjustment(for mode: PlayerGestureMode) {
        switch mode {
        case .adjustingBrightness(let delta):
            let target = Self.clampAdjustment(currentValue: brightnessAtGestureStart, delta: delta)
            UIScreen.main.brightness = target
            displayedBrightness = target
        case .adjustingVolume(let delta):
            let target = Double(Self.clampAdjustment(currentValue: CGFloat(volumeAtGestureStart), delta: delta))
            onVolumeChanged?(target)
            displayedVolume = target
        case .seeking, .none:
            break
        }
    }

    // MARK: - Pinch Gesture

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = Self.clampZoom(scale: value.magnification * zoomScale)
                onZoomChanged(newScale)
                gestureMode = .none
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = true
                }
            }
            .onEnded { value in
                let finalScale = Self.clampZoom(scale: value.magnification * zoomScale)
                if finalScale < 1.0 {
                    zoomScale = 1.0
                } else {
                    zoomScale = finalScale
                }
                onZoomChanged(zoomScale)
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    // MARK: - Gesture Indicator Overlay

    @ViewBuilder
    private var gestureIndicatorOverlay: some View {
        if showIndicator {
            VStack(spacing: 8) {
                indicatorIcon
                indicatorText
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(showIndicator ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: showIndicator)
        }
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        switch gestureMode {
        case .seeking(let offset):
            Image(systemName: offset >= 0 ? "forward.fill" : "backward.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .adjustingBrightness:
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundColor(.yellow)
        case .adjustingVolume:
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicatorText: some View {
        switch gestureMode {
        case .seeking(let offset):
            let target = Self.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )
            Text(formatTime(target))
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingBrightness:
            Text("\(Int((displayedBrightness * 100).rounded()))%")
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingVolume:
            Text("\(Int((displayedVolume * volumePercentScale).rounded()))%")
                .font(.caption)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(max(0, seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
#endif
