//
//  HLSPlaylistRewriterTests.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

@testable import HTTPMediaCache
import XCTest

final class HLSPlaylistRewriterTests: XCTestCase {
    override func tearDown() async throws {
        await HTTPMediaCache.setHLSContentHandler(nil as (@Sendable (String) -> String)?)
        await HTTPMediaCache.setHLSVariantStreamSelectionHandler(nil)
        await HTTPMediaCache.setHLSRenditionSelectionHandler(nil)
        try await super.tearDown()
    }

    func testMatchesDefaultAbsoluteURLHandling() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXTINF:10,
        http://cdn.example.com/segment-1.ts
        #EXTINF:10,
        video/segment-2.ts
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/hls/index.m3u8"))

        let output = try await rewriter.rewrite(playlist: playlist, baseURL: base)
        XCTAssertTrue(output.contains("./http://cdn.example.com/segment-1.ts"))
        XCTAssertTrue(output.contains("\nvideo/segment-2.ts"))
        XCTAssertFalse(output.contains("http://127.0.0.1:8123/HTTPMediaCachePlaceHolder"))
    }

    func testProxyPlaybackRewriteProducesPlayableProxyURLs() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
        #EXTINF:10,
        segment.ts
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/hls/index.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)
        XCTAssertTrue(output.contains("HTTPMediaCachePlaceHolder"))
        XCTAssertTrue(output.contains("HTTPMediaCacheLastPathComponent.m3u8"))
        XCTAssertTrue(output.contains("HTTPMediaCacheLastPathComponent.ts"))
    }

    func testProxyPlaybackRewriteEncodesPlaylistKinds() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",DEFAULT=YES,URI="subs/en/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="aud",SUBTITLES="sub"
        low/index.m3u8
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertTrue(output.contains("HTTPMediaCacheHLSResourceKind=variantPlaylist"))
        XCTAssertTrue(output.contains("HTTPMediaCacheHLSResourceKind=renditionPlaylist"))
        XCTAssertTrue(output.contains("HTTPMediaCacheHLSResourceKind=subtitlePlaylist"))
    }

    func testProxyPlaybackRewriteKeepsOnlySelectedVariantAndRendition() async throws {
        await HTTPMediaCache.setHLSVariantStreamSelectionHandler { streams, _, _ in
            streams.first(where: { $0.bandwidth == 100_000 })
        }
        await HTTPMediaCache.setHLSRenditionSelectionHandler { _, renditions, _, _ in
            renditions.first(where: { $0.url?.absoluteString.contains("/es/") == true })
        }
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",DEFAULT=NO,URI="audio/es/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="aud"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=300000,AUDIO="aud"
        high/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertTrue(output.contains("low"))
        XCTAssertTrue(output.contains("audio%2Fes"))
        XCTAssertFalse(output.contains("high"))
        XCTAssertFalse(output.contains("audio%2Fen"))
        XCTAssertFalse(output.contains("iframe"))
    }

    func testProxyPlaybackRewritePreservesSimpleMasterVariantsWithoutSelectionHandlers() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=493000,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=224x100,FRAME-RATE=24
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=932000,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=448x200,FRAME-RATE=24
        high/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertEqual(output.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 2)
        XCTAssertTrue(output.contains("low%2Findex%2Em3u8"))
        XCTAssertTrue(output.contains("high%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("iframe"))
    }

    func testProxyPlaybackRewriteSelectsVideoVariantWhenMasterAlsoContainsAudioOnlyVariants() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=493000,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=224x100,FRAME-RATE=24
        video-low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=68000,CODECS="mp4a.40.2"
        audio-only/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertEqual(output.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 1)
        XCTAssertTrue(output.contains("video%2Dlow%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("audio%2Donly%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("iframe"))
    }

    func testProxyPlaybackRewritePreservesAllVideoVariantsWhenMasterAlsoContainsAudioOnlyVariants() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=493000,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=224x100,FRAME-RATE=24
        video-low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=932000,CODECS="mp4a.40.2,avc1.66.30",RESOLUTION=448x200,FRAME-RATE=24
        video-high/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=68000,CODECS="mp4a.40.2"
        audio-only/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertEqual(output.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 2)
        XCTAssertTrue(output.contains("video%2Dlow%2Findex%2Em3u8"))
        XCTAssertTrue(output.contains("video%2Dhigh%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("audio%2Donly%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("iframe"))
    }

    func testProxyPlaybackRewriteSelectsDefaultVariantWhenRenditionsExist() async throws {
        let codec = ProxyURLCodec(port: 8123)
        let rewriter = HLSPlaylistRewriter(codec: codec)
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="AAC",DEFAULT=YES,URI="audio/aac/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ec3",NAME="Atmos",DEFAULT=YES,URI="audio/ec3/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,VIDEO-RANGE=SDR,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aac"
        sdr/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=30000000,VIDEO-RANGE=PQ,CODECS="dvh1.05.06,ec-3",AUDIO="ec3"
        dolby/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let output = try await rewriter.rewriteForProxyPlayback(playlist: playlist, baseURL: base)

        XCTAssertEqual(output.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 1)
        XCTAssertTrue(output.contains("sdr%2Findex%2Em3u8"))
        XCTAssertTrue(output.contains("audio%2Faac%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("dolby%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("audio%2Fec3%2Findex%2Em3u8"))
        XCTAssertFalse(output.contains("iframe"))
    }

    func testUsesConfiguredContentHandler() async throws {
        await HTTPMediaCache.setHLSContentHandler { content in
            content.replacingOccurrences(of: "segment.ts", with: "custom.ts")
        }
        let rewriter = HLSPlaylistRewriter(codec: ProxyURLCodec(port: 8123))

        let output = try await rewriter.rewrite(
            playlist: "#EXTM3U\nsegment.ts",
            baseURL: XCTUnwrap(URL(string: "https://example.com/hls/index.m3u8"))
        )

        XCTAssertEqual(output, "#EXTM3U\ncustom.ts")
    }

    func testParserBuildsMediaPlaylistResourceReferences() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="4@10"
        #EXTINF:6,
        #EXT-X-BYTERANGE:5@20
        segment-1.ts
        #EXTINF:6,
        #EXT-X-BYTERANGE:7
        segment-2.ts
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/video/index.m3u8"))

        let parsed = HLSPlaylistParser().parse(playlist: playlist, sourceURL: base)

        XCTAssertEqual(parsed.kind, .media)
        XCTAssertEqual(parsed.resourceReferences.map(\.type), [.key, .initialization, .segment, .segment])
        XCTAssertEqual(parsed.resourceReferences.map(\.url.absoluteString), [
            "https://example.com/video/key.bin",
            "https://example.com/video/init.mp4",
            "https://example.com/video/segment-1.ts",
            "https://example.com/video/segment-2.ts",
        ])
        XCTAssertEqual(parsed.resourceReferences[1].byteRange, ByteRange(start: 10, end: 13))
        XCTAssertEqual(parsed.resourceReferences[2].byteRange, ByteRange(start: 20, end: 24))
        XCTAssertEqual(parsed.resourceReferences[3].byteRange, ByteRange(start: 25, end: 31))
        XCTAssertEqual(parsed.resourceReferences[2].duration, 6)
    }

    func testParserBuildsMasterPlaylistResourceReferences() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",DEFAULT=YES,URI="subs/en/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="aud",SUBTITLES="sub"
        low/index.m3u8
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let parsed = HLSPlaylistParser().parse(playlist: playlist, sourceURL: base)

        XCTAssertEqual(parsed.kind, .master)
        XCTAssertEqual(parsed.resourceReferences.map(\.type), [.renditionPlaylist, .subtitlePlaylist, .variantPlaylist])
        XCTAssertEqual(parsed.resourceReferences.map(\.url.absoluteString), [
            "https://example.com/audio/en/index.m3u8",
            "https://example.com/subs/en/index.m3u8",
            "https://example.com/low/index.m3u8",
        ])
    }

    func testParserParsesIFrameStreamResourceReference() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=300000,URI="iframe/index.m3u8"
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/master.m3u8"))

        let parsed = HLSPlaylistParser().parse(playlist: playlist, sourceURL: base)

        XCTAssertEqual(parsed.kind, .master)
        XCTAssertEqual(parsed.resourceReferences.map(\.type), [.iFramePlaylist])
        XCTAssertEqual(parsed.resourceReferences.first?.url.absoluteString, "https://example.com/iframe/index.m3u8")
    }
}
