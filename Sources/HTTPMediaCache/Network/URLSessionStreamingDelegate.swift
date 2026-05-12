//
//  URLSessionStreamingDelegate.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

final class URLSessionStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let requestURL: URL
    private let metricsHandler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var responseResult: Result<HTTPURLResponse, Error>?
    private var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var cancellationHandler: (@Sendable () -> Void)?
    private var completionHandler: (@Sendable () -> Void)?
    private var didComplete = false
    private var streamReturned = false

    var shouldDelayBackgroundTaskEnd: Bool {
        lock.lock()
        let value = streamReturned
        lock.unlock()
        return value
    }

    init(requestURL: URL, metricsHandler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?) {
        self.requestURL = requestURL
        self.metricsHandler = metricsHandler
    }

    func setBodyContinuation(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.lock()
        bodyContinuation = continuation
        lock.unlock()

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else {
                return
            }
            self?.currentCancellationHandler()?()
        }
    }

    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        cancellationHandler = handler
        lock.unlock()
    }

    func setCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        completionHandler = handler
        let shouldCall = didComplete
        lock.unlock()

        if shouldCall {
            handler()
        }
    }

    func markStreamReturned() {
        lock.lock()
        streamReturned = true
        lock.unlock()
    }

    func waitForResponse() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let responseResult {
                lock.unlock()
                continuation.resume(with: responseResult)
                return
            }
            responseContinuation = continuation
            lock.unlock()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            let error = CacheError.networkFailure("Expected HTTPURLResponse.")
            completeResponse(.failure(error))
            finishBody(error)
            completionHandler(.cancel)
            return
        }

        completeResponse(.success(httpResponse))
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else {
            return
        }
        currentBodyContinuation()?.yield(data)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeResponse(.failure(error))
            finishBody(error)
        } else {
            finishBody(nil)
        }
        complete()
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        metricsHandler?(requestURL, metrics)
    }

    private func completeResponse(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard responseResult == nil else {
            lock.unlock()
            return
        }

        responseResult = result
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    private func currentBodyContinuation() -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        let continuation = bodyContinuation
        lock.unlock()
        return continuation
    }

    private func currentCancellationHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        let handler = cancellationHandler
        lock.unlock()
        return handler
    }

    private func finishBody(_ error: Error?) {
        lock.lock()
        let continuation = bodyContinuation
        bodyContinuation = nil
        lock.unlock()

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func complete() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }

        didComplete = true
        let handler = completionHandler
        lock.unlock()

        handler?()
    }
}
