//
//  HLSDownloadPolicy.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct HLSDownloadPolicy {
    func playlistRequest(from request: CacheRequest) async -> CacheRequest {
        await makeRequest(url: request.url, kind: .playlist, range: nil)
    }

    func mediaRequest(url: URL, range: ByteRange?) async -> CacheRequest {
        await makeRequest(url: url, kind: .segment, range: range)
    }

    func resourceRequest(url: URL, kind: HLSDownloadResourceKind, range: ByteRange?) async -> CacheRequest {
        await makeRequest(url: url, kind: kind, range: range)
    }

    func resourceRequest(for reference: HLSResourceReference) async -> CacheRequest {
        switch reference.type {
        case .playlist, .variantPlaylist, .renditionPlaylist, .subtitlePlaylist, .iFramePlaylist:
            return await makeRequest(url: reference.url, kind: reference.type.downloadKind, range: nil)
        case .key:
            return await makeRequest(url: reference.url, kind: .key, range: nil)
        case .initialization, .segment:
            return await makeRequest(url: reference.url, kind: reference.type.downloadKind, range: reference.byteRange)
        }
    }

    private func makeRequest(url: URL, kind: HLSDownloadResourceKind, range: ByteRange?) async -> CacheRequest {
        let context = HLSDownloadRequestContext(kind: kind, url: url, byteRange: range)
        let headers = await CacheRuntime.shared.hlsDownloadHeaders(for: context).filteringRangeHeader()
        return CacheRequest(downloadURL: url, headers: headers, range: range, allowsUnfilteredHeaders: true)
    }
}

private extension HLSResourceType {
    var downloadKind: HLSDownloadResourceKind {
        switch self {
        case .playlist:
            return .playlist
        case .variantPlaylist:
            return .variantPlaylist
        case .renditionPlaylist:
            return .renditionPlaylist
        case .subtitlePlaylist:
            return .subtitlePlaylist
        case .iFramePlaylist:
            return .iFramePlaylist
        case .key:
            return .key
        case .initialization:
            return .initialization
        case .segment:
            return .segment
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func filteringRangeHeader() -> [String: String] {
        filter { key, _ in
            key.caseInsensitiveCompare("Range") != .orderedSame
        }
    }
}
