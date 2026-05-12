//
//  ProxyOriginDownloader.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

enum ProxyOriginDownloader {
    static func downloadResponse(request: CacheRequest, downloader: any CacheDownloading) async throws -> CacheDownloadResponse {
        let response: CacheDownloadResponse
        if ProxyRequestClassifier.isHLSURL(request.url), let downloader = downloader as? any CacheHLSResponseDownloading {
            response = try await downloader.downloadHLSResponse(request: request)
        } else if let downloader = downloader as? any CacheResponseDownloading {
            response = try await downloader.downloadResponse(request: request)
        } else {
            let data = try await DataReader(downloader: downloader).read(request: request)
            response = CacheDownloadResponse(data: data, statusCode: 200, headers: [:])
        }

        try ProxyResponseValidator.validateResponse(response, for: request)
        return response
    }
}
