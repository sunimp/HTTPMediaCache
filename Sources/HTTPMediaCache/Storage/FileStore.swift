//
//  FileStore.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 文件系统操作封装。
public struct FileStore: Sendable {
    /// 创建文件存储封装。
    public init() {}

    /// 确保目录存在。
    public func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// 删除指定文件或目录；不存在时直接返回。
    public func deleteItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
