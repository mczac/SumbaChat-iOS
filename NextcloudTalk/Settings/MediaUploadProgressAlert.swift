//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// System-alert–sized progress dialog (Telegram-style): title, detail, `UIProgressView`, Cancel.
/// Hosted as an overlay — not `UIAlertController` — so progress can update without re-presenting.
@objcMembers public final class MediaUploadProgressAlert: UIView {

    public var onCancel: (() -> Void)?

    private let dimmingView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        return view
    }()

    private let cardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 14
        view.clipsToBounds = true
        return view
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
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.progressTintColor = NCAppBranding.elementColor()
        view.trackTintColor = .tertiarySystemFill
        return view
    }()

    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
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

    private var showsCancel: Bool = true {
        didSet { cancelButton.isHidden = !showsCancel; separator.isHidden = !showsCancel }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false

        addSubview(dimmingView)
        addSubview(cardView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(messageLabel)
        cardView.addSubview(progressView)
        cardView.addSubview(spinner)
        cardView.addSubview(separator)
        cardView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Attach full-screen over `host` (typically the confirmation VC's view).
    public func present(on host: UIView, animated: Bool = true) {
        guard superview !== host else { return }
        removeFromSuperview()
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        if animated {
            alpha = 0
            cardView.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            UIView.animate(withDuration: 0.2) {
                self.alpha = 1
                self.cardView.transform = .identity
            }
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
        }, completion: { _ in
            finish()
        })
    }

    public func update(title: String, message: String, progress: Float?, indeterminate: Bool, showsCancel: Bool) {
        titleLabel.text = title
        messageLabel.text = message
        self.showsCancel = showsCancel

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
        guard !progressView.isHidden else { return }
        progressView.setProgress(max(0, min(1, progress)), animated: animated)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
