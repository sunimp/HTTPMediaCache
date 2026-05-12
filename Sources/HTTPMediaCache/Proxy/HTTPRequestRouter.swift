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

        guard let originalURL = ProxyRequestParser.originalURL(from: head.uri) else {
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
                let requestContext = try await ProxyRequestParser.makeContext(
                    head: head,
                    originalURL: originalURL,
                    localPort: localPort
                )
                let isHeadRequest = requestContext.isHeadRequest
                let clientRequestedRange = requestContext.clientRequestedRange
                let request = requestContext.request
                let hlsDownloadRequest = requestContext.hlsDownloadRequest
                let hlsResourceKind = requestContext.hlsResourceKind

                if ProxyRequestClassifier.isHLSURL(originalURL) {
                    try await HLSProxyResponder(responseWriter: responseWriter).writeResponse(
                        for: hlsDownloadRequest,
                        isHeadRequest: isHeadRequest,
                        proxyPort: requestContext.proxyPort,
                        responseState: responseState,
                        context: contextBox.context
                    )
                    return
                }

                let cacheResponder = ProxyCacheResponder()
                if !clientRequestedRange, let cachedResponse = try await cacheResponder.cachedFullResponse(for: request) {
                    responseState.markStarted()
                    responseWriter.writeCachedResponse(cachedResponse, status: .ok, isHeadRequest: isHeadRequest, context: contextBox.context)
                    return
                }

                if let cachedResponse = try await cacheResponder.cachedResponse(for: request) {
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
                    let response = try await ProxyOriginDownloader.downloadResponse(request: hlsDownloadRequest, downloader: responseDownloader)
                    try await ProxyCacheWriter.record(data: response.data, request: hlsDownloadRequest, responseHeaders: response.headers)
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
                   ProxyRequestClassifier.isHLSMediaSegmentURL(originalURL),
                   let responseDownloader = downloader as? any CacheResponseDownloading
                {
                    let response = try await ProxyOriginDownloader.downloadResponse(request: hlsDownloadRequest, downloader: responseDownloader)
                    try await ProxyCacheWriter.record(data: response.data, request: hlsDownloadRequest, responseHeaders: response.headers)
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

                let response = try await ProxyOriginDownloader.downloadResponse(request: request, downloader: downloader)

                try await ProxyCacheWriter.record(data: response.data, request: request, responseHeaders: response.headers)

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

    private func assembledResponse(for request: CacheRequest, downloader: any CacheDownloading) async throws -> CachedProxyResponse? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        let normalizedRequest = request.proxyNormalizedForKnownTotalLength(item.totalLength)
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
                    let segmentRequest = normalizedRequest.proxyReplacingRange(chunkRange)
                    let response = try await ProxyOriginDownloader.downloadResponse(request: segmentRequest, downloader: downloader)
                    try await ProxyCacheWriter.record(data: response.data, request: segmentRequest, responseHeaders: response.headers)
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
        let normalizedRequest = request.proxyNormalizedForKnownTotalLength(item.totalLength)
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
                let segmentRequest = normalizedRequest.proxyReplacingRange(networkRange)
                let response = try await downloader.streamResponse(request: segmentRequest)
                try ProxyResponseValidator.validateStreamingResponse(response, for: segmentRequest)
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
        try ProxyResponseValidator.validateStreamingResponse(response, for: request)
        try await ProxyCacheWriter.prepareCapacity(for: response.headers, request: request)
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
                try await pump.write(body: response.body, initialOffset: ProxyCacheWriter.resolvedStartOffset(for: request, responseHeaders: response.headers))
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
                try await pump.write(body: response.body, initialOffset: ProxyCacheWriter.resolvedStartOffset(for: request, responseHeaders: response.headers))
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
        try ProxyResponseValidator.validateHeaderResponse(response, for: request)
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

        try ProxyResponseValidator.validateStreamingResponse(response, for: request)
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
}
