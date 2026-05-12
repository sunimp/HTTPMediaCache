//
//  HLSPreloadPlanner.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

enum HLSPreloadPlan: Equatable {
    case childPlaylists([CacheRequest])
    case media(HLSMediaPreloadPlan)
}

struct HLSMediaPreloadPlan: Equatable {
    var actions: [HLSPreloadAction]
    var policy: HLSPreloadPolicy
    var targetSegments: Int
}

struct HLSPreloadAction: Equatable {
    var reference: HLSResourceReference
    var loadedSegmentCount: Int
    var loadedDuration: TimeInterval
}

struct HLSPreloadPlanner {
    func plan(
        playlist: HLSPlaylist,
        options: PreloadOptions,
        originalURL: URL,
        currentURL: URL
    ) async -> HLSPreloadPlan {
        let selectedResources = await HLSSelectionResolver().selectedResources(
            in: playlist,
            originalURL: originalURL,
            currentURL: currentURL
        )
        if selectedResources.variant != nil {
            return .childPlaylists(selectedResources.childPlaylistRequests)
        }

        return .media(mediaPlan(playlist: playlist, limit: options.hlsLimit))
    }

    private func mediaPlan(playlist: HLSPlaylist, limit: PreloadOptions.HLSLimit) -> HLSMediaPreloadPlan {
        let policy = HLSPreloadPolicy(limit: limit)
        let targetSegments = policy.targetSegmentCount(in: playlist)
        guard targetSegments > 0 else {
            return HLSMediaPreloadPlan(actions: [], policy: policy, targetSegments: targetSegments)
        }

        var actions: [HLSPreloadAction] = []
        var loadedSegments = 0
        var loadedDuration: TimeInterval = 0
        for item in playlist.items {
            if loadedSegments > 0,
               !policy.shouldLoadMoreSegments(
                   loadedSegments: loadedSegments,
                   loadedDuration: loadedDuration,
                   loadedBytes: 0
               )
            {
                break
            }

            switch item {
            case let .key(url):
                actions.append(HLSPreloadAction(
                    reference: HLSResourceReference(type: .key, url: url),
                    loadedSegmentCount: loadedSegments,
                    loadedDuration: loadedDuration
                ))
            case let .initialization(item):
                actions.append(HLSPreloadAction(
                    reference: HLSResourceReference(type: .initialization, url: item.url, byteRange: item.byteRange),
                    loadedSegmentCount: loadedSegments,
                    loadedDuration: loadedDuration
                ))
            case let .segment(segment):
                guard policy.shouldLoadMoreSegments(
                    loadedSegments: loadedSegments,
                    loadedDuration: loadedDuration,
                    loadedBytes: 0
                ) else {
                    break
                }
                actions.append(HLSPreloadAction(
                    reference: HLSResourceReference(
                        type: .segment,
                        url: segment.url,
                        byteRange: segment.byteRange,
                        duration: segment.duration
                    ),
                    loadedSegmentCount: loadedSegments,
                    loadedDuration: loadedDuration
                ))
                loadedSegments += 1
                loadedDuration += segment.duration
            case .variantStream, .rendition, .iFrameStream:
                continue
            }
        }

        return HLSMediaPreloadPlan(actions: actions, policy: policy, targetSegments: targetSegments)
    }
}
