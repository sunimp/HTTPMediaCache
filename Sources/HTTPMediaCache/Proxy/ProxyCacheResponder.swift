//
//  ProxyCacheResponder.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct ProxyCacheResponder {
    func cachedResponse(for request: CacheRequest) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        let normalizedRequest = request.proxyNormalizedForKnownTotalLength(item.totalLength)
        guard let range = normalizedRequest.range, range.end != nil else {
            return nil
        }

        guard let data = try await unit.read(range: range) else {
            return nil
        }

        var headers = await unit.cachedResponseHeaders()
        headers["Content-Length"] = "\(data.count)"
        headers["Content-Range"] = "bytes \(range.start)-\(range.end ?? range.start)/\(item.totalLength)"
        if headers.headerValue(for: "Accept-Ranges") == nil {
            headers["Accept-Ranges"] = "bytes"
        }

        return CachedProxyResponse(data: data, range: range, headers: headers)
    }

    func cachedFullResponse(for request: CacheRequest) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        guard item.totalLength > 0 else {
            return nil
        }

        let range = ByteRange(start: 0, end: item.totalLength - 1)
        guard let data = try await unit.read(range: range) else {
            return nil
        }

        var headers = await unit.cachedResponseHeaders()
        if headers.headerValue(for: "Accept-Ranges") == nil {
            headers["Accept-Ranges"] = "bytes"
        }
        headers["Content-Length"] = "\(data.count)"
        return CachedProxyResponse(data: data, range: range, headers: headers)
    }
}
