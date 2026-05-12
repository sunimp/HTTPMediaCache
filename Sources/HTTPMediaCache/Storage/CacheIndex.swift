//
//  CacheIndex.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import CryptoKit
import Foundation

/// 缓存索引，负责 URL 到缓存单元的映射和缓存空间管理。
public actor CacheIndex {
    /// 默认最大缓存空间，单位为字节。
    public static let defaultMaxCacheLength: Int64 = 500 * 1024 * 1024

    private let rootDirectory: URL
    private let fileStore: FileStore
    private var units: [String: CacheUnit]
    private var unitKeysInQueueOrder: [String]
    private var loadState: LoadState
    private var maxCacheLength: Int64
    private var urlConverter: (@Sendable (URL) -> URL)?
    private var cacheIdentifierProvider: (@Sendable (URL) -> String)?

    /// 创建缓存索引。
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        fileStore = FileStore()
        maxCacheLength = Self.defaultMaxCacheLength
        units = [:]
        unitKeysInQueueOrder = []
        loadState = .unloaded
    }

    /// 获取或创建指定 URL 的缓存单元。
    public func unit(for url: URL) async throws -> CacheUnit {
        await ensureLoaded()
        let key = cacheKey(for: url)
        if let unit = units[key] {
            return unit
        }

        try fileStore.ensureDirectory(rootDirectory)
        let directory = rootDirectory.appendingPathComponent(key, isDirectory: true)
        try fileStore.ensureDirectory(directory)

        let unit = CacheUnit(url: url, directory: directory, cacheKey: key)
        units[key] = unit
        unitKeysInQueueOrder.append(key)
        return unit
    }

    /// 查询指定 URL 的缓存状态。
    public func cacheItem(for url: URL) async throws -> CacheItem? {
        await ensureLoaded()
        guard let unit = units[cacheKey(for: url)] else {
            return nil
        }

        return await unit.cacheItem()
    }

    /// 查询所有缓存条目。
    public func allCacheItems() async -> [CacheItem] {
        await ensureLoaded()
        var items: [CacheItem] = []
        for unit in units.values {
            await items.append(unit.cacheItem())
        }
        return items
    }

    /// 统计当前缓存总字节数。
    public func totalCacheLength() async -> Int64 {
        await ensureLoaded()
        var length: Int64 = 0
        for unit in units.values {
            length += await unit.rawCacheLength()
        }
        return length
    }

    /// 获取已完整缓存文件的本地路径。
    public func completeFileURL(for url: URL) async throws -> URL? {
        await ensureLoaded()
        guard let unit = units[cacheKey(for: url)] else {
            return nil
        }
        return await unit.completeFileURL()
    }

    /// 删除指定 URL 的缓存；正在使用的缓存单元会跳过删除。
    public func deleteCache(for url: URL) async {
        await ensureLoaded()
        let key = cacheKey(for: url)
        let unit = units[key]
        if let unit, await unit.isWorking() {
            return
        }
        units[key] = nil
        unitKeysInQueueOrder.removeAll { $0 == key }
        if let unit {
            await unit.deleteFiles()
        } else {
            let directory = rootDirectory.appendingPathComponent(key, isDirectory: true)
            try? fileStore.deleteItem(at: directory)
        }
    }

    /// 删除全部未使用中的缓存。
    public func deleteAllCaches() async {
        await ensureLoaded()
        let currentUnits = await units.asyncMap { key, unit in
            await (key: key, unit: unit, isWorking: unit.isWorking())
        }
        for currentUnit in currentUnits where !currentUnit.isWorking {
            units[currentUnit.key] = nil
            unitKeysInQueueOrder.removeAll { $0 == currentUnit.key }
            await currentUnit.unit.deleteFiles()
        }
        if units.isEmpty {
            try? fileStore.deleteItem(at: rootDirectory)
        }
    }

    /// 设置最大缓存空间，单位为字节。
    public func setMaxCacheLength(_ maxCacheLength: Int64) {
        self.maxCacheLength = max(0, maxCacheLength)
    }

    /// 获取最大缓存空间，单位为字节。
    public func currentMaxCacheLength() -> Int64 {
        maxCacheLength
    }

    /// 为即将写入的数据预留空间，必要时按访问顺序淘汰缓存。
    public func prepareForWrite(length: Int64, excluding url: URL) async throws {
        await ensureLoaded()
        guard maxCacheLength < Int64.max, length > 0 else {
            return
        }

        guard length <= maxCacheLength else {
            throw CacheError.insufficientCacheSpace(requiredLength: length, maxCacheLength: maxCacheLength)
        }

        let excludedKey = cacheKey(for: url)
        var totalLength = await totalCacheLength()
        guard totalLength + length > maxCacheLength else {
            return
        }

        var candidates: [(key: String, unit: CacheUnit, lastAccessDate: Date, queueOrder: Int)] = []
        for (queueOrder, key) in unitKeysInQueueOrder.enumerated() {
            guard key != excludedKey, let unit = units[key], await !(unit.isWorking()) else {
                continue
            }
            candidates.append((key: key, unit: unit, lastAccessDate: await unit.cacheItem().lastAccessDate, queueOrder: queueOrder))
        }
        candidates.sort {
            if $0.lastAccessDate != $1.lastAccessDate {
                return $0.lastAccessDate < $1.lastAccessDate
            }
            return $0.queueOrder < $1.queueOrder
        }

        for candidate in candidates {
            guard totalLength + length > maxCacheLength else {
                break
            }
            units[candidate.key] = nil
            unitKeysInQueueOrder.removeAll { $0 == candidate.key }
            totalLength -= await candidate.unit.rawCacheLength()
            await candidate.unit.deleteFiles()
        }

        if totalLength + length > maxCacheLength {
            throw CacheError.insufficientCacheSpace(requiredLength: length, maxCacheLength: maxCacheLength)
        }
    }

    /// 设置缓存 key 计算前的 URL 转换器。
    public func setURLConverter(_ converter: (@Sendable (URL) -> URL)?) {
        urlConverter = converter
    }

    /// 设置缓存标识提供器。
    public func setCacheIdentifierProvider(_ provider: (@Sendable (URL) -> String)?) {
        cacheIdentifierProvider = provider
    }

    func cacheKey(for url: URL) -> String {
        Self.cacheKey(for: url, converter: urlConverter, identifierProvider: cacheIdentifierProvider)
    }

    static func cacheKey(
        for url: URL,
        converter: (@Sendable (URL) -> URL)? = nil,
        identifierProvider: (@Sendable (URL) -> String)? = nil
    ) -> String {
        if let identifier = identifierProvider?(url) {
            return cacheKey(for: identifier)
        }
        let convertedURL = converter?(url) ?? url
        return cacheKey(for: convertedURL.absoluteString)
    }

    static func cacheKey(for urlString: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(urlString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func ensureLoaded() async {
        switch loadState {
        case .loaded:
            return
        case let .loading(task):
            let loadedUnits = await task.value
            finishLoading(loadedUnits)
        case .unloaded:
            let rootDirectory = rootDirectory
            let task = Task.detached(priority: .utility) {
                Self.loadUnits(rootDirectory: rootDirectory)
            }
            loadState = .loading(task)
            let loadedUnits = await task.value
            finishLoading(loadedUnits)
        }
    }

    private func finishLoading(_ loadedUnits: (units: [String: CacheUnit], unitKeysInQueueOrder: [String])) {
        guard case .loaded = loadState else {
            units = loadedUnits.units
            unitKeysInQueueOrder = loadedUnits.unitKeysInQueueOrder
            loadState = .loaded
            return
        }
    }

    private static func loadUnits(rootDirectory: URL) -> (units: [String: CacheUnit], unitKeysInQueueOrder: [String]) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([:], [])
        }

        var loadedUnits: [(key: String, unit: CacheUnit, createDate: Date)] = []
        for directory in directories {
            guard let unit = CacheUnit.load(directory: directory) else {
                continue
            }
            loadedUnits.append((key: unit.cacheKey, unit: unit, createDate: unit.queueOrderDate()))
        }
        loadedUnits.sort { lhs, rhs in
            lhs.createDate < rhs.createDate
        }

        let units = loadedUnits.reduce(into: [String: CacheUnit]()) { result, element in
            result[element.key] = element.unit
        }
        return (units, loadedUnits.map(\.key))
    }
}

private enum LoadState {
    case unloaded
    case loading(Task<(units: [String: CacheUnit], unitKeysInQueueOrder: [String]), Never>)
    case loaded
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            await values.append(transform(element))
        }
        return values
    }
}
