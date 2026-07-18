//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Video encode backend for Build 9 debug.
@objc public enum MediaUploadVideoEngine: Int {
    case assetWriter = 0
    case exportSession = 1
}

/// Tunable Low / Medium / High profile (Debug settings + App Group).
@objcMembers public final class MediaUploadProfileConfig: NSObject, Codable {
    public var imageMaxDimension: Int
    public var imageJPEGQuality: Int
    /// Target total media bitrate for Writer, in **megabits per second** (Mbps).
    public var videoRateMbps: Double
    public var videoMaxBytes: Int64
    public var videoMaxEdge: Int
    public var videoFPS: Double
    /// ExportSession preset key: low, medium, high, 480p, 540p, 720p, 1080p, 2160p.
    public var exportPreset: String

    private enum CodingKeys: String, CodingKey {
        case imageMaxDimension
        case imageJPEGQuality
        case videoRateMbps
        /// Legacy megabytes/second — migrated × 8 → Mbps on decode.
        case videoRateMBps
        case videoMaxBytes
        case videoMaxEdge
        case videoFPS
        case exportPreset
    }

    public init(imageMaxDimension: Int,
                imageJPEGQuality: Int,
                videoRateMbps: Double,
                videoMaxBytes: Int64,
                videoMaxEdge: Int,
                videoFPS: Double,
                exportPreset: String) {
        self.imageMaxDimension = imageMaxDimension
        self.imageJPEGQuality = imageJPEGQuality
        self.videoRateMbps = videoRateMbps
        self.videoMaxBytes = videoMaxBytes
        self.videoMaxEdge = videoMaxEdge
        self.videoFPS = videoFPS
        self.exportPreset = exportPreset
    }

    public required convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let imageMaxDimension = try c.decode(Int.self, forKey: .imageMaxDimension)
        let imageJPEGQuality = try c.decode(Int.self, forKey: .imageJPEGQuality)
        let videoRateMbps: Double
        if let modern = try c.decodeIfPresent(Double.self, forKey: .videoRateMbps) {
            videoRateMbps = modern
        } else if let legacyMBps = try c.decodeIfPresent(Double.self, forKey: .videoRateMBps) {
            videoRateMbps = legacyMBps * 8.0
        } else {
            videoRateMbps = 3.2
        }
        let videoMaxBytes = try c.decode(Int64.self, forKey: .videoMaxBytes)
        let videoMaxEdge = try c.decode(Int.self, forKey: .videoMaxEdge)
        let videoFPS = try c.decode(Double.self, forKey: .videoFPS)
        let exportPreset = try c.decode(String.self, forKey: .exportPreset)
        self.init(imageMaxDimension: imageMaxDimension,
                  imageJPEGQuality: imageJPEGQuality,
                  videoRateMbps: videoRateMbps,
                  videoMaxBytes: videoMaxBytes,
                  videoMaxEdge: videoMaxEdge,
                  videoFPS: videoFPS,
                  exportPreset: exportPreset)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(imageMaxDimension, forKey: .imageMaxDimension)
        try c.encode(imageJPEGQuality, forKey: .imageJPEGQuality)
        try c.encode(videoRateMbps, forKey: .videoRateMbps)
        try c.encode(videoMaxBytes, forKey: .videoMaxBytes)
        try c.encode(videoMaxEdge, forKey: .videoMaxEdge)
        try c.encode(videoFPS, forKey: .videoFPS)
        try c.encode(exportPreset, forKey: .exportPreset)
    }

    public static var defaultLow: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1920,
                                 imageJPEGQuality: 80,
                                 videoRateMbps: 8.0,
                                 videoMaxBytes: 100 * 1024 * 1024,
                                 videoMaxEdge: 1920,
                                 videoFPS: 30,
                                 exportPreset: "720p")
    }

    public static var defaultMedium: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1600,
                                 imageJPEGQuality: 50,
                                 videoRateMbps: 3.2,
                                 videoMaxBytes: 40 * 1024 * 1024,
                                 videoMaxEdge: 1280,
                                 videoFPS: 30,
                                 exportPreset: "540p")
    }

    public static var defaultHigh: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1280,
                                 imageJPEGQuality: 15,
                                 videoRateMbps: 0.96,
                                 videoMaxBytes: 12 * 1024 * 1024,
                                 videoMaxEdge: 640,
                                 videoFPS: 24,
                                 exportPreset: "low")
    }

    /// Copy with a lower encode max-edge (batch jetsam mitigation). Rate/FPS unchanged.
    public func cappingVideoMaxEdge(_ cap: Int) -> MediaUploadProfileConfig {
        let edge = max(320, min(videoMaxEdge, cap))
        return MediaUploadProfileConfig(imageMaxDimension: imageMaxDimension,
                                        imageJPEGQuality: imageJPEGQuality,
                                        videoRateMbps: videoRateMbps,
                                        videoMaxBytes: videoMaxBytes,
                                        videoMaxEdge: edge,
                                        videoFPS: videoFPS,
                                        exportPreset: exportPreset)
    }
}

/// Build 9 debug compression controls. Mirrored to App Group for Share Extension.
@objcMembers public final class MediaUploadDebugSettings: NSObject, Codable {
    private static let storageKey = "ncMediaUploadDebugSettings"
    private static let lock = NSLock()
    private static var cached: MediaUploadDebugSettings?
    /// Bytes last loaded/saved — used so Share Extension picks up main-app UI changes.
    private static var cachedData: Data?

    /// Default Automatic estimate safety margin for photos (percent). `estimate × (1 + margin/100) < cap`.
    public static let defaultAutomaticPhotoEstimateMarginPercent: Double = 20
    /// Default Automatic estimate safety margin for videos (percent).
    public static let defaultAutomaticVideoEstimateMarginPercent: Double = 10

    public var videoEngineRaw: Int
    public var perFileMaxBytes: Int64
    public var packageMaxBytes: Int64
    /// Automatic: allow this % underestimate on photo size estimates before accepting a level vs max file size.
    public var automaticPhotoEstimateMarginPercent: Double
    /// Automatic: allow this % underestimate on video size estimates before accepting a level vs max file size.
    public var automaticVideoEstimateMarginPercent: Double
    public var low: MediaUploadProfileConfig
    public var medium: MediaUploadProfileConfig
    public var high: MediaUploadProfileConfig

    private enum CodingKeys: String, CodingKey {
        case videoEngineRaw
        case perFileMaxBytes
        case packageMaxBytes
        case automaticPhotoEstimateMarginPercent
        case automaticVideoEstimateMarginPercent
        case low
        case medium
        case high
    }

    public var videoEngine: MediaUploadVideoEngine {
        get { MediaUploadVideoEngine(rawValue: videoEngineRaw) ?? .assetWriter }
        set { videoEngineRaw = newValue.rawValue }
    }

    public var usesAssetWriter: Bool {
        videoEngine == .assetWriter
    }

    public init(videoEngineRaw: Int = MediaUploadVideoEngine.assetWriter.rawValue,
                perFileMaxBytes: Int64 = 16 * 1024 * 1024,
                packageMaxBytes: Int64 = 16 * 1024 * 1024,
                automaticPhotoEstimateMarginPercent: Double = MediaUploadDebugSettings.defaultAutomaticPhotoEstimateMarginPercent,
                automaticVideoEstimateMarginPercent: Double = MediaUploadDebugSettings.defaultAutomaticVideoEstimateMarginPercent,
                low: MediaUploadProfileConfig = .defaultLow,
                medium: MediaUploadProfileConfig = .defaultMedium,
                high: MediaUploadProfileConfig = .defaultHigh) {
        self.videoEngineRaw = videoEngineRaw
        self.perFileMaxBytes = perFileMaxBytes
        self.packageMaxBytes = packageMaxBytes
        self.automaticPhotoEstimateMarginPercent = Self.clampedMarginPercent(automaticPhotoEstimateMarginPercent)
        self.automaticVideoEstimateMarginPercent = Self.clampedMarginPercent(automaticVideoEstimateMarginPercent)
        self.low = low
        self.medium = medium
        self.high = high
    }

    public required convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let videoEngineRaw = try c.decodeIfPresent(Int.self, forKey: .videoEngineRaw)
            ?? MediaUploadVideoEngine.assetWriter.rawValue
        let perFileMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .perFileMaxBytes) ?? (16 * 1024 * 1024)
        let packageMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .packageMaxBytes) ?? perFileMaxBytes
        let photoMargin = try c.decodeIfPresent(Double.self, forKey: .automaticPhotoEstimateMarginPercent)
            ?? Self.defaultAutomaticPhotoEstimateMarginPercent
        let videoMargin = try c.decodeIfPresent(Double.self, forKey: .automaticVideoEstimateMarginPercent)
            ?? Self.defaultAutomaticVideoEstimateMarginPercent
        let low = try c.decodeIfPresent(MediaUploadProfileConfig.self, forKey: .low) ?? .defaultLow
        let medium = try c.decodeIfPresent(MediaUploadProfileConfig.self, forKey: .medium) ?? .defaultMedium
        let high = try c.decodeIfPresent(MediaUploadProfileConfig.self, forKey: .high) ?? .defaultHigh
        self.init(videoEngineRaw: videoEngineRaw,
                  perFileMaxBytes: perFileMaxBytes,
                  packageMaxBytes: packageMaxBytes,
                  automaticPhotoEstimateMarginPercent: photoMargin,
                  automaticVideoEstimateMarginPercent: videoMargin,
                  low: low,
                  medium: medium,
                  high: high)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoEngineRaw, forKey: .videoEngineRaw)
        try c.encode(perFileMaxBytes, forKey: .perFileMaxBytes)
        try c.encode(packageMaxBytes, forKey: .packageMaxBytes)
        try c.encode(automaticPhotoEstimateMarginPercent, forKey: .automaticPhotoEstimateMarginPercent)
        try c.encode(automaticVideoEstimateMarginPercent, forKey: .automaticVideoEstimateMarginPercent)
        try c.encode(low, forKey: .low)
        try c.encode(medium, forKey: .medium)
        try c.encode(high, forKey: .high)
    }

    /// Clamps margin to 0…50%.
    public static func clampedMarginPercent(_ value: Double) -> Double {
        min(50, max(0, value))
    }

    public static var `default`: MediaUploadDebugSettings {
        MediaUploadDebugSettings()
    }

    public func profile(for level: MediaUploadCompressionLevel) -> MediaUploadProfileConfig? {
        switch level {
        case .low: return low
        case .medium: return medium
        case .high: return high
        case .none: return nil
        @unknown default: return nil
        }
    }

    private static func engineName(_ raw: Int) -> String {
        (MediaUploadVideoEngine(rawValue: raw) ?? .assetWriter) == .assetWriter ? "writer" : "exportSession"
    }

    /// Compact one-line dump for NCLog when settings are saved or reloaded.
    public var summaryForLog: String {
        func profileLine(_ name: String, _ c: MediaUploadProfileConfig) -> String {
            String(format: "%@[q=%d imgEdge=%d rate=%.2fMbps vidMax=%.1fMB vidEdge=%d fps=%.0f preset=%@]",
                   name,
                   c.imageJPEGQuality,
                   c.imageMaxDimension,
                   c.videoRateMbps,
                   Double(c.videoMaxBytes) / 1_048_576.0,
                   c.videoMaxEdge,
                   c.videoFPS,
                   c.exportPreset)
        }
        return String(format: "engine=%@ perFile=%.1fMB package=%.1fMB photoMargin=%.0f%% videoMargin=%.0f%% %@ %@ %@",
                      Self.engineName(videoEngineRaw),
                      Double(perFileMaxBytes) / 1_048_576.0,
                      Double(packageMaxBytes) / 1_048_576.0,
                      automaticPhotoEstimateMarginPercent,
                      automaticVideoEstimateMarginPercent,
                      profileLine("low", low),
                      profileLine("med", medium),
                      profileLine("high", high))
    }

    /// Field-level before → after for NCLog (compares against last persisted snapshot).
    public func changeDescription(from previous: MediaUploadDebugSettings?) -> String {
        guard let previous else {
            return "initial \(summaryForLog)"
        }
        var parts: [String] = []
        if previous.videoEngineRaw != videoEngineRaw {
            parts.append("engine: \(Self.engineName(previous.videoEngineRaw)) → \(Self.engineName(videoEngineRaw))")
        }
        if previous.perFileMaxBytes != perFileMaxBytes {
            parts.append(String(format: "perFile: %.1fMB → %.1fMB",
                                Double(previous.perFileMaxBytes) / 1_048_576.0,
                                Double(perFileMaxBytes) / 1_048_576.0))
        }
        if previous.packageMaxBytes != packageMaxBytes {
            parts.append(String(format: "package: %.1fMB → %.1fMB",
                                Double(previous.packageMaxBytes) / 1_048_576.0,
                                Double(packageMaxBytes) / 1_048_576.0))
        }
        if previous.automaticPhotoEstimateMarginPercent != automaticPhotoEstimateMarginPercent {
            parts.append(String(format: "photoMargin: %.0f%% → %.0f%%",
                                previous.automaticPhotoEstimateMarginPercent,
                                automaticPhotoEstimateMarginPercent))
        }
        if previous.automaticVideoEstimateMarginPercent != automaticVideoEstimateMarginPercent {
            parts.append(String(format: "videoMargin: %.0f%% → %.0f%%",
                                previous.automaticVideoEstimateMarginPercent,
                                automaticVideoEstimateMarginPercent))
        }
        func appendProfileDiff(_ name: String, _ before: MediaUploadProfileConfig, _ after: MediaUploadProfileConfig) {
            if before.imageJPEGQuality != after.imageJPEGQuality {
                parts.append("\(name).jpegQuality: \(before.imageJPEGQuality) → \(after.imageJPEGQuality)")
            }
            if before.imageMaxDimension != after.imageMaxDimension {
                parts.append("\(name).imgEdge: \(before.imageMaxDimension) → \(after.imageMaxDimension)")
            }
            if before.videoRateMbps != after.videoRateMbps {
                parts.append(String(format: "%@.rate: %.2f → %.2f Mbps", name, before.videoRateMbps, after.videoRateMbps))
            }
            if before.videoMaxBytes != after.videoMaxBytes {
                parts.append(String(format: "%@.vidMax: %.1f → %.1f MB",
                                    name,
                                    Double(before.videoMaxBytes) / 1_048_576.0,
                                    Double(after.videoMaxBytes) / 1_048_576.0))
            }
            if before.videoMaxEdge != after.videoMaxEdge {
                parts.append("\(name).vidEdge: \(before.videoMaxEdge) → \(after.videoMaxEdge)")
            }
            if before.videoFPS != after.videoFPS {
                parts.append(String(format: "%@.fps: %.0f → %.0f", name, before.videoFPS, after.videoFPS))
            }
            if before.exportPreset != after.exportPreset {
                parts.append("\(name).preset: \(before.exportPreset) → \(after.exportPreset)")
            }
        }
        appendProfileDiff("low", previous.low, low)
        appendProfileDiff("med", previous.medium, medium)
        appendProfileDiff("high", previous.high, high)
        if parts.isEmpty {
            return "no field changes"
        }
        return parts.joined(separator: "; ")
    }

    /// Need ~10% savings before offering a compress chip (estimate slack).
    public static let shrinkEnableMargin: Double = 0.9

    /// Community / empirical Mbps guesses for ExportSession presets (not Apple contracts).
    public static func guestimatedExportPresetMbps(_ presetKey: String) -> Double {
        switch presetKey {
        // Calibrated to High/ExportSession ACTUAL on screen recordings + phone clips (~0.10–0.21 Mbps).
        case "low": return 0.12
        case "medium": return 0.7
        case "high": return 8.0 // HighestQuality — often near source; treat as mild
        case "480p": return 1.5
        // Calibrated to Medium/ExportSession ACTUAL (5-video bag, ~3.4–5.7 Mbps, ~4.3 avg).
        case "540p": return 4.3
        case "720p": return 4.0
        case "1080p": return 8.0
        case "2160p": return 20.0
        default: return 2.0
        }
    }

    public static func guestimatedExportPresetLabel(_ presetKey: String) -> String {
        let mbps = guestimatedExportPresetMbps(presetKey)
        return String(format: "~%.2f Mbps", mbps)
    }

    /// Full Apple constant name for UI (e.g. `AVAssetExportPresetLowQuality`).
    public static func readableAVExportPreset(_ presetKey: String) -> String {
        avExportPresetName(forKey: presetKey)
    }

    /// Compact label for the settings value column (avoids wrapping): `1280x720`, `LowQuality`, …
    public static func shortAVExportPreset(_ presetKey: String) -> String {
        let full = avExportPresetName(forKey: presetKey)
        let prefix = "AVAssetExportPreset"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return full
    }

    /// File bytes → approx total Mbps for duration (includes audio + container).
    public static func approximateSourceTotalMbps(fileBytes: Int64, durationSeconds: Double) -> Double {
        guard fileBytes > 0, durationSeconds.isFinite, durationSeconds > 0.05 else { return 0 }
        return (Double(fileBytes) * 8.0) / durationSeconds / 1_000_000.0
    }

    /// Rough video-only Mbps after subtracting typical AAC.
    public static func approximateSourceVideoMbps(fileBytes: Int64, durationSeconds: Double) -> Double {
        let total = approximateSourceTotalMbps(fileBytes: fileBytes, durationSeconds: durationSeconds)
        return max(0.05, total - 0.128)
    }

    /// Effective Mbps for Writer: min(profile rate, size-cap → Mbps for this duration).
    public static func effectiveRateMbps(profile: MediaUploadProfileConfig, durationSeconds: Double) -> Double {
        let base = max(0.08, profile.videoRateMbps)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return base }
        // videoMaxBytes as an average bitrate ceiling for this clip length.
        let capped = Double(profile.videoMaxBytes) * 8.0 / durationSeconds / 1_000_000.0
        return min(base, max(0.08, capped))
    }

    private static let estimateCacheLock = NSLock()
    private static var estimateCache: [String: (bytes: Int64, at: Date)] = [:]
    private static let estimateCacheTTL: TimeInterval = 30

    /// Maps Debug preset keys to `AVAssetExportSession` preset names.
    public static func avExportPresetName(forKey key: String) -> String {
        switch key {
        case "medium": return AVAssetExportPresetMediumQuality
        case "high": return AVAssetExportPresetHighestQuality
        case "480p": return AVAssetExportPreset640x480
        case "540p": return AVAssetExportPreset960x540
        case "720p": return AVAssetExportPreset1280x720
        case "1080p": return AVAssetExportPreset1920x1080
        case "2160p": return AVAssetExportPreset3840x2160
        default: return AVAssetExportPresetLowQuality
        }
    }

    /// Apple's asset-aware ExportSession size estimate (better than Mbps guests). Cached ~30s.
    /// nil / failure → caller should prefer compress (don't skip on a bad guess).
    public static func appleEstimatedExportBytes(at fileURL: URL, presetKey: String, timeout: TimeInterval = 0.85) -> Int64? {
        let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
        let cacheKey = "\(fileURL.path)|\(presetKey)|\(original)"
        estimateCacheLock.lock()
        if let hit = estimateCache[cacheKey], Date().timeIntervalSince(hit.at) < estimateCacheTTL, hit.bytes > 0 {
            let cached = hit.bytes
            estimateCacheLock.unlock()
            return cached
        }
        estimateCacheLock.unlock()

        let presetName = avExportPresetName(forKey: presetKey)
        let asset = AVURLAsset(url: fileURL)
        if asset.statusOfValue(forKey: "duration", error: nil) != .loaded {
            let g = DispatchGroup()
            g.enter()
            asset.loadValuesAsynchronously(forKeys: ["duration"]) { g.leave() }
            _ = g.wait(timeout: .now() + 0.35)
        }
        let duration = asset.duration
        guard duration.isValid, !duration.isIndefinite, CMTimeGetSeconds(duration) > 0 else { return nil }
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else { return nil }

        session.timeRange = CMTimeRange(start: .zero, duration: duration)
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let group = DispatchGroup()
        group.enter()
        var estimated: Int64 = 0
        var estimateError: Error?
        session.estimateOutputFileLength { length, error in
            estimated = length
            estimateError = error
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            NCLog.log("MediaUploadHeuristic AppleEstimate TIMEOUT \(fileURL.lastPathComponent) preset=\(presetKey)")
            return nil
        }
        if let estimateError {
            NCLog.log("MediaUploadHeuristic AppleEstimate ERROR \(fileURL.lastPathComponent) preset=\(presetKey): \(estimateError.localizedDescription)")
            return nil
        }
        guard estimated > 0 else {
            NCLog.log("MediaUploadHeuristic AppleEstimate ZERO \(fileURL.lastPathComponent) preset=\(presetKey)")
            return nil
        }

        estimateCacheLock.lock()
        estimateCache[cacheKey] = (estimated, Date())
        estimateCacheLock.unlock()

        NCLog.log(String(format:
            "MediaUploadHeuristic AppleEstimate %@ preset=%@ → %lld (%.2f MB) original=%lld",
            fileURL.lastPathComponent, presetKey, estimated, Double(estimated) / 1_048_576.0, original))
        return estimated
    }

    /// Target Mbps for a profile under the current video engine (Writer rate or preset guestimate).
    public static func targetVideoMbps(profile: MediaUploadProfileConfig, durationSeconds: Double) -> Double {
        if shared().usesAssetWriter {
            return effectiveRateMbps(profile: profile, durationSeconds: durationSeconds)
        }
        return guestimatedExportPresetMbps(profile.exportPreset)
    }

    /// Telegram-style size estimate: `Mbps × duration / 8` (bytes).
    /// Matches Writer target rate (total file budget) for Manual chip labels.
    public static func telegramEstimatedVideoBytes(profile: MediaUploadProfileConfig,
                                                   durationSeconds: Double,
                                                   originalSize: Int64) -> Int64 {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return originalSize > 0 ? originalSize : 12_288
        }
        let rateMbps = effectiveRateMbps(profile: profile, durationSeconds: durationSeconds)
        let estimated = Int64(rateMbps * 1_000_000.0 / 8.0 * durationSeconds)
        return max(12_288, min(estimated, originalSize > 0 ? originalSize : estimated))
    }

    public static func estimatedVideoBytes(profile: MediaUploadProfileConfig, durationSeconds: Double, originalSize: Int64) -> Int64 {
        if shared().usesAssetWriter {
            return telegramEstimatedVideoBytes(profile: profile,
                                               durationSeconds: durationSeconds,
                                               originalSize: originalSize)
        }
        let mbps = guestimatedExportPresetMbps(profile.exportPreset)
        let estimated = Int64(mbps * durationSeconds * 1_000_000.0 / 8.0)
        if profile.exportPreset == "high" {
            return originalSize > 0 ? originalSize : max(12_288, estimated)
        }
        return max(12_288, min(estimated, originalSize > 0 ? originalSize : estimated))
    }

    /// URL-aware estimate: Apple ExportSession estimate when engine is presets.
    public static func estimatedVideoBytes(at fileURL: URL, profile: MediaUploadProfileConfig, durationSeconds: Double, originalSize: Int64) -> Int64 {
        if !shared().usesAssetWriter,
           let apple = appleEstimatedExportBytes(at: fileURL, presetKey: profile.exportPreset) {
            return max(12_288, min(apple, originalSize > 0 ? originalSize : apple))
        }
        return estimatedVideoBytes(profile: profile, durationSeconds: durationSeconds, originalSize: originalSize)
    }

    /// Cheap ExportSession-preset guestimate (no AVAsset). Used when Settings = Presets.
    public static func estimatedVideoBytesForExportPreset(at fileURL: URL,
                                                          profile: MediaUploadProfileConfig,
                                                          durationSeconds: Double,
                                                          originalSize: Int64) -> Int64 {
        _ = fileURL
        let mbps = guestimatedExportPresetMbps(profile.exportPreset)
        let estimated = Int64(mbps * durationSeconds * 1_000_000.0 / 8.0)
        return max(12_288, min(estimated, originalSize > 0 ? originalSize : estimated))
    }

    private static let shrinkDecisionCacheLock = NSLock()
    private static var shrinkDecisionCache: [String: (result: Bool, at: Date)] = [:]
    private static let shrinkDecisionCacheTTL: TimeInterval = 8

    /// Whether compressing this video at `level` is likely to shrink (≥10% smaller).
    /// - Parameter forceExportSession: When true, estimate with ExportSession guests (Settings=Presets).
    public static func videoCompressionLikelyShrinks(at fileURL: URL,
                                                     level: MediaUploadCompressionLevel,
                                                     forceExportSession: Bool = false) -> Bool {
        guard level != .none else { return true }
        guard let profile = shared().profile(for: level) else { return false }
        let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
        guard original > 0 else { return false }

        let usesWriter = shared().usesAssetWriter && !forceExportSession && !MediaUploadPreprocessor.preferExportSession
        let cacheKey = "\(fileURL.path)|\(level.rawValue)|\(usesWriter ? "w" : "e")|\(original)"
        shrinkDecisionCacheLock.lock()
        if let hit = shrinkDecisionCache[cacheKey], Date().timeIntervalSince(hit.at) < shrinkDecisionCacheTTL {
            let cached = hit.result
            shrinkDecisionCacheLock.unlock()
            return cached
        }
        shrinkDecisionCacheLock.unlock()

        let asset = AVURLAsset(url: fileURL)
        if asset.statusOfValue(forKey: "duration", error: nil) != .loaded {
            let group = DispatchGroup()
            group.enter()
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                group.leave()
            }
            _ = group.wait(timeout: .now() + 0.4)
        }
        let duration = CMTimeGetSeconds(asset.duration)
        // Short clips: container overhead dominates — allow compress (post-encode still guards).
        guard duration.isFinite, duration > 2.0 else {
            NCLog.log(String(format:
                "MediaUploadHeuristic video %@ level=%ld SHORT duration=%.2fs original=%lld → compress=YES (short-clip rule)",
                fileURL.lastPathComponent, level.rawValue, duration.isFinite ? duration : -1, original))
            shrinkDecisionCacheLock.lock()
            shrinkDecisionCache[cacheKey] = (true, Date())
            shrinkDecisionCacheLock.unlock()
            return true
        }

        let sourceTotalMbps = approximateSourceTotalMbps(fileBytes: original, durationSeconds: duration)
        let sourceVideoMbps = approximateSourceVideoMbps(fileBytes: original, durationSeconds: duration)
        let thresholdBytes = Int64(Double(original) * shrinkEnableMargin)

        let willShrink: Bool
        if usesWriter {
            let expectedBytes = telegramEstimatedVideoBytes(profile: profile,
                                                            durationSeconds: duration,
                                                            originalSize: original)
            let targetMbps = targetVideoMbps(profile: profile, durationSeconds: duration)
            let thresholdMbps = sourceVideoMbps * shrinkEnableMargin
            willShrink = targetMbps < thresholdMbps
            NCLog.log(String(format:
                "MediaUploadHeuristic video %@ level=%ld engine=writer duration=%.2fs original=%lld (%.2f MB) sourceTotal=%.3fMbps sourceVideo=%.3fMbps target=%.3fMbps threshold=%.3fMbps expected=%lld (%.2f MB) → %@",
                fileURL.lastPathComponent,
                level.rawValue,
                duration,
                original,
                Double(original) / 1_048_576.0,
                sourceTotalMbps,
                sourceVideoMbps,
                targetMbps,
                thresholdMbps,
                expectedBytes,
                Double(expectedBytes) / 1_048_576.0,
                willShrink ? "compress" : "skip"))
        } else if !forceExportSession,
                  let appleBytes = appleEstimatedExportBytes(at: fileURL, presetKey: profile.exportPreset) {
            willShrink = appleBytes < thresholdBytes
            let appleMbps = approximateSourceTotalMbps(fileBytes: appleBytes, durationSeconds: duration)
            NCLog.log(String(format:
                "MediaUploadHeuristic video %@ level=%ld engine=preset:%@ duration=%.2fs original=%lld (%.2f MB, %.3fMbps) AppleEstimate=%lld (%.2f MB, %.3fMbps) threshold=%lld → %@ (apple)",
                fileURL.lastPathComponent,
                level.rawValue,
                profile.exportPreset,
                duration,
                original,
                Double(original) / 1_048_576.0,
                sourceTotalMbps,
                appleBytes,
                Double(appleBytes) / 1_048_576.0,
                appleMbps,
                thresholdBytes,
                willShrink ? "compress" : "skip"))
        } else {
            let expectedBytes = estimatedVideoBytesForExportPreset(at: fileURL,
                                                                   profile: profile,
                                                                   durationSeconds: duration,
                                                                   originalSize: original)
            let targetMbps = guestimatedExportPresetMbps(profile.exportPreset)
            willShrink = expectedBytes < thresholdBytes
            NCLog.log(String(format:
                "MediaUploadHeuristic video %@ level=%ld engine=preset:%@ duration=%.2fs original=%lld (%.2f MB) sourceTotal=%.3fMbps sourceVideo=%.3fMbps target=%.3fMbps expected=%lld (%.2f MB) threshold=%lld → %@",
                fileURL.lastPathComponent,
                level.rawValue,
                profile.exportPreset,
                duration,
                original,
                Double(original) / 1_048_576.0,
                sourceTotalMbps,
                sourceVideoMbps,
                targetMbps,
                expectedBytes,
                Double(expectedBytes) / 1_048_576.0,
                thresholdBytes,
                willShrink ? "compress" : "skip"))
        }

        shrinkDecisionCacheLock.lock()
        shrinkDecisionCache[cacheKey] = (willShrink, Date())
        shrinkDecisionCacheLock.unlock()
        return willShrink
    }

    /// Whether re-JPEG at `level` is likely ≥10% smaller (no trial encode).
    /// Uses max-edge scale + rough bits-per-pixel from JPEG quality.
    @objc(imageCompressionLikelyShrinksAtURL:level:)
    public static func imageCompressionLikelyShrinks(at fileURL: URL, level: MediaUploadCompressionLevel) -> Bool {
        guard level != .none else { return true }
        guard let profile = shared().profile(for: level) else { return false }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "gif" {
            NCLog.log("MediaUploadHeuristic image \(fileURL.lastPathComponent) level=\(level.rawValue) GIF → skip")
            return false
        }

        let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
        guard original > 0 else { return false }

        guard let pixelSize = imagePixelSize(at: fileURL) else {
            NCLog.log("MediaUploadHeuristic image \(fileURL.lastPathComponent) level=\(level.rawValue) unknown pixels original=\(original) → compress=YES")
            return true
        }

        let maxEdge = CGFloat(max(320, profile.imageMaxDimension))
        let longest = max(pixelSize.width, pixelSize.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1.0
        let outPixels = Double(pixelSize.width * pixelSize.height) * Double(scale * scale)
        guard outPixels > 0 else { return true }

        let sourceBpp = (Double(original) * 8.0) / Double(pixelSize.width * pixelSize.height)
        let targetBpp = expectedJPEGBitsPerPixel(qualityPercent: profile.imageJPEGQuality)
        let expectedBytes = estimatedImageBytes(at: fileURL, profile: profile, originalSize: original)
        let thresholdBytes = Int64(Double(original) * shrinkEnableMargin)

        let willShrink: Bool
        var reason = ""
        if scale < 0.95 {
            willShrink = expectedBytes < thresholdBytes
            reason = "resize"
        } else if ["heic", "heif", "png", "webp"].contains(ext) {
            willShrink = expectedBytes < thresholdBytes
            reason = "heic/png"
        } else if sourceBpp <= targetBpp * 1.05 {
            willShrink = false
            reason = "bpp-already-low"
        } else {
            willShrink = expectedBytes < thresholdBytes
            reason = "quality"
        }

        NCLog.log(String(format:
            "MediaUploadHeuristic image %@ level=%ld %@ %.0fx%.0f scale=%.3f q=%d original=%lld (%.2f MB) sourceBpp=%.3f targetBpp=%.3f expected=%lld (%.2f MB) threshold=%lld → %@ (%@)",
            fileURL.lastPathComponent,
            level.rawValue,
            ext,
            pixelSize.width,
            pixelSize.height,
            scale,
            profile.imageJPEGQuality,
            original,
            Double(original) / 1_048_576.0,
            sourceBpp,
            targetBpp,
            expectedBytes,
            Double(expectedBytes) / 1_048_576.0,
            thresholdBytes,
            willShrink ? "compress" : "skip",
            reason))

        return willShrink
    }

    /// Rough output bpp for `jpegData(compressionQuality:)` (empirical, not a spec).
    /// Low-q band calibrated against phone-camera JPEG re-encodes (prefer slight overestimate for chips).
    public static func expectedJPEGBitsPerPixel(qualityPercent: Int) -> Double {
        let q = min(100, max(1, qualityPercent))
        switch q {
        case 1...20: return 0.25
        case 21...40: return 0.7
        case 41...60: return 1.3
        case 61...80: return 2.2
        default: return 3.5
        }
    }

    /// Chip / heuristic size for a re-JPEG at `profile` (resize + bpp). Falls back to quality×original if pixels unknown.
    public static func estimatedImageBytes(at fileURL: URL, profile: MediaUploadProfileConfig, originalSize: Int64) -> Int64 {
        let cap = originalSize > 0 ? originalSize : Int64.max
        guard let pixelSize = imagePixelSize(at: fileURL) else {
            let q = Double(max(1, min(100, profile.imageJPEGQuality))) / 100.0
            let factor = min(0.95, max(0.05, q * 0.65))
            return max(12_288, min(Int64(Double(max(0, originalSize)) * factor), cap == Int64.max ? Int64.max : cap))
        }
        let maxEdge = CGFloat(max(320, profile.imageMaxDimension))
        let longest = max(pixelSize.width, pixelSize.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1.0
        let outPixels = Double(pixelSize.width * pixelSize.height) * Double(scale * scale)
        guard outPixels > 0 else { return max(12_288, min(originalSize, cap)) }
        let targetBpp = expectedJPEGBitsPerPixel(qualityPercent: profile.imageJPEGQuality)
        let expected = Int64((outPixels * targetBpp) / 8.0)
        return max(12_288, min(expected, cap == Int64.max ? expected : cap))
    }

    private static func imagePixelSize(at fileURL: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        guard let wNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let hNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let w = CGFloat(truncating: wNum)
        let h = CGFloat(truncating: hNum)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Manual chip gate: None always.
    /// Enable Low/Medium/High if **any** video or image in the bag is likely to shrink;
    /// non-benefiting items skip that level on Send (as-is).
    public static func compressionLevelLikelyUseful(_ level: MediaUploadCompressionLevel, forFileURLs fileURLs: [URL]) -> Bool {
        if level == .none { return true }

        // Match Send engine: Writer estimates when Bitrate is selected (including multi-video).
        let forceExportSession = !shared().usesAssetWriter

        var sawCompressible = false
        for url in fileURLs {
            let ext = url.pathExtension.lowercased()
            if MediaUploadPreprocessor.isVideo(fileExtension: ext) {
                sawCompressible = true
                if videoCompressionLikelyShrinks(at: url, level: level, forceExportSession: forceExportSession) {
                    return true
                }
            } else if NCUtils.isImage(fileExtension: ext), ext != "gif" {
                sawCompressible = true
                if imageCompressionLikelyShrinks(at: url, level: level) {
                    return true
                }
            }
        }

        // No compressible media (pdf/audio/gif-only): chips unused; leave enabled.
        return !sawCompressible
    }

    /// Shared Send-path gate: compress this file at `level` only if likely to shrink.
    @objc(itemCompressionLikelyShrinksAtURL:level:)
    public static func itemCompressionLikelyShrinks(at fileURL: URL, level: MediaUploadCompressionLevel) -> Bool {
        itemCompressionLikelyShrinks(at: fileURL, level: level, forceExportSession: false)
    }

    public static func itemCompressionLikelyShrinks(at fileURL: URL,
                                                    level: MediaUploadCompressionLevel,
                                                    forceExportSession: Bool) -> Bool {
        if level == .none { return false }
        let ext = fileURL.pathExtension.lowercased()
        if MediaUploadPreprocessor.isVideo(fileExtension: ext) {
            return videoCompressionLikelyShrinks(at: fileURL, level: level, forceExportSession: forceExportSession)
        }
        if NCUtils.isImage(fileExtension: ext), ext != "gif" {
            return imageCompressionLikelyShrinks(at: fileURL, level: level)
        }
        return false
    }

    @objc(sharedSettings)
    public static func shared() -> MediaUploadDebugSettings {
        lock.lock()
        defer { lock.unlock() }
        // Re-read App Group every call so a warm Share Extension sees main-app Settings changes.
        // Keep the in-memory object only while the persisted bytes are unchanged.
        if let data = persistedData() {
            if let cached, cachedData == data {
                return cached
            }
            let reason: String
            if cachedData == nil {
                reason = "cold-load"
            } else {
                reason = "disk-changed"
            }
            if let loaded = try? JSONDecoder().decode(MediaUploadDebugSettings.self, from: data) {
                cached = loaded
                cachedData = data
                let summary = loaded.summaryForLog
                // Log outside the hot hit path only (reload / first load).
                DispatchQueue.global(qos: .utility).async {
                    NCLog.log("MediaUploadDebugSettings: cache reload (\(reason)) \(summary)")
                }
                return loaded
            }
        }
        let hadCache = cached != nil
        let fallback = MediaUploadDebugSettings.default
        cached = fallback
        cachedData = try? JSONEncoder().encode(fallback)
        let summary = fallback.summaryForLog
        DispatchQueue.global(qos: .utility).async {
            NCLog.log("MediaUploadDebugSettings: cache reload (\(hadCache ? "decode-failed→defaults" : "empty→defaults")) \(summary)")
        }
        return fallback
    }

    public static func invalidateCache() {
        lock.lock()
        let hadCache = cached != nil
        cached = nil
        cachedData = nil
        lock.unlock()
        NCLog.log("MediaUploadDebugSettings: invalidateCache (hadCache=\(hadCache))")
    }

    public func save() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Disk still holds the previous snapshot (UI mutates the in-memory object before save).
        let previous: MediaUploadDebugSettings?
        if let oldData = Self.persistedData() {
            previous = try? JSONDecoder().decode(MediaUploadDebugSettings.self, from: oldData)
        } else {
            previous = nil
        }
        let diff = changeDescription(from: previous)
        guard let data = try? JSONEncoder().encode(self) else {
            NCLog.log("MediaUploadDebugSettings: save FAILED (encode) pending=\(diff)")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        UserDefaults.standard.synchronize()
        var wroteGroup = false
        if let group = UserDefaults(suiteName: groupIdentifier) {
            group.set(data, forKey: Self.storageKey)
            group.synchronize()
            wroteGroup = true
        }
        Self.cached = self
        Self.cachedData = data
        // Diff of what changed + full Low/Med/High snapshot (JPEG + video fields).
        NCLog.log("MediaUploadDebugSettings: save (appGroup=\(wroteGroup)) changed: \(diff) | after: \(summaryForLog)")
    }

    public static func resetToDefaults() {
        NCLog.log("MediaUploadDebugSettings: resetToDefaults")
        let fresh = MediaUploadDebugSettings.default
        fresh.save()
    }

    /// App Group is the cross-process source of truth (main app ↔ Share Extension).
    private static func persistedData() -> Data? {
        if let group = UserDefaults(suiteName: groupIdentifier) {
            group.synchronize()
            if let data = group.data(forKey: storageKey) {
                return data
            }
        }
        return UserDefaults.standard.data(forKey: storageKey)
    }
}
