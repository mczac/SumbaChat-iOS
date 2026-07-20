//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Step 1: confirm account password before the irreversible countdown delete screen.
@objcMembers final class SumbaDeleteAccountPasswordViewController: UIViewController, UITextFieldDelegate {

    private let account: TalkAccount
    private var verifyTaskRunning = false

    private lazy var scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private lazy var accountNameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .label
        return label
    }()

    private lazy var accountHostLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 1
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var warningLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = SumbaDeleteAccountCopy.confirmationMessage
        return label
    }()

    private lazy var privacyPolicyButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = SumbaDeleteAccountCopy.privacyPolicyActionTitle
        configuration.baseForegroundColor = .link
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .footnote)
            attributes.underlineStyle = .single
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(privacyPolicyTapped), for: .touchUpInside)
        return button
    }()

    private lazy var passwordTextField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.placeholder = NSLocalizedString("Password", comment: "")
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        field.addTarget(self, action: #selector(passwordChanged), for: .editingChanged)

        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
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
        label.textColor = .systemRed
        label.isHidden = true
        return label
    }()

    private lazy var continueButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Continue", comment: "Delete account password step continue")
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        button.isEnabled = false
        return button
    }()

    private lazy var formStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            accountNameLabel,
            makeGap(4),
            accountHostLabel,
            makeGap(20),
            warningLabel,
            makeGap(8),
            privacyPolicyButton,
            makeGap(28),
            passwordTextField,
            makeGap(10),
            statusLabel
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        return stack
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
        title = NSLocalizedString("Delete account", comment: "")
        view.backgroundColor = .systemBackground
        NCAppBranding.styleViewController(self)
        navigationItem.largeTitleDisplayMode = .never

        view.addSubview(scrollView)
        scrollView.addSubview(formStack)
        view.addSubview(continueButton)

        let frameGuide = scrollView.frameLayoutGuide
        let contentGuide = scrollView.contentLayoutGuide

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -12),

            formStack.topAnchor.constraint(equalTo: contentGuide.topAnchor, constant: 40),
            formStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor, constant: -16),
            formStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 28),
            formStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -28),
            formStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -56),

            passwordTextField.heightAnchor.constraint(equalToConstant: 52),

            continueButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            continueButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            continueButton.heightAnchor.constraint(equalToConstant: 54),
            continueButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        populateAccountIdentity()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordTextField.becomeFirstResponder()
    }

    private func populateAccountIdentity() {
        let displayName = account.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = account.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = SumbaServerConfiguration.displayHost(fromServerURL: account.server)

        if !displayName.isEmpty {
            accountNameLabel.text = displayName
        } else if !user.isEmpty {
            accountNameLabel.text = user
        } else {
            accountNameLabel.text = NSLocalizedString("This account", comment: "Delete account fallback identity")
        }

        // No email — login is password-only; show server host only.
        accountHostLabel.text = host.isEmpty ? nil : host
        accountHostLabel.isHidden = host.isEmpty
    }

    private func makeGap(_ height: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    private func trimmedPassword() -> String {
        passwordTextField.text ?? ""
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func privacyPolicyTapped() {
        SumbaDeleteAccountCopy.openPrivacyPolicy(from: self, userId: account.userId)
    }

    @objc private func passwordChanged() {
        if !verifyTaskRunning {
            continueButton.isEnabled = !trimmedPassword().isEmpty
        }
        statusLabel.isHidden = true
    }

    @objc private func continueTapped() {
        guard !verifyTaskRunning else { return }
        let password = trimmedPassword()
        guard !password.isEmpty else { return }

        dismissKeyboard()
        setLoading(true)
        SumbaDeleteAccountService.verifyPassword(account: account, password: password) { [weak self] result in
            guard let self else { return }
            self.setLoading(false)
            switch result {
            case .success:
                let countdown = SumbaDeleteAccountCountdownViewController(account: self.account, password: password)
                countdown.modalPresentationStyle = .fullScreen
                self.present(countdown, animated: true)
            case .rateLimited:
                self.showPasswordError(SumbaServerConfiguration.tooManyAttemptsMessage)
            case .incorrectPassword:
                self.showPasswordError(NSLocalizedString("Incorrect password.", comment: ""))
            case .failed(let message):
                self.showPasswordError(message)
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        verifyTaskRunning = loading
        continueButton.isEnabled = loading ? false : !trimmedPassword().isEmpty
        passwordTextField.isEnabled = !loading

        var configuration = continueButton.configuration
        if loading {
            configuration?.showsActivityIndicator = true
            configuration?.title = NSLocalizedString("Checking…", comment: "")
        } else {
            configuration?.showsActivityIndicator = false
            configuration?.title = NSLocalizedString("Continue", comment: "Delete account password step continue")
        }
        continueButton.configuration = configuration
    }

    private func showPasswordError(_ message: String) {
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        shakePasswordField()
        passwordTextField.becomeFirstResponder()
    }

    private func shakePasswordField() {
        passwordTextField.layer.removeAnimation(forKey: "sumbaPasswordShake")
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-12, 12, -10, 10, -6, 6, -3, 3, 0]
        passwordTextField.layer.add(animation, forKey: "sumbaPasswordShake")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        continueTapped()
        return false
    }
}
