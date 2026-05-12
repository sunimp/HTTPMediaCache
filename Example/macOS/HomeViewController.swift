//
//  HomeViewController.swift
//  HTTPMediaCacheMacExample
//
//  Created by Sun on 2026/5/11.
//

import AppKit
import HTTPMediaCache

final class HomeViewController: NSViewController {
    private enum Column {
        static let title = NSUserInterfaceItemIdentifier("title")
        static let format = NSUserInterfaceItemIdentifier("format")
        static let cacheStatus = NSUserInterfaceItemIdentifier("cacheStatus")
        static let progress = NSUserInterfaceItemIdentifier("progress")
        static let url = NSUserInterfaceItemIdentifier("url")
    }

    private let mediaItems = MediaItem.samples
    private let mediaCategories = MediaItem.Category.allCases
    private let mediaURLs = Set(MediaItem.samples.map(\.url))
    private let statusLabel = NSTextField(labelWithString: "Starting proxy...")
    private let metricsSummaryLabel = NSTextField(labelWithString: DownloadMetricsSnapshot.empty.summaryText)
    private let metricsTextView = NSTextView()
    private let tableView = NSTableView()
    private let cacheProxyButton = NSButton(checkboxWithTitle: "Cache Proxy", target: nil, action: nil)
    private let airPlayProxyButton = NSButton(checkboxWithTitle: "AirPlay Proxy", target: nil, action: nil)
    private let preloadButton = NSButton(title: "Preload All", target: nil, action: nil)
    private let deleteAllButton = NSButton(title: "Delete All Cache", target: nil, action: nil)
    private var metricsSnapshot = DownloadMetricsSnapshot.empty
    private var cacheItemsByURL: [URL: CacheItem] = [:]
    private var cacheStatuses: [URL: CacheStatus] = [:]
    private var playerWindows: [PlayerWindowController] = []
    private var statusRefreshTask: Task<Void, Never>?
    private var metricsObserver: NSObjectProtocol?
    private var isCacheEnabled = true
    private var usesAirPlayProxy = false

    deinit {
        statusRefreshTask?.cancel()
        if let metricsObserver {
            NotificationCenter.default.removeObserver(metricsObserver)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureSubviews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureMetricsObservation()
        startProxy()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startCacheStatusRefresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopCacheStatusRefresh()
    }
}

private extension HomeViewController {
    enum CacheStatus: Equatable {
        case waiting
        case cached
        case finished
        case failed(String)

        var title: String {
            switch self {
            case .waiting:
                return "No Cache"
            case .cached:
                return "Caching"
            case .finished:
                return "Finished"
            case .failed:
                return "Failed"
            }
        }
    }

    enum TableRow {
        case category(MediaItem.Category)
        case media(MediaItem)
    }

    func configureSubviews() {
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        metricsSummaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metricsSummaryLabel.textColor = .labelColor

        cacheProxyButton.state = .on
        cacheProxyButton.target = self
        cacheProxyButton.action = #selector(cacheProxyChanged)
        airPlayProxyButton.target = self
        airPlayProxyButton.action = #selector(airPlayProxyChanged)
        preloadButton.target = self
        preloadButton.action = #selector(preloadAll)
        deleteAllButton.target = self
        deleteAllButton.action = #selector(deleteAllCaches)

        let buttonStack = NSStackView(views: [cacheProxyButton, airPlayProxyButton, preloadButton, deleteAllButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let headerStack = NSStackView(views: [statusLabel, NSView(), buttonStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12

        let metricsScrollView = NSScrollView()
        metricsScrollView.hasVerticalScroller = true
        metricsScrollView.borderType = .bezelBorder
        metricsScrollView.documentView = metricsTextView
        metricsTextView.isEditable = false
        metricsTextView.isSelectable = true
        metricsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metricsTextView.textContainerInset = NSSize(width: 8, height: 6)
        metricsTextView.string = "No metrics yet"

        let metricsStack = NSStackView(views: [metricsSummaryLabel, metricsScrollView])
        metricsStack.orientation = .vertical
        metricsStack.spacing = 6

        configureTableView()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let contentStack = NSStackView(views: [headerStack, metricsStack, scrollView])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            metricsScrollView.heightAnchor.constraint(equalToConstant: 92),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    func configureTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(playSelectedItem)
        tableView.target = self

        let titleColumn = NSTableColumn(identifier: Column.title)
        titleColumn.title = "Title"
        titleColumn.width = 230
        tableView.addTableColumn(titleColumn)

        let formatColumn = NSTableColumn(identifier: Column.format)
        formatColumn.title = "Format"
        formatColumn.width = 80
        tableView.addTableColumn(formatColumn)

        let statusColumn = NSTableColumn(identifier: Column.cacheStatus)
        statusColumn.title = "Cache"
        statusColumn.width = 110
        tableView.addTableColumn(statusColumn)

        let progressColumn = NSTableColumn(identifier: Column.progress)
        progressColumn.title = "Progress"
        progressColumn.width = 110
        tableView.addTableColumn(progressColumn)

        let urlColumn = NSTableColumn(identifier: Column.url)
        urlColumn.title = "URL"
        urlColumn.width = 360
        tableView.addTableColumn(urlColumn)
    }

    func startProxy() {
        guard isCacheEnabled else {
            updateStatus("Cache disabled")
            return
        }

        Task {
            do {
                await configureDownloadMetricsHandler()
                try await HTTPMediaCache.start(port: 0)
                guard isCacheEnabled else {
                    await HTTPMediaCache.stop()
                    await MainActor.run {
                        updateStatus("Cache disabled")
                    }
                    return
                }
                await MainActor.run {
                    updateStatus("Proxy started")
                }
                await refreshCacheSnapshot()
            } catch {
                await MainActor.run {
                    updateStatus("Proxy failed: \(error)")
                }
            }
        }
    }

    func stopProxy() {
        Task {
            await HTTPMediaCache.stop()
            await MainActor.run {
                updateStatus("Cache disabled")
            }
        }
    }

    func configureDownloadMetricsHandler() async {
        await HTTPMediaCache.setDownloadMetricsHandler { url, metrics in
            Task {
                await DownloadMetricsStore.shared.record(url: url, metrics: metrics)
            }
        }
        await refreshMetricsSnapshot()
    }

    func configureMetricsObservation() {
        metricsObserver = NotificationCenter.default.addObserver(
            forName: .downloadMetricsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.refreshMetricsSnapshot()
            }
        }
    }

    func refreshMetricsSnapshot() async {
        let snapshot = await DownloadMetricsStore.shared.snapshot()
        await MainActor.run {
            metricsSnapshot = snapshot
            metricsSummaryLabel.stringValue = "Download Metrics · \(snapshot.summaryText)"
            metricsTextView.string = metricsText(for: snapshot)
        }
    }

    func metricsText(for snapshot: DownloadMetricsSnapshot) -> String {
        guard !snapshot.records.isEmpty else {
            return "No metrics yet"
        }

        return snapshot.records.map { record in
            "\(record.hostText) · \(record.detailText) · \(record.url.lastPathComponent)"
        }.joined(separator: "\n")
    }

    func updateStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    @objc func playSelectedItem() {
        let selectedRow = tableView.selectedRow
        guard let item = mediaItem(at: selectedRow) else {
            return
        }
        play(item)
    }

    func play(_ item: MediaItem) {
        Task {
            do {
                let playbackURL = try await playbackURL(for: item)
                await MainActor.run {
                    let controller = PlayerWindowController(url: playbackURL, title: item.title)
                    playerWindows.append(controller)
                    controller.showWindow(nil)
                }
            } catch {
                await MainActor.run {
                    showError(error)
                }
            }
        }
    }

    func playbackURL(for item: MediaItem) async throws -> URL {
        guard isCacheEnabled else {
            return item.url
        }
        return try await HTTPMediaCache.proxyURL(for: item.url, bindToLocalhost: !usesAirPlayProxy)
    }

    @objc func cacheProxyChanged() {
        isCacheEnabled = cacheProxyButton.state == .on
        airPlayProxyButton.isEnabled = isCacheEnabled
        preloadButton.isEnabled = isCacheEnabled
        if isCacheEnabled {
            updateStatus("Starting proxy...")
            startProxy()
        } else {
            stopProxy()
        }
    }

    @objc func airPlayProxyChanged() {
        usesAirPlayProxy = airPlayProxyButton.state == .on
    }

    @objc func preloadAll() {
        guard isCacheEnabled else {
            updateStatus("Cache disabled")
            return
        }
        preloadButton.isEnabled = false
        Task {
            for item in mediaItems {
                do {
                    let task = try await HTTPMediaCache.preload(CacheRequest(url: item.url), options: .init())
                    for await progress in task.progress {
                        await MainActor.run {
                            updateStatus("Preloading \(item.title): \(Int(progress * 100))%")
                        }
                        await refreshCacheSnapshot()
                    }
                } catch {
                    await MainActor.run {
                        updateStatus("Preload failed: \(error)")
                    }
                }
            }
            await MainActor.run {
                preloadButton.isEnabled = true
                updateStatus("Preload finished")
            }
            await refreshCacheSnapshot()
        }
    }

    @objc func deleteAllCaches() {
        Task {
            do {
                try await HTTPMediaCache.deleteAllCaches()
                await MainActor.run {
                    updateStatus("All cache deleted")
                }
                await refreshCacheSnapshot()
            } catch {
                await MainActor.run {
                    updateStatus("Delete failed: \(error)")
                }
            }
        }
    }

    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    func startCacheStatusRefresh() {
        stopCacheStatusRefresh()
        statusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCacheSnapshot()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopCacheStatusRefresh() {
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
    }

    func refreshCacheSnapshot() async {
        let items = (try? await HTTPMediaCache.allCacheItems()) ?? []
        let nextItemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var nextStatuses: [URL: CacheStatus] = [:]
        for url in mediaURLs {
            nextStatuses[url] = await cacheStatus(for: url, cacheItem: nextItemsByURL[url])
        }

        await MainActor.run {
            cacheItemsByURL = nextItemsByURL
            cacheStatuses = nextStatuses
            tableView.reloadData()
        }
    }

    func cacheStatus(for url: URL, cacheItem: CacheItem?) async -> CacheStatus {
        if let error = await HTTPMediaCache.error(for: url) {
            return .failed(error.localizedDescription)
        }

        guard let cacheItem, cacheItem.totalLength > 0, cacheItem.cachedLength > 0 else {
            return .waiting
        }
        return cacheItem.progress >= 1 ? .finished : .cached
    }

    func cacheStatusText(for item: MediaItem) -> String {
        (cacheStatuses[item.url] ?? .waiting).title
    }

    func cacheProgressText(for item: MediaItem) -> String {
        guard let cacheItem = cacheItemsByURL[item.url],
              cacheItem.totalLength > 0
        else {
            return "-"
        }

        let progressText = percentText(for: cacheItem.progress)
        return "\(progressText) (\(byteCountText(cacheItem.cachedLength))/\(byteCountText(cacheItem.totalLength)))"
    }

    func percentText(for progress: Double) -> String {
        let clampedProgress = min(max(progress, 0), 1)
        return "\(Int(clampedProgress * 100))%"
    }

    func byteCountText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var tableRows: [TableRow] {
        mediaCategories.flatMap { category -> [TableRow] in
            [.category(category)] + mediaItems.filter { $0.category == category }.map(TableRow.media)
        }
    }

    func mediaItem(at row: Int) -> MediaItem? {
        guard tableRows.indices.contains(row) else {
            return nil
        }
        if case let .media(item) = tableRows[row] {
            return item
        }
        return nil
    }
}

extension HomeViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        tableRows.count
    }
}

extension HomeViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableRows.indices.contains(row) else {
            return false
        }
        if case .category = tableRows[row] {
            return true
        }
        return false
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        mediaItem(at: row) != nil
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableRows.indices.contains(row) else {
            return nil
        }

        if case let .category(category) = tableRows[row] {
            let cell = NSTableCellView()
            let textField = NSTextField(labelWithString: category.title)
            textField.font = .boldSystemFont(ofSize: 13)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        guard case let .media(item) = tableRows[row] else {
            return nil
        }

        let identifier = tableColumn?.identifier ?? Column.title
        let text: String
        switch identifier {
        case Column.title:
            text = item.title
        case Column.format:
            text = item.format.title
        case Column.cacheStatus:
            text = cacheStatusText(for: item)
        case Column.progress:
            text = cacheProgressText(for: item)
        case Column.url:
            text = item.url.absoluteString
        default:
            text = ""
        }

        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: text)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
