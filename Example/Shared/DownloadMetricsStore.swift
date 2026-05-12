//
//  DownloadMetricsStore.swift
//  HTTPMediaCacheExample
//
//  Created by Sun on 2026/5/12.
//

import Foundation

struct DownloadMetricRecord: Equatable, Identifiable {
    let id: UUID
    let url: URL
    let recordedAt: Date
    let duration: TimeInterval
    let redirectCount: Int
    let transactionCount: Int
    let statusCode: Int?
    let networkProtocolName: String?

    var hostText: String {
        url.host ?? url.absoluteString
    }

    var durationText: String {
        Self.formatDuration(duration)
    }

    var detailText: String {
        var parts = [durationText, "\(transactionCount) txn"]
        if let statusCode {
            parts.append("HTTP \(statusCode)")
        }
        if redirectCount > 0 {
            parts.append("\(redirectCount) redirect")
        }
        if let networkProtocolName, !networkProtocolName.isEmpty {
            parts.append(networkProtocolName)
        }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        durationFormatter.string(from: duration) ?? String(format: "%.2fs", duration)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct DownloadMetricsSnapshot: Equatable {
    let records: [DownloadMetricRecord]

    static let empty = DownloadMetricsSnapshot(records: [])

    var totalCount: Int {
        records.count
    }

    var latestRecord: DownloadMetricRecord? {
        records.first
    }

    var averageDuration: TimeInterval? {
        guard !records.isEmpty else {
            return nil
        }
        return records.map(\.duration).reduce(0, +) / Double(records.count)
    }

    var summaryText: String {
        guard let latestRecord else {
            return "No metrics yet"
        }

        let averageText = averageDuration.map(DownloadMetricRecord.formatDuration) ?? "-"
        return "\(totalCount) downloads · avg \(averageText) · latest \(latestRecord.durationText)"
    }
}

extension Notification.Name {
    static let downloadMetricsDidChange = Notification.Name("HTTPMediaCacheExampleDownloadMetricsDidChange")
}

actor DownloadMetricsStore {
    static let shared = DownloadMetricsStore()

    private let maxRecordCount = 20
    private var records: [DownloadMetricRecord] = []

    func record(url: URL, metrics: URLSessionTaskMetrics) {
        let latestTransaction = metrics.transactionMetrics.last
        let record = DownloadMetricRecord(
            id: UUID(),
            url: url,
            recordedAt: Date(),
            duration: metrics.taskInterval.duration,
            redirectCount: metrics.redirectCount,
            transactionCount: metrics.transactionMetrics.count,
            statusCode: (latestTransaction?.response as? HTTPURLResponse)?.statusCode,
            networkProtocolName: latestTransaction?.networkProtocolName
        )
        records.insert(record, at: 0)
        if records.count > maxRecordCount {
            records.removeLast(records.count - maxRecordCount)
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .downloadMetricsDidChange, object: nil)
        }
    }

    func snapshot() -> DownloadMetricsSnapshot {
        DownloadMetricsSnapshot(records: records)
    }

    func clear() {
        records.removeAll()
        Task { @MainActor in
            NotificationCenter.default.post(name: .downloadMetricsDidChange, object: nil)
        }
    }
}
