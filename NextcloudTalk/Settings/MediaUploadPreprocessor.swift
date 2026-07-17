//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import ImageIO
import Network
import UIKit
import UniformTypeIdentifiers

/// User preference for how media is compressed before upload.
@objc public enum MediaUploadMode: Int {
    case noCompression = 0
    case automatic = 1
    case chooseOnUpload = 2
}

/// Explicit compression strength (Choose on upload, or resolved Automatic level).
/// Raw values: none=0, low=1, medium=2, high=3 (Build 9; replaces moderate=1).
@objc public enum MediaUploadCompressionLevel: Int {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    /// Legacy name used before Build 9.
    public static var moderate: MediaUploadCompressionLevel { .medium }
}

@objcMembers public final class MediaUploadCompressionSettings: NSObject {

    public static let defaultImageMaxDimension = 1280
    public static let defaultImageJPEGQuality = 45
    public static let defaultVideoPreset = "low"

    public static let automaticMaxBytes: Int64 = 16 * 1024 * 1024
    public static let automaticCellularEscalateBytes: Int64 = 8 * 1024 * 1024

    public let enabled: Bool
    public let imageEnabled: Bool
    public let imageMaxDimension: CGFloat
    public let imageJPEGQuality: CGFloat
    public let videoEnabled: Bool
    public let videoPreset: String
    public let profile: MediaUploadProfileConfig?

    public override convenience init() {
        self.init(level: .high)
    }

    @objc(initWithLevel:)
    public convenience init(level: MediaUploadCompressionLevel) {
        let debug = MediaUploadDebugSettings.shared()
        switch level {
        case .none:
            self.init(enabled: false,
                      imageEnabled: false,
                      imageMaxDimension: Self.defaultImageMaxDimension,
                      imageJPEGQuality: 100,
                      videoEnabled: false,
                      videoPreset: Self.defaultVideoPreset,
                      profile: nil)
        case .low, .medium, .high:
            let profile = debug.profile(for: level) ?? .defaultMedium
            self.init(enabled: true,
                      imageEnabled: true,
                      imageMaxDimension: profile.imageMaxDimension,
                      imageJPEGQuality: profile.imageJPEGQuality,
                      videoEnabled: true,
                      videoPreset: profile.exportPreset,
                      profile: profile)
        }
    }

    /// Kept for Realm/capabilities compatibility; uploads no longer use server values.
    @objc(initWithTalkCapabilities:)
    public convenience init(talkCapabilities: TalkCapabilities) {
        _ = talkCapabilities
        self.init(level: .none)
    }

    public init(enabled: Bool,
                imageEnabled: Bool,
                imageMaxDimension: Int,
                imageJPEGQuality: Int,
                videoEnabled: Bool,
                videoPreset: String,
                profile: MediaUploadProfileConfig? = nil) {
        self.enabled = enabled
        self.imageEnabled = imageEnabled
        self.imageMaxDimension = CGFloat(Self.validImageMaxDimension(imageMaxDimension))
        self.imageJPEGQuality = CGFloat(Self.validImageJPEGQuality(imageJPEGQuality)) / 100
        self.videoEnabled = videoEnabled
        self.videoPreset = Self.validVideoPreset(videoPreset)
        self.profile = profile
    }

    public var shouldCompressImages: Bool {
        enabled && imageEnabled
    }

    public var shouldCompressVideos: Bool {
        enabled && videoEnabled
    }

    fileprivate var avVideoPreset: String {
        switch videoPreset {
        case "medium":
            return AVAssetExportPresetMediumQuality
        case "high":
            return AVAssetExportPresetHighestQuality
        case "480p":
            return AVAssetExportPreset640x480
        case "540p":
            return AVAssetExportPreset960x540
        case "720p":
            return AVAssetExportPreset1280x720
        case "1080p":
            return AVAssetExportPreset1920x1080
        case "2160p":
            return AVAssetExportPreset3840x2160
        default:
            return AVAssetExportPresetLowQuality
        }
    }

    private static func validImageMaxDimension(_ value: Int) -> Int {
        guard (320...8192).contains(value) else {
            return defaultImageMaxDimension
        }
        return value
    }

    private static func validImageJPEGQuality(_ value: Int) -> Int {
        guard (1...100).contains(value) else {
            return defaultImageJPEGQuality
        }
        return value
    }

    private static func validVideoPreset(_ value: String) -> String {
        let supportedPresets = ["low", "medium", "high", "480p", "540p", "720p", "1080p", "2160p"]
        return supportedPresets.contains(value) ? value : defaultVideoPreset
    }
}

/// Package-aware Automatic picker: per-file cap X, package cap Y (Y wins).
@objcMembers public final class MediaUploadAutomaticPolicy: NSObject {

    private static let pathMonitor = NWPathMonitor()
    private static let monitorQueue = DispatchQueue(label: "com.spl.SumbaChat.media-upload-path")
    private static var latestPath: NWPath?
    private static var didStartMonitor = false

    public static func startMonitoringIfNeeded() {
        guard !didStartMonitor else { return }
        didStartMonitor = true
        pathMonitor.pathUpdateHandler = { path in
            latestPath = path
        }
        pathMonitor.start(queue: monitorQueue)
    }

    /// Legacy single-file API — prefers Low/Medium/High from package logic for one URL.
    @objc(compressionLevelForFileURL:)
    public static func compressionLevel(forFileURL fileURL: URL) -> MediaUploadCompressionLevel {
        let levels = compressionLevels(forFileURLs: [fileURL])
        return levels.first ?? .medium
    }

    /// Mildest per-item levels such that estimates ≤ X and sum ≤ Y; escalate largest first; High is best effort.
    public static func compressionLevels(forFileURLs fileURLs: [URL]) -> [MediaUploadCompressionLevel] {
        startMonitoringIfNeeded()
        let debug = MediaUploadDebugSettings.shared()
        let perFileCap = max(Int64(1024), debug.perFileMaxBytes)
        let packageCap = max(perFileCap, debug.packageMaxBytes)

        var levels: [MediaUploadCompressionLevel] = fileURLs.map { url in
            let ext = url.pathExtension.lowercased()
            let isMedia = NCUtils.isImage(fileExtension: ext) || MediaUploadPreprocessor.isVideo(fileExtension: ext)
            return isMedia ? .low : .none
        }

        func estimate(at index: Int) -> Int64 {
            let url = fileURLs[index]
            let level = levels[index]
            if level == .none {
                return MediaUploadPreprocessor.fileSizePublic(at: url)
            }
            return MediaUploadPreprocessor.estimatedByteCount(at: url, level: level)
        }

        func escalate(_ index: Int) -> Bool {
            switch levels[index] {
            case .low:
                levels[index] = .medium
                return true
            case .medium:
                levels[index] = .high
                return true
            default:
                return false
            }
        }

        // Per-file cap X.
        var changed = true
        while changed {
            changed = false
            for i in fileURLs.indices where levels[i] != .none {
                if estimate(at: i) > perFileCap, escalate(i) {
                    changed = true
                }
            }
        }

        // Package cap Y wins — escalate largest compressible items.
        while true {
            let estimates = fileURLs.indices.map { estimate(at: $0) }
            let total = estimates.reduce(Int64(0), +)
            if total <= packageCap { break }

            var bestIndex: Int?
            var bestSize: Int64 = -1
            for i in fileURLs.indices where levels[i] != .none && levels[i] != .high {
                if estimates[i] > bestSize {
                    bestSize = estimates[i]
                    bestIndex = i
                }
            }
            guard let index = bestIndex, escalate(index) else { break }
        }

        // Cellular nudge: if still on Low for a large item, prefer Medium.
        let path = latestPath
        let isConstrainedCellular = path?.isExpensive == true || path?.isConstrained == true
            || path?.usesInterfaceType(.cellular) == true
        if isConstrainedCellular {
            for i in fileURLs.indices where levels[i] == .low {
                let original = MediaUploadPreprocessor.fileSizePublic(at: fileURLs[i])
                if original > MediaUploadCompressionSettings.automaticCellularEscalateBytes {
                    levels[i] = .medium
                }
            }
        }

        for (url, level) in zip(fileURLs, levels) {
            NCLog.log("MediaUploadAutomaticPolicy: \(url.lastPathComponent) → \(level.rawValue) (X=\(perFileCap) Y=\(packageCap))")
        }
        return levels
    }
}

/// Cancels in-flight video exports / writer sessions when the user dismisses Send/prepare.
@objcMembers public final class MediaUploadPreparationToken: NSObject {
    private let lock = NSLock()
    private var exportSession: AVAssetExportSession?
    private var writerCancel: (() -> Void)?
    public private(set) var isCancelled = false

    @objc public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        exportSession?.cancelExport()
        writerCancel?()
    }

    func attach(_ session: AVAssetExportSession) {
        lock.lock()
        defer { lock.unlock() }
        exportSession = session
        if isCancelled {
            session.cancelExport()
        }
    }

    func attachWriterCancel(_ block: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        writerCancel = block
        if isCancelled {
            block()
        }
    }
}

/// Compresses photos and videos before they are uploaded.
@objcMembers public class MediaUploadPreprocessor: NSObject {

    @objc(compressImageAtURL:toDestinationURL:settings:)
    public static func compressImage(at sourceURL: URL,
                                     toDestinationURL destinationURL: URL,
                                     settings: MediaUploadCompressionSettings) -> Bool {
        let fileExtension = sourceURL.pathExtension.lowercased()

        if fileExtension == "gif" || !settings.shouldCompressImages {
            return false
        }

        guard let image = previewImage(at: sourceURL, maxDimension: settings.imageMaxDimension)
                ?? UIImage(contentsOfFile: sourceURL.path) else {
            NCLog.log("MediaUploadPreprocessor: failed to decode image for compression at \(sourceURL.lastPathComponent)")
            return false
        }

        guard let jpegData = compressedJPEGData(from: image, settings: settings), !jpegData.isEmpty else {
            NCLog.log("MediaUploadPreprocessor: JPEG encode produced empty data for \(sourceURL.lastPathComponent)")
            return false
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path
        let destinationIsSource = sourcePath == destinationPath

        do {
            if !destinationIsSource, FileManager.default.fileExists(atPath: destinationPath) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try jpegData.write(to: destinationURL, options: .atomic)

            let written = fileSize(at: destinationURL)
            guard written > 0 else {
                NCLog.log("MediaUploadPreprocessor: compressed image write left 0-byte file")
                if !destinationIsSource {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                return false
            }

            NCLog.log(String(format:
                "MediaUploadPreprocessor: image ACTUAL %@ %lld (%.2f MB) → %lld (%.2f MB) q=%.2f maxEdge=%.0f",
                sourceURL.lastPathComponent,
                fileSize(at: sourceURL),
                Double(fileSize(at: sourceURL)) / 1_048_576.0,
                written,
                Double(written) / 1_048_576.0,
                settings.imageJPEGQuality,
                settings.imageMaxDimension))
            return true
        } catch {
            NCLog.log("MediaUploadPreprocessor: failed to write compressed image: \(error.localizedDescription)")
            return false
        }
    }

    @objc(compressedJPEGDataFromImage:settings:)
    public static func compressedJPEGData(from image: UIImage, settings: MediaUploadCompressionSettings) -> Data? {
        let resizedImage = settings.shouldCompressImages
            ? resizeImageIfNeeded(image, maxDimension: settings.imageMaxDimension)
            : image
        let quality = settings.shouldCompressImages ? settings.imageJPEGQuality : 1
        return resizedImage.jpegData(compressionQuality: quality)
    }

    @objc(isVideoFileExtension:)
    public static func isVideo(fileExtension: String) -> Bool {
        guard let fileType = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return fileType.conforms(to: .movie)
    }

    @objc(compressVideoAtURL:toDestinationURL:settings:cancelToken:progress:completion:)
    public static func compressVideo(at sourceURL: URL,
                                     toDestinationURL destinationURL: URL,
                                     settings: MediaUploadCompressionSettings,
                                     cancelToken: MediaUploadPreparationToken?,
                                     progress: ((Float) -> Void)?,
                                     completion: @escaping (Bool) -> Void) {
        if cancelToken?.isCancelled == true {
            completion(false)
            return
        }

        guard settings.shouldCompressVideos else {
            completion(false)
            return
        }

        let debug = MediaUploadDebugSettings.shared()
        if debug.usesAssetWriter, let profile = settings.profile {
            MediaUploadVideoWriter.compress(at: sourceURL,
                                            toDestinationURL: destinationURL,
                                            profile: profile,
                                            cancelToken: cancelToken,
                                            progress: progress) { success in
                if success {
                    completion(true)
                    return
                }
                if cancelToken?.isCancelled == true {
                    completion(false)
                    return
                }
                NCLog.log("MediaUploadPreprocessor: Writer failed — falling back to ExportSession")
                compressVideoWithExportSession(at: sourceURL,
                                               toDestinationURL: destinationURL,
                                               settings: settings,
                                               cancelToken: cancelToken,
                                               progress: progress,
                                               completion: completion)
            }
            return
        }

        compressVideoWithExportSession(at: sourceURL,
                                       toDestinationURL: destinationURL,
                                       settings: settings,
                                       cancelToken: cancelToken,
                                       progress: progress,
                                       completion: completion)
    }

    private static func compressVideoWithExportSession(at sourceURL: URL,
                                                       toDestinationURL destinationURL: URL,
                                                       settings: MediaUploadCompressionSettings,
                                                       cancelToken: MediaUploadPreparationToken?,
                                                       progress: ((Float) -> Void)?,
                                                       completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: settings.avVideoPreset) else {
            NCLog.log("MediaUploadPreprocessor: unable to create export session")
            completion(false)
            return
        }

        cancelToken?.attach(exportSession)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        var progressTimer: Timer?
        if progress != nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                progress?(exportSession.progress)
                if exportSession.status != .waiting && exportSession.status != .exporting {
                    timer.invalidate()
                }
            }
            progressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                progressTimer?.invalidate()
                progress?(exportSession.progress)

                if cancelToken?.isCancelled == true || exportSession.status == .cancelled {
                    try? FileManager.default.removeItem(at: destinationURL)
                    NCLog.log("MediaUploadPreprocessor: video export cancelled")
                    completion(false)
                    return
                }

                switch exportSession.status {
                case .completed:
                    let sourceSize = fileSize(at: sourceURL)
                    let compressedSize = fileSize(at: destinationURL)

                    guard compressedSize > 0, sourceSize == 0 || compressedSize < sourceSize else {
                        try? FileManager.default.removeItem(at: destinationURL)
                        NCLog.log("MediaUploadPreprocessor: compressed video was not smaller; using original")
                        completion(false)
                        return
                    }

                    let duration = CMTimeGetSeconds(asset.duration)
                    let srcMbps = duration > 0 ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: sourceSize, durationSeconds: duration) : 0
                    let outMbps = duration > 0 ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: compressedSize, durationSeconds: duration) : 0
                    NCLog.log(String(format:
                        "MediaUploadPreprocessor: ExportSession ACTUAL %@ %lld (%.2f MB, %.3fMbps) → %lld (%.2f MB, %.3fMbps) preset=%@",
                        sourceURL.lastPathComponent,
                        sourceSize, Double(sourceSize) / 1_048_576.0, srcMbps,
                        compressedSize, Double(compressedSize) / 1_048_576.0, outMbps,
                        settings.videoPreset))
                    completion(true)
                case .failed, .cancelled:
                    NCLog.log("MediaUploadPreprocessor: video export failed: \(exportSession.error?.localizedDescription ?? "unknown error")")
                    completion(false)
                default:
                    completion(false)
                }
            }
        }
    }

    @objc(estimatedByteCountAtURL:level:)
    public static func estimatedByteCount(at fileURL: URL, level: MediaUploadCompressionLevel) -> Int64 {
        let counts = cheapEstimatedByteCounts(at: fileURL)
        switch level {
        case .none:
            return counts.none
        case .low:
            return counts.low
        case .medium:
            return counts.medium
        case .high:
            return counts.high
        @unknown default:
            return counts.none
        }
    }

    public struct LevelEstimates {
        public var none: Int64
        public var low: Int64
        public var medium: Int64
        public var high: Int64
    }

    /// Share Extension–safe chip labels.
    public static func cheapEstimatedByteCounts(at fileURL: URL, treatAsImage: Bool? = nil) -> LevelEstimates {
        let extensionName = fileURL.pathExtension.lowercased()
        let originalSize = fileSize(at: fileURL)
        let none = originalSize
        let debug = MediaUploadDebugSettings.shared()

        let looksLikeImage = treatAsImage ?? NCUtils.isImage(fileExtension: extensionName)
        if looksLikeImage {
            if extensionName == "gif" {
                return LevelEstimates(none: none, low: none, medium: none, high: none)
            }
            let low = min(heuristicCompressedByteCount(originalSize: originalSize, level: .low), none)
            let medium = min(heuristicCompressedByteCount(originalSize: originalSize, level: .medium), low)
            let high = min(heuristicCompressedByteCount(originalSize: originalSize, level: .high), medium)
            return LevelEstimates(none: none, low: low, medium: medium, high: high)
        }

        if isVideo(fileExtension: extensionName) {
            let duration = videoDurationSeconds(at: fileURL)
            let lowP = debug.low
            let medP = debug.medium
            let highP = debug.high
            let low: Int64
            let medium: Int64
            let high: Int64
            if let duration, duration > 0 {
                low = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL, profile: lowP, durationSeconds: duration, originalSize: originalSize)
                medium = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL, profile: medP, durationSeconds: duration, originalSize: originalSize)
                high = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL, profile: highP, durationSeconds: duration, originalSize: originalSize)
            } else {
                low = heuristicCompressedByteCount(originalSize: originalSize, level: .low)
                medium = heuristicCompressedByteCount(originalSize: originalSize, level: .medium)
                high = heuristicCompressedByteCount(originalSize: originalSize, level: .high)
            }
            return LevelEstimates(none: none,
                                  low: min(low, none),
                                  medium: min(medium, min(low, none)),
                                  high: min(high, min(medium, min(low, none))))
        }

        return LevelEstimates(none: none, low: none, medium: none, high: none)
    }

    public static func cheapEstimatedByteCounts(forFileURLs fileURLs: [URL]) -> LevelEstimates {
        var none: Int64 = 0
        var low: Int64 = 0
        var medium: Int64 = 0
        var high: Int64 = 0
        for url in fileURLs {
            let counts = cheapEstimatedByteCounts(at: url)
            // Match Send: skip items that would not shrink at that level → count original size.
            let lowBytes = MediaUploadDebugSettings.itemCompressionLikelyShrinks(at: url, level: .low)
                ? counts.low : counts.none
            let mediumBytes = MediaUploadDebugSettings.itemCompressionLikelyShrinks(at: url, level: .medium)
                ? counts.medium : counts.none
            let highBytes = MediaUploadDebugSettings.itemCompressionLikelyShrinks(at: url, level: .high)
                ? counts.high : counts.none

            var itemLow = min(lowBytes, counts.none)
            var itemMedium = min(mediumBytes, itemLow)
            var itemHigh = min(highBytes, itemMedium)

            none += counts.none
            low += itemLow
            medium += itemMedium
            high += itemHigh
        }
        return LevelEstimates(none: none, low: low, medium: medium, high: high)
    }

    private static func heuristicCompressedByteCount(originalSize: Int64, level: MediaUploadCompressionLevel) -> Int64 {
        guard originalSize > 0 else { return 0 }
        let debug = MediaUploadDebugSettings.shared()
        let factor: Double
        switch level {
        case .none:
            return originalSize
        case .low:
            factor = Double(debug.low.imageJPEGQuality) / 100.0 * 0.85
        case .medium:
            factor = Double(debug.medium.imageJPEGQuality) / 100.0 * 0.75
        case .high:
            factor = Double(debug.high.imageJPEGQuality) / 100.0 * 0.65
        @unknown default:
            return originalSize
        }
        return max(12_288, Int64(Double(originalSize) * min(0.95, max(0.05, factor))))
    }

    @objc(formattedByteCount:)
    public static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: byteCount)
    }

    @objc(previewImageAtURL:maxDimension:)
    public static func previewImage(at fileURL: URL, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: fileURL.path)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: fileURL.path)
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private static func videoDurationSeconds(at fileURL: URL) -> Double? {
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
        guard duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private static func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixels = pixelSize(of: image)
        let largestSide = max(pixels.width, pixels.height)

        guard largestSide > maxDimension else {
            return image
        }

        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: pixels.width * scale, height: pixels.height * scale)

        return NCUtils.renderAspectImage(image: image, ofSize: targetSize, scale: 1.0, centerImage: false) ?? image
    }

    fileprivate static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Public for Writer / Automatic policy.
    @objc(fileSizePublicAtURL:)
    public static func fileSizePublic(at url: URL) -> Int64 {
        fileSize(at: url)
    }
}
