//
//  ProxyURLCodec.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// 本地代理 URL 编解码器。
public struct ProxyURLCodec: Sendable {
    /// 本地代理端口。
    public let port: UInt16

    private let placeholderToken = "HTTPMediaCachePlaceHolder"
    private let lastPathComponentToken = "HTTPMediaCacheLastPathComponent"

    /// 创建代理 URL 编解码器。
    public init(port: UInt16) {
        self.port = port
    }

    /// 将原始 URL 编码为本地代理 URL。
    public func proxyURL(for originalURL: URL, bindToLocalhost: Bool) throws -> URL {
        try proxyURL(for: originalURL, bindToLocalhost: bindToLocalhost, hlsResourceKind: nil, byteRange: nil)
    }

    func proxyURL(
        for originalURL: URL,
        bindToLocalhost: Bool,
        hlsResourceKind: HLSDownloadResourceKind?,
        byteRange: ByteRange?
    ) throws -> URL {
        guard !originalURL.isFileURL, !originalURL.absoluteString.isEmpty else {
            return originalURL
        }

        let host = bindToLocalhost ? "localhost" : Self.primaryIPAddress()
        let pathExtension = originalURL.pathExtension.isEmpty ? "" : ".\(originalURL.pathExtension)"
        let query = Self.hlsQueryString(kind: hlsResourceKind, byteRange: byteRange)
        let urlString = "http://\(host):\(port)/\(Self.encode(originalURL.absoluteString))/\(placeholderToken)/\(lastPathComponentToken)\(pathExtension)\(query)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        return url
    }

    /// 判断 URL 是否为本编解码器生成的代理 URL。
    public func isProxyURL(_ url: URL) -> Bool {
        url.absoluteString.contains(placeholderToken) && url.absoluteString.contains(lastPathComponentToken)
    }

    /// 从代理 URL 还原原始 URL。
    public func originalURL(from proxyURL: URL) -> URL? {
        guard isProxyURL(proxyURL) else {
            return proxyURL
        }

        let components = proxyURL.absoluteString.components(separatedBy: "/")
        guard components.count >= 4,
              let value = Self.decode(components[3]),
              value.hasPrefix("http"),
              let originalURL = URL(string: value)
        else {
            return proxyURL
        }
        return originalURL
    }

    private static func primaryIPAddress() -> String {
        #if canImport(Darwin)
            var address = "localhost"
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaces) == 0, let interfaces else {
                return address
            }
            defer {
                freeifaddrs(interfaces)
            }

            var pointer: UnsafeMutablePointer<ifaddrs>? = interfaces
            while let current = pointer {
                defer {
                    pointer = current.pointee.ifa_next
                }

                guard String(cString: current.pointee.ifa_name) == "en0",
                      current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                      current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
                else {
                    continue
                }

                var socketAddress = current.pointee.ifa_addr.pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                withUnsafePointer(to: &socketAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addressPointer in
                        var address = addressPointer.pointee.sin_addr
                        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
                    }
                }
                address = String(cString: buffer)
                break
            }
            return address
        #else
            return "localhost"
        #endif
    }

    static func encode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func decode(_ string: String) -> String? {
        string.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    static func hlsResourceKind(from uri: String) -> HLSDownloadResourceKind? {
        queryItems(from: uri).first { $0.name == hlsResourceKindQueryKey }
            .flatMap { $0.value }
            .flatMap(HLSDownloadResourceKind.init(rawValue:))
    }

    static func hlsByteRange(from uri: String) -> ByteRange? {
        let items = queryItems(from: uri)
        guard let startText = items.first(where: { $0.name == hlsByteRangeStartQueryKey })?.value,
              let start = Int64(startText)
        else {
            return nil
        }
        let end = items.first(where: { $0.name == hlsByteRangeEndQueryKey })?.value.flatMap(Int64.init)
        return ByteRange(start: start, end: end)
    }

    private static var hlsResourceKindQueryKey: String {
        "HTTPMediaCacheHLSResourceKind"
    }

    private static var hlsByteRangeStartQueryKey: String {
        "HTTPMediaCacheHLSByteRangeStart"
    }

    private static var hlsByteRangeEndQueryKey: String {
        "HTTPMediaCacheHLSByteRangeEnd"
    }

    private static func hlsQueryString(kind: HLSDownloadResourceKind?, byteRange: ByteRange?) -> String {
        var items: [URLQueryItem] = []
        if let kind {
            items.append(URLQueryItem(name: hlsResourceKindQueryKey, value: kind.rawValue))
        }
        if let byteRange {
            items.append(URLQueryItem(name: hlsByteRangeStartQueryKey, value: "\(byteRange.start)"))
            if let end = byteRange.end {
                items.append(URLQueryItem(name: hlsByteRangeEndQueryKey, value: "\(end)"))
            }
        }
        guard !items.isEmpty else {
            return ""
        }
        var components = URLComponents()
        components.queryItems = items
        return components.string ?? ""
    }

    private static func queryItems(from uri: String) -> [URLQueryItem] {
        if let components = URLComponents(string: uri), let items = components.queryItems {
            return items
        }
        return URLComponents(string: "http://localhost\(uri)")?.queryItems ?? []
    }
}
