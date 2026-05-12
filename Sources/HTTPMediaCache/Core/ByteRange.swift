//
//  ByteRange.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

/// HTTP Range 字节区间。
public struct ByteRange: Sendable, Codable, Hashable, Comparable {
    /// 后缀 Range 的起点占位值，例如 `bytes=-500`。
    public static let notFound: Int64 = .max

    /// 区间起点。
    public var start: Int64
    /// 区间终点；为 nil 时表示开放区间。
    public var end: Int64?

    /// 创建字节区间。
    public init(start: Int64, end: Int64? = nil) {
        self.start = start
        self.end = end
    }

    /// 从 HTTP `Range` 请求头解析字节区间。
    public init?(requestHeader: String) {
        guard requestHeader.hasPrefix("bytes=") else {
            return nil
        }

        let rangeText = requestHeader.dropFirst(6)
        let rangeParts = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeParts.count == 2 else {
            return nil
        }

        let startText = rangeParts[0]
        let endText = rangeParts[1]
        let start: Int64
        let end: Int64?
        if !startText.isEmpty,
           let parsedStart = Int64(startText),
           parsedStart >= 0
        {
            start = parsedStart
            if endText.isEmpty {
                end = nil
            } else {
                guard let parsedEnd = Int64(endText), parsedEnd >= parsedStart else {
                    return nil
                }
                end = parsedEnd
            }
        } else if startText.isEmpty,
                  let suffixLength = Int64(endText),
                  suffixLength > 0
        {
            start = Self.notFound
            end = suffixLength
        } else {
            return nil
        }

        if let end, start != Self.notFound, end < start {
            return nil
        }

        if start == Self.notFound, end == nil {
            return nil
        }

        self.init(start: start, end: end)
    }

    /// 是否为后缀 Range。
    public var isSuffixRange: Bool {
        start == Self.notFound && end != nil
    }

    /// 是否为从 0 开始的开放区间。
    public var isFullRange: Bool {
        start == 0 && end == nil
    }

    /// 区间长度；开放区间和后缀 Range 返回 nil。
    public var length: Int64? {
        guard let end, start != Self.notFound else {
            return nil
        }
        return end - start + 1
    }

    /// 对应的 HTTP `Range` 请求头值。
    public var requestHeaderValue: String {
        if start == Self.notFound {
            guard let end else {
                return "bytes=-"
            }
            return "bytes=-\(end)"
        }
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    /// 根据资源总长度规整开放区间。
    public func normalized(totalLength: Int64) -> ByteRange {
        guard totalLength > 0 else {
            return self
        }
        if start == Self.notFound {
            return self
        }
        if end == nil || (end ?? 0) >= totalLength {
            return ByteRange(start: start, end: totalLength - 1)
        }
        return self
    }

    /// 按起点和终点排序区间。
    public static func < (lhs: ByteRange, rhs: ByteRange) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        switch (lhs.end, rhs.end) {
        case let (lhsEnd?, rhsEnd?):
            return lhsEnd < rhsEnd
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return false
        }
    }
}
