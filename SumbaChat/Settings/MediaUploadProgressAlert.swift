//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Upload progress overlay.
/// - `centeredAlert`: in-app HUD (title, bar, Cancel in one card) — no brand chrome.
/// - `bottomCompactBranded`: Share Extension — logo + name + progress, separate Cancel.
@objcMembers public final class MediaUploadProgressAlert: UIView {

    // Explicit ObjC name — bare `Style` clashes with UIKit typedefs in *-Swift.h.
    @objc(MediaUploadProgressAlertStyle)
    public enum Style: Int {
        case centeredAlert = 0
        /// Share Extension only — includes SumbaChat logo + name.
        case bottomCompactBranded = 1
    }

    public var onCancel: (() -> Void)?
    public let style: Style

    private let dimmingView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let cardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 14
        return view
    }()

    private let brandLogoView: UIImageView = {
        let view = UIImageView(image: NCAppBranding.navigationLogoImage())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.tintColor = NCAppBranding.elementColor()
        return view
    }()

    private let brandLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NCAppBranding.elementColor()
        label.textAlignment = .center
        label.numberOfLines = 1
        label.text = talkAppName
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        return label
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label.withAlphaComponent(0.72)
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.progressTintColor = NCAppBranding.elementColor()
        view.trackTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.22)
                : UIColor.black.withAlphaComponent(0.12)
        }
        return view
    }()

    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
        view.color = NCAppBranding.elementColor()
        return view
    }()

    private let separator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator
        return view
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    private lazy var bottomCancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 14
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    private var showsCancel: Bool = true {
        didSet { applyCancelVisibility() }
    }

    private var lastTitle = ""
    private var lastMessage = ""
    private var compactDeterminateConstraints: [NSLayoutConstraint] = []
    private var compactIndeterminateConstraints: [NSLayoutConstraint] = []
    private var showingCompactIndeterminate = true

    private var isBrandedBottomCompact: Bool {
        style == .bottomCompactBranded
    }

    public init(style: Style = .centeredAlert) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false

        addSubview(dimmingView)
        addSubview(cardView)
        cardView.addSubview(brandLogoView)
        cardView.addSubview(brandLabel)
        cardView.addSubview(titleLabel)
        cardView.addSubview(messageLabel)
        cardView.addSubview(progressView)
        cardView.addSubview(spinner)

        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        switch style {
        case .centeredAlert:
            dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            brandLogoView.isHidden = true
            brandLabel.isHidden = true
            cardView.clipsToBounds = true
            cardView.addSubview(separator)
            cardView.addSubview(cancelButton)
            installCenteredLayout()
        case .bottomCompactBranded:
            dimmingView.backgroundColor = .clear
            brandLogoView.isHidden = false
            brandLabel.isHidden = false
            applyElevatedCardChrome(to: cardView)
            bottomCancelButton.layer.cornerRadius = 14
            bottomCancelButton.clipsToBounds = true
            bottomCancelButton.layer.borderWidth = 1.0 / UIScreen.main.scale
            bottomCancelButton.layer.borderColor = UIColor.separator.cgColor
            addSubview(bottomCancelButton)
            installBrandedBottomCompactLayout()
        }
    }

    private func applyElevatedCardChrome(to view: UIView) {
        view.layer.masksToBounds = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 12
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.layer.borderWidth = 1.0 / UIScreen.main.scale
        view.layer.borderColor = UIColor.separator.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installCenteredLayout() {
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(equalToConstant: 270),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            progressView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            progressView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            spinner.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),

            separator.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            cancelButton.topAnchor.constraint(equalTo: separator.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
        ])
    }

    private func installBrandedBottomCompactLayout() {
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bottomCancelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bottomCancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bottomCancelButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            bottomCancelButton.heightAnchor.constraint(equalToConstant: 50),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            cardView.bottomAnchor.constraint(equalTo: bottomCancelButton.topAnchor, constant: -8),

            brandLogoView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            brandLogoView.widthAnchor.constraint(equalToConstant: 36),
            brandLogoView.heightAnchor.constraint(equalToConstant: 36),

            brandLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            brandLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            progressView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            spinner.centerXAnchor.constraint(equalTo: cardView.centerXAnchor)
        ])

        compactIndeterminateConstraints = [
            brandLogoView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            brandLabel.topAnchor.constraint(equalTo: brandLogoView.bottomAnchor, constant: 0),
            spinner.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 14),
            spinner.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),
            cardView.heightAnchor.constraint(equalToConstant: 126)
        ]

        compactDeterminateConstraints = [
            brandLogoView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            brandLabel.topAnchor.constraint(equalTo: brandLogoView.bottomAnchor, constant: 0),
            titleLabel.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 10),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            progressView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            progressView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: progressView.centerYAnchor)
        ]

        NSLayoutConstraint.activate(compactIndeterminateConstraints)
        titleLabel.isHidden = true
        messageLabel.isHidden = true
        progressView.isHidden = true
    }

    private func applyCancelVisibility() {
        switch style {
        case .centeredAlert:
            cancelButton.isHidden = !showsCancel
            separator.isHidden = !showsCancel
        case .bottomCompactBranded:
            bottomCancelButton.isHidden = !showsCancel
        }
    }

    private func setCompactIndeterminate(_ indeterminate: Bool) {
        guard isBrandedBottomCompact, showingCompactIndeterminate != indeterminate else {
            if isBrandedBottomCompact, indeterminate {
                spinner.startAnimating()
            }
            return
        }
        showingCompactIndeterminate = indeterminate
        NSLayoutConstraint.deactivate(compactDeterminateConstraints)
        NSLayoutConstraint.deactivate(compactIndeterminateConstraints)
        brandLogoView.isHidden = false
        brandLabel.isHidden = false
        if indeterminate {
            titleLabel.isHidden = true
            messageLabel.isHidden = true
            progressView.isHidden = true
            NSLayoutConstraint.activate(compactIndeterminateConstraints)
            spinner.startAnimating()
        } else {
            titleLabel.isHidden = false
            messageLabel.isHidden = false
            progressView.isHidden = false
            spinner.stopAnimating()
            NSLayoutConstraint.activate(compactDeterminateConstraints)
        }
    }

    public func present(on host: UIView, animated: Bool = true) {
        if superview === host {
            host.bringSubviewToFront(self)
            if alpha < 1 { alpha = 1 }
            return
        }
        removeFromSuperview()
        host.addSubview(self)
        host.bringSubviewToFront(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        let canAnimate = animated && host.window != nil
        if canAnimate {
            alpha = 0
            if isBrandedBottomCompact {
                cardView.transform = CGAffineTransform(translationX: 0, y: 24)
                bottomCancelButton.transform = CGAffineTransform(translationX: 0, y: 24)
                UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                    self.alpha = 1
                    self.cardView.transform = .identity
                    self.bottomCancelButton.transform = .identity
                }
            } else {
                cardView.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                UIView.animate(withDuration: 0.2) {
                    self.alpha = 1
                    self.cardView.transform = .identity
                }
            }
        } else {
            alpha = 1
            cardView.transform = .identity
            bottomCancelButton.transform = .identity
        }
    }

    public func dismiss(animated: Bool = true, completion: (() -> Void)? = nil) {
        let finish = {
            self.removeFromSuperview()
            completion?()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
            if self.isBrandedBottomCompact {
                self.cardView.transform = CGAffineTransform(translationX: 0, y: 16)
                self.bottomCancelButton.transform = CGAffineTransform(translationX: 0, y: 16)
            }
        }, completion: { _ in
            finish()
        })
    }

    public func update(title: String, message: String, progress: Float?, indeterminate: Bool, showsCancel: Bool) {
        lastTitle = title
        lastMessage = message
        titleLabel.text = title
        messageLabel.text = message
        self.showsCancel = showsCancel

        if isBrandedBottomCompact {
            accessibilityLabel = "\(talkAppName). \(title). \(message)"
            let hasProgress = !(indeterminate || progress == nil || (progress ?? 0) <= 0.001)
            setCompactIndeterminate(!hasProgress)
            if hasProgress, let progress {
                progressView.setProgress(max(0, min(1, progress)), animated: true)
            }
            return
        }

        accessibilityLabel = "\(title). \(message)"

        if indeterminate || progress == nil {
            progressView.isHidden = true
            progressView.progress = 0
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            progressView.isHidden = false
            progressView.setProgress(max(0, min(1, progress!)), animated: true)
        }
    }

    public func setProgress(_ progress: Float, animated: Bool = true) {
        if isBrandedBottomCompact {
            if showingCompactIndeterminate, progress > 0.001 {
                update(title: lastTitle, message: lastMessage, progress: progress, indeterminate: false, showsCancel: showsCancel)
                return
            }
            guard !progressView.isHidden else { return }
            progressView.setProgress(max(0, min(1, progress)), animated: animated)
            return
        }
        guard !progressView.isHidden else { return }
        progressView.setProgress(max(0, min(1, progress)), animated: animated)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
