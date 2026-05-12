//
//  NIOProxyServer.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation
import NIO
import NIOHTTP1
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// 基于 SwiftNIO 的本地 HTTP 代理服务。
public actor NIOProxyServer {
    let eventLoopThreadCount: Int
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var codec: ProxyURLCodec?
    private var state = ServerState.stopped
    private var foregroundObserver: ForegroundRestartObserver?

    /// 代理服务是否正在运行。
    public var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    /// 创建本地代理服务。
    public init() {
        self.init(eventLoopThreadCount: Self.defaultEventLoopThreadCount)
    }

    init(eventLoopThreadCount: Int) {
        let resolvedThreadCount = max(1, eventLoopThreadCount)
        self.eventLoopThreadCount = resolvedThreadCount
        group = MultiThreadedEventLoopGroup(numberOfThreads: resolvedThreadCount)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// 启动代理服务。
    public func start(port: UInt16) async throws {
        state = .starting(requestedPort: port)
        if foregroundObserver == nil {
            foregroundObserver = ForegroundRestartObserver { [weak self] in
                Task {
                    await self?.restartAfterForegroundIfNeeded()
                }
            }
        }
        guard channel == nil else {
            state = .running(requestedPort: port)
            return
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPRequestRouter())
                }
            }

        do {
            let bound = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            channel = bound
            let actualPort = bound.localAddress?.port ?? Int(port)
            codec = ProxyURLCodec(port: UInt16(actualPort))
            state = .running(requestedPort: port)
        } catch {
            channel = nil
            codec = nil
            state = .stopped
            throw error
        }
    }

    /// 停止代理服务。
    public func stop() async {
        state = .stopped
        try? await channel?.close().get()
        channel = nil
        codec = nil
    }

    /// 将原始 URL 转成当前代理服务可处理的 URL。
    public func proxyURL(for url: URL, bindToLocalhost: Bool) throws -> URL {
        guard !url.isFileURL, !url.absoluteString.isEmpty else {
            return url
        }
        guard let codec else {
            return url
        }
        return try codec.proxyURL(for: url, bindToLocalhost: bindToLocalhost)
    }

    /// 从代理 URL 还原原始 URL。
    public func originalURL(from proxyURL: URL) -> URL? {
        codec?.originalURL(from: proxyURL)
    }

    private func restartAfterForegroundIfNeeded() async {
        guard case let .running(requestedPort) = state else {
            return
        }

        if await ping() {
            return
        }

        try? await channel?.close().get()
        channel = nil
        codec = nil
        state = .stopped
        try? await start(port: requestedPort)
    }

    private func ping() async -> Bool {
        guard let codec,
              let sourceURL = URL(string: "HTTPMediaCachePing"),
              let pingURL = try? codec.proxyURL(for: sourceURL, bindToLocalhost: true)
        else {
            return false
        }

        var request = URLRequest(url: pingURL)
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return !data.isEmpty
        } catch {
            return false
        }
    }

    private static var defaultEventLoopThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}

private enum ServerState {
    case stopped
    case starting(requestedPort: UInt16)
    case running(requestedPort: UInt16)
}

private final class ForegroundRestartObserver: NSObject, @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init()

        #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleForegroundNotification),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
        #elseif canImport(AppKit)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleForegroundNotification),
                name: NSApplication.willBecomeActiveNotification,
                object: nil
            )
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleForegroundNotification() {
        handler()
    }
}
