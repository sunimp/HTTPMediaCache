//
//  CacheRequest.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 一次缓存读取、下载或预加载请求。
public struct CacheRequest: Sendable, Equatable {
    /// 原始媒体 URL。
    public var url: URL
    /// 透传给下载请求的 HTTP 头。
    public var headers: [String: String]
    /// 请求的字节区间。
    public var range: ByteRange?
    var allowsUnfilteredHeaders: Bool

    /// 创建缓存请求。
    ///
    /// 如果没有显式传入 `range` 或 `Range` 请求头，会默认设置为从 0 开始的开放区间。
    public init(url: URL, headers: [String: String] = [:], range: ByteRange? = nil) {
        self.url = url
        var headers = headers
        if let range {
            headers["Range"] = range.requestHeaderValue
            self.range = range
        } else if let rangeHeader = headers["Range"] {
            self.range = ByteRange(requestHeader: rangeHeader)
        } else {
            let fullRange = ByteRange(start: 0, end: nil)
            headers["Range"] = fullRange.requestHeaderValue
            self.range = fullRange
        }
        self.headers = headers
        allowsUnfilteredHeaders = false
    }

    init(downloadURL url: URL, headers: [String: String] = [:], range: ByteRange? = nil, allowsUnfilteredHeaders: Bool = false) {
        self.url = url
        var headers = headers
        if let range {
            headers["Range"] = range.requestHeaderValue
        }
        self.headers = headers
        self.range = range
        self.allowsUnfilteredHeaders = allowsUnfilteredHeaders
    }
}
