//
//  CacheStorageTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class CacheStorageTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.setURLConverter(nil)
        await HTTPMediaCache.setCacheIdentifierProvider(nil)
        try await super.tearDown()
    }

    func testWritesZonesWithoutMerging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.recordWrite(range: ByteRange(start: 0, end: 99), totalLength: 200, contentType: "video/mp4")
        try await unit.recordWrite(range: ByteRange(start: 100, end: 199), totalLength: 200, contentType: "video/mp4")

        let item = try await index.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 200)
        XCTAssertEqual(item?.zones, [ByteRange(start: 0, end: 99), ByteRange(start: 100, end: 199)])
    }

    func testCacheItemUsesValidLengthForOverlappingZones() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.recordWrite(range: ByteRange(start: 0, end: 99), totalLength: 200, contentType: "video/mp4")
        try await unit.recordWrite(range: ByteRange(start: 50, end: 149), totalLength: 200, contentType: "video/mp4")

        let item = try await index.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 150)
    }

    func testTotalCacheLengthUsesRawCacheLengthForOverlappingZones() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.recordWrite(range: ByteRange(start: 0, end: 99), totalLength: 200, contentType: "video/mp4")
        try await unit.recordWrite(range: ByteRange(start: 50, end: 149), totalLength: 200, contentType: "video/mp4")

        let item = try await index.cacheItem(for: url)
        let totalLength = await index.totalCacheLength()

        XCTAssertEqual(item?.cachedLength, 150)
        XCTAssertEqual(totalLength, 200)
    }

    func testWritesAndReadsCachedRangeData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 8, contentType: "video/mp4")
        try await unit.write(data: Data([4, 5, 6, 7]), offset: 4, totalLength: 8, contentType: "video/mp4")

        let reader = DataReader(
            request: CacheRequest(url: url, range: ByteRange(start: 2, end: 5)),
            cacheIndex: index,
            downloader: MockDownloader.mock(Data())
        )
        let data = try await reader.read()

        XCTAssertEqual(data, Data([2, 3, 4, 5]))
    }

    func testCacheMetadataIsLoadedFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let firstIndex = CacheIndex(rootDirectory: root)
        let unit = try await firstIndex.unit(for: url)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")

        let secondIndex = CacheIndex(rootDirectory: root)
        let item = try await secondIndex.cacheItem(for: url)

        XCTAssertEqual(item?.totalLength, 4)
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.contentType, "video/mp4")
        XCTAssertEqual(item?.zones, [ByteRange(start: 0, end: 3)])
    }

    func testCompleteFileURLRequiresSingleContiguousLeadingZone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.write(data: Data([0, 1]), offset: 0, totalLength: 4, contentType: "video/mp4")
        try await unit.write(data: Data([2, 3]), offset: 2, totalLength: 4, contentType: "video/mp4")

        let completeURL = try await index.completeFileURL(for: url)

        XCTAssertNil(completeURL)
    }

    func testCompleteFileURLUsesCompleteFileNameWithOriginalExtension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        let unit = try await index.unit(for: url)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")

        let maybeCompleteURL = try await index.completeFileURL(for: url)
        let completeURL = try XCTUnwrap(maybeCompleteURL)

        XCTAssertEqual(completeURL.lastPathComponent, "\(CacheIndex.cacheKey(for: url)).mp4")
    }

    func testDeleteCacheRemovesFilesFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let unit = try await index.unit(for: url)
        let directory = await unit.directory

        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")
        await index.deleteCache(for: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let item = try await index.cacheItem(for: url)
        XCTAssertNil(item)
    }

    func testDeleteCacheSkipsWorkingUnit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let unit = try await index.unit(for: url)
        let directory = await unit.directory

        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")
        await unit.workingRetain()
        await index.deleteCache(for: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let retainedItem = try await index.cacheItem(for: url)
        XCTAssertNotNil(retainedItem)

        await unit.workingRelease()
        await index.deleteCache(for: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let deletedItem = try await index.cacheItem(for: url)
        XCTAssertNil(deletedItem)
    }

    func testEvictionSkipsWorkingUnit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        await index.setMaxCacheLength(4)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let thirdURL = try XCTUnwrap(URL(string: "https://example.com/third.mp4"))

        let firstUnit = try await index.unit(for: firstURL)
        try await firstUnit.write(data: Data([0, 1]), offset: 0, totalLength: 2, contentType: "video/mp4")
        await firstUnit.workingRetain()
        let secondUnit = try await index.unit(for: secondURL)
        try await secondUnit.write(data: Data([2, 3]), offset: 0, totalLength: 2, contentType: "video/mp4")

        try await index.prepareForWrite(length: 2, excluding: thirdURL)
        let thirdUnit = try await index.unit(for: thirdURL)
        try await thirdUnit.write(data: Data([4, 5]), offset: 0, totalLength: 2, contentType: "video/mp4")

        let firstItem = try await index.cacheItem(for: firstURL)
        let secondItem = try await index.cacheItem(for: secondURL)
        let thirdItem = try await index.cacheItem(for: thirdURL)

        XCTAssertNotNil(firstItem)
        XCTAssertNil(secondItem)
        XCTAssertNotNil(thirdItem)

        await firstUnit.workingRelease()
    }

    func testURLConverterIsUsedForCacheIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MockDownloader.mock(Data([0, 1, 2, 3])))
        await HTTPMediaCache.setURLConverter { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url ?? url
        }
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=1"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=2"))

        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: firstURL), options: .init())
        try await preloadTask.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: secondURL)
        XCTAssertEqual(item?.cachedLength, 4)
    }

    func testCacheIdentifierProviderOverridesURLConverterForCacheIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MockDownloader.mock(Data([0, 1, 2, 3])))
        await HTTPMediaCache.setURLConverter { url in
            URL(string: "https://example.com/converter-\(url.lastPathComponent)") ?? url
        }
        await HTTPMediaCache.setCacheIdentifierProvider { url in
            "media-\(url.deletingPathExtension().lastPathComponent)"
        }
        let firstURL = try XCTUnwrap(URL(string: "https://cdn-a.example.com/video.mp4?token=1"))
        let secondURL = try XCTUnwrap(URL(string: "https://cdn-b.example.com/video.mov?token=2"))

        let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: firstURL), options: .init())
        try await preloadTask.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: secondURL)
        XCTAssertEqual(item?.cachedLength, 4)
    }

    func testURLConverterCacheIdentitySurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=1"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=2"))
        let converter: @Sendable (URL) -> URL = { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url ?? url
        }

        let firstIndex = CacheIndex(rootDirectory: root)
        await firstIndex.setURLConverter(converter)
        let unit = try await firstIndex.unit(for: firstURL)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")

        let secondIndex = CacheIndex(rootDirectory: root)
        await secondIndex.setURLConverter(converter)
        let item = try await secondIndex.cacheItem(for: secondURL)

        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.zones, [ByteRange(start: 0, end: 3)])
    }

    func testSettingURLConverterDoesNotRewriteExistingUnitIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=1"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=2"))
        let index = CacheIndex(rootDirectory: root)

        let unit = try await index.unit(for: firstURL)
        try await unit.write(data: Data([0, 1, 2, 3]), offset: 0, totalLength: 4, contentType: "video/mp4")
        await index.setURLConverter { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url ?? url
        }

        let item = try await index.cacheItem(for: secondURL)

        XCTAssertNil(item)
    }

    func testCacheItemLookupDoesNotAffectEvictionOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        await index.setMaxCacheLength(4)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let thirdURL = try XCTUnwrap(URL(string: "https://example.com/third.mp4"))

        let firstUnit = try await index.unit(for: firstURL)
        try await firstUnit.write(data: Data([0, 1]), offset: 0, totalLength: 2, contentType: "video/mp4")
        let secondUnit = try await index.unit(for: secondURL)
        try await secondUnit.write(data: Data([2, 3]), offset: 0, totalLength: 2, contentType: "video/mp4")
        _ = try await index.cacheItem(for: firstURL)

        try await index.prepareForWrite(length: 2, excluding: thirdURL)
        let thirdUnit = try await index.unit(for: thirdURL)
        try await thirdUnit.write(data: Data([4, 5]), offset: 0, totalLength: 2, contentType: "video/mp4")

        let firstItem = try await index.cacheItem(for: firstURL)
        let secondItem = try await index.cacheItem(for: secondURL)
        let thirdItem = try await index.cacheItem(for: thirdURL)

        XCTAssertNil(firstItem)
        XCTAssertNotNil(secondItem)
        XCTAssertNotNil(thirdItem)
    }

    func testEvictionUsesUnitQueueOrderInsteadOfLastWriteDate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let index = CacheIndex(rootDirectory: root)
        await index.setMaxCacheLength(4)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let thirdURL = try XCTUnwrap(URL(string: "https://example.com/third.mp4"))

        let firstUnit = try await index.unit(for: firstURL)
        let secondUnit = try await index.unit(for: secondURL)
        try await secondUnit.write(data: Data([2, 3]), offset: 0, totalLength: 2, contentType: "video/mp4")
        try await firstUnit.write(data: Data([0, 1]), offset: 0, totalLength: 2, contentType: "video/mp4")

        try await index.prepareForWrite(length: 2, excluding: thirdURL)
        let thirdUnit = try await index.unit(for: thirdURL)
        try await thirdUnit.write(data: Data([4, 5]), offset: 0, totalLength: 2, contentType: "video/mp4")

        let firstItem = try await index.cacheItem(for: firstURL)
        let secondItem = try await index.cacheItem(for: secondURL)
        let thirdItem = try await index.cacheItem(for: thirdURL)

        XCTAssertNil(firstItem)
        XCTAssertNotNil(secondItem)
        XCTAssertNotNil(thirdItem)
    }

    func testCacheReaderRetainsWorkingUnitDuringRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloader = BlockingSegmentDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: url)
        try await unit.write(data: Data([0, 1]), offset: 0, totalLength: 4, contentType: "video/mp4")

        let reader = await HTTPMediaCache.cacheReader(with: CacheRequest(url: url, range: ByteRange(start: 0, end: 3)))
        async let loadedData = reader.read()
        await downloader.waitUntilStarted()

        try await HTTPMediaCache.deleteCache(for: url)
        await downloader.finish()

        let data = try await loadedData
        let item = try await HTTPMediaCache.cacheItem(for: url)
        let completeURL = try await HTTPMediaCache.completeFileURL(for: url)

        XCTAssertEqual(data, Data([0, 1, 2, 3]))
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.zones, [ByteRange(start: 0, end: 3)])
        XCTAssertNotNil(completeURL)
    }
}

private struct BlockingSegmentDownloader: CacheResponseDownloading {
    private let state = BlockingSegmentDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try [await downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.download(request: request)
    }

    func waitUntilStarted() async {
        await state.waitUntilStarted()
    }

    func finish() async {
        await state.finish()
    }
}

private actor BlockingSegmentDownloadState {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var isStarted = false
    private var isFinished = false

    func download(request: CacheRequest) async throws -> CacheDownloadResponse {
        XCTAssertEqual(request.range, ByteRange(start: 2, end: 3))
        isStarted = true
        startedContinuation?.resume()
        startedContinuation = nil

        if !isFinished {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }

        return CacheDownloadResponse(
            data: Data([2, 3]),
            statusCode: 206,
            headers: [
                "Content-Length": "2",
                "Content-Range": "bytes 2-3/4",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func waitUntilStarted() async {
        if isStarted {
            return
        }

        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish() {
        isFinished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
