//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia
import UIKit
import os

/// Lightweight post-encode checks shared by Writer and ExportSession.
enum MediaUploadVideoIntegrity {
    static func assetHasAudioTrack(at url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return !asset.tracks(withMediaType: .audio).isEmpty
    }

    static func outputHasAudioTrack(at url: URL) -> Bool {
        assetHasAudioTrack(at: url)
    }

    /// True when source had no audio, or output kept at least one audio track.
    static func preservesAudioIfPresent(source: URL, output: URL) -> Bool {
        guard assetHasAudioTrack(at: source) else { return true }
        return assetHasAudioTrack(at: output)
    }
}

/// Waits for jetsam headroom between serial AVAssetWriter sessions.
enum MediaUploadMemoryGate {
    static func availableBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// Share Extension process — free memory often plateaus ~100 MB while Photos is open.
    static var isAppExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    /// App: 120 MB. Appex: 80 MB (logs showed ~103 MB free never reaching 120).
    static var defaultMinAvailableBytes: UInt64 {
        isAppExtension ? 80 * 1024 * 1024 : 120 * 1024 * 1024
    }

    /// App: 2.5 s. Appex: 1.0 s — plateau bail usually exits sooner anyway.
    static var defaultTimeout: TimeInterval {
        isAppExtension ? 1.0 : 2.5
    }

    /// Block the calling (background) thread until free memory recovers, plateaus, or timeout.
    /// `os_proc_available_memory()` may return 0 when unknown — do not spin on that
    /// (was burning a full 2.5s after multi-video ExportSession, masking the real handoff crash).
    ///
    /// When free memory stops improving (~2 MB over 3 spins), bail early: waiting the full
    /// timeout does not create headroom and only slows multi-photo/video share.
    static func waitForHeadroom(minAvailableBytes: UInt64? = nil,
                                timeout: TimeInterval? = nil) {
        let minBytes = minAvailableBytes ?? defaultMinAvailableBytes
        let timeoutValue = timeout ?? defaultTimeout
        let available = availableBytes()
        if available == 0 {
            MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate skip wait (available unknown), min=%.0fMB",
                                            Double(minBytes) / 1_048_576.0))
            return
        }
        if available >= minBytes {
            return
        }
        let deadline = Date().addingTimeInterval(timeoutValue)
        let improveBytes: UInt64 = 2 * 1024 * 1024
        let plateauLimit = 3
        var spins = 0
        var plateauSpins = 0
        var best = available
        var exitedForPlateau = false
        while Date() < deadline {
            let now = availableBytes()
            if now >= minBytes {
                break
            }
            spins += 1
            Thread.sleep(forTimeInterval: 0.08)
            autoreleasepool { }

            let after = availableBytes()
            if after >= best &+ improveBytes {
                best = after
                plateauSpins = 0
            } else {
                if after > best {
                    best = after
                }
                plateauSpins += 1
                if plateauSpins >= plateauLimit {
                    exitedForPlateau = true
                    break
                }
            }
        }
        if spins > 0 {
            let reason = exitedForPlateau ? "plateau" : (availableBytes() >= minBytes ? "ok" : "timeout")
            MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate waited %d spin(s) avail=%.1fMB (min=%.0fMB) reason=%@",
                                            spins,
                                            Double(availableBytes()) / 1_048_576.0,
                                            Double(minBytes) / 1_048_576.0,
                                            reason))
        }
    }

    /// Fixed mediaserverd cooldown after a heavy ExportSession batch (no memory API dependency).
    static func drainAfterExportBatch(seconds: TimeInterval = 1.0) {
        MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate post-batch drain %.2fs avail=%.0fMB",
                                        seconds, Double(availableBytes()) / 1_048_576.0))
        Thread.sleep(forTimeInterval: seconds)
        autoreleasepool { }
        MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate post-batch drain done avail=%.0fMB",
                                        Double(availableBytes()) / 1_048_576.0))
    }
}

/// ObjC entry for ShareItemController between-encode / post-batch pauses.
@objcMembers public final class MediaUploadMemoryGateObjC: NSObject {
    @objc public static func waitForHeadroom() {
        MediaUploadMemoryGate.waitForHeadroom()
    }

    @objc public static func drainAfterExportBatch() {
        MediaUploadMemoryGate.drainAfterExportBatch()
    }

    @objc public static func availableMegabytes() -> Double {
        Double(MediaUploadMemoryGate.availableBytes()) / 1_048_576.0
    }
}

/// AVAssetWriter-based video compress with bitrate, max edge, and fps targets.
enum MediaUploadVideoWriter {

    static func compress(at sourceURL: URL,
                         toDestinationURL destinationURL: URL,
                         profile: MediaUploadProfileConfig,
                         cancelToken: MediaUploadPreparationToken?,
                         progress: ((Float) -> Void)?,
                         completion: @escaping (Bool) -> Void) {
        if cancelToken?.isCancelled == true {
            completion(false)
            return
        }

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            NCLog.log("MediaUploadVideoWriter: no video track")
            completion(false)
            return
        }

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            NCLog.log("MediaUploadVideoWriter: invalid duration")
            completion(false)
            return
        }

        // Scale storage (natural) size so the on-screen longest edge ≤ maxEdge; keep preferredTransform.
        let natural = videoTrack.naturalSize
        let displaySize = orientedSize(for: videoTrack)
        let maxEdge = CGFloat(max(320, profile.videoMaxEdge))
        let displayLong = max(displaySize.width, displaySize.height)
        let scale = displayLong > maxEdge ? maxEdge / displayLong : 1
        let width = evenInt(natural.width * scale)
        let height = evenInt(natural.height * scale)
        if width < 2 || height < 2 {
            NCLog.log("MediaUploadVideoWriter: invalid output size \(width)x\(height)")
            completion(false)
            return
        }

        let rateMbps = MediaUploadDebugSettings.effectiveRateMbps(profile: profile, durationSeconds: durationSeconds)
        let totalBitsPerSecond = rateMbps * 1_000_000.0
        let audioBitsPerSecond = 128_000.0
        let videoBitsPerSecond = max(100_000, Int(totalBitsPerSecond - audioBitsPerSecond))
        let fps = max(1, Int(profile.videoFPS.rounded()))
        MediaUploadTrace.logSync(String(format:
            "WRITER start %@ duration=%.1fs out=%dx%d edge=%d rate=%.2fMbps videoBitrate=%d fps=%d avail=%.0fMB",
            sourceURL.lastPathComponent,
            durationSeconds,
            width, height,
            profile.videoMaxEdge,
            rateMbps,
            videoBitsPerSecond,
            fps,
            MediaUploadMemoryGateObjC.availableMegabytes()))

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true

            // Prefer decoder output at encode size — avoids full-res frame peaks even when scale ≈ 1.
            let readerVideoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
            videoReaderOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoReaderOutput) else {
                completion(false)
                return
            }
            reader.add(videoReaderOutput)

            // H.264 High + CABAC at the profile target bitrate/fps.
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: videoBitsPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
            let writerVideoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression
            ]
            let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
            videoWriterInput.expectsMediaDataInRealTime = false
            videoWriterInput.transform = videoTrack.preferredTransform
            guard writer.canAdd(videoWriterInput) else {
                completion(false)
                return
            }
            writer.add(videoWriterInput)

            // Audio — Telegram-style PCM→AAC (always re-encode). Passthrough without a
            // sourceFormatHint is rejected for MP4 and we used to ship silent files.
            let sourceHasAudio = !asset.tracks(withMediaType: .audio).isEmpty
            var audioReaderOutput: AVAssetReaderTrackOutput?
            var audioWriterInput: AVAssetWriterInput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                if let wired = Self.wireAudio(track: audioTrack, reader: reader, writer: writer) {
                    audioReaderOutput = wired.readerOutput
                    audioWriterInput = wired.writerInput
                    MediaUploadTrace.logSync(String(format: "WRITER audio path=%@ %@",
                                                    wired.pathName, sourceURL.lastPathComponent))
                } else {
                    // Fail the Writer encode so ExportSession can take over — never upload mute.
                    MediaUploadTrace.logSync("WRITER audio FAIL (could not wire) \(sourceURL.lastPathComponent)")
                    NCLog.log("MediaUploadVideoWriter: unable to wire audio track")
                    completion(false)
                    return
                }
            }

            // Must be set before startWriting — Writer does not inherit source metadata.
            // Applied after inputs so metadata never interferes with canAdd for audio.
            let preserved = Self.captureMetadataItems(from: asset)
            if !preserved.isEmpty {
                writer.metadata = preserved
                MediaUploadTrace.logSync(String(format: "WRITER metadata preserved %d item(s) for %@",
                                                preserved.count, sourceURL.lastPathComponent))
            } else {
                MediaUploadTrace.logSync("WRITER metadata none \(sourceURL.lastPathComponent)")
            }

            let state = WriterState()
            cancelToken?.attachWriterCancel { [weak state] in
                state?.cancel(reader: reader, writer: writer)
            }

            guard reader.startReading(), writer.startWriting() else {
                NCLog.log("MediaUploadVideoWriter: failed to start reader/writer")
                completion(false)
                return
            }
            writer.startSession(atSourceTime: .zero)

            let videoQueue = DispatchQueue(label: "com.spl.SumbaChat.media-upload-video")
            let audioQueue = DispatchQueue(label: "com.spl.SumbaChat.media-upload-audio")
            let group = DispatchGroup()
            let totalDuration = asset.duration

            group.enter()
            videoWriterInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoWriterInput.isReadyForMoreMediaData {
                    if cancelToken?.isCancelled == true || state.isCancelled {
                        videoWriterInput.markAsFinished()
                        group.leave()
                        return
                    }
                    var reachedEnd = false
                    autoreleasepool {
                        if let sample = videoReaderOutput.copyNextSampleBuffer() {
                            if !videoWriterInput.append(sample) {
                                reachedEnd = true
                                return
                            }
                            let t = CMSampleBufferGetPresentationTimeStamp(sample)
                            let fraction = Float(CMTimeGetSeconds(t) / max(0.001, CMTimeGetSeconds(totalDuration)))
                            if state.shouldReportProgress(fraction) {
                                DispatchQueue.main.async {
                                    progress?(min(0.99, max(0, fraction)))
                                }
                            }
                        } else {
                            reachedEnd = true
                        }
                    }
                    if reachedEnd {
                        videoWriterInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioWriterInput, let audioReaderOutput {
                group.enter()
                audioWriterInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioWriterInput.isReadyForMoreMediaData {
                        if cancelToken?.isCancelled == true || state.isCancelled {
                            audioWriterInput.markAsFinished()
                            group.leave()
                            return
                        }
                        var reachedEnd = false
                        autoreleasepool {
                            if let sample = audioReaderOutput.copyNextSampleBuffer() {
                                if !audioWriterInput.append(sample) {
                                    reachedEnd = true
                                }
                            } else {
                                reachedEnd = true
                            }
                        }
                        if reachedEnd {
                            audioWriterInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                if cancelToken?.isCancelled == true || state.isCancelled {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: destinationURL)
                    DispatchQueue.main.async {
                        progress?(0)
                        completion(false)
                    }
                    return
                }

                writer.finishWriting {
                    let sourceSize = MediaUploadPreprocessor.fileSizePublic(at: sourceURL)
                    let compressedSize = MediaUploadPreprocessor.fileSizePublic(at: destinationURL)
                    let duration = durationSeconds
                    let writerStatus = writer.status
                    let writerError = writer.error?.localizedDescription
                    // Leave the finishWriting callback before hopping to main so AVFoundation can drop buffers.
                    DispatchQueue.global(qos: .utility).async {
                        cancelToken?.clearExportSession()
                        MediaUploadMemoryGate.waitForHeadroom()
                        DispatchQueue.main.async {
                            if cancelToken?.isCancelled == true {
                                try? FileManager.default.removeItem(at: destinationURL)
                                completion(false)
                                return
                            }
                            guard writerStatus == .completed else {
                                MediaUploadTrace.log("ENCODE video FAIL \(sourceURL.lastPathComponent) engine=Writer \(writerError ?? "unknown")")
                                NCLog.log("MediaUploadVideoWriter: finish failed \(writerError ?? "unknown")")
                                try? FileManager.default.removeItem(at: destinationURL)
                                completion(false)
                                return
                            }
                            guard compressedSize > 0, sourceSize == 0 || compressedSize < sourceSize else {
                                try? FileManager.default.removeItem(at: destinationURL)
                                MediaUploadTrace.log("ENCODE video keep-original \(sourceURL.lastPathComponent) engine=Writer (not smaller)")
                                NCLog.log("MediaUploadVideoWriter: output not smaller; using original")
                                completion(false)
                                return
                            }
                            if sourceHasAudio,
                               !MediaUploadVideoIntegrity.outputHasAudioTrack(at: destinationURL) {
                                try? FileManager.default.removeItem(at: destinationURL)
                                MediaUploadTrace.log("ENCODE video FAIL \(sourceURL.lastPathComponent) engine=Writer missing-audio")
                                NCLog.log("MediaUploadVideoWriter: output missing audio track")
                                completion(false)
                                return
                            }
                            let srcMbps = duration > 0
                                ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: sourceSize, durationSeconds: duration) : 0
                            let outMbps = duration > 0
                                ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: compressedSize, durationSeconds: duration) : 0
                            MediaUploadTrace.log(String(format:
                                "ENCODE video ACTUAL %@ %@ (%.3fMbps) → %@ (%.3fMbps) engine=Writer %dx%d videoBitrate=%d audio=%@",
                                sourceURL.lastPathComponent,
                                MediaUploadTrace.mb(sourceSize), srcMbps,
                                MediaUploadTrace.mb(compressedSize), outMbps,
                                width, height, videoBitsPerSecond,
                                sourceHasAudio ? "yes" : "none"))
                            completion(true)
                        }
                    }
                }
            }
        } catch {
            MediaUploadTrace.log("ENCODE video FAIL \(sourceURL.lastPathComponent) engine=Writer \(error.localizedDescription)")
            NCLog.log("MediaUploadVideoWriter: \(error.localizedDescription)")
            completion(false)
        }
    }

    private struct WiredAudio {
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput
        let pathName: String
    }

    /// Wire source audio. Matches Telegram's converter: decode PCM → encode AAC for MP4
    /// (passthrough without a format hint is rejected and used to produce silent uploads).
    private static func wireAudio(track audioTrack: AVAssetTrack,
                                  reader: AVAssetReader,
                                  writer: AVAssetWriter) -> WiredAudio? {
        let formatHint = audioTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }

        // Optional fast path: copy compressed audio when MP4 accepts it with a format hint.
        if let formatHint {
            let passthrough = AVAssetWriterInput(mediaType: .audio,
                                                 outputSettings: nil,
                                                 sourceFormatHint: formatHint)
            passthrough.expectsMediaDataInRealTime = false
            if writer.canAdd(passthrough) {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    writer.add(passthrough)
                    reader.add(output)
                    return WiredAudio(readerOutput: output, writerInput: passthrough, pathName: "passthrough")
                }
            }
        }

        // Telegram-style fallback / primary path: Linear PCM → AAC.
        var channels = 1
        if let formatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatHint)?.pointee,
           asbd.mChannelsPerFrame > 0 {
            channels = Int(asbd.mChannelsPerFrame)
        }
        channels = max(1, min(2, channels))

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = channels > 1
            ? kAudioChannelLayoutTag_Stereo
            : kAudioChannelLayoutTag_Mono
        let channelLayoutData = withUnsafeBytes(of: &channelLayout) { Data($0) }

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
            AVChannelLayoutKey: channelLayoutData
        ]
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let aacInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        aacInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(aacInput) else { return nil }
        let pcmOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        pcmOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(pcmOutput) else { return nil }
        writer.add(aacInput)
        reader.add(pcmOutput)
        return WiredAudio(readerOutput: pcmOutput, writerInput: aacInput, pathName: "aac")
    }

    /// Location + creation date (and light camera identity) from the source movie.
    /// Loads metadata keys if needed — file-based assets often still have empty `commonMetadata`
    /// until `loadValuesAsynchronously` finishes.
    private static func captureMetadataItems(from asset: AVAsset) -> [AVMetadataItem] {
        let keys = ["commonMetadata", "metadata", "availableMetadataFormats"]
        let group = DispatchGroup()
        group.enter()
        asset.loadValuesAsynchronously(forKeys: keys) {
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)

        var result: [AVMetadataItem] = []
        var seen = Set<String>()

        func appendIfWanted(_ item: AVMetadataItem) {
            guard wantsCaptureMetadata(item) else { return }
            let id = item.identifier?.rawValue
                ?? "\(item.keySpace?.rawValue ?? "")|\(String(describing: item.key))"
            guard !seen.contains(id) else { return }
            guard item.value != nil
                    || item.dataValue != nil
                    || item.stringValue != nil
                    || item.dateValue != nil else { return }
            seen.insert(id)
            // Mutable copies are safer for AVAssetWriter than handing it live asset items.
            if let copy = item.mutableCopy() as? AVMetadataItem {
                result.append(copy)
            } else {
                result.append(item)
            }
        }

        for item in asset.commonMetadata {
            appendIfWanted(item)
        }
        for item in asset.metadata {
            appendIfWanted(item)
        }
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                appendIfWanted(item)
            }
        }
        return result
    }

    private static func wantsCaptureMetadata(_ item: AVMetadataItem) -> Bool {
        if let common = item.commonKey {
            switch common {
            case .commonKeyCreationDate, .commonKeyLocation, .commonKeyMake, .commonKeyModel:
                return true
            default:
                break
            }
        }
        if let identifier = item.identifier {
            switch identifier {
            case .commonIdentifierCreationDate,
                 .commonIdentifierLocation,
                 .commonIdentifierMake,
                 .commonIdentifierModel,
                 .quickTimeMetadataCreationDate,
                 .quickTimeMetadataLocationISO6709,
                 .quickTimeMetadataLocationName,
                 .quickTimeMetadataMake,
                 .quickTimeMetadataModel,
                 .quickTimeUserDataCreationDate,
                 .quickTimeUserDataLocationISO6709:
                return true
            default:
                break
            }
        }
        return false
    }

    private static func orientedSize(for track: AVAssetTrack) -> CGSize {
        let natural = track.naturalSize
        let transformed = natural.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func evenInt(_ value: CGFloat) -> Int {
        var n = Int(value.rounded())
        if n % 2 != 0 { n += 1 }
        return max(2, n)
    }

    private final class WriterState {
        private let lock = NSLock()
        private(set) var isCancelled = false
        private var lastProgressReported: Float = -1

        func shouldReportProgress(_ fraction: Float) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fraction - lastProgressReported >= 0.05 || fraction >= 0.99 {
                lastProgressReported = fraction
                return true
            }
            return false
        }

        func cancel(reader: AVAssetReader, writer: AVAssetWriter) {
            lock.lock()
            isCancelled = true
            lock.unlock()
            reader.cancelReading()
            writer.cancelWriting()
        }
    }
}
