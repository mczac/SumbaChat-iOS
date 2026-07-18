//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension UIView {
    // From https://stackoverflow.com/a/36388769
    class func fromNib<T: UIView>() -> T {
        // swiftlint:disable:next force_cast
        return Bundle(for: T.self).loadNibNamed(String(describing: T.self), owner: nil, options: nil)![0] as! T
    }

    // https://stackoverflow.com/a/41288197
    // Using a function since `var image` might conflict with an existing variable
    // (like on `UIImageView`)
    func asImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { rendererContext in
            layer.render(in: rendererContext.cgContext)
        }
    }

    private static let sumbaChromeEffectTag = 9_140_277

    @available(iOS 26.0, *)
    @discardableResult
    func addGlassView(withStyle style: UIGlassEffect.Style = .regular) -> UIVisualEffectView {
        self.backgroundColor = .clear

        let effectView = UIVisualEffectView()
        self.insertSubview(effectView, at: 0)

        let glassEffect = UIGlassEffect(style: style)
        effectView.effect = glassEffect
        effectView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            effectView.leftAnchor.constraint(equalTo: self.leftAnchor),
            effectView.rightAnchor.constraint(equalTo: self.rightAnchor),
            effectView.topAnchor.constraint(equalTo: self.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        return effectView
    }

    /// Frosted chrome for chat composer pills: liquid glass on iOS 26+, ultra-thin material earlier.
    @discardableResult
    func installSumbaChromeEffect() -> UIVisualEffectView {
        viewWithTag(Self.sumbaChromeEffectTag)?.removeFromSuperview()
        backgroundColor = .clear

        let effectView = UIVisualEffectView()
        effectView.tag = Self.sumbaChromeEffectTag
        effectView.isUserInteractionEnabled = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(effectView, at: 0)

        if #available(iOS 26.0, *) {
            effectView.effect = UIGlassEffect(style: .regular)
        } else {
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }

        NSLayoutConstraint.activate([
            effectView.leftAnchor.constraint(equalTo: leftAnchor),
            effectView.rightAnchor.constraint(equalTo: rightAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        return effectView
    }
}
