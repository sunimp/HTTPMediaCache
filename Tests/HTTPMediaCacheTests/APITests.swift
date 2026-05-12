//
//  APITests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class APITests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.setDownloadRequestHeaderRangeLength(nil)
        await HTTPMediaCache.cleanErrors()
        try await super.tearDown()
    }

    func testCacheRequestDefaultsToFullRange() throws {
        let request = try CacheRequest(url: XCTUnwrap(URL(string: "https://example.com/video.mp4")))
        XCTAssertEqual(request.url.absoluteString, "https://example.com/video.mp4")
        XCTAssertEqual(request.headers["Range"], "bytes=0-")
        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
    }

    func testCacheRequestMatchesCaseSensitiveRangeHeaderLookup() throws {
        let request = try CacheRequest(
            url: XCTUnwrap(URL(string: "https://example.com/video.mp4")),
            headers: ["range": "bytes=5-9"]
        )

        XCTAssertEqual(request.headers["range"], "bytes=5-9")
        XCTAssertEqual(request.headers["Range"], "bytes=0-")
        XCTAssertEqual(request.range, ByteRange(start: 0, end: nil))
    }

    func testCacheItemExposesProgress() throws {
        let item = try CacheItem(
            url: XCTUnwrap(URL(string: "https://example.com/video.mp4")),
            totalLength: 100,
            cachedLength: 25,
            contentType: "video/mp4",
            lastAccessDate: Date(timeIntervalSince1970: 0),
            zones: [ByteRange(start: 0, end: 24)]
        )
        XCTAssertEqual(item.progress, 0.25)
    }

    func testLogErrorAPIMatchesBehavior() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let error = NSError(domain: "HTTPMediaCacheTests", code: 7)

        await HTTPMediaCache.addError(error, for: url)

        let stored = await HTTPMediaCache.error(for: url) as NSError?
        let errors = await HTTPMediaCache.errors()
        XCTAssertEqual(stored?.domain, "HTTPMediaCacheTests")
        XCTAssertEqual(stored?.code, 7)
        XCTAssertEqual((errors[url] as NSError?)?.code, 7)

        await HTTPMediaCache.cleanError(for: url)
        let cleanedError = await HTTPMediaCache.error(for: url)
        XCTAssertNil(cleanedError)
    }

    func testRecordLogFileURLMatchesEmptyFileBehavior() async {
        await HTTPMediaCache.setRecordLogEnable(false)
        await HTTPMediaCache.deleteRecordLogFile()

        let fileURL = await HTTPMediaCache.recordLogFileURL()

        XCTAssertNil(fileURL)
    }

    func testDeleteRecordLogFileClosesHandleButKeepsExistingFile() async throws {
        await HTTPMediaCache.setRecordLogEnable(true)
        await HTTPMediaCache.addLog("log-before-delete")
        let currentRecordLogFileURL = await HTTPMediaCache.recordLogFileURL()
        let fileURLBeforeDelete = try XCTUnwrap(currentRecordLogFileURL)

        await HTTPMediaCache.deleteRecordLogFile()
        let fileURLAfterDelete = await HTTPMediaCache.recordLogFileURL()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURLBeforeDelete.path))
        XCTAssertNotNil(fileURLAfterDelete)

        await HTTPMediaCache.setRecordLogEnable(false)
        try? FileManager.default.removeItem(at: fileURLBeforeDelete)
    }

    func testDataReaderUsesCachedDataAndOnlyDownloadsMissingRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ReaderSegmentDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: url, range: ByteRange(start: 0, end: 1)), options: .init())
        try await preloadTask.waitForCompletion()

        let reader = await HTTPMediaCache.cacheReader(with: CacheRequest(url: url, range: ByteRange(start: 0, end: 3)))
        let data = try await reader.read()

        XCTAssertEqual(data, Data([0, 1, 2, 3]))
    }

    func testDataReaderSplitsMissingNetworkRangesUsingConfiguredRequestHeaderRangeLength() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ChunkedRangeDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        await HTTPMediaCache.setDownloadRequestHeaderRangeLength { requestURL, totalLength in
            XCTAssertEqual(requestURL, url)
            XCTAssertEqual(totalLength, 6)
            return 2
        }

        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: url, range: ByteRange(start: 0, end: 1)), options: .init())
        try await preloadTask.waitForCompletion()

        let reader = await HTTPMediaCache.cacheReader(with: CacheRequest(url: url, range: ByteRange(start: 0, end: 5)))
        let data = try await reader.read()

        XCTAssertEqual(data, Data([0, 1, 2, 3, 4, 5]))
        let ranges = await downloader.downloadedRanges()
        XCTAssertEqual(ranges, [
            ByteRange(start: 0, end: 1),
            ByteRange(start: 2, end: 3),
            ByteRange(start: 4, end: 5),
        ])
    }
}

private struct ReaderSegmentDownloader: CacheResponseDownloading {
    private let state = ReaderSegmentDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.download(request: request)
    }
}

private actor ReaderSegmentDownloadState {
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
            throw CacheError.networkFailure("unexpected reader download")
        }
    }
}

private struct ChunkedRangeDownloader: CacheResponseDownloading {
    private let state = ChunkedRangeDownloadState()

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

private actor ChunkedRangeDownloadState {
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
