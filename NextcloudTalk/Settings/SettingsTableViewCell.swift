//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Telegram-inspired palette for main Settings icon tiles.
enum SettingsIconColor {
    static let red = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)          // privacy / alerts
    static let orange = UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1)         // system / devices
    static let yellow = UIColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)         // power / warnings
    static let green = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)        // calls / data
    static let blue = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)           // media / appearance
    static let lightBlue = UIColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1)    // folders / extras
    static let purple = UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)       // language / about
    static let gray = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)         // security
}

class SettingsTableViewCell: UITableViewCell {

    private static let iconTileSize = CGSize(width: 29, height: 29)
    private static let iconCornerRadius: CGFloat = 7
    private static let iconSymbolPointSize: CGFloat = 15

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        textLabel?.numberOfLines = 0
        detailTextLabel?.numberOfLines = 0
        detailTextLabel?.textColor = .secondaryLabel
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        textLabel?.text = nil
        detailTextLabel?.text = nil
        imageView?.image = nil
        imageView?.tintColor = nil
        accessoryView = nil
        accessoryType = .none
        selectionStyle = .default
    }

    /// Legacy gray template icon (kept for non-main / transitional callers).
    func setSettingsImage(image: UIImage?, renderingMode: UIImage.RenderingMode = .alwaysTemplate) {
        self.imageView?.image = NCUtils.renderAspectImage(image: image, ofSize: .init(width: 20, height: 20), centerImage: true)?.withRenderingMode(renderingMode)
        self.imageView?.tintColor = .secondaryLabel
        self.imageView?.contentMode = .scaleAspectFit
    }

    /// Telegram-style colored rounded square with a white glyph.
    func setColoredSettingsIcon(systemName: String, backgroundColor: UIColor) {
        let config = UIImage.SymbolConfiguration(pointSize: Self.iconSymbolPointSize, weight: .semibold)
        let symbol = UIImage(systemName: systemName, withConfiguration: config)
        setColoredSettingsIcon(image: symbol, backgroundColor: backgroundColor)
    }

    /// Telegram-style colored rounded square with a white glyph (SF Symbol or template asset).
    func setColoredSettingsIcon(image: UIImage?, backgroundColor: UIColor) {
        let tile = Self.makeIconTile(symbol: image, backgroundColor: backgroundColor)
        imageView?.image = tile
        imageView?.tintColor = nil
        imageView?.contentMode = .center
    }

    private static func makeIconTile(symbol: UIImage?, backgroundColor: UIColor) -> UIImage {
        let size = iconTileSize
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: iconCornerRadius)
            backgroundColor.setFill()
            path.fill()

            guard let symbol else { return }

            let template = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
            let maxSymbolSide = size.width * 0.58
            let symbolSize = template.size
            let scale = min(maxSymbolSide / max(symbolSize.width, 1), maxSymbolSide / max(symbolSize.height, 1))
            let drawSize = CGSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            template.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
