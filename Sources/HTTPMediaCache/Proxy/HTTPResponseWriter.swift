//
//  HTTPResponseWriter.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
import NIO
import NIOHTTP1

/// HTTP 响应写入工具。
public struct HTTPResponseWriter: Sendable {
    /// 创建响应写入工具。
    public init() {}

    func writeNotFound(context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            let head = HTTPResponseHead(version: .http1_1, status: .notFound, headers: headers)
            contextBox.context.write(wrap(.head(head)), promise: nil)
            contextBox.context.writeAndFlush(wrap(.end(nil)), promise: nil)
        }
    }

    func writeOK(data: Data, headers sourceHeaders: [String: String] = [:], context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            var headers = responseHeaders(from: sourceHeaders)
            headers.add(name: "Content-Length", value: "\(data.count)")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            contextBox.context.write(wrap(.head(head)), promise: nil)

            var buffer = contextBox.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            contextBox.context.write(wrap(.body(.byteBuffer(buffer))), promise: nil)
            contextBox.context.writeAndFlush(wrap(.end(nil)), promise: nil)
        }
    }

    func writePartialContent(data: Data, range: ByteRange, headers sourceHeaders: [String: String] = [:], context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            let start = range.isSuffixRange ? sourceHeaders.contentRangeStart ?? 0 : range.start
            let end = start + Int64(data.count) - 1

            var headers = responseHeaders(from: sourceHeaders)
            headers.replaceOrAdd(name: "Accept-Ranges", value: "bytes")
            headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
            headers.replaceOrAdd(name: "Content-Range", value: sourceHeaders.headerValue(for: "Content-Range") ?? "bytes \(start)-\(end)/*")

            let head = HTTPResponseHead(version: .http1_1, status: .partialContent, headers: headers)
            contextBox.context.write(wrap(.head(head)), promise: nil)

            var buffer = contextBox.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            contextBox.context.write(wrap(.body(.byteBuffer(buffer))), promise: nil)
            contextBox.context.writeAndFlush(wrap(.end(nil)), promise: nil)
        }
    }

    func writeStreamingHead(status: HTTPResponseStatus, headers sourceHeaders: [String: String], range: ByteRange?, context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            var headers = responseHeaders(from: sourceHeaders)
            headers.replaceOrAdd(name: "Accept-Ranges", value: sourceHeaders.headerValue(for: "Accept-Ranges") ?? "bytes")

            if let contentLength = sourceHeaders.headerValue(for: "Content-Length") {
                headers.replaceOrAdd(name: "Content-Length", value: contentLength)
            }

            if status == .partialContent, let range {
                headers.replaceOrAdd(
                    name: "Content-Range",
                    value: sourceHeaders.headerValue(for: "Content-Range") ?? "bytes \(range.start)-\(range.end ?? range.start)/*"
                )
            }

            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            contextBox.context.writeAndFlush(wrap(.head(head)), promise: nil)
        }
    }

    func writeHeadOnly(status: HTTPResponseStatus, headers sourceHeaders: [String: String], context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            var headers = responseHeaders(from: sourceHeaders)
            if let contentLength = sourceHeaders.headerValue(for: "Content-Length") {
                headers.replaceOrAdd(name: "Content-Length", value: contentLength)
            }
            if let contentRange = sourceHeaders.headerValue(for: "Content-Range") {
                headers.replaceOrAdd(name: "Content-Range", value: contentRange)
            }
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            contextBox.context.write(wrap(.head(head)), promise: nil)
            contextBox.context.writeAndFlush(wrap(.end(nil)), promise: nil)
        }
    }

    func writeBody(_ data: Data, context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            var buffer = contextBox.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            contextBox.context.writeAndFlush(wrap(.body(.byteBuffer(buffer))), promise: nil)
        }
    }

    func writeEnd(context: ChannelHandlerContext) {
        let contextBox = ResponseContextBox(context)
        context.eventLoop.execute {
            contextBox.context.writeAndFlush(wrap(.end(nil)), promise: nil)
        }
    }

    private func wrap(_ part: HTTPServerResponsePart) -> NIOAny {
        NIOAny(part)
    }

    private func responseHeaders(from sourceHeaders: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for name in ["Accept-Ranges", "Connection", "Content-Type", "Server"] {
            guard let value = sourceHeaders.headerValue(for: name) else {
                continue
            }
            headers.replaceOrAdd(name: name, value: value)
        }
        return headers
    }
}

private struct ResponseContextBox: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}
