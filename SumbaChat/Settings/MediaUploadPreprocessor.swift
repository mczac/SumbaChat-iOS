//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// User preference for how media is compressed before upload.
@objc public enum MediaUploadMode: Int {
    case noCompression = 0
    case automatic = 1
    case chooseOnUpload = 2
}

/// Compression strength for Choose on upload, or the level Automatic resolved to.
@objc public enum MediaUploadCompressionLevel: Int {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    /// Older name for `.medium` (kept for callers that still use it).
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
        self.init(level: level, videoMaxEdgeCap: 0)
    }

    /// - Parameter videoMaxEdgeCap: When > 0, Writer encode edge is min(profile, cap). Used for multi-video batches.
    @objc(initWithLevel:videoMaxEdgeCap:)
    public convenience init(level: MediaUploadCompressionLevel, videoMaxEdgeCap: Int) {
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
            var profile = debug.profile(for: level) ?? .defaultMedium
            if videoMaxEdgeCap > 0 {
                profile = profile.cappingVideoMaxEdge(videoMaxEdgeCap)
            }
            self.init(enabled: true,
                      imageEnabled: true,
                      imageMaxDimension: profile.imageMaxDimension,
                      imageJPEGQuality: profile.imageJPEGQuality,
                      videoEnabled: true,
                      videoPreset: profile.exportPreset,
                      profile: profile)
        }
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

/// Per-file Automatic picker (no package/bag size). Bag limit is selection count only (10).
///
/// Quality ladder (our Low = highest quality / mildest shrink):
/// 1. High quality (Low) if estimate stays under cap after estimate-error margin
/// 2. else Medium if estimate stays under cap after margin
/// 3. else Low quality (High compression)
///
/// Margin (Settings debug): photos default 20%, videos 10%.
/// Accept level when `estimate × (1 + margin/100) < max file size`.
@objcMembers public final class MediaUploadAutomaticPolicy: NSObject {

    public static func startMonitoringIfNeeded() {
        // Kept for call sites; Automatic no longer watches network path.
    }

    /// Legacy single-file API.
    @objc(compressionLevelForFileURL:)
    public static func compressionLevel(forFileURL fileURL: URL) -> MediaUploadCompressionLevel {
        let levels = compressionLevels(forFileURLs: [fileURL])
        return levels.first ?? .medium
    }

    /// Max compressed size for Automatic (default 16 MB; Settings “Automatic max file size”).
    public static var automaticFileMaxBytes: Int64 {
        max(Int64(1024 * 1024), MediaUploadDebugSettings.shared().perFileMaxBytes)
    }

    /// Effective ceiling used when comparing estimates: `cap / (1 + margin/100)`.
    public static func estimateAcceptanceCeilingBytes(fileCap: Int64, marginPercent: Double) -> Int64 {
        let margin = MediaUploadDebugSettings.clampedMarginPercent(marginPercent)
        let divisor = 1.0 + margin / 100.0
        guard divisor > 1.0 else { return fileCap }
        return Int64(Double(fileCap) / divisor)
    }

    /// True when `estimate × (1 + margin/100) < fileCap`.
    public static func estimateFitsUnderCap(_ estimateBytes: Int64, fileCap: Int64, marginPercent: Double) -> Bool {
        guard estimateBytes > 0, fileCap > 0 else { return false }
        let ceiling = estimateAcceptanceCeilingBytes(fileCap: fileCap, marginPercent: marginPercent)
        return estimateBytes < ceiling
    }

    public static func compressionLevels(forFileURLs fileURLs: [URL]) -> [MediaUploadCompressionLevel] {
        let debug = MediaUploadDebugSettings.shared()
        let fileCap = automaticFileMaxBytes
        let photoMargin = debug.automaticPhotoEstimateMarginPercent
        let videoMargin = debug.automaticVideoEstimateMarginPercent

        return fileURLs.map { url in
            let ext = url.pathExtension.lowercased()
            let isImage = NCUtils.isImage(fileExtension: ext)
            let isVideo = MediaUploadPreprocessor.isVideo(fileExtension: ext)
            guard isImage || isVideo else {
                NCLog.log("MediaUploadAutomaticPolicy: \(url.lastPathComponent) → none (non-media)")
                return .none
            }

            let margin = isVideo ? videoMargin : photoMargin
            let ceiling = estimateAcceptanceCeilingBytes(fileCap: fileCap, marginPercent: margin)
            let original = MediaUploadPreprocessor.fileSizePublic(at: url)
            let kind = isVideo ? "video" : "photo"

            // Ladder: No Compression → Low → Medium → High (first that fits under cap; High last resort).
            if estimateFitsUnderCap(original, fileCap: fileCap, marginPercent: margin) {
                MediaUploadTrace.log(String(format:
                    "AUTO %@ %@ original=%@ → none (original < ceiling=%@; cap=%@ margin=%.0f%%)",
                    kind, url.lastPathComponent,
                    MediaUploadTrace.mb(original),
                    MediaUploadTrace.mb(ceiling),
                    MediaUploadTrace.mb(fileCap),
                    margin))
                return .none
            }

            let lowBytes = MediaUploadPreprocessor.estimatedByteCount(at: url, level: .low)
            if estimateFitsUnderCap(lowBytes, fileCap: fileCap, marginPercent: margin) {
                MediaUploadTrace.log(String(format:
                    "AUTO %@ %@ original=%@ → %@ (est=%@ < ceiling=%@; cap=%@ margin=%.0f%%)",
                    kind, url.lastPathComponent,
                    MediaUploadTrace.mb(original),
                    MediaUploadTrace.levelName(.low),
                    MediaUploadTrace.mb(lowBytes),
                    MediaUploadTrace.mb(ceiling),
                    MediaUploadTrace.mb(fileCap),
                    margin))
                return .low
            }

            let mediumBytes = MediaUploadPreprocessor.estimatedByteCount(at: url, level: .medium)
            if estimateFitsUnderCap(mediumBytes, fileCap: fileCap, marginPercent: margin) {
                MediaUploadTrace.log(String(format:
                    "AUTO %@ %@ original=%@ → %@ (est=%@ < ceiling=%@; cap=%@ margin=%.0f%%)",
                    kind, url.lastPathComponent,
                    MediaUploadTrace.mb(original),
                    MediaUploadTrace.levelName(.medium),
                    MediaUploadTrace.mb(mediumBytes),
                    MediaUploadTrace.mb(ceiling),
                    MediaUploadTrace.mb(fileCap),
                    margin))
                return .medium
            }

            let highBytes = MediaUploadPreprocessor.estimatedByteCount(at: url, level: .high)
            MediaUploadTrace.log(String(format:
                "AUTO %@ %@ original=%@ → %@ (est=%@; ceiling=%@; cap=%@ margin=%.0f%%) last-resort",
                kind, url.lastPathComponent,
                MediaUploadTrace.mb(original),
                MediaUploadTrace.levelName(.high),
                MediaUploadTrace.mb(highBytes),
                MediaUploadTrace.mb(ceiling),
                MediaUploadTrace.mb(fileCap),
                margin))
            return .high
        }
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

    /// Drop the finished session so mediaserverd can reclaim before the next encode.
    func clearExportSession() {
        lock.lock()
        defer { lock.unlock() }
        exportSession = nil
        writerCancel = nil
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

    /// Legacy flag: when YES, compressVideo uses ExportSession even if Settings = Writer.
    /// Multi-video Bitrate sends no longer set this (serial Writer + edge cap).
    @objc public static var preferExportSession = false

    /// One export at a time; asset/session created here — never on the main thread.
    private static let exportQueue = DispatchQueue(label: "com.spl.SumbaChat.media-upload-export", qos: .userInitiated)
    @objc(compressImageAtURL:toDestinationURL:settings:)
    public static func compressImage(at sourceURL: URL,
                                     toDestinationURL destinationURL: URL,
                                     settings: MediaUploadCompressionSettings) -> Bool {
        let fileExtension = sourceURL.pathExtension.lowercased()

        if fileExtension == "gif" || !settings.shouldCompressImages {
            return false
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path
        // Case-insensitive volumes treat IMG.JPG and IMG.jpg as one file — string == is not enough.
        let destinationIsSource = Self.isSameLocalFile(sourceURL, destinationURL)

        let fm = FileManager.default
        // ImageIO finalize is non-atomic — always write a sibling temp then replace.
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(destinationURL.lastPathComponent)")

        do {
            // Prefer ImageIO downsample → JPEG (orientation baked in; GPS + capture dates preserved).
            let wroteImageIO = writeDownsampledJPEG(from: sourceURL,
                                                    to: tempURL,
                                                    maxDimension: settings.imageMaxDimension,
                                                    quality: settings.imageJPEGQuality)
            let encodePath: String
            if wroteImageIO {
                encodePath = "ImageIO"
            } else {
                try? fm.removeItem(at: tempURL)
                MediaUploadTrace.log("ENCODE image fallback jpegData \(sourceURL.lastPathComponent)")
                guard let image = previewImage(at: sourceURL, maxDimension: settings.imageMaxDimension)
                        ?? UIImage(contentsOfFile: sourceURL.path) else {
                    NCLog.log("MediaUploadPreprocessor: failed to decode image for compression at \(sourceURL.lastPathComponent)")
                    return false
                }
                // Prefer ImageIO so we can re-attach GPS / capture dates from the source file.
                if writeJPEG(from: image,
                             preservingMetadataFrom: sourceURL,
                             to: tempURL,
                             quality: settings.imageJPEGQuality) {
                    encodePath = "UIImage+ImageIO"
                } else {
                    guard let jpegData = compressedJPEGData(from: image, settings: settings), !jpegData.isEmpty else {
                        NCLog.log("MediaUploadPreprocessor: JPEG encode produced empty data for \(sourceURL.lastPathComponent)")
                        return false
                    }
                    try jpegData.write(to: tempURL, options: .atomic)
                    encodePath = "jpegData"
                }
            }

            let written = fileSize(at: tempURL)
            guard written > 0 else {
                NCLog.log("MediaUploadPreprocessor: compressed image write left 0-byte file")
                try? fm.removeItem(at: tempURL)
                return false
            }

            if destinationIsSource {
                // Same inode (incl. IMG.JPG vs IMG.jpg) — swap via backup then move temp into place.
                let backupURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).bak.\(destinationURL.lastPathComponent)")
                if fm.fileExists(atPath: destinationPath) || fm.fileExists(atPath: sourcePath) {
                    MediaUploadDiskStore.removeItemAllowingCaseVariants(at: backupURL)
                    try fm.moveItem(at: sourceURL, to: backupURL)
                }
                do {
                    try fm.moveItem(at: tempURL, to: destinationURL)
                    try? fm.removeItem(at: backupURL)
                } catch {
                    try? fm.removeItem(at: tempURL)
                    if fm.fileExists(atPath: backupURL.path) {
                        MediaUploadDiskStore.removeItemAllowingCaseVariants(at: destinationURL)
                        try? fm.moveItem(at: backupURL, to: destinationURL)
                    }
                    throw error
                }
            } else {
                MediaUploadDiskStore.removeItemAllowingCaseVariants(at: destinationURL)
                try fm.moveItem(at: tempURL, to: destinationURL)
            }

            let sourceSize = fileSize(at: sourceURL)
            MediaUploadTrace.log(String(format:
                "ENCODE image ACTUAL %@ %@ → %@ path=%@ q=%.2f maxEdge=%.0f",
                sourceURL.lastPathComponent,
                MediaUploadTrace.mb(sourceSize),
                MediaUploadTrace.mb(written),
                encodePath,
                settings.imageJPEGQuality,
                settings.imageMaxDimension))
            return true
        } catch {
            try? fm.removeItem(at: tempURL)
            NCLog.log("MediaUploadPreprocessor: failed to write compressed image: \(error.localizedDescription)")
            return false
        }
    }

    /// True when both URLs resolve to the same file (inode), including case-only path variants.
    private static func isSameLocalFile(_ a: URL, _ b: URL) -> Bool {
        let aPath = a.standardizedFileURL.path
        let bPath = b.standardizedFileURL.path
        if aPath.compare(bPath, options: [.caseInsensitive]) == .orderedSame {
            return true
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: aPath), fm.fileExists(atPath: bPath),
              let aAttrs = try? fm.attributesOfItem(atPath: aPath),
              let bAttrs = try? fm.attributesOfItem(atPath: bPath),
              let aNum = aAttrs[.systemFileNumber] as? NSNumber,
              let bNum = bAttrs[.systemFileNumber] as? NSNumber,
              let aDev = aAttrs[.systemNumber] as? NSNumber,
              let bDev = bAttrs[.systemNumber] as? NSNumber else {
            return false
        }
        return aNum == bNum && aDev == bDev
    }

    /// ImageIO thumbnail + JPEG destination (orientation baked in; GPS + capture dates preserved).
    /// Caller must pass a temp URL — Finalize is not crash-atomic.
    private static func writeDownsampledJPEG(from sourceURL: URL,
                                             to destinationURL: URL,
                                             maxDimension: CGFloat,
                                             quality: CGFloat) -> Bool {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            return false
        }

        let maxPixel = max(320, Int(maxDimension.rounded()))
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return false
        }

        return finalizeJPEG(cgImage: cgImage,
                            source: source,
                            to: destinationURL,
                            quality: quality)
    }

    /// UIImage fallback that still copies GPS / capture dates from the original file when possible.
    private static func writeJPEG(from image: UIImage,
                                  preservingMetadataFrom sourceURL: URL,
                                  to destinationURL: URL,
                                  quality: CGFloat) -> Bool {
        let drawn: UIImage
        if image.imageOrientation == .up {
            drawn = image
        } else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = image.scale
            format.opaque = false
            drawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        guard let cgImage = drawn.cgImage else { return false }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
            return false
        }
        return finalizeJPEG(cgImage: cgImage,
                            source: source,
                            to: destinationURL,
                            quality: quality)
    }

    private static func finalizeJPEG(cgImage: CGImage,
                                     source: CGImageSource,
                                     to destinationURL: URL,
                                     quality: CGFloat) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }

        let q = min(1, max(0.01, quality))
        let properties = jpegPropertiesPreservingCaptureMetadata(
            from: source,
            quality: q,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        if !ok {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        return ok
    }

    /// Keeps GPS and capture timestamps (plus light camera identity). Orientation is reset to `.up`
    /// because pixels are already transformed. Bulky MakerNote / XMP packets are not copied.
    private static func jpegPropertiesPreservingCaptureMetadata(from source: CGImageSource,
                                                                quality: CGFloat,
                                                                pixelWidth: Int,
                                                                pixelHeight: Int) -> [CFString: Any] {
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]

        guard let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return properties
        }

        if let gps = sourceProps[kCGImagePropertyGPSDictionary] {
            properties[kCGImagePropertyGPSDictionary] = gps
        }

        if let exif = sourceProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var outExif: [CFString: Any] = [:]
            let exifKeys: [CFString] = [
                kCGImagePropertyExifDateTimeOriginal,
                kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifSubsecTime,
                kCGImagePropertyExifSubsecTimeOriginal,
                kCGImagePropertyExifSubsecTimeDigitized,
                kCGImagePropertyExifOffsetTime,
                kCGImagePropertyExifOffsetTimeOriginal,
                kCGImagePropertyExifOffsetTimeDigitized
            ]
            for key in exifKeys {
                if let value = exif[key] {
                    outExif[key] = value
                }
            }
            outExif[kCGImagePropertyExifPixelXDimension] = pixelWidth
            outExif[kCGImagePropertyExifPixelYDimension] = pixelHeight
            if !outExif.isEmpty {
                properties[kCGImagePropertyExifDictionary] = outExif
            }
        }

        if let tiff = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var outTiff: [CFString: Any] = [:]
            let tiffKeys: [CFString] = [
                kCGImagePropertyTIFFDateTime,
                kCGImagePropertyTIFFMake,
                kCGImagePropertyTIFFModel
            ]
            for key in tiffKeys {
                if let value = tiff[key] {
                    outTiff[key] = value
                }
            }
            outTiff[kCGImagePropertyTIFFOrientation] = 1
            if !outTiff.isEmpty {
                properties[kCGImagePropertyTIFFDictionary] = outTiff
            }
        }

        if let iptc = sourceProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            var outIptc: [CFString: Any] = [:]
            let iptcKeys: [CFString] = [
                kCGImagePropertyIPTCDateCreated,
                kCGImagePropertyIPTCTimeCreated,
                kCGImagePropertyIPTCDigitalCreationDate,
                kCGImagePropertyIPTCDigitalCreationTime
            ]
            for key in iptcKeys {
                if let value = iptc[key] {
                    outIptc[key] = value
                }
            }
            if !outIptc.isEmpty {
                properties[kCGImagePropertyIPTCDictionary] = outIptc
            }
        }

        return properties
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
        // One process-wide encode at a time.
        MediaUploadVideoEncodeQueue.shared.enqueue { finished in
            let finish: (Bool) -> Void = { success in
                DispatchQueue.main.async {
                    completion(success)
                    // Release the global slot only after the caller has been notified.
                    finished()
                }
            }

            if cancelToken?.isCancelled == true {
                finish(false)
                return
            }

            guard settings.shouldCompressVideos else {
                finish(false)
                return
            }

            let debug = MediaUploadDebugSettings.shared()
            let useWriter = debug.usesAssetWriter && !preferExportSession
            if useWriter, let profile = settings.profile {
                MediaUploadTrace.log("ENCODE video path=Writer \(sourceURL.lastPathComponent)")
                MediaUploadVideoWriter.compress(at: sourceURL,
                                                toDestinationURL: destinationURL,
                                                profile: profile,
                                                cancelToken: cancelToken,
                                                progress: progress) { success in
                    if success {
                        finish(true)
                        return
                    }
                    if cancelToken?.isCancelled == true {
                        finish(false)
                        return
                    }
                    MediaUploadTrace.log("ENCODE video Writer→ExportSession fallback \(sourceURL.lastPathComponent)")
                    NCLog.log("MediaUploadPreprocessor: Writer failed — falling back to ExportSession")
                    compressVideoWithExportSession(at: sourceURL,
                                                   toDestinationURL: destinationURL,
                                                   settings: settings,
                                                   cancelToken: cancelToken,
                                                   progress: progress,
                                                   completion: finish)
                }
                return
            }

            if preferExportSession {
                MediaUploadTrace.log("ENCODE video path=ExportSession (prefer) \(sourceURL.lastPathComponent)")
                NCLog.log("MediaUploadPreprocessor: preferExportSession — \(sourceURL.lastPathComponent)")
            } else {
                MediaUploadTrace.log("ENCODE video path=ExportSession \(sourceURL.lastPathComponent)")
            }

            compressVideoWithExportSession(at: sourceURL,
                                           toDestinationURL: destinationURL,
                                           settings: settings,
                                           cancelToken: cancelToken,
                                           progress: progress,
                                           completion: finish)
        }
    }

    private static func compressVideoWithExportSession(at sourceURL: URL,
                                                       toDestinationURL destinationURL: URL,
                                                       settings: MediaUploadCompressionSettings,
                                                       cancelToken: MediaUploadPreparationToken?,
                                                       progress: ((Float) -> Void)?,
                                                       completion: @escaping (Bool) -> Void) {
        // Public pattern: serial OperationQueue / dedicated queue + full session release between
        // exports. Creating AVAssetExportSession on the main thread repeatedly correlated with
        // silent process death on the Nth file (avail RAM still multi-GB).
        let run: () -> Void = {
            autoreleasepool {
                if cancelToken?.isCancelled == true {
                    DispatchQueue.main.async { completion(false) }
                    return
                }

                let asset = AVURLAsset(url: sourceURL, options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: false
                ])
                let sourceHasAudio = MediaUploadVideoIntegrity.assetHasAudioTrack(at: sourceURL)

                guard let exportSession = AVAssetExportSession(asset: asset, presetName: settings.avVideoPreset) else {
                    NCLog.log("MediaUploadPreprocessor: unable to create export session")
                    DispatchQueue.main.async { completion(false) }
                    return
                }

                cancelToken?.attach(exportSession)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }

                exportSession.outputURL = destinationURL
                exportSession.outputFileType = .mp4
                exportSession.shouldOptimizeForNetworkUse = true
                // Default copies source metadata (incl. GPS / creation date).
                // Never use forSharing — that filter strips location.
                exportSession.metadataItemFilter = nil

                final class ProgressPollState: @unchecked Sendable {
                    var active = true
                }
                let pollState = ProgressPollState()
                if progress != nil {
                    exportQueue.async {
                        while pollState.active {
                            let fraction = exportSession.progress
                            DispatchQueue.main.async {
                                progress?(fraction)
                            }
                            let status = exportSession.status
                            if status != .waiting && status != .exporting {
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.25)
                        }
                    }
                }

                exportSession.exportAsynchronously {
                    pollState.active = false
                    let status = exportSession.status
                    let errorDescription = exportSession.error?.localizedDescription
                    let sourceSize = fileSize(at: sourceURL)
                    let compressedSize = fileSize(at: destinationURL)
                    let duration = CMTimeGetSeconds(asset.duration)
                    let presetName = settings.videoPreset
                    let sourceName = sourceURL.lastPathComponent

                    // Drop session refs before the next encode — mediaserverd needs a beat to reclaim.
                    cancelToken?.clearExportSession()
                    Thread.sleep(forTimeInterval: 0.45)
                    autoreleasepool { }

                    DispatchQueue.main.async {
                        progress?(1.0)

                        if cancelToken?.isCancelled == true || status == .cancelled {
                            try? FileManager.default.removeItem(at: destinationURL)
                            NCLog.log("MediaUploadPreprocessor: video export cancelled")
                            completion(false)
                            return
                        }

                        switch status {
                        case .completed:
                            guard compressedSize > 0, sourceSize == 0 || compressedSize < sourceSize else {
                                try? FileManager.default.removeItem(at: destinationURL)
                                MediaUploadTrace.log("ENCODE video keep-original \(sourceName) engine=ExportSession (not smaller)")
                                NCLog.log("MediaUploadPreprocessor: compressed video was not smaller; using original")
                                completion(false)
                                return
                            }
                            if sourceHasAudio,
                               !MediaUploadVideoIntegrity.outputHasAudioTrack(at: destinationURL) {
                                try? FileManager.default.removeItem(at: destinationURL)
                                MediaUploadTrace.log("ENCODE video FAIL \(sourceName) engine=ExportSession missing-audio")
                                NCLog.log("MediaUploadPreprocessor: ExportSession output missing audio track")
                                completion(false)
                                return
                            }

                            let srcMbps = duration > 0 ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: sourceSize, durationSeconds: duration) : 0
                            let outMbps = duration > 0 ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: compressedSize, durationSeconds: duration) : 0
                            MediaUploadTrace.logSync(String(format:
                                "ENCODE video ACTUAL %@ %@ (%.3fMbps) → %@ (%.3fMbps) engine=ExportSession preset=%@ audio=%@",
                                sourceName,
                                MediaUploadTrace.mb(sourceSize), srcMbps,
                                MediaUploadTrace.mb(compressedSize), outMbps,
                                presetName,
                                sourceHasAudio ? "yes" : "none"))
                            completion(true)
                        case .failed, .cancelled:
                            MediaUploadTrace.log("ENCODE video FAIL \(sourceName) engine=ExportSession \(errorDescription ?? "unknown")")
                            NCLog.log("MediaUploadPreprocessor: video export failed: \(errorDescription ?? "unknown error")")
                            try? FileManager.default.removeItem(at: destinationURL)
                            completion(false)
                        default:
                            try? FileManager.default.removeItem(at: destinationURL)
                            completion(false)
                        }
                    }
                }
            }
        }

        if Thread.isMainThread {
            exportQueue.async(execute: run)
        } else {
            run()
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

    /// Chip bag: label totals + enablement (any item that shrinks ≥10% enables that level).
    public struct BagCompressionEstimates {
        public var totals: LevelEstimates
        public var enabled: Set<MediaUploadCompressionLevel>
        public var perItem: [LevelEstimates]
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
            // Same resize + bpp model as shrink heuristic (not original×quality — that overstates High badly).
            let low = MediaUploadDebugSettings.estimatedImageBytes(at: fileURL, profile: debug.low, originalSize: originalSize)
            let medium = MediaUploadDebugSettings.estimatedImageBytes(at: fileURL, profile: debug.medium, originalSize: originalSize)
            let high = MediaUploadDebugSettings.estimatedImageBytes(at: fileURL, profile: debug.high, originalSize: originalSize)
            return LevelEstimates(none: none,
                                  low: min(low, none),
                                  medium: min(medium, min(low, none)),
                                  high: min(high, min(medium, min(low, none))))
        }

        if isVideo(fileExtension: extensionName) {
            // One AVAsset for duration + Low/Med/High Writer audio targets.
            let asset = AVURLAsset(url: fileURL)
            let duration = videoDurationSeconds(from: asset)
            let lowP = debug.low
            let medP = debug.medium
            let highP = debug.high
            let low: Int64
            let medium: Int64
            let high: Int64
            if let duration, duration > 0 {
                low = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL,
                                                                   profile: lowP,
                                                                   durationSeconds: duration,
                                                                   originalSize: originalSize,
                                                                   asset: asset)
                medium = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL,
                                                                      profile: medP,
                                                                      durationSeconds: duration,
                                                                      originalSize: originalSize,
                                                                      asset: asset)
                high = MediaUploadDebugSettings.estimatedVideoBytes(at: fileURL,
                                                                    profile: highP,
                                                                    durationSeconds: duration,
                                                                    originalSize: originalSize,
                                                                    asset: asset)
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
        bagCompressionEstimates(forFileURLs: fileURLs).totals
    }

    /// One pass: chip label totals + any-item enablement + per-item estimates for logging.
    public static func bagCompressionEstimates(forFileURLs fileURLs: [URL]) -> BagCompressionEstimates {
        var none: Int64 = 0
        var low: Int64 = 0
        var medium: Int64 = 0
        var high: Int64 = 0
        var anyLow = false
        var anyMedium = false
        var anyHigh = false
        var perItem: [LevelEstimates] = []
        // Sum raw estimates only — do not re-run MediaUploadHeuristic shrink checks here
        // (that was logging ~6 lines per level when chips also called compressionLevelLikelyUseful).
        let usesWriter = MediaUploadDebugSettings.shared().usesAssetWriter
        let debug = MediaUploadDebugSettings.shared()
        let shrinkThreshold = 0.90

        for url in fileURLs {
            var counts = cheapEstimatedByteCounts(at: url)
            if !usesWriter,
               isVideo(fileExtension: url.pathExtension.lowercased()),
               let duration = videoDurationSeconds(at: url), duration > 0 {
                let original = fileSize(at: url)
                let exportLow = MediaUploadDebugSettings.estimatedVideoBytesForExportPreset(
                    at: url,
                    profile: debug.low,
                    durationSeconds: duration,
                    originalSize: original)
                let exportMedium = MediaUploadDebugSettings.estimatedVideoBytesForExportPreset(
                    at: url,
                    profile: debug.medium,
                    durationSeconds: duration,
                    originalSize: original)
                let exportHigh = MediaUploadDebugSettings.estimatedVideoBytesForExportPreset(
                    at: url,
                    profile: debug.high,
                    durationSeconds: duration,
                    originalSize: original)
                let cap = original > 0 ? original : max(exportLow, max(exportMedium, exportHigh))
                counts.low = max(12_288, min(exportLow, cap))
                counts.medium = max(12_288, min(exportMedium, counts.low))
                counts.high = max(12_288, min(exportHigh, counts.medium))
            }

            perItem.append(counts)

            // Chip totals: use compress estimate only when it is ≥10% smaller; else original.
            // Enable level if **any** item would shrink (Send still keeps original for non-winners).
            let threshold = Int64(Double(counts.none) * shrinkThreshold)
            let itemLow: Int64
            if counts.low < threshold {
                anyLow = true
                itemLow = counts.low
            } else {
                itemLow = counts.none
            }
            let itemMedium: Int64
            if counts.medium < threshold {
                anyMedium = true
                itemMedium = counts.medium
            } else {
                itemMedium = counts.none
            }
            let itemHigh: Int64
            if counts.high < threshold {
                anyHigh = true
                itemHigh = counts.high
            } else {
                itemHigh = counts.none
            }

            none += counts.none
            low += min(itemLow, counts.none)
            medium += min(itemMedium, min(itemLow, counts.none))
            high += min(itemHigh, min(itemMedium, min(itemLow, counts.none)))
        }

        var enabled: Set<MediaUploadCompressionLevel> = [.none]
        if anyLow { enabled.insert(.low) }
        if anyMedium { enabled.insert(.medium) }
        if anyHigh { enabled.insert(.high) }

        return BagCompressionEstimates(
            totals: LevelEstimates(none: none, low: low, medium: medium, high: high),
            enabled: enabled,
            perItem: perItem
        )
    }

    /// Bag-total enablement (legacy). Prefer `bagCompressionEstimates` any-item enablement for chips.
    public static func compressionLevelsUsefulFromEstimates(_ totals: LevelEstimates) -> Set<MediaUploadCompressionLevel> {
        var enabled: Set<MediaUploadCompressionLevel> = [.none]
        let threshold = Int64(Double(totals.none) * 0.90)
        if totals.low < threshold { enabled.insert(.low) }
        if totals.medium < threshold { enabled.insert(.medium) }
        if totals.high < threshold { enabled.insert(.high) }
        return enabled
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
        // Compact chip labels: at most one fractional digit (e.g. 4.1 MB, not 4.14 MB).
        let absCount = abs(byteCount)
        let unit: String
        let value: Double
        if absCount >= 1_000_000_000 {
            unit = "GB"
            value = Double(byteCount) / 1_000_000_000
        } else if absCount >= 1_000_000 {
            unit = "MB"
            value = Double(byteCount) / 1_000_000
        } else if absCount >= 1_000 {
            unit = "KB"
            value = Double(byteCount) / 1_000
        } else {
            return "\(byteCount) B"
        }

        let number = NumberFormatter()
        number.locale = .current
        number.numberStyle = .decimal
        number.minimumFractionDigits = 0
        number.maximumFractionDigits = 1
        let amount = number.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return "\(amount) \(unit)"
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
        videoDurationSeconds(from: AVURLAsset(url: fileURL))
    }

    private static func videoDurationSeconds(from asset: AVAsset) -> Double? {
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
