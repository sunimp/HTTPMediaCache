//
//  CacheViewController.swift
//  HTTPMediaCacheiOSExample
//
//  Created by Sun on 2026/5/9.
//

import HTTPMediaCache
import UIKit

final class CacheViewController: UITableViewController {
    private static let cellReuseIdentifier = "Cell"

    private let mediaItems: [MediaItem]
    private let mediaURLs: Set<URL>
    private var statuses: [Status]
    private var cacheItemsByURL: [URL: CacheItem] = [:]
    private var expandedURLs: Set<URL> = []
    private var statusRefreshTask: Task<Void, Never>?
    private var preloadTasks: [Int: Task<Void, Never>] = [:]

    private lazy var startItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.down.circle"),
            style: .plain,
            target: self,
            action: #selector(startPreload)
        )
        item.accessibilityLabel = "Preload All"
        return item
    }()

    private lazy var deleteAllItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            style: .plain,
            target: self,
            action: #selector(deleteAllCaches)
        )
        item.tintColor = .systemRed
        item.accessibilityLabel = "Delete All Cache"
        return item
    }()

    private var unmatchedCacheItems: [CacheItem] {
        cacheItemsByURL.values
            .filter { !mediaURLs.contains($0.url) && !isHLSResourceCacheURL($0.url) }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    init(mediaItems: [MediaItem]) {
        self.mediaItems = mediaItems
        mediaURLs = Set(mediaItems.map(\.url))
        statuses = Array(repeating: .waiting, count: mediaItems.count)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        statusRefreshTask?.cancel()
        preloadTasks.values.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Cache"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
        navigationItem.rightBarButtonItems = [startItem, deleteAllItem]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCacheStatusRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCacheStatusRefresh()
    }
}

private extension CacheViewController {
    enum Section: Int, CaseIterable {
        case samples
        case unmatched

        var title: String {
            switch self {
            case .samples:
                return "Samples"
            case .unmatched:
                return "Unmatched Cache"
            }
        }
    }

    enum Status: Equatable {
        case waiting
        case loading(Double)
        case finished
        case failed(String)

        var title: String {
            switch self {
            case .waiting:
                return "Waiting"
            case let .loading(progress):
                return Self.percentText(for: progress)
            case .finished:
                return "100%"
            case .failed:
                return "Failed"
            }
        }

        var textColor: UIColor {
            switch self {
            case .failed:
                return .systemRed
            case .waiting, .loading, .finished:
                return .secondaryLabel
            }
        }

        private static func percentText(for progress: Double) -> String {
            let clampedProgress = min(max(progress, 0), 1)
            return "\(Int(clampedProgress * 100))%"
        }
    }

    enum Row {
        case sample(Int)
        case sampleZone(sampleIndex: Int, zoneIndex: Int)
        case sampleHLSResourceSummary(Int)
        case sampleHLSResource(sampleIndex: Int, resourceIndex: Int)
        case sampleHLSResourceZone(sampleIndex: Int, resourceIndex: Int, zoneIndex: Int)
        case unmatched(Int)
        case unmatchedZone(cacheIndex: Int, zoneIndex: Int)
        case emptyUnmatched
    }
}

// MARK: - 表格

extension CacheViewController {
    override func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
        configure(cell, for: row(at: indexPath))
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        handleSelection(of: row(at: indexPath))
    }

    override func tableView(
        _: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, let url = deletableURL(for: row(at: indexPath)) else {
            return
        }
        deleteCache(for: url)
    }
}

private extension CacheViewController {
    func rows(in section: Int) -> [Row] {
        guard let section = Section(rawValue: section) else {
            return []
        }

        switch section {
        case .samples:
            return sampleRows()
        case .unmatched:
            return unmatchedRows()
        }
    }

    func sampleRows() -> [Row] {
        mediaItems.indices.flatMap { index -> [Row] in
            let item = mediaItems[index]
            guard expandedURLs.contains(item.url) else {
                return [.sample(index)]
            }

            var rows: [Row] = [.sample(index)]
            if let zones = cacheItemsByURL[item.url]?.zones, !zones.isEmpty {
                rows.append(contentsOf: zones.indices.map { .sampleZone(sampleIndex: index, zoneIndex: $0) })
            }

            if item.format == .hls {
                let resources = relatedHLSCacheItems(for: item)
                rows.append(.sampleHLSResourceSummary(index))
                for resourceIndex in resources.indices {
                    rows.append(.sampleHLSResource(sampleIndex: index, resourceIndex: resourceIndex))
                    guard expandedURLs.contains(resources[resourceIndex].url) else {
                        continue
                    }
                    rows.append(contentsOf: resources[resourceIndex].zones.indices.map {
                        .sampleHLSResourceZone(sampleIndex: index, resourceIndex: resourceIndex, zoneIndex: $0)
                    })
                }
            }

            return rows
        }
    }

    func unmatchedRows() -> [Row] {
        let items = unmatchedCacheItems
        guard !items.isEmpty else {
            return [.emptyUnmatched]
        }

        return items.indices.flatMap { index -> [Row] in
            guard expandedURLs.contains(items[index].url) else {
                return [.unmatched(index)]
            }
            return [.unmatched(index)] + items[index].zones.indices.map {
                .unmatchedZone(cacheIndex: index, zoneIndex: $0)
            }
        }
    }

    func row(at indexPath: IndexPath) -> Row {
        rows(in: indexPath.section)[indexPath.row]
    }
}

// MARK: - 单元格配置

private extension CacheViewController {
    func configure(_ cell: UITableViewCell, for row: Row) {
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.numberOfLines = 3
        cell.accessoryType = .none
        cell.accessoryView = nil

        switch row {
        case let .sample(index):
            configureSampleCell(&content, cell: cell, index: index)
        case let .sampleZone(sampleIndex, zoneIndex):
            configureZoneCell(&content, title: "Zone \(zoneIndex + 1)", zone: sampleZone(sampleIndex: sampleIndex, zoneIndex: zoneIndex))
        case let .sampleHLSResourceSummary(index):
            configureHLSResourceSummaryCell(&content, index: index)
        case let .sampleHLSResource(sampleIndex, resourceIndex):
            configureHLSResourceCell(&content, cell: cell, sampleIndex: sampleIndex, resourceIndex: resourceIndex)
        case let .sampleHLSResourceZone(sampleIndex, resourceIndex, zoneIndex):
            let resource = relatedHLSCacheItems(for: mediaItems[sampleIndex])[resourceIndex]
            configureZoneCell(&content, title: "Resource Zone \(zoneIndex + 1)", zone: resource.zones[zoneIndex])
        case let .unmatched(index):
            configureUnmatchedCell(&content, cell: cell, index: index)
        case let .unmatchedZone(cacheIndex, zoneIndex):
            configureZoneCell(&content, title: "Zone \(zoneIndex + 1)", zone: unmatchedCacheItems[cacheIndex].zones[zoneIndex])
        case .emptyUnmatched:
            content.text = "No Cache"
            content.secondaryText = "No cached item outside samples or HLS resources."
        }

        cell.contentConfiguration = content
    }

    func configureSampleCell(_ content: inout UIListContentConfiguration, cell: UITableViewCell, index: Int) {
        let item = mediaItems[index]
        let cacheItem = cacheItemsByURL[item.url]
        content.text = item.title
        content.secondaryText = sampleDetailText(for: item, cacheItem: cacheItem)
        cell.accessoryView = makeSampleAccessoryView(for: item, index: index)
    }

    func configureHLSResourceSummaryCell(_ content: inout UIListContentConfiguration, index: Int) {
        let resources = relatedHLSCacheItems(for: mediaItems[index])
        let cachedLength = resources.reduce(0) { $0 + $1.cachedLength }
        content.text = "HLS Resources"
        content.secondaryText = resources.isEmpty
            ? "No cached segment, key, or init map resource."
            : "\(resources.count) resources, \(byteCountText(cachedLength)) cached"
    }

    func configureHLSResourceCell(_ content: inout UIListContentConfiguration, cell: UITableViewCell, sampleIndex: Int, resourceIndex: Int) {
        let item = relatedHLSCacheItems(for: mediaItems[sampleIndex])[resourceIndex]
        content.text = resourceTitle(for: item.url)
        content.secondaryText = "\(item.url.absoluteString)\n\(cacheDetailText(for: item))"
        cell.accessoryType = item.zones.isEmpty ? .none : .disclosureIndicator
    }

    func configureUnmatchedCell(_ content: inout UIListContentConfiguration, cell: UITableViewCell, index: Int) {
        let item = unmatchedCacheItems[index]
        content.text = item.url.absoluteString
        content.secondaryText = cacheDetailText(for: item)
        cell.accessoryType = item.zones.isEmpty ? .none : .disclosureIndicator
    }

    func configureZoneCell(_ content: inout UIListContentConfiguration, title: String, zone: ByteRange?) {
        content.text = title
        content.secondaryText = zone.map(zoneDetailText)
    }

    func makeProgressLabel(for status: Status) -> UILabel {
        let label = UILabel()
        label.text = status.title
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        label.textColor = status.textColor
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.frame.size = CGSize(width: 72, height: 20)
        label.sizeToFit()
        label.frame.size.width = max(label.frame.width, 72)
        return label
    }

    func sampleZone(sampleIndex: Int, zoneIndex: Int) -> ByteRange? {
        let item = mediaItems[sampleIndex]
        return cacheItemsByURL[item.url]?.zones[safe: zoneIndex]
    }

    func makeSampleAccessoryView(for item: MediaItem, index: Int) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 132, height: 32))

        let progressLabel = makeProgressLabel(for: statuses[index])
        progressLabel.frame = CGRect(x: 0, y: 6, width: 72, height: 20)
        container.addSubview(progressLabel)

        let button = UIButton(type: .system)
        button.configuration = preloadButtonConfiguration(for: item)
        button.tag = index
        button.frame = CGRect(x: 80, y: 2, width: 52, height: 28)
        button.addTarget(self, action: #selector(preloadSample(_:)), for: .touchUpInside)
        container.addSubview(button)

        return container
    }

    func preloadButtonConfiguration(for item: MediaItem) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = item.format == .hls ? "30s" : "2MB"
        configuration.buttonSize = .mini
        return configuration
    }
}

// MARK: - 用户操作

private extension CacheViewController {
    func handleSelection(of row: Row) {
        switch row {
        case let .sample(index):
            toggleSampleExpansion(at: index)
        case let .sampleHLSResource(sampleIndex, resourceIndex):
            toggleExpansion(for: relatedHLSCacheItems(for: mediaItems[sampleIndex])[resourceIndex].url)
        case let .unmatched(index):
            toggleExpansion(for: unmatchedCacheItems[index].url)
        case .sampleZone, .sampleHLSResourceSummary, .sampleHLSResourceZone, .unmatchedZone, .emptyUnmatched:
            break
        }
    }

    func toggleSampleExpansion(at index: Int) {
        let item = mediaItems[index]
        guard canExpandSample(item) else {
            return
        }
        toggleExpansion(for: item.url)
    }

    func toggleExpansion(for url: URL) {
        if expandedURLs.contains(url) {
            expandedURLs.remove(url)
        } else {
            expandedURLs.insert(url)
        }
        tableView.reloadData()
    }

    @objc func preloadSample(_ sender: UIButton) {
        startSamplePreload(at: sender.tag)
    }

    @objc func startPreload() {
        startItem.isEnabled = false
        Task {
            for index in mediaItems.indices {
                await preloadItem(at: index, options: .init())
                await refreshCacheSnapshot()
            }
            await MainActor.run {
                startItem.isEnabled = true
            }
        }
    }

    func startSamplePreload(at index: Int) {
        preloadTasks[index]?.cancel()
        preloadTasks[index] = Task { [weak self] in
            guard let self else {
                return
            }
            await self.preloadItem(at: index, options: self.preloadOptions(for: self.mediaItems[index]))
            await self.refreshCacheSnapshot()
            await MainActor.run {
                self.preloadTasks[index] = nil
            }
        }
    }

    func preloadOptions(for item: MediaItem) -> PreloadOptions {
        switch item.format {
        case .hls:
            return PreloadOptions(hlsLimit: .duration(30))
        case .mp3, .aac, .wav, .flac, .ogg, .mp4, .mov:
            return PreloadOptions(fileLimit: .byteCount(2 * 1024 * 1024))
        }
    }

    @objc func deleteAllCaches() {
        Task {
            try? await HTTPMediaCache.deleteAllCaches()
            await MainActor.run {
                expandedURLs.removeAll()
            }
            await refreshCacheSnapshot()
        }
    }

    func deleteCache(for url: URL) {
        Task {
            try? await HTTPMediaCache.deleteCache(for: url)
            await refreshCacheSnapshot()
        }
    }

    func deletableURL(for row: Row) -> URL? {
        switch row {
        case let .sample(index):
            let url = mediaItems[index].url
            return cacheItemsByURL[url] == nil ? nil : url
        case let .sampleHLSResource(sampleIndex, resourceIndex):
            return relatedHLSCacheItems(for: mediaItems[sampleIndex])[resourceIndex].url
        case let .unmatched(index):
            return unmatchedCacheItems[index].url
        case .sampleZone, .sampleHLSResourceSummary, .sampleHLSResourceZone, .unmatchedZone, .emptyUnmatched:
            return nil
        }
    }
}

// MARK: - 缓存状态

private extension CacheViewController {
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
        let itemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let activePreloadStatuses = await MainActor.run {
            preloadTasks.keys.reduce(into: [Int: Status]()) { result, index in
                result[index] = statuses[safe: index]
            }
        }
        var nextStatuses: [Status] = []
        nextStatuses.reserveCapacity(mediaItems.count)
        for index in mediaItems.indices {
            if let activeStatus = activePreloadStatuses[index] {
                nextStatuses.append(activeStatus)
            } else {
                let item = mediaItems[index]
                nextStatuses.append(await status(for: item.url, cacheItem: itemsByURL[item.url]))
            }
        }

        await MainActor.run {
            cacheItemsByURL = itemsByURL
            statuses = nextStatuses
            expandedURLs = expandedURLs.filter { url in
                mediaURLs.contains(url) || itemsByURL[url]?.zones.isEmpty == false
            }
            tableView.reloadData()
        }
    }

    func status(for url: URL, cacheItem: CacheItem?) async -> Status {
        if let error = await HTTPMediaCache.error(for: url) {
            return .failed(error.localizedDescription)
        }

        guard let cacheItem, cacheItem.totalLength > 0 else {
            return .waiting
        }
        if cacheItem.progress >= 1 {
            return .finished
        }
        if cacheItem.progress > 0 {
            return .loading(cacheItem.progress)
        }
        return .waiting
    }

    func preloadItem(at index: Int, options: PreloadOptions) async {
        let item = mediaItems[index]
        updateStatus(.loading(0), at: index)

        do {
            let preloadTask = try await HTTPMediaCache.preload(CacheRequest(url: item.url), options: options)
            for await progress in preloadTask.progress {
                updateStatus(.loading(progress), at: index)
            }
            updateStatus(await finalStatus(for: item.url), at: index)
        } catch {
            updateStatus(.failed(String(describing: error)), at: index)
        }
    }

    func finalStatus(for url: URL) async -> Status {
        if let error = await HTTPMediaCache.error(for: url) {
            return .failed(error.localizedDescription)
        }
        return .finished
    }

    @MainActor
    func updateStatus(_ status: Status, at index: Int) {
        statuses[index] = status
        tableView.reloadData()
    }
}

// MARK: - 文本格式

private extension CacheViewController {
    func sampleDetailText(for item: MediaItem, cacheItem: CacheItem?) -> String {
        let prefix = "\(item.category.title) · \(item.format.title)"
        guard let cacheItem else {
            if item.format == .hls {
                return "\(prefix)\n\(item.url.absoluteString)\n\(hlsResourceSummaryText(for: item))"
            }
            return "\(prefix)\n\(item.url.absoluteString)"
        }

        if item.format == .hls {
            return "\(prefix)\n\(item.url.absoluteString)\nPlaylist: \(cacheDetailText(for: cacheItem))\n\(hlsResourceSummaryText(for: item))"
        }
        return "\(prefix)\n\(item.url.absoluteString)\n\(cacheDetailText(for: cacheItem))"
    }

    func hlsResourceSummaryText(for item: MediaItem) -> String {
        let relatedItems = relatedHLSCacheItems(for: item)
        let relatedLength = relatedItems.reduce(0) { $0 + $1.cachedLength }
        return "Resources: \(relatedItems.count), \(byteCountText(relatedLength))"
    }

    func cacheDetailText(for item: CacheItem) -> String {
        "\(item.cachedLength)/\(item.totalLength) bytes, \(Int(item.progress * 100))%, \(item.zones.count) zones"
    }

    func zoneDetailText(for zone: ByteRange) -> String {
        "Offset: \(zone.start), Length: \(zone.length ?? 0)"
    }

    func relatedHLSCacheItems(for item: MediaItem) -> [CacheItem] {
        guard item.format == .hls else {
            return []
        }
        return cacheItemsByURL.values
            .filter { !mediaURLs.contains($0.url) && isLikelyRelatedHLSResource($0.url, to: item.url) }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    func isHLSResourceCacheURL(_ url: URL) -> Bool {
        mediaItems.contains { item in
            item.format == .hls && isLikelyRelatedHLSResource(url, to: item.url)
        }
    }

    func resourceTitle(for url: URL) -> String {
        let filename = url.lastPathComponent
        return filename.isEmpty ? "HLS Resource" : filename
    }

    func canExpandSample(_ item: MediaItem) -> Bool {
        if item.format == .hls {
            return true
        }
        return cacheItemsByURL[item.url]?.zones.isEmpty == false
    }

    func isLikelyRelatedHLSResource(_ resourceURL: URL, to playlistURL: URL) -> Bool {
        guard resourceURL.host == playlistURL.host else {
            return false
        }
        let parentPath = playlistURL.deletingLastPathComponent().path
        return resourceURL.path.hasPrefix(parentPath)
    }

    func byteCountText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}
