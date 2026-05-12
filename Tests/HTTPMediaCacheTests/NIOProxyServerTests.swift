//
//  NIOProxyServerTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
@testable import HTTPMediaCache
import XCTest

final class NIOProxyServerTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.stop()
        try await super.tearDown()
    }

    func testServerStartsAndBuildsProxyURL() async throws {
        try await HTTPMediaCache.start(port: 0)

        let isRunningAfterStart = await HTTPMediaCache.isRunning
        XCTAssertTrue(isRunningAfterStart)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try await HTTPMediaCache.proxyURL(for: original)

        XCTAssertEqual(HTTPMediaCache.originalURL(from: proxy), original)

        await HTTPMediaCache.stop()
        let isRunningAfterStop = await HTTPMediaCache.isRunning
        XCTAssertFalse(isRunningAfterStop)
    }

    func testProxyURLReturnsOriginalWhenServerIsNotRunningOrURLIsFile() async throws {
        await HTTPMediaCache.stop()

        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let fileURL = URL(fileURLWithPath: "/tmp/video.mp4")

        let remoteProxy = try await HTTPMediaCache.proxyURL(for: remoteURL)
        try await HTTPMediaCache.start(port: 0)
        let fileProxy = try await HTTPMediaCache.proxyURL(for: fileURL)

        XCTAssertEqual(remoteProxy, remoteURL)
        XCTAssertEqual(fileProxy, fileURL)
    }

    func testOriginalURLReturnsInputWhenURLIsNotProxyURL() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        XCTAssertEqual(HTTPMediaCache.originalURL(from: original), original)
    }

    func testStreamingBodyFailureAfterResponseHeadDoesNotWriteSecondResponse() async throws {
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.ts"))
        await HTTPMediaCache.configureForTests(
            storageRoot: storageRoot,
            downloader: FailingAfterFirstChunkStreamingDownloader()
        )
        try await HTTPMediaCache.start(port: 0)

        let proxy = try await HTTPMediaCache.proxyURL(for: original)

        do {
            _ = try await URLSession.shared.data(from: proxy)
            XCTFail("Streaming body failure should terminate the proxy response.")
        } catch {}

        let error = await HTTPMediaCache.error(for: original)
        XCTAssertNotNil(error)
    }
}

private struct FailingAfterFirstChunkStreamingDownloader: CacheDownloading, CacheStreamingDownloading {
    func download(request _: CacheRequest) async throws -> [Data] {
        []
    }

    func streamResponse(request _: CacheRequest) async throws -> CacheStreamResponse {
        CacheStreamResponse(
            statusCode: 200,
            headers: [
                "Content-Length": "6",
                "Content-Type": "video/MP2T",
            ],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data([0, 1, 2]))
                continuation.finish(throwing: CacheError.networkFailure("simulated streaming failure"))
            }
        )
    }
}
