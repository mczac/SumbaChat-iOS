//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Structured media-upload diagnostics. Grep logs for `MediaUploadTrace:`.
@objcMembers public final class MediaUploadTrace: NSObject {

    private static let prefix = "MediaUploadTrace:"

    @objc public static func log(_ message: String) {
        NCLog.log("\(prefix) \(message)")
    }

    @objc public static func logSync(_ message: String) {
        NCLog.logSync("\(prefix) \(message)")
    }

    @objc(modeName:)
    public static func modeName(_ mode: MediaUploadMode) -> String {
        switch mode {
        case .noCompression: return "none"
        case .automatic: return "automatic"
        case .chooseOnUpload: return "manual"
        @unknown default: return "unknown"
        }
    }

    /// Low = high quality / mild; High = low quality / aggressive.
    @objc(levelName:)
    public static func levelName(_ level: MediaUploadCompressionLevel) -> String {
        switch level {
        case .none: return "none(original)"
        case .low: return "low(high-quality)"
        case .medium: return "medium"
        case .high: return "high(low-quality)"
        @unknown default: return "level(\(level.rawValue))"
        }
    }

    @objc(mb:)
    public static func mb(_ bytes: Int64) -> String {
        String(format: "%.2fMB", Double(max(0, bytes)) / 1_048_576.0)
    }

    @objc(mbUInt:)
    public static func mbUInt(_ bytes: UInt64) -> String {
        mb(Int64(bytes))
    }

    /// One-line Active compression settings for Send / prepare headers.
    @objc public static func settingsSnapshot() -> String {
        MediaUploadDebugSettings.shared().summaryForLog
    }
}
