//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
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
    public var videoRateMBps: Double
    public var videoMaxBytes: Int64
    public var videoMaxEdge: Int
    public var videoFPS: Double
    /// ExportSession preset key: low, medium, high, 480p, 540p, 720p, 1080p, 2160p.
    public var exportPreset: String

    public init(imageMaxDimension: Int,
                imageJPEGQuality: Int,
                videoRateMBps: Double,
                videoMaxBytes: Int64,
                videoMaxEdge: Int,
                videoFPS: Double,
                exportPreset: String) {
        self.imageMaxDimension = imageMaxDimension
        self.imageJPEGQuality = imageJPEGQuality
        self.videoRateMBps = videoRateMBps
        self.videoMaxBytes = videoMaxBytes
        self.videoMaxEdge = videoMaxEdge
        self.videoFPS = videoFPS
        self.exportPreset = exportPreset
    }

    public static var defaultLow: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1920,
                                 imageJPEGQuality: 80,
                                 videoRateMBps: 1.0,
                                 videoMaxBytes: 100 * 1024 * 1024,
                                 videoMaxEdge: 1920,
                                 videoFPS: 30,
                                 exportPreset: "720p")
    }

    public static var defaultMedium: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1600,
                                 imageJPEGQuality: 50,
                                 videoRateMBps: 0.4,
                                 videoMaxBytes: 40 * 1024 * 1024,
                                 videoMaxEdge: 1280,
                                 videoFPS: 30,
                                 exportPreset: "540p")
    }

    public static var defaultHigh: MediaUploadProfileConfig {
        MediaUploadProfileConfig(imageMaxDimension: 1280,
                                 imageJPEGQuality: 15,
                                 videoRateMBps: 0.12,
                                 videoMaxBytes: 12 * 1024 * 1024,
                                 videoMaxEdge: 640,
                                 videoFPS: 24,
                                 exportPreset: "low")
    }
}

/// Build 9 debug compression controls. Mirrored to App Group for Share Extension.
@objcMembers public final class MediaUploadDebugSettings: NSObject, Codable {
    private static let storageKey = "ncMediaUploadDebugSettings"
    private static let lock = NSLock()
    private static var cached: MediaUploadDebugSettings?

    public var videoEngineRaw: Int
    public var perFileMaxBytes: Int64
    public var packageMaxBytes: Int64
    public var low: MediaUploadProfileConfig
    public var medium: MediaUploadProfileConfig
    public var high: MediaUploadProfileConfig

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
                low: MediaUploadProfileConfig = .defaultLow,
                medium: MediaUploadProfileConfig = .defaultMedium,
                high: MediaUploadProfileConfig = .defaultHigh) {
        self.videoEngineRaw = videoEngineRaw
        self.perFileMaxBytes = perFileMaxBytes
        self.packageMaxBytes = packageMaxBytes
        self.low = low
        self.medium = medium
        self.high = high
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

    /// Need ~10% savings before offering a compress chip (estimate slack).
    public static let shrinkEnableMargin: Double = 0.9

    /// Community / empirical Mbps guesses for ExportSession presets (not Apple contracts).
    public static func guestimatedExportPresetMbps(_ presetKey: String) -> Double {
        switch presetKey {
        case "low": return 0.15
        case "medium": return 0.7
        case "high": return 8.0 // HighestQuality — often near source; treat as mild
        case "480p": return 1.5
        case "540p": return 2.5
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

    /// Target Mbps for a profile under the current video engine.
    public static func targetVideoMbps(profile: MediaUploadProfileConfig, durationSeconds: Double) -> Double {
        if shared().usesAssetWriter {
            // Writer Debug rate is MB/s → Mbps × 8.
            return effectiveRateMBps(profile: profile, durationSeconds: durationSeconds) * 8.0
        }
        return guestimatedExportPresetMbps(profile.exportPreset)
    }

    public static func estimatedVideoBytes(profile: MediaUploadProfileConfig, durationSeconds: Double, originalSize: Int64) -> Int64 {
        let mbps = targetVideoMbps(profile: profile, durationSeconds: durationSeconds)
        let estimated = Int64(mbps * durationSeconds * 1_000_000.0 / 8.0)
        // HighestQuality / huge presets: never claim below original for chip math.
        if !shared().usesAssetWriter, profile.exportPreset == "high" {
            return originalSize > 0 ? originalSize : max(12_288, estimated)
        }
        return max(12_288, min(estimated, originalSize > 0 ? originalSize : estimated))
    }

    /// Whether compressing this video at `level` is likely to shrink (≥10% smaller).
    public static func videoCompressionLikelyShrinks(at fileURL: URL, level: MediaUploadCompressionLevel) -> Bool {
        guard level != .none else { return true }
        guard let profile = shared().profile(for: level) else { return false }
        let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
        guard original > 0 else { return false }

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
        guard duration.isFinite, duration > 2.0 else { return true }

        let sourceMbps = approximateSourceVideoMbps(fileBytes: original, durationSeconds: duration)
        let targetMbps = targetVideoMbps(profile: profile, durationSeconds: duration)
        return targetMbps < sourceMbps * shrinkEnableMargin
    }

    /// Whether re-JPEG at `level` is likely ≥10% smaller (no trial encode).
    /// Uses max-edge scale + rough bits-per-pixel from JPEG quality.
    public static func imageCompressionLikelyShrinks(at fileURL: URL, level: MediaUploadCompressionLevel) -> Bool {
        guard level != .none else { return true }
        guard let profile = shared().profile(for: level) else { return false }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "gif" { return false }

        let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
        guard original > 0 else { return false }

        guard let pixelSize = imagePixelSize(at: fileURL) else {
            // Unknown dimensions — allow compress; Send path decides.
            return true
        }

        let maxEdge = CGFloat(max(320, profile.imageMaxDimension))
        let longest = max(pixelSize.width, pixelSize.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1.0
        let outPixels = Double(pixelSize.width * pixelSize.height) * Double(scale * scale)
        guard outPixels > 0 else { return true }

        let sourceBpp = (Double(original) * 8.0) / Double(pixelSize.width * pixelSize.height)
        let targetBpp = expectedJPEGBitsPerPixel(qualityPercent: profile.imageJPEGQuality)
        let expectedBytes = Int64((outPixels * targetBpp) / 8.0)

        // Resize almost always wins on large camera photos.
        if scale < 0.95 {
            return expectedBytes < Int64(Double(original) * shrinkEnableMargin)
        }

        // Quality-only: if source is already denser-compressed than our target JPEG, skip.
        // HEIC/PNG often look "small" in bytes but expand when forced to JPEG — require clear win.
        if ["heic", "heif", "png", "webp"].contains(ext) {
            return expectedBytes < Int64(Double(original) * shrinkEnableMargin)
        }

        // Already-JPEG (or similar): compare bpp / expected size.
        if sourceBpp <= targetBpp * 1.05 {
            return false
        }
        return expectedBytes < Int64(Double(original) * shrinkEnableMargin)
    }

    /// Rough output bpp for `jpegData(compressionQuality:)` (empirical, not a spec).
    public static func expectedJPEGBitsPerPixel(qualityPercent: Int) -> Double {
        let q = min(100, max(1, qualityPercent))
        switch q {
        case 1...20: return 0.45
        case 21...40: return 0.8
        case 41...60: return 1.3
        case 61...80: return 2.2
        default: return 3.5
        }
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
    /// - Videos present: every video must likely shrink (images ignored — one level still applies on Send).
    /// - Photos-only: every compressible image must likely shrink.
    public static func compressionLevelLikelyUseful(_ level: MediaUploadCompressionLevel, forFileURLs fileURLs: [URL]) -> Bool {
        if level == .none { return true }

        var sawVideo = false
        var sawImage = false

        for url in fileURLs {
            let ext = url.pathExtension.lowercased()
            if MediaUploadPreprocessor.isVideo(fileExtension: ext) {
                sawVideo = true
                if !videoCompressionLikelyShrinks(at: url, level: level) {
                    return false
                }
            } else if NCUtils.isImage(fileExtension: ext), ext != "gif" {
                sawImage = true
            }
        }

        if sawVideo {
            return true
        }

        // Photos-only (or images + non-media): gate on images.
        if sawImage {
            for url in fileURLs {
                let ext = url.pathExtension.lowercased()
                guard NCUtils.isImage(fileExtension: ext), ext != "gif" else { continue }
                if !imageCompressionLikelyShrinks(at: url, level: level) {
                    return false
                }
            }
            return true
        }

        // No media to compress (pdf/audio/etc.) — chips unused; leave enabled.
        return true
    }

    @objc(sharedSettings)
    public static func shared() -> MediaUploadDebugSettings {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let loaded = loadFromDefaults() ?? .default
        cached = loaded
        return loaded
    }

    public static func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    public func save() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        UserDefaults.standard.synchronize()
        if let group = UserDefaults(suiteName: groupIdentifier) {
            group.set(data, forKey: Self.storageKey)
            group.synchronize()
        }
        Self.cached = self
    }

    public static func resetToDefaults() {
        let fresh = MediaUploadDebugSettings.default
        fresh.save()
    }

    private static func loadFromDefaults() -> MediaUploadDebugSettings? {
        let data = UserDefaults.standard.data(forKey: storageKey)
            ?? UserDefaults(suiteName: groupIdentifier)?.data(forKey: storageKey)
        guard let data else { return nil }
        return try? JSONDecoder().decode(MediaUploadDebugSettings.self, from: data)
    }
}
