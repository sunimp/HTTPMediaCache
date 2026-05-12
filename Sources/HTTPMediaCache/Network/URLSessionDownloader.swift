//
//  URLSessionDownloader.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// 基于 URLSession 的默认下载器。
public struct URLSessionDownloader: CacheDownloading {
    private let configuration: URLSessionConfiguration

    /// 创建 URLSession 下载器。
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    /// 下载请求并返回完整数据。
    public func download(request cacheRequest: CacheRequest) async throws -> [Data] {
        try await [downloadResponse(request: cacheRequest).data]
    }
}

struct CacheDownloadResponse {
    var data: Data
    var statusCode: Int
    var headers: [String: String]
}

struct CacheHeaderResponse {
    var statusCode: Int
    var headers: [String: String]
}

protocol CacheResponseDownloading: CacheDownloading {
    func downloadResponse(request cacheRequest: CacheRequest) async throws -> CacheDownloadResponse
}

protocol CacheHeaderDownloading: CacheDownloading {
    func downloadHeaderResponse(request cacheRequest: CacheRequest) async throws -> CacheHeaderResponse
}

struct CacheStreamResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: AsyncThrowingStream<Data, Error>
    var cancel: (@Sendable () -> Void)?
}

protocol CacheStreamingDownloading: CacheDownloading {
    func streamResponse(request cacheRequest: CacheRequest) async throws -> CacheStreamResponse
}

extension URLSessionDownloader: CacheResponseDownloading {
    func downloadResponse(request cacheRequest: CacheRequest) async throws -> CacheDownloadResponse {
        try await perform(request: cacheRequest, validatesResponse: true)
    }
}

protocol CacheHLSResponseDownloading: CacheDownloading {
    func downloadHLSResponse(request cacheRequest: CacheRequest) async throws -> CacheDownloadResponse
}

extension URLSessionDownloader: CacheHLSResponseDownloading {
    func downloadHLSResponse(request cacheRequest: CacheRequest) async throws -> CacheDownloadResponse {
        try await perform(request: cacheRequest, validatesResponse: false, sendsRangeHeader: false)
    }
}

extension URLSessionDownloader: CacheHeaderDownloading {
    func downloadHeaderResponse(request cacheRequest: CacheRequest) async throws -> CacheHeaderResponse {
        let response = try await streamResponse(request: cacheRequest)
        response.cancel?()
        return CacheHeaderResponse(statusCode: response.statusCode, headers: response.headers)
    }
}

extension URLSessionDownloader: CacheStreamingDownloading {
    func streamResponse(request cacheRequest: CacheRequest) async throws -> CacheStreamResponse {
        try await withTransientRetry {
            try await streamResponseOnce(request: cacheRequest, validatesResponse: true)
        }
    }
}

private extension URLSessionDownloader {
    func streamResponseOnce(
        request cacheRequest: CacheRequest,
        validatesResponse: Bool,
        sendsRangeHeader: Bool = true
    ) async throws -> CacheStreamResponse {
        let request = await makeURLRequest(for: cacheRequest, sendsRangeHeader: sendsRangeHeader)
        let settings = await URLSessionDownloaderSettings.shared.snapshot()
        await URLSessionDownloaderBackgroundTaskCoordinator.shared.beginIfNeeded()

        let streamDelegate = URLSessionStreamingDelegate(
            requestURL: cacheRequest.url,
            metricsHandler: settings.metricsHandler
        )
        let backgroundTaskCoordinator = URLSessionDownloaderBackgroundTaskCoordinator.shared
        let body = AsyncThrowingStream<Data, Error> { continuation in
            streamDelegate.setBodyContinuation(continuation)
        }
        let session = URLSession(configuration: configuration, delegate: streamDelegate, delegateQueue: nil)
        streamDelegate.setCompletionHandler {
            session.finishTasksAndInvalidate()
            Task {
                if streamDelegate.shouldDelayBackgroundTaskEnd {
                    await backgroundTaskCoordinator.endIfNeededDelayed()
                } else {
                    await backgroundTaskCoordinator.endIfNeeded()
                }
            }
        }
        let task = session.dataTask(with: request)
        streamDelegate.setCancellationHandler {
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()

        let httpResponse: HTTPURLResponse
        do {
            httpResponse = try await streamDelegate.waitForResponse()
            if validatesResponse, httpResponse.statusCode > 400 {
                throw CacheError.networkFailure("HTTP \(httpResponse.statusCode) for \(cacheRequest.url.absoluteString).")
            }
            if validatesResponse {
                try await validateResponse(httpResponse, cacheRequest: cacheRequest)
            }
        } catch {
            task.cancel()
            session.invalidateAndCancel()
            throw error
        }

        streamDelegate.markStreamReturned()

        return CacheStreamResponse(
            statusCode: httpResponse.statusCode,
            headers: httpResponse.headerDictionary,
            body: body,
            cancel: {
                task.cancel()
                session.invalidateAndCancel()
            }
        )
    }
}

private final class URLSessionStreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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

private extension URLSessionDownloader {
    func perform(request cacheRequest: CacheRequest, validatesResponse: Bool, sendsRangeHeader: Bool = true) async throws -> CacheDownloadResponse {
        try await withTransientRetry {
            try await performOnce(request: cacheRequest, validatesResponse: validatesResponse, sendsRangeHeader: sendsRangeHeader)
        }
    }

    func performOnce(request cacheRequest: CacheRequest, validatesResponse: Bool, sendsRangeHeader: Bool = true) async throws -> CacheDownloadResponse {
        let response = try await streamResponseOnce(
            request: cacheRequest,
            validatesResponse: validatesResponse,
            sendsRangeHeader: sendsRangeHeader
        )
        var data = Data()
        for try await chunk in response.body {
            data.append(chunk)
        }

        return CacheDownloadResponse(data: data, statusCode: response.statusCode, headers: response.headers)
    }

    func withTransientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        let maxAttemptCount = 3
        var lastError: Error?

        for attempt in 1 ... maxAttemptCount {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttemptCount, isTransientNetworkError(error) else {
                    throw error
                }
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
            }
        }

        throw lastError ?? CacheError.networkFailure("Transient retry failed without an underlying error.")
    }

    func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }

        let retryableCodes = [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ]
        return retryableCodes.contains(nsError.code)
    }

    func validateResponse(_ response: HTTPURLResponse, cacheRequest: CacheRequest) async throws {
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

        let headers = response.headerDictionary
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

    func makeURLRequest(for cacheRequest: CacheRequest, sendsRangeHeader: Bool = true) async -> URLRequest {
        let settings = await URLSessionDownloaderSettings.shared.snapshot()
        var request = URLRequest(url: cacheRequest.url)
        request.timeoutInterval = settings.timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for (field, value) in cacheRequest.headers {
            guard cacheRequest.allowsUnfilteredHeaders || settings.shouldForwardHeader(field) else {
                continue
            }
            if !sendsRangeHeader, field.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            request.setValue(value, forHTTPHeaderField: field)
        }
        if sendsRangeHeader, let range = cacheRequest.range {
            request.setValue(range.requestHeaderValue, forHTTPHeaderField: "Range")
        }
        for (field, value) in settings.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

private actor URLSessionDownloaderBackgroundTaskCoordinator {
    static let shared = URLSessionDownloaderBackgroundTaskCoordinator()

    private var activeDownloadCount = 0

    #if canImport(UIKit)
        private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    func beginIfNeeded() async {
        activeDownloadCount += 1
        #if canImport(UIKit)
            guard backgroundTask == .invalid
            else {
                return
            }

            let applicationState = await MainActor.run {
                UIApplication.shared.applicationState
            }
            guard applicationState == .background else {
                return
            }

            backgroundTask = await MainActor.run {
                UIApplication.shared.beginBackgroundTask { [weak self] in
                    Task {
                        await self?.endIfNeeded(force: true)
                    }
                }
            }
        #endif
    }

    func endIfNeeded() async {
        await endIfNeeded(force: false)
    }

    func endIfNeededDelayed() async {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        await endIfNeeded(force: false)
    }

    private func endIfNeeded(force: Bool) async {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        #if canImport(UIKit)
            guard backgroundTask != .invalid,
                  force || activeDownloadCount == 0
            else {
                return
            }
            let endedBackgroundTask = backgroundTask
            backgroundTask = .invalid
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(endedBackgroundTask)
            }
        #endif
    }
}

private extension HTTPURLResponse {
    var headerDictionary: [String: String] {
        allHeaderFields.reduce(into: [String: String]()) { result, header in
            guard let name = header.key as? String else {
                return
            }
            result[name] = "\(header.value)"
        }
    }
}

actor URLSessionDownloaderSettings {
    static let shared = URLSessionDownloaderSettings()

    private var timeoutInterval: TimeInterval = 30
    private var whitelistHeaderKeys: [String] = []
    private var additionalHeaders: [String: String] = [:]
    private var acceptableContentTypes: [String]? = [
        "text/",
        "video/",
        "audio/",
        "vnd.apple.mpegURL",
        "application/x-mpegURL",
        "application/mp4",
        "application/octet-stream",
        "binary/octet-stream",
    ]
    private var unacceptableContentTypeDisposer: (@Sendable (URL, String) -> Bool)?
    private var metricsHandler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?

    func setTimeoutInterval(_ timeoutInterval: TimeInterval) {
        self.timeoutInterval = timeoutInterval
    }

    func setWhitelistHeaderKeys(_ whitelistHeaderKeys: [String]) {
        self.whitelistHeaderKeys = whitelistHeaderKeys
    }

    func setAdditionalHeaders(_ additionalHeaders: [String: String]) {
        self.additionalHeaders = additionalHeaders
    }

    func setAcceptableContentTypes(_ acceptableContentTypes: [String]?) {
        self.acceptableContentTypes = acceptableContentTypes
    }

    func setUnacceptableContentTypeDisposer(_ disposer: (@Sendable (URL, String) -> Bool)?) {
        unacceptableContentTypeDisposer = disposer
    }

    func setMetricsHandler(_ handler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?) {
        metricsHandler = handler
    }

    func reset() {
        timeoutInterval = 30
        whitelistHeaderKeys = []
        additionalHeaders = [:]
        acceptableContentTypes = [
            "text/",
            "video/",
            "audio/",
            "vnd.apple.mpegURL",
            "application/x-mpegURL",
            "application/mp4",
            "application/octet-stream",
            "binary/octet-stream",
        ]
        unacceptableContentTypeDisposer = nil
        metricsHandler = nil
    }

    func snapshot() -> URLSessionDownloaderSettingsSnapshot {
        URLSessionDownloaderSettingsSnapshot(
            timeoutInterval: timeoutInterval,
            whitelistHeaderKeys: whitelistHeaderKeys,
            additionalHeaders: additionalHeaders,
            acceptableContentTypes: acceptableContentTypes,
            unacceptableContentTypeDisposer: unacceptableContentTypeDisposer,
            metricsHandler: metricsHandler
        )
    }
}

struct URLSessionDownloaderSettingsSnapshot {
    var timeoutInterval: TimeInterval
    var whitelistHeaderKeys: [String]
    var additionalHeaders: [String: String]
    var acceptableContentTypes: [String]?
    var unacceptableContentTypeDisposer: (@Sendable (URL, String) -> Bool)?
    var metricsHandler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?

    func shouldForwardHeader(_ name: String) -> Bool {
        let availableHeaderKeys = [
            "User-Agent",
            "Connection",
            "Accept",
            "Accept-Encoding",
            "Accept-Language",
            "Range",
        ]
        return availableHeaderKeys.contains(name) || whitelistHeaderKeys.contains(name)
    }
}
