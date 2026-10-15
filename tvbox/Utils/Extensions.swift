import SwiftUI
import ImageIO

#if os(macOS)
import AppKit
#endif

/// 配置键定义 - 对应 Android 版 HawkConfig.java
struct HawkConfig {
    static let API_URL = "api_url"
    static let HOME_API = "home_api"
    static let HOME_REC = "home_rec"
    static let PLAY_TYPE = "play_type"
    static let PLAY_TYPE_VOD = "play_type_vod"
    static let PLAY_TYPE_LIVE = "play_type_live"
    static let DOH_URL = "doh_url"
    static let SEARCH_VIEW = "search_view"
    static let LIVE_API_URL = "live_api_url"
    static let PARSE_WEBVIEW = "parse_webview"
    static let IJK_CODEC = "ijk_codec"
    static let RENDER_TYPE = "render_type"
    static let PLAY_SCALE = "play_scale"
    static let PLAY_SPEED = "play_speed"
    static let PLAY_VOLUME = "play_volume"
    static let PLAY_DECODE_MODE = "play_decode_mode"
    static let PLAY_VLC_BUFFER_MODE = "play_vlc_buffer_mode"
    static let PLAY_TIME_STEP = "play_time_step"
    static let HOME_REC_STYLE = "home_rec_style"
    static let HISTORY_NUM = "history_num"
    static let SEARCH_HISTORY = "search_history"
}

/// 通用 Swift 扩展
extension String {
    /// 移除 HTML 标签
    var stripHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 是否为有效 URL
    var isValidURL: Bool {
        guard let url = URL(string: self) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}

extension Bundle {
    /// 实际构建产物的版本号（如 “1.0.3 (1)”），设置页与个人中心统一使用。
    var appVersionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        guard let build = infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }
}

extension Date {
    /// 格式化日期显示
    var displayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: self)
    }
    
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }
    
    /// 首页日期显示
    var homeDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd EEEE HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: self)
    }
}

extension Int {
    /// 播放时长格式化
    var durationString: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension Double {
    /// 播放时长格式化
    var durationString: String {
        Int(self).durationString
    }
}

// MARK: - Design System (Merged from DesignSystem.swift)

struct AppTheme {
    static let primaryGradient = LinearGradient(
        colors: [
            Color(hex: "1a1a2e"),
            Color(hex: "16213e"),
            Color(hex: "0f3460")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let accentGradient = LinearGradient(
        colors: [.orange, .red],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    static let glassBackgroud = Color.white.opacity(0.1)
    static let cardRadius: CGFloat = 16
    static let glassRadius: CGFloat = 20
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// 玻璃拟态基础组件
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.glassRadius
    
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background(.ultraThinMaterial)
            #else
            .background(VisualEffectView().opacity(0.85))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

#if os(macOS)
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

extension View {
    func glassCard(cornerRadius: CGFloat = AppTheme.glassRadius) -> some View {
        self.modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Image URL

extension URL {
    /// 统一解析海报 URL，处理协议缺失和已知防盗链域名
    static func posterURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        var absolute = trimmed
        if absolute.hasPrefix("//") {
            absolute = "https:\(absolute)"
        }
        
        guard let originalURL = URL(string: absolute),
              let host = originalURL.host?.lowercased() else {
            return nil
        }
        
        // 部分源图片域名有防盗链，直接访问会 403，走代理兜底
        if host == "img.picbf.com" {
            var components = URLComponents(string: "https://images.weserv.nl/")
            components?.queryItems = [URLQueryItem(name: "url", value: absolute)]
            return components?.url
        }
        
        return originalURL
    }
}

// MARK: - Cached Async Image

/// 自定义异步图片加载组件
/// AsyncImage 不支持自定义 header，许多图片服务器需要 Referer/User-Agent 才能正常返回图片
/// 此组件通过自定义 URLSession 发起请求，解决海报永远加载不出来的问题
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    
    @State private var loadedImage: PlatformImage?
    @State private var loadFailed = false
    
    private static var delayedRetryDelay: TimeInterval { 3.0 }
    
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let image = loadedImage {
                #if os(macOS)
                content(Image(nsImage: image))
                #else
                content(Image(uiImage: image))
                #endif
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            loadedImage = nil
            loadFailed = false
        }
    }
    
    private func loadImage() async {
        guard let url = url else {
            loadedImage = nil
            return
        }
        
        if let cached = ImageCache.shared.get(for: url) {
            loadedImage = cached
            return
        }
        
        do {
            let image = try await ImageLoader.shared.load(url: url)
            guard !Task.isCancelled else { return }
            ImageCache.shared.set(image, for: url)
            loadedImage = image
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadedImage = nil
            
            if error.isNetworkConnectionError && !loadFailed {
                loadFailed = true
                try? await Task.sleep(nanoseconds: UInt64(Self.delayedRetryDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await loadImage()
            }
        }
    }
}

// MARK: - Platform Image Type
#if os(macOS)
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// MARK: - Image Loader

/// 使用自定义 URLSession 加载图片，支持自定义请求头
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    
    private let session: URLSession
    private let urlCache: URLCache
    private let thumbnailMaxPixelSize: CGFloat = 420
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 6
        let cache = URLCache(
            memoryCapacity: 12 * 1024 * 1024,
            diskCapacity: 120 * 1024 * 1024,
            diskPath: "image_cache"
        )
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        self.urlCache = cache
        self.session = URLSession(configuration: config)
    }
    
    private static let maxImageRetries = 1
    private static let imageRetryDelay: TimeInterval = 1.0
    
    func load(url: URL) async throws -> PlatformImage {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let host = url.host {
            request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        
        var lastError: Error = ImageLoadError.invalidData
        let totalAttempts = Self.maxImageRetries + 1
        
        for attempt in 0..<totalAttempts {
            do {
                try Task.checkCancellation()
                
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    let error = ImageLoadError.httpError(httpResponse.statusCode)
                    if Self.isRetryableImageError(error, statusCode: httpResponse.statusCode),
                       attempt < totalAttempts - 1 {
                        lastError = error
                        try await Task.sleep(nanoseconds: UInt64(Self.imageRetryDelay * 1_000_000_000))
                        continue
                    }
                    throw error
                }
                
                let maxPixelSize = thumbnailMaxPixelSize
                guard let image = Self.decodeImage(data: data, maxPixelSize: maxPixelSize) else {
                    throw ImageLoadError.invalidData
                }
                
                return image
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if error.isNetworkConnectionError && attempt < totalAttempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(Self.imageRetryDelay * 1_000_000_000))
                    continue
                }
                if attempt >= totalAttempts - 1 { throw error }
            }
        }
        
        throw lastError
    }
    
    private static func isRetryableImageError(_ error: Error, statusCode: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(statusCode)
    }
    
    var cacheUsage: (memory: Int, disk: Int) {
        (urlCache.currentMemoryUsage, urlCache.currentDiskUsage)
    }
    
    func clearCache() {
        urlCache.removeAllCachedResponses()
    }
    
    private static func decodeImage(data: Data, maxPixelSize: CGFloat) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up))),
            kCGImageSourceShouldCacheImmediately: true
        ]
        
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            #if os(macOS)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #else
            return UIImage(cgImage: cgImage)
            #endif
        }
        
        return PlatformImage(data: data)
    }
}

enum ImageLoadError: Error {
    case httpError(Int)
    case invalidData
}

// MARK: - Image Memory Cache

/// 简单的内存缓存，避免重复下载
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    
    private let cache = NSCache<NSURL, PlatformImage>()
    
    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 40 * 1024 * 1024
    }
    
    func get(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }
    
    func set(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: image.memoryCost)
    }
    
    func clear() {
        cache.removeAllObjects()
    }
}

#if os(macOS)
extension NSImage {
    var memoryCost: Int {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
#else
extension UIImage {
    var memoryCost: Int {
        if let cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        return max(1, Int(pixelWidth * pixelHeight * 4))
    }
}
#endif

// MARK: - Selection Modal

/// 通用选择对话框 - 重新设计的玻璃拟态样式
struct SelectionModal<Item: Identifiable & Equatable>: View {
    let title: String
    let icon: String // SF Symbol 名称
    let items: [Item]
    let selectedItem: Item?
    let itemTitle: (Item) -> String
    let onSelect: (Item) -> Void
    let onCancel: () -> Void
    
    // 动画状态
    @State private var animateIn = false
    @State private var hoverItemId: Item.ID? = nil
    
    var body: some View {
        ZStack {
            // 背景遮罩
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        animateIn = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onCancel()
                    }
                }
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部图标 & 标题
                VStack(spacing: 16) {
                    ZStack {
                        // 动态光晕背景
                        Circle()
                            .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 56, height: 56)
                            .blur(radius: 20)
                            .opacity(0.4)
                        
                        // 主图标
                        Image(systemName: icon)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18)
                                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                    )
                            )
                            .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
                    }
                    .padding(.top, 28)
                    
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 24)
                
                // 选项列表
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            Button {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    onSelect(item)
                                }
                            } label: {
                                HStack(spacing: 16) {
                                    Text(itemTitle(item))
                                        .font(.system(size: 15, weight: item == selectedItem ? .semibold : .medium))
                                        .foregroundColor(item == selectedItem ? .white : .white.opacity(0.7))
                                    
                                    Spacer()
                                    
                                    if item == selectedItem {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.orange)
                                            .font(.system(size: 18))
                                            .shadow(color: Color.orange.opacity(0.4), radius: 4)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1.5)
                                            .frame(width: 18, height: 18)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(selectionBackground(item: item))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(selectionStroke(item: item), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    hoverItemId = isHovering ? item.id : nil
                                }
                            }
                            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hoverItemId)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 320)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.horizontal, 24)
                
                // 取消按钮
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        animateIn = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onCancel()
                    }
                } label: {
                    Text("取消")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .frame(width: 300)
            .glassCard(cornerRadius: 28)
            .scaleEffect(animateIn ? 1 : 0.9)
            .opacity(animateIn ? 1 : 0)
            .shadow(color: Color.black.opacity(0.5), radius: 40, x: 0, y: 20)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                animateIn = true
            }
        }
    }
    
    private func selectionBackground(item: Item) -> Color {
        if item == selectedItem {
            return Color.orange.opacity(0.2)
        } else if item.id == hoverItemId {
            return Color.white.opacity(0.1)
        } else {
            return Color.white.opacity(0.04)
        }
    }
    
    private func selectionStroke(item: Item) -> Color {
        if item == selectedItem {
            return Color.orange.opacity(0.6)
        } else if item.id == hoverItemId {
            return Color.white.opacity(0.2)
        } else {
            return Color.clear
        }
    }
}

// 模拟扩展
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
