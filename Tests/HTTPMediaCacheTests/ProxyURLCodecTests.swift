//
//  ProxyURLCodecTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class ProxyURLCodecTests: XCTestCase {
    func testBuildsAndRestoresProxyURL() throws {
        let codec = ProxyURLCodec(port: 8123)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4?token=a b"))
        let proxy = try codec.proxyURL(for: original, bindToLocalhost: true)

        XCTAssertEqual(proxy.scheme, "http")
        XCTAssertEqual(proxy.host, "localhost")
        XCTAssertEqual(proxy.port, 8123)
        XCTAssertTrue(proxy.path.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertTrue(proxy.path.contains("HTTPMediaCacheLastPathComponent.mp4"))
        XCTAssertNil(URLComponents(url: proxy, resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(codec.originalURL(from: proxy), original)
    }

    func testBuildsNonLocalhostProxyURL() throws {
        let codec = ProxyURLCodec(port: 8123)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        let proxy = try codec.proxyURL(for: original, bindToLocalhost: false)

        XCTAssertNotEqual(proxy.host, "0.0.0.0")
        XCTAssertFalse(proxy.host?.isEmpty ?? true)
        XCTAssertEqual(codec.originalURL(from: proxy), original)
    }

    func testOriginalURLReturnsInputWhenURLDoesNotMatchProxyShape() throws {
        let codec = ProxyURLCodec(port: 8123)
        let original = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))

        XCTAssertEqual(codec.originalURL(from: original), original)
    }

    func testRecognizesProxyURLShape() throws {
        let codec = ProxyURLCodec(port: 8123)
        let original = try XCTUnwrap(URL(string: "https://example.com/path/video.mp4?token=1"))
        let proxy = try codec.proxyURL(for: original, bindToLocalhost: true)

        XCTAssertTrue(codec.isProxyURL(proxy))
        XCTAssertEqual(codec.originalURL(from: proxy), original)
    }

    func testEncodesAndRestoresHLSResourceMetadata() throws {
        let codec = ProxyURLCodec(port: 8123)
        let original = try XCTUnwrap(URL(string: "https://example.com/path/init.mp4?token=1"))
        let proxy = try codec.proxyURL(
            for: original,
            bindToLocalhost: true,
            hlsResourceKind: .initialization,
            byteRange: ByteRange(start: 8, end: 11)
        )

        XCTAssertEqual(codec.originalURL(from: proxy), original)
        XCTAssertEqual(ProxyURLCodec.hlsResourceKind(from: proxy.absoluteString), .initialization)
        XCTAssertEqual(ProxyURLCodec.hlsByteRange(from: proxy.absoluteString), ByteRange(start: 8, end: 11))
    }
}
