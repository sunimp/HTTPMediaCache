//
//  HTTPResponseWriter+Proxy.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation
import NIO
import NIOHTTP1

extension HTTPResponseWriter {
    func writeCachedResponse(_ response: CachedProxyResponse, status: HTTPResponseStatus, isHeadRequest: Bool, context: ChannelHandlerContext) {
        if isHeadRequest {
            writeHeadOnly(status: status, headers: response.headers, context: context)
        } else if status == .partialContent {
            writePartialContent(data: response.data, range: response.range, headers: response.headers, context: context)
        } else {
            writeOK(data: response.data, headers: response.headers, context: context)
        }
    }

    func writeDataResponse(data: Data, range: ByteRange? = nil, headers: [String: String], isHeadRequest: Bool, context: ChannelHandlerContext) {
        if let range {
            if isHeadRequest {
                let start = range.isSuffixRange ? headers.contentRangeStart ?? 0 : range.start
                let end = start + Int64(data.count) - 1
                var headHeaders = headers
                headHeaders["Accept-Ranges"] = headHeaders.headerValue(for: "Accept-Ranges") ?? "bytes"
                headHeaders["Content-Length"] = "\(data.count)"
                headHeaders["Content-Range"] = headHeaders.headerValue(for: "Content-Range") ?? "bytes \(start)-\(end)/*"
                writeHeadOnly(status: .partialContent, headers: headHeaders, context: context)
            } else {
                writePartialContent(data: data, range: range, headers: headers, context: context)
            }
        } else if isHeadRequest {
            var headHeaders = headers
            headHeaders["Content-Length"] = "\(data.count)"
            writeHeadOnly(status: .ok, headers: headHeaders, context: context)
        } else {
            writeOK(data: data, headers: headers, context: context)
        }
    }
}
