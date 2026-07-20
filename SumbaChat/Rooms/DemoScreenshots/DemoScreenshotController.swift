//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

#if DEMO_SCREENSHOTS

/// App Store screenshot build helpers (`demo-screenshot` branch only).
enum DemoScreenshotController {

    static let demoRoomTokenPrefix = "demo-"
    static let splashHoldDuration: TimeInterval = 3

    private static var splashOverlay: UIView?

    static var isEnabled: Bool { true }

    static func isDemoRoom(_ room: NCRoom) -> Bool {
        guard let token = room.token else { return false }
        return token.hasPrefix(demoRoomTokenPrefix)
    }

    static func isDemoRoomToken(_ token: String?) -> Bool {
        guard let token else { return false }
        return token.hasPrefix(demoRoomTokenPrefix)
    }

    /// Keeps the launch image visible for `splashHoldDuration` so splash screenshots are easy to capture.
    static func installSplashHold(on window: UIWindow?) {
        guard let window else { return }

        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor(
            red: 0.011764705882352941,
            green: 0.58431372549019611,
            blue: 0.98431372549019602,
            alpha: 1
        )

        let imageView = UIImageView(image: UIImage(named: "launchscreen"))
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: overlay.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
        ])

        window.addSubview(overlay)
        splashOverlay = overlay

        DispatchQueue.main.asyncAfter(deadline: .now() + splashHoldDuration) {
            UIView.animate(withDuration: 0.25, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
                if splashOverlay === overlay {
                    splashOverlay = nil
                }
            })
        }
    }
}

#endif
