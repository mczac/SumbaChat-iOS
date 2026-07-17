//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

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

    /// Effective MB/s for a clip: min(profile rate, profileMaxBytes / duration).
    public static func effectiveRateMBps(profile: MediaUploadProfileConfig, durationSeconds: Double) -> Double {
        let base = max(0.01, profile.videoRateMBps)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return base }
        let capped = Double(profile.videoMaxBytes) / (durationSeconds * 1_048_576.0)
        return min(base, max(0.01, capped))
    }

    public static func estimatedVideoBytes(profile: MediaUploadProfileConfig, durationSeconds: Double, originalSize: Int64) -> Int64 {
        let rate = effectiveRateMBps(profile: profile, durationSeconds: durationSeconds)
        let estimated = Int64(rate * durationSeconds * 1_048_576.0)
        return max(12_288, min(estimated, originalSize > 0 ? originalSize : estimated))
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
