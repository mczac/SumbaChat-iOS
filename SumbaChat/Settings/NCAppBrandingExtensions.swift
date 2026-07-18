//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI

extension NCAppBranding {

    @objc
    static func elementColorBackground() -> UIColor {
        var lightColor: UIColor
        var darkColor: UIColor

        if #available(iOS 18.0, *) {
            lightColor = NCAppBranding.elementColor().withProminence(.quaternary)
            darkColor = NCAppBranding.elementColor().withProminence(.secondary)
        } else {
            lightColor = NCAppBranding.elementColor().withAlphaComponent(0.1)
            darkColor = NCAppBranding.elementColor().withAlphaComponent(0.2)
        }

        return NCAppBranding.getDynamicColor(lightColor, withDarkMode: darkColor)
    }

    @objc
    static func userAgent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        return "Mozilla/5.0 (iOS) SumbaChat v\(version)"
    }

    @objc
    static func userAgentForLogin() -> String {
        let appDisplayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] ?? "Unknown app"
        let device = UIDevice.current
        let deviceModel = hardwareModelIdentifier()

        return "\(deviceModel) - \(device.systemName) \(device.systemVersion) (\(appDisplayName))"
    }

    private static func hardwareModelIdentifier() -> String {
#if targetEnvironment(simulator)
        if let simulatedModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulatedModel.isEmpty {
            return simulatedModel
        }
#endif

        var systemInfo = utsname()
        uname(&systemInfo)

        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

}
