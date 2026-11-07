import Darwin
import Foundation
import OSLog

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let fileManager = FileManager.default
    private let logDirectory = AppLogger.userHomeDirectory
        .appendingPathComponent("Library/Logs/SlimKit", isDirectory: true)
    private let logFileName = "SlimKit.log"
    private let maxFileSize = 1_048_576
    private let retainedFileCount = 5
    private let logger = Logger(subsystem: "com.slimkit.app", category: "application")
    private let queue = DispatchQueue(label: "com.slimkit.app.file-logger")
    private var fileHandle: FileHandle?

    private static var userHomeDirectory: URL {
        guard let userRecord = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let homePath = String(cString: userRecord.pointee.pw_dir)
        return URL(fileURLWithPath: homePath, isDirectory: true)
    }

    private init() {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let activeLog = activeLogURL
            if !fileManager.fileExists(atPath: activeLog.path) {
                fileManager.createFile(atPath: activeLog.path, contents: nil)
            }
            fileHandle = try FileHandle(forWritingTo: activeLog)
            try fileHandle?.seekToEnd()
            info("Logging", "File logging initialized; directory=\(logDirectory.path)")
        } catch {
            logger.error("File logging unavailable at requested path: \(error.localizedDescription, privacy: .public)")
        }
    }

    func debug(_ category: String, _ message: String) {
        write(.debug, category, message)
    }

    func info(_ category: String, _ message: String) {
        write(.info, category, message)
    }

    func warning(_ category: String, _ message: String) {
        write(.default, category, message)
    }

    func error(_ category: String, _ message: String) {
        write(.error, category, message)
    }

    private var activeLogURL: URL {
        logDirectory.appendingPathComponent(logFileName)
    }

    private func write(_ level: OSLogType, _ category: String, _ message: String) {
        let cleanMessage = message.replacingOccurrences(of: "\n", with: " ")
        let entry = "\(Date().ISO8601Format()) [\(levelName(level))] [\(category)] \(cleanMessage)"
        logger.log(level: level, "\(entry, privacy: .public)")
        let data = Data((entry + "\n").utf8)
        queue.async { [weak self] in
            self?.append(data)
        }
    }

    private func append(_ data: Data) {
        guard let fileHandle else { return }
        do {
            let currentSize = try fileHandle.seekToEnd()
            if currentSize + UInt64(data.count) > UInt64(maxFileSize) {
                try fileHandle.close()
                self.fileHandle = nil
                try rotateLogs()
                if !fileManager.createFile(atPath: activeLogURL.path, contents: nil) {
                    throw CocoaError(.fileWriteUnknown)
                }
                self.fileHandle = try FileHandle(forWritingTo: activeLogURL)
            }
            try self.fileHandle?.write(contentsOf: data)
        } catch {
            logger.error("Failed writing log file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateLogs() throws {
        let oldestLog = rotatedLogURL(retainedFileCount)
        if fileManager.fileExists(atPath: oldestLog.path) {
            try fileManager.removeItem(at: oldestLog)
        }
        if retainedFileCount > 1 {
            for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
                let source = rotatedLogURL(index)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: rotatedLogURL(index + 1))
                }
            }
        }
        if fileManager.fileExists(atPath: activeLogURL.path) {
            try fileManager.moveItem(at: activeLogURL, to: rotatedLogURL(1))
        }
    }

    private func rotatedLogURL(_ index: Int) -> URL {
        logDirectory.appendingPathComponent("SlimKit.\(index).log")
    }

    private func levelName(_ level: OSLogType) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .default: "WARNING"
        case .error: "ERROR"
        case .fault: "FAULT"
        default: "LOG"
        }
    }
}
