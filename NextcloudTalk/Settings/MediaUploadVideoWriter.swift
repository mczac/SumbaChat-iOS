//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import CoreMedia
import UIKit
import os

/// Waits for jetsam headroom between serial AVAssetWriter sessions.
enum MediaUploadMemoryGate {
    static func availableBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// Block the calling (background) thread until free memory recovers or timeout.
    /// `os_proc_available_memory()` may return 0 when unknown — do not spin on that
    /// (was burning a full 2.5s after multi-video ExportSession, masking the real handoff crash).
    static func waitForHeadroom(minAvailableBytes: UInt64 = 120 * 1024 * 1024,
                                timeout: TimeInterval = 2.5) {
        let available = availableBytes()
        if available == 0 {
            MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate skip wait (available unknown), min=%.0fMB",
                                            Double(minAvailableBytes) / 1_048_576.0))
            return
        }
        if available >= minAvailableBytes {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        var spins = 0
        while availableBytes() < minAvailableBytes, Date() < deadline {
            spins += 1
            Thread.sleep(forTimeInterval: 0.08)
            autoreleasepool { }
        }
        if spins > 0 {
            MediaUploadTrace.logSync(String(format: "JETSAM MemoryGate waited %d spin(s) avail=%.1fMB (min=%.0fMB)",
                                            spins,
                                            Double(availableBytes()) / 1_048_576.0,
                                            Double(minAvailableBytes) / 1_048_576.0))
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

            // Telegram TGMediaVideoConverter: H.264 High + CABAC + target bitrate/fps.
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

            // Passthrough compressed audio — Linear PCM decode was a large memory spike.
            var audioReaderOutput: AVAssetReaderTrackOutput?
            var audioWriterInput: AVAssetWriterInput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                aOut.alwaysCopiesSampleData = false
                if reader.canAdd(aOut) {
                    reader.add(aOut)
                    audioReaderOutput = aOut
                    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                    aIn.expectsMediaDataInRealTime = false
                    if writer.canAdd(aIn) {
                        writer.add(aIn)
                        audioWriterInput = aIn
                    } else {
                        audioReaderOutput = nil
                    }
                }
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
                            let srcMbps = duration > 0
                                ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: sourceSize, durationSeconds: duration) : 0
                            let outMbps = duration > 0
                                ? MediaUploadDebugSettings.approximateSourceTotalMbps(fileBytes: compressedSize, durationSeconds: duration) : 0
                            MediaUploadTrace.log(String(format:
                                "ENCODE video ACTUAL %@ %@ (%.3fMbps) → %@ (%.3fMbps) engine=Writer %dx%d videoBitrate=%d",
                                sourceURL.lastPathComponent,
                                MediaUploadTrace.mb(sourceSize), srcMbps,
                                MediaUploadTrace.mb(compressedSize), outMbps,
                                width, height, videoBitsPerSecond))
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
