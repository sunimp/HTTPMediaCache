//
//  CacheError.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// HTTPMediaCache 对外暴露的错误类型。
public enum CacheError: Error, Equatable {
    /// URL 无效或无法转换为代理 URL。
    case invalidURL
    /// 本地代理服务尚未启动。
    case proxyNotRunning
    /// Range 或预加载范围参数无效。
    case invalidRange
    /// 远端响应的内容类型不在允许范围内。
    case unsupportedContentType(String?)
    /// 网络请求失败。
    case networkFailure(String)
    /// 缓存文件或索引读写失败。
    case storageFailure(String)
}
