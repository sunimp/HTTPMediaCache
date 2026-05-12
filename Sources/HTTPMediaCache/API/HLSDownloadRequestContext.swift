//
//  HLSDownloadRequestContext.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

/// HLS 下载资源类型。
public enum HLSDownloadResourceKind: String, Sendable, Equatable {
    case playlist
    case variantPlaylist
    case renditionPlaylist
    case subtitlePlaylist
    case iFramePlaylist
    case key
    case initialization
    case segment
}

/// HLS 下载请求上下文。
public struct HLSDownloadRequestContext: Sendable, Equatable {
    /// 当前资源类型。
    public var kind: HLSDownloadResourceKind
    /// 当前资源的原始 URL。
    public var url: URL
    /// 当前资源需要请求的字节区间；完整资源为 nil。
    public var byteRange: ByteRange?

    /// 创建 HLS 下载请求上下文。
    public init(kind: HLSDownloadResourceKind, url: URL, byteRange: ByteRange? = nil) {
        self.kind = kind
        self.url = url
        self.byteRange = byteRange
    }
}

/// HLS 下载请求头提供器。
public typealias HLSDownloadHeaderProvider = @Sendable (HLSDownloadRequestContext) -> [String: String]
