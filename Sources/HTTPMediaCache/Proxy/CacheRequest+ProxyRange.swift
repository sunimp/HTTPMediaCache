//
//  CacheRequest+ProxyRange.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

extension CacheRequest {
    func proxyNormalizedForKnownTotalLength(_ totalLength: Int64) -> CacheRequest {
        guard totalLength > 0, let range else {
            return self
        }
        return proxyReplacingRange(range.normalized(totalLength: totalLength))
    }

    func proxyReplacingRange(_ range: ByteRange) -> CacheRequest {
        var headers = headers
        headers["Range"] = range.requestHeaderValue
        return CacheRequest(url: url, headers: headers, range: range)
    }
}
