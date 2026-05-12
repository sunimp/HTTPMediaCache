//
//  HomeViewController.swift
//  HTTPMediaCacheiOSExample
//
//  Created by Sun on 2026/5/9.
//

import HTTPMediaCache
import UIKit

final class HomeViewController: UIViewController {
    private enum ToolRow: Int, CaseIterable {
        case cacheProxy
        case airPlayProxy
        case cache
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let mediaItems = MediaItem.samples
    private let mediaCategories = MediaItem.Category.allCases
    private var metricsSnapshot = DownloadMetricsSnapshot.empty
    private var proxyStatus = "Starting proxy..."
    private var isCacheEnabled = true
    private var usesAirPlayProxy = false
    private var metricsObserver: NSObjectProtocol?

    deinit {
        if let metricsObserver {
            NotificationCenter.default.removeObserver(metricsObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Example"
        view.backgroundColor = .systemBackground
        configureTableView()
        configureMetricsObservation()
        startProxy()
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startProxy() {
        guard isCacheEnabled else {
            proxyStatus = "Cache disabled"
            tableView.reloadSections(IndexSet(integer: toolsSection), with: .automatic)
            return
        }

        Task {
            do {
                await configureDownloadMetricsHandler()
                try await HTTPMediaCache.start(port: 0)
                guard isCacheEnabled else {
                    await HTTPMediaCache.stop()
                    await MainActor.run {
                        proxyStatus = "Cache disabled"
                        tableView.reloadSections(IndexSet(integer: toolsSection), with: .automatic)
                    }
                    return
                }
                proxyStatus = "Proxy started"
            } catch {
                proxyStatus = "Proxy failed: \(error)"
            }
            await MainActor.run {
                tableView.reloadSections(IndexSet(integer: toolsSection), with: .automatic)
            }
        }
    }

    private func stopProxy() {
        Task {
            await HTTPMediaCache.stop()
            await MainActor.run {
                proxyStatus = "Cache disabled"
                tableView.reloadSections(IndexSet(integer: toolsSection), with: .automatic)
            }
        }
    }

    private func configureDownloadMetricsHandler() async {
        await HTTPMediaCache.setDownloadMetricsHandler { url, metrics in
            Task {
                await DownloadMetricsStore.shared.record(url: url, metrics: metrics)
            }
        }
        await refreshMetricsSnapshot()
    }

    private func configureMetricsObservation() {
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

    private func refreshMetricsSnapshot() async {
        let snapshot = await DownloadMetricsStore.shared.snapshot()
        await MainActor.run {
            metricsSnapshot = snapshot
            tableView.reloadSections(IndexSet(integer: metricsSection), with: .automatic)
        }
    }

    private func play(_ item: MediaItem) {
        Task {
            do {
                let playbackURL = try await playbackURL(for: item)
                await MainActor.run {
                    present(PlayerViewController(url: playbackURL), animated: true)
                }
            } catch {
                await MainActor.run {
                    showError(error)
                }
            }
        }
    }

    private func playbackURL(for item: MediaItem) async throws -> URL {
        guard isCacheEnabled else {
            return item.url
        }
        return try await HTTPMediaCache.proxyURL(for: item.url, bindToLocalhost: !usesAirPlayProxy)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: String(describing: error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private var toolsSection: Int {
        mediaCategories.count
    }

    private var metricsSection: Int {
        mediaCategories.count + 1
    }

    private func category(for section: Int) -> MediaItem.Category? {
        mediaCategories.indices.contains(section) ? mediaCategories[section] : nil
    }

    private func items(in category: MediaItem.Category) -> [MediaItem] {
        mediaItems.filter { $0.category == category }
    }

    @objc private func cacheProxySwitchChanged(_ sender: UISwitch) {
        isCacheEnabled = sender.isOn
        if isCacheEnabled {
            proxyStatus = "Starting proxy..."
            tableView.reloadSections(IndexSet(integer: toolsSection), with: .automatic)
            startProxy()
        } else {
            stopProxy()
        }
    }

    @objc private func airPlayProxySwitchChanged(_ sender: UISwitch) {
        usesAirPlayProxy = sender.isOn
    }
}

extension HomeViewController: UITableViewDataSource {
    func numberOfSections(in _: UITableView) -> Int {
        mediaCategories.count + 2
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let category = category(for: section) {
            return items(in: category).count
        }
        if section == metricsSection {
            return max(metricsSnapshot.records.count, 1)
        }
        return ToolRow.allCases.count
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        if let category = category(for: section) {
            return category.title
        }
        if section == toolsSection {
            return proxyStatus
        }
        if section == metricsSection {
            return "Download Metrics · \(metricsSnapshot.summaryText)"
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.accessoryView = nil

        if let category = category(for: indexPath.section) {
            let item = items(in: category)[indexPath.row]
            content.text = item.title
            content.secondaryText = "\(item.format.title) · \(item.url.absoluteString)"
            cell.accessoryType = .disclosureIndicator
        } else if indexPath.section == metricsSection {
            if metricsSnapshot.records.isEmpty {
                content.text = "No Metrics"
                content.secondaryText = "Play or preload media to collect URLSession metrics."
            } else {
                let record = metricsSnapshot.records[indexPath.row]
                content.text = record.hostText
                content.secondaryText = "\(record.detailText) · \(record.url.lastPathComponent)"
            }
        } else if let row = ToolRow(rawValue: indexPath.row) {
            switch row {
            case .cacheProxy:
                content.text = "Cache Proxy"
                content.secondaryText = isCacheEnabled ? "Playback uses HTTPMediaCache proxy" : "Playback uses original URLs"
                let cacheSwitch = UISwitch()
                cacheSwitch.isOn = isCacheEnabled
                cacheSwitch.addTarget(self, action: #selector(cacheProxySwitchChanged), for: .valueChanged)
                cell.accessoryView = cacheSwitch
            case .airPlayProxy:
                content.text = "AirPlay Proxy"
                if isCacheEnabled {
                    content.secondaryText = usesAirPlayProxy ? "Remote AirPlay access enabled" : "Localhost only"
                } else {
                    content.secondaryText = "Disabled while cache proxy is off"
                }
                let proxySwitch = UISwitch()
                proxySwitch.isOn = usesAirPlayProxy
                proxySwitch.isEnabled = isCacheEnabled
                proxySwitch.addTarget(self, action: #selector(airPlayProxySwitchChanged), for: .valueChanged)
                cell.accessoryView = proxySwitch
            case .cache:
                content.text = "Cache"
                content.secondaryText = isCacheEnabled ? nil : "Enable cache proxy to inspect or preload cache"
                cell.accessoryType = isCacheEnabled ? .disclosureIndicator : .none
            }
        }

        cell.contentConfiguration = content
        return cell
    }
}

extension HomeViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if let category = category(for: indexPath.section) {
            play(items(in: category)[indexPath.row])
        } else if ToolRow(rawValue: indexPath.row) == .cache {
            guard isCacheEnabled else {
                return
            }
            navigationController?.pushViewController(CacheViewController(mediaItems: mediaItems), animated: true)
        }
    }
}
