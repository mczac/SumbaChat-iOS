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
@objc public enum MediaUploadCompressionLevel: Int {
    case none = 0
    case moderate = 1
    case high = 2
}

@objcMembers public final class MediaUploadCompressionSettings: NSObject {

    public static let defaultImageMaxDimension = 1280
    public static let defaultImageJPEGQuality = 45
    public static let defaultVideoPreset = "low"

    public static let moderateImageMaxDimension = 1920
    public static let moderateImageJPEGQuality = 80
    public static let moderateVideoPreset = "720p"

    public static let highImageMaxDimension = 1280
    public static let highImageJPEGQuality = 45
    public static let highVideoPreset = "low"

    public static let automaticMaxBytes: Int64 = 16 * 1024 * 1024
    public static let automaticCellularEscalateBytes: Int64 = 8 * 1024 * 1024

    public let enabled: Bool
    public let imageEnabled: Bool
    public let imageMaxDimension: CGFloat
    public let imageJPEGQuality: CGFloat
    public let videoEnabled: Bool
    public let videoPreset: String

    public override convenience init() {
        self.init(level: .high)
    }

    @objc(initWithLevel:)
    public convenience init(level: MediaUploadCompressionLevel) {
        switch level {
        case .none:
            self.init(enabled: false,
                      imageEnabled: false,
                      imageMaxDimension: Self.defaultImageMaxDimension,
                      imageJPEGQuality: 100,
                      videoEnabled: false,
                      videoPreset: Self.defaultVideoPreset)
        case .moderate:
            self.init(enabled: true,
                      imageEnabled: true,
                      imageMaxDimension: Self.moderateImageMaxDimension,
                      imageJPEGQuality: Self.moderateImageJPEGQuality,
                      videoEnabled: true,
                      videoPreset: Self.moderateVideoPreset)
        case .high:
            self.init(enabled: true,
                      imageEnabled: true,
                      imageMaxDimension: Self.highImageMaxDimension,
                      imageJPEGQuality: Self.highImageJPEGQuality,
                      videoEnabled: true,
                      videoPreset: Self.highVideoPreset)
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
                videoPreset: String) {
        self.enabled = enabled
        self.imageEnabled = imageEnabled
        self.imageMaxDimension = CGFloat(Self.validImageMaxDimension(imageMaxDimension))
        self.imageJPEGQuality = CGFloat(Self.validImageJPEGQuality(imageJPEGQuality)) / 100
        self.videoEnabled = videoEnabled
        self.videoPreset = Self.validVideoPreset(videoPreset)
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
        guard (10...100).contains(value) else {
            return defaultImageJPEGQuality
        }
        return value
    }

    private static func validVideoPreset(_ value: String) -> String {
        let supportedPresets = ["low", "medium", "high", "480p", "720p", "1080p", "2160p"]
        return supportedPresets.contains(value) ? value : defaultVideoPreset
    }
}

/// Resolves Automatic compression to Moderate or High. Always compresses (never None).
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

    @objc(compressionLevelForFileURL:)
    public static func compressionLevel(forFileURL fileURL: URL) -> MediaUploadCompressionLevel {
        startMonitoringIfNeeded()

        // Use on-disk size only. A full JPEG simulate-encode here used to run on the main
        // thread during Send (Automatic), which can jetsam the app on large HEIC/photos —
        // especially noticeable on iOS 18 / lower-RAM devices. Escalation thresholds still
        // work well against original bytes.
        let originalBytes = MediaUploadPreprocessor.fileSize(at: fileURL)
        let path = latestPath
        let isConstrainedCellular = path?.isExpensive == true || path?.isConstrained == true
            || path?.usesInterfaceType(.cellular) == true

        if originalBytes > MediaUploadCompressionSettings.automaticMaxBytes {
            NCLog.log("MediaUploadAutomaticPolicy: \(fileURL.lastPathComponent) → High (\(originalBytes) bytes > 16 MB)")
            return .high
        }

        if isConstrainedCellular && originalBytes > MediaUploadCompressionSettings.automaticCellularEscalateBytes {
            NCLog.log("MediaUploadAutomaticPolicy: \(fileURL.lastPathComponent) → High (cellular, \(originalBytes) bytes)")
            return .high
        }

        NCLog.log("MediaUploadAutomaticPolicy: \(fileURL.lastPathComponent) → Moderate (\(originalBytes) bytes)")
        return .moderate
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

        // Downsample via ImageIO to the target max dimension — never decode full-resolution
        // HEIC/JPEG into memory (UIImage(contentsOfFile:) jetsams on large camera photos).
        guard let image = previewImage(at: sourceURL, maxDimension: settings.imageMaxDimension)
                ?? UIImage(contentsOfFile: sourceURL.path) else {
            NCLog.log("MediaUploadPreprocessor: failed to decode image for compression at \(sourceURL.lastPathComponent)")
            return false
        }

        guard let jpegData = compressedJPEGData(from: image, settings: settings), !jpegData.isEmpty else {
            NCLog.log("MediaUploadPreprocessor: JPEG encode produced empty data for \(sourceURL.lastPathComponent)")
            return false
        }

        // Never delete the source if destination is the same path.
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

            NCLog.log("MediaUploadPreprocessor: compressed image \(sourceURL.lastPathComponent) (\(fileSize(at: sourceURL)) → \(written) bytes)")
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

    @objc(compressVideoAtURL:toDestinationURL:settings:progress:completion:)
    public static func compressVideo(at sourceURL: URL,
                                     toDestinationURL destinationURL: URL,
                                     settings: MediaUploadCompressionSettings,
                                     progress: ((Float) -> Void)?,
                                     completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: sourceURL)

        guard settings.shouldCompressVideos else {
            completion(false)
            return
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: settings.avVideoPreset) else {
            NCLog.log("MediaUploadPreprocessor: unable to create export session")
            completion(false)
            return
        }

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

                    NCLog.log("MediaUploadPreprocessor: compressed video from \(sourceSize) to \(compressedSize) bytes")
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
        let counts = estimatedByteCounts(at: fileURL, treatAsImage: nil)
        switch level {
        case .none:
            return counts.none
        case .moderate:
            return counts.moderate
        case .high:
            return counts.high
        @unknown default:
            return counts.none
        }
    }

    /// Per-level size estimates for one file. Image levels share one decode so chips stay consistent and ordered.
    public static func estimatedByteCounts(at fileURL: URL, treatAsImage: Bool? = nil) -> (none: Int64, moderate: Int64, high: Int64) {
        let extensionName = fileURL.pathExtension.lowercased()
        let originalSize = fileSize(at: fileURL)
        let none = originalSize

        let looksLikeImage = treatAsImage ?? NCUtils.isImage(fileExtension: extensionName)
        if looksLikeImage {
            if extensionName == "gif" {
                return (none, none, none)
            }
            return estimatedImageByteCounts(at: fileURL, originalSize: originalSize)
        }

        if isVideo(fileExtension: extensionName) {
            let moderate = estimatedVideoByteCount(at: fileURL, level: .moderate, originalSize: originalSize)
            let high = estimatedVideoByteCount(at: fileURL, level: .high, originalSize: originalSize)
            return (none, moderate, min(high, moderate))
        }

        return (none, none, none)
    }

    private static func estimatedImageByteCounts(at fileURL: URL, originalSize: Int64) -> (none: Int64, moderate: Int64, high: Int64) {
        let none = originalSize

        // Decode once at the largest target; each level then resizes/encodes with its own preset.
        let sourceImage = previewImage(at: fileURL, maxDimension: CGFloat(MediaUploadCompressionSettings.moderateImageMaxDimension))
            ?? UIImage(contentsOfFile: fileURL.path)

        guard let sourceImage else {
            return (
                none,
                heuristicCompressedByteCount(originalSize: originalSize, level: .moderate),
                heuristicCompressedByteCount(originalSize: originalSize, level: .high)
            )
        }

        let moderateSettings = MediaUploadCompressionSettings(level: .moderate)
        let highSettings = MediaUploadCompressionSettings(level: .high)

        let moderateEncoded = compressedJPEGData(from: sourceImage, settings: moderateSettings).map { Int64($0.count) }
        let highEncoded = compressedJPEGData(from: sourceImage, settings: highSettings).map { Int64($0.count) }

        let moderate = min(
            moderateEncoded ?? heuristicCompressedByteCount(originalSize: originalSize, level: .moderate),
            none
        )
        // High must stay ≤ Moderate so the three chips read as a clear quality ladder.
        let high = min(
            highEncoded ?? heuristicCompressedByteCount(originalSize: originalSize, level: .high),
            moderate
        )

        return (none, moderate, high)
    }

    /// Last-resort differentiated sizes when decode/encode fails (keeps chips from looking identical).
    private static func heuristicCompressedByteCount(originalSize: Int64, level: MediaUploadCompressionLevel) -> Int64 {
        guard originalSize > 0 else { return 0 }
        let factor: Double
        switch level {
        case .none:
            return originalSize
        case .moderate:
            factor = 0.62
        case .high:
            factor = 0.22
        @unknown default:
            return originalSize
        }
        return max(12_288, Int64(Double(originalSize) * factor))
    }

    @objc(formattedByteCount:)
    public static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: byteCount)
    }

    /// Loads a downsampled image suitable for preview/crop without decoding the full original into memory.
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

    private static func estimatedVideoByteCount(at fileURL: URL, level: MediaUploadCompressionLevel, originalSize: Int64) -> Int64 {
        let asset = AVURLAsset(url: fileURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else {
            return originalSize
        }

        // Approximate average video bitrates for export presets (bits/sec), plus AAC audio.
        let videoBitsPerSecond: Double
        switch level {
        case .none:
            return originalSize
        case .moderate:
            videoBitsPerSecond = 2_500_000
        case .high:
            videoBitsPerSecond = 800_000
        @unknown default:
            return originalSize
        }
        let audioBitsPerSecond = 128_000.0
        let estimated = Int64((videoBitsPerSecond + audioBitsPerSecond) * duration / 8.0)
        return min(estimated, originalSize)
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
}
