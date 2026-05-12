//
//  ProxyRequestParser.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation
import NIOHTTP1

struct ProxyRequestContext {
    var originalURL: URL
    var request: CacheRequest
    var hlsDownloadRequest: CacheRequest
    var hlsResourceKind: HLSDownloadResourceKind?
    var isHeadRequest: Bool
    var clientRequestedRange: Bool
    var proxyPort: UInt16
}

enum ProxyRequestParser {
    static func makeContext(
        head: HTTPRequestHead,
        originalURL: URL,
        localPort: Int?
    ) async throws -> ProxyRequestContext {
        let request = try await cacheRequest(for: originalURL, headers: head.headers)
        let hlsResourceKind = ProxyURLCodec.hlsResourceKind(from: head.uri)
        return ProxyRequestContext(
            originalURL: originalURL,
            request: request,
            hlsDownloadRequest: await cleanHLSDownloadRequest(for: request, originalURL: originalURL, proxyURI: head.uri),
            hlsResourceKind: hlsResourceKind,
            isHeadRequest: head.method == .HEAD,
            clientRequestedRange: head.headers.first(name: "Range") != nil,
            proxyPort: proxyPort(from: head.headers, localPort: localPort)
        )
    }

    static func originalURL(from uri: String) -> URL? {
        var components = uri.components(separatedBy: "/")
        guard components.count >= 3 else {
            return nil
        }

        let urlString = ProxyURLCodec.decode(components[1])
        guard let urlString, urlString.hasPrefix("http") else {
            return nil
        }

        if uri.contains("HTTPMediaCacheLastPathComponent") {
            return URL(string: urlString)
        }

        components.remove(at: 0)
        components.remove(at: 0)

        guard var baseURL = URL(string: urlString)?.deletingLastPathComponent() else {
            return nil
        }
        if uri.contains("HTTPMediaCachePlaceHolder") {
            components.remove(at: 0)
        } else {
            baseURL = baseURL.deletingLastPathComponent()
        }

        let lastPathComponent = components.joined(separator: "/")
        if lastPathComponent.hasPrefix("http") {
            return URL(string: lastPathComponent)
        }
        return baseURL.appendingPathComponent(lastPathComponent)
    }

    private static func cacheRequest(for url: URL, headers: HTTPHeaders) async throws -> CacheRequest {
        var forwardedHeaders: [String: String] = [:]
        for header in headers {
            guard shouldForwardHeader(named: header.name) else {
                continue
            }
            forwardedHeaders[header.name] = header.value
        }

        let range = try await normalizedRange(from: headers.first(name: "Range"))
        if let range {
            forwardedHeaders["Range"] = range.requestHeaderValue
        }
        return CacheRequest(url: url, headers: forwardedHeaders, range: range)
    }

    private static func cleanHLSDownloadRequest(for request: CacheRequest, originalURL: URL, proxyURI: String) async -> CacheRequest {
        let policy = HLSDownloadPolicy()
        if ProxyRequestClassifier.isHLSURL(originalURL) {
            return await policy.playlistRequest(from: request)
        }
        if let kind = ProxyURLCodec.hlsResourceKind(from: proxyURI) {
            return await policy.resourceRequest(url: request.url, kind: kind, range: ProxyURLCodec.hlsByteRange(from: proxyURI))
        }
        guard ProxyRequestClassifier.isHLSMediaSegmentURL(originalURL) else {
            return request
        }
        return await policy.mediaRequest(url: request.url, range: request.range)
    }

    private static func shouldForwardHeader(named name: String) -> Bool {
        let blockedHeaders = [
            "Host",
            "Proxy-Connection",
            "Keep-Alive",
            "Transfer-Encoding",
            "TE",
            "Trailer",
            "Upgrade",
        ]
        return !blockedHeaders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func normalizedRange(from header: String?) async throws -> ByteRange? {
        guard let header else {
            return ByteRange(start: 0, end: nil)
        }

        guard let range = ByteRange(requestHeader: header) else {
            return nil
        }
        return range
    }

    private static func proxyPort(from headers: HTTPHeaders, localPort: Int?) -> UInt16 {
        if let port = localPort {
            return UInt16(port)
        }

        guard let host = headers.first(name: "Host") else {
            return 0
        }

        let portText: String
        if host.hasPrefix("[") {
            guard let closingBracket = host.firstIndex(of: "]") else {
                return 0
            }
            let nextIndex = host.index(after: closingBracket)
            guard nextIndex < host.endIndex, host[nextIndex] == ":" else {
                return 0
            }
            portText = String(host[host.index(after: nextIndex)...])
        } else {
            guard let colonIndex = host.lastIndex(of: ":") else {
                return 0
            }
            portText = String(host[host.index(after: colonIndex)...])
        }

        return UInt16(portText) ?? 0
    }
}
