//
//  URLSessionDownloaderTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
@testable import HTTPMediaCache
import XCTest

final class URLSessionDownloaderTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.stop()
        RangeCapturingURLProtocol.clearHandler()
        await HTTPMediaCache.setDownloadWhitelistHeaderKeys([])
        await HTTPMediaCache.setDownloadAdditionalHeaders([:])
        await HTTPMediaCache.setDownloadAcceptableContentTypes([
            "text/",
            "video/",
            "audio/",
            "vnd.apple.mpegURL",
            "application/x-mpegURL",
            "application/mp4",
            "application/octet-stream",
            "binary/octet-stream",
        ])
        await HTTPMediaCache.setDownloadUnacceptableContentTypeDisposer(nil)
        await HTTPMediaCache.setDownloadMetricsHandler(nil)
        await HTTPMediaCache.setDownloadTimeoutInterval(30)
        try await super.tearDown()
    }

    func testDownloaderSendsRangeHeaderAndReturnsResponseData() async throws {
        let expectedData = Data(repeating: 7, count: 10)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        RangeCapturingURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")

            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Range": "bytes 10-19/100",
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let chunks = try await downloader.download(
            request: CacheRequest(url: expectedURL, headers: ["Accept": "*/*"], range: ByteRange(start: 10, end: 19))
        )

        XCTAssertEqual(chunks, [expectedData])
    }

    func testDownloaderMatchesHeaderFilteringAndAdditionalHeaders() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        await HTTPMediaCache.setDownloadWhitelistHeaderKeys(["X-Allowed"])
        await HTTPMediaCache.setDownloadAdditionalHeaders(["X-Extra": "extra"])

        RangeCapturingURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Allowed"), "yes")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Blocked"), nil)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Extra"), "extra")

            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let chunks = try await downloader.download(
            request: CacheRequest(
                url: expectedURL,
                headers: [
                    "Accept": "*/*",
                    "X-Allowed": "yes",
                    "X-Blocked": "no",
                ]
            )
        )

        XCTAssertEqual(chunks, [expectedData])
    }

    func testDownloaderAllowsPolicyGeneratedHeaders() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/segment.ts"))

        RangeCapturingURLProtocol.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-HLS-Kind"), "segment")

            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "video/mp2t",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let chunks = try await downloader.download(
            request: CacheRequest(
                downloadURL: expectedURL,
                headers: [
                    "Authorization": "Bearer token",
                    "X-HLS-Kind": "segment",
                ],
                allowsUnfilteredHeaders: true
            )
        )

        XCTAssertEqual(chunks, [expectedData])
    }

    func testDownloaderHeaderFilteringIsCaseSensitive() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        RangeCapturingURLProtocol.setHandler { request in
            XCTAssertNil(request.allHTTPHeaderFields?["accept"])
            XCTAssertNil(request.allHTTPHeaderFields?["Accept"])

            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let chunks = try await downloader.download(
            request: CacheRequest(
                url: expectedURL,
                headers: [
                    "accept": "*/*",
                ]
            )
        )

        XCTAssertEqual(chunks, [expectedData])
    }

    func testDownloadConfigurationGettersExposeCurrentValues() async {
        await HTTPMediaCache.setDownloadTimeoutInterval(12)
        await HTTPMediaCache.setDownloadWhitelistHeaderKeys(["X-Allowed"])
        await HTTPMediaCache.setDownloadAdditionalHeaders(["X-Extra": "extra"])
        await HTTPMediaCache.setDownloadAcceptableContentTypes(["video/mp4"])

        let timeout = await HTTPMediaCache.downloadTimeoutInterval()
        let whitelist = await HTTPMediaCache.downloadWhitelistHeaderKeys()
        let additionalHeaders = await HTTPMediaCache.downloadAdditionalHeaders()
        let acceptableContentTypes = await HTTPMediaCache.downloadAcceptableContentTypes()

        XCTAssertEqual(timeout, 12)
        XCTAssertEqual(whitelist, ["X-Allowed"])
        XCTAssertEqual(additionalHeaders, ["X-Extra": "extra"])
        XCTAssertEqual(acceptableContentTypes, ["video/mp4"])
    }

    func testDownloadMetricsHandlerReceivesURLSessionMetrics() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let store = DownloadMetricsStore()
        await HTTPMediaCache.setDownloadMetricsHandler { url, metrics in
            Task {
                await store.record(url: url, metrics: metrics)
            }
        }

        RangeCapturingURLProtocol.setHandler { _ in
            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        _ = try await downloader.download(request: CacheRequest(url: expectedURL))
        let recorded = await store.waitForRecord()

        XCTAssertEqual(recorded?.url, expectedURL)
        XCTAssertNotNil(recorded?.metrics)
    }

    func testUnacceptableContentTypeDisposerCanAllowResponse() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.custom"))
        await HTTPMediaCache.setDownloadAcceptableContentTypes(["video/mp4"])
        await HTTPMediaCache.setDownloadUnacceptableContentTypeDisposer { url, contentType in
            url == expectedURL && contentType == "application/custom-video"
        }

        RangeCapturingURLProtocol.setHandler { _ in
            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "application/custom-video",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let chunks = try await downloader.download(request: CacheRequest(url: expectedURL))

        XCTAssertEqual(chunks, [expectedData])
    }

    func testNilAcceptableContentTypesRejectsUnlessDisposerAllows() async throws {
        let expectedData = Data(repeating: 1, count: 4)
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.custom"))
        await HTTPMediaCache.setDownloadAcceptableContentTypes(nil)

        RangeCapturingURLProtocol.setHandler { _ in
            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedData.count)",
                    "Content-Type": "application/custom-video",
                ]
            )!
            return (response, expectedData)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        do {
            _ = try await downloader.download(request: CacheRequest(url: expectedURL))
            XCTFail("nil acceptableContentTypes should reject unmatched content types.")
        } catch {}

        await HTTPMediaCache.setDownloadUnacceptableContentTypeDisposer { url, contentType in
            url == expectedURL && contentType == "application/custom-video"
        }

        let chunks = try await downloader.download(request: CacheRequest(url: expectedURL))
        XCTAssertEqual(chunks, [expectedData])
    }

    func testDownloaderRejectsInvalidResponseBeforeReadingBody() async throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.custom"))
        let didAttemptBodyRead = BodyReadTracker()
        await HTTPMediaCache.setDownloadAcceptableContentTypes(["video/mp4"])

        RangeCapturingURLProtocol.setHandler { _ in
            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "4",
                    "Content-Type": "application/custom-video",
                ]
            )!
            return (response, Data([0, 1, 2, 3]), didAttemptBodyRead)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        do {
            _ = try await downloader.download(request: CacheRequest(url: expectedURL))
            XCTFail("Invalid response should be rejected before body is read.")
        } catch {}

        let attemptedBodyRead = await didAttemptBodyRead.value()
        XCTAssertFalse(attemptedBodyRead)
    }

    func testHLSProxyDownloadAllowsMissingContentLengthAndContentType() async throws {
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment.ts
        """
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        RangeCapturingURLProtocol.setHandler { request in
            XCTAssertEqual(request.url, playlistURL)
            let response = HTTPURLResponse(
                url: playlistURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (response, Data(playlist.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]
        await HTTPMediaCache.configureForTests(storageRoot: storageRoot, downloader: URLSessionDownloader(configuration: configuration))
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: playlistURL)
        let (data, response) = try await URLSession.shared.data(from: proxy)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let playlistText = try XCTUnwrap(String(data: data, encoding: .utf8))
        let proxySegmentURL = try XCTUnwrap(
            playlistText
                .split(separator: "\n")
                .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                .first(where: { HTTPMediaCache.isProxyURL($0) })
        )
        XCTAssertEqual(HTTPMediaCache.originalURL(from: proxySegmentURL), try XCTUnwrap(URL(string: "https://example.com/live/segment.ts")))
        XCTAssertTrue(playlistText.contains("HTTPMediaCachePlaceHolder"))
    }

    func testHLSDownloadAllowsHTTPErrorStatusWithBody() async throws {
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment.ts
        """
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))

        RangeCapturingURLProtocol.setHandler { _ in
            let response = HTTPURLResponse(
                url: playlistURL,
                statusCode: 500,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (response, Data(playlist.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]

        let downloader = URLSessionDownloader(configuration: configuration)
        let response = try await downloader.downloadHLSResponse(request: CacheRequest(url: playlistURL))

        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(String(data: response.data, encoding: .utf8), playlist)
    }

    func testStreamingResponseYieldsURLSessionDataChunks() async throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let expectedChunks = [
            Data([0, 1, 2]),
            Data([3, 4]),
            Data([5, 6, 7, 8]),
        ]

        RangeCapturingURLProtocol.setChunkHandler { request in
            XCTAssertEqual(request.url, expectedURL)
            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedChunks.reduce(0) { $0 + $1.count })",
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, expectedChunks)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]
        let downloader = URLSessionDownloader(configuration: configuration)

        let response = try await downloader.streamResponse(request: CacheRequest(url: expectedURL))
        var receivedChunks: [Data] = []
        for try await chunk in response.body {
            receivedChunks.append(chunk)
        }

        XCTAssertEqual(receivedChunks, expectedChunks)
    }

    func testStreamingResponseRetriesTransientFailureBeforeReturningResponse() async throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/video.ts"))
        let expectedChunks = [Data([0, 1, 2])]
        let attemptCounter = AttemptCounter()

        RangeCapturingURLProtocol.setChunkHandler { _ in
            let attempt = attemptCounter.next()
            if attempt == 1 {
                throw URLError(.secureConnectionFailed)
            }

            let response = HTTPURLResponse(
                url: expectedURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(expectedChunks[0].count)",
                    "Content-Type": "video/MP2T",
                ]
            )!
            return (response, expectedChunks)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCapturingURLProtocol.self]
        let downloader = URLSessionDownloader(configuration: configuration)

        let response = try await downloader.streamResponse(request: CacheRequest(url: expectedURL))
        var receivedChunks: [Data] = []
        for try await chunk in response.body {
            receivedChunks.append(chunk)
        }

        XCTAssertEqual(receivedChunks, expectedChunks)
        XCTAssertEqual(attemptCounter.value(), 2)
    }
}

private final class RangeCapturingURLProtocol: URLProtocol {
    private static let handlerStore = URLProtocolHandlerStore()
    private let lock = NSLock()
    private var isStopped = false

    static func clearHandler() {
        handlerStore.set(nil)
    }

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?) {
        guard let handler else {
            handlerStore.set(nil)
            return
        }
        handlerStore.set { request in
            let (response, data) = try handler(request)
            return (response, [data], nil)
        }
    }

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data, BodyReadTracker?))?) {
        guard let handler else {
            handlerStore.set(nil)
            return
        }
        handlerStore.set { request in
            let (response, data, bodyReadTracker) = try handler(request)
            return (response, [data], bodyReadTracker)
        }
    }

    static func setChunkHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data]))?) {
        guard let handler else {
            handlerStore.set(nil)
            return
        }
        handlerStore.set { request in
            let (response, chunks) = try handler(request)
            return (response, chunks, nil)
        }
    }

    static func setChunkHandler(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data], BodyReadTracker?))?) {
        handlerStore.set(handler)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handlerStore.get() else {
            client?.urlProtocol(self, didFailWithError: CacheError.networkFailure("missing handler"))
            return
        }

        do {
            let (response, chunks, bodyReadTracker) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let bodyReadTracker {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    Task {
                        guard let self else {
                            return
                        }
                        guard !self.currentIsStopped() else {
                            return
                        }
                        await bodyReadTracker.markRead()
                        for chunk in chunks {
                            self.client?.urlProtocol(self, didLoad: chunk)
                        }
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
                return
            }
            if chunks.count > 1 {
                loadChunks(chunks)
                return
            }
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func loadChunks(_ chunks: [Data], index: Int = 0) {
        guard index < chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(index == 0 ? 0 : 10)) { [weak self] in
            guard let self else {
                return
            }
            guard !self.currentIsStopped() else {
                return
            }
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.loadChunks(chunks, index: index + 1)
        }
    }

    override func stopLoading() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }

    private func currentIsStopped() -> Bool {
        lock.lock()
        let value = isStopped
        lock.unlock()
        return value
    }
}

private final class URLProtocolHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data], BodyReadTracker?))?

    func set(_ handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data], BodyReadTracker?))?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func get() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, [Data], BodyReadTracker?))? {
        lock.lock()
        let handler = handler
        lock.unlock()
        return handler
    }
}

private actor BodyReadTracker {
    private var didRead = false

    func markRead() {
        didRead = true
    }

    func value() -> Bool {
        didRead
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }

    func value() -> Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }
}

private actor DownloadMetricsStore {
    private var record: (url: URL, metrics: URLSessionTaskMetrics)?
    private var continuation: CheckedContinuation<(url: URL, metrics: URLSessionTaskMetrics)?, Never>?

    func record(url: URL, metrics: URLSessionTaskMetrics) {
        let value = (url: url, metrics: metrics)
        record = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func waitForRecord() async -> (url: URL, metrics: URLSessionTaskMetrics)? {
        if let record {
            return record
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
