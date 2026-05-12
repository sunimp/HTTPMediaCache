//
//  SourcePlanner.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

/// 一段数据的来源。
public enum SourceSegment: Sendable, Equatable {
    /// 从本地缓存文件读取。
    case file(ByteRange)
    /// 从网络下载。
    case network(ByteRange)
}

/// 根据请求区间和已缓存区间规划读取来源。
public struct SourcePlanner: Sendable {
    /// 创建读取来源规划器。
    public init() {}

    /// 将请求区间拆成缓存文件读取段和网络下载段。
    public func plan(request: ByteRange, cachedZones: [ByteRange]) -> [SourceSegment] {
        guard let requestEnd = request.end else {
            return [.network(request)]
        }
        guard request.start <= requestEnd else {
            return []
        }

        var segments: [SourceSegment] = []
        var cursor = request.start

        for zone in cachedZones.sorted(by: { orderedRangeBefore($0, $1) }) {
            guard let zoneEnd = zone.end, zone.start <= zoneEnd else {
                continue
            }

            let intersectionStart = max(zone.start, request.start)
            let intersectionEnd = min(zoneEnd, requestEnd)
            guard intersectionStart <= intersectionEnd, intersectionEnd >= cursor else {
                continue
            }

            let fileStart = max(intersectionStart, cursor)
            if cursor < fileStart {
                segments.append(.network(ByteRange(start: cursor, end: fileStart - 1)))
            }

            segments.append(.file(ByteRange(start: fileStart, end: intersectionEnd)))

            cursor = intersectionEnd + 1
        }

        if cursor <= requestEnd {
            segments.append(.network(ByteRange(start: cursor, end: requestEnd)))
        }

        return segments
    }

    private func orderedRangeBefore(_ lhs: ByteRange, _ rhs: ByteRange) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        switch (lhs.end, rhs.end) {
        case let (lhsEnd?, rhsEnd?):
            return lhsEnd > rhsEnd
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return false
        }
    }
}
