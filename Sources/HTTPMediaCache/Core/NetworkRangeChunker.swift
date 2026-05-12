//
//  NetworkRangeChunker.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

enum NetworkRangeChunker {
    static func split(_ range: ByteRange, maximumLength: Int64) -> [ByteRange] {
        guard maximumLength > 0, let end = range.end, range.start <= end else {
            return [range]
        }

        var ranges: [ByteRange] = []
        var start = range.start
        while start <= end {
            let chunkEnd = min(start + maximumLength - 1, end)
            ranges.append(ByteRange(start: start, end: chunkEnd))
            start = chunkEnd + 1
        }
        return ranges
    }
}
