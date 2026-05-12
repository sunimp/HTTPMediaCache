//
//  ProxyResponseValidator.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

enum ProxyResponseValidator {
    static func validateResponse(_ response: CacheDownloadResponse, for request: CacheRequest) throws {
        guard let range = request.range,
              !range.isSuffixRange,
              let requestedEnd = range.end,
              let expectedLength = range.length
        else {
            return
        }

        let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength ?? Int64(response.data.count)
        guard requestedEnd < totalLength else {
            return
        }

        let contentLength = response.headers.contentLength ?? Int64(response.data.count)
        guard contentLength == expectedLength else {
            throw CacheError.networkFailure("Mismatched Content-Length for \(request.url.absoluteString).")
        }
    }

    static func validateStreamingResponse(_ response: CacheStreamResponse, for request: CacheRequest) throws {
        guard let range = request.range,
              !range.isSuffixRange,
              let requestedEnd = range.end,
              let expectedLength = range.length,
              let contentLength = response.headers.contentLength,
              let totalLength = response.headers.contentRangeTotalLength ?? response.headers.contentLength,
              requestedEnd < totalLength
        else {
            return
        }

        guard contentLength == expectedLength else {
            throw CacheError.networkFailure("Mismatched Content-Length for \(request.url.absoluteString).")
        }
    }

    static func validateHeaderResponse(_ response: CacheHeaderResponse, for request: CacheRequest) throws {
        guard response.statusCode <= 400 else {
            throw CacheError.networkFailure("HTTP \(response.statusCode) for \(request.url.absoluteString).")
        }
        try validateStreamingResponse(
            CacheStreamResponse(
                statusCode: response.statusCode,
                headers: response.headers,
                body: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            ),
            for: request
        )
    }
}
