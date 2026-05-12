//
//  URLSessionDownloadRetryPolicy.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct URLSessionDownloadRetryPolicy {
    func run<T>(_ operation: () async throws -> T) async throws -> T {
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

    private func isTransientNetworkError(_ error: Error) -> Bool {
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
}
