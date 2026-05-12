//
//  HLSPreloadPolicy.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct HLSPreloadPolicy: Equatable {
    let limit: PreloadOptions.HLSLimit

    func targetSegmentCount(in playlist: HLSPlaylist) -> Int {
        switch limit {
        case .all:
            return playlist.segmentCount
        case let .segmentCount(count):
            return min(max(count, 0), playlist.segmentCount)
        case let .duration(duration):
            guard duration > 0 else {
                return 0
            }
            var total: TimeInterval = 0
            var count = 0
            for item in playlist.items {
                guard case let .segment(segment) = item else {
                    continue
                }
                guard total < duration else {
                    break
                }
                total += segment.duration
                count += 1
            }
            return count
        case let .byteCount(byteCount):
            guard byteCount > 0 else {
                return 0
            }
            return playlist.segmentCount
        }
    }

    func shouldLoadMoreSegments(
        loadedSegments: Int,
        loadedDuration: TimeInterval,
        loadedBytes: Int64
    ) -> Bool {
        switch limit {
        case .all:
            return true
        case let .segmentCount(count):
            return loadedSegments < count
        case let .duration(duration):
            return loadedDuration < duration
        case let .byteCount(byteCount):
            return loadedBytes < byteCount
        }
    }

    func progressValue(
        loadedSegments: Int,
        loadedDuration: TimeInterval,
        loadedBytes: Int64,
        targetSegments: Int
    ) -> Double {
        switch limit {
        case .all, .segmentCount:
            guard targetSegments > 0 else {
                return 1
            }
            return min(Double(loadedSegments) / Double(targetSegments), 1)
        case let .duration(duration):
            guard duration > 0 else {
                return 1
            }
            return min(loadedDuration / duration, 1)
        case let .byteCount(byteCount):
            guard byteCount > 0 else {
                return 1
            }
            return min(Double(loadedBytes) / Double(byteCount), 1)
        }
    }
}
