//
//  HLSSelectionResolver.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct HLSSelectedResources: Equatable {
    var variant: HLSVariantStreamItem?
    var renditions: [HLSRenditionItem]

    var childPlaylistRequests: [CacheRequest] {
        ([variant?.url].compactMap { $0 } + renditions.compactMap(\.url)).map {
            CacheRequest(url: $0)
        }
    }

    var urls: Set<URL> {
        Set([variant?.url].compactMap { $0 } + renditions.compactMap(\.url))
    }
}

struct HLSPlaybackSelection: Equatable {
    var variantURLs: Set<URL>
    var renditionURLs: Set<URL>
    var filtersVariants: Bool
    var filtersRenditions: Bool

    static let unrestricted = HLSPlaybackSelection(
        variantURLs: [],
        renditionURLs: [],
        filtersVariants: false,
        filtersRenditions: false
    )
}

struct HLSSelectionResolver {
    func selectedResources(
        in playlist: HLSPlaylist,
        originalURL: URL,
        currentURL: URL
    ) async -> HLSSelectedResources {
        guard let selectedVariant = await CacheRuntime.shared.selectVariantStream(
            from: playlist.variantStreams,
            originalURL: originalURL,
            currentURL: currentURL
        ) else {
            return HLSSelectedResources(variant: nil, renditions: [])
        }

        let renditions = await [
            selectedRendition(type: .audio, groupID: selectedVariant.audioGroupID, in: playlist, originalURL: originalURL, currentURL: currentURL),
            selectedRendition(type: .video, groupID: selectedVariant.videoGroupID, in: playlist, originalURL: originalURL, currentURL: currentURL),
            selectedRendition(type: .subtitles, groupID: selectedVariant.subtitlesGroupID, in: playlist, originalURL: originalURL, currentURL: currentURL),
        ].compactMap { $0 }

        return HLSSelectedResources(variant: selectedVariant, renditions: renditions)
    }

    func playbackSelection(
        in playlist: HLSPlaylist,
        originalURL: URL,
        currentURL: URL
    ) async -> HLSPlaybackSelection {
        let hasSelectionHandler = await CacheRuntime.shared.hasHLSSelectionHandler()

        guard hasSelectionHandler else {
            if playlist.hasMixedVideoAndAudioOnlyVariants {
                return HLSPlaybackSelection(
                    variantURLs: Set(playlist.variantStreams.filter(\.hasVideoTrackSignal).map(\.url)),
                    renditionURLs: [],
                    filtersVariants: true,
                    filtersRenditions: false
                )
            }
            return .unrestricted
        }

        let selected = await selectedResources(in: playlist, originalURL: originalURL, currentURL: currentURL)

        return HLSPlaybackSelection(
            variantURLs: Set([selected.variant?.url].compactMap { $0 }),
            renditionURLs: Set(selected.renditions.compactMap(\.url)),
            filtersVariants: true,
            filtersRenditions: true
        )
    }

    private func selectedRendition(
        type: HLSRenditionType,
        groupID: String?,
        in playlist: HLSPlaylist,
        originalURL: URL,
        currentURL: URL
    ) async -> HLSRenditionItem? {
        guard let groupID else {
            return nil
        }

        let matches = playlist.renditions.filter { $0.type.selectionType == type && $0.groupID == groupID }
        guard !matches.isEmpty else {
            return nil
        }
        return await CacheRuntime.shared.selectRendition(type: type, renditions: matches, originalURL: originalURL, currentURL: currentURL)
    }
}
