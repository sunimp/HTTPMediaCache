//
//  HLSPlaylistRewriter.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// HLS 播放列表改写器。
public struct HLSPlaylistRewriter: Sendable {
    private let codec: ProxyURLCodec

    /// 创建 HLS 播放列表改写器。
    public init(codec: ProxyURLCodec) {
        self.codec = codec
    }

    static func containsProxyURLMarkers(_ playlist: String) -> Bool {
        playlist.contains("HTTPMediaCachePlaceHolder") || playlist.contains("HTTPMediaCacheLastPathComponent")
    }

    /// 改写缓存侧 HLS playlist 内容。
    public func rewrite(playlist: String, baseURL _: URL) async throws -> String {
        if let handled = await CacheRuntime.shared.handleHLSContent(playlist) {
            return handled
        }

        let handled = playlist
        guard handled.contains("\nhttp") else {
            return handled
        }

        return handled
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                if text.hasPrefix("http") {
                    return "./\(text)"
                }
                return text
            }
            .joined(separator: "\n")
    }

    /// 改写播放侧 HLS playlist，将需要代理的 URI 转成代理 URL。
    public func rewriteForProxyPlayback(playlist: String, baseURL: URL) async throws -> String {
        if let handled = await CacheRuntime.shared.handleHLSContent(playlist) {
            return handled
        }

        let parsed = HLSPlaylistParser().parse(playlist: playlist, sourceURL: baseURL)
        let selectedURLs = await selectedPlaybackURLs(in: parsed, originalURL: baseURL, currentURL: baseURL)
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var rewrittenLines: [String] = []
        var index = 0
        var pendingSegmentByteRange: ByteRange?
        var previousSegmentEnd: Int64 = 0
        while index < lines.count {
            let text = lines[index]
            if text.hasPrefix("#EXT-X-STREAM-INF:") {
                if let uriIndex = nextURIIndex(after: index, in: lines),
                   let url = URL(string: lines[uriIndex], relativeTo: baseURL)?.absoluteURL
                {
                    if selectedURLs.isEmpty || selectedURLs.contains(url) {
                        rewrittenLines.append(rewriteURIAttribute(in: text, baseURL: baseURL, kind: nil))
                        var cursor = index + 1
                        while cursor < uriIndex {
                            rewrittenLines.append(rewriteLineForProxyPlayback(lines[cursor], baseURL: baseURL))
                            cursor += 1
                        }
                        rewrittenLines.append(proxyURLString(for: lines[uriIndex], baseURL: baseURL, kind: .variantPlaylist) ?? lines[uriIndex])
                    }
                    index = uriIndex + 1
                    continue
                }
            }
            if text.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                index += 1
                continue
            }

            if text.hasPrefix("#EXT-X-MEDIA:"),
               let rewritten = rewriteRenditionLine(text, baseURL: baseURL, selectedURLs: selectedURLs)
            {
                rewrittenLines.append(rewritten)
            } else if !text.hasPrefix("#EXT-X-MEDIA:") {
                if text.hasPrefix("#EXT-X-BYTERANGE:"),
                   let byteRange = byteRange(from: text, previousEnd: previousSegmentEnd)
                {
                    pendingSegmentByteRange = byteRange
                    rewrittenLines.append(text)
                } else if !text.isEmpty, !text.hasPrefix("#") {
                    rewrittenLines.append(proxyURLString(for: text, baseURL: baseURL, kind: .segment, byteRange: pendingSegmentByteRange) ?? text)
                    if let end = pendingSegmentByteRange?.end {
                        previousSegmentEnd = end + 1
                    }
                    pendingSegmentByteRange = nil
                } else {
                    rewrittenLines.append(rewriteLineForProxyPlayback(text, baseURL: baseURL))
                }
            }
            index += 1
        }

        return rewrittenLines.joined(separator: "\n")
    }

    private func rewriteRenditionLine(_ line: String, baseURL: URL, selectedURLs: Set<URL>) -> String? {
        guard let uriRange = line.range(of: "URI=") else {
            return line
        }

        let valueStart = uriRange.upperBound
        let isQuoted = valueStart < line.endIndex && line[valueStart] == "\""
        let contentStart = isQuoted ? line.index(after: valueStart) : valueStart
        var contentEnd = contentStart
        while contentEnd < line.endIndex {
            let character = line[contentEnd]
            if isQuoted, character == "\"" {
                break
            }
            if !isQuoted, character == "," {
                break
            }
            contentEnd = line.index(after: contentEnd)
        }

        let uriText = String(line[contentStart ..< contentEnd])
        guard let url = URL(string: uriText, relativeTo: baseURL)?.absoluteURL else {
            return line
        }
        guard selectedURLs.isEmpty || selectedURLs.contains(url) else {
            return nil
        }
        return rewriteURIAttribute(in: line, baseURL: baseURL, kind: renditionKind(from: line))
    }

    private func rewriteLineForProxyPlayback(_ line: String, baseURL: URL) -> String {
        if line.hasPrefix("#") {
            return rewriteURIAttribute(in: line, baseURL: baseURL, kind: uriAttributeKind(from: line), byteRange: byteRange(from: line, previousEnd: 0))
        }
        guard !line.isEmpty else {
            return line
        }
        return proxyURLString(for: line, baseURL: baseURL, kind: .segment) ?? line
    }

    private func rewriteURIAttribute(
        in line: String,
        baseURL: URL,
        kind: HLSDownloadResourceKind?,
        byteRange: ByteRange? = nil
    ) -> String {
        guard let uriRange = line.range(of: "URI=") else {
            return line
        }

        let valueStart = uriRange.upperBound
        let isQuoted = valueStart < line.endIndex && line[valueStart] == "\""
        let contentStart = isQuoted ? line.index(after: valueStart) : valueStart
        var contentEnd = contentStart
        while contentEnd < line.endIndex {
            let character = line[contentEnd]
            if isQuoted, character == "\"" {
                break
            }
            if !isQuoted, character == "," {
                break
            }
            contentEnd = line.index(after: contentEnd)
        }

        let uriText = String(line[contentStart ..< contentEnd])
        guard let proxyURLString = proxyURLString(for: uriText, baseURL: baseURL, kind: kind, byteRange: byteRange) else {
            return line
        }

        var output = line
        output.replaceSubrange(contentStart ..< contentEnd, with: proxyURLString)
        return output
    }

    private func proxyURLString(
        for uri: String,
        baseURL: URL,
        kind: HLSDownloadResourceKind?,
        byteRange: ByteRange? = nil
    ) -> String? {
        guard let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        return try? codec.proxyURL(for: url, bindToLocalhost: true, hlsResourceKind: kind, byteRange: byteRange).absoluteString
    }

    private func uriAttributeKind(from line: String) -> HLSDownloadResourceKind? {
        if line.hasPrefix("#EXT-X-KEY:") {
            return .key
        }
        if line.hasPrefix("#EXT-X-MAP:") {
            return .initialization
        }
        return nil
    }

    private func renditionKind(from line: String) -> HLSDownloadResourceKind {
        let attributes = parseAttributes(line)
        if attributes["TYPE"]?.caseInsensitiveCompare("SUBTITLES") == .orderedSame {
            return .subtitlePlaylist
        }
        return .renditionPlaylist
    }

    private func byteRange(from line: String, previousEnd: Int64) -> ByteRange? {
        let prefix: String
        if line.hasPrefix("#EXT-X-BYTERANGE:") {
            prefix = "#EXT-X-BYTERANGE:"
        } else if line.hasPrefix("#EXT-X-MAP:") {
            let attributes = parseAttributes(line)
            guard let value = attributes["BYTERANGE"] else {
                return nil
            }
            return parseByteRange(value, previousEnd: previousEnd)
        } else {
            return nil
        }
        return parseByteRange(String(line.dropFirst(prefix.count)), previousEnd: previousEnd)
    }

    private func parseByteRange(_ value: String, previousEnd: Int64) -> ByteRange? {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(parts.first ?? ""), length > 0 else {
            return nil
        }
        let start = parts.count > 1 ? Int64(parts[1]) ?? previousEnd : previousEnd
        return ByteRange(start: start, end: start + length - 1)
    }

    private func parseAttributes(_ line: String) -> [String: String] {
        let text = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? line
        var attributes: [String: String] = [:]
        var key = ""
        var value = ""
        var isReadingKey = true
        var isQuoted = false

        func commit() {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else {
                key = ""
                value = ""
                isReadingKey = true
                return
            }
            attributes[normalizedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            key = ""
            value = ""
            isReadingKey = true
        }

        for character in text {
            if isReadingKey {
                if character == "=" {
                    isReadingKey = false
                } else {
                    key.append(character)
                }
                continue
            }

            if character == "\"" {
                isQuoted.toggle()
                continue
            }

            if character == ",", !isQuoted {
                commit()
                continue
            }

            value.append(character)
        }
        commit()
        return attributes
    }

    private func selectedPlaybackURLs(
        in playlist: HLSPlaylist,
        originalURL: URL,
        currentURL: URL
    ) async -> Set<URL> {
        await HLSSelectionResolver().selectedPlaybackURLs(in: playlist, originalURL: originalURL, currentURL: currentURL)
    }

    private func nextURIIndex(after index: Int, in lines: [String]) -> Int? {
        var nextIndex = index + 1
        while nextIndex < lines.count {
            let line = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !line.hasPrefix("#") {
                return nextIndex
            }
            nextIndex += 1
        }
        return nil
    }

    /// 从 playlist 中提取需要缓存的资源 URL。
    public static func makeURLs(for playlist: String, sourceURL: URL) -> [URL] {
        playlist
            .components(separatedBy: "\n")
            .compactMap { line -> URL? in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.hasPrefix("#") else {
                    return nil
                }

                if text.contains("HTTPMediaCachePlaceHolder"), let url = URL(string: text) {
                    return ProxyURLCodec(port: UInt16(url.port ?? 0)).originalURL(from: url) ?? url
                }

                if text.hasPrefix("http") {
                    return URL(string: text)
                }

                if text.hasPrefix("./http") {
                    return URL(string: text.replacingOccurrences(of: "./http", with: "http"))
                }

                return sourceURL.deletingLastPathComponent().appendingPathComponent(text)
            }
    }
}

extension HLSPlaylist {
    var hasMixedVideoAndAudioOnlyVariants: Bool {
        variantStreams.contains { $0.hasVideoTrackSignal } &&
            variantStreams.contains { $0.isAudioOnlyVariant }
    }
}

extension HLSVariantStreamItem {
    var hasVideoTrackSignal: Bool {
        if resolution?.isEmpty == false || videoGroupID?.isEmpty == false || videoRange?.isEmpty == false {
            return true
        }

        let codecs = codecs?.lowercased() ?? ""
        return codecs.contains("avc") ||
            codecs.contains("hvc") ||
            codecs.contains("hev") ||
            codecs.contains("dvh") ||
            codecs.contains("vp9") ||
            codecs.contains("av01")
    }

    var isAudioOnlyVariant: Bool {
        guard !hasVideoTrackSignal else {
            return false
        }

        let codecs = codecs?.lowercased() ?? ""
        return codecs.contains("mp4a") ||
            codecs.contains("ac-3") ||
            codecs.contains("ec-3") ||
            codecs.contains("opus")
    }
}
