//
//  CacheLogger.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import Foundation

/// 日志级别。
public enum CacheLogLevel: Sendable {
    /// 调试信息。
    case debug
    /// 普通运行信息。
    case info
    /// 警告信息。
    case warning
    /// 错误信息。
    case error
}

/// 自定义日志输出接口。
public protocol CacheLogger: Sendable {
    /// 输出一条日志。
    func log(_ level: CacheLogLevel, _ message: @autoclosure @Sendable () -> String)
}

actor CacheLogStore {
    static let shared = CacheLogStore()

    private var consoleLogEnable = false
    private var recordLogEnable = false
    private var writingHandle: FileHandle?
    private var errors: [URL: NSError] = [:]
    private let recordLogFileURL: URL

    init(recordLogFileURL: URL = CacheLogStore.defaultRecordLogFileURL) {
        self.recordLogFileURL = recordLogFileURL
    }

    func addLog(_ log: String) {
        guard !log.isEmpty else {
            return
        }

        if consoleLogEnable {
            print(log)
        }

        guard recordLogEnable else {
            return
        }

        let line = "\(Date()) \(log)\n"
        if writingHandle == nil {
            try? FileManager.default.createDirectory(
                at: recordLogFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: recordLogFileURL)
            FileManager.default.createFile(atPath: recordLogFileURL.path, contents: nil)
            writingHandle = try? FileHandle(forWritingTo: recordLogFileURL)
        }
        try? writingHandle?.write(contentsOf: Data(line.utf8))
    }

    func setConsoleLogEnable(_ consoleLogEnable: Bool) {
        self.consoleLogEnable = consoleLogEnable
    }

    func isConsoleLogEnabled() -> Bool {
        consoleLogEnable
    }

    func setRecordLogEnable(_ recordLogEnable: Bool) {
        self.recordLogEnable = recordLogEnable
    }

    func isRecordLogEnabled() -> Bool {
        recordLogEnable
    }

    func currentRecordLogFileURL() -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: recordLogFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0
        else {
            return nil
        }
        return recordLogFileURL
    }

    func deleteRecordLogFile() {
        try? writingHandle?.synchronize()
        try? writingHandle?.close()
        writingHandle = nil
    }

    func addError(_ error: Error, for url: URL) {
        errors[url] = error as NSError
    }

    func allErrors() -> [URL: NSError] {
        errors
    }

    func cleanError(for url: URL) {
        errors[url] = nil
    }

    func cleanErrors() {
        errors.removeAll()
    }

    func error(for url: URL) -> NSError? {
        errors[url]
    }

    private static var defaultRecordLogFileURL: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("HTTPMediaCache", isDirectory: true)
            .appendingPathComponent("HTTPMediaCache.log")
    }
}
