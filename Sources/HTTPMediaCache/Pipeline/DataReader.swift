//
//  DataReader.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 数据读取器，优先读取本地缓存，缺失区间再回源下载并写入缓存。
public struct DataReader: Sendable {
    private let request: CacheRequest?
    private let cacheIndex: CacheIndex?
    private let downloader: any CacheDownloading

    /// 创建只负责下载读取的数据读取器。
    public init(downloader: any CacheDownloading) {
        request = nil
        cacheIndex = nil
        self.downloader = downloader
    }

    /// 创建带缓存索引的数据读取器。
    public init(request: CacheRequest, cacheIndex: CacheIndex, downloader: any CacheDownloading) {
        self.request = request
        self.cacheIndex = cacheIndex
        self.downloader = downloader
    }

    /// 读取初始化时绑定的请求。
    public func read() async throws -> Data {
        guard let request, let cacheIndex else {
            throw CacheError.storageFailure("DataReader requires a cache request.")
        }

        return try await readThroughCache(request: request, cacheIndex: cacheIndex)
    }

    /// 直接下载指定请求。
    public func read(request: CacheRequest) async throws -> Data {
        let chunks = try await downloader.download(request: request)
        return chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
    }

    private func readThroughCache(request: CacheRequest, cacheIndex: CacheIndex) async throws -> Data {
        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        do {
            let data = try await readThroughCache(request: request, cacheIndex: cacheIndex, unit: unit)
            await unit.workingRelease()
            return data
        } catch {
            await unit.workingRelease()
            throw error
        }
    }

    private func readThroughCache(request: CacheRequest, cacheIndex: CacheIndex, unit: CacheUnit) async throws -> Data {
        let item = await unit.cacheItem()
        let normalizedRequest = request.normalizedForKnownTotalLength(item.totalLength)
        guard let range = normalizedRequest.range else {
            if item.totalLength > 0,
               let data = try await unit.read(range: ByteRange(start: 0, end: item.totalLength - 1))
            {
                return data
            }
            return try await downloadAndCache(request: normalizedRequest, cacheIndex: cacheIndex)
        }

        var data = Data()
        let segments = await SourcePlanner().plan(request: range, cachedZones: unit.cachedZones())
        for segment in segments {
            switch segment {
            case let .file(fileRange):
                guard let cachedData = try await unit.read(range: fileRange) else {
                    throw CacheError.storageFailure("Missing cached data for \(request.url.absoluteString).")
                }
                data.append(cachedData)
            case let .network(networkRange):
                let chunkSize = await CacheRuntime.shared.requestHeaderRangeLength(for: normalizedRequest.url, totalLength: item.totalLength)
                for chunkRange in NetworkRangeChunker.split(networkRange, maximumLength: chunkSize) {
                    let networkData = try await downloadAndCache(request: normalizedRequest.replacingRange(chunkRange), cacheIndex: cacheIndex)
                    data.append(networkData)
                }
            }
        }
        return data
    }

    private func downloadAndCache(request: CacheRequest, cacheIndex: CacheIndex) async throws -> Data {
        let response: CacheDownloadResponse
        if let downloader = downloader as? any CacheResponseDownloading {
            response = try await downloader.downloadResponse(request: request)
        } else {
            let data = try await read(request: request)
            response = CacheDownloadResponse(data: data, statusCode: 200, headers: [:])
        }

        try await writeToCache(data: response.data, request: request, responseHeaders: response.headers, cacheIndex: cacheIndex)
        return response.data
    }

    private func writeToCache(
        data: Data,
        request: CacheRequest,
        responseHeaders: [String: String],
        cacheIndex: CacheIndex
    ) async throws {
        guard !data.isEmpty else {
            return
        }

        let start = request.range?.isSuffixRange == true ? responseHeaders.contentRangeStart ?? 0 : request.range?.start ?? 0
        let end = start + Int64(data.count) - 1
        let totalLength = responseHeaders.contentRangeTotalLength ?? responseHeaders.contentLength ?? max(end + 1, Int64(data.count))
        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        do {
            try await cacheIndex.prepareForWrite(length: Int64(data.count), excluding: request.url)
            try await unit.write(
                data: data,
                offset: start,
                totalLength: totalLength,
                responseHeaders: responseHeaders
            )
            await unit.workingRelease()
        } catch {
            await unit.workingRelease()
            throw error
        }
    }
}

private extension CacheRequest {
    func normalizedForKnownTotalLength(_ totalLength: Int64) -> CacheRequest {
        guard totalLength > 0, let range else {
            return self
        }
        return replacingRange(range.normalized(totalLength: totalLength))
    }

    func replacingRange(_ range: ByteRange) -> CacheRequest {
        var headers = headers
        headers["Range"] = range.requestHeaderValue
        return CacheRequest(url: url, headers: headers, range: range)
    }
}
