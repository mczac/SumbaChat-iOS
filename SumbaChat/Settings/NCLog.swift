//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

@objcMembers public class NCLog: NSObject {

    /// How long daily `debug-yyyy-MM-dd.log` files are retained before automatic cleanup.
    public static let retentionDays = 10

    private static let backgroundLogQueue = DispatchQueue(label: "\(bundleIdentifier).backgroundLogQueue", qos: .background)

    /// `CFBundleVersion` (build) — cached so every line can tag the binary that wrote it.
    private static let buildNumber: String = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "?"
    }()

    private static let logLineDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Trailing Z marks UTC for server-log reconciliation.
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"

        return dateFormatter
    }()

    private static let fileNameDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return dateFormatter
    }()

    private static var logfilePath: URL? = {
        let fileManager = FileManager.default
        let logDir: URL

        if let groupContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            logDir = groupContainer.appendingPathComponent("logs")
        } else if let documentDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            logDir = documentDir.appendingPathComponent("logs")
        } else {
            return nil
        }

        let logPath = logDir.path

        // Allow writing to files while the app is in the background
        if !fileManager.fileExists(atPath: logPath) {
            try? fileManager.createDirectory(atPath: logPath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        }

        return logDir
    }()

    public static func log(_ message: String) {
        guard let logfilePath else { return }

        // Determine the queue here, as otherwise it will be always the backgroundQueue
        let currentQueueName = Thread.current.queueName

        backgroundLogQueue.async {
            appendLogLine(message, queueName: currentQueueName, logfilePath: logfilePath)
        }
    }

    /// Writes immediately — use on jetsam-prone paths where async `log` may never flush.
    @objc public static func logSync(_ message: String) {
        guard let logfilePath else {
            NSLog("%@", message)
            return
        }
        let currentQueueName = Thread.current.queueName
        // Serialize with the async logger so lines stay ordered.
        backgroundLogQueue.sync {
            appendLogLine(message, queueName: currentQueueName, logfilePath: logfilePath)
        }
    }

    private static func appendLogLine(_ message: String, queueName: String, logfilePath: URL) {
        do {
            let now = Date()

            var logMessage = "\(logLineDateFormatter.string(from: now)) "
            logMessage += "[b\(buildNumber)] (\(queueName)): \(message)\n"

            let dateString = fileNameDateFormatter.string(from: now)
            let logFileName = "debug-\(dateString).log"
            let fullPath = logfilePath.appendingPathComponent(logFileName).path

            if let fileHandle = FileHandle(forWritingAtPath: fullPath) {
                fileHandle.seekToEndOfFile()
                // UTF-8 will never be nil
                try fileHandle.write(contentsOf: logMessage.data(using: .utf8)!)
                try fileHandle.close()
            } else {
                try logMessage.write(toFile: fullPath, atomically: false, encoding: .utf8)
            }

            NSLog("%@", logMessage)
        } catch {
            NSLog("Exception in NCLog.log: %@", error.localizedDescription)
            NSLog("Message: %@", message)
        }
    }

    public static func getLogfiles() -> [URL] {
        removeOldLogfiles()

        guard let logfilePath else { return [] }

        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(at: logfilePath, includingPropertiesForKeys: nil)
        else { return [] }

        // Sort descending by file name so the most recent logfile is listed first
        return files
            .filter { $0.lastPathComponent.hasPrefix("debug-") && $0.lastPathComponent.hasSuffix(".log") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes every `debug-*.log` file immediately.
    public static func clearAllLogfiles() {
        guard let logfilePath else { return }

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: logfilePath, includingPropertiesForKeys: nil)
        else { return }

        for file in files where file.lastPathComponent.hasPrefix("debug-") && file.lastPathComponent.hasSuffix(".log") {
            NSLog("Clearing logfile %@", file.path)
            try? fileManager.removeItem(at: file)
        }
    }

    /// Keeps only the last `retentionDays` of daily log files (by date in the filename).
    public static func removeOldLogfiles() {
        guard let logfilePath else { return }

        let fileManager = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let todayStart = utcCalendar.startOfDay(for: Date())
        guard let thresholdDate = utcCalendar.date(byAdding: .day, value: -(retentionDays - 1), to: todayStart)
        else { return }

        guard let files = try? fileManager.contentsOfDirectory(at: logfilePath, includingPropertiesForKeys: nil)
        else { return }

        for fileURL in files {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("debug-"), name.hasSuffix(".log") else { continue }

            let fileDate: Date?
            if let parsed = fileNameDateFormatter.date(from: String(name.dropFirst("debug-".count).dropLast(".log".count))) {
                fileDate = utcCalendar.startOfDay(for: parsed)
            } else if let creationDate = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.creationDate] as? Date {
                fileDate = utcCalendar.startOfDay(for: creationDate)
            } else {
                fileDate = nil
            }

            guard let fileDate, fileDate < thresholdDate else { continue }

            NSLog("Deleting old logfile %@", fileURL.path)
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
