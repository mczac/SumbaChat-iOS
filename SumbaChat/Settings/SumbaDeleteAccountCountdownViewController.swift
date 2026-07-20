//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Step 2: Sanam-style countdown so the user can still cancel before deletion runs.
@objcMembers final class SumbaDeleteAccountCountdownViewController: UIViewController {

    private enum Phase {
        case counting
        case deleting
        case finished
        case failed
    }

    private let account: TalkAccount
    private let password: String
    private let duration = 5

    private var phase: Phase = .counting
    private var remaining = 5
    private var countdownTimer: Timer?
    private var progressDisplayLink: CADisplayLink?
    private var countdownStartedAt: CFTimeInterval = 0

    private lazy var shredderView: SumbaShredderView = {
        let view = SumbaShredderView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = NSLocalizedString("Deleting account", comment: "")
        return label
    }()

    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private lazy var cancelButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .secondarySystemFill
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 22)
        configuration.imagePadding = 10
        configuration.title = NSLocalizedString("Cancel", comment: "").uppercased()
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 16, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    private lazy var countdownRing: SumbaCountdownRingView = {
        let ring = SumbaCountdownRingView()
        ring.translatesAutoresizingMaskIntoConstraints = false
        return ring
    }()

    init(account: TalkAccount, password: String) {
        self.account = account
        self.password = password
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        isModalInPresentation = true

        view.addSubview(shredderView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(cancelButton)

        // Countdown ring is drawn as the cancel button’s leading image via configuration.
        cancelButton.configuration?.image = countdownRing.snapshotImage()

        let displayName = account.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = account.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = SumbaServerConfiguration.displayHost(fromServerURL: account.server)
        let identity = [displayName.isEmpty ? user : displayName, host]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if identity.isEmpty {
            subtitleLabel.text = NSLocalizedString(
                "We are deleting this account. You can still cancel before the countdown ends. This cannot be undone.",
                comment: "Delete account countdown subtitle"
            )
        } else {
            subtitleLabel.text = String(
                format: NSLocalizedString(
                    "Deleting “%@”. You can still cancel before the countdown ends. This cannot be undone.",
                    comment: "Delete account countdown subtitle with account identity"
                ),
                identity
            )
        }

        NSLayoutConstraint.activate([
            shredderView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shredderView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            shredderView.widthAnchor.constraint(equalToConstant: 160),
            shredderView.heightAnchor.constraint(equalToConstant: 160),

            titleLabel.topAnchor.constraint(equalTo: shredderView.bottomAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase == .counting else { return }
        shredderView.startAnimating()
        startCountdown()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdown()
        shredderView.stopAnimating()
    }

    private func startCountdown() {
        remaining = duration
        countdownStartedAt = CACurrentMediaTime()
        updateCancelButtonImage(progress: 1, counter: remaining)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.phase == .counting else {
                timer.invalidate()
                return
            }
            self.remaining -= 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if self.remaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.finishCountdown()
            } else {
                self.updateCancelButtonImage(progress: CGFloat(self.remaining) / CGFloat(self.duration), counter: self.remaining)
            }
        }

        progressDisplayLink = CADisplayLink(target: self, selector: #selector(tickProgress))
        progressDisplayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tickProgress() {
        guard phase == .counting else { return }
        let elapsed = CACurrentMediaTime() - countdownStartedAt
        let progress = max(0, 1 - (elapsed / CFTimeInterval(duration)))
        updateCancelButtonImage(progress: CGFloat(progress), counter: max(remaining, 0))
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        progressDisplayLink?.invalidate()
        progressDisplayLink = nil
    }

    private func updateCancelButtonImage(progress: CGFloat, counter: Int) {
        var configuration = cancelButton.configuration
        configuration?.image = countdownRing.image(progress: progress, counter: counter)
        cancelButton.configuration = configuration
    }

    private func finishCountdown() {
        phase = .deleting
        stopCountdown()
        cancelButton.isEnabled = false
        subtitleLabel.text = NSLocalizedString("Removing your account…", comment: "")
        var configuration = cancelButton.configuration
        configuration?.title = NSLocalizedString("Deleting…", comment: "").uppercased()
        configuration?.showsActivityIndicator = true
        configuration?.image = nil
        cancelButton.configuration = configuration

        let accountId = account.accountId
        NCLog.log("Delete account: countdown finished — starting deletion for \(accountId)")
        SumbaDeleteAccountService.deleteAccount(account: account, password: password) { [weak self] result in
            guard let self else { return }
            switch result {
            case .deleted:
                NCLog.log("Delete account: UI success — logging out \(accountId)")
                self.phase = .finished
                self.shredderView.playFinish()
                self.titleLabel.text = NSLocalizedString("Account deleted", comment: "")
                self.subtitleLabel.text = NSLocalizedString("Your data was completely removed.", comment: "")
                self.cancelButton.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.logoutAndDismiss()
                }
            case .failed(let message):
                NCLog.log("Delete account: UI failure for \(accountId) — \(message)")
                self.phase = .failed
                self.stopShredAndShowMessage(
                    title: NSLocalizedString("Couldn’t delete account", comment: ""),
                    message: message
                )
            }
        }
    }

    private func stopShredAndShowMessage(title: String, message: String) {
        shredderView.stopAnimating()
        titleLabel.text = title
        subtitleLabel.text = message
        cancelButton.isEnabled = true
        var configuration = cancelButton.configuration
        configuration?.showsActivityIndicator = false
        configuration?.image = nil
        configuration?.title = NSLocalizedString("Close", comment: "").uppercased()
        cancelButton.configuration = configuration
        cancelButton.removeTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    }

    private func logoutAndDismiss() {
        let accountId = account.accountId
        // Capture before logout removes the account from Realm.
        let hadOtherAccounts = NCDatabaseManager.sharedInstance().numberOfAccounts() > 1
        NCLog.log("Delete account: logging out and removing local account \(accountId) hadOtherAccounts=\(hadOtherAccounts)")

        NCSettingsController.sharedInstance().logoutAccount(withAccountId: accountId) { error in
            if let error {
                NCLog.log("Delete account: logout finished with error for \(accountId) — \(error.localizedDescription)")
            } else {
                NCLog.log("Delete account: logout completed for \(accountId)")
            }

            let ui = NCUserInterfaceController.sharedInstance()
            // Dismiss countdown + Settings (and any nested presents) from the root.
            ui.mainViewController.dismiss(animated: true) {
                if hadOtherAccounts {
                    NCLog.log("Delete account: returning to conversations (other accounts remain)")
                    ui.popToConversationsList()
                    NCConnectionController.shared.checkAppState()
                } else {
                    NCLog.log("Delete account: no accounts left — presenting login")
                    NCConnectionController.shared.checkAppState()
                }
            }
        }
    }

    @objc private func cancelTapped() {
        guard phase == .counting else { return }
        phase = .failed
        stopCountdown()
        shredderView.stopAnimating()
        dismiss(animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

// MARK: - Countdown ring (Sanam CountDown, small)

private final class SumbaCountdownRingView: UIView {

    private let size: CGFloat = 22
    private let lineWidth: CGFloat = 2.5

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func snapshotImage() -> UIImage {
        image(progress: 1, counter: 5)
    }

    func image(progress: CGFloat, counter: Int) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            let rect = CGRect(x: lineWidth / 2, y: lineWidth / 2, width: size - lineWidth, height: size - lineWidth)

            UIColor.tertiaryLabel.setStroke()
            cg.setLineWidth(lineWidth)
            cg.strokeEllipse(in: rect)

            UIColor.label.setStroke()
            cg.setLineCap(.round)
            let start = -CGFloat.pi / 2
            let end = start + (2 * .pi * max(0, min(1, progress)))
            cg.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: (size - lineWidth) / 2, startAngle: start, endAngle: end, clockwise: false)
            cg.strokePath()

            let text = "\(max(counter, 0))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.label
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attrs
            )
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Fixed-size shredder decoration (cannot affect surrounding layout)

private final class SumbaShredderView: UIView {

    private let documentView = UIImageView()
    private let slotView = UIView()
    private let stripsContainer = UIView()
    private var stripLayers: [CALayer] = []
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.contentMode = .scaleAspectFit
        documentView.tintColor = .secondaryLabel
        documentView.image = UIImage(systemName: "doc.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .regular))

        slotView.translatesAutoresizingMaskIntoConstraints = false
        slotView.backgroundColor = UIColor.label.withAlphaComponent(0.18)
        slotView.layer.cornerRadius = 3

        stripsContainer.translatesAutoresizingMaskIntoConstraints = false
        stripsContainer.clipsToBounds = true
        stripsContainer.isUserInteractionEnabled = false

        addSubview(documentView)
        addSubview(slotView)
        addSubview(stripsContainer)

        NSLayoutConstraint.activate([
            documentView.centerXAnchor.constraint(equalTo: centerXAnchor),
            documentView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            documentView.widthAnchor.constraint(equalToConstant: 72),
            documentView.heightAnchor.constraint(equalToConstant: 80),

            slotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            slotView.topAnchor.constraint(equalTo: documentView.bottomAnchor, constant: 6),
            slotView.widthAnchor.constraint(equalToConstant: 88),
            slotView.heightAnchor.constraint(equalToConstant: 6),

            stripsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stripsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stripsContainer.topAnchor.constraint(equalTo: slotView.bottomAnchor, constant: 4),
            stripsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard stripLayers.isEmpty else { return }
        buildStrips()
    }

    private func buildStrips() {
        stripsContainer.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        stripLayers.removeAll()

        let stripCount = 7
        let width = stripsContainer.bounds.width
        let height = stripsContainer.bounds.height
        guard width > 0, height > 0 else { return }

        let stripWidth = (width - CGFloat(stripCount - 1) * 4) / CGFloat(stripCount)
        for index in 0..<stripCount {
            let layer = CALayer()
            layer.backgroundColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            layer.cornerRadius = 2
            layer.frame = CGRect(
                x: CGFloat(index) * (stripWidth + 4),
                y: -height,
                width: stripWidth,
                height: height * 0.55
            )
            stripsContainer.layer.addSublayer(layer)
            stripLayers.append(layer)
        }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        if stripLayers.isEmpty {
            layoutIfNeeded()
            buildStrips()
        }

        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseIn, .repeat, .autoreverse], animations: {
            self.documentView.transform = CGAffineTransform(translationX: 0, y: 10)
        })

        for (index, layer) in stripLayers.enumerated() {
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = -layer.bounds.height
            animation.toValue = stripsContainer.bounds.height + layer.bounds.height
            animation.duration = 1.1
            animation.beginTime = CACurrentMediaTime() + (Double(index) * 0.08)
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(animation, forKey: "fall")
        }
    }

    func stopAnimating() {
        isAnimating = false
        documentView.layer.removeAllAnimations()
        documentView.transform = .identity
        stripLayers.forEach { $0.removeAllAnimations() }
    }

    func playFinish() {
        stopAnimating()
        documentView.tintColor = .systemGreen
        documentView.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .regular))
        stripLayers.forEach { $0.opacity = 0 }
    }
}
