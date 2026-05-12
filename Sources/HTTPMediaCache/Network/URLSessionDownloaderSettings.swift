//
//  URLSessionDownloaderSettings.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

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
