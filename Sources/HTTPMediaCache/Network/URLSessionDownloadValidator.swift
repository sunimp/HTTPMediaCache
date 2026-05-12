//
//  URLSessionDownloadValidator.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct URLSessionDownloadValidator {
    func validate(response: HTTPURLResponse, cacheRequest: CacheRequest) async throws {
        let settings = await URLSessionDownloaderSettings.shared.snapshot()
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type"), !contentType.isEmpty else {
            throw CacheError.networkFailure("Unacceptable content type for \(cacheRequest.url.absoluteString).")
        }

        let acceptableContentTypes = settings.acceptableContentTypes ?? []
        let isAcceptable = acceptableContentTypes.contains {
            contentType.range(of: $0, options: [.caseInsensitive]) != nil
        }
        if !isAcceptable,
           settings.unacceptableContentTypeDisposer?(cacheRequest.url, contentType) != true
        {
            throw CacheError.networkFailure("Unacceptable content type for \(cacheRequest.url.absoluteString).")
        }

        let headers = response.urlSessionHeaderDictionary
        let contentLength = headers.contentLength ?? 0
        guard contentLength > 0 else {
            throw CacheError.networkFailure("Invalid Content-Length for \(cacheRequest.url.absoluteString).")
        }

        guard let range = cacheRequest.range,
              !range.isSuffixRange,
              let requestedEnd = range.end,
              let expectedLength = range.length,
              let totalLength = headers.contentRangeTotalLength ?? headers.contentLength,
              requestedEnd < totalLength
        else {
            return
        }

        guard contentLength == expectedLength else {
            throw CacheError.networkFailure("Mismatched Content-Length for \(cacheRequest.url.absoluteString).")
        }
    }
}
