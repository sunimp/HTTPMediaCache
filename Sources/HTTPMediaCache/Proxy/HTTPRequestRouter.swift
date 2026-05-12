//
//  HTTPRequestRouter.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
import NIO
import NIOHTTP1

final class HTTPRequestRouter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responseWriter = HTTPResponseWriter()
    private let pingToken = "HTTPMediaCachePing"
    private let taskLock = NSLock()
    private var requestTasks: [UUID: Task<Void, Never>] = [:]

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case let .head(head) = part else {
            return
        }

        if head.uri.contains(pingToken) {
            responseWriter.writeOK(data: Data("ping".utf8), context: context)
            return
        }

        guard let originalURL = originalURL(from: head.uri) else {
            responseWriter.writeNotFound(context: context)
            return
        }

        let contextBox = ChannelHandlerContextBox(context)
        let responseState = ProxyResponseState()
        let localPort = context.channel.localAddress?.port
        let taskID = UUID()
        let task = Task {
            defer {
                self.removeTask(id: taskID)
            }
            do {
                let isHeadRequest = head.method == .HEAD
                let clientRequestedRange = head.headers.first(name: "Range") != nil
                let request = try await cacheRequest(for: originalURL, headers: head.headers)
                let hlsDownloadRequest = await cleanHLSDownloadRequest(for: request, originalURL: originalURL, proxyURI: head.uri)
                let hlsResourceKind = ProxyURLCodec.hlsResourceKind(from: head.uri)

                if isHLSURL(originalURL) {
                    try await writeHLSResponse(
                        for: hlsDownloadRequest,
                        isHeadRequest: isHeadRequest,
                        proxyPort: proxyPort(from: head.headers, localPort: localPort),
                        responseState: responseState,
                        context: contextBox.context
                    )
                    return
                }

                if !clientRequestedRange, let cachedResponse = try await cachedFullResponse(for: request) {
                    responseState.markStarted()
                    responseWriter.writeCachedResponse(cachedResponse, status: .ok, isHeadRequest: isHeadRequest, context: contextBox.context)
                    return
                }

                if let cachedResponse = try await cachedResponse(for: request) {
                    if clientRequestedRange {
                        responseState.markStarted()
                        responseWriter.writeCachedResponse(
                            cachedResponse,
                            status: .partialContent,
                            isHeadRequest: isHeadRequest,
                            context: contextBox.context
                        )
                    } else {
                        responseState.markStarted()
                        responseWriter.writeCachedResponse(cachedResponse, status: .ok, isHeadRequest: isHeadRequest, context: contextBox.context)
                    }
                    return
                }

                let downloader = await CacheRuntime.shared.downloader

                if !isHeadRequest,
                   hlsResourceKind != nil,
                   let responseDownloader = downloader as? any CacheResponseDownloading
                {
                    let response = try await downloadResponse(request: hlsDownloadRequest, downloader: responseDownloader)
                    try await recordCacheWrite(data: response.data, request: hlsDownloadRequest, responseHeaders: response.headers)
                    if clientRequestedRange, let range = hlsDownloadRequest.range {
                        responseState.markStarted()
                        responseWriter.writeDataResponse(
                            data: response.data,
                            range: range,
                            headers: response.headers,
                            isHeadRequest: false,
                            context: contextBox.context
                        )
                    } else {
                        responseState.markStarted()
                        responseWriter.writeDataResponse(
                            data: response.data,
                            headers: response.headers,
                            isHeadRequest: false,
                            context: contextBox.context
                        )
                    }
                    return
                }

                if isHeadRequest, let headerDownloader = downloader as? any CacheHeaderDownloading {
                    try await writeHeaderResponse(
                        request: request,
                        clientRequestedRange: clientRequestedRange,
                        downloader: headerDownloader,
                        responseState: responseState,
                        context: contextBox.context
                    )
                    return
                }

                if isHeadRequest, let streamingDownloader = downloader as? any CacheStreamingDownloading {
                    try await writeStreamingHeadResponse(
                        request: request,
                        clientRequestedRange: clientRequestedRange,
                        downloader: streamingDownloader,
                        responseState: responseState,
                        context: contextBox.context
                    )
                    return
                }

                if !isHeadRequest,
                   isHLSMediaSegmentURL(originalURL),
                   let responseDownloader = downloader as? any CacheResponseDownloading
                {
                    let response = try await downloadResponse(request: hlsDownloadRequest, downloader: responseDownloader)
                    try await recordCacheWrite(data: response.data, request: hlsDownloadRequest, responseHeaders: response.headers)
                    if clientRequestedRange, let range = request.range {
                        responseState.markStarted()
                        responseWriter.writeDataResponse(
                            data: response.data,
                            range: range,
                            headers: response.headers,
                            isHeadRequest: false,
                            context: contextBox.context
                        )
                    } else {
                        responseState.markStarted()
                        responseWriter.writeDataResponse(
                            data: response.data,
                            headers: response.headers,
                            isHeadRequest: false,
                            context: contextBox.context
                        )
                    }
                    return
                }

                if !isHeadRequest, let streamingDownloader = downloader as? any CacheStreamingDownloading {
                    if try await streamAssembledResponse(
                        request: request,
                        clientRequestedRange: clientRequestedRange,
                        downloader: streamingDownloader,
                        responseState: responseState,
                        context: contextBox.context
                    ) {
                        return
                    }

                    try await streamResponse(
                        request: request,
                        clientRequestedRange: clientRequestedRange,
                        downloader: streamingDownloader,
                        responseState: responseState,
                        context: contextBox.context
                    )
                    return
                }

                if let assembledResponse = try await assembledResponse(for: request, downloader: downloader) {
                    let status: HTTPResponseStatus = clientRequestedRange ? .partialContent : .ok
                    responseState.markStarted()
                    responseWriter.writeCachedResponse(
                        assembledResponse,
                        status: status,
                        isHeadRequest: isHeadRequest,
                        context: contextBox.context
                    )
                    return
                }

                let response = try await downloadResponse(request: request, downloader: downloader)

                try await recordCacheWrite(data: response.data, request: request, responseHeaders: response.headers)

                if clientRequestedRange, let range = request.range {
                    responseState.markStarted()
                    responseWriter.writeDataResponse(
                        data: response.data,
                        range: range,
                        headers: response.headers,
                        isHeadRequest: isHeadRequest,
                        context: contextBox.context
                    )
                } else {
                    responseState.markStarted()
                    responseWriter.writeDataResponse(
                        data: response.data,
                        headers: response.headers,
                        isHeadRequest: isHeadRequest,
                        context: contextBox.context
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await HTTPMediaCache.addError(error, for: originalURL)
                if responseState.didStart {
                    contextBox.context.eventLoop.execute {
                        contextBox.context.close(promise: nil)
                    }
                } else {
                    responseWriter.writeNotFound(context: contextBox.context)
                }
            }
        }
        storeTask(task, id: taskID)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelRequestTasks()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        cancelRequestTasks()
        context.close(promise: nil)
    }

    private func originalURL(from uri: String) -> URL? {
        var components = uri.components(separatedBy: "/")
        guard components.count >= 3 else {
            return nil
        }

        let urlString = ProxyURLCodec.decode(components[1])
        guard let urlString, urlString.hasPrefix("http") else {
            return nil
        }

        if uri.contains("HTTPMediaCacheLastPathComponent") {
            return URL(string: urlString)
        }

        components.remove(at: 0)
        components.remove(at: 0)

        guard var baseURL = URL(string: urlString)?.deletingLastPathComponent() else {
            return nil
        }
        if uri.contains("HTTPMediaCachePlaceHolder") {
            components.remove(at: 0)
        } else {
            baseURL = baseURL.deletingLastPathComponent()
        }

        let lastPathComponent = components.joined(separator: "/")
        if lastPathComponent.hasPrefix("http") {
            return URL(string: lastPathComponent)
        }
        return baseURL.appendingPathComponent(lastPathComponent)
    }

    private func cacheRequest(for url: URL, headers: HTTPHeaders) async throws -> CacheRequest {
        var forwardedHeaders: [String: String] = [:]
        for header in headers {
            guard shouldForwardHeader(named: header.name) else {
                continue
            }
            forwardedHeaders[header.name] = header.value
        }

        let range = try await normalizedRange(from: headers.first(name: "Range"), url: url)
        if let range {
            forwardedHeaders["Range"] = range.requestHeaderValue
        }
        return CacheRequest(url: url, headers: forwardedHeaders, range: range)
    }

    private func cleanHLSDownloadRequest(for request: CacheRequest, originalURL: URL, proxyURI: String) async -> CacheRequest {
        let policy = HLSDownloadPolicy()
        if isHLSURL(originalURL) {
            return await policy.playlistRequest(from: request)
        }
        if let kind = ProxyURLCodec.hlsResourceKind(from: proxyURI) {
            return await policy.resourceRequest(url: request.url, kind: kind, range: ProxyURLCodec.hlsByteRange(from: proxyURI))
        }
        guard isHLSMediaSegmentURL(originalURL) else {
            return request
        }
        return await policy.mediaRequest(url: request.url, range: request.range)
    }

    private func shouldForwardHeader(named name: String) -> Bool {
        let blockedHeaders = [
            "Host",
            "Proxy-Connection",
            "Keep-Alive",
            "Transfer-Encoding",
            "TE",
            "Trailer",
            "Upgrade",
        ]
        return !blockedHeaders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func normalizedRange(from header: String?, url _: URL) async throws -> ByteRange? {
        guard let header else {
            return ByteRange(start: 0, end: nil)
        }

        guard let range = ByteRange(requestHeader: header) else {
            return nil
        }
        return range
    }

    private func downloadResponse(request: CacheRequest, downloader: any CacheDownloading) async throws -> CacheDownloadResponse {
        let response: CacheDownloadResponse
        if isHLSURL(request.url), let downloader = downloader as? any CacheHLSResponseDownloading {
            response = try await downloader.downloadHLSResponse(request: request)
        } else if let downloader = downloader as? any CacheResponseDownloading {
            response = try await downloader.downloadResponse(request: request)
        } else {
            let data = try await DataReader(downloader: downloader).read(request: request)
            response = CacheDownloadResponse(data: data, statusCode: 200, headers: [:])
        }

        try validateResponse(response, for: request)
        return response
    }

    private func cachedResponse(for request: CacheRequest) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        let normalizedRequest = request.normalizedForKnownTotalLength(item.totalLength)
        guard let range = normalizedRequest.range, range.end != nil else {
            return nil
        }

        guard let data = try await unit.read(range: range) else {
            return nil
        }

        var headers = await unit.cachedResponseHeaders()
        headers["Content-Length"] = "\(data.count)"
        headers["Content-Range"] = "bytes \(range.start)-\(range.end ?? range.start)/\(item.totalLength)"
        if headers.headerValue(for: "Accept-Ranges") == nil {
            headers["Accept-Ranges"] = "bytes"
        }

        return CachedProxyResponse(data: data, range: range, headers: headers)
    }

    private func assembledResponse(for request: CacheRequest, downloader: any CacheDownloading) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        let normalizedRequest = request.normalizedForKnownTotalLength(item.totalLength)
        guard let range = normalizedRequest.range, range.end != nil else {
            return nil
        }

        let chunkSize = await CacheRuntime.shared.requestHeaderRangeLength(for: normalizedRequest.url, totalLength: item.totalLength)
        let segments = await SourcePlanner().plan(request: range, cachedZones: unit.cachedZones())
        let hasFileSegment = segments.contains { segment in
            if case .file = segment {
                return true
            }
            return false
        }
        guard hasFileSegment || chunkSize > 0 else {
            return nil
        }

        var data = Data()
        var responseHeaders: [String: String] = [:]

        for segment in segments {
            switch segment {
            case let .file(fileRange):
                guard let cachedData = try await unit.read(range: fileRange) else {
                    return nil
                }
                data.append(cachedData)
            case let .network(networkRange):
                for chunkRange in NetworkRangeChunker.split(networkRange, maximumLength: chunkSize) {
                    let segmentRequest = normalizedRequest.replacingRange(chunkRange)
                    let response = try await downloadResponse(request: segmentRequest, downloader: downloader)
                    try await recordCacheWrite(data: response.data, request: segmentRequest, responseHeaders: response.headers)
                    responseHeaders.merge(response.headers) { _, newValue in newValue }
                    data.append(response.data)
                }
            }
        }

        let totalLength = responseHeaders.contentRangeTotalLength ?? item.totalLength
        if responseHeaders.headerValue(for: "Accept-Ranges") == nil {
            let cachedHeaders = await unit.cachedResponseHeaders()
            responseHeaders["Accept-Ranges"] = cachedHeaders.headerValue(for: "Accept-Ranges") ?? "bytes"
        }
        responseHeaders["Content-Length"] = "\(data.count)"
        if totalLength > 0, let end = range.end {
            responseHeaders["Content-Range"] = "bytes \(range.start)-\(end)/\(totalLength)"
        }
        let cachedHeaders = await unit.cachedResponseHeaders()
        for (field, value) in cachedHeaders where responseHeaders.headerValue(for: field) == nil {
            responseHeaders[field] = value
        }

        return CachedProxyResponse(data: data, range: range, headers: responseHeaders)
    }

    private func cachedFullResponse(for request: CacheRequest) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        guard item.totalLength > 0 else {
            return nil
        }

        let range = ByteRange(start: 0, end: item.totalLength - 1)
        guard let data = try await unit.read(range: range) else {
            return nil
        }

        var headers = await unit.cachedResponseHeaders()
        if headers.headerValue(for: "Accept-Ranges") == nil {
            headers["Accept-Ranges"] = "bytes"
        }
        headers["Content-Length"] = "\(data.count)"
        return CachedProxyResponse(data: data, range: range, headers: headers)
    }

    private func streamAssembledResponse(
        request: CacheRequest,
        clientRequestedRange: Bool,
        downloader: any CacheStreamingDownloading,
        responseState: ProxyResponseState,
        context: ChannelHandlerContext
    ) async throws -> Bool {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        let normalizedRequest = request.normalizedForKnownTotalLength(item.totalLength)
        guard let range = normalizedRequest.range, let rangeLength = range.length else {
            return false
        }

        let segments = await SourcePlanner().plan(request: range, cachedZones: unit.cachedZones())
        let hasFileSegment = segments.contains { segment in
            if case .file = segment {
                return true
            }
            return false
        }
        let hasNetworkSegment = segments.contains { segment in
            if case .network = segment {
                return true
            }
            return false
        }
        guard hasFileSegment, hasNetworkSegment else {
            return false
        }

        var headers = await unit.cachedResponseHeaders()
        headers["Accept-Ranges"] = headers.headerValue(for: "Accept-Ranges") ?? "bytes"
        headers["Content-Length"] = "\(rangeLength)"
        if item.totalLength > 0, let end = range.end {
            headers["Content-Range"] = "bytes \(range.start)-\(end)/\(item.totalLength)"
        }

        let status: HTTPResponseStatus = clientRequestedRange ? .partialContent : .ok
        responseState.markStarted()
        responseWriter.writeStreamingHead(status: status, headers: headers, range: range, context: context)

        let contextBox = ChannelHandlerContextBox(context)
        for segment in segments {
            try Task.checkCancellation()
            switch segment {
            case let .file(fileRange):
                guard let cachedData = try await unit.read(range: fileRange) else {
                    throw CacheError.storageFailure("Missing cached data for \(request.url.absoluteString).")
                }
                responseWriter.writeBody(cachedData, context: contextBox.context)
            case let .network(networkRange):
                let segmentRequest = normalizedRequest.replacingRange(networkRange)
                let response = try await downloader.streamResponse(request: segmentRequest)
                try validateStreamingResponse(response, for: segmentRequest)
                try await streamNetworkSegment(
                    response: response,
                    request: segmentRequest,
                    cacheIndex: cacheIndex,
                    context: contextBox.context
                )
            }
        }

        responseWriter.writeEnd(context: contextBox.context)
        return true
    }

    private func streamResponse(
        request: CacheRequest,
        clientRequestedRange: Bool,
        downloader: any CacheStreamingDownloading,
        responseState: ProxyResponseState,
        context: ChannelHandlerContext
    ) async throws {
        let response = try await downloader.streamResponse(request: request)
        try validateStreamingResponse(response, for: request)
        try await prepareCacheCapacity(for: response.headers, request: request)
        let status: HTTPResponseStatus = clientRequestedRange ? .partialContent : .ok
        responseState.markStarted()
        responseWriter.writeStreamingHead(status: status, headers: response.headers, range: request.range, context: context)

        try await withTaskCancellationHandler {
            let contextBox = ChannelHandlerContextBox(context)
            let cacheIndex = await CacheRuntime.shared.cacheIndex
            let cacheWriter = StreamingCacheWriter(
                request: request,
                responseHeaders: response.headers,
                cacheIndex: cacheIndex
            )
            let pump = StreamingProxyBodyPump(
                cacheWriter: { data, offset in
                    try await cacheWriter.write(data: data, offset: offset)
                },
                bodyWriter: { [responseWriter] data in
                    responseWriter.writeBody(data, context: contextBox.context)
                },
                endWriter: { [responseWriter] in
                    responseWriter.writeEnd(context: contextBox.context)
                }
            )
            do {
                try await pump.write(body: response.body, initialOffset: resolvedStartOffset(for: request, responseHeaders: response.headers))
                await cacheWriter.finish()
            } catch {
                await cacheWriter.finish()
                throw error
            }
        } onCancel: {
            response.cancel?()
        }
    }

    private func streamNetworkSegment(
        response: CacheStreamResponse,
        request: CacheRequest,
        cacheIndex: CacheIndex,
        context: ChannelHandlerContext
    ) async throws {
        try await withTaskCancellationHandler {
            let contextBox = ChannelHandlerContextBox(context)
            let cacheWriter = StreamingCacheWriter(
                request: request,
                responseHeaders: response.headers,
                cacheIndex: cacheIndex
            )
            let pump = StreamingProxyBodyPump(
                cacheWriter: { data, offset in
                    try await cacheWriter.write(data: data, offset: offset)
                },
                bodyWriter: { [responseWriter] data in
                    responseWriter.writeBody(data, context: contextBox.context)
                },
                endWriter: {}
            )
            do {
                try await pump.write(body: response.body, initialOffset: resolvedStartOffset(for: request, responseHeaders: response.headers))
                await cacheWriter.finish()
            } catch {
                await cacheWriter.finish()
                throw error
            }
        } onCancel: {
            response.cancel?()
        }
    }

    private func writeHeaderResponse(
        request: CacheRequest,
        clientRequestedRange: Bool,
        downloader: any CacheHeaderDownloading,
        responseState: ProxyResponseState,
        context: ChannelHandlerContext
    ) async throws {
        let response = try await downloader.downloadHeaderResponse(request: request)
        try validateHeaderResponse(response, for: request)
        let status: HTTPResponseStatus = clientRequestedRange ? .partialContent : .ok
        responseState.markStarted()
        responseWriter.writeHeadOnly(status: status, headers: response.headers, context: context)
    }

    private func writeStreamingHeadResponse(
        request: CacheRequest,
        clientRequestedRange: Bool,
        downloader: any CacheStreamingDownloading,
        responseState: ProxyResponseState,
        context: ChannelHandlerContext
    ) async throws {
        let response = try await downloader.streamResponse(request: request)
        defer {
            response.cancel?()
        }

        try validateStreamingResponse(response, for: request)
        let status: HTTPResponseStatus = clientRequestedRange ? .partialContent : .ok
        responseState.markStarted()
        responseWriter.writeHeadOnly(status: status, headers: response.headers, context: context)
    }

    private func storeTask(_ task: Task<Void, Never>, id: UUID) {
        taskLock.lock()
        requestTasks[id] = task
        taskLock.unlock()
    }

    private func removeTask(id: UUID) {
        taskLock.lock()
        requestTasks[id] = nil
        taskLock.unlock()
    }

    private func cancelRequestTasks() {
        taskLock.lock()
        let tasks = Array(requestTasks.values)
        requestTasks.removeAll()
        taskLock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    private func writeHLSResponse(
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
            let response = try await downloadResponse(request: request, downloader: downloader)
            var rawHeaders = response.headers
            rawHeaders["Content-Length"] = "\(response.data.count)"
            try await recordCacheWrite(data: response.data, offset: 0, request: request, responseHeaders: rawHeaders, end: Int64(response.data.count) - 1)
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

    private func validateResponse(_ response: CacheDownloadResponse, for request: CacheRequest) throws {
        guard let range = request.range,
              !range.isSuffixRange,
              let requestedEnd = range.end,
              let expectedLength = range.length
        else {
            return
        }

        let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength ?? Int64(response.data.count)
        guard requestedEnd < totalLength else {
            return
        }

        let contentLength = response.headers.contentLength ?? Int64(response.data.count)
        guard contentLength == expectedLength else {
            throw CacheError.networkFailure("Mismatched Content-Length for \(request.url.absoluteString).")
        }
    }

    private func validateStreamingResponse(_ response: CacheStreamResponse, for request: CacheRequest) throws {
        guard let range = request.range,
              !range.isSuffixRange,
              let requestedEnd = range.end,
              let expectedLength = range.length,
              let contentLength = response.headers.contentLength,
              let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength,
              requestedEnd < totalLength
        else {
            return
        }

        guard contentLength == expectedLength else {
            throw CacheError.networkFailure("Mismatched Content-Length for \(request.url.absoluteString).")
        }
    }

    private func validateHeaderResponse(_ response: CacheHeaderResponse, for request: CacheRequest) throws {
        guard response.statusCode <= 400 else {
            throw CacheError.networkFailure("HTTP \(response.statusCode) for \(request.url.absoluteString).")
        }
        try validateStreamingResponse(
            CacheStreamResponse(
                statusCode: response.statusCode,
                headers: response.headers,
                body: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            ),
            for: request
        )
    }

    private func resolvedStartOffset(for request: CacheRequest, responseHeaders: [String: String]) -> Int64 {
        if request.range?.isSuffixRange == true {
            return responseHeaders.contentRangeStart ?? 0
        }
        return request.range?.start ?? 0
    }

    private func isHLSURL(_ url: URL) -> Bool {
        url.absoluteString.range(of: ".m3u", options: [.caseInsensitive]) != nil
    }

    private func isHLSMediaSegmentURL(_ url: URL) -> Bool {
        let segmentExtensions = [
            "ts",
            "m4s",
            "m4a",
            "aac",
            "vtt",
            "webvtt",
        ]
        return segmentExtensions.contains(url.pathExtension.lowercased())
    }

    private func proxyPort(from headers: HTTPHeaders, localPort: Int?) -> UInt16 {
        if let port = localPort {
            return UInt16(port)
        }

        guard let host = headers.first(name: "Host") else {
            return 0
        }

        let portText: String
        if host.hasPrefix("[") {
            guard let closingBracket = host.firstIndex(of: "]") else {
                return 0
            }
            let nextIndex = host.index(after: closingBracket)
            guard nextIndex < host.endIndex, host[nextIndex] == ":" else {
                return 0
            }
            portText = String(host[host.index(after: nextIndex)...])
        } else {
            guard let colonIndex = host.lastIndex(of: ":") else {
                return 0
            }
            portText = String(host[host.index(after: colonIndex)...])
        }

        return UInt16(portText) ?? 0
    }

    private func recordCacheWrite(data: Data, request: CacheRequest, responseHeaders: [String: String]) async throws {
        guard !data.isEmpty else {
            return
        }

        let start = request.range?.isSuffixRange == true ? responseHeaders.contentRangeStart ?? 0 : request.range?.start ?? 0
        let end = start + Int64(data.count) - 1
        try await recordCacheWrite(data: data, offset: start, request: request, responseHeaders: responseHeaders, end: end)
    }

    private func prepareCacheCapacity(for responseHeaders: [String: String], request: CacheRequest) async throws {
        guard let contentLength = responseHeaders.contentLength, contentLength > 0 else {
            return
        }

        let cacheIndex = await CacheRuntime.shared.cacheIndex
        try await cacheIndex.prepareForWrite(length: contentLength, excluding: request.url)
    }

    private func recordCacheWrite(
        data: Data,
        offset: Int64,
        request: CacheRequest,
        responseHeaders: [String: String],
        end explicitEnd: Int64? = nil
    ) async throws {
        guard !data.isEmpty else {
            return
        }

        let end = explicitEnd ?? offset + Int64(data.count) - 1
        let totalLength = responseHeaders.contentRangeTotalLength ?? responseHeaders.contentLength ?? max(end + 1, Int64(data.count))
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        do {
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

private struct CachedProxyResponse {
    var data: Data
    var range: ByteRange
    var headers: [String: String]
}

private struct CachedHLSPlaylistResponse {
    var data: Data
    var headers: [String: String]
}

private final class ProxyResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false

    var didStart: Bool {
        lock.lock()
        let value = hasStarted
        lock.unlock()
        return value
    }

    func markStarted() {
        lock.lock()
        hasStarted = true
        lock.unlock()
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

private extension HTTPResponseWriter {
    func writeCachedResponse(_ response: CachedProxyResponse, status: HTTPResponseStatus, isHeadRequest: Bool, context: ChannelHandlerContext) {
        if isHeadRequest {
            writeHeadOnly(status: status, headers: response.headers, context: context)
        } else if status == .partialContent {
            writePartialContent(data: response.data, range: response.range, headers: response.headers, context: context)
        } else {
            writeOK(data: response.data, headers: response.headers, context: context)
        }
    }

    func writeDataResponse(data: Data, range: ByteRange? = nil, headers: [String: String], isHeadRequest: Bool, context: ChannelHandlerContext) {
        if let range {
            if isHeadRequest {
                let start = range.isSuffixRange ? headers.contentRangeStart ?? 0 : range.start
                let end = start + Int64(data.count) - 1
                var headHeaders = headers
                headHeaders["Accept-Ranges"] = headHeaders.headerValue(for: "Accept-Ranges") ?? "bytes"
                headHeaders["Content-Length"] = "\(data.count)"
                headHeaders["Content-Range"] = headHeaders.headerValue(for: "Content-Range") ?? "bytes \(start)-\(end)/*"
                writeHeadOnly(status: .partialContent, headers: headHeaders, context: context)
            } else {
                writePartialContent(data: data, range: range, headers: headers, context: context)
            }
        } else if isHeadRequest {
            var headHeaders = headers
            headHeaders["Content-Length"] = "\(data.count)"
            writeHeadOnly(status: .ok, headers: headHeaders, context: context)
        } else {
            writeOK(data: data, headers: headers, context: context)
        }
    }
}

private extension HTTPURLResponse {
    var headerDictionary: [String: String] {
        allHeaderFields.reduce(into: [String: String]()) { result, header in
            guard let name = header.key as? String else {
                return
            }
            result[name] = "\(header.value)"
        }
    }
}

private struct ChannelHandlerContextBox: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}
