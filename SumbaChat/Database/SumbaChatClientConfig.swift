//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit

extension Notification.Name {
    /// Posted on the main queue when SumbaChat client update policy should be evaluated/presented.
    static let SumbaChatClientUpdateCheck = Notification.Name("SumbaChatClientUpdateCheckNotification")
}

/// Remote SumbaChat client knobs from Talk capabilities (`spreed.config.sumbachat-client`).
///
/// Example:
/// ```json
/// { "minIosBuild": 30, "latestIosBuild": 35, "app": "1234567890" }
/// ```
/// `app` may be an App Store numeric id or a full `https://` / `itms-apps://` URL.
enum SumbaChatClientConfig {

    private static let dismissedRecommendedBuildKey = "sumbaChatDismissedRecommendedBuild"

    struct UpdatePolicy: Equatable {
        let minIosBuild: Int
        let latestIosBuild: Int
        let app: String

        var appStoreURL: URL? {
            let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased().hasPrefix("http") || trimmed.lowercased().hasPrefix("itms") {
                return URL(string: trimmed)
            }
            return URL(string: "itms-apps://itunes.apple.com/app/id\(trimmed)")
        }
    }

    enum UpdateKind: Equatable {
        case mandatory(UpdatePolicy)
        case recommended(UpdatePolicy)
    }

    private(set) static var lastPolicy: UpdatePolicy?

    /// Invoked from `NCDatabaseManager.setTalkCapabilities` (login + talk-hash refresh).
    static func applyIfPresent(from capabilitiesDict: [AnyHashable: Any]) {
        let config = capabilitiesDict["config"] as? [String: Any]
        // Namespaced key — ignored by stock Nextcloud Talk clients.
        let raw = (config?["sumbachat-client"] as? [String: Any])
            ?? (config?["sumbachat"] as? [String: Any])

        guard let raw else {
            lastPolicy = nil
            return
        }

        let minBuild = intValue(raw["minIosBuild"]) ?? 0
        let latestBuild = intValue(raw["latestIosBuild"]) ?? 0
        let app = (raw["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard minBuild > 0 || latestBuild > 0, !app.isEmpty else {
            lastPolicy = nil
            return
        }

        let policy = UpdatePolicy(minIosBuild: minBuild, latestIosBuild: latestBuild, app: app)
        lastPolicy = policy

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .SumbaChatClientUpdateCheck, object: nil)
        }
    }

    static func currentBuildNumber() -> Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Int(raw) ?? 0
    }

    /// Mandatory first (`build < minIosBuild`), else recommended (`build < latestIosBuild`).
    static func pendingUpdateKind() -> UpdateKind? {
        guard let policy = lastPolicy else { return nil }
        let build = currentBuildNumber()

        if policy.minIosBuild > 0, build < policy.minIosBuild {
            return .mandatory(policy)
        }

        if policy.latestIosBuild > 0, build < policy.latestIosBuild {
            let dismissed = UserDefaults.standard.integer(forKey: dismissedRecommendedBuildKey)
            if dismissed >= policy.latestIosBuild {
                return nil
            }
            return .recommended(policy)
        }

        return nil
    }

    static func dismissRecommended(for policy: UpdatePolicy) {
        UserDefaults.standard.set(policy.latestIosBuild, forKey: dismissedRecommendedBuildKey)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
