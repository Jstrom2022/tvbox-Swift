import Foundation

/// 播放器引擎类型
enum PlayerEngine: Int, CaseIterable, Identifiable {
    /// 系统 AVPlayer 内核。
    case system = 0
    /// VLC 内核（需编译时可导入 VLCKitSPM）。
    case vlc = 10
    
    var id: Int { rawValue }
    
    /// UI 展示名。
    var title: String {
        switch self {
        case .system:
            return "系统播放器"
        case .vlc:
            return "VLC播放器"
        }
    }
    
    /// 当前构建产物是否包含 VLC 能力。
    static var isVLCAvailable: Bool {
        #if canImport(VLCKitSPM)
        return true
        #else
        return false
        #endif
    }
    
    /// 实际可供用户选择的播放器列表。
    /// 当 VLC 不可用时，仅暴露系统播放器，避免无效配置。
    static var availableEngines: [PlayerEngine] {
        var engines: [PlayerEngine] = [.system]
        if isVLCAvailable {
            engines.append(.vlc)
        }
        return engines
    }
    
    /// 从持久化值恢复播放器选项，并自动兜底到可用引擎。
    static func fromStoredValue(_ rawValue: Int) -> PlayerEngine {
        guard let engine = PlayerEngine(rawValue: rawValue) else {
            return .system
        }
        
        if engine == .vlc && !isVLCAvailable {
            return .system
        }
        
        return engine
    }
}

/// 视频解码模式
enum VideoDecodeMode: Int, CaseIterable, Identifiable {
    /// 自动策略，优先硬解，失败时用户可切换。
    case auto = 0
    /// 强制硬解。
    case hardware = 1
    /// 强制软解。
    case software = 2
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .hardware:
            return "硬解码"
        case .software:
            return "软解码"
        }
    }
    
    static func fromStoredValue(_ rawValue: Int) -> VideoDecodeMode {
        VideoDecodeMode(rawValue: rawValue) ?? .auto
    }
    
    /// VLC 媒体选项
    /// 返回 `avcodec-hw` 对应的值。
    var vlcHardwareDecodeOption: String? {
        switch self {
        case .auto:
            // 自动模式默认硬解优先，异常时用户仍可手动切到软解。
            return "any"
        case .hardware:
            return "any"
        case .software:
            return "none"
        }
    }
}

/// VLC 缓冲策略
enum VLCBufferMode: Int, CaseIterable, Identifiable {
    /// 低延迟优先，适合直播但容错较低。
    case lowLatency = 0
    /// 兼顾延迟与稳定性，作为默认策略。
    case balanced = 1
    /// 稳定流畅优先，允许更高缓冲。
    case smooth = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lowLatency:
            return "低延迟"
        case .balanced:
            return "均衡"
        case .smooth:
            return "流畅优先"
        }
    }

    static var defaultMode: VLCBufferMode { .balanced }

    static func fromStoredValue(_ rawValue: Int) -> VLCBufferMode {
        VLCBufferMode(rawValue: rawValue) ?? defaultMode
    }

    /// 读取用户保存的缓冲策略，设置页与播放器统一走这里。
    /// 从未保存过时返回默认值：`integer(forKey:)` 对缺失键返回 0，会被误判为“低延迟”。
    static func stored(in defaults: UserDefaults = .standard) -> VLCBufferMode {
        guard defaults.object(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE) != nil else {
            return defaultMode
        }
        return fromStoredValue(defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE))
    }

    var enableFrameDrop: Bool {
        self == .lowLatency
    }

    /// 根据直播/点播场景输出三类缓存值（单位毫秒）。
    /// - Parameters:
    ///   - isLive: 是否直播场景
    /// - Returns: network/live/file 三类缓存配置
    func cacheConfig(isLive: Bool) -> (network: Int, live: Int, file: Int) {
        switch self {
        case .lowLatency:
            if isLive {
                return (network: 1200, live: 1200, file: 1600)
            }
            return (network: 1800, live: 1600, file: 2400)
        case .balanced:
            if isLive {
                return (network: 2600, live: 2600, file: 3200)
            }
            return (network: 6000, live: 5000, file: 6400)
        case .smooth:
            if isLive {
                return (network: 4200, live: 4200, file: 5200)
            }
            return (network: 8000, live: 6800, file: 8400)
        }
    }
}

/// 倍速文案：两个播放内核共用，保留有效小数并去掉无意义的尾零（0.75x、1.25x、1x）。
enum PlaybackRateFormatter {
    static func label(for rate: Float) -> String {
        if rate.rounded() == rate {
            return "\(Int(rate))x"
        }
        if (rate * 10).rounded() == rate * 10 {
            return "\(String(format: "%.1f", rate))x"
        }
        return "\(String(format: "%.2f", rate))x"
    }
}

/// HLS 选流约束：保留主播放列表（含外置音轨/字幕组等上下文），由播放器在主列表内按约束选择变体。
/// 用于依赖 `EXT-X-MEDIA` 外置媒体组的主列表——直接播放变体子列表会丢失这些轨道。
struct PlaybackQualityConstraint: Hashable {
    /// 目标变体声明的 BANDWIDTH（bit/s），播放器只选择不超过该码率的变体。
    let peakBitRate: Int
    /// 目标变体分辨率（RESOLUTION 属性），缺省时只按码率约束。
    let maxWidth: Int?
    let maxHeight: Int?
}
