//
//  HLSProxyResponder.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation
import NIO

struct HLSProxyResponder {
    let responseWriter: HTTPResponseWriter

    func writeResponse(
        for request: CacheRequest,
        isHeadRequest: Bool,
        proxyPort: UInt16,
        responseState: ProxyResponseState,
        context: ChannelHandlerContext
    ) async throws {
        let rawResponse: CachedHLSPlaylistResponse
        if let cachedResponse = try await cachedHLSPlaylistResponse(for: request) {
            rawResponse = cachedResponse
        } else {
            let downloader = await CacheRuntime.shared.downloader
            let response = try await ProxyOriginDownloader.downloadResponse(request: request, downloader: downloader)
            var rawHeaders = response.headers
            rawHeaders["Content-Length"] = "\(response.data.count)"
            try await ProxyCacheWriter.record(data: response.data, offset: 0, request: request, responseHeaders: rawHeaders, end: Int64(response.data.count) - 1)
            rawResponse = CachedHLSPlaylistResponse(data: response.data, headers: rawHeaders)
        }

        guard let playlist = String(data: rawResponse.data, encoding: .utf8) else {
            throw CacheError.networkFailure("HLS playlist is not UTF-8: \(request.url.absoluteString).")
        }

        let codec = ProxyURLCodec(port: proxyPort)
        let rewritten = try await HLSPlaylistRewriter(codec: codec).rewriteForProxyPlayback(playlist: playlist, baseURL: request.url)
        let data = Data(rewritten.utf8)
        var headers = rawResponse.headers
        headers["Content-Length"] = "\(data.count)"
        responseState.markStarted()
        responseWriter.writeDataResponse(data: data, headers: headers, isHeadRequest: isHeadRequest, context: context)
    }

    private func cachedHLSPlaylistResponse(for request: CacheRequest) async throws -> CachedHLSPlaylistResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        guard item.totalLength > 0,
              let data = try await unit.read(range: ByteRange(start: 0, end: item.totalLength - 1))
        else {
            return nil
        }
        if let playlist = String(data: data, encoding: .utf8),
           HLSPlaylistRewriter.containsProxyURLMarkers(playlist)
        {
            await cacheIndex.deleteCache(for: request.url)
            return nil
        }
        return CachedHLSPlaylistResponse(data: data, headers: await unit.cachedResponseHeaders())
    }
}
