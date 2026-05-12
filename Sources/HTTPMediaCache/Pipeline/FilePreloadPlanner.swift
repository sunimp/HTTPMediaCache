//
//  FilePreloadPlanner.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

struct FilePreloadPlan: Equatable {
    var targetRange: ByteRange
    var missingRanges: [ByteRange]
    var targetLength: Int64
}

struct FilePreloadPlanner {
    static let probeRange = ByteRange(start: 0, end: 1)
    private let minimumChunkLength: Int64 = 10 * 1024 * 1024

    func chunkLength(forTargetLength targetLength: Int64) -> Int64 {
        max(minimumChunkLength, targetLength * 5 / 100)
    }

    func plan(
        requestedStart: Int64,
        requestedByteCount: Int64,
        totalLength: Int64,
        cachedZones: [ByteRange]
    ) throws -> FilePreloadPlan {
        guard requestedStart >= 0, requestedByteCount > 0, totalLength > 0, requestedStart < totalLength else {
            throw CacheError.invalidRange
        }

        let cappedEnd = min(requestedStart + requestedByteCount - 1, totalLength - 1)
        let targetRange = ByteRange(start: requestedStart, end: cappedEnd)
        let missingRanges = SourcePlanner()
            .plan(request: targetRange, cachedZones: cachedZones)
            .compactMap { segment -> ByteRange? in
                if case let .network(range) = segment {
                    return range
                }
                return nil
            }

        return FilePreloadPlan(
            targetRange: targetRange,
            missingRanges: missingRanges,
            targetLength: cappedEnd - requestedStart + 1
        )
    }
}
