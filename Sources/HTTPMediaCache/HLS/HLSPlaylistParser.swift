//
//  HLSPlaylistParser.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct HLSPlaylist {
    var items: [HLSPlaylistItem]

    var kind: HLSPlaylistKind {
        if !variantStreams.isEmpty || !iFrameStreams.isEmpty {
            return .master
        }
        return .media
    }

    var variantStreams: [HLSVariantStreamItem] {
        items.compactMap {
            if case let .variantStream(item) = $0 {
                return item
            }
            return nil
        }
    }

    var renditions: [HLSRenditionItem] {
        items.compactMap {
            if case let .rendition(item) = $0 {
                return item
            }
            return nil
        }
    }

    var iFrameStreams: [HLSIFrameStreamItem] {
        items.compactMap {
            if case let .iFrameStream(item) = $0 {
                return item
            }
            return nil
        }
    }

    var segmentCount: Int {
        items.reduce(0) { count, item in
            if case .segment = item {
                return count + 1
            }
            return count
        }
    }

    var resourceReferences: [HLSResourceReference] {
        items.compactMap { item in
            switch item {
            case let .key(url):
                return HLSResourceReference(type: .key, url: url)
            case let .initialization(item):
                return HLSResourceReference(type: .initialization, url: item.url, byteRange: item.byteRange)
            case let .segment(item):
                return HLSResourceReference(type: .segment, url: item.url, byteRange: item.byteRange, duration: item.duration)
            case let .variantStream(item):
                return HLSResourceReference(type: .variantPlaylist, url: item.url)
            case let .rendition(item):
                guard let url = item.url else {
                    return nil
                }
                let type: HLSResourceType = item.type == .subtitles ? .subtitlePlaylist : .renditionPlaylist
                return HLSResourceReference(type: type, url: url)
            case let .iFrameStream(item):
                return HLSResourceReference(type: .iFramePlaylist, url: item.url)
            }
        }
    }
}

enum HLSPlaylistKind: Equatable {
    case master
    case media
}

enum HLSResourceType: Equatable {
    case playlist
    case variantPlaylist
    case renditionPlaylist
    case subtitlePlaylist
    case iFramePlaylist
    case key
    case initialization
    case segment
}

struct HLSResourceReference: Equatable {
    var type: HLSResourceType
    var url: URL
    var byteRange: ByteRange?
    var duration: TimeInterval?
}

enum HLSPlaylistItem: Equatable {
    case key(URL)
    case initialization(HLSInitializationItem)
    case segment(HLSSegmentItem)
    case variantStream(HLSVariantStreamItem)
    case rendition(HLSRenditionItem)
    case iFrameStream(HLSIFrameStreamItem)
}

struct HLSInitializationItem: Equatable {
    var url: URL
    var byteRange: ByteRange?
}

struct HLSSegmentItem: Equatable {
    var url: URL
    var duration: TimeInterval
    var byteRange: ByteRange?
}

struct HLSVariantStreamItem: Equatable {
    var url: URL
    var bandwidth: Int
    var averageBandwidth: Int
    var codecs: String?
    var resolution: String?
    var videoRange: String?
    var frameRate: Double?
    var audioGroupID: String?
    var videoGroupID: String?
    var subtitlesGroupID: String?
}

struct HLSIFrameStreamItem: Equatable {
    var url: URL
    var bandwidth: Int
    var averageBandwidth: Int
    var codecs: String?
    var resolution: String?
    var videoRange: String?
}

struct HLSRenditionItem: Equatable {
    enum RenditionType: String {
        case audio = "AUDIO"
        case video = "VIDEO"
        case subtitles = "SUBTITLES"
        case closedCaptions = "CLOSED-CAPTIONS"
    }

    var type: RenditionType
    var groupID: String
    var name: String?
    var language: String?
    var isDefault: Bool
    var isAutoSelect: Bool
    var url: URL?
}

struct HLSPlaylistParser {
    func parse(playlist: String, sourceURL: URL) -> HLSPlaylist {
        var items: [HLSPlaylistItem] = []
        var pendingSegmentDuration: TimeInterval?
        var pendingSegmentByteRange: ByteRange?
        var lastSegmentByteRangeEnd: Int64 = 0

        let lines = playlist.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                index += 1
            }

            guard !line.isEmpty else {
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                pendingSegmentDuration = parseDuration(line)
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                let range = parseByteRange(value, previousEnd: lastSegmentByteRangeEnd)
                pendingSegmentByteRange = range
                if let end = range?.end {
                    lastSegmentByteRangeEnd = end + 1
                }
                continue
            }

            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if let uri = attributes["URI"], let url = resolve(uri, relativeTo: sourceURL) {
                    items.append(.key(url))
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attributes["URI"], let url = resolve(uri, relativeTo: sourceURL) {
                    let byteRange = attributes["BYTERANGE"].flatMap { parseByteRange($0, previousEnd: 0) }
                    items.append(.initialization(HLSInitializationItem(url: url, byteRange: byteRange)))
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if let typeText = attributes["TYPE"],
                   let type = HLSRenditionItem.RenditionType(rawValue: typeText),
                   let groupID = attributes["GROUP-ID"]
                {
                    items.append(.rendition(HLSRenditionItem(
                        type: type,
                        groupID: groupID,
                        name: attributes["NAME"],
                        language: attributes["LANGUAGE"],
                        isDefault: attributes["DEFAULT"] == "YES",
                        isAutoSelect: attributes["AUTOSELECT"] == "YES",
                        url: attributes["URI"].flatMap { resolve($0, relativeTo: sourceURL) }
                    )))
                }
                continue
            }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let uriLine = nextURI(after: index, in: lines)
                if let uriLine, let url = resolve(uriLine, relativeTo: sourceURL) {
                    items.append(.variantStream(HLSVariantStreamItem(
                        url: url,
                        bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                        averageBandwidth: Int(attributes["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                        codecs: attributes["CODECS"],
                        resolution: attributes["RESOLUTION"],
                        videoRange: attributes["VIDEO-RANGE"],
                        frameRate: Double(attributes["FRAME-RATE"] ?? ""),
                        audioGroupID: attributes["AUDIO"],
                        videoGroupID: attributes["VIDEO"],
                        subtitlesGroupID: attributes["SUBTITLES"]
                    )))
                }
                continue
            }

            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)))
                if let uri = attributes["URI"], let url = resolve(uri, relativeTo: sourceURL) {
                    items.append(.iFrameStream(HLSIFrameStreamItem(
                        url: url,
                        bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                        averageBandwidth: Int(attributes["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                        codecs: attributes["CODECS"],
                        resolution: attributes["RESOLUTION"],
                        videoRange: attributes["VIDEO-RANGE"]
                    )))
                }
                continue
            }

            guard !line.hasPrefix("#"), let segmentURL = resolve(line, relativeTo: sourceURL) else {
                continue
            }

            if let duration = pendingSegmentDuration {
                items.append(.segment(HLSSegmentItem(url: segmentURL, duration: duration, byteRange: pendingSegmentByteRange)))
                pendingSegmentDuration = nil
                pendingSegmentByteRange = nil
            }
        }

        return HLSPlaylist(items: items)
    }

    private func parseDuration(_ line: String) -> TimeInterval {
        let value = line
            .dropFirst("#EXTINF:".count)
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? "0"
        return TimeInterval(value) ?? 0
    }

    private func parseByteRange(_ value: String, previousEnd: Int64) -> ByteRange? {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(parts.first ?? ""), length > 0 else {
            return nil
        }

        let start = parts.count > 1 ? Int64(parts[1]) ?? previousEnd : previousEnd
        return ByteRange(start: start, end: start + length - 1)
    }

    private func nextURI(after index: Int, in lines: [String]) -> String? {
        var nextIndex = index + 1
        while nextIndex < lines.count {
            let line = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !line.hasPrefix("#") {
                return line
            }
            nextIndex += 1
        }
        return nil
    }

    private func parseAttributes(_ text: String) -> [String: String] {
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

    private func resolve(_ uri: String, relativeTo sourceURL: URL) -> URL? {
        let restoredURI = uri.hasPrefix("./http") ? String(uri.dropFirst(2)) : uri
        return URL(string: restoredURI, relativeTo: sourceURL)?.absoluteURL
    }
}

extension HLSVariantStreamItem {
    var selectionInfo: HLSVariantStream {
        HLSVariantStream(
            url: url,
            bandwidth: bandwidth,
            averageBandwidth: averageBandwidth,
            codecs: codecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            audioGroupID: audioGroupID,
            videoGroupID: videoGroupID,
            subtitlesGroupID: subtitlesGroupID
        )
    }

    func matches(selection: HLSVariantStream) -> Bool {
        url.absoluteString == selection.url.absoluteString
    }
}

extension HLSRenditionItem {
    var selectionInfo: HLSRendition {
        HLSRendition(
            type: type.selectionType,
            groupID: groupID,
            name: name,
            language: language,
            isDefault: isDefault,
            isAutoSelect: isAutoSelect,
            url: url
        )
    }

    func matches(selection: HLSRendition) -> Bool {
        guard type.selectionType == selection.type, groupID == selection.groupID else {
            return false
        }

        switch (url, selection.url) {
        case let (lhs?, rhs?):
            return lhs.absoluteString == rhs.absoluteString
        case (nil, nil):
            return true
        case (.some, nil), (nil, .some):
            return false
        }
    }
}

extension HLSRenditionItem.RenditionType {
    var selectionType: HLSRenditionType {
        switch self {
        case .audio:
            return .audio
        case .video:
            return .video
        case .subtitles:
            return .subtitles
        case .closedCaptions:
            return .closedCaptions
        }
    }
}
