//
//  ProxyRequestClassifier.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

enum ProxyRequestClassifier {
    static func isHLSURL(_ url: URL) -> Bool {
        url.absoluteString.range(of: ".m3u", options: [.caseInsensitive]) != nil
    }

    static func isHLSMediaSegmentURL(_ url: URL) -> Bool {
        let segmentExtensions = [
            "ts",
            "m4s",
            "m4a",
            "aac",
            "vtt",
            "webvtt",
        ]
        return segmentExtensions.contains(url.pathExtension.lowercased())
    }
}
