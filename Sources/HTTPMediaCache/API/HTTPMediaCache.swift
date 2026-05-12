//
//  HTTPMediaCache.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// HTTPMediaCache 的主入口。
public enum HTTPMediaCache {
    /// 启动本地 HTTP 代理服务。
    ///
    /// - Parameter port: 监听端口。传入 0 时由系统自动分配可用端口。
    public static func start(port: UInt16 = 0) async throws {
        let server = await CacheRuntime.shared.server
        try await server.start(port: port)
    }

    /// 停止本地 HTTP 代理服务。
    public static func stop() async {
        let server = await CacheRuntime.shared.server
        await server.stop()
    }

    /// 本地代理服务是否正在运行。
    public static var isRunning: Bool {
        get async {
            let server = await CacheRuntime.shared.server
            return await server.isRunning
        }
    }

    /// 将原始媒体 URL 转换为本地代理 URL。
    ///
    /// - Parameters:
    ///   - url: 原始媒体 URL。
    ///   - bindToLocalhost: 是否使用 `127.0.0.1` 作为代理 host。
    public static func proxyURL(for url: URL, bindToLocalhost: Bool = true) async throws -> URL {
        let server = await CacheRuntime.shared.server
        return try await server.proxyURL(for: url, bindToLocalhost: bindToLocalhost)
    }

    /// 从代理 URL 中还原原始媒体 URL。
    public static func originalURL(from proxyURL: URL) -> URL? {
        ProxyURLCodec(port: UInt16(proxyURL.port ?? 0)).originalURL(from: proxyURL)
    }

    /// 判断 URL 是否为 HTTPMediaCache 生成的代理 URL。
    public static func isProxyURL(_ url: URL) -> Bool {
        ProxyURLCodec(port: UInt16(url.port ?? 0)).isProxyURL(url)
    }

    /// 按指定请求和配置创建预加载任务。
    public static func preload(_ request: CacheRequest, options: PreloadOptions) async throws -> PreloadTask {
        let downloader = await CacheRuntime.shared.downloader
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        let progress = PreloadProgress()
        let taskID = UUID()
        let startGate = PreloadStartGate()
        let task = Task<Void, Error> {
            await startGate.wait()
            var didEnterPreloadQueue = false
            do {
                try await withTaskCancellationHandler {
                    try await PreloadCoordinator.shared.enter(id: taskID)
                    didEnterPreloadQueue = true
                } onCancel: {
                    Task {
                        await PreloadCoordinator.shared.cancel(id: taskID)
                    }
                }
                try await runPreload(
                    request: request,
                    options: options,
                    downloader: downloader,
                    cacheIndex: cacheIndex,
                    progress: progress
                )
                await CacheLogStore.shared.cleanError(for: request.url)
                if didEnterPreloadQueue {
                    await PreloadCoordinator.shared.leave()
                }
            } catch is CancellationError {
                if didEnterPreloadQueue {
                    await PreloadCoordinator.shared.leave()
                }
                await PreloadCoordinator.shared.unregister(id: taskID)
                progress.finish()
                throw CancellationError()
            } catch {
                if didEnterPreloadQueue {
                    await PreloadCoordinator.shared.leave()
                }
                await addError(error, for: request.url)
                await PreloadCoordinator.shared.unregister(id: taskID)
                progress.finish()
                throw error
            }
            await PreloadCoordinator.shared.unregister(id: taskID)
            progress.finish()
        }
        await PreloadCoordinator.shared.register(id: taskID, task: task)
        await startGate.open()

        return PreloadTask(
            request: request,
            progress: progress.stream,
            completionTask: task,
            cancel: {
                Task {
                    await PreloadCoordinator.shared.cancel(id: taskID)
                }
            }
        )
    }

    /// 预加载完整媒体资源。
    public static func preload(_ url: URL) async throws -> PreloadTask {
        try await preload(CacheRequest(url: url), options: .init())
    }

    /// 预加载完整媒体资源。
    public static func prefetch(_ url: URL) async throws -> PreloadTask {
        try await preload(url)
    }

    /// 按字节数预加载媒体资源。
    ///
    /// 文件资源会缓存指定长度的前缀；HLS 资源会按 segment 累计到指定字节数。
    public static func preload(_ url: URL, prefetchSize: Int64) async throws -> PreloadTask {
        guard prefetchSize > 0 else {
            throw CacheError.invalidRange
        }
        return try await preload(
            CacheRequest(url: url),
            options: PreloadOptions(hlsLimit: .byteCount(prefetchSize), fileLimit: .byteCount(prefetchSize))
        )
    }

    /// 按字节数预加载媒体资源。
    public static func prefetch(_ url: URL, prefetchSize: Int64) async throws -> PreloadTask {
        try await preload(url, prefetchSize: prefetchSize)
    }

    /// 按文件数量语义预加载媒体资源。
    ///
    /// HLS 资源会缓存指定数量的 segment；文件资源会缓存完整文件。
    public static func preload(_ url: URL, prefetchFileCount: Int) async throws -> PreloadTask {
        guard prefetchFileCount > 0 else {
            throw CacheError.invalidRange
        }
        return try await preload(
            CacheRequest(url: url),
            options: PreloadOptions(hlsLimit: .segmentCount(prefetchFileCount), fileLimit: .all)
        )
    }

    /// 按文件数量语义预加载媒体资源。
    public static func prefetch(_ url: URL, prefetchFileCount: Int) async throws -> PreloadTask {
        try await preload(url, prefetchFileCount: prefetchFileCount)
    }

    /// 按目标播放时长预加载媒体资源。
    ///
    /// HLS 资源会按 `EXTINF` 累计到目标时长；文件资源会缓存完整文件。
    public static func preload(_ url: URL, preloadDuration: TimeInterval) async throws -> PreloadTask {
        guard preloadDuration > 0 else {
            throw CacheError.invalidRange
        }
        return try await preload(
            CacheRequest(url: url),
            options: PreloadOptions(hlsLimit: .duration(preloadDuration), fileLimit: .all)
        )
    }

    /// 按目标播放时长预加载媒体资源。
    public static func prefetch(_ url: URL, preloadDuration: TimeInterval) async throws -> PreloadTask {
        try await preload(url, preloadDuration: preloadDuration)
    }

    /// 设置预加载队列最大并发数。
    public static func setMaxConcurrentPreloadCount(_ count: Int) async {
        await PreloadCoordinator.shared.setMaxConcurrentTaskCount(count)
    }

    /// 获取预加载队列最大并发数。
    public static func maxConcurrentPreloadCount() async -> Int {
        await PreloadCoordinator.shared.currentMaxConcurrentTaskCount()
    }

    /// 取消所有预加载任务。
    public static func cancelAllPreloadTasks() async {
        await PreloadCoordinator.shared.cancelAll()
    }

    /// 创建普通媒体资源读取器。
    public static func cacheReader(with request: CacheRequest) async -> DataReader {
        let downloader = await CacheRuntime.shared.downloader
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return DataReader(request: request, cacheIndex: cacheIndex, downloader: downloader)
    }

    /// 创建普通媒体资源加载器。
    public static func cacheLoader(with request: CacheRequest) async -> DataLoader {
        await DataLoader(reader: cacheReader(with: request))
    }

    /// 创建 HLS 资源加载器。
    public static func cacheHLSLoader(with request: CacheRequest) async -> DataLoader {
        let downloader = await CacheRuntime.shared.downloader
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return DataLoader(hlsRequest: request, cacheIndex: cacheIndex, downloader: downloader)
    }

    /// 查询指定 URL 的缓存状态。
    public static func cacheItem(for url: URL) async throws -> CacheItem? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return try await cacheIndex.cacheItem(for: url)
    }

    /// 查询所有缓存条目。
    public static func allCacheItems() async throws -> [CacheItem] {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return await cacheIndex.allCacheItems()
    }

    /// 查询当前缓存总字节数。
    public static func totalCacheLength() async throws -> Int64 {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return await cacheIndex.totalCacheLength()
    }

    /// 获取已完整缓存文件的本地路径。
    public static func completeFileURL(for url: URL) async throws -> URL? {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return try await cacheIndex.completeFileURL(for: url)
    }

    /// 删除指定 URL 的缓存。
    public static func deleteCache(for url: URL) async throws {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        await cacheIndex.deleteCache(for: url)
        await CacheLogStore.shared.cleanError(for: url)
    }

    /// 删除全部缓存。
    public static func deleteAllCaches() async throws {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        await cacheIndex.deleteAllCaches()
        await CacheLogStore.shared.cleanErrors()
    }

    /// 设置最大缓存空间，单位为字节。
    public static func setMaxCacheLength(_ maxCacheLength: Int64) async {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        await cacheIndex.setMaxCacheLength(maxCacheLength)
    }

    /// 获取最大缓存空间，单位为字节。
    public static func maxCacheLength() async -> Int64 {
        let cacheIndex = await CacheRuntime.shared.cacheIndex
        return await cacheIndex.currentMaxCacheLength()
    }

    /// 设置下载前的 URL 转换器。
    public static func setURLConverter(_ converter: (@Sendable (URL) -> URL)?) async {
        await CacheRuntime.shared.setURLConverter(converter)
    }

    /// 设置缓存标识提供器。
    ///
    /// 返回值会直接作为缓存 identity 参与 key 计算；设置后优先级高于 URL 转换器。
    public static func setCacheIdentifierProvider(_ provider: (@Sendable (URL) -> String)?) async {
        await CacheRuntime.shared.setCacheIdentifierProvider(provider)
    }

    /// 注入测试用缓存目录和下载器。
    public static func configureForTests(storageRoot: URL, downloader: any CacheDownloading) async {
        await CacheRuntime.shared.configureForTests(storageRoot: storageRoot, downloader: downloader)
    }

    /// 设置 HLS playlist 内容返回给播放器前的处理器。
    public static func setHLSContentHandler(_ handler: (@Sendable (String) -> String)?) async {
        await CacheRuntime.shared.setHLSContentHandler(handler)
    }

    /// 设置 HLS variant stream 选择器。
    public static func setHLSVariantStreamSelectionHandler(_ handler: HLSVariantStreamSelectionHandler?) async {
        await CacheRuntime.shared.setHLSVariantStreamSelectionHandler(handler)
    }

    /// 设置 HLS rendition 选择器。
    public static func setHLSRenditionSelectionHandler(_ handler: HLSRenditionSelectionHandler?) async {
        await CacheRuntime.shared.setHLSRenditionSelectionHandler(handler)
    }

    /// 设置 HLS 下载请求头提供器。
    ///
    /// Provider 返回的请求头只用于 HLS playlist、key、init map 和 segment 回源下载；播放器请求头仍按 HLS 下载策略清洗。
    /// 返回的 `Range` 会被忽略，init map 和 byte-range segment 的 Range 仍由 playlist 中的 `BYTERANGE` 决定。
    public static func setHLSDownloadHeaderProvider(_ provider: HLSDownloadHeaderProvider?) async {
        await CacheRuntime.shared.setHLSDownloadHeaderProvider(provider)
    }

    /// 设置下载超时时间。
    public static func setDownloadTimeoutInterval(_ timeoutInterval: TimeInterval) async {
        await URLSessionDownloaderSettings.shared.setTimeoutInterval(timeoutInterval)
    }

    /// 获取下载超时时间。
    public static func downloadTimeoutInterval() async -> TimeInterval {
        await URLSessionDownloaderSettings.shared.snapshot().timeoutInterval
    }

    /// 设置允许从播放请求透传到下载请求的请求头 key。
    public static func setDownloadWhitelistHeaderKeys(_ whitelistHeaderKeys: [String]) async {
        await URLSessionDownloaderSettings.shared.setWhitelistHeaderKeys(whitelistHeaderKeys)
    }

    /// 获取允许透传的请求头 key。
    public static func downloadWhitelistHeaderKeys() async -> [String] {
        await URLSessionDownloaderSettings.shared.snapshot().whitelistHeaderKeys
    }

    /// 设置下载请求追加的固定请求头。
    public static func setDownloadAdditionalHeaders(_ additionalHeaders: [String: String]) async {
        await URLSessionDownloaderSettings.shared.setAdditionalHeaders(additionalHeaders)
    }

    /// 获取下载请求追加的固定请求头。
    public static func downloadAdditionalHeaders() async -> [String: String] {
        await URLSessionDownloaderSettings.shared.snapshot().additionalHeaders
    }

    /// 设置可接受的响应内容类型前缀。
    public static func setDownloadAcceptableContentTypes(_ acceptableContentTypes: [String]?) async {
        await URLSessionDownloaderSettings.shared.setAcceptableContentTypes(acceptableContentTypes)
    }

    /// 获取可接受的响应内容类型前缀。
    public static func downloadAcceptableContentTypes() async -> [String]? {
        await URLSessionDownloaderSettings.shared.snapshot().acceptableContentTypes
    }

    /// 设置不可接受响应内容类型的处置回调。
    public static func setDownloadUnacceptableContentTypeDisposer(_ disposer: (@Sendable (URL, String) -> Bool)?) async {
        await URLSessionDownloaderSettings.shared.setUnacceptableContentTypeDisposer(disposer)
    }

    /// 设置 URLSession 下载指标回调。
    public static func setDownloadMetricsHandler(_ handler: (@Sendable (URL, URLSessionTaskMetrics) -> Void)?) async {
        await URLSessionDownloaderSettings.shared.setMetricsHandler(handler)
    }

    /// 设置下载请求 Range 长度提供器。
    public static func setDownloadRequestHeaderRangeLength(_ provider: (@Sendable (URL, Int64) -> Int64)?) async {
        await CacheRuntime.shared.setRequestHeaderRangeLength(provider)
    }

    /// 写入一条业务日志。
    public static func addLog(_ log: String) async {
        await CacheLogStore.shared.addLog(log)
    }

    /// 设置是否输出控制台日志。
    public static func setConsoleLogEnable(_ consoleLogEnable: Bool) async {
        await CacheLogStore.shared.setConsoleLogEnable(consoleLogEnable)
    }

    /// 查询是否输出控制台日志。
    public static func consoleLogEnable() async -> Bool {
        await CacheLogStore.shared.isConsoleLogEnabled()
    }

    /// 设置是否记录日志文件。
    public static func setRecordLogEnable(_ recordLogEnable: Bool) async {
        await CacheLogStore.shared.setRecordLogEnable(recordLogEnable)
    }

    /// 查询是否记录日志文件。
    public static func recordLogEnable() async -> Bool {
        await CacheLogStore.shared.isRecordLogEnabled()
    }

    /// 获取当前日志文件路径；没有日志内容时返回 nil。
    public static func recordLogFileURL() async -> URL? {
        await CacheLogStore.shared.currentRecordLogFileURL()
    }

    /// 删除日志文件。
    public static func deleteRecordLogFile() async {
        await CacheLogStore.shared.deleteRecordLogFile()
    }

    /// 获取全部按 URL 记录的错误。
    public static func errors() async -> [URL: NSError] {
        await CacheLogStore.shared.allErrors()
    }

    /// 清理指定 URL 的错误记录。
    public static func cleanError(for url: URL) async {
        await CacheLogStore.shared.cleanError(for: url)
    }

    /// 清理全部错误记录。
    public static func cleanErrors() async {
        await CacheLogStore.shared.cleanErrors()
    }

    /// 获取指定 URL 的错误记录。
    public static func error(for url: URL) async -> NSError? {
        await CacheLogStore.shared.error(for: url)
    }

    static func addError(_ error: Error, for url: URL) async {
        await CacheLogStore.shared.addError(error, for: url)
    }

    private static func runPreload(
        request: CacheRequest,
        options: PreloadOptions,
        downloader: any CacheDownloading,
        cacheIndex: CacheIndex,
        progress: PreloadProgress
    ) async throws {
        if isHLSURL(request.url) {
            try await HLSPreloadExecutor(
                request: request,
                options: options,
                downloader: downloader,
                cacheIndex: cacheIndex,
                progress: progress
            ).run()
            return
        }

        try await FilePreloadExecutor(
            request: request,
            limit: options.fileLimit,
            downloader: downloader,
            cacheIndex: cacheIndex,
            progress: progress
        ).run()
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        url.absoluteString.range(of: ".m3u", options: [.caseInsensitive]) != nil
    }
}

extension [String: String] {
    func removingRangeHeader() -> [String: String] {
        filter { key, _ in
            key.caseInsensitiveCompare("Range") != .orderedSame
        }
    }

    var contentLength: Int64? {
        headerValue(for: "Content-Length").flatMap(Int64.init)
    }

    var contentRangeTotalLength: Int64? {
        guard let contentRange = headerValue(for: "Content-Range"),
              let total = contentRange.split(separator: "/").last,
              total != "*"
        else {
            return nil
        }
        return Int64(total)
    }

    var contentRangeStart: Int64? {
        guard let contentRange = headerValue(for: "Content-Range") else {
            return nil
        }
        let rangeText = contentRange
            .replacingOccurrences(of: "bytes ", with: "")
            .split(separator: "/")
            .first?
            .split(separator: "-")
            .first
        return rangeText.flatMap { Int64($0) }
    }

    func headerValue(for name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
