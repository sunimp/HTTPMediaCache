//
//  URLSessionDownloader.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

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
        try await URLSessionDownloadRetryPolicy().run {
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
                try await URLSessionDownloadValidator().validate(response: httpResponse, cacheRequest: cacheRequest)
            }
        } catch {
            task.cancel()
            session.invalidateAndCancel()
            throw error
        }

        streamDelegate.markStreamReturned()

        return CacheStreamResponse(
            statusCode: httpResponse.statusCode,
            headers: httpResponse.urlSessionHeaderDictionary,
            body: body,
            cancel: {
                task.cancel()
                session.invalidateAndCancel()
            }
        )
    }
}

private extension URLSessionDownloader {
    func perform(request cacheRequest: CacheRequest, validatesResponse: Bool, sendsRangeHeader: Bool = true) async throws -> CacheDownloadResponse {
        try await URLSessionDownloadRetryPolicy().run {
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
