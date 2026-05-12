//
//  URLSessionDownloaderBackgroundTaskCoordinator.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

actor URLSessionDownloaderBackgroundTaskCoordinator {
    static let shared = URLSessionDownloaderBackgroundTaskCoordinator()

    private var activeDownloadCount = 0

    #if canImport(UIKit)
        private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    func beginIfNeeded() async {
        activeDownloadCount += 1
        #if canImport(UIKit)
            guard backgroundTask == .invalid
            else {
                return
            }

            let applicationState = await MainActor.run {
                UIApplication.shared.applicationState
            }
            guard applicationState == .background else {
                return
            }

            backgroundTask = await MainActor.run {
                UIApplication.shared.beginBackgroundTask { [weak self] in
                    Task {
                        await self?.endIfNeeded(force: true)
                    }
                }
            }
        #endif
    }

    func endIfNeeded() async {
        await endIfNeeded(force: false)
    }

    func endIfNeededDelayed() async {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        await endIfNeeded(force: false)
    }

    private func endIfNeeded(force: Bool) async {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        #if canImport(UIKit)
            guard backgroundTask != .invalid,
                  force || activeDownloadCount == 0
            else {
                return
            }
            let endedBackgroundTask = backgroundTask
            backgroundTask = .invalid
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(endedBackgroundTask)
            }
        #endif
    }
}
