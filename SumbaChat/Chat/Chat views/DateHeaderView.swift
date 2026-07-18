//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

protocol DateHeaderViewDelegate: AnyObject {
    func dateHeaderViewTapped(inSection section: Int)
}

class DateHeaderView: UIView {

    static let maxHeight: CGFloat = 60
    static let horizontalPadding: CGFloat = 32
    static let verticalPadding: CGFloat = 16
    static let labelFont: UIFont = UIFont.preferredFont(forTextStyle: .footnote)
    private static let pillCornerRadius: CGFloat = 8

    public var section: Int = 0
    public weak var delegate: DateHeaderViewDelegate?

    public let titleLabel = PaddedLabel()
    private let pillView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        setupConstraints()
        setupGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        setupConstraints()
        setupGesture()
    }

    private func setupView() {
        backgroundColor = .clear

        titleLabel.textAlignment = .center
        titleLabel.font = DateHeaderView.labelFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.clipsToBounds = true
        pillView.layer.cornerRadius = DateHeaderView.pillCornerRadius

        if #available(iOS 26.0, *) {
            // Solid secondarySystemGroupedBackground fights Liquid Glass when the sticky
            // header touches the nav chrome (fill becomes ≈ textColor). Use a glass pill
            // so "Today" stays readable over photos and under the scroll edge.
            _ = pillView.installSumbaChromeEffect()
            pillView.viewWithTag(9_140_277)?.layer.cornerRadius = DateHeaderView.pillCornerRadius
            pillView.viewWithTag(9_140_277)?.clipsToBounds = true
        } else {
            pillView.backgroundColor = .secondarySystemGroupedBackground
            titleLabel.textColor = .secondaryLabel
        }

        addSubview(pillView)
        pillView.addSubview(titleLabel)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            pillView.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            pillView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: DateHeaderView.verticalPadding / 2),
            pillView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -DateHeaderView.verticalPadding / 2),
            pillView.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: DateHeaderView.horizontalPadding / 2),
            pillView.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -DateHeaderView.horizontalPadding / 2),

            titleLabel.topAnchor.constraint(equalTo: pillView.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),

            heightAnchor.constraint(lessThanOrEqualToConstant: DateHeaderView.maxHeight)
        ])
    }

    private func setupGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(headerTapped))
        self.addGestureRecognizer(tap)
    }

    @objc private func headerTapped() {
        delegate?.dateHeaderViewTapped(inSection: section)
    }

    static func height(for text: String, fittingWidth width: CGFloat) -> CGFloat {
        let maxLabelWidth = width - horizontalPadding
        let constraintRect = CGSize(width: maxLabelWidth, height: .greatestFiniteMagnitude)

        let boundingRect = text.boundingRect(
            with: constraintRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: labelFont],
            context: nil
        )

        let labelHeight = ceil(boundingRect.height)
        let labelVerticalInsets = PaddedLabel.textInsets.top + PaddedLabel.textInsets.bottom
        let totalHeight = labelHeight + labelVerticalInsets + verticalPadding

        return min(totalHeight, maxHeight)
    }
}
