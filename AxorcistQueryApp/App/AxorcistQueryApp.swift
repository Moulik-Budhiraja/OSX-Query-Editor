import SwiftUI

@main
struct AxorcistQueryApp: App {
    init() {
        TemporaryTelemetry.shared.install()
        TemporaryTelemetry.shared.log(
            category: "lifecycle",
            message: "app_init",
            metadata: ["telemetry_path": TemporaryTelemetry.shared.logFilePath])
    }

    var body: some Scene {
        WindowGroup {
            WorkbenchView()
                .frame(minWidth: 1120, minHeight: 760)
        }
    }
}

private func axorcistUncaughtExceptionHandler(_ exception: NSException) {
    TemporaryTelemetry.shared.recordUncaughtException(exception)
}

final class TemporaryTelemetry: @unchecked Sendable {
    static let shared = TemporaryTelemetry()

    private let lock = NSLock()
    private let dateFormatter = ISO8601DateFormatter()
    private let fileURL: URL
    private let maxFileSizeBytes = 4_000_000
    private var hasInstalledExceptionHandler = false

    private init() {
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fileURL = Self.makeTelemetryFileURL()
        self.prepareLogFileIfNeeded()
        self.log(
            category: "lifecycle",
            message: "session_start",
            metadata: ["pid": String(ProcessInfo.processInfo.processIdentifier)])
    }

    var logFilePath: String {
        self.fileURL.path
    }

    func install() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.hasInstalledExceptionHandler else { return }
        NSSetUncaughtExceptionHandler(axorcistUncaughtExceptionHandler)
        self.hasInstalledExceptionHandler = true
        self.writeLine(self.formattedLine(
            category: "lifecycle",
            message: "installed_uncaught_exception_handler",
            metadata: [:]))
    }

    func recordUncaughtException(_ exception: NSException) {
        self.log(
            category: "crash",
            message: "uncaught_ns_exception",
            metadata: [
                "name": exception.name.rawValue,
                "reason": exception.reason ?? "nil",
                "stack": exception.callStackSymbols.joined(separator: " | "),
            ])
    }

    func log(category: String, message: String, metadata: [String: String] = [:]) {
        let line = self.formattedLine(category: category, message: message, metadata: metadata)
        self.lock.lock()
        defer { self.lock.unlock() }
        self.writeLine(line)
    }

    private func formattedLine(category: String, message: String, metadata: [String: String]) -> String {
        let timestamp = self.dateFormatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "background"
        let metadataString = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in
                let sanitized = value.replacingOccurrences(of: "\n", with: "\\n")
                return "\(key)=\(sanitized)"
            }
            .joined(separator: " ")

        if metadataString.isEmpty {
            return "\(timestamp) [\(thread)] [\(category)] \(message)"
        }
        return "\(timestamp) [\(thread)] [\(category)] \(message) \(metadataString)"
    }

    private func writeLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: self.fileURL) else { return }
        defer {
            try? handle.close()
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Avoid recursive logging while telemetry writes fail.
        }
    }

    private static func makeTelemetryFileURL() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let logsDirectory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AxorcistQueryApp", isDirectory: true)
        return logsDirectory.appendingPathComponent("temporary-telemetry.log", isDirectory: false)
    }

    private func prepareLogFileIfNeeded() {
        let directory = self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if
            let attributes = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue > self.maxFileSizeBytes
        {
            try? FileManager.default.removeItem(at: self.fileURL)
        }

        if !FileManager.default.fileExists(atPath: self.fileURL.path) {
            _ = FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
        }
    }
}
