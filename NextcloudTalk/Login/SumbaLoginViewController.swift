//
// SPDX-FileCopyrightText: 2026 SumbaChat contributors
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

    private lazy var logoImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "sumbaLoginLogo") ?? UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        // Compress first when vertical space is tight.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return imageView
    }()

    private lazy var logoContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(logoImageView)
        container.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
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
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
        label.translatesAutoresizingMaskIntoConstraints = false
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

    /// Prefer roomy gaps; Auto Layout may compress them when the keyboard is up.
    private lazy var afterLogoSpacer = makeSpacer(preferred: 14, minimum: 6)
    private lazy var afterTitleSpacer = makeSpacer(preferred: 6, minimum: 2)
    private lazy var afterSubtitleSpacer = makeSpacer(preferred: 28, minimum: 8)
    private lazy var afterUsernameSpacer = makeSpacer(preferred: 12, minimum: 8)
    private lazy var beforeButtonSpacer = makeSpacer(preferred: 18, minimum: 8)

    private lazy var formStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            logoContainer,
            afterLogoSpacer,
            titleLabel,
            afterTitleSpacer,
            subtitleLabel,
            afterSubtitleSpacer,
            usernameTextField,
            afterUsernameSpacer,
            passwordTextField,
            errorLabel,
            beforeButtonSpacer,
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let side = logoImageView.bounds.width
        guard side > 0 else { return }
        logoImageView.layer.cornerRadius = min(18, side * 0.2)
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

        view.addSubview(formStack)
        view.addSubview(copyrightLabel)

        let stackFillWidth = formStack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -40)
        stackFillWidth.priority = .defaultHigh

        // Prefer a roomy top inset; allow it to compress slightly on short screens.
        let preferredTop = formStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        preferredTop.priority = .defaultHigh
        let minimumTop = formStack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)

        // Keep the form clear of the keyboard. Compression happens on logo/spacers first.
        let keyboardClearance = formStack.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor,
            constant: -12
        )

        let preferredLogoHeight = logoContainer.heightAnchor.constraint(equalToConstant: 88)
        preferredLogoHeight.priority = .defaultHigh
        let minimumLogoHeight = logoContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)

        NSLayoutConstraint.activate([
            stackFillWidth,
            preferredTop,
            minimumTop,
            formStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            formStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            formStack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            keyboardClearance,

            preferredLogoHeight,
            minimumLogoHeight,
            logoImageView.heightAnchor.constraint(equalTo: logoContainer.heightAnchor),
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
        view.addGestureRecognizer(tapGesture)
    }

    private func makeSpacer(preferred: CGFloat, minimum: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let preferredHeight = spacer.heightAnchor.constraint(equalToConstant: preferred)
        preferredHeight.priority = .defaultHigh
        let minimumHeight = spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum)
        NSLayoutConstraint.activate([preferredHeight, minimumHeight])
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
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        field.setContentCompressionResistancePriority(.required, for: .vertical)

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

        let frameInView = view.convert(keyboardFrame, from: nil)
        let keyboardVisible = frameInView.minY < view.bounds.maxY - 1
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.copyrightLabel.alpha = keyboardVisible ? 0 : 1
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) {
            self.copyrightLabel.alpha = 1
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
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
        loginButton.isEnabled = !loading

        if loading {
            loginButton.configuration?.showsActivityIndicator = true
            loginButton.configuration?.title = NSLocalizedString("Logging in…", comment: "")
        } else {
            loginButton.configuration?.showsActivityIndicator = false
            loginButton.configuration?.title = NSLocalizedString("Log in", comment: "")
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
