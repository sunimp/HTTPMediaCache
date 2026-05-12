//
//  HLSSelection.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

/// HLS master playlist 中的一条 variant stream。
public struct HLSVariantStream: Sendable, Equatable {
    /// variant playlist URL。
    public var url: URL
    /// `BANDWIDTH` 标记值。
    public var bandwidth: Int
    /// `AVERAGE-BANDWIDTH` 标记值。
    public var averageBandwidth: Int
    /// `CODECS` 标记值。
    public var codecs: String?
    /// `RESOLUTION` 标记值。
    public var resolution: String?
    /// `VIDEO-RANGE` 标记值。
    public var videoRange: String?
    /// `FRAME-RATE` 标记值。
    public var frameRate: Double?
    /// 关联的音频组 ID。
    public var audioGroupID: String?
    /// 关联的视频组 ID。
    public var videoGroupID: String?
    /// 关联的字幕组 ID。
    public var subtitlesGroupID: String?

    /// 创建 variant stream 描述。
    public init(
        url: URL,
        bandwidth: Int,
        averageBandwidth: Int = 0,
        codecs: String? = nil,
        resolution: String? = nil,
        videoRange: String? = nil,
        frameRate: Double? = nil,
        audioGroupID: String? = nil,
        videoGroupID: String? = nil,
        subtitlesGroupID: String? = nil
    ) {
        self.url = url
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.codecs = codecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.audioGroupID = audioGroupID
        self.videoGroupID = videoGroupID
        self.subtitlesGroupID = subtitlesGroupID
    }
}

/// HLS rendition 类型。
public enum HLSRenditionType: String, Sendable, Equatable {
    /// 音频轨。
    case audio = "AUDIO"
    /// 视频轨。
    case video = "VIDEO"
    /// 字幕轨。
    case subtitles = "SUBTITLES"
    /// 内嵌字幕。
    case closedCaptions = "CLOSED-CAPTIONS"
}

/// HLS master playlist 中的一条 rendition。
public struct HLSRendition: Sendable, Equatable {
    /// rendition 类型。
    public var type: HLSRenditionType
    /// 所属组 ID。
    public var groupID: String
    /// rendition 名称。
    public var name: String?
    /// rendition 语言。
    public var language: String?
    /// 是否为默认 rendition。
    public var isDefault: Bool
    /// 是否允许播放器自动选择该 rendition。
    public var isAutoSelect: Bool
    /// rendition playlist URL；`CLOSED-CAPTIONS` 通常没有独立 URL。
    public var url: URL?

    /// 创建 rendition 描述。
    public init(
        type: HLSRenditionType,
        groupID: String,
        name: String? = nil,
        language: String? = nil,
        isDefault: Bool,
        isAutoSelect: Bool = false,
        url: URL?
    ) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isAutoSelect = isAutoSelect
        self.url = url
    }
}

/// HLS variant stream 选择回调。
public typealias HLSVariantStreamSelectionHandler = @Sendable (
    _ streams: [HLSVariantStream],
    _ originalURL: URL,
    _ currentURL: URL
) -> HLSVariantStream?

/// HLS rendition 选择回调。
public typealias HLSRenditionSelectionHandler = @Sendable (
    _ type: HLSRenditionType,
    _ renditions: [HLSRendition],
    _ originalURL: URL,
    _ currentURL: URL
) -> HLSRendition?
