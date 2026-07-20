//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import UIKit

/// App Group `Library/Caches` layout for upload staging, convert reuse, download warm-cache, and thumbs.
/// Falls back to `NSTemporaryDirectory()` when the App Group container is unavailable.
@objcMembers public final class MediaUploadDiskStore: NSObject {

    @objc public static let shared = MediaUploadDiskStore()

    /// Soft cap for `{upload}/` staging (separate from download Settings cap).
    public static let uploadStagingMaxBytes: Int64 = 512 * 1024 * 1024
    /// Soft cap for convert-cache (encoded reuse). Shares purge style with downloads.
    public static let convertCacheMaxBytes: Int64 = 512 * 1024 * 1024
    public static let maxConcurrentUploads = 2

    private static let legacyMigratedKey = "ncMediaCacheMigratedToAppGroup"

    private let fileManager = FileManager.default

    public let cachesRootURL: URL
    public let downloadRootURL: URL
    public let uploadRootURL: URL
    public let convertRootURL: URL
    public let thumbsRootURL: URL

    private override init() {
        let root: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            root = group.appendingPathComponent("Library/Caches/SumbaMedia", isDirectory: true)
        } else {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SumbaMedia", isDirectory: true)
            NCLog.log("MediaUploadDiskStore: App Group unavailable — using temporary SumbaMedia root")
        }
        cachesRootURL = root
        downloadRootURL = root.appendingPathComponent("download", isDirectory: true)
        uploadRootURL = root.appendingPathComponent("upload", isDirectory: true)
        convertRootURL = root.appendingPathComponent("convert", isDirectory: true)
        thumbsRootURL = root.appendingPathComponent("thumbs", isDirectory: true)
        super.init()
        ensureDirectories()
        migrateLegacyDownloadCacheIfNeeded()
    }

    @objc public var uploadDirectoryPath: String {
        uploadRootURL.path
    }

    @objc public var downloadRootPath: String {
        downloadRootURL.path
    }

    /// App Group files: readable after first unlock (Share Extension + background).
    private static let mediaFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    public func downloadDirectoryPath(forAccountId accountId: String) -> String {
        let encoded = accountId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? accountId
        let url = downloadRootURL.appendingPathComponent(encoded, isDirectory: true)
        Self.createProtectedDirectory(at: url)
        return url.path
    }

    /// Per-account convert reuse root (`convert/{accountId}/`).
    public func convertDirectoryURL(forAccountId accountId: String) -> URL {
        let raw = accountId.isEmpty ? "_unknown" : accountId
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? raw
        let url = convertRootURL.appendingPathComponent(encoded, isDirectory: true)
        Self.createProtectedDirectory(at: url)
        return url
    }

    /// Wipe per-account download + convert caches only. Does not touch other accounts or shared upload/thumbs.
    @objc(purgeLocalCachesForAccountId:)
    public func purgeLocalCaches(forAccountId accountId: String) {
        guard !accountId.isEmpty else { return }
        let encoded = accountId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? accountId
        let downloadURL = downloadRootURL.appendingPathComponent(encoded, isDirectory: true)
        let convertURL = convertRootURL.appendingPathComponent(encoded, isDirectory: true)
        for url in [downloadURL, convertURL] {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
                NCLog.log("MediaUploadDiskStore: purged \(url.lastPathComponent) cache for account \(accountId)")
            }
        }
    }

    public func ensureDirectories() {
        for url in [cachesRootURL, downloadRootURL, uploadRootURL, convertRootURL, thumbsRootURL] {
            Self.createProtectedDirectory(at: url)
        }
    }

    private static func createProtectedDirectory(at url: URL) {
        let attrs: [FileAttributeKey: Any] = [.protectionKey: mediaFileProtection]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private static func applyFileProtection(atPath path: String) {
        try? FileManager.default.setAttributes([.protectionKey: mediaFileProtection], ofItemAtPath: path)
    }

    /// One-time copy of `{tmp}/download` → App Group download (best-effort).
    public func migrateLegacyDownloadCacheIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.legacyMigratedKey) == false else { return }
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
            do {
                let children = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                for child in children {
                    let dest = downloadRootURL.appendingPathComponent(child.lastPathComponent)
                    if fileManager.fileExists(atPath: dest.path) { continue }
                    try? fileManager.copyItem(at: child, to: dest)
                }
                NCLog.log("MediaUploadDiskStore: migrated legacy tmp/download → App Group (\(children.count) entries)")
            } catch {
                NCLog.log("MediaUploadDiskStore: legacy download migrate failed: \(error.localizedDescription)")
            }
        }
        defaults.set(true, forKey: Self.legacyMigratedKey)
    }

    // MARK: - Promote upload → download cache

    /// Copy/move a successfully uploaded local file into the shared download cache.
    @objc(promoteUploadedFileAtPath:accountId:serverFileName:remoteBytes:remoteModificationDate:)
    public static func promoteUploadedFile(atPath localPath: String,
                                           accountId: String,
                                           serverFileName: String,
                                           remoteBytes: Int64,
                                           remoteModificationDate: Date?) -> Bool {
        shared.promote(localPath: localPath,
                       accountId: accountId,
                       serverFileName: serverFileName,
                       remoteBytes: remoteBytes,
                       remoteModificationDate: remoteModificationDate)
    }

    /// Removes `url` when present, including a case-only sibling (`IMG.JPG` vs `IMG.jpg`).
    @objc(removeItemAllowingCaseVariantsAtURL:)
    public static func removeItemAllowingCaseVariants(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        let target = url.lastPathComponent
        guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            try? fm.removeItem(at: child)
        }
    }

    /// `copyItem` after clearing destination and case-insensitive name collisions.
    @objc(copyItemReplacingAtURL:toURL:error:)
    public static func copyItemReplacing(at source: URL, to destination: URL) throws {
        removeItemAllowingCaseVariants(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    @discardableResult
    public func promote(localPath: String,
                        accountId: String,
                        serverFileName: String,
                        remoteBytes: Int64,
                        remoteModificationDate: Date?) -> Bool {
        guard !localPath.isEmpty, !serverFileName.isEmpty, remoteBytes > 0 else { return false }
        guard fileManager.fileExists(atPath: localPath) else { return false }

        let dir = downloadDirectoryPath(forAccountId: accountId)
        let destPath = (dir as NSString).appendingPathComponent(serverFileName)
        let destURL = URL(fileURLWithPath: destPath)

        do {
            try Self.copyItemReplacing(at: URL(fileURLWithPath: localPath), to: destURL)

            var attrs: [FileAttributeKey: Any] = [
                .creationDate: Date(),
                .size: NSNumber(value: remoteBytes)
            ]
            if let remoteModificationDate {
                attrs[.modificationDate] = remoteModificationDate
            }
            try? fileManager.setAttributes(attrs, ofItemAtPath: destPath)
            Self.applyFileProtection(atPath: destPath)
            Self.touchCacheAccess(atPath: destPath)

            // Align size if copy differs (should match).
            if let size = (try? fileManager.attributesOfItem(atPath: destPath)[.size] as? Int64), size != remoteBytes {
                NCLog.log("MediaUploadDiskStore: promote size mismatch local=\(size) remote=\(remoteBytes) for \(serverFileName)")
            }

            MediaUploadTrace.log("CACHE promote OK \(serverFileName) \(MediaUploadTrace.mb(remoteBytes)) → \(destPath)")
            DispatchQueue.global(qos: .utility).async {
                Self.enforceDownloadCacheBudget(excludingPath: destPath)
                Self.enforceConvertCacheBudget()
            }
            return true
        } catch {
            MediaUploadTrace.log("CACHE promote FAIL \(serverFileName): \(error.localizedDescription)")
            return false
        }
    }

    /// Download-cache purge (Settings `fileCacheMaxBytes`, 95% → 80%).
    /// Evicts least-recently-accessed files (see `touchCacheAccess`).
    public static func enforceDownloadCacheBudget(excludingPath: String? = nil) {
        let maxBytes = NCUserDefaults.fileCacheMaxBytes()
        purgeOldest(in: shared.downloadRootURL,
                    maxBytes: maxBytes,
                    label: "download",
                    excludingPath: excludingPath,
                    sortByAccess: true)
    }

    /// Bump last-access for LRU purge. Does **not** change `modificationDate`
    /// (download STALE still compares remote mtime + size).
    @objc(touchCacheAccessAtPath:)
    public static func touchCacheAccess(atPath path: String) {
        guard !path.isEmpty else { return }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? url.setResourceValues(values)
    }

    /// Cheap chat-UI probe: download cache has `fileName` with matching byte size.
    /// Does not delete stale files (unlike the download path’s mtime check).
    public static func hasCachedDownload(named fileName: String, size: Int64, accountId: String) -> Bool {
        guard !fileName.isEmpty, size > 0, !accountId.isEmpty else { return false }
        let dir = shared.downloadDirectoryPath(forAccountId: accountId)
        let path = (dir as NSString).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let localSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return localSize == size
    }

    // MARK: - Convert cache

    @objc(profileFingerprintForLevel:settings:)
    public static func profileFingerprint(level: MediaUploadCompressionLevel,
                                          settings: MediaUploadCompressionSettings) -> String {
        let debug = MediaUploadDebugSettings.shared()
        let engine = debug.usesAssetWriter ? "w" : "e"
        // Prefer settings.profile (includes multi-video edge cap) over raw debug profile.
        let profile = settings.profile ?? debug.profile(for: level)
        let q = profile?.imageJPEGQuality ?? 0
        let imgEdge = profile?.imageMaxDimension ?? 0
        let rate = profile?.videoRateMbps ?? 0
        let vidEdge = profile?.videoMaxEdge ?? 0
        let fps = profile?.videoFPS ?? 0
        let preset = profile?.exportPreset ?? ""
        let vidMax = profile?.videoMaxBytes ?? 0
        let audioKbps = profile?.audioBitrateKbps ?? 0
        let audioCh = profile?.audioChannels ?? 0
        return String(format: "lv%ld_%@_q%d_ie%d_r%.3f_ve%d_f%.0f_p%@_vm%lld_a%dk%dc",
                      level.rawValue, engine, q, imgEdge, rate, vidEdge, fps, preset, vidMax,
                      audioKbps, audioCh)
    }

    /// Stable key for staged file contents (`v2` + SHA256 of samples + size).
    /// Small files (≤1 MB) are fully hashed; larger files use head + two mid windows + tail.
    @objc(contentFingerprintAtPath:)
    public static func contentFingerprint(atPath path: String) -> String? {
        contentFingerprint(at: URL(fileURLWithPath: path))
    }

    public static func contentFingerprint(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int64, size > 0 else { return nil }

        var hasher = SHA256()
        let fullHashLimit: Int64 = 1_024 * 1_024
        if size <= fullHashLimit {
            if let all = try? handle.readToEnd() {
                hasher.update(data: all)
            }
        } else {
            let headLen = Int(min(size, 512 * 1_024))
            if let head = try? handle.read(upToCount: headLen) {
                hasher.update(data: head)
            }
            let window = Int64(64 * 1_024)
            for fraction in [1.0 / 3.0, 2.0 / 3.0] as [Double] {
                let center = Int64(Double(size) * fraction)
                let start = max(0, min(size - window, center - window / 2))
                try? handle.seek(toOffset: UInt64(start))
                if let mid = try? handle.read(upToCount: Int(window)) {
                    hasher.update(data: mid)
                }
            }
            let tailLen = Int(min(size, window))
            try? handle.seek(toOffset: UInt64(size - Int64(tailLen)))
            if let tail = try? handle.read(upToCount: tailLen) {
                hasher.update(data: tail)
            }
        }
        var sizeBE = size.bigEndian
        withUnsafeBytes(of: &sizeBE) { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "v2_\(digest)_\(size)"
    }

    public static func convertCacheFileURL(accountId: String,
                                           contentKey: String,
                                           profileKey: String,
                                           pathExtension: String) -> URL {
        let safeContent = contentKey.replacingOccurrences(of: "/", with: "_")
        let safeProfile = profileKey.replacingOccurrences(of: "/", with: "_")
        let name = "\(safeContent)__\(safeProfile).\(pathExtension.isEmpty ? "bin" : pathExtension)"
        return shared.convertDirectoryURL(forAccountId: accountId).appendingPathComponent(name)
    }

    /// Returns existing convert-cache file for this account + source + profile, if present and non-empty.
    @objc(cachedConvertURLForSourceURL:accountId:level:settings:outputExtension:)
    public static func cachedConvertURL(forSourceURL sourceURL: URL,
                                        accountId: String,
                                        level: MediaUploadCompressionLevel,
                                        settings: MediaUploadCompressionSettings,
                                        outputExtension: String) -> URL? {
        guard let contentKey = contentFingerprint(at: sourceURL) else { return nil }
        let profileKey = profileFingerprint(level: level, settings: settings)
        let url = convertCacheFileURL(accountId: accountId,
                                      contentKey: contentKey,
                                      profileKey: profileKey,
                                      pathExtension: outputExtension)
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > 0 else {
            return nil
        }
        touchCacheAccess(atPath: url.path)
        return url
    }

    /// Store a successful encode into convert cache (copy).
    @discardableResult
    @objc(storeConvertResultFrom:sourceURL:accountId:level:settings:)
    public static func storeConvertResult(from encodedURL: URL,
                                          sourceURL: URL,
                                          accountId: String,
                                          level: MediaUploadCompressionLevel,
                                          settings: MediaUploadCompressionSettings) -> Bool {
        guard let contentKey = contentFingerprint(at: sourceURL) else { return false }
        let profileKey = profileFingerprint(level: level, settings: settings)
        let ext = encodedURL.pathExtension.lowercased()
        let dest = convertCacheFileURL(accountId: accountId,
                                       contentKey: contentKey,
                                       profileKey: profileKey,
                                       pathExtension: ext)
        let fm = FileManager.default
        // Copy to a sibling temp then replace — crash mid-write must not leave a corrupt convert-HIT.
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(dest.lastPathComponent)")
        do {
            if fm.fileExists(atPath: temp.path) {
                try fm.removeItem(at: temp)
            }
            try fm.copyItem(at: encodedURL, to: temp)
            removeItemAllowingCaseVariants(at: dest)
            try fm.moveItem(at: temp, to: dest)
            try? fm.setAttributes([.creationDate: Date()], ofItemAtPath: dest.path)
            applyFileProtection(atPath: dest.path)
            touchCacheAccess(atPath: dest.path)
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            MediaUploadTrace.log("CACHE convert-STORE \(dest.lastPathComponent) \(MediaUploadTrace.mb(size)) account=\(accountId) profile=\(profileKey)")
            DispatchQueue.global(qos: .utility).async {
                enforceConvertCacheBudget()
            }
            return true
        } catch {
            try? fm.removeItem(at: temp)
            MediaUploadTrace.log("CACHE convert-STORE FAIL: \(error.localizedDescription)")
            return false
        }
    }

    public static func enforceConvertCacheBudget() {
        purgeOldest(in: shared.convertRootURL,
                    maxBytes: convertCacheMaxBytes,
                    label: "convert",
                    excludingPath: nil,
                    sortByAccess: true)
    }

    public static func enforceUploadStagingBudget() {
        // Session scratch — FIFO by creation, not access LRU.
        purgeOldest(in: shared.uploadRootURL,
                    maxBytes: uploadStagingMaxBytes,
                    label: "upload",
                    excludingPath: nil,
                    sortByAccess: false)
    }

    public static func clearConvertCache() {
        try? FileManager.default.removeItem(at: shared.convertRootURL)
        shared.ensureDirectories()
    }

    public static func clearThumbsCache() {
        try? FileManager.default.removeItem(at: shared.thumbsRootURL)
        shared.ensureDirectories()
    }

    /// Current size of `upload/` staging (not part of Cache limit).
    @objc public static func uploadStagingUsageBytes() -> Int64 {
        directorySize(at: shared.uploadRootURL)
    }

    /// Encode-reuse cache size (`convert/`).
    @objc public static func convertCacheUsageBytes() -> Int64 {
        directorySize(at: shared.convertRootURL)
    }

    /// Share-sheet image thumbs (`thumbs/`).
    @objc public static func thumbsCacheUsageBytes() -> Int64 {
        directorySize(at: shared.thumbsRootURL)
    }

    /// Manual clear of upload staging (+ share thumbs). Does not touch download/convert.
    /// Returns `false` when a live share session marker blocks the wipe (cross-process safety).
    /// Uses a synchronous wipe so the caller can observe the skip.
    @objc @discardableResult
    public static func clearUploadStagingCaches() -> Bool {
        clearSessionScratchCaches(reason: "settings-clear-upload", wait: true)
    }

    private static func directorySize(at root: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent == uploadSessionMarkerName { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Session scratch (upload/ + thumbs/)

    /// Serializes scratch wipes so launch / success / cancel never race each other.
    private static let scratchCleanupQueue = DispatchQueue(label: "com.spl.SumbaChat.mediaScratchCleanup", qos: .utility)
    /// Coalesces delayed post-cancel wipes (Cancel vs in-flight PUT body read).
    private static var pendingDelayedScratchClear: DispatchWorkItem?

    /// Files newer than this are kept by idle launch cleanup (active share session).
    public static let scratchIdleMaxAge: TimeInterval = 30 * 60
    /// After Cancel during upload, wait so URLSession can release `upload/` paths.
    public static let scratchClearAfterCancelDelay: TimeInterval = 2.5
    /// How often the share sheet refreshes `.upload-session` while open (must be under max age).
    public static let uploadSessionHeartbeatInterval: TimeInterval = 10 * 60

    /// Cross-process marker under `upload/` — Settings / idle must not wipe while fresh.
    private static let uploadSessionMarkerName = ".upload-session"
    /// Stale marker after crash is ignored so Settings can clear again.
    public static let uploadSessionMaxAge: TimeInterval = 45 * 60

    private static var uploadSessionMarkerURL: URL {
        shared.uploadRootURL.appendingPathComponent(uploadSessionMarkerName)
    }

    /// Reasons that always wipe (owning share session ending or starting fresh).
    private static let forcedScratchClearReasons: Set<String> = [
        "share-init",
        "sheet-dismiss",
        "share-remove-all"
    ]

    /// Write/refresh App Group marker so the main app will not wipe `upload/` mid-share.
    @objc(beginUploadSessionWithReason:)
    public static func beginUploadSession(reason: String) {
        scratchCleanupQueue.async {
            shared.ensureDirectories()
            let payload: [String: Any] = [
                "t": Date().timeIntervalSince1970,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "name": ProcessInfo.processInfo.processName,
                "reason": reason
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            try? data.write(to: uploadSessionMarkerURL, options: .atomic)
            applyFileProtection(atPath: uploadSessionMarkerURL.path)
            MediaUploadTrace.log("CACHE upload-session begin reason=\(reason) pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }

    /// Refresh marker timestamp (e.g. on Send) so long compose sessions stay protected.
    @objc public static func touchUploadSession() {
        beginUploadSession(reason: "touch")
    }

    /// `true` when a fresh share session marker exists in the App Group (any process).
    @objc public static func isUploadSessionActive() -> Bool {
        scratchCleanupQueue.sync {
            uploadSessionActiveUnlocked()
        }
    }

    private static func uploadSessionActiveUnlocked() -> Bool {
        let url = uploadSessionMarkerURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["t"] as? TimeInterval else {
            return false
        }
        return Date().timeIntervalSince1970 - t < uploadSessionMaxAge
    }

    /// Wipe `upload/` + `thumbs/` (session scratch only — not download/convert).
    /// - Parameter wait: `true` for ShareItemController init (must be empty before staging).
    /// - Returns: `false` when skipped because another process holds an active upload session.
    @objc(clearSessionScratchCachesWithReason:wait:)
    @discardableResult
    public static func clearSessionScratchCaches(reason: String, wait: Bool) -> Bool {
        var didClear = true
        let work = {
            didClear = Self.performClearSessionScratch(reason: reason)
        }
        if wait {
            scratchCleanupQueue.sync(execute: work)
        } else {
            scratchCleanupQueue.async(execute: work)
            // Async path: caller cannot observe skip; Settings uses isUploadSessionActive first.
            didClear = true
        }
        return didClear
    }

    /// Force-wipe after a delay (Cancel during PUT). Coalesces; cancelled by a later immediate clear.
    @objc(scheduleClearSessionScratchCachesWithReason:afterDelay:)
    public static func scheduleClearSessionScratchCaches(reason: String, afterDelay delay: TimeInterval) {
        let wait = max(0, delay)
        scratchCleanupQueue.async {
            pendingDelayedScratchClear?.cancel()
            let work = DispatchWorkItem {
                pendingDelayedScratchClear = nil
                _ = Self.performClearSessionScratch(reason: reason)
            }
            pendingDelayedScratchClear = work
            MediaUploadTrace.log("CACHE scratch-clear scheduled reason=\(reason) delay=\(Int(wait))s")
            scratchCleanupQueue.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// Non-blocking launch cleanup: delete scratch files older than `scratchIdleMaxAge`.
    /// Skips entirely while an upload-session marker is fresh; skips recent files otherwise.
    @objc public static func scheduleIdleSessionScratchCleanup() {
        scratchCleanupQueue.async {
            if uploadSessionActiveUnlocked() {
                MediaUploadTrace.log("CACHE scratch-idle-clean skip (upload-session active)")
                return
            }
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-scratchIdleMaxAge)
            var removed = 0
            for root in [shared.uploadRootURL, shared.thumbsRootURL] {
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == uploadSessionMarkerName { continue }
                    guard let values = try? fileURL.resourceValues(forKeys: [
                        .isRegularFileKey, .contentModificationDateKey, .creationDateKey
                    ]),
                          values.isRegularFile == true else { continue }
                    let stamp = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    guard stamp < cutoff else { continue }
                    try? fm.removeItem(at: fileURL)
                    removed += 1
                }
            }
            if removed > 0 {
                MediaUploadTrace.log("CACHE scratch-idle-clean removed=\(removed) maxAge=\(Int(scratchIdleMaxAge))s")
            }
            shared.ensureDirectories()
        }
    }

    /// - Returns: `false` if wipe was skipped due to an active cross-process session.
    @discardableResult
    private static func performClearSessionScratch(reason: String) -> Bool {
        pendingDelayedScratchClear?.cancel()
        pendingDelayedScratchClear = nil

        let force = forcedScratchClearReasons.contains(reason)
        if !force, uploadSessionActiveUnlocked() {
            MediaUploadTrace.log("CACHE scratch-clear SKIP reason=\(reason) (upload-session active)")
            return false
        }

        let fm = FileManager.default
        for root in [shared.uploadRootURL, shared.thumbsRootURL] {
            if fm.fileExists(atPath: root.path) {
                try? fm.removeItem(at: root)
            }
        }
        shared.ensureDirectories()
        MediaUploadTrace.log("CACHE scratch-clear reason=\(reason)")

        if reason == "share-init" {
            // Owning process starts a new session immediately after wipe.
            let payload: [String: Any] = [
                "t": Date().timeIntervalSince1970,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "name": ProcessInfo.processInfo.processName,
                "reason": reason
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
                try? data.write(to: uploadSessionMarkerURL, options: .atomic)
                applyFileProtection(atPath: uploadSessionMarkerURL.path)
            }
            MediaUploadTrace.log("CACHE upload-session begin reason=\(reason) pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
        return true
    }

    // MARK: - Cache breakdown (Settings)

    public enum CacheKind {
        case images
        case videos
        case documents
    }

    public struct CacheUsageBytes {
        public var images: Int64
        public var videos: Int64
        public var documents: Int64

        public var total: Int64 { images + videos + documents }
    }

    /// Settings display: whole units only (e.g. `512 KB`, `57 MB`, `3 GB` — no decimals).
    public static func formatCacheBytes(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        let kb: Int64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        if value < kb {
            return "\(value) B"
        }
        if value < mb {
            return "\(value / kb) KB"
        }
        if value < gb {
            return "\(value / mb) MB"
        }
        return "\(value / gb) GB"
    }

    private static func cacheKind(forFileURL url: URL) -> CacheKind {
        let ext = url.pathExtension.lowercased()
        if NCUtils.isImage(fileExtension: ext) {
            return .images
        }
        if MediaUploadPreprocessor.isVideo(fileExtension: ext) {
            return .videos
        }
        return .documents
    }

    /// Settings Cached Images/Videos/Documents: `download/` by type (matches Cache limit).
    public static func attachmentCacheUsage() -> CacheUsageBytes {
        var usage = CacheUsageBytes(images: 0, videos: 0, documents: 0)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: shared.downloadRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return usage
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            switch cacheKind(forFileURL: fileURL) {
            case .images: usage.images += size
            case .videos: usage.videos += size
            case .documents: usage.documents += size
            }
        }
        return usage
    }

    /// Clears only matching files under `download/`. Convert / thumbs / SD / URL have their own Settings rows.
    public static func clearAttachmentCache(kind: CacheKind) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: shared.downloadRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var toDelete: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            if cacheKind(forFileURL: fileURL) == kind {
                toDelete.append(fileURL)
            }
        }
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Thumbs

    public static func thumbURL(forStagingPath path: String) -> URL {
        let key = contentFingerprint(atPath: path)
            ?? path.replacingOccurrences(of: "/", with: "_")
        let name = key.replacingOccurrences(of: "/", with: "_") + ".jpg"
        return shared.thumbsRootURL.appendingPathComponent(name)
    }

    @objc(storeThumbFromImage:forStagingPath:)
    public static func storeThumb(from image: UIImage, forStagingPath path: String) {
        let maxEdge: CGFloat = 320
        let size = image.size
        let longest = max(size.width, size.height)
        let scaled: UIImage
        if longest > maxEdge, longest > 0 {
            let scale = maxEdge / longest
            let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            scaled = image
        }
        guard let data = scaled.jpegData(compressionQuality: 0.72), !data.isEmpty else { return }
        let url = thumbURL(forStagingPath: path)
        try? data.write(to: url, options: .atomic)
    }

    @objc(loadThumbForStagingPath:)
    public static func loadThumb(forStagingPath path: String) -> UIImage? {
        let url = thumbURL(forStagingPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Purge helper

    /// - Parameter sortByAccess: When true (download/convert), evict least-recently-accessed
    ///   (`contentAccessDate`, falling back to `creationDate`). When false (upload staging), FIFO by creation.
    private static func purgeOldest(in root: URL,
                                    maxBytes: Int64,
                                    label: String,
                                    excludingPath: String?,
                                    sortByAccess: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard maxBytes > 0 else { return }

        let keys: Set<URLResourceKey> = sortByAccess
            ? [.isRegularFileKey, .contentAccessDateKey, .creationDateKey, .fileSizeKey]
            : [.isRegularFileKey, .creationDateKey, .fileSizeKey]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let size: Int64
            let stamp: Date
        }

        var files: [Entry] = []
        var total: Int64 = 0
        let excluded = excludingPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            if let excluded, path == excluded { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { continue }
            let stamp: Date
            if sortByAccess {
                stamp = values.contentAccessDate ?? values.creationDate ?? .distantPast
            } else {
                stamp = values.creationDate ?? .distantPast
            }
            files.append(Entry(url: fileURL, size: size, stamp: stamp))
            total += size
        }

        if let excludingPath,
           let attrs = try? fm.attributesOfItem(atPath: excludingPath),
           let size = attrs[.size] as? Int64 {
            total += size
        }

        let start = Int64(Double(maxBytes) * 0.95)
        let target = Int64(Double(maxBytes) * 0.80)
        guard total > start else { return }

        files.sort { $0.stamp < $1.stamp }
        let before = total
        var removed = 0
        for file in files {
            guard total > target else { break }
            try? fm.removeItem(at: file.url)
            total -= file.size
            removed += 1
        }
        MediaUploadTrace.log(String(format:
            "CACHE purge %@ before=%@ after=%@ removed=%d max=%@",
            label,
            MediaUploadTrace.mb(before),
            MediaUploadTrace.mb(total),
            removed,
            MediaUploadTrace.mb(maxBytes)))
    }
}

// MARK: - Upload concurrency gate

/// Limits parallel DAV PUTs after serial encode (Share Extension memory/network).
@objcMembers public final class MediaUploadUploadGate: NSObject {
    @objc public static let shared = MediaUploadUploadGate()

    private let lock = NSLock()
    private var active = 0
    private var waiters: [(label: String, start: () -> Void)] = []
    private let maxConcurrent: Int

    public override init() {
        maxConcurrent = MediaUploadDiskStore.maxConcurrentUploads
        super.init()
    }

    /// Call `finished` exactly once when the upload slot may be released.
    @objc(acquireWithLabel:work:)
    public func acquire(label: String, _ work: @escaping (_ finished: @escaping () -> Void) -> Void) {
        lock.lock()
        if active < maxConcurrent {
            active += 1
            let running = active
            lock.unlock()
            MediaUploadTrace.log("PUT gate START \(label) active=\(running)/\(maxConcurrent)")
            run(label: label, work)
        } else {
            waiters.append((label, { [weak self] in
                self?.run(label: label, work)
            }))
            let queued = waiters.count
            let running = active
            lock.unlock()
            MediaUploadTrace.log("PUT gate WAIT \(label) active=\(running)/\(maxConcurrent) queued=\(queued)")
        }
    }

    private func run(label: String, _ work: @escaping (_ finished: @escaping () -> Void) -> Void) {
        work { [weak self] in
            self?.releaseSlot(label: label)
        }
    }

    private func releaseSlot(label: String) {
        lock.lock()
        active = max(0, active - 1)
        let afterRelease = active
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next != nil {
            active += 1
        }
        let running = active
        let queued = waiters.count
        lock.unlock()
        MediaUploadTrace.log("PUT gate DONE \(label) active=\(afterRelease)/\(maxConcurrent) queued=\(queued)")
        if let next {
            MediaUploadTrace.log("PUT gate START \(next.label) active=\(running)/\(maxConcurrent)")
            next.start()
        }
    }
}
