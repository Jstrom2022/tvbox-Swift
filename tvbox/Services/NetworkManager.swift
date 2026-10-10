import Foundation

/// 网络请求封装 - 对应 Android 版 OkGo
class NetworkManager {
    /// 全局共享实例。
    static let shared = NetworkManager()
    
    /// 默认最大重试次数（不含首次请求）。
    static let defaultMaxRetries = 2
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
    func getString(
        from urlString: String,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> String {
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
        
        return str
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
        maxRetries: Int
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
                    let error = NetworkError.httpError(httpResponse.statusCode)
                    if Self.isRetryableHTTPStatus(httpResponse.statusCode) && attempt < totalAttempts - 1 {
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
                if Self.isRetryableError(error) && attempt < totalAttempts - 1 {
                    try await retryDelay(attempt: attempt)
                    continue
                }
                throw error
            }
        }
        
        throw lastError
    }
    
    /// 指数退避延迟 + 随机抖动，避免多请求同时重试造成惊群效应。
    private func retryDelay(attempt: Int) async throws {
        let base = Self.retryBaseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        let delay = min(base + jitter, Self.retryMaxDelay)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    
    /// 判断 HTTP 状态码是否值得重试（仅服务端临时错误）。
    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }
    
    /// 判断错误是否为可重试的瞬态网络错误。
    private static func isRetryableError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        
        if let networkError = error as? NetworkError {
            if case .httpError(let code) = networkError {
                return isRetryableHTTPStatus(code)
            }
            if case .invalidURL = networkError { return false }
            if case .decodingError = networkError { return false }
        }
        
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorDataNotAllowed:
                return true
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
    case httpError(Int)
    case decodingError(String)
    
    /// 面向 UI/日志的错误描述。
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的URL: \(url)"
        case .invalidResponse: return "无效的响应"
        case .httpError(let code): return "HTTP 错误: \(code)"
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
