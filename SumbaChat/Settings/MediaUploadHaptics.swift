//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Light haptics for media send and upload completion.
enum MediaUploadHaptics {
    private static let impact = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        impact.prepare()
        notification.prepare()
    }

    /// Soft tick when Send starts (compose dismiss / prepare begins).
    static func sendStarted() {
        impact.prepare()
        impact.impactOccurred(intensity: 0.6)
    }

    /// Success tick when the batch finished uploading.
    static func uploadSucceeded() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    /// Error tick when the batch failed (or partially failed).
    static func uploadFailed() {
        notification.prepare()
        notification.notificationOccurred(.error)
    }
}
