//
//  ProxyRangeResponseTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
@testable import HTTPMediaCache
import XCTest
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class ProxyRangeResponseTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.stop()
        await HTTPMediaCache.setDownloadRequestHeaderRangeLength(nil)
        await HTTPMediaCache.setMaxCacheLength(CacheIndex.defaultMaxCacheLength)
        await HTTPMediaCache.setHLSDownloadHeaderProvider(nil)
        try await super.tearDown()
    }

    func testInvalidProxyPathReturns404() async throws {
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        let invalid = try XCTUnwrap(URL(string: "http://\(proxy.host!):\(proxy.port!)/invalid"))
        let (_, response) = try await URLSession.shared.data(from: invalid)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testValidProxyPathUsesFullRangeInternallyButReturnsOK() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = RangeAssertingDownloader(expectedRange: ByteRange(start: 0, end: nil), data: Data(repeating: 7, count: 4))
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        let (data, response) = try await URLSession.shared.data(from: proxy)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data(repeating: 7, count: 4))
    }

    func testRangeRequestReturnsPartialContentAndCachesRange() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = RangeAssertingDownloader(expectedRange: ByteRange(start: 2, end: 5), data: Data([2, 3, 4, 5]))
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let maybeCacheItem = try await HTTPMediaCache.cacheItem(for: original)
        let cacheItem = try XCTUnwrap(maybeCacheItem)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/*")
        XCTAssertEqual(data, Data([2, 3, 4, 5]))
        XCTAssertEqual(cacheItem.zones, [ByteRange(start: 2, end: 5)])
    }

    func testStreamingBodyIsWrittenBeforeCacheWriteCompletes() async throws {
        let cacheWriteStarted = AsyncSignal()
        let allowCacheWriteToFinish = AsyncSignal()
        let bodyWritten = AsyncSignal()
        let pump = StreamingProxyBodyPump(
            cacheWriter: { data, _ in
                XCTAssertEqual(data, Data([1, 2, 3, 4]))
                await cacheWriteStarted.signal()
                await allowCacheWriteToFinish.wait()
            },
            bodyWriter: { data in
                XCTAssertEqual(data, Data([1, 2, 3, 4]))
                await bodyWritten.signal()
            },
            endWriter: {}
        )

        let pumpTask = Task {
            try await pump.write(
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data([1, 2, 3, 4]))
                    continuation.finish()
                },
                initialOffset: 0
            )
        }

        try await withTimeout(seconds: 2) {
            await cacheWriteStarted.wait()
        }
        try await withTimeout(seconds: 2) {
            await bodyWritten.wait()
        }
        await allowCacheWriteToFinish.signal()
        try await pumpTask.value
    }

    func testStreamingPumpDoesNotBlockNextChunkOnCacheWrite() async throws {
        let firstCacheWriteStarted = AsyncSignal()
        let allowFirstCacheWriteToFinish = AsyncSignal()
        let secondBodyWritten = AsyncSignal()
        let pump = StreamingProxyBodyPump(
            cacheWriter: { data, _ in
                if data == Data([1, 2, 3, 4]) {
                    XCTAssertEqual(data, Data([1, 2, 3, 4]))
                    await firstCacheWriteStarted.signal()
                    await allowFirstCacheWriteToFinish.wait()
                }
            },
            bodyWriter: { data in
                if data == Data([5, 6, 7, 8]) {
                    XCTAssertEqual(data, Data([5, 6, 7, 8]))
                    await secondBodyWritten.signal()
                }
            },
            endWriter: {}
        )

        let pumpTask = Task {
            try await pump.write(
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data([1, 2, 3, 4]))
                    continuation.yield(Data([5, 6, 7, 8]))
                    continuation.finish()
                },
                initialOffset: 0
            )
        }

        try await withTimeout(seconds: 2) {
            await firstCacheWriteStarted.wait()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let didWriteSecondBody = await secondBodyWritten.isSignalled()
        XCTAssertTrue(didWriteSecondBody)
        await allowFirstCacheWriteToFinish.signal()
        try await pumpTask.value
    }

    func testProxyRangeRequestSplitsNetworkOnlyRangeUsingConfiguredRequestHeaderRangeLength() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ChunkedProxyRangeDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        await HTTPMediaCache.setDownloadRequestHeaderRangeLength { requestURL, totalLength in
            XCTAssertEqual(requestURL, original)
            XCTAssertEqual(totalLength, 0)
            return 2
        }

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let ranges = await downloader.downloadedRanges()

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(data, Data([2, 3, 4, 5]))
        XCTAssertEqual(ranges, [
            ByteRange(start: 2, end: 3),
            ByteRange(start: 4, end: 5),
        ])
    }

    func testPartialResponseDoesNotDuplicateAcceptRangesHeader() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = MetadataRangeDownloader(
            expectedRange: ByteRange(start: 2, end: 5),
            response: CacheDownloadResponse(
                data: Data([2, 3, 4, 5]),
                statusCode: 206,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Length": "4",
                    "Content-Range": "bytes 2-5/10",
                    "Content-Type": "video/mp4",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        var request = URLRequest(url: proxy)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.allHeaderFields["Accept-Ranges"] as? String, "bytes")
    }

    func testProxyHeadersMatchForwardingRules() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = HeaderAssertingDownloader(
            forbiddenHeaders: ["Host"],
            requiredHeaders: ["Connection": "keep-alive"],
            data: Data([1])
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        var request = URLRequest(url: proxy)
        request.setValue("127.0.0.1:\(proxy.port ?? 0)", forHTTPHeaderField: "Host")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data([1]))
    }

    func testProxyDownloadFailureIsRecorded() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let expectedError = NSError(domain: "HTTPMediaCacheTests", code: 42)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: FailingDownloader(error: expectedError))
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (_, response) = try await URLSession.shared.data(from: proxy)
        let storedError = await HTTPMediaCache.error(for: original) as NSError?

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(storedError?.domain, "HTTPMediaCacheTests")
        XCTAssertEqual(storedError?.code, 42)
    }

    func testCachedRangeIsServedWithoutDownloadingAgain() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = SingleUseDownloader(data: Data([0, 1, 2, 3]))
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        var request = URLRequest(url: proxy)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")

        let (firstData, firstResponse) = try await URLSession.shared.data(for: request)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(firstData, Data([0, 1, 2, 3]))
        XCTAssertEqual(secondData, Data([0, 1, 2, 3]))
    }

    func testCachedResponseHeadersUseMetadataWhitelist() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let downloader = MetadataRangeDownloader(
            expectedRange: ByteRange(start: 0, end: nil),
            response: CacheDownloadResponse(
                data: Data([0, 1, 2, 3]),
                statusCode: 200,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Connection": "keep-alive",
                    "Content-Length": "4",
                    "Content-Type": "video/mp4",
                    "ETag": "abc",
                    "Last-Modified": "Sat, 09 May 2026 00:00:00 GMT",
                    "Server": "origin",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)

        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: original), options: .init())
        try await preloadTask.waitForCompletion()
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (_, response) = try await URLSession.shared.data(from: proxy)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Server"), "origin")
        XCTAssertNil(httpResponse.value(forHTTPHeaderField: "ETag"))
        XCTAssertNil(httpResponse.value(forHTTPHeaderField: "Last-Modified"))
    }

    func testPartiallyCachedRangeIsAssembledFromFileAndNetworkSegments() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = SegmentAssertingDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: original, range: ByteRange(start: 0, end: 1)), options: .init())
        try await preloadTask.waitForCompletion()
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data([0, 1, 2, 3]))
    }

    func testPartiallyCachedFullRequestIsAssembled() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = SegmentAssertingDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: original, range: ByteRange(start: 0, end: 1)), options: .init())
        try await preloadTask.waitForCompletion()
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (data, response) = try await URLSession.shared.data(from: proxy)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(data, Data([0, 1, 2, 3]))
    }

    func testPartiallyCachedRangeWithStreamingDownloaderDoesNotWaitForNetworkCompletion() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = BlockingMixedStreamingDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: original, range: ByteRange(start: 0, end: 1)), options: .init())
        try await preloadTask.waitForCompletion()
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let byteRequest = request

        let (response, received) = try await withTimeout(seconds: 0.3) {
            let (bytes, response) = try await URLSession.shared.bytes(for: byteRequest)
            var received: [UInt8] = []
            for try await byte in bytes {
                received.append(byte)
                if received.count == 3 {
                    break
                }
            }
            return (response, received)
        }
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(received, [0, 1, 2])
        let streamedRanges = await downloader.streamedRanges()
        XCTAssertEqual(streamedRanges, [ByteRange(start: 0, end: 1), ByteRange(start: 2, end: 3)] as [ByteRange?])
        let didFinishSecondRequest = await downloader.didFinishSecondRequest()
        XCTAssertFalse(didFinishSecondRequest)
        await downloader.allowSecondRequestToFinish()
    }

    func testOpenEndedRangeRequestIsForwardedWithoutCapping() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expectedRange = ByteRange(start: 10, end: nil)
        let downloader = MetadataRangeDownloader(
            expectedRange: expectedRange,
            response: CacheDownloadResponse(
                data: Data(repeating: 1, count: 8),
                statusCode: 206,
                headers: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes 10-17/1000",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=10-", forHTTPHeaderField: "Range")

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let maybeCacheItem = try await HTTPMediaCache.cacheItem(for: original)
        let cacheItem = try XCTUnwrap(maybeCacheItem)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 10-17/1000")
        XCTAssertEqual(cacheItem.totalLength, 1000)
        XCTAssertEqual(cacheItem.contentType, "video/mp4")
    }

    func testCachedOpenEndedRangeUsesKnownTotalLength() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: FailingDownloader())

        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: original)
        try await unit.write(
            data: Data([0, 1, 2, 3]),
            offset: 0,
            totalLength: 4,
            contentType: "video/mp4"
        )
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=2-", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 2-3/4")
        XCTAssertEqual(data, Data([2, 3]))
    }

    func testSuffixRangeRequestIsForwardedWithoutHEADNormalization() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expectedRange = ByteRange(start: ByteRange.notFound, end: 8)
        let downloader = MetadataRangeDownloader(
            expectedRange: expectedRange,
            response: CacheDownloadResponse(
                data: Data(repeating: 2, count: 8),
                statusCode: 206,
                headers: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "8",
                    "Content-Range": "bytes 92-99/100",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=-8", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 92-99/100")
        XCTAssertEqual(data, Data(repeating: 2, count: 8))
    }

    func testSuffixRangeStreamingCachesAtContentRangeOffset() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = StreamingSuffixDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=-8", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let expectedZones = [ByteRange(start: 92, end: 95), ByteRange(start: 96, end: 99)]
        let item = try await waitForCacheItem(url: original, totalLength: 100, zones: expectedZones)

        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 92-99/100")
        XCTAssertEqual(data, Data([92, 93, 94, 95, 96, 97, 98, 99]))
        XCTAssertEqual(item.totalLength, 100)
        XCTAssertEqual(item.zones, expectedZones)
    }

    func testStreamingResponseRejectsWhenCacheSpaceIsInsufficient() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = StreamingFixedLengthDownloader(length: 8)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        await HTTPMediaCache.setMaxCacheLength(4)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (data, response) = try await URLSession.shared.data(from: proxy)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let item = try await HTTPMediaCache.cacheItem(for: original)

        XCTAssertEqual(httpResponse.statusCode, 404)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(item?.cachedLength, 0)
    }

    func testClientDisconnectCancelsStreamingDownload() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = DisconnectAwareStreamingDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var socket = try XCTUnwrap(connectSocket(host: "127.0.0.1", port: proxy.port ?? 0))
        defer {
            if socket >= 0 {
                close(socket)
            }
        }

        let requestText = "GET \(proxy.path) HTTP/1.1\r\nHost: \(proxy.host ?? "localhost"):\(proxy.port ?? 0)\r\nConnection: close\r\n\r\n"
        _ = requestText.withCString { pointer in
            send(socket, pointer, strlen(pointer), 0)
        }

        await downloader.waitUntilStreamResponseStarted()
        closeSocketImmediately(socket)
        socket = -1

        let didCancel = await downloader.waitUntilCancelled(timeout: 2)
        let item = try await HTTPMediaCache.cacheItem(for: original)

        XCTAssertTrue(didCancel)
        XCTAssertEqual(item?.cachedLength ?? 0, 0)
    }

    func testRangeRequestRejectedWhenOriginIgnoresRange() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = MetadataRangeDownloader(
            expectedRange: ByteRange(start: 2, end: 5),
            response: CacheDownloadResponse(
                data: Data([0, 1, 2, 3, 4, 5, 6, 7]),
                statusCode: 200,
                headers: [
                    "Content-Length": "8",
                    "Content-Type": "video/mp4",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let item = try await HTTPMediaCache.cacheItem(for: original)

        XCTAssertEqual(httpResponse.statusCode, 404)
        XCTAssertEqual(item?.cachedLength, 0)
        XCTAssertEqual(item?.zones, [])
    }

    func testHLSProxyRewritesPlaylistAndCachesRawPlaylist() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        #EXTINF:10,
        segment-2.ts
        """
        let downloader = MetadataRangeDownloader(
            expectedRange: nil,
            response: CacheDownloadResponse(
                data: Data(playlist.utf8),
                statusCode: 200,
                headers: [
                    "Content-Length": "\(playlist.utf8.count)",
                    "Content-Type": "application/x-mpegURL",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let original = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (data, response) = try await URLSession.shared.data(from: proxy)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))
        let maybeItem = try await HTTPMediaCache.cacheItem(for: original)
        let item = try XCTUnwrap(maybeItem)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(output.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertFalse(output.contains("\nsegment-2.ts"))
        XCTAssertEqual(item.cachedLength, Int64(playlist.utf8.count))
    }

    func testHLSProxyUsesCleanDownloadRequestLikePreload() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="4@8"
        #EXTINF:10,
        segment-1.ts
        """
        let downloader = HLSCleanRequestDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        await HTTPMediaCache.setHLSDownloadHeaderProvider { context in
            ["X-HLS-Kind": context.kind.rawValue]
        }
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let playlistProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        var playlistRequest = URLRequest(url: playlistProxy)
        playlistRequest.setValue("AVPlayer-Test", forHTTPHeaderField: "User-Agent")
        playlistRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let (playlistData, _) = try await URLSession.shared.data(for: playlistRequest)
        let playlistText = try XCTUnwrap(String(data: playlistData, encoding: .utf8))
        let proxyURLs = playlistText
            .split(separator: "\n")
            .flatMap { line in
                line
                    .split(separator: "\"")
                    .map(String.init)
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .filter { HTTPMediaCache.isProxyURL($0) }
        let keyProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "bin" })
        let initProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "mp4" })
        let segmentProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "ts" })

        var keyRequest = URLRequest(url: keyProxy)
        keyRequest.setValue("AVPlayer-Test", forHTTPHeaderField: "User-Agent")
        keyRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (keyData, _) = try await URLSession.shared.data(for: keyRequest)

        var initRequest = URLRequest(url: initProxy)
        initRequest.setValue("AVPlayer-Test", forHTTPHeaderField: "User-Agent")
        initRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (initData, _) = try await URLSession.shared.data(for: initRequest)

        var segmentRequest = URLRequest(url: segmentProxy)
        segmentRequest.setValue("AVPlayer-Test", forHTTPHeaderField: "User-Agent")
        segmentRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let (segmentData, response) = try await URLSession.shared.data(for: segmentRequest)
        let requestedURLs = await downloader.requestedURLs()
        let requestedKinds = await downloader.requestedKinds()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(keyData, Data([9, 9]))
        XCTAssertEqual(initData, Data([5, 6, 7, 8]))
        XCTAssertEqual(segmentData, Data([1, 2, 3, 4]))
        XCTAssertEqual(requestedURLs, [
            "https://example.com/live/index.m3u8",
            "https://example.com/live/key.bin",
            "https://example.com/live/init.mp4",
            "https://example.com/live/segment-1.ts",
        ])
        XCTAssertEqual(requestedKinds, [
            HLSDownloadResourceKind.playlist.rawValue,
            HLSDownloadResourceKind.key.rawValue,
            HLSDownloadResourceKind.initialization.rawValue,
            HLSDownloadResourceKind.segment.rawValue,
        ])
    }

    func testHLSProxyCachesSubresourcesUsingCacheIdentifierProvider() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin?token=origin"
        #EXT-X-MAP:URI="init.mp4?token=origin",BYTERANGE="4@8"
        #EXTINF:10,
        segment-1.ts?token=origin
        """
        let downloader = HLSCleanRequestDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        await HTTPMediaCache.setCacheIdentifierProvider { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url?.absoluteString ?? url.absoluteString
        }
        await HTTPMediaCache.setHLSDownloadHeaderProvider { context in
            ["X-HLS-Kind": context.kind.rawValue]
        }
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8?token=origin"))
        let playlistProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (playlistData, _) = try await URLSession.shared.data(from: playlistProxy)
        let playlistText = try XCTUnwrap(String(data: playlistData, encoding: .utf8))
        let proxyURLs = playlistText
            .split(separator: "\n")
            .flatMap { line in
                line
                    .split(separator: "\"")
                    .map(String.init)
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .filter { HTTPMediaCache.isProxyURL($0) }

        let keyProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "bin" })
        let initProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "mp4" })
        let segmentProxy = try XCTUnwrap(proxyURLs.first { $0.pathExtension == "ts" })

        _ = try await URLSession.shared.data(from: keyProxy)
        _ = try await URLSession.shared.data(from: initProxy)
        _ = try await URLSession.shared.data(from: segmentProxy)

        let keyLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/key.bin?token=lookup"))
        let initLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/init.mp4?token=lookup"))
        let segmentLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-1.ts?token=lookup"))

        let keyItem = try await HTTPMediaCache.cacheItem(for: keyLookupURL)
        let initItem = try await HTTPMediaCache.cacheItem(for: initLookupURL)
        let segmentItem = try await HTTPMediaCache.cacheItem(for: segmentLookupURL)

        XCTAssertEqual(keyItem?.cachedLength, 2)
        XCTAssertEqual(initItem?.cachedLength, 4)
        XCTAssertEqual(segmentItem?.cachedLength, 4)
    }

    func testHLSPlaylistIgnoresClientRangeProbeAndReturnsFullPlaylist() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment-1.ts
        """
        let downloader = HLSPlaylistRangeProbeDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let playlistProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        var request = URLRequest(url: playlistProxy)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let requestedRanges = await downloader.requestedRanges()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(text.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertEqual(requestedRanges, [nil])
    }

    func testHLSProxyDoesNotPreloadPlaylistSegments() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        #EXTINF:10,
        segment-2.ts
        """
        let downloader = HLSPreloadDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "http://cdn.example.com/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-2.ts"))
        let proxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        _ = try await URLSession.shared.data(from: proxy)

        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)

        XCTAssertNil(firstSegment)
        XCTAssertNil(secondSegment)
    }

    func testHLSProxyCachesRawPlaylistAndRewritesWithCurrentPort() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment-1.ts
        """
        let downloader = HLSPreloadDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let firstProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (firstData, _) = try await URLSession.shared.data(from: firstProxy)
        let firstText = try XCTUnwrap(String(data: firstData, encoding: .utf8))
        let maybeCachedItem = try await HTTPMediaCache.cacheItem(for: playlistURL)
        let cachedItem = try XCTUnwrap(maybeCachedItem)
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let cachedUnit = try await cacheIndex.unit(for: playlistURL)
        let maybeCachedData = try await cachedUnit.read(range: ByteRange(start: 0, end: cachedItem.totalLength - 1))
        let cachedData = try XCTUnwrap(maybeCachedData)
        let cachedText = try XCTUnwrap(String(data: cachedData, encoding: .utf8))

        XCTAssertTrue(firstText.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertEqual(cachedText, playlist)

        await HTTPMediaCache.stop()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: FailingDownloader())
        try await HTTPMediaCache.start(port: 0)

        let secondProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (secondData, secondResponse) = try await URLSession.shared.data(from: secondProxy)
        let secondText = try XCTUnwrap(String(data: secondData, encoding: .utf8))

        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(secondText.contains("localhost:\(secondProxy.port ?? 0)"))
        if firstProxy.port != secondProxy.port {
            XCTAssertFalse(secondText.contains("localhost:\(firstProxy.port ?? 0)"))
        }
    }

    func testHLSProxyInvalidatesProxyPlaylistCacheBeforePlayback() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment-1.ts
        """
        let downloader = HLSPreloadDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: playlistURL)
        let stalePlaylist = """
        #EXTM3U
        #EXTINF:10,
        http://localhost:1/old/HTTPMediaCachePlaceHolder/HTTPMediaCacheLastPathComponent.ts
        """
        try await unit.write(
            data: Data(stalePlaylist.utf8),
            offset: 0,
            totalLength: Int64(stalePlaylist.utf8.count),
            responseHeaders: [
                "Content-Length": "\(stalePlaylist.utf8.count)",
                "Content-Type": "application/x-mpegURL",
            ]
        )
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (data, response) = try await URLSession.shared.data(from: proxy)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let maybeCacheItem = try await HTTPMediaCache.cacheItem(for: playlistURL)
        let cacheItem = try XCTUnwrap(maybeCacheItem)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(text.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertFalse(text.contains("localhost:1"))
        XCTAssertEqual(cacheItem.cachedLength, Int64(playlist.utf8.count))
    }

    func testHLSRedirectPathResolvesToSegmentURL() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        """
        let downloader = URLDataDownloader(responses: [
            "https://example.com/live/index.m3u8": Data(playlist.utf8),
            "http://cdn.example.com/segment-1.ts": Data([1, 2, 3]),
        ])
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let playlistProxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (playlistData, _) = try await URLSession.shared.data(from: playlistProxy)
        let playlistText = try XCTUnwrap(String(data: playlistData, encoding: .utf8))
        let proxySegmentURL = try XCTUnwrap(
            playlistText
                .split(separator: "\n")
                .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                .first(where: { HTTPMediaCache.isProxyURL($0) })
        )
        XCTAssertEqual(
            HTTPMediaCache.originalURL(from: proxySegmentURL),
            try XCTUnwrap(URL(string: "http://cdn.example.com/segment-1.ts"))
        )
        let segmentURL = proxySegmentURL

        let (data, response) = try await URLSession.shared.data(from: segmentURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testHLSSegmentProxyUsesCompleteDownloadBeforeResponding() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/live/segment-1.ts"))
        let downloader = HLSSegmentCompleteDownloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        let (data, response) = try await URLSession.shared.data(from: proxy)
        let cacheItem = try await HTTPMediaCache.cacheItem(for: original)
        let didUseStreamingResponse = await downloader.didUseStreamingResponse()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        XCTAssertEqual(cacheItem?.cachedLength, 4)
        XCTAssertFalse(didUseStreamingResponse)
    }

    func testHeadRequestUsesCachedResponse() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: FailingDownloader())

        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: original)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.httpMethod = "HEAD"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), "4")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertTrue(data.isEmpty)
    }

    func testHeadRequestUsesConfiguredDownloader() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let downloader = MetadataRangeDownloader(
            expectedRange: ByteRange(start: 0, end: nil),
            response: CacheDownloadResponse(
                data: Data([0, 1, 2, 3]),
                statusCode: 200,
                headers: [
                    "Content-Length": "4",
                    "Content-Type": "video/mp4",
                ]
            )
        )
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)
        var request = URLRequest(url: proxy)
        request.httpMethod = "HEAD"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let item = try await HTTPMediaCache.cacheItem(for: original)

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), "4")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertTrue(data.isEmpty)
    }

    func testHeadRequestWithResponseDownloaderReturnsAfterResponseHeaders() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = HeadOnlyResponseDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        var request = URLRequest(url: proxy)
        request.httpMethod = "HEAD"
        let headRequest = request

        let (data, response) = try await withTimeout(seconds: 0.2) {
            try await URLSession.shared.data(for: headRequest)
        }
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let didDownloadBody = await downloader.didDownloadBody()
        let item = try await HTTPMediaCache.cacheItem(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), "100")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertTrue(data.isEmpty)
        XCTAssertFalse(didDownloadBody)
        XCTAssertEqual(item?.cachedLength, 0)
    }

    func testHeadRequestWithStreamingDownloaderReturnsAfterResponseHeaders() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = HeadOnlyStreamingDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: downloader)
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        var request = URLRequest(url: proxy)
        request.httpMethod = "HEAD"
        let headRequest = request

        let (data, response) = try await withTimeout(seconds: 0.2) {
            try await URLSession.shared.data(for: headRequest)
        }
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let didDownloadBody = await downloader.didDownloadBody()

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), "100")
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertTrue(data.isEmpty)
        XCTAssertFalse(didDownloadBody)
    }

    func testPingProxyURLReturnsPing() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: FailingDownloader())
        try await HTTPMediaCache.start(port: 0)

        let pingSource = try XCTUnwrap(URL(string: "HTTPMediaCachePing"))
        let pingURL = try await HTTPMediaCache.proxyURL(for: pingSource)
        let (data, response) = try await URLSession.shared.data(from: pingURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ping")
    }
}

private struct RangeAssertingDownloader: CacheDownloading {
    let expectedRange: ByteRange
    let data: Data

    func download(request: CacheRequest) async throws -> [Data] {
        XCTAssertEqual(request.range, expectedRange)
        XCTAssertEqual(request.headers["Range"], expectedRange.requestHeaderValue)
        return [data]
    }
}

private struct MetadataRangeDownloader: CacheResponseDownloading {
    let expectedRange: ByteRange?
    let response: CacheDownloadResponse

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        XCTAssertEqual(request.range, expectedRange)
        XCTAssertEqual(request.headers["Range"], expectedRange?.requestHeaderValue)
        return response
    }
}

private struct HeaderAssertingDownloader: CacheDownloading {
    let forbiddenHeaders: [String]
    var requiredHeaders: [String: String] = [:]
    let data: Data

    func download(request: CacheRequest) async throws -> [Data] {
        for header in forbiddenHeaders {
            XCTAssertNil(request.headers.first { $0.key.caseInsensitiveCompare(header) == .orderedSame })
        }
        for (header, value) in requiredHeaders {
            XCTAssertEqual(request.headers.first { $0.key.caseInsensitiveCompare(header) == .orderedSame }?.value, value)
        }
        return [data]
    }
}

private struct SingleUseDownloader: CacheDownloading {
    private let state: SingleUseDownloadState

    init(data: Data) {
        state = SingleUseDownloadState(data: data)
    }

    func download(request _: CacheRequest) async throws -> [Data] {
        try await state.download()
    }
}

private actor SingleUseDownloadState {
    private let data: Data
    private var didDownload = false

    init(data: Data) {
        self.data = data
    }

    func download() throws -> [Data] {
        if didDownload {
            throw CacheError.networkFailure("download should not be called again")
        }

        didDownload = true
        return [data]
    }
}

private struct ChunkedProxyRangeDownloader: CacheResponseDownloading {
    private let state = ChunkedProxyRangeDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.download(request: request)
    }

    func downloadedRanges() async -> [ByteRange?] {
        await state.downloadedRanges()
    }
}

private actor ChunkedProxyRangeDownloadState {
    private var ranges: [ByteRange?] = []

    func download(request: CacheRequest) throws -> CacheDownloadResponse {
        ranges.append(request.range)
        guard let range = request.range, let end = range.end else {
            throw CacheError.networkFailure("unexpected open-ended range")
        }
        let bytes = (range.start ... end).map { UInt8($0) }
        return CacheDownloadResponse(
            data: Data(bytes),
            statusCode: 206,
            headers: [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(bytes.count)",
                "Content-Range": "bytes \(range.start)-\(end)/6",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func downloadedRanges() -> [ByteRange?] {
        ranges
    }
}

private struct SegmentAssertingDownloader: CacheResponseDownloading {
    private let state = SegmentAssertingDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.download(request: request)
    }
}

private actor SegmentAssertingDownloadState {
    private var callIndex = 0

    func download(request: CacheRequest) throws -> CacheDownloadResponse {
        callIndex += 1
        switch callIndex {
        case 1:
            XCTAssertEqual(request.range, ByteRange(start: 0, end: 1))
            return CacheDownloadResponse(
                data: Data([0, 1]),
                statusCode: 206,
                headers: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 0-1/4",
                    "Content-Type": "video/mp4",
                ]
            )
        case 2:
            XCTAssertEqual(request.range, ByteRange(start: 2, end: 3))
            return CacheDownloadResponse(
                data: Data([2, 3]),
                statusCode: 206,
                headers: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 2-3/4",
                    "Content-Type": "video/mp4",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected segment download")
        }
    }
}

private struct BlockingMixedStreamingDownloader: CacheStreamingDownloading {
    private let state = BlockingMixedStreamingState()

    func download(request: CacheRequest) async throws -> [Data] {
        var data = Data()
        let response = try await streamResponse(request: request)
        for try await chunk in response.body {
            data.append(chunk)
        }
        return [data]
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        try await state.streamResponse(request: request)
    }

    func didFinishSecondRequest() async -> Bool {
        await state.didFinishSecondRequest()
    }

    func allowSecondRequestToFinish() async {
        await state.allowSecondRequestToFinish()
    }

    func streamedRanges() async -> [ByteRange?] {
        await state.streamedRanges()
    }
}

private actor BlockingMixedStreamingState {
    private var allowFinishContinuation: CheckedContinuation<Void, Never>?
    private var canFinishSecondRequest = false
    private var didFinishSecond = false
    private var ranges: [ByteRange?] = []

    func streamResponse(request: CacheRequest) throws -> CacheStreamResponse {
        ranges.append(request.range)

        if request.range == ByteRange(start: 0, end: 1) {
            return CacheStreamResponse(
                statusCode: 206,
                headers: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 0-1/4",
                    "Content-Type": "video/mp4",
                ],
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data([0, 1]))
                    continuation.finish()
                }
            )
        }

        if request.range == ByteRange(start: 2, end: 3) {
            return CacheStreamResponse(
                statusCode: 206,
                headers: [
                    "Content-Length": "2",
                    "Content-Range": "bytes 2-3/4",
                    "Content-Type": "video/mp4",
                ],
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data([2]))
                    Task {
                        await self.waitUntilAllowedToFinish()
                        continuation.yield(Data([3]))
                        continuation.finish()
                        self.markSecondRequestFinished()
                    }
                }
            )
        }

        XCTAssertEqual(request.range, ByteRange(start: 0, end: 3))
        return CacheStreamResponse(
            statusCode: 206,
            headers: [
                "Content-Length": "4",
                "Content-Range": "bytes 0-3/4",
                "Content-Type": "video/mp4",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data([0, 1, 2]))
                Task {
                    await self.waitUntilAllowedToFinish()
                    continuation.yield(Data([3]))
                    continuation.finish()
                    self.markSecondRequestFinished()
                }
            }
        )
    }

    func didFinishSecondRequest() -> Bool {
        didFinishSecond
    }

    func streamedRanges() -> [ByteRange?] {
        ranges
    }

    func allowSecondRequestToFinish() {
        canFinishSecondRequest = true
        allowFinishContinuation?.resume()
        allowFinishContinuation = nil
    }

    private func waitUntilAllowedToFinish() async {
        if canFinishSecondRequest {
            return
        }
        await withCheckedContinuation { continuation in
            allowFinishContinuation = continuation
        }
    }

    private func markSecondRequestFinished() {
        didFinishSecond = true
    }
}

private struct HLSPreloadDownloader: CacheResponseDownloading {
    let playlist: String

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        if request.url.absoluteString == "https://example.com/live/index.m3u8" {
            return CacheDownloadResponse(
                data: Data(playlist.utf8),
                statusCode: 200,
                headers: [
                    "Content-Length": "\(playlist.utf8.count)",
                    "Content-Type": "application/x-mpegURL",
                ]
            )
        }

        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
        return CacheDownloadResponse(
            data: Data([1, 2, 3]),
            statusCode: 200,
            headers: [
                "Content-Length": "3",
                "Content-Type": "video/mp2t",
            ]
        )
    }
}

private struct URLDataDownloader: CacheDownloading {
    let responses: [String: Data]

    func download(request: CacheRequest) async throws -> [Data] {
        guard let data = responses[request.url.absoluteString] else {
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
        return [data]
    }
}

private struct HLSSegmentCompleteDownloadDownloader: CacheResponseDownloading, CacheStreamingDownloading {
    private let state = HLSSegmentCompleteDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request _: CacheRequest) async throws -> CacheDownloadResponse {
        CacheDownloadResponse(
            data: Data([1, 2, 3, 4]),
            statusCode: 200,
            headers: [
                "Content-Length": "4",
                "Content-Type": "video/MP2T",
            ]
        )
    }

    func streamResponse(request _: CacheRequest) async throws -> CacheStreamResponse {
        await state.markStreamingResponseUsed()
        return CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "4",
                "Content-Type": "video/MP2T",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data([1, 2]))
                continuation.finish(throwing: CacheError.networkFailure("simulated HLS segment stream failure"))
            }
        )
    }

    func didUseStreamingResponse() async -> Bool {
        await state.didUseStreamingResponse()
    }
}

private struct HLSCleanRequestDownloader: CacheResponseDownloading, CacheStreamingDownloading {
    let playlist: String
    private let state = HLSCleanRequestState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.record(request: request)
        switch request.url.pathExtension {
        case "m3u8":
            return CacheDownloadResponse(
                data: Data(playlist.utf8),
                statusCode: 200,
                headers: [
                    "Content-Length": "\(playlist.utf8.count)",
                    "Content-Type": "application/x-mpegURL",
                ]
            )
        case "bin":
            return CacheDownloadResponse(
                data: Data([9, 9]),
                statusCode: 200,
                headers: [
                    "Content-Length": "2",
                    "Content-Type": "application/octet-stream",
                ]
            )
        case "mp4":
            return CacheDownloadResponse(
                data: Data([5, 6, 7, 8]),
                statusCode: 206,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 8-11/20",
                    "Content-Type": "video/mp4",
                ]
            )
        default:
            return CacheDownloadResponse(
                data: Data([1, 2, 3, 4]),
                statusCode: 200,
                headers: [
                    "Content-Length": "4",
                    "Content-Type": "video/MP2T",
                ]
            )
        }
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        try await state.record(request: request)
        return CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "4",
                "Content-Type": "video/MP2T",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data([1, 2, 3, 4]))
                continuation.finish()
            }
        )
    }

    func requestedURLs() async -> [String] {
        await state.requestedURLs()
    }

    func requestedKinds() async -> [String] {
        await state.requestedKinds()
    }
}

private actor HLSCleanRequestState {
    private var urls: [String] = []
    private var kinds: [String] = []

    func record(request: CacheRequest) throws {
        if request.headers.contains(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            throw CacheError.networkFailure("HLS proxy should not forward User-Agent.")
        }
        if request.headers.contains(where: { $0.key.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }) {
            throw CacheError.networkFailure("HLS proxy should not forward Accept-Encoding.")
        }
        switch request.url.pathExtension {
        case "bin":
            XCTAssertNil(request.range)
        case "mp4":
            XCTAssertEqual(request.range, ByteRange(start: 8, end: 11))
        default:
            break
        }
        urls.append(request.url.absoluteString)
        if let kind = request.headers["X-HLS-Kind"] {
            kinds.append(kind)
        }
    }

    func requestedURLs() -> [String] {
        urls
    }

    func requestedKinds() -> [String] {
        kinds
    }
}

private struct HLSPlaylistRangeProbeDownloader: CacheResponseDownloading {
    let playlist: String
    private let state = HLSPlaylistRangeProbeState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        await state.record(range: request.range)
        return CacheDownloadResponse(
            data: Data(playlist.utf8),
            statusCode: 200,
            headers: [
                "Content-Length": "\(playlist.utf8.count)",
                "Content-Type": "application/x-mpegURL",
            ]
        )
    }

    func requestedRanges() async -> [ByteRange?] {
        await state.requestedRanges()
    }
}

private actor HLSPlaylistRangeProbeState {
    private var ranges: [ByteRange?] = []

    func record(range: ByteRange?) {
        ranges.append(range)
    }

    func requestedRanges() -> [ByteRange?] {
        ranges
    }
}

private actor HLSSegmentCompleteDownloadState {
    private var usedStreamingResponse = false

    func markStreamingResponseUsed() {
        usedStreamingResponse = true
    }

    func didUseStreamingResponse() -> Bool {
        usedStreamingResponse
    }
}

private struct FailingDownloader: CacheDownloading {
    var error: Error?

    func download(request: CacheRequest) async throws -> [Data] {
        throw error ?? CacheError.networkFailure("unexpected download \(request.url.absoluteString)")
    }
}

private struct StreamingSuffixDownloader: CacheStreamingDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        var data = Data()
        let response = try await streamResponse(request: request)
        for try await chunk in response.body {
            data.append(chunk)
        }
        return [data]
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        XCTAssertEqual(request.range, ByteRange(start: ByteRange.notFound, end: 8))
        return CacheStreamResponse(
            statusCode: 206,
            headers: [
                "Content-Length": "8",
                "Content-Range": "bytes 92-99/100",
                "Content-Type": "video/mp4",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data([92, 93, 94, 95]))
                continuation.yield(Data([96, 97, 98, 99]))
                continuation.finish()
            }
        )
    }
}

private struct StreamingFixedLengthDownloader: CacheStreamingDownloading {
    let length: Int

    func download(request: CacheRequest) async throws -> [Data] {
        var data = Data()
        let response = try await streamResponse(request: request)
        for try await chunk in response.body {
            data.append(chunk)
        }
        return [data]
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
        return CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "\(length)",
                "Content-Type": "video/mp4",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(repeating: 1, count: length))
                continuation.finish()
            }
        )
    }
}

private struct DisconnectAwareStreamingDownloader: CacheStreamingDownloading {
    private let state = DisconnectAwareStreamingState()

    func download(request: CacheRequest) async throws -> [Data] {
        var data = Data()
        let response = try await streamResponse(request: request)
        for try await chunk in response.body {
            data.append(chunk)
        }
        return [data]
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
        await state.markStarted()
        return CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "8",
                "Content-Type": "video/mp4",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.onTermination = { termination in
                    if case .cancelled = termination {
                        Task {
                            await state.markCancelled()
                        }
                    }
                }
            },
            cancel: {
                Task {
                    await state.markCancelled()
                }
            }
        )
    }

    func waitUntilStreamResponseStarted() async {
        await state.waitUntilStarted()
    }

    func waitUntilCancelled(timeout: TimeInterval) async -> Bool {
        await state.waitUntilCancelled(timeout: timeout)
    }
}

private struct HeadOnlyStreamingDownloader: CacheStreamingDownloading {
    private let state = HeadOnlyStreamingState()

    func download(request _: CacheRequest) async throws -> [Data] {
        await state.markBodyDownload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return [Data()]
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
        return CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "100",
                "Content-Type": "video/mp4",
            ],
            body: AsyncThrowingStream { _ in }
        )
    }

    func didDownloadBody() async -> Bool {
        await state.didDownloadBody()
    }
}

private struct HeadOnlyResponseDownloader: CacheResponseDownloading, CacheHeaderDownloading {
    private let state = HeadOnlyResponseState()

    func download(request _: CacheRequest) async throws -> [Data] {
        await state.markBodyDownload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return [Data(repeating: 1, count: 100)]
    }

    func downloadResponse(request _: CacheRequest) async throws -> CacheDownloadResponse {
        await state.markBodyDownload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return CacheDownloadResponse(
            data: Data(repeating: 1, count: 100),
            statusCode: 200,
            headers: [
                "Content-Length": "100",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func downloadHeaderResponse(request _: CacheRequest) async throws -> CacheHeaderResponse {
        CacheHeaderResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "100",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func didDownloadBody() async -> Bool {
        await state.didDownloadBody()
    }
}

private actor HeadOnlyResponseState {
    private var downloadedBody = false

    func markBodyDownload() {
        downloadedBody = true
    }

    func didDownloadBody() -> Bool {
        downloadedBody
    }
}

private actor HeadOnlyStreamingState {
    private var downloadedBody = false

    func markBodyDownload() {
        downloadedBody = true
    }

    func didDownloadBody() -> Bool {
        downloadedBody
    }
}

private actor AsyncSignal {
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        if signalled {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func isSignalled() -> Bool {
        signalled
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CacheError.networkFailure("Timed out waiting for operation.")
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func waitForCacheItem(url: URL, totalLength: Int64, zones: [ByteRange]) async throws -> CacheItem {
    try await withTimeout(seconds: 2) {
        while true {
            if let item = try await HTTPMediaCache.cacheItem(for: url),
               item.totalLength == totalLength,
               item.zones == zones
            {
                return item
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor DisconnectAwareStreamingState {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didCancel = false

    func markStarted() {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func markCancelled() {
        didCancel = true
    }

    func waitUntilCancelled(timeout: TimeInterval) async -> Bool {
        if didCancel {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if didCancel {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return didCancel
    }
}

private func connectSocket(host: String, port: Int) -> Int32? {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
        return nil
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    let conversionResult = host.withCString { pointer in
        inet_pton(AF_INET, pointer, &address.sin_addr)
    }
    guard conversionResult == 1 else {
        close(socketDescriptor)
        return nil
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    guard connected == 0 else {
        close(socketDescriptor)
        return nil
    }
    return socketDescriptor
}

private func closeSocketImmediately(_ socketDescriptor: Int32) {
    var lingerOption = linger(l_onoff: 1, l_linger: 0)
    _ = withUnsafePointer(to: &lingerOption) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<linger>.size) { optionPointer in
            setsockopt(socketDescriptor, SOL_SOCKET, SO_LINGER, optionPointer, socklen_t(MemoryLayout<linger>.size))
        }
    }
    close(socketDescriptor)
}
