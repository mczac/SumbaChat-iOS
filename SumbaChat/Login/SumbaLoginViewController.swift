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

    private let serverURL: String
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

    /// Keeps the logo a fixed square while the form stack uses `.fill` for fields/buttons.
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
        label.text = NSLocalizedString("Enter your username and password to continue", comment: "")
        return label
    }()

    private lazy var usernameTextField = makeTextField(
        placeholder: NSLocalizedString("Username", comment: ""),
        systemImage: "person.fill",
        contentType: .username
    )

    private lazy var passwordVisibilityButton: UIButton = {
        let button = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
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
        label.translatesAutoresizingMaskIntoConstraints = false
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
            usernameTextField,
            makeGap(12),
            passwordTextField,
            makeGap(10),
            errorLabel,
            makeGap(18),
            loginButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        return stack
    }()

    init(serverURL: String) {
        self.serverURL = serverURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        registerForKeyboardNotifications()
        updateLoginButtonState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        view.addSubview(copyrightLabel)

        let frameGuide = scrollView.frameLayoutGuide
        let contentGuide = scrollView.contentLayoutGuide

        // Pin leading/trailing to the content guide (not just centerX) so the
        // scroll view's content size stays aligned with the screen width.
        // Keyboard only adjusts contentInset — no logo/spacer compression jump.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            formStack.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 32),
            formStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -24),
            formStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -20),
            formStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -40),

            logoContainer.heightAnchor.constraint(equalToConstant: 96),
            logoImageView.heightAnchor.constraint(equalToConstant: 96),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor),
            logoImageView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoImageView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),

            usernameTextField.heightAnchor.constraint(equalToConstant: 52),
            passwordTextField.heightAnchor.constraint(equalToConstant: 52),
            loginButton.heightAnchor.constraint(equalToConstant: 54),

            copyrightLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            copyrightLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            copyrightLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)
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
        field.textContentType = contentType
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

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 52))
        icon.frame = CGRect(x: 16, y: 16, width: 20, height: 20)
        container.addSubview(icon)
        field.leftView = container
        field.leftViewMode = .always
        return field
    }

    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        let keyboardFrameInView = view.convert(keyboardFrame, from: nil)
        let overlap = max(0, scrollView.frame.maxY - keyboardFrameInView.minY)
        let keyboardVisible = overlap > 0

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.scrollView.contentInset.bottom = overlap
            self.scrollView.verticalScrollIndicatorInsets.bottom = overlap
            self.copyrightLabel.alpha = keyboardVisible ? 0 : 1
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = 0
            self.scrollView.verticalScrollIndicatorInsets.bottom = 0
            self.copyrightLabel.alpha = 1
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func textFieldEditingChanged() {
        updateLoginButtonState()
    }

    private func hasCredentials() -> Bool {
        let username = usernameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = passwordTextField.text ?? ""
        return !username.isEmpty && !password.isEmpty
    }

    private func updateLoginButtonState() {
        // Keep the button disabled until both fields have content (unless logging in).
        if loginTask == nil {
            loginButton.isEnabled = hasCredentials()
        }
    }

    @objc private func togglePasswordVisibility(_ sender: UIButton) {
        passwordTextField.isSecureTextEntry.toggle()
        let imageName = passwordTextField.isSecureTextEntry ? "eye.slash" : "eye"
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        sender.setImage(UIImage(systemName: imageName, withConfiguration: symbolConfig), for: .normal)
        sender.accessibilityLabel = passwordTextField.isSecureTextEntry
            ? NSLocalizedString("Show password", comment: "")
            : NSLocalizedString("Hide password", comment: "")
    }

    @objc private func signIn() {
        guard loginTask == nil else {
            return
        }

        errorLabel.isHidden = true

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
        requestAppPassword(username: username, password: password)
    }

    private func requestAppPassword(username: String, password: String) {
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
                self?.handleLoginResponse(data: data, response: response, error: error, username: username)
            }
        }
        loginTask?.resume()
    }

    private func handleLoginResponse(data: Data?,
                                     response: URLResponse?,
                                     error: Error?,
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
            completeWithError(NSLocalizedString("Incorrect username or password.", comment: ""))
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

    private func completeWithError(_ message: String) {
        setLoading(false)
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func setLoading(_ loading: Bool) {
        usernameTextField.isEnabled = !loading
        passwordTextField.isEnabled = !loading

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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameTextField {
            passwordTextField.becomeFirstResponder()
        } else {
            signIn()
        }
        return true
    }
}
