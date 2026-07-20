//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

@objc protocol SumbaLoginViewControllerDelegate: AnyObject {
    func sumbaLoginViewControllerDidFinish(_ viewController: SumbaLoginViewController)
}

@objcMembers final class SumbaLoginViewController: UIViewController, UITextFieldDelegate {

    weak var delegate: SumbaLoginViewControllerDelegate?

    private let initialSubdomain: String
    private let initialUsername: String?
    private var loginTask: URLSessionDataTask?
    private lazy var loginSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
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

    private lazy var logoImageView: UIImageView = {
        let image = (UIImage(named: "sumbaLoginLogo") ?? UIImage(systemName: "bubble.left.and.bubble.right.fill"))?
            .withRenderingMode(.alwaysTemplate)
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        // Adapts with the interface: white on the dark login background.
        imageView.tintColor = .label
        return imageView
    }()

    /// Keeps the logo a fixed square while the form stack uses `.fill` for fields.
    private lazy var logoContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(logoImageView)
        return container
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 32, weight: .heavy)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.textAlignment = .center
        label.text = "SumbaChat"
        return label
    }()

    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.text = NSLocalizedString("Enter your server, username and password", comment: "")
        return label
    }()

    /// Editable subdomain only; domain suffix sits immediately after the typed text.
    private lazy var subdomainTextField: UITextField = {
        let field = SumbaFlushTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.placeholder = NSLocalizedString("Server", comment: "Subdomain label before domain suffix")
        field.textContentType = .URL
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .never
        field.returnKeyType = .next
        field.enablesReturnKeyAutomatically = true
        field.text = initialSubdomain
        // Grow with typed text, but yield to the fixed domain suffix on narrow widths.
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)
        return field
    }()

    private lazy var subdomainSuffixLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = SumbaServerConfiguration.domainSuffix
        // Match the subdomain field font exactly so width math and glyphs align.
        label.font = subdomainTextField.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private var subdomainFieldWidthConstraint: NSLayoutConstraint?
    /// Positions domain suffix at the end of the typed text (not the field’s trailing edge / caret slack).
    private var subdomainSuffixLeadingConstraint: NSLayoutConstraint?
    /// Last subdomain we successfully probed (or attempted); avoids re-probing while typing other fields.
    private var lastProbedSubdomain: String?
    private var serverStatus: SumbaServerConfiguration.ServerStatus?
    private var statusProbeGeneration = 0

    private lazy var serverStatusDot: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "circle.fill"))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    private lazy var serverStatusSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel
        return spinner
    }()

    private lazy var subdomainServerRow: UIView = {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 12
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.separator.cgColor
        row.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "server.rack"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(icon)
        row.addSubview(subdomainTextField)
        row.addSubview(subdomainSuffixLabel)
        row.addSubview(serverStatusDot)
        row.addSubview(serverStatusSpinner)

        let width = subdomainTextField.widthAnchor.constraint(equalToConstant: 40)
        width.priority = .defaultHigh
        subdomainFieldWidthConstraint = width

        // Pin suffix to measured text width from the field’s leading edge — not trailing —
        // so caret slack never opens a gap before domain suffix.
        let suffixLeading = subdomainSuffixLabel.leadingAnchor.constraint(
            equalTo: subdomainTextField.leadingAnchor,
            constant: 40
        )
        subdomainSuffixLeadingConstraint = suffixLeading

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            subdomainTextField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            subdomainTextField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            subdomainTextField.heightAnchor.constraint(equalTo: row.heightAnchor),
            width,

            suffixLeading,
            subdomainSuffixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            subdomainSuffixLabel.trailingAnchor.constraint(lessThanOrEqualTo: serverStatusDot.leadingAnchor, constant: -8),

            serverStatusDot.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            serverStatusDot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            serverStatusDot.widthAnchor.constraint(equalToConstant: 12),
            serverStatusDot.heightAnchor.constraint(equalToConstant: 12),

            serverStatusSpinner.centerXAnchor.constraint(equalTo: serverStatusDot.centerXAnchor),
            serverStatusSpinner.centerYAnchor.constraint(equalTo: serverStatusDot.centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(focusSubdomainField))
        row.addGestureRecognizer(tap)
        return row
    }()

    private lazy var usernameTextField: UITextField = {
        let field = makeTextField(
            placeholder: NSLocalizedString("Username", comment: ""),
            systemImage: "person.fill",
            contentType: .username
        )
        if let initialUsername, !initialUsername.isEmpty {
            field.text = initialUsername
        }
        return field
    }()

    private lazy var passwordVisibilityButton: UIButton = {
        let button = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.setImage(UIImage(systemName: "eye.slash", withConfiguration: symbolConfig), for: .normal)
        button.tintColor = .secondaryLabel
        button.frame = CGRect(x: 0, y: 0, width: 36, height: 52)
        button.accessibilityLabel = NSLocalizedString("Show password", comment: "")
        button.addTarget(self, action: #selector(togglePasswordVisibility), for: .touchUpInside)
        return button
    }()

    private lazy var passwordTextField: UITextField = {
        let field = makeTextField(
            placeholder: NSLocalizedString("Password", comment: ""),
            systemImage: "lock.fill",
            contentType: .password
        )
        field.isSecureTextEntry = true
        field.returnKeyType = .go

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 52))
        passwordVisibilityButton.frame = CGRect(x: 0, y: 0, width: 36, height: 52)
        container.addSubview(passwordVisibilityButton)
        field.rightView = container
        field.rightViewMode = .always
        return field
    }()

    private lazy var loginButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Log in", comment: "")
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = NCAppBranding.brandColor()
        configuration.baseForegroundColor = NCAppBranding.brandTextColor()
        // Space between the activity indicator and the title while logging in.
        configuration.imagePadding = 10
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }()

    private lazy var forgotPasswordButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = NSLocalizedString("Forgot password?", comment: "")
        configuration.baseForegroundColor = .systemBlue
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .footnote)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.addTarget(self, action: #selector(forgotPasswordTapped), for: .touchUpInside)
        return button
    }()

    private lazy var errorLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.textAlignment = .center
        label.isHidden = true
        label.accessibilityTraits = .staticText
        return label
    }()

    private lazy var copyrightLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        label.text = "\(copyright)\n\(licenseNotice)"
        return label
    }()

    private lazy var formStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            logoContainer,
            makeGap(20),
            titleLabel,
            makeGap(6),
            subtitleLabel,
            makeGap(28),
            subdomainServerRow,
            makeGap(12),
            usernameTextField,
            makeGap(12),
            passwordTextField,
            makeGap(8),
            forgotPasswordButton,
            makeGap(10),
            errorLabel,
            makeGap(24),
            copyrightLabel
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        return stack
    }()

    /// - Parameters:
    ///   - initialSubdomain: Prefill for the server label (default: last used, else branding default).
    ///   - initialUsername: Prefill for username/email (e.g. when switching server).
    init(initialSubdomain: String? = nil, initialUsername: String? = nil) {
        self.initialSubdomain = SumbaServerConfiguration.normalizeSubdomain(initialSubdomain ?? "")
            ?? SumbaServerConfiguration.preferredSubdomain
        let trimmed = initialUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.initialUsername = trimmed.isEmpty ? nil : trimmed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        updateLoginButtonState()
    }

    deinit {
        loginTask?.cancel()
        loginSession.invalidateAndCancel()
    }

    private func configureView() {
        title = NSLocalizedString("Sign in", comment: "")
        view.backgroundColor = .systemBackground
        NCAppBranding.styleViewController(self)

        if NCDatabaseManager.sharedInstance().numberOfAccounts() > 0 {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }

        view.addSubview(scrollView)
        scrollView.addSubview(formStack)
        view.addSubview(loginButton)

        let frameGuide = scrollView.frameLayoutGuide
        let contentGuide = scrollView.contentLayoutGuide

        // Log in rides above the keyboard via keyboardLayoutGuide; form scrolls above it.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: loginButton.topAnchor, constant: -12),

            formStack.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 32),
            formStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -16),
            formStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -20),
            formStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -40),

            logoContainer.heightAnchor.constraint(equalToConstant: 96),
            logoImageView.heightAnchor.constraint(equalToConstant: 96),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),

            subdomainServerRow.heightAnchor.constraint(equalToConstant: 52),
            usernameTextField.heightAnchor.constraint(equalToConstant: 52),
            passwordTextField.heightAnchor.constraint(equalToConstant: 52),

            loginButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            loginButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            loginButton.heightAnchor.constraint(equalToConstant: 54),
            loginButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        updateSubdomainFieldWidth()
        // Prefill — probe once so Log in can enable without re-editing the server field.
        probeServerStatusIfNeeded(force: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSubdomainFieldWidth()
    }

    @objc private func focusSubdomainField() {
        subdomainTextField.becomeFirstResponder()
    }

    private func updateSubdomainFieldWidth() {
        let font = subdomainTextField.font ?? .systemFont(ofSize: 18)
        let hasText = !(subdomainTextField.text ?? "").isEmpty
        let measuringText: String
        if hasText {
            measuringText = subdomainTextField.text ?? ""
        } else {
            measuringText = subdomainTextField.placeholder ?? "Server"
        }
        let measured = ceil((measuringText as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).width)
        // Suffix sits flush after glyphs; field is slightly wider only so the caret has room.
        let caretSlack: CGFloat = 2
        subdomainSuffixLeadingConstraint?.constant = measured
        // Keep suffix font in lockstep with the field (Dynamic Type).
        subdomainSuffixLabel.font = font

        let desired: CGFloat
        if hasText {
            desired = max(measured + caretSlack, 8)
        } else {
            desired = max(measured + caretSlack, 28)
        }

        // Cap so icon + field + domain suffix always fit the row on narrow phones.
        let rowWidth = subdomainServerRow.bounds.width
        if rowWidth > 1 {
            let suffixWidth = ceil(
                (SumbaServerConfiguration.domainSuffix as NSString)
                    .boundingRect(
                        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: font],
                        context: nil
                    )
                    .width
            )
            // Leading icon + padding + suffix + status dot slot + trailing padding.
            let reserved: CGFloat = 12 + 20 + 6 + suffixWidth + 8 + 12 + 14
            let maxFieldWidth = max(rowWidth - reserved, 28)
            let capped = min(desired, maxFieldWidth)
            subdomainFieldWidthConstraint?.constant = capped
            // Keep suffix inside the capped field when the subdomain is truncated.
            if capped < measured {
                subdomainSuffixLeadingConstraint?.constant = max(capped - caretSlack, 0)
            }
        } else {
            subdomainFieldWidthConstraint?.constant = desired
        }
    }

    private func currentNormalizedSubdomain() -> String? {
        SumbaServerConfiguration.normalizeSubdomain(subdomainTextField.text ?? "")
    }

    /// Probe `status.php` after the server field is done editing (or once for prefill).
    private func probeServerStatusIfNeeded(force: Bool = false) {
        guard let subdomain = currentNormalizedSubdomain(),
              let serverURL = SumbaServerConfiguration.serverURL(subdomain: subdomain) else {
            lastProbedSubdomain = nil
            applyServerStatus(nil, isChecking: false)
            updateLoginButtonState()
            return
        }

        if !force, subdomain == lastProbedSubdomain, serverStatus != nil {
            return
        }

        lastProbedSubdomain = subdomain
        statusProbeGeneration += 1
        let generation = statusProbeGeneration
        applyServerStatus(nil, isChecking: true)
        updateLoginButtonState()

        SumbaServerConfiguration.checkServerStatus(serverURL: serverURL) { [weak self] status in
            guard let self, generation == self.statusProbeGeneration else { return }
            // Subdomain may have changed while the probe was in flight.
            guard self.currentNormalizedSubdomain() == subdomain else { return }
            self.applyServerStatus(status, isChecking: false)
            self.updateLoginButtonState()
        }
    }

    private func applyServerStatus(_ status: SumbaServerConfiguration.ServerStatus?, isChecking: Bool) {
        serverStatus = status
        if isChecking {
            serverStatusDot.isHidden = true
            serverStatusSpinner.startAnimating()
            serverStatusDot.accessibilityLabel = NSLocalizedString("Checking server", comment: "")
            return
        }

        serverStatusSpinner.stopAnimating()
        guard let status else {
            serverStatusDot.isHidden = true
            serverStatusDot.accessibilityLabel = nil
            return
        }

        serverStatusDot.isHidden = false
        switch status {
        case .online:
            serverStatusDot.tintColor = .systemGreen
            serverStatusDot.accessibilityLabel = NSLocalizedString("Server online", comment: "")
        case .maintenance:
            serverStatusDot.tintColor = .systemOrange
            serverStatusDot.accessibilityLabel = NSLocalizedString("Server under maintenance", comment: "")
        case .offline:
            serverStatusDot.tintColor = .systemRed
            serverStatusDot.accessibilityLabel = NSLocalizedString("Server offline", comment: "")
        }
    }

    private var isServerOnlineForLogin: Bool {
        serverStatus == .online
    }

    private func makeGap(_ height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func makeTextField(placeholder: String,
                               systemImage: String,
                               contentType: UITextContentType) -> UITextField {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.placeholder = placeholder
        // Simulator AutoFill often replaces Paste / ⌘V with an “AutoFill” affordance only.
        // Keep username/password content types on device; skip them in Simulator for paste.
        #if targetEnvironment(simulator)
        field.textContentType = nil
        #else
        field.textContentType = contentType
        #endif
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        // Return key stays dimmed until the field has content.
        field.enablesReturnKeyAutomatically = true
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit

        // Tight left adornment: 12 leading + 20 icon + 6 before text.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 52))
        icon.frame = CGRect(x: 12, y: 16, width: 20, height: 20)
        container.addSubview(icon)
        field.leftView = container
        field.leftViewMode = .always
        return field
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func textFieldEditingChanged() {
        if subdomainTextField.isFirstResponder || subdomainTextField.text != nil {
            updateSubdomainFieldWidth()
        }
        // Typing a new server invalidates the last probe until blur.
        if subdomainTextField.isFirstResponder {
            let normalized = currentNormalizedSubdomain()
            if normalized != lastProbedSubdomain {
                lastProbedSubdomain = nil
                applyServerStatus(nil, isChecking: false)
            }
        }
        updateLoginButtonState()
    }

    private func resolvedServerURL() -> String? {
        SumbaServerConfiguration.serverURL(subdomain: subdomainTextField.text ?? "")
    }

    private func hasCredentials() -> Bool {
        let username = usernameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = passwordTextField.text ?? ""
        return resolvedServerURL() != nil && !username.isEmpty && !password.isEmpty
    }

    private func updateLoginButtonState() {
        // Log in only when credentials are filled and the server probe reports online.
        if loginTask == nil {
            loginButton.isEnabled = hasCredentials() && isServerOnlineForLogin
        }
    }

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        passwordTextField.isSecureTextEntry.toggle()
        let imageName = passwordTextField.isSecureTextEntry ? "eye.slash" : "eye"
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        sender.setImage(UIImage(systemName: imageName, withConfiguration: symbolConfig), for: .normal)
        sender.accessibilityLabel = passwordTextField.isSecureTextEntry
            ? NSLocalizedString("Show password", comment: "")
            : NSLocalizedString("Hide password", comment: "")
    }

    @objc private func forgotPasswordTapped() {
        dismissKeyboard()
        guard let serverURL = resolvedServerURL() else {
            showValidationError(NSLocalizedString("Enter a valid server name.", comment: ""), field: subdomainTextField)
            return
        }
        let identifier = usernameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let forgot = SumbaForgotPasswordViewController(serverURL: serverURL, initialIdentifier: identifier)
        navigationController?.pushViewController(forgot, animated: true)
    }

    @objc private func signIn() {
        guard loginTask == nil else {
            return
        }

        errorLabel.isHidden = true

        guard let serverURL = resolvedServerURL() else {
            showValidationError(NSLocalizedString("Enter a valid server name.", comment: ""), field: subdomainTextField)
            return
        }

        guard isServerOnlineForLogin else {
            if serverStatus == nil {
                probeServerStatusIfNeeded(force: true)
            }
            showValidationError(
                NSLocalizedString("Server is offline or under maintenance.", comment: ""),
                field: subdomainTextField
            )
            return
        }

        guard let username = usernameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty else {
            showValidationError(NSLocalizedString("Enter your username.", comment: ""), field: usernameTextField)
            return
        }

        guard let password = passwordTextField.text, !password.isEmpty else {
            showValidationError(NSLocalizedString("Enter your password.", comment: ""), field: passwordTextField)
            return
        }

        dismissKeyboard()
        setLoading(true)
        requestAppPassword(serverURL: serverURL, username: username, password: password)
    }

    private func requestAppPassword(serverURL: String, username: String, password: String) {
        guard let url = URL(string: "\(serverURL)/ocs/v2.php/core/getapppassword?format=json") else {
            completeWithError(NSLocalizedString("The server address is invalid.", comment: ""))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NCAppBranding.userAgentForLogin(), forHTTPHeaderField: "User-Agent")

        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        loginTask = loginSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleLoginResponse(data: data, response: response, error: error, serverURL: serverURL, username: username)
            }
        }
        loginTask?.resume()
    }

    private func handleLoginResponse(data: Data?,
                                     response: URLResponse?,
                                     error: Error?,
                                     serverURL: String,
                                     username: String) {
        loginTask = nil

        if let error {
            completeWithError(error.localizedDescription)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            completeWithError(NSLocalizedString("The server did not return a valid response.", comment: ""))
            return
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            completeWithError(
                NSLocalizedString("Incorrect username or password.", comment: ""),
                shakeCredentials: true
            )
            return
        }

        if httpResponse.statusCode == 429 {
            completeWithError(SumbaServerConfiguration.tooManyAttemptsMessage, shakeCredentials: true)
            return
        }

        guard (200...299).contains(httpResponse.statusCode),
              let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let responseData = ocs["data"] as? [String: Any],
              let appPassword = responseData["apppassword"] as? String,
              !appPassword.isEmpty else {
            let message = serverErrorMessage(from: data)
                ?? NSLocalizedString("Sign in failed. Check your details and try again.", comment: "")
            completeWithError(message)
            return
        }

        passwordTextField.text = nil
        if let subdomain = SumbaServerConfiguration.subdomain(fromServerURL: serverURL) {
            SumbaServerConfiguration.rememberSubdomain(subdomain)
        }
        NCSettingsController.sharedInstance().addNewAccount(forUser: username, withToken: appPassword, inServer: serverURL)
        setLoading(false)
        delegate?.sumbaLoginViewControllerDidFinish(self)
    }

    private func serverErrorMessage(from data: Data?) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let meta = ocs["meta"] as? [String: Any],
              let message = meta["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }

    private func showValidationError(_ message: String, field: UITextField) {
        errorLabel.text = message
        errorLabel.isHidden = false
        field.becomeFirstResponder()
    }

    private func completeWithError(_ message: String, shakeCredentials: Bool = false) {
        setLoading(false)
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
        if shakeCredentials {
            // Generic copy doesn’t say which field failed — shake both.
            shakeView(usernameTextField)
            shakeView(passwordTextField)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func shakeView(_ view: UIView) {
        view.layer.removeAnimation(forKey: "sumbaLoginShake")
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-12, 12, -10, 10, -6, 6, -3, 3, 0]
        view.layer.add(animation, forKey: "sumbaLoginShake")
    }

    private func setLoading(_ loading: Bool) {
        subdomainTextField.isEnabled = !loading
        subdomainServerRow.alpha = loading ? 0.6 : 1
        usernameTextField.isEnabled = !loading
        passwordTextField.isEnabled = !loading
        forgotPasswordButton.isEnabled = !loading

        if loading {
            loginButton.isEnabled = true
            loginButton.configuration?.showsActivityIndicator = true
            loginButton.configuration?.title = NSLocalizedString("Logging in…", comment: "")
        } else {
            loginButton.configuration?.showsActivityIndicator = false
            loginButton.configuration?.title = NSLocalizedString("Log in", comment: "")
            updateLoginButtonState()
        }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === subdomainTextField {
            updateSubdomainFieldWidth()
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === subdomainTextField {
            updateSubdomainFieldWidth()
            probeServerStatusIfNeeded()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === subdomainTextField {
            // Blur triggers the status probe, then move to username.
            usernameTextField.becomeFirstResponder()
        } else if textField === usernameTextField {
            passwordTextField.becomeFirstResponder()
        } else {
            signIn()
        }
        return true
    }
}

/// Zero text insets so measured glyph width matches where characters actually draw.
private final class SumbaFlushTextField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds }
}
