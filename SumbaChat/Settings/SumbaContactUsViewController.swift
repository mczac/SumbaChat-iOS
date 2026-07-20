//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import MessageUI
import UIKit

/// Contact / feedback form inspired by Sanam `SendFeedbackView`:
/// soft composer → Send → thank-you. Mail still goes to the configured support address.
@objcMembers final class SumbaContactUsViewController: UIViewController, UITextViewDelegate, MFMailComposeViewControllerDelegate {

    private let account: TalkAccount
    private var feedbackSent = false

    private lazy var composerContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 12
        view.layer.shadowColor = UIColor.secondaryLabel.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 1.5
        view.layer.shadowOffset = .zero
        return view
    }()

    private lazy var messageTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        textView.textContainer.lineFragmentPadding = 5
        textView.returnKeyType = .default
        return textView
    }()

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = NSLocalizedString(
            "Send us a message if you are facing an issue with the app or have a feature request",
            comment: "Contact us placeholder"
        )
        return label
    }()

    private lazy var thankYouIcon: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        let view = UIImageView(image: UIImage(systemName: "checkmark.bubble.fill", withConfiguration: config))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = NCAppBranding.brandColor()
        view.contentMode = .scaleAspectFit
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        return view
    }()

    private lazy var thankYouLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = NSLocalizedString(
            "Thank you — we’re looking into your feedback…",
            comment: "Contact us success"
        )
        label.alpha = 0
        label.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        return label
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Send feedback", comment: "")
        configuration.image = UIImage(systemName: "paperplane.fill")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 10
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = NCAppBranding.brandColor()
        configuration.baseForegroundColor = NCAppBranding.brandTextColor()
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        button.isEnabled = false
        return button
    }()

    init(account: TalkAccount) {
        self.account = account
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Contact us", comment: "")
        view.backgroundColor = .systemGroupedBackground
        NCAppBranding.styleViewController(self)
        navigationItem.largeTitleDisplayMode = .never

        view.addSubview(composerContainer)
        // Placeholder is a sibling of the text view (not inside the scrollable text view)
        // so Auto Layout can wrap it to the composer width.
        composerContainer.addSubview(messageTextView)
        composerContainer.addSubview(placeholderLabel)
        view.addSubview(thankYouIcon)
        view.addSubview(thankYouLabel)
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            composerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            composerContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            composerContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            composerContainer.heightAnchor.constraint(equalToConstant: 180),

            messageTextView.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            messageTextView.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            messageTextView.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            messageTextView.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),

            // Match UITextView textContainerInset + lineFragmentPadding.
            placeholderLabel.topAnchor.constraint(equalTo: composerContainer.topAnchor, constant: 14),
            placeholderLabel.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 15),
            placeholderLabel.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -15),
            placeholderLabel.bottomAnchor.constraint(lessThanOrEqualTo: composerContainer.bottomAnchor, constant: -14),

            thankYouIcon.centerXAnchor.constraint(equalTo: composerContainer.centerXAnchor),
            thankYouIcon.centerYAnchor.constraint(equalTo: composerContainer.centerYAnchor, constant: -16),
            thankYouIcon.widthAnchor.constraint(equalToConstant: 72),
            thankYouIcon.heightAnchor.constraint(equalToConstant: 72),

            thankYouLabel.topAnchor.constraint(equalTo: thankYouIcon.bottomAnchor, constant: 16),
            thankYouLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            thankYouLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),

            sendButton.topAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: 24),
            sendButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sendButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            sendButton.heightAnchor.constraint(equalToConstant: 54)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = placeholderLabel.bounds.width
        if width > 1, placeholderLabel.preferredMaxLayoutWidth != width {
            placeholderLabel.preferredMaxLayoutWidth = width
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !feedbackSent {
            messageTextView.becomeFirstResponder()
        }
    }

    private func trimmedMessage() -> String {
        messageTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSendButtonState() {
        sendButton.isEnabled = !feedbackSent && !trimmedMessage().isEmpty
        placeholderLabel.isHidden = !messageTextView.text.isEmpty
    }

    /// Included in the email only — not shown on screen (Sanam-style).
    private func metaSummary() -> String {
        let host = SumbaServerConfiguration.displayHost(fromServerURL: account.server)
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = account.userId
        let version = NCAppBranding.getAppVersionString()
        var lines = [
            String(format: NSLocalizedString("Server: %@", comment: ""), host),
            String(format: NSLocalizedString("User: %@", comment: ""), user)
        ]
        if !email.isEmpty {
            lines.append(String(format: NSLocalizedString("Email: %@", comment: ""), email))
        }
        lines.append(String(format: NSLocalizedString("App: %@", comment: ""), version))
        return lines.joined(separator: "\n")
    }

    private func composedBody() -> String {
        """
        \(trimmedMessage())

        ———
        \(metaSummary())
        """
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func sendTapped() {
        guard !feedbackSent, !trimmedMessage().isEmpty else { return }
        dismissKeyboard()

        if MFMailComposeViewController.canSendMail() {
            let mail = MFMailComposeViewController()
            mail.mailComposeDelegate = self
            mail.setToRecipients([SumbaServerConfiguration.supportEmail])
            mail.setSubject(NSLocalizedString("SumbaChat feedback", comment: "Support email subject"))
            mail.setMessageBody(composedBody(), isHTML: false)
            present(mail, animated: true)
            return
        }

        openMailtoFallback()
    }

    private func showThankYouState() {
        guard !feedbackSent else { return }
        feedbackSent = true
        sendButton.isEnabled = false

        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            self.composerContainer.alpha = 0
            self.composerContainer.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.sendButton.alpha = 0
            self.sendButton.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        } completion: { _ in
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.6,
                options: []
            ) {
                self.thankYouIcon.alpha = 1
                self.thankYouIcon.transform = .identity
                self.thankYouLabel.alpha = 1
                self.thankYouLabel.transform = .identity
            } completion: { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                }
            }
        }
    }

    private func openMailtoFallback() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = SumbaServerConfiguration.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: NSLocalizedString("SumbaChat feedback", comment: "Support email subject")),
            URLQueryItem(name: "body", value: composedBody())
        ]

        guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
            presentUnavailableAlert()
            return
        }
        UIApplication.shared.open(url)
        // Can’t know if they sent — still acknowledge the handoff.
        showThankYouState()
    }

    private func presentUnavailableAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("Mail not available", comment: ""),
            message: String(
                format: NSLocalizedString(
                    "Please email us at %@ with your message.",
                    comment: "Contact us when no mail client"
                ),
                SumbaServerConfiguration.supportEmail
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Copy address", comment: ""), style: .default) { _ in
            UIPasteboard.general.string = SumbaServerConfiguration.supportEmail
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        updateSendButtonState()
    }

    // MARK: - MFMailComposeViewControllerDelegate

    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult,
        error: Error?
    ) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            switch result {
            case .sent:
                self.showThankYouState()
            case .failed:
                let alert = UIAlertController(
                    title: NSLocalizedString("Couldn’t send", comment: ""),
                    message: error?.localizedDescription
                        ?? String(
                            format: NSLocalizedString("Please try again or email %@.", comment: ""),
                            SumbaServerConfiguration.supportEmail
                        ),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                self.present(alert, animated: true)
            default:
                break
            }
        }
    }
}
