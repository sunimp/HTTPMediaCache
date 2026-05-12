//
//  ProxyResponseModels.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation
import NIO

struct CachedProxyResponse {
    var data: Data
    var range: ByteRange
    var headers: [String: String]
}

struct CachedHLSPlaylistResponse {
    var data: Data
    var headers: [String: String]
}

final class ProxyResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStarted = false

    var didStart: Bool {
        lock.lock()
        let value = hasStarted
        lock.unlock()
        return value
    }

    func markStarted() {
        lock.lock()
        hasStarted = true
        lock.unlock()
    }
}

struct ChannelHandlerContextBox: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}
