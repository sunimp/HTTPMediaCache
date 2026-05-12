//
//  CacheRuntime.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

actor CacheRuntime {
    static let shared = CacheRuntime()

    private(set) var server = NIOProxyServer()
    private(set) var cacheIndex = CacheIndex(rootDirectory: CacheRuntime.defaultRootDirectoryURL)
    private(set) var downloader: any CacheDownloading = URLSessionDownloader()
    private var hlsContentHandler: (@Sendable (String) -> String)?
    private var hlsVariantStreamSelectionHandler: HLSVariantStreamSelectionHandler?
    private var hlsRenditionSelectionHandler: HLSRenditionSelectionHandler?
    private var hlsDownloadHeaderProvider: HLSDownloadHeaderProvider?
    private var requestHeaderRangeLength: (@Sendable (URL, Int64) -> Int64)?

    func configureForTests(storageRoot: URL, downloader: any CacheDownloading) async {
        await PreloadCoordinator.shared.resetForTests()
        server = NIOProxyServer()
        cacheIndex = CacheIndex(rootDirectory: storageRoot)
        self.downloader = downloader
        hlsContentHandler = nil
        hlsVariantStreamSelectionHandler = nil
        hlsRenditionSelectionHandler = nil
        hlsDownloadHeaderProvider = nil
        requestHeaderRangeLength = nil
        await URLSessionDownloaderSettings.shared.reset()
    }

    func setHLSContentHandler(_ handler: (@Sendable (String) -> String)?) {
        hlsContentHandler = handler
    }

    func setHLSVariantStreamSelectionHandler(_ handler: HLSVariantStreamSelectionHandler?) {
        hlsVariantStreamSelectionHandler = handler
    }

    func setHLSRenditionSelectionHandler(_ handler: HLSRenditionSelectionHandler?) {
        hlsRenditionSelectionHandler = handler
    }

    func setHLSDownloadHeaderProvider(_ provider: HLSDownloadHeaderProvider?) {
        hlsDownloadHeaderProvider = provider
    }

    func hlsDownloadHeaders(for context: HLSDownloadRequestContext) -> [String: String] {
        hlsDownloadHeaderProvider?(context) ?? [:]
    }

    func handleHLSContent(_ content: String) -> String? {
        hlsContentHandler?(content)
    }

    func hasHLSSelectionHandler() -> Bool {
        hlsVariantStreamSelectionHandler != nil || hlsRenditionSelectionHandler != nil
    }

    func selectVariantStream(
        from variants: [HLSVariantStreamItem],
        originalURL: URL,
        currentURL: URL
    ) -> HLSVariantStreamItem? {
        guard !variants.isEmpty else {
            return nil
        }

        let candidates = variants.map(\.selectionInfo)
        if let handler = hlsVariantStreamSelectionHandler,
           let selected = handler(candidates, originalURL, currentURL),
           let matched = variants.first(where: { $0.matches(selection: selected) })
        {
            return matched
        }
        return defaultVariantStream(from: variants)
    }

    func selectRendition(
        type: HLSRenditionType,
        renditions: [HLSRenditionItem],
        originalURL: URL,
        currentURL: URL
    ) -> HLSRenditionItem? {
        let candidates = renditions.map(\.selectionInfo)
        if let handler = hlsRenditionSelectionHandler,
           let selected = handler(type, candidates, originalURL, currentURL),
           let matched = renditions.first(where: { $0.matches(selection: selected) })
        {
            return matched
        }
        return renditions.first { $0.isDefault } ?? renditions.first
    }

    private func defaultVariantStream(from variants: [HLSVariantStreamItem]) -> HLSVariantStreamItem? {
        guard let fallback = fallbackVariantStream(from: variants) else {
            return nil
        }
        guard variants.contains(where: { $0.codecs != nil || $0.videoRange != nil || $0.averageBandwidth > 0 }) else {
            return fallback
        }

        return variants.min { lhs, rhs in
            let left = variantCompatibilityScore(lhs)
            let right = variantCompatibilityScore(rhs)
            if left != right {
                return left < right
            }
            return effectiveBandwidth(lhs) < effectiveBandwidth(rhs)
        } ?? fallback
    }

    private func fallbackVariantStream(from variants: [HLSVariantStreamItem]) -> HLSVariantStreamItem? {
        guard !variants.isEmpty else {
            return nil
        }
        return variants[variants.count / 2]
    }

    private func variantCompatibilityScore(_ variant: HLSVariantStreamItem) -> Int {
        let codecs = variant.codecs?.lowercased() ?? ""
        let videoRange = variant.videoRange?.uppercased()
        var score = 0

        if videoRange == "PQ" || videoRange == "HLG" {
            score += VariantCompatibilityScore.hdrPenalty
        }
        if codecs.contains("dvh") || codecs.contains("dvhe") {
            score += VariantCompatibilityScore.dolbyVisionPenalty
        }
        if codecs.contains("ec-3") || codecs.contains("ac-3") {
            score += VariantCompatibilityScore.surroundAudioPenalty
        }
        if codecs.contains("mp4a") {
            score += VariantCompatibilityScore.commonCodecBonus
        }
        if codecs.contains("avc1") {
            score += VariantCompatibilityScore.commonCodecBonus
        }

        return score
    }

    private func effectiveBandwidth(_ variant: HLSVariantStreamItem) -> Int {
        if variant.averageBandwidth > 0 {
            return variant.averageBandwidth
        }
        return variant.bandwidth
    }

    func setRequestHeaderRangeLength(_ provider: (@Sendable (URL, Int64) -> Int64)?) {
        requestHeaderRangeLength = provider
    }

    func requestHeaderRangeLength(for url: URL, totalLength: Int64) -> Int64 {
        requestHeaderRangeLength?(url, totalLength) ?? 0
    }

    func setURLConverter(_ converter: (@Sendable (URL) -> URL)?) async {
        await cacheIndex.setURLConverter(converter)
    }

    func setCacheIdentifierProvider(_ provider: (@Sendable (URL) -> String)?) async {
        await cacheIndex.setCacheIdentifierProvider(provider)
    }

    static func defaultRootDirectory(cachesDirectory: URL, documentsDirectory _: URL) -> URL {
        cachesDirectory.appendingPathComponent("HTTPMediaCache", isDirectory: true)
    }

    private static var defaultRootDirectoryURL: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? cachesDirectory
        return defaultRootDirectory(cachesDirectory: cachesDirectory, documentsDirectory: documentsDirectory)
    }
}

private enum VariantCompatibilityScore {
    static let hdrPenalty = 100
    static let dolbyVisionPenalty = 100
    static let surroundAudioPenalty = 20
    static let commonCodecBonus = -10
}
