import Foundation

/// 网络请求封装 - 对应 Android 版 OkGo
class NetworkManager {
    /// 全局共享实例。
    static let shared = NetworkManager()
    
    /// 默认最大重试次数（不含首次请求）。
    static let defaultMaxRetries = 2
    /// 媒体与图片请求使用的默认 User-Agent（部分 CDN 会拒绝没有浏览器 UA 的请求）。
    /// 配置中声明了 `ua` 的直播源优先使用配置值。
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 文本响应及其最终地址（跟随重定向之后），解析相对资源时必须以最终地址为基准。
    struct TextResponse {
        let text: String
        let finalURL: URL
    }

    /// 请求失败后的重试策略。
    enum RetryPolicy {
        /// 网络瞬态错误、超时与 408/429/5xx 都重试（配置、列表等廉价且幂等的请求）。
        case standard
        /// 只重试连接没有建立起来的错误（找不到主机、连不上、断网等）。
        /// 用于服务端现场执行耗时逻辑的接口（如 T4）：超时与 5xx 多是确定性失败，
        /// 重试只会成倍拉长等待，并让服务端把同一段逻辑重复执行。
        case connectionOnly
    }
    /// 服务端错误提示的最大展示长度。
    private static let maxServerMessageLength = 200
    /// 重试基础延迟（秒），实际延迟 = base * 2^attempt + jitter。
    private static let retryBaseDelay: TimeInterval = 0.5
    /// 重试最大延迟上限（秒）。
    private static let retryMaxDelay: TimeInterval = 8.0
    
    /// 兜底字符集名称列表（按常见中文资源站编码优先级排序）。
    private static let fallbackCharsetNames: [String] = [
        "utf-8",
        "gb18030",
        "gbk",
        "gb2312",
        "utf-16",
        "utf-16le",
        "utf-16be",
        "utf-32",
        "windows-1252",
        "iso-8859-1"
    ]
    
    /// 兜底字符串编码列表（与字符集列表互补）。
    private static let fallbackStringEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .utf32,
        .utf32LittleEndian,
        .utf32BigEndian,
        .windowsCP1252,
        .isoLatin1
    ]
    
    /// 内部会话对象，统一超时与连接上限配置。
    private let session: URLSession
    /// JSON 解码器。
    private let decoder = JSONDecoder()
    
    /// 私有初始化，防止外部创建多个请求管理器。
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 5
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
    
    /// GET 请求获取字符串，支持自动重试。
    /// - Parameter timeout: 单次请求超时（秒），覆盖会话默认的 15 秒；为空时使用会话默认值。
    func getString(
        from urlString: String,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries,
        timeout: TimeInterval? = nil,
        retryPolicy: RetryPolicy = .standard
    ) async throws -> String {
        try await getTextResponse(
            from: urlString,
            headers: headers,
            maxRetries: maxRetries,
            timeout: timeout,
            retryPolicy: retryPolicy
        ).text
    }

    /// GET 请求获取字符串，同时返回重定向后的最终地址。
    func getTextResponse(
        from urlString: String,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries,
        timeout: TimeInterval? = nil,
        retryPolicy: RetryPolicy = .standard
    ) async throws -> TextResponse {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 请求级超时会覆盖会话配置的 timeoutIntervalForRequest（总时长仍受 timeoutIntervalForResource 约束）。
        if let timeout {
            request.timeoutInterval = timeout
        }
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, httpResponse) = try await performRequest(request, maxRetries: maxRetries, retryPolicy: retryPolicy)

        guard let str = Self.decodeString(data: data, response: httpResponse) else {
            throw NetworkError.decodingError("文本解码失败")
        }

        return TextResponse(text: str, finalURL: httpResponse.url ?? url)
    }
    
    /// GET 请求获取字符串，同时返回跟随重定向后的最终地址
    /// （解析 m3u8 内的相对路径时必须以最终地址为基准）。
    func getStringWithFinalURL(
        from urlString: String,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> (text: String, finalURL: URL) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, httpResponse) = try await performRequest(request, maxRetries: maxRetries)
        guard let str = Self.decodeString(data: data, response: httpResponse) else {
            throw NetworkError.decodingError("文本解码失败")
        }
        return (str, httpResponse.url ?? url)
    }

    /// GET 请求解码 JSON，支持自动重试。
    func getJSON<T: Decodable>(
        from urlString: String,
        type: T.Type,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> T {
        let str = try await getString(from: urlString, headers: headers, maxRetries: maxRetries)
        guard let data = str.data(using: .utf8) else {
            throw NetworkError.decodingError("字符串转 Data 失败")
        }
        return try decoder.decode(T.self, from: data)
    }
    
    /// GET 请求获取原始 Data，支持自动重试和 HTTP 状态码校验。
    func getData(
        from urlString: String,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> Data {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }
        let request = URLRequest(url: url)
        let (data, _) = try await performRequest(request, maxRetries: maxRetries)
        return data
    }
    
    // MARK: - 带重试的核心请求方法
    
    /// 执行 HTTP 请求，遇到可重试错误时自动指数退避重试。
    private func performRequest(
        _ request: URLRequest,
        maxRetries: Int,
        retryPolicy: RetryPolicy = .standard
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = NetworkError.invalidResponse
        let totalAttempts = max(1, maxRetries + 1)
        
        for attempt in 0..<totalAttempts {
            do {
                try Task.checkCancellation()
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let error = NetworkError.httpError(
                        httpResponse.statusCode,
                        message: Self.serverMessage(from: data)
                    )
                    if Self.isRetryableHTTPStatus(httpResponse.statusCode, policy: retryPolicy) && attempt < totalAttempts - 1 {
                        lastError = error
                        try await retryDelay(attempt: attempt)
                        continue
                    }
                    throw error
                }
                
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.isRetryableError(error, policy: retryPolicy) && attempt < totalAttempts - 1 {
                    try await retryDelay(attempt: attempt)
                    continue
                }
                throw error
            }
        }
        
        throw lastError
    }
    
    /// 从错误响应体中提取服务端给出的提示（如 drpy-node 的 `{"error": "..."}`）。
    /// 只认 JSON 对象中的 error / msg / message 字符串字段，HTML 等其他内容不展示。
    static func serverMessage(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        for key in ["error", "msg", "message"] {
            guard let value = json[key] as? String else { continue }
            let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }
            return message.count > maxServerMessageLength
                ? String(message.prefix(maxServerMessageLength)) + "…"
                : message
        }
        return nil
    }
    
    /// 指数退避延迟 + 随机抖动，避免多请求同时重试造成惊群效应。
    private func retryDelay(attempt: Int) async throws {
        let base = Self.retryBaseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        let delay = min(base + jitter, Self.retryMaxDelay)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    
    /// 判断 HTTP 状态码是否值得重试（仅服务端临时错误；`connectionOnly` 策略一律不重试）。
    static func isRetryableHTTPStatus(_ statusCode: Int, policy: RetryPolicy = .standard) -> Bool {
        guard policy == .standard else { return false }
        switch statusCode {
        case 408, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }
    
    /// 判断错误是否为可重试的瞬态网络错误。
    static func isRetryableError(_ error: Error, policy: RetryPolicy = .standard) -> Bool {
        if error is CancellationError { return false }
        
        if let networkError = error as? NetworkError {
            if case .httpError(let code, _) = networkError {
                return isRetryableHTTPStatus(code, policy: policy)
            }
            if case .invalidURL = networkError { return false }
            if case .decodingError = networkError { return false }
        }
        
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorDataNotAllowed:
                return true
            case NSURLErrorTimedOut:
                // 超时说明请求已经到达服务端：耗时接口重试只会让服务端把同一段逻辑再执行一遍。
                return policy == .standard
            default:
                return false
            }
        }
        
        return false
    }
    
    /// 文本解码策略：
    /// 1) 先用响应头声明字符集；
    /// 2) 再按常见字符集与编码顺序尝试；
    /// 3) 最后用 UTF-8 宽容解码兜底。
    private static func decodeString(data: Data, response: HTTPURLResponse) -> String? {
        // 优先使用服务端声明的字符集（如 gbk / gb2312 / gb18030）
        if let charset = response.textEncodingName,
           let declaredEncoding = encoding(fromIANACharset: charset),
           let value = String(data: data, encoding: declaredEncoding) {
            return value
        }
        
        for charset in fallbackCharsetNames {
            if let encoding = encoding(fromIANACharset: charset),
               let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        for encoding in fallbackStringEncodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        // 最后兜底，避免单纯因编码不一致直接报错
        if !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        
        return nil
    }
    
    /// IANA 字符集名转 `String.Encoding`。
    private static func encoding(fromIANACharset charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}

/// 网络层错误定义。
enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    /// 非 2xx 响应；`message` 为响应体中服务端给出的错误提示（没有时为空）。
    case httpError(Int, message: String? = nil)
    case decodingError(String)
    
    /// 面向 UI/日志的错误描述。
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的URL: \(url)"
        case .invalidResponse: return "无效的响应"
        case .httpError(let code, let message):
            if let message, !message.isEmpty {
                return "HTTP 错误: \(code)，服务端提示：\(message)"
            }
            return "HTTP 错误: \(code)"
        case .decodingError(let msg): return "解码错误: \(msg)"
        }
    }
    
    /// 是否为网络不可用导致的错误（供 UI 层判断是否显示网络提示）。
    var isNetworkUnavailable: Bool {
        if case .httpError = self { return false }
        return true
    }
}

extension Error {
    /// 判断是否为网络连接类错误（超时、断网、DNS 失败等）。
    var isNetworkConnectionError: Bool {
        if self is CancellationError { return false }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
