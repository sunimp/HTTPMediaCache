//
//  FilePreloadExecutor.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct FilePreloadExecutor {
    let request: CacheRequest
    let limit: PreloadOptions.FileLimit
    let downloader: any CacheDownloading
    let cacheIndex: CacheIndex
    let progress: PreloadProgress

    func run() async throws {
        switch limit {
        case .all:
            try await runFullPreload()
        case let .byteCount(byteCount):
            try await runByteLimitedPreload(byteCount: byteCount)
        }
    }

    private func runFullPreload() async throws {
        if try await isRequestCached(request) {
            progress.yield(1)
            return
        }

        if let downloader = downloader as? any CacheStreamingDownloading {
            try await streamPreload(request: request, downloader: downloader)
            return
        }

        let response = try await downloadResponse(request)
        try Task.checkCancellation()
        try await write(data: response.data, request: request, responseHeaders: response.headers)
        progress.yield(1)
    }

    private func runByteLimitedPreload(byteCount: Int64) async throws {
        guard byteCount > 0 else {
            throw CacheError.invalidRange
        }

        let start = request.range?.isSuffixRange == true ? 0 : request.range?.start ?? 0
        let totalLength = try await totalLengthForByteLimitedPreload(start: start)
        let unit = try await cacheIndex.unit(for: request.url)
        var cachedZones = await unit.cachedZones()
        let planner = FilePreloadPlanner()
        var plan = try planner.plan(
            requestedStart: start,
            requestedByteCount: byteCount,
            totalLength: totalLength,
            cachedZones: cachedZones
        )

        if !isCached(range: FilePreloadPlanner.probeRange, in: cachedZones), start == 0 {
            let probeRequest = CacheRequest(
                url: request.url,
                headers: request.headers.removingRangeHeader(),
                range: FilePreloadPlanner.probeRange
            )
            let probeResponse = try await downloadResponse(probeRequest)
            try Task.checkCancellation()
            try await write(data: probeResponse.data, request: probeRequest, responseHeaders: probeResponse.headers)
            cachedZones = await unit.cachedZones()
            plan = try planner.plan(
                requestedStart: start,
                requestedByteCount: byteCount,
                totalLength: totalLength,
                cachedZones: cachedZones
            )
        }

        let targetLength = plan.targetLength
        let chunkLength = planner.chunkLength(forTargetLength: targetLength)
        var loadedLength = cachedLength(in: plan.targetRange, cachedZones: cachedZones)
        if loadedLength >= targetLength {
            progress.yield(1)
            return
        }

        for range in plan.missingRanges {
            for chunkRange in NetworkRangeChunker.split(range, maximumLength: chunkLength) {
                try Task.checkCancellation()
                let chunkRequest = CacheRequest(
                    url: request.url,
                    headers: request.headers.removingRangeHeader(),
                    range: chunkRange
                )
                let response = try await downloadResponse(chunkRequest)
                try Task.checkCancellation()
                try await write(data: response.data, request: chunkRequest, responseHeaders: response.headers)
                loadedLength += Int64(response.data.count)
                progress.yield(min(Double(loadedLength) / Double(targetLength), 1))
            }
        }
    }

    private func totalLengthForByteLimitedPreload(start: Int64) async throws -> Int64 {
        if let item = try await cacheIndex.cacheItem(for: request.url), item.totalLength > start {
            return item.totalLength
        }

        let probeRequest = CacheRequest(
            url: request.url,
            headers: request.headers.removingRangeHeader(),
            range: FilePreloadPlanner.probeRange
        )
        let response = try await downloadResponse(probeRequest)
        try Task.checkCancellation()
        try await write(data: response.data, request: probeRequest, responseHeaders: response.headers)
        let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength ?? Int64(response.data.count)
        guard totalLength > start else {
            throw CacheError.networkFailure("File preload probe did not return a valid total length: \(request.url.absoluteString).")
        }
        return totalLength
    }

    private func streamPreload(
        request: CacheRequest,
        downloader: any CacheStreamingDownloading
    ) async throws {
        let response = try await downloader.streamResponse(request: request)
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
                    try await unit.write(
                        data: chunk,
                        offset: offset,
                        totalLength: totalLength > 0 ? totalLength : offset + Int64(chunk.count),
                        responseHeaders: response.headers
                    )
                    offset += Int64(chunk.count)
                    loadedLength += Int64(chunk.count)
                    if let contentLength = response.headers.contentLength, contentLength > 0 {
                        progress.yield(min(Double(loadedLength) / Double(contentLength), 1))
                    }
                }
                if response.headers.contentLength == nil {
                    progress.yield(1)
                }
            } onCancel: {
                response.cancel?()
            }
            await unit.workingRelease()
        } catch {
            await unit.workingRelease()
            throw error
        }
    }

    private func downloadResponse(_ request: CacheRequest) async throws -> CacheDownloadResponse {
        if let downloader = downloader as? any CacheResponseDownloading {
            return try await downloader.downloadResponse(request: request)
        }

        let data = try await DataReader(downloader: downloader).read(request: request)
        return CacheDownloadResponse(data: data, statusCode: 200, headers: ["Content-Length": "\(data.count)"])
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

    private func isRequestCached(_ request: CacheRequest) async throws -> Bool {
        guard let item = try await cacheIndex.cacheItem(for: request.url), item.totalLength > 0 else {
            return false
        }

        let requestedRange = request.range ?? ByteRange(start: 0)
        let normalizedRange: ByteRange
        if requestedRange.isSuffixRange {
            guard let suffixLength = requestedRange.end else {
                return false
            }
            let start = max(item.totalLength - suffixLength, 0)
            normalizedRange = ByteRange(start: start, end: item.totalLength - 1)
        } else {
            normalizedRange = requestedRange.normalized(totalLength: item.totalLength)
        }

        return isCached(range: normalizedRange, in: item.zones)
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

    private func cachedLength(in targetRange: ByteRange, cachedZones: [ByteRange]) -> Int64 {
        cachedZones.reduce(Int64(0)) { partial, zone in
            guard let targetEnd = targetRange.end, let zoneEnd = zone.end else {
                return partial
            }
            let start = max(targetRange.start, zone.start)
            let end = min(targetEnd, zoneEnd)
            guard start <= end else {
                return partial
            }
            return partial + end - start + 1
        }
    }
}
