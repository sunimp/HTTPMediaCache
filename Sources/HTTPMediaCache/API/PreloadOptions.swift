//
//  PreloadOptions.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

/// 预加载范围配置。
public struct PreloadOptions: Sendable, Equatable {
    /// HLS 资源的预加载限制。
    public enum HLSLimit: Sendable, Equatable {
        /// 预加载全部可解析资源。
        case all
        /// 按 segment 数量限制预加载。
        case segmentCount(Int)
        /// 按 `EXTINF` 累计时长限制预加载，segment 会完整缓存。
        case duration(TimeInterval)
        /// 按 segment 大小累计字节数限制预加载。
        case byteCount(Int64)
    }

    /// 普通文件资源的预加载限制。
    public enum FileLimit: Sendable, Equatable {
        /// 预加载完整文件。
        case all
        /// 只预加载文件前缀的指定字节数。
        case byteCount(Int64)
    }

    /// HLS 资源预加载限制。
    public var hlsLimit: HLSLimit
    /// 普通文件资源预加载限制。
    public var fileLimit: FileLimit

    /// 创建预加载配置。
    public init(hlsLimit: HLSLimit = .all, fileLimit: FileLimit = .all) {
        self.hlsLimit = hlsLimit
        self.fileLimit = fileLimit
    }
}
