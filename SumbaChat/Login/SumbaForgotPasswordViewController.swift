//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Nextcloud lost-password flow: `POST /lostpassword/email` with username or email.
@objcMembers final class SumbaForgotPasswordViewController: UIViewController, UITextFieldDelegate {

    private let serverURL: String
    private let initialIdentifier: String
    private var requestTask: URLSessionDataTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()

    private lazy var scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = NSLocalizedString("Forgot password", comment: "")
        return label
    }()

    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = NSLocalizedString("Enter your email or username. If an account exists, we’ll send a reset link.", comment: "")
        return label
    }()

    private lazy var identifierTextField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.placeholder = NSLocalizedString("Email or username", comment: "")
        field.textContentType = .username
        field.keyboardType = .emailAddress
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        field.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)

        let icon = UIImageView(image: UIImage(systemName: "envelope.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 52))
        icon.frame = CGRect(x: 16, y: 16, width: 20, height: 20)
        container.addSubview(icon)
        field.leftView = container
        field.leftViewMode = .always
        return field
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Send reset link", comment: "")
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = NCAppBranding.brandColor()
        configuration.baseForegroundColor = NCAppBranding.brandTextColor()
        configuration.imagePadding = 10
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(sendResetLink), for: .touchUpInside)
        return button
    }()

    private lazy var formStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            makeGap(8),
            subtitleLabel,
            makeGap(28),
            identifierTextField,
            makeGap(12),
            statusLabel
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        return stack
    }()

    init(serverURL: String, initialIdentifier: String = "") {
        self.serverURL = serverURL
        self.initialIdentifier = initialIdentifier
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Forgot password", comment: "")
        view.backgroundColor = .systemBackground
        NCAppBranding.styleViewController(self)
        navigationItem.largeTitleDisplayMode = .never

        if !initialIdentifier.isEmpty {
            identifierTextField.text = initialIdentifier
        }

        view.addSubview(scrollView)
        scrollView.addSubview(formStack)
        view.addSubview(sendButton)

        let frameGuide = scrollView.frameLayoutGuide
        let contentGuide = scrollView.contentLayoutGuide

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -12),

            formStack.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 32),
            formStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -16),
            formStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -20),
            formStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -40),

            identifierTextField.heightAnchor.constraint(equalToConstant: 52),

            sendButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sendButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            sendButton.heightAnchor.constraint(equalToConstant: 54),
            sendButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
        updateSendButtonState()
    }

    deinit {
        requestTask?.cancel()
        session.invalidateAndCancel()
    }

    private func makeGap(_ height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func textFieldEditingChanged() {
        updateSendButtonState()
    }

    private func trimmedIdentifier() -> String {
        identifierTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func updateSendButtonState() {
        if requestTask == nil {
            sendButton.isEnabled = !trimmedIdentifier().isEmpty
        }
    }

    @objc private func sendResetLink() {
        guard requestTask == nil else { return }

        let identifier = trimmedIdentifier()
        guard !identifier.isEmpty else {
            showStatus(NSLocalizedString("Enter your email or username.", comment: ""), isError: true)
            identifierTextField.becomeFirstResponder()
            return
        }

        dismissKeyboard()
        setLoading(true)
        fetchRequestToken { [weak self] token in
            guard let self else { return }
            self.postLostPasswordEmail(user: identifier, requestToken: token)
        }
    }

    /// Nextcloud frontpage POST needs a CSRF request token from the login page.
    private func fetchRequestToken(completion: @escaping (String?) -> Void) {
        let candidates = [
            "\(serverURL)/login",
            "\(serverURL)/index.php/login"
        ]

        fetchRequestToken(from: candidates, index: 0, completion: completion)
    }

    private func fetchRequestToken(from urls: [String], index: Int, completion: @escaping (String?) -> Void) {
        guard index < urls.count, let url = URL(string: urls[index]) else {
            requestTask = nil
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(NCAppBranding.userAgentForLogin(), forHTTPHeaderField: "User-Agent")

        requestTask = session.dataTask(with: request) { [weak self] data, _, error in
            if error != nil || data == nil {
                DispatchQueue.main.async {
                    self?.fetchRequestToken(from: urls, index: index + 1, completion: completion)
                }
                return
            }

            let html = String(data: data!, encoding: .utf8) ?? ""
            if let token = Self.extractRequestToken(from: html), !token.isEmpty {
                DispatchQueue.main.async {
                    self?.requestTask = nil
                    completion(token)
                }
                return
            }

            DispatchQueue.main.async {
                self?.fetchRequestToken(from: urls, index: index + 1, completion: completion)
            }
        }
        requestTask?.resume()
    }

    private static func extractRequestToken(from html: String) -> String? {
        let patterns = [
            #"data-requesttoken="([^"]+)""#,
            #""requesttoken"\s*:\s*"([^"]+)""#,
            #"name="requesttoken"\s+value="([^"]+)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               match.numberOfRanges > 1,
               let tokenRange = Range(match.range(at: 1), in: html) {
                return String(html[tokenRange])
            }
        }
        return nil
    }

    private func postLostPasswordEmail(user: String, requestToken: String?) {
        let candidates = [
            "\(serverURL)/lostpassword/email",
            "\(serverURL)/index.php/lostpassword/email"
        ]
        postLostPasswordEmail(user: user, requestToken: requestToken, urls: candidates, index: 0)
    }

    private func postLostPasswordEmail(user: String, requestToken: String?, urls: [String], index: Int) {
        guard index < urls.count, let url = URL(string: urls[index]) else {
            // Still show the privacy-preserving success copy — server may have accepted via an earlier path,
            // or mail is disabled; we must not leak account existence.
            finishWithGenericSuccess()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NCAppBranding.userAgentForLogin(), forHTTPHeaderField: "User-Agent")

        var bodyItems = [URLQueryItem(name: "user", value: user)]
        if let requestToken, !requestToken.isEmpty {
            bodyItems.append(URLQueryItem(name: "requesttoken", value: requestToken))
            request.setValue(requestToken, forHTTPHeaderField: "requesttoken")
        }
        var components = URLComponents()
        components.queryItems = bodyItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        requestTask = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleLostPasswordResponse(data: data,
                                                 response: response,
                                                 error: error,
                                                 user: user,
                                                 requestToken: requestToken,
                                                 urls: urls,
                                                 index: index)
            }
        }
        requestTask?.resume()
    }

    private func handleLostPasswordResponse(data: Data?,
                                            response: URLResponse?,
                                            error: Error?,
                                            user: String,
                                            requestToken: String?,
                                            urls: [String],
                                            index: Int) {
        requestTask = nil

        if let error {
            setLoading(false)
            showStatus(error.localizedDescription, isError: true)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            setLoading(false)
            showStatus(NSLocalizedString("The server did not return a valid response.", comment: ""), isError: true)
            return
        }

        if http.statusCode == 429 {
            setLoading(false)
            showStatus(SumbaServerConfiguration.tooManyAttemptsMessage, isError: true)
            return
        }

        // Wrong path / CSRF → try next candidate URL.
        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 412 {
            postLostPasswordEmail(user: user, requestToken: requestToken, urls: urls, index: index + 1)
            return
        }

        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? String,
           status == "error",
           let message = json["msg"] as? String,
           message.localizedCaseInsensitiveContains("disabled") {
            setLoading(false)
            showStatus(NSLocalizedString("Password reset is disabled on this server.", comment: ""), isError: true)
            return
        }

        // Nextcloud returns success even when the account/email is unknown (anti-enumeration).
        finishWithGenericSuccess()
    }

    private func finishWithGenericSuccess() {
        setLoading(false)
        showStatus(
            NSLocalizedString("If an account exists for that address, we've sent a reset link.", comment: ""),
            isError: false
        )
        sendButton.configuration?.title = NSLocalizedString("Send again", comment: "")
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.text = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func setLoading(_ loading: Bool) {
        identifierTextField.isEnabled = !loading
        if loading {
            sendButton.isEnabled = true
            sendButton.configuration?.showsActivityIndicator = true
            sendButton.configuration?.title = NSLocalizedString("Sending…", comment: "")
            statusLabel.isHidden = true
        } else {
            sendButton.configuration?.showsActivityIndicator = false
            sendButton.configuration?.title = NSLocalizedString("Send reset link", comment: "")
            updateSendButtonState()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendResetLink()
        return true
    }
}
