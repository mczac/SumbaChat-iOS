//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Process-wide serial video encode queue.
/// Only one AVAssetWriter / AVAssetExportSession runs at a time (app and Share Extension).
@objcMembers public final class MediaUploadVideoEncodeQueue: NSObject {

    @objc public static let shared = MediaUploadVideoEncodeQueue()

    private let lock = NSLock()
    private var pending: [(@escaping () -> Void) -> Void] = []
    private var running = false
    private let worker = DispatchQueue(label: "com.spl.SumbaChat.media-upload-encode-worker", qos: .userInitiated)

    private override init() {
        super.init()
    }

    /// Enqueue work that calls `finished` exactly once when the encode (and teardown) is done.
    @objc public func enqueue(_ work: @escaping (@escaping () -> Void) -> Void) {
        lock.lock()
        pending.append(work)
        let startNow = !running
        if startNow {
            running = true
        }
        lock.unlock()

        if startNow {
            runNext()
        }
    }

    private func runNext() {
        lock.lock()
        guard !pending.isEmpty else {
            running = false
            lock.unlock()
            return
        }
        let job = pending.removeFirst()
        running = true
        lock.unlock()

        // Never start AVFoundation encode work on the caller's thread (often main).
        worker.async {
            job { [weak self] in
                // Brief mediaserverd cooldown between serial encode jobs.
                // Uses extension-aware defaults + plateau early-exit (see MediaUploadMemoryGate).
                MediaUploadMemoryGate.waitForHeadroom()
                self?.runNext()
            }
        }
    }
}
