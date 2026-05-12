//
//  PreloadCoordinator.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/11.
//

import Foundation

actor PreloadCoordinator {
    static let shared = PreloadCoordinator()

    private var maxConcurrentTaskCount = 1
    private var runningTaskCount = 0
    private var waitingContinuations: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var tasks: [UUID: Task<Void, Error>] = [:]

    func register(id: UUID, task: Task<Void, Error>) {
        tasks[id] = task
    }

    func unregister(id: UUID) {
        tasks[id] = nil
        removeWaitingTask(id: id)?.resume(throwing: CancellationError())
    }

    func enter(id: UUID) async throws {
        try Task.checkCancellation()
        if runningTaskCount < maxConcurrentTaskCount {
            runningTaskCount += 1
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            waitingContinuations.append((id, continuation))
        }
        try Task.checkCancellation()
    }

    func leave() {
        runningTaskCount = max(runningTaskCount - 1, 0)
        resumeWaitingTasksIfNeeded()
    }

    func cancel(id: UUID) {
        tasks[id]?.cancel()
        removeWaitingTask(id: id)?.resume(throwing: CancellationError())
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        let continuations = waitingContinuations.map(\.1)
        waitingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setMaxConcurrentTaskCount(_ count: Int) {
        maxConcurrentTaskCount = max(count, 1)
        resumeWaitingTasksIfNeeded()
    }

    func currentMaxConcurrentTaskCount() -> Int {
        maxConcurrentTaskCount
    }

    func resetForTests() {
        cancelAll()
        maxConcurrentTaskCount = 1
        runningTaskCount = 0
        tasks.removeAll()
    }

    private func resumeWaitingTasksIfNeeded() {
        while runningTaskCount < maxConcurrentTaskCount, !waitingContinuations.isEmpty {
            let (_, continuation) = waitingContinuations.removeFirst()
            runningTaskCount += 1
            continuation.resume()
        }
    }

    private func removeWaitingTask(id: UUID) -> CheckedContinuation<Void, Error>? {
        guard let index = waitingContinuations.firstIndex(where: { $0.0 == id }) else {
            return nil
        }
        return waitingContinuations.remove(at: index).1
    }
}
