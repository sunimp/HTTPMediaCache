//
//  CacheDownloading.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 缓存链路使用的下载接口。
public protocol CacheDownloading: Sendable {
    /// 下载指定请求并返回数据块。
    func download(request: CacheRequest) async throws -> [Data]
}

/// 测试用固定数据下载器。
public struct MockDownloader: CacheDownloading {
    private let data: Data

    /// 创建固定数据下载器。
    public static func mock(_ data: Data) -> MockDownloader {
        MockDownloader(data: data)
    }

    /// 创建固定数据下载器。
    public init(data: Data) {
        self.data = data
    }

    /// 返回初始化时注入的数据。
    public func download(request _: CacheRequest) async throws -> [Data] {
        [data]
    }
}
