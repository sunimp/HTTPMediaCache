//
//  CacheUnit.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 单个 URL 对应的缓存单元，负责数据文件和元数据维护。
public actor CacheUnit {
    /// 缓存 key。
    public let cacheKey: String
    /// 原始媒体 URL。
    public let url: URL
    /// 缓存单元目录。
    public let directory: URL

    private var totalLength: Int64
    private var responseHeaders: [String: String]
    private let createDate: Date
    private var lastAccessDate: Date
    private var zones: [ByteRange]
    private var workingCount: Int
    private var dataFileURL: URL {
        directory.appendingPathComponent("data.bin")
    }

    private var completeDataFileURL: URL {
        let fileName = url.pathExtension.isEmpty ? cacheKey : "\(cacheKey).\(url.pathExtension)"
        return directory.appendingPathComponent(fileName)
    }

    private var metadataFileURL: URL {
        directory.appendingPathComponent("metadata.json")
    }

    /// 创建缓存单元。
    public init(url: URL, directory: URL, cacheKey: String? = nil) {
        self.cacheKey = cacheKey ?? directory.lastPathComponent
        self.url = url
        self.directory = directory
        totalLength = 0
        responseHeaders = [:]
        createDate = Date()
        lastAccessDate = Date()
        zones = []
        workingCount = 0
    }

    private init(metadata: CacheUnitMetadata, directory: URL) {
        cacheKey = metadata.cacheKey ?? directory.lastPathComponent
        url = metadata.url
        self.directory = directory
        totalLength = metadata.totalLength
        responseHeaders = metadata.responseHeaders
        createDate = metadata.createDate ?? metadata.lastAccessDate
        lastAccessDate = metadata.lastAccessDate
        zones = Self.orderedZones(metadata.zones)
        workingCount = 0
    }

    static func load(directory: URL) -> CacheUnit? {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(CacheUnitMetadata.self, from: data)
        else {
            return nil
        }
        return CacheUnit(metadata: metadata, directory: directory)
    }

    /// 记录一次缓存写入。
    public func recordWrite(range: ByteRange, totalLength: Int64, contentType: String?) throws {
        var responseHeaders: [String: String] = [:]
        if let contentType {
            responseHeaders["Content-Type"] = contentType
        }
        try recordWrite(range: range, totalLength: totalLength, responseHeaders: responseHeaders)
    }

    /// 记录一次缓存写入和响应头。
    public func recordWrite(range: ByteRange, totalLength: Int64, responseHeaders: [String: String]) throws {
        try recordWrite(range: range, totalLength: totalLength, responseHeaders: responseHeaders, persistsMetadata: true)
    }

    func recordStreamingWrite(range: ByteRange, totalLength: Int64, responseHeaders: [String: String]) throws {
        try recordWrite(range: range, totalLength: totalLength, responseHeaders: responseHeaders, persistsMetadata: false)
    }

    func finishStreamingWrite() throws {
        try persistMetadata()
    }

    func writableDataFileURL() -> URL {
        if !FileManager.default.fileExists(atPath: dataFileURL.path) {
            FileManager.default.createFile(atPath: dataFileURL.path, contents: nil)
        }
        return dataFileURL
    }

    /// 返回用于缓存淘汰队列排序的创建时间。
    public nonisolated func queueOrderDate() -> Date {
        createDate
    }

    private func recordWrite(range: ByteRange, totalLength: Int64, responseHeaders: [String: String], persistsMetadata: Bool) throws {
        guard let rangeLength = range.length, rangeLength > 0 else {
            throw CacheError.invalidRange
        }

        self.totalLength = totalLength
        self.responseHeaders = Self.metadataResponseHeaders(from: responseHeaders)
        lastAccessDate = Date()
        zones = Self.orderedZones(zones + [range])
        if persistsMetadata {
            try persistMetadata()
        }
    }

    /// 写入数据并记录缓存区间。
    public func write(data: Data, offset: Int64, totalLength: Int64, contentType: String?) throws {
        var responseHeaders: [String: String] = [:]
        if let contentType {
            responseHeaders["Content-Type"] = contentType
        }
        try write(data: data, offset: offset, totalLength: totalLength, responseHeaders: responseHeaders)
    }

    /// 写入数据并记录缓存区间和响应头。
    public func write(data: Data, offset: Int64, totalLength: Int64, responseHeaders: [String: String]) throws {
        guard !data.isEmpty, offset >= 0 else {
            throw CacheError.invalidRange
        }

        if !FileManager.default.fileExists(atPath: dataFileURL.path) {
            FileManager.default.createFile(atPath: dataFileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: dataFileURL)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)

        try recordWrite(
            range: ByteRange(start: offset, end: offset + Int64(data.count) - 1),
            totalLength: totalLength,
            responseHeaders: responseHeaders
        )
    }

    /// 读取指定已缓存区间。
    public func read(range: ByteRange) throws -> Data? {
        guard isCached(range: range), let length = range.length else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: dataFileURL)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: UInt64(range.start))
        return try handle.read(upToCount: Int(length))
    }

    /// 生成当前缓存状态。
    public func cacheItem() -> CacheItem {
        CacheItem(
            url: url,
            totalLength: totalLength,
            cachedLength: Self.validLength(for: zones),
            contentType: responseHeaders.headerValue(for: "Content-Type"),
            lastAccessDate: lastAccessDate,
            zones: zones
        )
    }

    /// 统计当前缓存单元的有效数据长度。
    public func rawCacheLength() -> Int64 {
        zones.reduce(Int64(0)) { partialResult, range in
            partialResult + (range.length ?? 0)
        }
    }

    /// 返回完整缓存文件路径；未完整缓存时返回 nil。
    public func completeFileURL() -> URL? {
        guard totalLength > 0, let firstZone = zones.first else {
            return nil
        }
        guard firstZone.start == 0,
              let firstZoneEnd = firstZone.end,
              firstZoneEnd == totalLength - 1
        else {
            return nil
        }
        guard ensureCompleteFileExists() else {
            return nil
        }
        return completeDataFileURL
    }

    /// 返回已缓存区间。
    public func cachedZones() -> [ByteRange] {
        zones
    }

    /// 返回最近记录的响应头。
    public func cachedResponseHeaders() -> [String: String] {
        responseHeaders
    }

    /// 删除缓存单元目录。
    public func deleteFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 标记缓存单元正在被读取或写入。
    public func workingRetain() {
        workingCount += 1
    }

    /// 释放使用标记，并在空闲时合并完整文件。
    public func workingRelease() {
        workingCount = max(0, workingCount - 1)
        if workingCount == 0, mergeFilesIfNeeded() {
            try? persistMetadata()
        }
    }

    /// 当前是否正在被读取或写入。
    public func isWorking() -> Bool {
        workingCount > 0
    }

    private func isCached(range: ByteRange) -> Bool {
        guard let requestedEnd = range.end else {
            return false
        }

        return zones.contains { zone in
            guard let zoneEnd = zone.end else {
                return false
            }
            return zone.start <= range.start && zoneEnd >= requestedEnd
        }
    }

    private static func orderedZones(_ ranges: [ByteRange]) -> [ByteRange] {
        ranges
            .filter { $0.length != nil }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start {
                    return lhs.start < rhs.start
                }
                switch (lhs.end, rhs.end) {
                case let (lhsEnd?, rhsEnd?):
                    return lhsEnd > rhsEnd
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    return false
                }
            }
    }

    private static func validLength(for ranges: [ByteRange]) -> Int64 {
        var offset: Int64 = 0
        var length: Int64 = 0

        for range in orderedZones(ranges) {
            guard let end = range.end else {
                continue
            }

            let invalidLength = max(offset - range.start, 0)
            let rangeLength = end - range.start + 1
            let validLength = max(rangeLength - invalidLength, 0)
            offset = max(offset, end + 1)
            length += validLength
        }

        return length
    }

    private func mergeFilesIfNeeded() -> Bool {
        guard totalLength > 0, workingCount == 0, !zones.isEmpty else {
            return false
        }

        let orderedZones = Self.orderedZones(zones)
        guard let firstZone = orderedZones.first,
              firstZone.start == 0,
              Self.isFullyCovered(orderedZones, totalLength: totalLength)
        else {
            return false
        }

        let mergedZone = ByteRange(start: 0, end: totalLength - 1)
        guard orderedZones.count != 1 || orderedZones[0] != mergedZone else {
            return false
        }

        zones = [mergedZone]
        return true
    }

    private static func isFullyCovered(_ ranges: [ByteRange], totalLength: Int64) -> Bool {
        guard totalLength > 0 else {
            return false
        }

        let requestedEnd = totalLength - 1
        var cursor: Int64 = 0

        for range in ranges {
            guard let end = range.end else {
                return false
            }

            if end < cursor {
                continue
            }

            if range.start > cursor {
                return false
            }

            cursor = end == Int64.max ? Int64.max : end + 1
            if cursor > requestedEnd {
                return true
            }
        }

        return cursor > requestedEnd
    }

    private func ensureCompleteFileExists() -> Bool {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: completeDataFileURL.path) {
                try FileManager.default.removeItem(at: completeDataFileURL)
            }
            try FileManager.default.copyItem(at: dataFileURL, to: completeDataFileURL)
            return true
        } catch {
            return false
        }
    }

    private static func metadataResponseHeaders(from headers: [String: String]) -> [String: String] {
        let whitelist = [
            "Accept-Ranges",
            "Connection",
            "Content-Type",
            "Server",
        ]

        return whitelist.reduce(into: [String: String]()) { result, name in
            if let value = headers.headerValue(for: name) {
                result[name] = value
            }
        }
    }

    private func persistMetadata() throws {
        let metadata = CacheUnitMetadata(
            cacheKey: cacheKey,
            url: url,
            totalLength: totalLength,
            responseHeaders: responseHeaders,
            createDate: createDate,
            lastAccessDate: lastAccessDate,
            zones: zones
        )
        try Self.persist(metadata: metadata, to: metadataFileURL)
    }

    private static func persist(metadata: CacheUnitMetadata, to metadataFileURL: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataFileURL, options: .atomic)
    }
}

private struct CacheUnitMetadata: Codable {
    var cacheKey: String?
    var url: URL
    var totalLength: Int64
    var responseHeaders: [String: String]
    var createDate: Date?
    var lastAccessDate: Date
    var zones: [ByteRange]

    private enum CodingKeys: String, CodingKey {
        case cacheKey
        case uniqueIdentifier
        case url
        case totalLength
        case responseHeaders
        case contentType
        case createDate
        case lastAccessDate
        case zones
    }

    init(cacheKey: String, url: URL, totalLength: Int64, responseHeaders: [String: String], createDate: Date, lastAccessDate: Date, zones: [ByteRange]) {
        self.cacheKey = cacheKey
        self.url = url
        self.totalLength = totalLength
        self.responseHeaders = responseHeaders
        self.createDate = createDate
        self.lastAccessDate = lastAccessDate
        self.zones = zones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
            ?? container.decodeIfPresent(String.self, forKey: .uniqueIdentifier)
        url = try container.decode(URL.self, forKey: .url)
        totalLength = try container.decode(Int64.self, forKey: .totalLength)
        createDate = try container.decodeIfPresent(Date.self, forKey: .createDate)
        lastAccessDate = try container.decode(Date.self, forKey: .lastAccessDate)
        zones = try container.decode([ByteRange].self, forKey: .zones)

        let storedHeaders = try container.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:]
        if storedHeaders.isEmpty, let contentType = try container.decodeIfPresent(String.self, forKey: .contentType), !contentType.isEmpty {
            responseHeaders = ["Content-Type": contentType]
        } else {
            responseHeaders = storedHeaders
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cacheKey, forKey: .cacheKey)
        try container.encode(url, forKey: .url)
        try container.encode(totalLength, forKey: .totalLength)
        try container.encode(responseHeaders, forKey: .responseHeaders)
        try container.encode(createDate, forKey: .createDate)
        try container.encode(lastAccessDate, forKey: .lastAccessDate)
        try container.encode(zones, forKey: .zones)
    }
}
