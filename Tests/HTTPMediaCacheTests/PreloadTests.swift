//
//  PreloadTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
@testable import HTTPMediaCache
import XCTest

final class PreloadTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.stop()
        await HTTPMediaCache.setMaxCacheLength(500 * 1024 * 1024)
        await HTTPMediaCache.setHLSVariantStreamSelectionHandler(nil)
        await HTTPMediaCache.setHLSRenditionSelectionHandler(nil)
        await HTTPMediaCache.setHLSDownloadHeaderProvider(nil)
        try await super.tearDown()
    }

    func testPreloadCreatesCacheItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MockDownloader.mock(Data(repeating: 3, count: 8)))

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        try await task.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 8)
    }

    func testPreloadSkipsDownloadWhenResourceIsAlreadyFullyCached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = DuplicatePreloadGuardDownloader(data: Data([0, 1, 2, 3]))
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let firstTask = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        try await firstTask.waitForCompletion()
        let secondTask = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        try await secondTask.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: url)
        let error = await HTTPMediaCache.error(for: url)
        let downloadCount = await downloader.downloadCount()
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.progress, 1)
        XCTAssertEqual(downloadCount, 1)
        XCTAssertNil(error)
    }

    func testSuccessfulPreloadClearsPreviousError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MockDownloader.mock(Data(repeating: 3, count: 8)))

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        await HTTPMediaCache.addError(CacheError.networkFailure("previous failure"), for: url)

        let task = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        try await task.waitForCompletion()

        let error = await HTTPMediaCache.error(for: url)
        XCTAssertNil(error)
    }

    func testPreloadReturnsTaskBeforeDownloadFinishesAndCancelStopsCacheWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = BlockingPreloadDownloader(data: Data([0, 1, 2, 3]))
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await withTimeout(nanoseconds: 200_000_000) {
            try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        }
        await downloader.waitUntilStarted()

        task.cancel()
        await downloader.finish()
        try await Task.sleep(nanoseconds: 50_000_000)

        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertNil(item)
    }

    func testStreamingPreloadReportsIncrementalProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = StreamingPreloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        var progressIterator = task.progress.makeAsyncIterator()
        await downloader.waitUntilStreamRequested()

        await downloader.yield(Data([0, 1]))
        let firstProgress = await progressIterator.next()
        await downloader.yield(Data([2, 3]))
        await downloader.finish()
        let secondProgress = await progressIterator.next()

        XCTAssertEqual(firstProgress, 0.5)
        XCTAssertEqual(secondProgress, 1.0)
        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 4)
    }

    func testPreloadWritesReadableCacheData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = SingleUsePreloadDownloader(data: Data([0, 1, 2, 3]))
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(CacheRequest(url: url), options: .init())
        try await task.waitForCompletion()
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: url)
        var request = URLRequest(url: proxy)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data([0, 1, 2, 3]))
    }

    func testPreloadRespectsMaxCacheLengthByDeletingOldCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: FixedLengthPreloadDownloader())
        await HTTPMediaCache.setMaxCacheLength(4)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let firstTask = try await HTTPMediaCache.preload(CacheRequest(url: firstURL), options: .init())
        try await firstTask.waitForCompletion()
        let secondTask = try await HTTPMediaCache.preload(CacheRequest(url: secondURL), options: .init())
        try await secondTask.waitForCompletion()

        let firstItem = try await HTTPMediaCache.cacheItem(for: firstURL)
        let secondItem = try await HTTPMediaCache.cacheItem(for: secondURL)
        let totalLength = try await HTTPMediaCache.totalCacheLength()

        XCTAssertNil(firstItem)
        XCTAssertEqual(secondItem?.cachedLength, 4)
        XCTAssertLessThanOrEqual(totalLength, 4)
    }

    func testPrefetchSizeCachesOnlyRequestedFilePrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: RangeAssertingFilePrefetchDownloader())

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(url, prefetchSize: 4)
        try await task.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.zones, [
            ByteRange(start: 0, end: 1),
            ByteRange(start: 2, end: 3),
        ])
    }

    func testFilePreloadPlannerCapsTargetLengthToTotalLength() throws {
        let planner = FilePreloadPlanner()

        let plan = try planner.plan(
            requestedStart: 0,
            requestedByteCount: 10,
            totalLength: 4,
            cachedZones: []
        )

        XCTAssertEqual(plan.targetRange, ByteRange(start: 0, end: 3))
        XCTAssertEqual(plan.missingRanges, [ByteRange(start: 0, end: 3)])
        XCTAssertEqual(plan.targetLength, 4)
    }

    func testFilePreloadPlannerSkipsCachedPrefixRanges() throws {
        let planner = FilePreloadPlanner()

        let plan = try planner.plan(
            requestedStart: 0,
            requestedByteCount: 10,
            totalLength: 20,
            cachedZones: [ByteRange(start: 0, end: 3), ByteRange(start: 7, end: 8)]
        )

        XCTAssertEqual(plan.targetRange, ByteRange(start: 0, end: 9))
        XCTAssertEqual(plan.missingRanges, [
            ByteRange(start: 4, end: 6),
            ByteRange(start: 9, end: 9),
        ])
        XCTAssertEqual(plan.targetLength, 10)
    }

    func testFilePreloadPlannerUsesMinimumChunkSize() {
        let planner = FilePreloadPlanner()

        XCTAssertEqual(planner.chunkLength(forTargetLength: 100), 10 * 1024 * 1024)
        XCTAssertEqual(planner.chunkLength(forTargetLength: 400 * 1024 * 1024), 20 * 1024 * 1024)
    }

    func testHLSPreloadPlannerBuildsChildPlaylistPlanWithSelectedRenditionsWithoutIFramePlaylist() async throws {
        let masterURL = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
        let playlist = HLSPlaylistParser().parse(
            playlist: """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,URI="subtitles/en/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="aud",SUBTITLES="subs"
            low/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=300000,AUDIO="aud",SUBTITLES="subs"
            high/index.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
            """,
            sourceURL: masterURL
        )
        await HTTPMediaCache.setHLSVariantStreamSelectionHandler { variants, _, _ in
            variants.first { $0.bandwidth == 300_000 }
        }
        await HTTPMediaCache.setHLSRenditionSelectionHandler { _, renditions, _, _ in
            renditions.first { $0.isDefault }
        }
        let planner = HLSPreloadPlanner()

        let plan = await planner.plan(playlist: playlist, options: .init(), originalURL: masterURL, currentURL: masterURL)

        guard case let .childPlaylists(requests) = plan else {
            return XCTFail("Expected child playlist plan")
        }
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://example.com/high/index.m3u8",
            "https://example.com/audio/en/index.m3u8",
            "https://example.com/subtitles/en/index.m3u8",
        ])
    }

    func testHLSVariantAndRenditionSelectionExposeDetailedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: DetailedSelectionPlaylistDownloader())

        await HTTPMediaCache.setHLSVariantStreamSelectionHandler { streams, _, _ in
            XCTAssertEqual(streams.count, 2)
            let target = streams.first { stream in
                stream.averageBandwidth == 90000 &&
                    stream.codecs == "avc1.64001f,mp4a.40.2" &&
                    stream.resolution == "1280x720" &&
                    stream.videoRange == "SDR" &&
                    stream.frameRate == 29.97
            }
            XCTAssertNotNil(target)
            return target
        }

        await HTTPMediaCache.setHLSRenditionSelectionHandler { type, renditions, _, _ in
            XCTAssertEqual(type, .audio)
            let target = renditions.first { rendition in
                rendition.name == "English" &&
                    rendition.language == "en" &&
                    rendition.isAutoSelect &&
                    rendition.isDefault
            }
            XCTAssertNotNil(target)
            return target
        }

        let masterURL = try XCTUnwrap(URL(string: "https://example.com/detailed/master.m3u8"))
        let selectedSegmentURL = try XCTUnwrap(URL(string: "https://example.com/detailed/selected/segment-1.ts"))
        let audioSegmentURL = try XCTUnwrap(URL(string: "https://example.com/detailed/audio/en/segment-1.ts"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: masterURL),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )
        try await task.waitForCompletion()

        let selectedSegment = try await HTTPMediaCache.cacheItem(for: selectedSegmentURL)
        let audioSegment = try await HTTPMediaCache.cacheItem(for: audioSegmentURL)
        XCTAssertEqual(selectedSegment?.cachedLength, 3)
        XCTAssertEqual(audioSegment?.cachedLength, 2)
    }

    func testHLSPreloadPlannerBuildsMediaActionsWithDependenciesAndByteRanges() async throws {
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let playlist = HLSPlaylistParser().parse(
            playlist: """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key-a.bin"
            #EXT-X-MAP:URI="init-a.mp4",BYTERANGE="4@0"
            #EXTINF:5,
            #EXT-X-BYTERANGE:6@10
            file.ts
            #EXT-X-KEY:METHOD=AES-128,URI="key-b.bin"
            #EXT-X-MAP:URI="init-b.mp4",BYTERANGE="8@20"
            #EXTINF:5,
            #EXT-X-BYTERANGE:6@16
            file.ts
            """,
            sourceURL: playlistURL
        )
        let planner = HLSPreloadPlanner()

        let plan = await planner.plan(
            playlist: playlist,
            options: PreloadOptions(hlsLimit: .segmentCount(2)),
            originalURL: playlistURL,
            currentURL: playlistURL
        )

        guard case let .media(mediaPlan) = plan else {
            return XCTFail("Expected media plan")
        }
        XCTAssertEqual(mediaPlan.targetSegments, 2)
        XCTAssertEqual(mediaPlan.actions.map(\.reference.type), [
            .key,
            .initialization,
            .segment,
            .key,
            .initialization,
            .segment,
        ])
        XCTAssertEqual(mediaPlan.actions.map(\.reference.url.lastPathComponent), [
            "key-a.bin",
            "init-a.mp4",
            "file.ts",
            "key-b.bin",
            "init-b.mp4",
            "file.ts",
        ])
        XCTAssertEqual(mediaPlan.actions[1].reference.byteRange, ByteRange(start: 0, end: 3))
        XCTAssertEqual(mediaPlan.actions[2].reference.byteRange, ByteRange(start: 10, end: 15))
        XCTAssertEqual(mediaPlan.actions[4].reference.byteRange, ByteRange(start: 20, end: 27))
        XCTAssertEqual(mediaPlan.actions[5].reference.byteRange, ByteRange(start: 16, end: 21))
    }

    func testHLSDownloadPolicyBuildsTypeAwareRequests() async throws {
        let policy = HLSDownloadPolicy()
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let sourceRequest = CacheRequest(
            url: playlistURL,
            headers: [
                "Accept-Encoding": "gzip",
                "Range": "bytes=20-40",
                "User-Agent": "UnitTest",
            ]
        )

        let playlistRequest = await policy.playlistRequest(from: sourceRequest)
        XCTAssertEqual(playlistRequest.url, playlistURL)
        XCTAssertNil(playlistRequest.range)
        XCTAssertEqual(playlistRequest.headers, [:])

        let keyURL = try XCTUnwrap(URL(string: "https://example.com/video/key.bin"))
        let keyRequest = await policy.resourceRequest(for: HLSResourceReference(type: .key, url: keyURL))
        XCTAssertNil(keyRequest.range)
        XCTAssertEqual(keyRequest.headers, [:])

        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment.ts"))
        let segmentRequest = await policy.resourceRequest(for: HLSResourceReference(type: .segment, url: segmentURL))
        XCTAssertNil(segmentRequest.range)
        XCTAssertEqual(segmentRequest.headers, [:])

        let initURL = try XCTUnwrap(URL(string: "https://example.com/video/init.mp4"))
        let initRequest = await policy.resourceRequest(for: HLSResourceReference(
            type: .initialization,
            url: initURL,
            byteRange: ByteRange(start: 12, end: 15)
        ))
        XCTAssertEqual(initRequest.range, ByteRange(start: 12, end: 15))
        XCTAssertEqual(initRequest.headers, ["Range": "bytes=12-15"])
    }

    func testHLSDownloadPolicyAppliesResourceHeadersWithoutOverridingRange() async throws {
        await HTTPMediaCache.setHLSDownloadHeaderProvider { context in
            [
                "Range": "bytes=0-0",
                "X-Resource-Kind": context.kind.rawValue,
            ]
        }

        let policy = HLSDownloadPolicy()
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let playlistRequest = await policy.playlistRequest(from: CacheRequest(url: playlistURL))
        XCTAssertNil(playlistRequest.range)
        XCTAssertEqual(playlistRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.playlist.rawValue)
        XCTAssertNil(playlistRequest.headers["Range"])

        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment.ts"))
        let segmentRequest = await policy.resourceRequest(for: HLSResourceReference(
            type: .segment,
            url: segmentURL,
            byteRange: ByteRange(start: 12, end: 15)
        ))
        XCTAssertEqual(segmentRequest.range, ByteRange(start: 12, end: 15))
        XCTAssertEqual(segmentRequest.headers["Range"], "bytes=12-15")
        XCTAssertEqual(segmentRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.segment.rawValue)
    }

    func testHLSDownloadPolicyMapsPlaylistKinds() async throws {
        await HTTPMediaCache.setHLSDownloadHeaderProvider { context in
            ["X-Resource-Kind": context.kind.rawValue]
        }

        let policy = HLSDownloadPolicy()
        let variantURL = try XCTUnwrap(URL(string: "https://example.com/video/variant.m3u8"))
        let renditionURL = try XCTUnwrap(URL(string: "https://example.com/video/rendition.m3u8"))
        let subtitleURL = try XCTUnwrap(URL(string: "https://example.com/video/subtitle.m3u8"))
        let iframeURL = try XCTUnwrap(URL(string: "https://example.com/video/iframe.m3u8"))

        let variantRequest = await policy.resourceRequest(for: HLSResourceReference(type: .variantPlaylist, url: variantURL))
        let renditionRequest = await policy.resourceRequest(for: HLSResourceReference(type: .renditionPlaylist, url: renditionURL))
        let subtitleRequest = await policy.resourceRequest(for: HLSResourceReference(type: .subtitlePlaylist, url: subtitleURL))
        let iframeRequest = await policy.resourceRequest(for: HLSResourceReference(type: .iFramePlaylist, url: iframeURL))

        XCTAssertEqual(variantRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.variantPlaylist.rawValue)
        XCTAssertEqual(renditionRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.renditionPlaylist.rawValue)
        XCTAssertEqual(subtitleRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.subtitlePlaylist.rawValue)
        XCTAssertEqual(iframeRequest.headers["X-Resource-Kind"], HLSDownloadResourceKind.iFramePlaylist.rawValue)
        XCTAssertNil(variantRequest.range)
        XCTAssertNil(renditionRequest.range)
        XCTAssertNil(subtitleRequest.range)
        XCTAssertNil(iframeRequest.range)
    }

    func testHLSPreloadUsesTypeAwareDownloadRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = HLSRequestPolicyDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)
        await HTTPMediaCache.setHLSDownloadHeaderProvider { context in
            ["X-HLS-Kind": context.kind.rawValue]
        }

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/policy/index.m3u8"))
        let task = try await HTTPMediaCache.preload(
            CacheRequest(
                url: playlistURL,
                headers: [
                    "Accept-Encoding": "gzip",
                    "Range": "bytes=10-20",
                    "User-Agent": "UnitTest",
                ]
            ),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )
        try await task.waitForCompletion()

        let requests = await downloader.requests()
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://example.com/policy/index.m3u8",
            "https://example.com/policy/key.bin",
            "https://example.com/policy/init.mp4",
            "https://example.com/policy/segment-1.ts",
        ])
        XCTAssertTrue(requests.allSatisfy { request in
            request.headers["User-Agent"] == nil && request.headers["Accept-Encoding"] == nil
        })
        XCTAssertEqual(requests.map { $0.headers["X-HLS-Kind"] }, [
            HLSDownloadResourceKind.playlist.rawValue,
            HLSDownloadResourceKind.key.rawValue,
            HLSDownloadResourceKind.initialization.rawValue,
            HLSDownloadResourceKind.segment.rawValue,
        ])
        XCTAssertNil(requests[0].range)
        XCTAssertNil(requests[1].range)
        XCTAssertEqual(requests[2].range, ByteRange(start: 4, end: 7))
        XCTAssertNil(requests[3].range)
    }

    func testPrefetchSizeProbesFileLengthBeforeChunkedPreload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ProbingFilePreloadDownloader(totalLength: 6)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(url, prefetchSize: 10)
        try await task.waitForCompletion()

        let ranges = await downloader.ranges()
        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertEqual(ranges.compactMap { $0 }, [
            ByteRange(start: 0, end: 1),
            ByteRange(start: 2, end: 5),
        ])
        XCTAssertEqual(item?.cachedLength, 6)
        XCTAssertEqual(item?.totalLength, 6)
    }

    func testPrefetchSizeReusesAlreadyCachedFileRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ProbingFilePreloadDownloader(totalLength: 8)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let firstTask = try await HTTPMediaCache.preload(CacheRequest(url: url, range: ByteRange(start: 0, end: 3)), options: .init())
        try await firstTask.waitForCompletion()

        let secondTask = try await HTTPMediaCache.preload(url, prefetchSize: 6)
        try await secondTask.waitForCompletion()

        let ranges = await downloader.ranges().compactMap { $0 }
        XCTAssertTrue(ranges.contains(ByteRange(start: 4, end: 5)))
        XCTAssertFalse(ranges.contains(ByteRange(start: 0, end: 5)))
    }

    func testChunkedFilePreloadReportsProgressToOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ProbingFilePreloadDownloader(totalLength: 6)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(url, prefetchSize: 6)
        let progressValues = try await collectProgressValues(from: task.progress)
        try await task.waitForCompletion()

        XCTAssertEqual(progressValues.last, 1)
    }

    func testChunkedFilePreloadCancellationStopsLaterWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = BlockingChunkedFilePreloadDownloader(totalLength: 6)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(url, prefetchSize: 6)
        await downloader.waitUntilBlocked()

        task.cancel()
        await downloader.finish()
        try? await task.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertFalse(item?.zones.contains(ByteRange(start: 2, end: 5)) == true)
    }

    func testPrefetchFileCountCachesWholeFileResource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: SingleUsePreloadDownloader(data: Data([0, 1, 2, 3, 4, 5])))

        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let task = try await HTTPMediaCache.preload(url, prefetchFileCount: 2)
        try await task.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: url)
        XCTAssertEqual(item?.cachedLength, 6)
        XCTAssertEqual(item?.progress, 1)
    }

    func testMaxConcurrentPreloadCountSerializesQueuedTasksByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = QueuedPreloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let firstTask = try await HTTPMediaCache.preload(firstURL)
        let secondTask = try await HTTPMediaCache.preload(secondURL)
        await downloader.waitUntilStarted(count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let startedCountBeforeFinishingFirstTask = await downloader.startedCount()
        XCTAssertEqual(startedCountBeforeFinishingFirstTask, 1)

        await downloader.finishNext()
        await downloader.waitUntilStarted(count: 2)
        await downloader.finishNext()
        try await firstTask.waitForCompletion()
        try await secondTask.waitForCompletion()

        let startedCount = await downloader.startedCount()
        XCTAssertEqual(startedCount, 2)
    }

    func testSetMaxConcurrentPreloadCountAllowsMultipleTasksToRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = QueuedPreloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)
        await HTTPMediaCache.setMaxConcurrentPreloadCount(2)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let firstTask = try await HTTPMediaCache.preload(firstURL)
        let secondTask = try await HTTPMediaCache.preload(secondURL)
        await downloader.waitUntilStarted(count: 2)
        let maxConcurrentCount = await HTTPMediaCache.maxConcurrentPreloadCount()

        await downloader.finishNext()
        await downloader.finishNext()
        try await firstTask.waitForCompletion()
        try await secondTask.waitForCompletion()

        let startedCount = await downloader.startedCount()
        XCTAssertEqual(maxConcurrentCount, 2)
        XCTAssertEqual(startedCount, 2)
    }

    func testCancelAllPreloadTasksCancelsRunningAndQueuedTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = QueuedPreloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.mp4"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.mp4"))
        let firstTask = try await HTTPMediaCache.preload(firstURL)
        let secondTask = try await HTTPMediaCache.preload(secondURL)
        await downloader.waitUntilStarted(count: 1)

        await HTTPMediaCache.cancelAllPreloadTasks()
        await downloader.finishNext()
        try? await firstTask.waitForCompletion()
        try? await secondTask.waitForCompletion()

        let startedCount = await downloader.startedCount()
        let firstItem = try await HTTPMediaCache.cacheItem(for: firstURL)
        let secondItem = try await HTTPMediaCache.cacheItem(for: secondURL)
        XCTAssertEqual(startedCount, 1)
        XCTAssertNil(firstItem)
        XCTAssertNil(secondItem)
    }

    func testDefaultMaxCacheLengthMatches() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MockDownloader.mock(Data()))

        let maxCacheLength = await HTTPMediaCache.maxCacheLength()

        XCTAssertEqual(maxCacheLength, 500 * 1024 * 1024)
    }

    func testPreloadTaskWaitForCompletionThrowsDownloadError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: FailingPreloadDownloader())

        let url = try XCTUnwrap(URL(string: "https://example.com/failing.mp4"))
        let task = try await HTTPMediaCache.preload(url)

        do {
            try await task.waitForCompletion()
            XCTFail("waitForCompletion should throw the download error")
        } catch let CacheError.networkFailure(message) {
            XCTAssertEqual(message, "preload failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recordedError = await HTTPMediaCache.error(for: url)
        XCTAssertEqual(recordedError?.domain, "HTTPMediaCache.CacheError")
        XCTAssertEqual(recordedError?.code, 1)
    }

    func testHLSPreloadCachesPlaylistAndSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        #EXTINF:10,
        segment-2.ts
        """
        let downloader = HLSRecursivePreloadDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "http://cdn.example.com/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-2.ts"))
        let task = try await HTTPMediaCache.preload(CacheRequest(url: playlistURL), options: .init())
        try await task.waitForCompletion()

        let playlistItem = try await HTTPMediaCache.cacheItem(for: playlistURL)
        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let playlistUnit = try await cacheIndex.unit(for: playlistURL)
        let cachedPlaylistData = try await playlistUnit.read(range: ByteRange(start: 0, end: Int64(playlist.utf8.count) - 1))
        let cachedPlaylist = try XCTUnwrap(cachedPlaylistData.flatMap { String(data: $0, encoding: .utf8) })

        XCTAssertEqual(playlistItem?.cachedLength, Int64(playlist.utf8.count))
        XCTAssertEqual(cachedPlaylist, playlist)
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
    }

    func testHLSPreloadCachesSubresourcesUsingCacheIdentifierProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin?token=origin"
        #EXT-X-MAP:URI="init.mp4?token=origin",BYTERANGE="4@8"
        #EXTINF:10,
        segment-1.ts?token=origin
        """
        let downloader = HLSIdentityProviderDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)
        await HTTPMediaCache.setCacheIdentifierProvider { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return components?.url?.absoluteString ?? url.absoluteString
        }

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8?token=origin"))
        let keyLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/key.bin?token=lookup"))
        let initLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/init.mp4?token=lookup"))
        let segmentLookupURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-1.ts?token=lookup"))
        let task = try await HTTPMediaCache.preload(CacheRequest(url: playlistURL), options: .init(hlsLimit: .segmentCount(1)))
        try await task.waitForCompletion()

        let keyItem = try await HTTPMediaCache.cacheItem(for: keyLookupURL)
        let initItem = try await HTTPMediaCache.cacheItem(for: initLookupURL)
        let segmentItem = try await HTTPMediaCache.cacheItem(for: segmentLookupURL)

        XCTAssertEqual(keyItem?.cachedLength, 2)
        XCTAssertEqual(initItem?.cachedLength, 4)
        XCTAssertEqual(segmentItem?.cachedLength, 4)
    }

    func testCacheHLSLoaderCachesPlaylistAndSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        #EXTINF:10,
        segment-2.ts
        """
        let downloader = HLSRecursivePreloadDownloader(playlist: playlist)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "http://cdn.example.com/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-2.ts"))
        let loader = await HTTPMediaCache.cacheHLSLoader(with: CacheRequest(url: playlistURL))
        _ = try await loader.load()

        let playlistItem = try await HTTPMediaCache.cacheItem(for: playlistURL)
        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)

        XCTAssertEqual(playlistItem?.cachedLength, Int64(playlist.utf8.count + 2))
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
    }

    func testCacheHLSLoaderUsesCachedPlaylistBeforeDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cachedPlaylist = """
        #EXTM3U
        #EXTINF:10,
        segment-1.ts
        """
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-1.ts"))
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: CachedPlaylistSegmentDownloader())

        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: playlistURL)
        try await unit.write(
            data: Data(cachedPlaylist.utf8),
            offset: 0,
            totalLength: Int64(cachedPlaylist.utf8.count),
            contentType: "application/x-mpegURL"
        )

        let loader = await HTTPMediaCache.cacheHLSLoader(with: CacheRequest(url: playlistURL))
        let data = try await loader.load()

        let segment = try await HTTPMediaCache.cacheItem(for: segmentURL)
        XCTAssertEqual(String(data: data, encoding: .utf8), cachedPlaylist)
        XCTAssertEqual(segment?.cachedLength, 3)
    }

    func testHLSPreloadUsesCachedPlaylistBeforeDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cachedPlaylist = """
        #EXTM3U
        #EXTINF:10,
        segment-1.ts
        """
        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-1.ts"))
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: CachedPlaylistSegmentDownloader())

        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let unit = try await cacheIndex.unit(for: playlistURL)
        try await unit.write(
            data: Data(cachedPlaylist.utf8),
            offset: 0,
            totalLength: Int64(cachedPlaylist.utf8.count),
            contentType: "application/x-mpegURL"
        )

        let task = try await HTTPMediaCache.preload(CacheRequest(url: playlistURL), options: .init())
        try await task.waitForCompletion()

        let segment = try await HTTPMediaCache.cacheItem(for: segmentURL)
        XCTAssertEqual(segment?.cachedLength, 3)
    }

    func testHLSPreloadInvalidatesProxyPlaylistCacheBeforeDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        segment-2.ts
        """
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: HLSRecursivePreloadDownloader(playlist: playlist))

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/live/index.m3u8"))
        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/live/segment-2.ts"))
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

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: playlistURL),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )
        try await task.waitForCompletion()

        let playlistItem = try await HTTPMediaCache.cacheItem(for: playlistURL)
        let segmentItem = try await HTTPMediaCache.cacheItem(for: segmentURL)

        XCTAssertEqual(playlistItem?.cachedLength, Int64(playlist.utf8.count))
        XCTAssertEqual(segmentItem?.cachedLength, 4)
    }

    func testHLSPreloadWithSegmentCountRecursesIntoSelectedVariantPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MasterPlaylistDownloader())

        let masterURL = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
        let variantURL = try XCTUnwrap(URL(string: "https://example.com/high/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "https://example.com/high/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/high/segment-2.ts"))
        let thirdSegmentURL = try XCTUnwrap(URL(string: "https://example.com/high/segment-3.ts"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: masterURL),
            options: PreloadOptions(hlsLimit: .segmentCount(2))
        )
        try await task.waitForCompletion()

        let masterItem = try await HTTPMediaCache.cacheItem(for: masterURL)
        let variantItem = try await HTTPMediaCache.cacheItem(for: variantURL)
        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        let thirdSegment = try await HTTPMediaCache.cacheItem(for: thirdSegmentURL)
        XCTAssertNotNil(masterItem)
        XCTAssertNotNil(variantItem)
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
        XCTAssertNil(thirdSegment)
    }

    func testHLSPreloadWithDurationConvenienceAPICachesEnoughSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MediaPlaylistWithDependenciesDownloader())

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-2.ts"))
        let thirdSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-3.ts"))

        let task = try await HTTPMediaCache.preload(playlistURL, preloadDuration: 12)
        try await task.waitForCompletion()

        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        let thirdSegment = try await HTTPMediaCache.cacheItem(for: thirdSegmentURL)
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
        XCTAssertNil(thirdSegment)
    }

    func testHLSPreloadWithDurationCachesEnoughSegmentsAndDependencies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MediaPlaylistWithDependenciesDownloader())

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let keyURL = try XCTUnwrap(URL(string: "https://example.com/video/key.bin"))
        let initURL = try XCTUnwrap(URL(string: "https://example.com/video/init.mp4"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-2.ts"))
        let thirdSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-3.ts"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: playlistURL),
            options: PreloadOptions(hlsLimit: .duration(12))
        )
        try await task.waitForCompletion()

        let keyItem = try await HTTPMediaCache.cacheItem(for: keyURL)
        let initItem = try await HTTPMediaCache.cacheItem(for: initURL)
        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        let thirdSegment = try await HTTPMediaCache.cacheItem(for: thirdSegmentURL)
        XCTAssertEqual(keyItem?.cachedLength, 2)
        XCTAssertEqual(initItem?.cachedLength, 2)
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
        XCTAssertNil(thirdSegment)
    }

    func testHLSPreloadStopsBeforeLoadingLateDependenciesAfterDurationThreshold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: LateDependencyMediaPlaylistDownloader())

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let keyURL = try XCTUnwrap(URL(string: "https://example.com/video/key.bin"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-2.ts"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: playlistURL),
            options: PreloadOptions(hlsLimit: .duration(6))
        )
        try await task.waitForCompletion()

        let keyItem = try await HTTPMediaCache.cacheItem(for: keyURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        XCTAssertNil(keyItem)
        XCTAssertNil(secondSegment)
    }

    func testHLSPreloadWithPrefetchSizeCachesSegmentsUntilRequestedBytesAreReached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MediaPlaylistWithDependenciesDownloader())

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))
        let firstSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-1.ts"))
        let secondSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-2.ts"))
        let thirdSegmentURL = try XCTUnwrap(URL(string: "https://example.com/video/segment-3.ts"))

        let task = try await HTTPMediaCache.preload(playlistURL, prefetchSize: 7)
        try await task.waitForCompletion()

        let firstSegment = try await HTTPMediaCache.cacheItem(for: firstSegmentURL)
        let secondSegment = try await HTTPMediaCache.cacheItem(for: secondSegmentURL)
        let thirdSegment = try await HTTPMediaCache.cacheItem(for: thirdSegmentURL)
        XCTAssertEqual(firstSegment?.cachedLength, 3)
        XCTAssertEqual(secondSegment?.cachedLength, 4)
        XCTAssertNil(thirdSegment)
    }

    func testHLSPreloadUsesByteRangeForPartialSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: ByteRangePlaylistDownloader())

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/ranged/index.m3u8"))
        let segmentURL = try XCTUnwrap(URL(string: "https://example.com/ranged/file.ts"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: playlistURL),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )
        try await task.waitForCompletion()

        let item = try await HTTPMediaCache.cacheItem(for: segmentURL)
        XCTAssertEqual(item?.cachedLength, 4)
        XCTAssertEqual(item?.zones.first?.start, 10)
        XCTAssertEqual(item?.zones.first?.end, 13)
    }

    func testHLSPreloadUsesCustomSelectionHandlersAndAggregatesProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: MasterPlaylistSelectionDownloader())
        await HTTPMediaCache.setHLSVariantStreamSelectionHandler { streams, _, _ in
            streams.first(where: { $0.bandwidth == 100_000 })
        }
        await HTTPMediaCache.setHLSRenditionSelectionHandler { type, renditions, _, _ in
            guard type == .audio else {
                return renditions.first
            }
            return renditions.first(where: { $0.url?.absoluteString.contains("/es/") == true })
        }

        let masterURL = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
        let lowSegmentURL = try XCTUnwrap(URL(string: "https://example.com/low/segment-1.ts"))
        let highSegmentURL = try XCTUnwrap(URL(string: "https://example.com/high/segment-1.ts"))
        let spanishSegmentURL = try XCTUnwrap(URL(string: "https://example.com/audio/es/segment-1.ts"))
        let englishSegmentURL = try XCTUnwrap(URL(string: "https://example.com/audio/en/segment-1.ts"))

        let task = try await HTTPMediaCache.preload(masterURL)
        let progressValues = try await collectProgressValues(from: task.progress)
        try await task.waitForCompletion()

        let masterItem = try await HTTPMediaCache.cacheItem(for: masterURL)
        let lowSegmentItem = try await HTTPMediaCache.cacheItem(for: lowSegmentURL)
        let highSegmentItem = try await HTTPMediaCache.cacheItem(for: highSegmentURL)
        let spanishSegmentItem = try await HTTPMediaCache.cacheItem(for: spanishSegmentURL)
        let englishSegmentItem = try await HTTPMediaCache.cacheItem(for: englishSegmentURL)

        XCTAssertNotNil(masterItem)
        XCTAssertEqual(lowSegmentItem?.cachedLength, 3)
        XCTAssertNil(highSegmentItem)
        XCTAssertEqual(spanishSegmentItem?.cachedLength, 2)
        XCTAssertNil(englishSegmentItem)
        XCTAssertEqual(progressValues.first, 0.5)
        XCTAssertEqual(progressValues.last, 1.0)
    }

    func testHLSPreloadStreamsSegmentProgressBeforeSegmentCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = StreamingHLSPreloadDownloader()
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: downloader)

        let playlistURL = try XCTUnwrap(URL(string: "https://example.com/streaming/index.m3u8"))
        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: playlistURL),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )

        var iterator = task.progress.makeAsyncIterator()
        await downloader.waitUntilSegmentStreamRequested()
        await downloader.yieldSegmentChunk(Data([1, 2]))
        let firstProgress = await iterator.next()
        await downloader.yieldSegmentChunk(Data([3, 4]))
        await downloader.finishSegment()
        let secondProgress = await iterator.next()
        let finalProgress = await iterator.next()
        try await task.waitForCompletion()

        XCTAssertEqual(firstProgress, 0.5)
        XCTAssertEqual(secondProgress, 1.0)
        XCTAssertEqual(finalProgress, 1.0)
    }

    func testHLSPreloadDefaultsToCompatibleVariantAndSelectedSubtitles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await HTTPMediaCache.configureForTests(storageRoot: root, downloader: CompatibilityMasterPlaylistDownloader())

        let masterURL = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))
        let compatibleSegmentURL = try XCTUnwrap(URL(string: "https://example.com/sdr/segment-1.ts"))
        let dolbySegmentURL = try XCTUnwrap(URL(string: "https://example.com/dolby/segment-1.ts"))
        let aacSegmentURL = try XCTUnwrap(URL(string: "https://example.com/audio/aac/segment-1.ts"))
        let atmosSegmentURL = try XCTUnwrap(URL(string: "https://example.com/audio/ec3/segment-1.ts"))
        let subtitleSegmentURL = try XCTUnwrap(URL(string: "https://example.com/subtitles/en/segment-1.vtt"))

        let task = try await HTTPMediaCache.preload(
            CacheRequest(url: masterURL),
            options: PreloadOptions(hlsLimit: .segmentCount(1))
        )
        try await task.waitForCompletion()

        let compatibleSegment = try await HTTPMediaCache.cacheItem(for: compatibleSegmentURL)
        let dolbySegment = try await HTTPMediaCache.cacheItem(for: dolbySegmentURL)
        let aacSegment = try await HTTPMediaCache.cacheItem(for: aacSegmentURL)
        let atmosSegment = try await HTTPMediaCache.cacheItem(for: atmosSegmentURL)
        let subtitleSegment = try await HTTPMediaCache.cacheItem(for: subtitleSegmentURL)

        XCTAssertEqual(compatibleSegment?.cachedLength, 3)
        XCTAssertNil(dolbySegment)
        XCTAssertEqual(aacSegment?.cachedLength, 2)
        XCTAssertNil(atmosSegment)
        XCTAssertEqual(subtitleSegment?.cachedLength, 2)
    }
}

private struct SingleUsePreloadDownloader: CacheDownloading {
    private let state: SingleUsePreloadDownloadState

    init(data: Data) {
        state = SingleUsePreloadDownloadState(data: data)
    }

    func download(request _: CacheRequest) async throws -> [Data] {
        try await state.download()
    }
}

private struct DuplicatePreloadGuardDownloader: CacheDownloading {
    private let state: DuplicatePreloadGuardDownloadState

    init(data: Data) {
        state = DuplicatePreloadGuardDownloadState(data: data)
    }

    func download(request _: CacheRequest) async throws -> [Data] {
        try await state.download()
    }

    func downloadCount() async -> Int {
        await state.downloadCount()
    }
}

private struct BlockingPreloadDownloader: CacheDownloading {
    private let state: BlockingPreloadDownloadState

    init(data: Data) {
        state = BlockingPreloadDownloadState(data: data)
    }

    func download(request _: CacheRequest) async throws -> [Data] {
        try await state.download()
    }

    func waitUntilStarted() async {
        await state.waitUntilStarted()
    }

    func finish() async {
        await state.finish()
    }
}

private actor BlockingPreloadDownloadState {
    private let data: Data
    private var isStarted = false
    private var isFinished = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(data: Data) {
        self.data = data
    }

    func download() async throws -> [Data] {
        isStarted = true
        startedContinuation?.resume()
        startedContinuation = nil

        if !isFinished {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }

        try Task.checkCancellation()
        return [data]
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

private struct StreamingPreloadDownloader: CacheStreamingDownloading {
    private let state = StreamingPreloadDownloadState()

    func download(request _: CacheRequest) async throws -> [Data] {
        []
    }

    func streamResponse(request _: CacheRequest) async throws -> CacheStreamResponse {
        await CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "4",
                "Content-Type": "video/mp4",
            ],
            body: state.stream()
        )
    }

    func yield(_ data: Data) async {
        await state.yield(data)
    }

    func waitUntilStreamRequested() async {
        await state.waitUntilStreamRequested()
    }

    func finish() async {
        await state.finish()
    }
}

private actor StreamingPreloadDownloadState {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var streamRequestedContinuation: CheckedContinuation<Void, Never>?

    func stream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.streamRequestedContinuation?.resume()
            self.streamRequestedContinuation = nil
        }
    }

    func waitUntilStreamRequested() async {
        if continuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            streamRequestedContinuation = continuation
        }
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private actor SingleUsePreloadDownloadState {
    private let data: Data
    private var didDownload = false

    init(data: Data) {
        self.data = data
    }

    func download() throws -> [Data] {
        if didDownload {
            throw CacheError.networkFailure("preload should have populated the cache")
        }

        didDownload = true
        return [data]
    }
}

private actor DuplicatePreloadGuardDownloadState {
    private let data: Data
    private var count = 0

    init(data: Data) {
        self.data = data
    }

    func download() throws -> [Data] {
        count += 1
        if count > 1 {
            throw CacheError.networkFailure("preload should skip fully cached resources")
        }

        return [data]
    }

    func downloadCount() -> Int {
        count
    }
}

private func withTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw CacheError.networkFailure("Timed out waiting for operation.")
        }

        let result = try await group.next()
        group.cancelAll()
        return try XCTUnwrap(result)
    }
}

private struct FixedLengthPreloadDownloader: CacheDownloading {
    func download(request _: CacheRequest) async throws -> [Data] {
        [Data(repeating: 9, count: 4)]
    }
}

private struct FailingPreloadDownloader: CacheDownloading {
    func download(request _: CacheRequest) async throws -> [Data] {
        throw CacheError.networkFailure("preload failed")
    }
}

private struct QueuedPreloadDownloader: CacheDownloading {
    private let state = QueuedPreloadDownloadState()

    func download(request _: CacheRequest) async throws -> [Data] {
        try await state.download()
    }

    func waitUntilStarted(count: Int) async {
        await state.waitUntilStarted(count: count)
    }

    func startedCount() async -> Int {
        await state.startedCount()
    }

    func finishNext() async {
        await state.finishNext()
    }
}

private actor QueuedPreloadDownloadState {
    private var started = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []

    func download() async throws -> [Data] {
        started += 1
        resumeSatisfiedStartWaiters()
        await withCheckedContinuation { continuation in
            finishContinuations.append(continuation)
        }
        try Task.checkCancellation()
        return [Data([1, 2, 3, 4])]
    }

    func waitUntilStarted(count: Int) async {
        if started >= count {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func startedCount() -> Int {
        started
    }

    func finishNext() {
        guard !finishContinuations.isEmpty else {
            return
        }
        finishContinuations.removeFirst().resume()
    }

    private func resumeSatisfiedStartWaiters() {
        let readyWaiters = startWaiters.filter { started >= $0.0 }
        startWaiters.removeAll { started >= $0.0 }
        for waiter in readyWaiters {
            waiter.1.resume()
        }
    }
}

private struct RangeAssertingFilePrefetchDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        guard let range = request.range, let end = range.end else {
            throw CacheError.networkFailure("expected bounded range")
        }
        let count = Int(end - range.start + 1)
        return CacheDownloadResponse(
            data: Data(repeating: UInt8(range.start), count: count),
            statusCode: 206,
            headers: [
                "Content-Length": "\(count)",
                "Content-Range": "bytes \(range.start)-\(end)/10",
                "Content-Type": "video/mp4",
            ]
        )
    }
}

private struct ProbingFilePreloadDownloader: CacheResponseDownloading {
    let totalLength: Int64
    private let state = ProbingFilePreloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        await state.record(request.range)
        guard let range = request.range, let end = range.end else {
            throw CacheError.networkFailure("expected bounded range")
        }
        let start = range.start
        let count = Int(end - start + 1)
        return CacheDownloadResponse(
            data: Data(repeating: UInt8(start), count: count),
            statusCode: 206,
            headers: [
                "Content-Length": "\(count)",
                "Content-Range": "bytes \(start)-\(end)/\(totalLength)",
                "Accept-Ranges": "bytes",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func ranges() async -> [ByteRange?] {
        await state.ranges()
    }
}

private actor ProbingFilePreloadState {
    private var values: [ByteRange?] = []

    func record(_ range: ByteRange?) {
        values.append(range)
    }

    func ranges() -> [ByteRange?] {
        values
    }
}

private struct BlockingChunkedFilePreloadDownloader: CacheResponseDownloading {
    let totalLength: Int64
    private let state = BlockingChunkedFilePreloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        guard let range = request.range, let end = range.end else {
            throw CacheError.networkFailure("expected bounded range")
        }
        if range.start > 0 {
            await state.block()
            try Task.checkCancellation()
        }

        let count = Int(end - range.start + 1)
        return CacheDownloadResponse(
            data: Data(repeating: UInt8(range.start), count: count),
            statusCode: 206,
            headers: [
                "Content-Length": "\(count)",
                "Content-Range": "bytes \(range.start)-\(end)/\(totalLength)",
                "Accept-Ranges": "bytes",
                "Content-Type": "video/mp4",
            ]
        )
    }

    func waitUntilBlocked() async {
        await state.waitUntilBlocked()
    }

    func finish() async {
        await state.finish()
    }
}

private actor BlockingChunkedFilePreloadState {
    private var isBlocked = false
    private var isFinished = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil

        if !isFinished {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }
    }

    func waitUntilBlocked() async {
        if isBlocked {
            return
        }

        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func finish() {
        isFinished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct HLSRecursivePreloadDownloader: CacheResponseDownloading {
    let playlist: String

    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/live/index.m3u8":
            return CacheDownloadResponse(
                data: Data(playlist.utf8),
                statusCode: 200,
                headers: [
                    "Content-Length": "\(playlist.utf8.count)",
                    "Content-Type": "application/x-mpegURL",
                ]
            )
        case "http://cdn.example.com/segment-1.ts":
            return CacheDownloadResponse(
                data: Data([1, 2, 3]),
                statusCode: 200,
                headers: [
                    "Content-Length": "3",
                    "Content-Type": "video/mp2t",
                ]
            )
        case "https://example.com/live/segment-2.ts":
            return CacheDownloadResponse(
                data: Data([4, 5, 6, 7]),
                statusCode: 200,
                headers: [
                    "Content-Length": "4",
                    "Content-Type": "video/mp2t",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct CachedPlaylistSegmentDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/live/index.m3u8":
            throw CacheError.networkFailure("cached playlist should be read before downloading")
        case "https://example.com/live/segment-1.ts":
            return CacheDownloadResponse(
                data: Data([1, 2, 3]),
                statusCode: 200,
                headers: [
                    "Content-Length": "3",
                    "Content-Type": "video/mp2t",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct HLSIdentityProviderDownloader: CacheResponseDownloading {
    let playlist: String

    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.path {
        case "/live/index.m3u8":
            return CacheDownloadResponse(
                data: Data(playlist.utf8),
                statusCode: 200,
                headers: [
                    "Content-Length": "\(playlist.utf8.count)",
                    "Content-Type": "application/x-mpegURL",
                ]
            )
        case "/live/key.bin":
            XCTAssertNil(request.range)
            return CacheDownloadResponse(
                data: Data([1, 2]),
                statusCode: 200,
                headers: [
                    "Content-Length": "2",
                    "Content-Type": "application/octet-stream",
                ]
            )
        case "/live/init.mp4":
            XCTAssertEqual(request.range, ByteRange(start: 8, end: 11))
            return CacheDownloadResponse(
                data: Data([3, 4, 5, 6]),
                statusCode: 206,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 8-11/20",
                    "Content-Type": "video/mp4",
                ]
            )
        case "/live/segment-1.ts":
            XCTAssertNil(request.range)
            return CacheDownloadResponse(
                data: Data([7, 8, 9, 10]),
                statusCode: 200,
                headers: [
                    "Content-Length": "4",
                    "Content-Type": "video/mp2t",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct MasterPlaylistDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/master.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=100000
            low/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=300000
            high/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=500000
            ultra/index.m3u8
            """
            return playlistResponse(playlist)
        case "https://example.com/high/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            #EXTINF:5,
            segment-2.ts
            #EXTINF:5,
            segment-3.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/high/segment-1.ts":
            return dataResponse([1, 2, 3], contentType: "video/mp2t")
        case "https://example.com/high/segment-2.ts":
            return dataResponse([4, 5, 6, 7], contentType: "video/mp2t")
        case "https://example.com/high/segment-3.ts":
            return dataResponse([8, 9, 10, 11, 12], contentType: "video/mp2t")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct MasterPlaylistSelectionDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/master.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",DEFAULT=NO,URI="audio/es/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="aud"
            low/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=300000,AUDIO="aud"
            high/index.m3u8
            """
            return playlistResponse(playlist)
        case "https://example.com/low/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/high/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/audio/en/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/audio/es/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/low/segment-1.ts":
            return dataResponse([1, 2, 3], contentType: "video/mp2t")
        case "https://example.com/high/segment-1.ts":
            return dataResponse([4, 5, 6], contentType: "video/mp2t")
        case "https://example.com/audio/en/segment-1.ts":
            return dataResponse([7, 8, 9], contentType: "video/mp2t")
        case "https://example.com/audio/es/segment-1.ts":
            return dataResponse([10, 11], contentType: "video/mp2t")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct CompatibilityMasterPlaylistDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/master.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="AAC",DEFAULT=YES,URI="audio/aac/index.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ec3",NAME="Atmos",DEFAULT=YES,URI="audio/ec3/index.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,URI="subtitles/en/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,VIDEO-RANGE=SDR,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aac",SUBTITLES="subs"
            sdr/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=30000000,VIDEO-RANGE=PQ,CODECS="dvh1.05.06,ec-3",AUDIO="ec3",SUBTITLES="subs"
            dolby/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=40000000,VIDEO-RANGE=PQ,CODECS="hvc1.2.20000000.H150.B0,ec-3",AUDIO="ec3",SUBTITLES="subs"
            hdr/index.m3u8
            """
            return playlistResponse(playlist)
        case "https://example.com/sdr/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/dolby/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/hdr/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/audio/aac/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/audio/ec3/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/subtitles/en/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.vtt
            """
            return playlistResponse(playlist)
        case "https://example.com/sdr/segment-1.ts":
            return dataResponse([1, 2, 3], contentType: "video/mp2t")
        case "https://example.com/dolby/segment-1.ts":
            return dataResponse([4, 5, 6], contentType: "video/mp2t")
        case "https://example.com/audio/aac/segment-1.ts":
            return dataResponse([7, 8], contentType: "audio/mp4")
        case "https://example.com/audio/ec3/segment-1.ts":
            return dataResponse([9, 10], contentType: "audio/mp4")
        case "https://example.com/subtitles/en/segment-1.vtt":
            return dataResponse([11, 12], contentType: "text/vtt")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct MediaPlaylistWithDependenciesDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/video/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6,
            segment-1.ts
            #EXTINF:6,
            segment-2.ts
            #EXTINF:6,
            segment-3.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/video/key.bin":
            return dataResponse([1, 2], contentType: "application/octet-stream")
        case "https://example.com/video/init.mp4":
            return dataResponse([3, 4], contentType: "video/mp4")
        case "https://example.com/video/segment-1.ts":
            return dataResponse([5, 6, 7], contentType: "video/mp2t")
        case "https://example.com/video/segment-2.ts":
            return dataResponse([8, 9, 10, 11], contentType: "video/mp2t")
        case "https://example.com/video/segment-3.ts":
            return dataResponse([12, 13, 14, 15, 16], contentType: "video/mp2t")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct LateDependencyMediaPlaylistDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/video/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:6,
            segment-1.ts
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXTINF:6,
            segment-2.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/video/segment-1.ts":
            return dataResponse([1, 2, 3], contentType: "video/mp2t")
        case "https://example.com/video/key.bin":
            return dataResponse([4, 5], contentType: "application/octet-stream")
        case "https://example.com/video/segment-2.ts":
            return dataResponse([6, 7, 8, 9], contentType: "video/mp2t")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct ByteRangePlaylistDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/ranged/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            #EXT-X-BYTERANGE:4@10
            file.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/ranged/file.ts":
            XCTAssertEqual(request.range?.start, 10)
            XCTAssertEqual(request.range?.end, 13)
            return CacheDownloadResponse(
                data: Data([1, 2, 3, 4]),
                statusCode: 206,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 10-13/100",
                    "Content-Type": "video/mp2t",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct HLSRequestPolicyDownloader: CacheResponseDownloading {
    private let state = HLSRequestPolicyDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        try await state.downloadResponse(request: request)
    }

    func requests() async -> [CacheRequest] {
        await state.requests()
    }
}

private actor HLSRequestPolicyDownloadState {
    private var recordedRequests: [CacheRequest] = []

    func downloadResponse(request: CacheRequest) throws -> CacheDownloadResponse {
        recordedRequests.append(request)
        switch request.url.absoluteString {
        case "https://example.com/policy/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="4@4"
            #EXTINF:5,
            segment-1.ts
            #EXTINF:5,
            segment-2.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/policy/key.bin":
            return dataResponse([1, 2], contentType: "application/octet-stream")
        case "https://example.com/policy/init.mp4":
            XCTAssertEqual(request.range, ByteRange(start: 4, end: 7))
            return CacheDownloadResponse(
                data: Data([3, 4, 5, 6]),
                statusCode: 206,
                headers: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 4-7/20",
                    "Content-Type": "video/mp4",
                ]
            )
        case "https://example.com/policy/segment-1.ts":
            return dataResponse([7, 8, 9], contentType: "video/mp2t")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }

    func requests() -> [CacheRequest] {
        recordedRequests
    }
}

private struct DetailedSelectionPlaylistDownloader: CacheResponseDownloading {
    func download(request: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: request).data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/detailed/master.m3u8":
            let playlist = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en/index.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",LANGUAGE="es",DEFAULT=NO,AUTOSELECT=YES,URI="audio/es/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=200000,AVERAGE-BANDWIDTH=180000,RESOLUTION=1920x1080,FRAME-RATE=59.94,CODECS="dvh1.05.06,ec-3",VIDEO-RANGE=PQ,AUDIO="aud"
            dolby/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=100000,AVERAGE-BANDWIDTH=90000,RESOLUTION=1280x720,FRAME-RATE=29.97,CODECS="avc1.64001f,mp4a.40.2",VIDEO-RANGE=SDR,AUDIO="aud"
            selected/index.m3u8
            """
            return playlistResponse(playlist)
        case "https://example.com/detailed/selected/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/detailed/audio/en/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/detailed/selected/segment-1.ts":
            return dataResponse([1, 2, 3], contentType: "video/mp2t")
        case "https://example.com/detailed/audio/en/segment-1.ts":
            return dataResponse([4, 5], contentType: "audio/mp4")
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }
}

private struct StreamingHLSPreloadDownloader: CacheResponseDownloading, CacheStreamingDownloading {
    private let state = StreamingHLSPreloadDownloadState()

    func download(request: CacheRequest) async throws -> [Data] {
        if request.url.pathExtension == "m3u8" {
            return try await [downloadResponse(request: request).data]
        }

        let response = try await streamResponse(request: request)
        var data = Data()
        for try await chunk in response.body {
            data.append(chunk)
        }
        return [data]
    }

    func downloadResponse(request: CacheRequest) async throws -> CacheDownloadResponse {
        switch request.url.absoluteString {
        case "https://example.com/streaming/index.m3u8":
            let playlist = """
            #EXTM3U
            #EXTINF:5,
            segment-1.ts
            """
            return playlistResponse(playlist)
        case "https://example.com/streaming/segment-1.ts":
            let chunks = try await download(request: request)
            let data = chunks.reduce(into: Data()) { $0.append($1) }
            return CacheDownloadResponse(
                data: data,
                statusCode: 200,
                headers: [
                    "Content-Length": "\(data.count)",
                    "Content-Type": "video/mp2t",
                ]
            )
        default:
            throw CacheError.networkFailure("unexpected URL \(request.url.absoluteString)")
        }
    }

    func streamResponse(request: CacheRequest) async throws -> CacheStreamResponse {
        guard request.url.absoluteString == "https://example.com/streaming/segment-1.ts" else {
            throw CacheError.networkFailure("unexpected streaming URL \(request.url.absoluteString)")
        }

        return await CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "4",
                "Content-Type": "video/mp2t",
            ],
            body: state.stream()
        )
    }

    func waitUntilSegmentStreamRequested() async {
        await state.waitUntilStreamRequested()
    }

    func yieldSegmentChunk(_ data: Data) async {
        await state.yield(data)
    }

    func finishSegment() async {
        await state.finish()
    }
}

private actor StreamingHLSPreloadDownloadState {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var streamRequestedContinuation: CheckedContinuation<Void, Never>?

    func stream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.streamRequestedContinuation?.resume()
            self.streamRequestedContinuation = nil
        }
    }

    func waitUntilStreamRequested() async {
        if continuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            streamRequestedContinuation = continuation
        }
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private func playlistResponse(_ playlist: String) -> CacheDownloadResponse {
    CacheDownloadResponse(
        data: Data(playlist.utf8),
        statusCode: 200,
        headers: [
            "Content-Length": "\(playlist.utf8.count)",
            "Content-Type": "application/x-mpegURL",
        ]
    )
}

private func dataResponse(_ bytes: [UInt8], contentType: String) -> CacheDownloadResponse {
    CacheDownloadResponse(
        data: Data(bytes),
        statusCode: 200,
        headers: [
            "Content-Length": "\(bytes.count)",
            "Content-Type": contentType,
        ]
    )
}

private func collectProgressValues(from stream: AsyncStream<Double>) async throws -> [Double] {
    var iterator = stream.makeAsyncIterator()
    var values: [Double] = []
    while let value = await iterator.next() {
        values.append(value)
    }
    return values
}
