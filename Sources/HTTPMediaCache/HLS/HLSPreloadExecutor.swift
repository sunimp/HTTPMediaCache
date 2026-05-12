//
//  HLSPreloadExecutor.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct HLSPreloadExecutor {
    let request: CacheRequest
    let options: PreloadOptions
    let downloader: any CacheDownloading
    let cacheIndex: CacheIndex
    let progress: PreloadProgress
    private let downloadPolicy = HLSDownloadPolicy()

    func run() async throws {
        try await preload(
            request: request,
            progressBase: 0,
            progressSpan: 1
        )
        try Task.checkCancellation()
        progress.yield(1)
    }

    private func preload(
        request: CacheRequest,
        progressBase: Double,
        progressSpan: Double
    ) async throws {
        let playlistRequest = await downloadPolicy.playlistRequest(from: request)
        let data = try await loadAndCachePlaylist(request: playlistRequest)
        guard let content = String(data: data, encoding: .utf8) else {
            throw CacheError.networkFailure("HLS playlist is not UTF-8: \(playlistRequest.url.absoluteString).")
        }

        let playlist = HLSPlaylistParser().parse(playlist: content, sourceURL: playlistRequest.url)
        let planner = HLSPreloadPlanner()
        let plan = await planner.plan(playlist: playlist, options: options, originalURL: playlistRequest.url, currentURL: playlistRequest.url)

        switch plan {
        case let .childPlaylists(childRequests):
            try await preloadChildPlaylists(childRequests, progressBase: progressBase, progressSpan: progressSpan)
        case let .media(mediaPlan):
            try await preloadMediaPlan(mediaPlan, progressBase: progressBase, progressSpan: progressSpan)
        }
    }

    private func preloadChildPlaylists(
        _ childRequests: [CacheRequest],
        progressBase: Double,
        progressSpan: Double
    ) async throws {
        let childCount = max(childRequests.count, 1)
        for (index, childRequest) in childRequests.enumerated() {
            let childBase = progressBase + progressSpan * Double(index) / Double(childCount)
            let childSpan = progressSpan / Double(childCount)
            try await preload(request: childRequest, progressBase: childBase, progressSpan: childSpan)
        }
    }

    private func preloadMediaPlan(
        _ plan: HLSMediaPreloadPlan,
        progressBase: Double,
        progressSpan: Double
    ) async throws {
        guard plan.targetSegments > 0 else {
            progress.yield(progressBase + progressSpan)
            return
        }

        var loadedSegments = 0
        var loadedDuration: TimeInterval = 0
        var loadedBytes: Int64 = 0
        for action in plan.actions {
            try Task.checkCancellation()
            if loadedSegments > 0,
               !plan.policy.shouldLoadMoreSegments(
                   loadedSegments: loadedSegments,
                   loadedDuration: loadedDuration,
                   loadedBytes: loadedBytes
               )
            {
                progress.yield(progressBase + progressSpan)
                return
            }

            let loadedLength = try await preloadResource(action.reference) { partialLength, expectedLength in
                guard action.reference.type == .segment else {
                    return
                }
                yieldSegmentProgress(
                    plan: plan,
                    progressBase: progressBase,
                    progressSpan: progressSpan,
                    loadedSegments: loadedSegments,
                    loadedDuration: loadedDuration,
                    loadedBytes: loadedBytes,
                    reference: action.reference,
                    partialLength: partialLength,
                    expectedLength: expectedLength
                )
            }
            if action.reference.type == .segment {
                loadedSegments += 1
                loadedDuration += action.reference.duration ?? 0
                loadedBytes += loadedLength
                progress.yield(progressBase + progressSpan * plan.policy.progressValue(
                    loadedSegments: loadedSegments,
                    loadedDuration: loadedDuration,
                    loadedBytes: loadedBytes,
                    targetSegments: plan.targetSegments
                ))
            }
        }
    }

    private func loadAndCachePlaylist(request: CacheRequest) async throws -> Data {
        if let cachedData = try await cachedCompleteData(for: request) {
            return cachedData
        }

        let response = try await downloadResponse(request)
        guard String(data: response.data, encoding: .utf8) != nil else {
            throw CacheError.networkFailure("HLS playlist is not UTF-8: \(request.url.absoluteString).")
        }

        var headers = response.headers
        headers["Content-Length"] = "\(response.data.count)"
        try await write(data: response.data, request: request, responseHeaders: headers)
        return response.data
    }

    private func cachedCompleteData(for request: CacheRequest) async throws -> Data? {
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

    private func yieldSegmentProgress(
        plan: HLSMediaPreloadPlan,
        progressBase: Double,
        progressSpan: Double,
        loadedSegments: Int,
        loadedDuration: TimeInterval,
        loadedBytes: Int64,
        reference: HLSResourceReference,
        partialLength: Int64,
        expectedLength: Int64?
    ) {
        let progressValue: Double
        switch plan.policy.limit {
        case .all, .segmentCount:
            guard plan.targetSegments > 0 else {
                return
            }
            let fraction = segmentFraction(partialLength: partialLength, expectedLength: expectedLength)
            progressValue = min((Double(loadedSegments) + fraction) / Double(plan.targetSegments), 1)
        case let .duration(duration):
            guard duration > 0 else {
                return
            }
            let fraction = segmentFraction(partialLength: partialLength, expectedLength: expectedLength)
            progressValue = min((loadedDuration + (reference.duration ?? 0) * fraction) / duration, 1)
        case let .byteCount(byteCount):
            guard byteCount > 0 else {
                return
            }
            progressValue = min(Double(loadedBytes + partialLength) / Double(byteCount), 1)
        }
        progress.yield(progressBase + progressSpan * progressValue)
    }

    private func segmentFraction(partialLength: Int64, expectedLength: Int64?) -> Double {
        guard let expectedLength, expectedLength > 0 else {
            return 0
        }
        return min(Double(partialLength) / Double(expectedLength), 1)
    }

    private func preloadResource(
        _ reference: HLSResourceReference,
        onProgress: ((Int64, Int64?) -> Void)? = nil
    ) async throws -> Int64 {
        let request = await downloadPolicy.resourceRequest(for: reference)
        if let cachedLength = try await cachedLengthIfFullyCached(request: request) {
            onProgress?(cachedLength, cachedLength)
            return cachedLength
        }

        if let streamingDownloader = downloader as? any CacheStreamingDownloading {
            return try await streamPreloadResource(
                request: request,
                downloader: streamingDownloader,
                onProgress: onProgress
            )
        }

        let data = try await DataReader(
            request: request,
            cacheIndex: cacheIndex,
            downloader: downloader
        ).read()
        onProgress?(Int64(data.count), Int64(data.count))
        return Int64(data.count)
    }

    private func streamPreloadResource(
        request: CacheRequest,
        downloader: any CacheStreamingDownloading,
        onProgress: ((Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        let response = try await downloader.streamResponse(request: request)
        let expectedLength = request.range?.length ?? response.headers.contentLength
        let unit = try await cacheIndex.unit(for: request.url)
        let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength ?? 0
        if let contentLength = response.headers.contentLength, contentLength > 0 {
            try await cacheIndex.prepareForWrite(length: contentLength, excluding: request.url)
        }

        var offset = request.range?.isSuffixRange == true ? response.headers.contentRangeStart ?? 0 : request.range?.start ?? 0
        var loadedLength: Int64 = 0
        await unit.workingRetain()
        do {
            try await withTaskCancellationHandler {
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    guard !chunk.isEmpty else {
                        continue
                    }

                    if response.headers.contentLength == nil {
                        try await cacheIndex.prepareForWrite(length: Int64(chunk.count), excluding: request.url)
                    }
                    let chunkLength = Int64(chunk.count)
                    try await unit.write(
                        data: chunk,
                        offset: offset,
                        totalLength: totalLength > 0 ? totalLength : offset + chunkLength,
                        responseHeaders: response.headers
                    )
                    offset += chunkLength
                    loadedLength += chunkLength
                    onProgress?(loadedLength, expectedLength)
                }
            } onCancel: {
                response.cancel?()
            }
            await unit.workingRelease()
            return loadedLength
        } catch {
            await unit.workingRelease()
            throw error
        }
    }

    private func cachedLengthIfFullyCached(request: CacheRequest) async throws -> Int64? {
        let unit = try await cacheIndex.unit(for: request.url)
        let item = await unit.cacheItem()
        guard item.totalLength > 0 else {
            return nil
        }

        let range: ByteRange
        if let requestRange = request.range {
            range = requestRange.normalized(totalLength: item.totalLength)
        } else {
            range = ByteRange(start: 0, end: item.totalLength - 1)
        }

        guard isCached(range: range, in: item.zones), let length = range.length else {
            return nil
        }
        return length
    }

    private func isCached(range: ByteRange, in cachedZones: [ByteRange]) -> Bool {
        guard let requestedEnd = range.end else {
            return false
        }

        return cachedZones.contains { zone in
            guard let zoneEnd = zone.end else {
                return false
            }
            return zone.start <= range.start && zoneEnd >= requestedEnd
        }
    }

    private func downloadResponse(_ request: CacheRequest) async throws -> CacheDownloadResponse {
        if let downloader = downloader as? any CacheHLSResponseDownloading {
            return try await downloader.downloadHLSResponse(request: request)
        }

        if let downloader = downloader as? any CacheResponseDownloading {
            return try await downloader.downloadResponse(request: request)
        }

        let data = try await DataReader(downloader: downloader).read(request: request)
        return CacheDownloadResponse(data: data, statusCode: 200, headers: [:])
    }

    private func write(data: Data, request: CacheRequest, responseHeaders: [String: String]) async throws {
        guard !data.isEmpty else {
            return
        }

        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        let offset = request.range?.isSuffixRange == true ? responseHeaders.contentRangeStart ?? 0 : request.range?.start ?? 0
        let end = offset + Int64(data.count) - 1
        let totalLength = responseHeaders.contentRangeTotalLength ?? responseHeaders.contentLength ?? max(end + 1, Int64(data.count))
        do {
            try await cacheIndex.prepareForWrite(length: Int64(data.count), excluding: request.url)
            try await unit.write(data: data, offset: offset, totalLength: totalLength, responseHeaders: responseHeaders)
            await unit.workingRelease()
        } catch {
            await unit.workingRelease()
            throw error
        }
    }
}
