//
//  ProxyCacheWriter.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

enum ProxyCacheWriter {
    static func record(data: Data, request: CacheRequest, responseHeaders: [String: String]) async throws {
        guard !data.isEmpty else {
            return
        }

        let start = request.range?.isSuffixRange == true ? responseHeaders.contentRangeStart ?? 0 : request.range?.start ?? 0
        let end = start + Int64(data.count) - 1
        try await record(data: data, offset: start, request: request, responseHeaders: responseHeaders, end: end)
    }

    static func prepareCapacity(for responseHeaders: [String: String], request: CacheRequest) async throws {
        guard let contentLength = responseHeaders.contentLength, contentLength > 0 else {
            return
        }

        let cacheIndex = await CacheRuntime.shared.cacheIndex
        try await cacheIndex.prepareForWrite(length: contentLength, excluding: request.url)
    }

    static func resolvedStartOffset(for request: CacheRequest, responseHeaders: [String: String]) -> Int64 {
        if request.range?.isSuffixRange == true {
            return responseHeaders.contentRangeStart ?? 0
        }
        return request.range?.start ?? 0
    }

    static func record(
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
