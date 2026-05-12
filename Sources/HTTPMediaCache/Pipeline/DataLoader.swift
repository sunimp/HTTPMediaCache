//
//  DataLoader.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 面向上层调用的数据加载器。
public struct DataLoader: Sendable {
    private enum Mode {
        case reader(DataReader)
        case hls(request: CacheRequest, cacheIndex: CacheIndex, downloader: any CacheDownloading)
    }

    private let mode: Mode

    /// 创建普通资源加载器。
    public init(reader: DataReader) {
        mode = .reader(reader)
    }

    init(hlsRequest request: CacheRequest, cacheIndex: CacheIndex, downloader: any CacheDownloading) {
        mode = .hls(request: request, cacheIndex: cacheIndex, downloader: downloader)
    }

    /// 加载初始化时绑定的资源。
    public func load() async throws -> Data {
        switch mode {
        case let .reader(reader):
            try await reader.read()
        case let .hls(request, cacheIndex, downloader):
            try await loadHLS(request: request, cacheIndex: cacheIndex, downloader: downloader)
        }
    }

    /// 加载指定请求。
    public func load(request: CacheRequest) async throws -> Data {
        switch mode {
        case let .reader(reader):
            try await reader.read(request: request)
        case let .hls(_, cacheIndex, downloader):
            try await DataReader(request: request, cacheIndex: cacheIndex, downloader: downloader).read()
        }
    }

    private func loadHLS(request: CacheRequest, cacheIndex: CacheIndex, downloader: any CacheDownloading) async throws -> Data {
        let data: Data
        if let cachedData = try await cachedCompleteData(for: request, cacheIndex: cacheIndex) {
            data = cachedData
        } else {
            let response: CacheDownloadResponse
            if let downloader = downloader as? any CacheHLSResponseDownloading {
                response = try await downloader.downloadHLSResponse(request: request)
            } else if let downloader = downloader as? any CacheResponseDownloading {
                response = try await downloader.downloadResponse(request: request)
            } else {
                let data = try await DataReader(downloader: downloader).read(request: request)
                response = CacheDownloadResponse(data: data, statusCode: 200, headers: [:])
            }

            guard let playlist = String(data: response.data, encoding: .utf8) else {
                throw CacheError.networkFailure("HLS playlist is not UTF-8: \(request.url.absoluteString).")
            }

            let rewritten = try await HLSPlaylistRewriter(codec: ProxyURLCodec(port: 0)).rewrite(playlist: playlist, baseURL: request.url)
            data = Data(rewritten.utf8)
            var responseHeaders = response.headers
            responseHeaders["Content-Length"] = "\(data.count)"
            try await writeToCache(data: data, request: request, responseHeaders: responseHeaders, cacheIndex: cacheIndex)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw CacheError.networkFailure("HLS playlist is not UTF-8: \(request.url.absoluteString).")
        }

        let segmentURLs = HLSPlaylistRewriter.makeURLs(for: content, sourceURL: request.url)
        for segmentURL in segmentURLs {
            _ = try await DataReader(request: CacheRequest(url: segmentURL), cacheIndex: cacheIndex, downloader: downloader).read()
        }

        return data
    }

    private func cachedCompleteData(for request: CacheRequest, cacheIndex: CacheIndex) async throws -> Data? {
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        guard item.totalLength > 0 else {
            return nil
        }
        guard let data = try await unit.read(range: ByteRange(start: 0, end: item.totalLength - 1)) else {
            return nil
        }
        if let playlist = String(data: data, encoding: .utf8),
           HLSPlaylistRewriter.containsProxyURLMarkers(playlist)
        {
            await cacheIndex.deleteCache(for: request.url)
            return nil
        }
        return data
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

        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        do {
            let offset = request.range?.isSuffixRange == true ? responseHeaders.contentRangeStart ?? 0 : request.range?.start ?? 0
            let end = offset + Int64(data.count) - 1
            let totalLength = responseHeaders.contentRangeTotalLength ?? responseHeaders.contentLength ?? max(end + 1, Int64(data.count))
            try await cacheIndex.prepareForWrite(length: Int64(data.count), excluding: request.url)
            try await unit.write(
                data: data,
                offset: offset,
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
