//
//  CacheItem.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 单个媒体资源的缓存状态。
public struct CacheItem: Sendable, Equatable {
    /// 原始媒体 URL。
    public var url: URL
    /// 资源总长度，未知时由响应头或写入范围推导。
    public var totalLength: Int64
    /// 当前已缓存的字节数。
    public var cachedLength: Int64
    /// 最近一次缓存写入记录的内容类型。
    public var contentType: String?
    /// 最近访问时间，用于缓存淘汰排序。
    public var lastAccessDate: Date
    /// 已缓存的字节区间。
    public var zones: [ByteRange]

    /// 缓存进度，范围为 0...1。
    public var progress: Double {
        guard totalLength > 0 else { return 0 }
        return Double(cachedLength) / Double(totalLength)
    }

    /// 创建缓存状态描述。
    public init(
        url: URL,
        totalLength: Int64,
        cachedLength: Int64,
        contentType: String?,
        lastAccessDate: Date,
        zones: [ByteRange]
    ) {
        self.url = url
        self.totalLength = totalLength
        self.cachedLength = cachedLength
        self.contentType = contentType
        self.lastAccessDate = lastAccessDate
        self.zones = zones
    }
}
