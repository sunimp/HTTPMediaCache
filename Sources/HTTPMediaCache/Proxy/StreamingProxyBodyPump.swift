//
//  StreamingProxyBodyPump.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct StreamingProxyBodyPump {
    typealias CacheWriter = @Sendable (Data, Int64) async throws -> Void
    typealias BodyWriter = @Sendable (Data) async throws -> Void
    typealias EndWriter = @Sendable () async throws -> Void

    private let cacheWriter: CacheWriter
    private let bodyWriter: BodyWriter
    private let endWriter: EndWriter

    init(
        cacheWriter: @escaping CacheWriter,
        bodyWriter: @escaping BodyWriter,
        endWriter: @escaping EndWriter
    ) {
        self.cacheWriter = cacheWriter
        self.bodyWriter = bodyWriter
        self.endWriter = endWriter
    }

    func write(body: AsyncThrowingStream<Data, Error>, initialOffset: Int64) async throws {
        var offset = initialOffset
        let cacheWrites = AsyncStream<(Data, Int64)>.makeStream()
        let cacheTask = Task {
            for await (data, offset) in cacheWrites.stream {
                try await cacheWriter(data, offset)
            }
        }

        do {
            for try await data in body {
                try Task.checkCancellation()
                guard !data.isEmpty else {
                    continue
                }

                let currentOffset = offset
                try await bodyWriter(data)
                cacheWrites.continuation.yield((data, currentOffset))
                offset += Int64(data.count)
            }
        } catch {
            cacheWrites.continuation.finish()
            cacheTask.cancel()
            throw error
        }

        cacheWrites.continuation.finish()
        do {
            try await cacheTask.value
            try await endWriter()
        } catch {
            cacheTask.cancel()
            throw error
        }
    }
}

actor StreamingCacheWriter {
    private let request: CacheRequest
    private let responseHeaders: [String: String]
    private let cacheIndex: CacheIndex

    private var unit: CacheUnit?
    private var handle: FileHandle?
    private var isDisabled = false

    init(request: CacheRequest, responseHeaders: [String: String], cacheIndex: CacheIndex) {
        self.request = request
        self.responseHeaders = responseHeaders
        self.cacheIndex = cacheIndex
    }

    func write(data: Data, offset: Int64) async throws {
        guard !isDisabled, !data.isEmpty else {
            return
        }

        do {
            try await prepareIfNeeded(firstChunkLength: Int64(data.count))
            guard let unit, let handle else {
                return
            }

            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)

            let end = offset + Int64(data.count) - 1
            let totalLength = responseHeaders.contentRangeTotalLength ?? responseHeaders.contentLength ?? max(end + 1, Int64(data.count))
            try await unit.recordStreamingWrite(
                range: ByteRange(start: offset, end: end),
                totalLength: totalLength,
                responseHeaders: responseHeaders
            )
        } catch {
            isDisabled = true
            await close()
            throw error
        }
    }

    func finish() async {
        await close(persistsMetadata: true)
    }

    private func prepareIfNeeded(firstChunkLength: Int64) async throws {
        guard unit == nil, handle == nil else {
            return
        }

        let desiredLength = responseHeaders.contentLength ?? firstChunkLength
        try await cacheIndex.prepareForWrite(length: desiredLength, excluding: request.url)

        let unit = try await cacheIndex.unit(for: request.url)
        await unit.workingRetain()
        let fileURL = await unit.writableDataFileURL()
        handle = try FileHandle(forWritingTo: fileURL)
        self.unit = unit
    }

    private func close(persistsMetadata: Bool = false) async {
        if let handle {
            try? handle.close()
            self.handle = nil
        }

        guard let unit else {
            return
        }
        if persistsMetadata {
            try? await unit.finishStreamingWrite()
        }
        await unit.workingRelease()
        self.unit = nil
    }
}
