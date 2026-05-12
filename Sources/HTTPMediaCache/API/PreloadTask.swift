//
//  PreloadTask.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 预加载任务句柄。
public final class PreloadTask: @unchecked Sendable {
    /// 任务对应的缓存请求。
    public let request: CacheRequest
    /// 预加载进度流，取值范围为 0...1。
    public let progress: AsyncStream<Double>
    private let cancelHandler: @Sendable () -> Void
    private let completionTask: Task<Void, Error>

    /// 创建预加载任务句柄。
    public init(
        request: CacheRequest,
        progress: AsyncStream<Double>,
        completionTask: Task<Void, Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.request = request
        self.progress = progress
        self.completionTask = completionTask
        cancelHandler = cancel
    }

    /// 取消预加载任务。
    public func cancel() {
        cancelHandler()
    }

    /// 等待预加载完成；失败或取消时会抛出对应错误。
    public func waitForCompletion() async throws {
        try await completionTask.value
    }
}

final class PreloadProgress: @unchecked Sendable {
    let stream: AsyncStream<Double>
    private let lock = NSLock()
    private var continuation: AsyncStream<Double>.Continuation?

    init() {
        var continuation: AsyncStream<Double>.Continuation?
        stream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    func yield(_ progress: Double) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(progress)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

actor PreloadStartGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
