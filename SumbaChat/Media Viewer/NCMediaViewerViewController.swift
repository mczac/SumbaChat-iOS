//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit

/// Immersive chat media gallery (Telegram-style): dark chrome, swipe or edge-tap to advance,
/// title shows sender + time and gallery position — not the raw filename.
@objcMembers class NCMediaViewerViewController: UIViewController,
                                                UIPageViewControllerDelegate,
                                                UIPageViewControllerDataSource,
                                                NCMediaViewerPageViewControllerDelegate {

    private let room: NCRoom
    private let account: TalkAccount
    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var initialMessage: NCChatMessage
    /// Swipeable image/video messages in chat order (snapshot for this presentation).
    private var galleryMessages: [NCChatMessage] = []
    private var chromeHidden = false
    private var edgeTapEnabled = true
    private var galleryTapRecognizer: UITapGestureRecognizer?

    /// Plain footer — not `UIToolbar`. iOS 26 Liquid Glass regroups toolbar items and breaks centering.
    private lazy var galleryFooterBar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let leadingStack = UIStackView(arrangedSubviews: [shareFooterButton, showMessageFooterButton])
        leadingStack.axis = .horizontal
        leadingStack.alignment = .center
        leadingStack.spacing = 20
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(leadingStack)
        bar.addSubview(muteFooterButton)

        let centerX = leadingStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        let leading = leadingStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20)
        leading.isActive = false
        footerCenterXConstraint = centerX
        footerLeadingConstraint = leading

        NSLayoutConstraint.activate([
            centerX,
            leadingStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            leadingStack.bottomAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            muteFooterButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            muteFooterButton.centerYAnchor.constraint(equalTo: leadingStack.centerYAnchor),
            shareFooterButton.widthAnchor.constraint(equalToConstant: 44),
            shareFooterButton.heightAnchor.constraint(equalToConstant: 44),
            showMessageFooterButton.widthAnchor.constraint(equalToConstant: 44),
            showMessageFooterButton.heightAnchor.constraint(equalToConstant: 44),
            muteFooterButton.widthAnchor.constraint(equalToConstant: 44),
            muteFooterButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        return bar
    }()

    private var footerCenterXConstraint: NSLayoutConstraint?
    private var footerLeadingConstraint: NSLayoutConstraint?

    private lazy var shareFooterButton: UIButton = {
        makeGalleryFooterButton(
            systemName: "square.and.arrow.up",
            accessibilityLabel: NSLocalizedString("Share", comment: "Share media from gallery")
        ) { [unowned self] sender in
            guard let mediaPageViewController = self.getCurrentPageViewController() else { return }

            var itemsToShare: [Any] = []

            if let image = mediaPageViewController.currentImage {
                itemsToShare.append(image)
            } else if let videoURL = mediaPageViewController.currentVideoURL {
                itemsToShare.append(videoURL)
            } else {
                return
            }

            let activityViewController = UIActivityViewController(activityItems: itemsToShare, applicationActivities: nil)
            activityViewController.popoverPresentationController?.sourceView = sender
            activityViewController.popoverPresentationController?.sourceRect = sender.bounds
            self.present(activityViewController, animated: true)
        }
    }()

    private lazy var showMessageFooterButton: UIButton = {
        makeGalleryFooterButton(
            systemName: "text.magnifyingglass",
            accessibilityLabel: NSLocalizedString("Show in chat", comment: "Open message context in chat")
        ) { [unowned self] _ in
            guard let mediaPageViewController = self.getCurrentPageViewController() else { return }

            let message = mediaPageViewController.message

            if let account = message.account, let chatViewController = ContextChatViewController(forRoom: self.room, withAccount: account, withMessage: [], withHighlightId: 0) {
                chatViewController.showContext(ofMessageId: message.messageId, withLimit: 50, withCloseButton: true)

                let navController = NCNavigationController(rootViewController: chatViewController)
                self.present(navController, animated: true)
            }
        }
    }()

    private lazy var muteFooterButton: UIButton = {
        let button = makeGalleryFooterButton(
            systemName: "speaker.wave.2.fill",
            accessibilityLabel: NSLocalizedString("Mute", comment: "Mute video playback")
        ) { [unowned self] _ in
            guard let page = self.getCurrentPageViewController() else { return }
            let muted = page.toggleVideoMute()
            self.updateMuteFooterButton(muted: muted)
        }
        button.isHidden = true
        return button
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override var prefersStatusBarHidden: Bool {
        return chromeHidden
    }

    init(initialMessage: NCChatMessage, room: NCRoom, account: TalkAccount) {
        self.room = room
        self.initialMessage = initialMessage
        self.account = account

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        self.view.backgroundColor = .black
        self.galleryMessages = self.buildGalleryMessages()
        self.setupNavigationBar()
        self.applyDarkGalleryAppearance()

        self.pageController.delegate = self
        self.pageController.dataSource = self
        self.pageController.view.backgroundColor = .black
        self.pageController.view.translatesAutoresizingMaskIntoConstraints = false

        self.addChild(self.pageController)
        self.view.addSubview(self.pageController.view)
        self.view.addSubview(self.galleryFooterBar)
        self.pageController.didMove(toParent: self)

        // Full-bleed media under translucent chrome.
        NSLayoutConstraint.activate([
            self.pageController.view.leftAnchor.constraint(equalTo: self.view.leftAnchor),
            self.pageController.view.rightAnchor.constraint(equalTo: self.view.rightAnchor),
            self.pageController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.pageController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),

            self.galleryFooterBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.galleryFooterBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.galleryFooterBar.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])

        // Tap does not cancel touches — swipe / pinch still reach the pager and zoom view.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleGalleryTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        galleryTapRecognizer = tap

        let initialViewController = NCMediaViewerPageViewController(message: self.initialMessage, account: self.account)
        initialViewController.delegate = self
        self.pageController.setViewControllers([initialViewController], direction: .forward, animated: false)

        self.updateChrome(for: initialViewController)

        AllocationTracker.shared.addAllocation("NCMediaViewerViewController")
    }

    deinit {
        AllocationTracker.shared.removeAllocation("NCMediaViewerViewController")
    }

    func setupNavigationBar() {
        let closeButton = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: nil,
            action: nil
        )
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "")
        closeButton.primaryAction = UIAction { [unowned self] _ in
            self.dismiss(animated: true)
        }
        self.navigationItem.leftBarButtonItem = closeButton
        self.navigationItem.rightBarButtonItem = nil

        self.navigationController?.setToolbarHidden(true, animated: false)
    }

    private func makeGalleryFooterButton(
        systemName: String,
        accessibilityLabel: String,
        handler: @escaping (UIButton) -> Void
    ) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.isEnabled = false
        button.accessibilityLabel = accessibilityLabel
        button.adjustsImageWhenHighlighted = false

        if #available(iOS 26.0, *) {
            button.configuration = .glass()
            button.configuration?.image = UIImage(systemName: systemName)
        } else {
            button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            button.layer.cornerRadius = 22
            button.clipsToBounds = true
            button.setImage(UIImage(systemName: systemName), for: .normal)
        }

        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            handler(button)
        }, for: .touchUpInside)

        return button
    }

    private func updateMuteFooterButton(muted: Bool) {
        let imageName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"

        if #available(iOS 26.0, *), var configuration = muteFooterButton.configuration {
            configuration.image = UIImage(systemName: imageName)
            muteFooterButton.configuration = configuration
        } else {
            muteFooterButton.setImage(UIImage(systemName: imageName), for: .normal)
        }

        muteFooterButton.accessibilityLabel = muted
            ? NSLocalizedString("Unmute", comment: "Unmute video playback")
            : NSLocalizedString("Mute", comment: "Mute video playback")
    }

    private func updateFooterLayout(for page: NCMediaViewerPageViewController) {
        let isVideo = page.currentVideoURL != nil
        muteFooterButton.isHidden = !isVideo
        footerCenterXConstraint?.isActive = !isVideo
        footerLeadingConstraint?.isActive = isVideo

        if isVideo {
            updateMuteFooterButton(muted: page.isVideoMuted)
            muteFooterButton.isEnabled = true
        }
    }

    private func applyDarkGalleryAppearance() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        navigationController?.navigationBar.standardAppearance = navAppearance
        navigationController?.navigationBar.scrollEdgeAppearance = navAppearance
        navigationController?.navigationBar.compactAppearance = navAppearance
        navigationController?.navigationBar.tintColor = .white
        navigationController?.navigationBar.isTranslucent = true
    }

    func getCurrentPageViewController() -> NCMediaViewerPageViewController? {
        return self.pageController.viewControllers?.first as? NCMediaViewerPageViewController
    }

    // MARK: - Gallery list / chrome

    private func buildGalleryMessages() -> [NCChatMessage] {
        guard let results = getAllFileMessages() else { return [initialMessage] }

        var media: [NCChatMessage] = []
        for index in 0..<results.count {
            guard let message = results.object(at: UInt(index)) as? NCChatMessage, isGalleryMedia(message) else { continue }
            media.append(message)
        }

        if media.isEmpty {
            return [initialMessage]
        }
        return media
    }

    private func isGalleryMedia(_ message: NCChatMessage) -> Bool {
        guard let filePath = message.file()?.path else { return false }

        let fileType = message.file()?.mimetype ?? ""
        let isSupportedMedia = NCUtils.isImage(fileType: fileType) || NCUtils.isVideo(fileType: fileType)
        let isUnsupportedExtension = VLCKitVideoViewController.supportedFileExtensions.contains(
            URL(fileURLWithPath: filePath).pathExtension.lowercased()
        )
        return isSupportedMedia && !isUnsupportedExtension
    }

    private func galleryIndex(of message: NCChatMessage) -> Int? {
        return galleryMessages.firstIndex { $0.messageId == message.messageId }
    }

    private func updateChrome(for page: NCMediaViewerPageViewController) {
        let message = page.message
        let senderName: String = {
            if message.isMessage(from: account.userId) {
                return NSLocalizedString("You", comment: "Media gallery sender when message is from the current user")
            }
            let name = message.actorDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? NSLocalizedString("Guest", comment: "") : name
        }()

        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        var subtitleParts: [String] = [NCUtils.readableTimeAndDate(fromDate: date)]

        let index = galleryIndex(of: message)
        if let index, galleryMessages.count > 1 {
            subtitleParts.append(
                String.localizedStringWithFormat(
                    NSLocalizedString("%d of %d", comment: "Media gallery position, e.g. 3 of 12"),
                    index + 1,
                    galleryMessages.count
                )
            )
        }

        navigationItem.titleView = makeTitleView(title: senderName, subtitle: subtitleParts.joined(separator: "  ·  "))

        if let galleryTap = galleryTapRecognizer, let doubleTap = page.doubleTapGestureRecognizer {
            galleryTap.require(toFail: doubleTap)
        }

        let mediaReady = (page.currentImage != nil) || (page.currentVideoURL != nil)
        shareFooterButton.isEnabled = mediaReady
        showMessageFooterButton.isEnabled = mediaReady
        updateFooterLayout(for: page)
    }

    @objc private func handleGalleryTap(_ recognizer: UITapGestureRecognizer) {
        guard edgeTapEnabled, recognizer.state == .ended else { return }

        let x = recognizer.location(in: view).x
        let width = view.bounds.width
        guard width > 0 else { return }

        let edgeFraction: CGFloat = 0.22
        if x < width * edgeFraction {
            showAdjacentMedia(direction: .reverse)
        } else if x > width * (1 - edgeFraction) {
            showAdjacentMedia(direction: .forward)
        } else {
            toggleChrome()
        }
    }

    private func makeTitleView(title: String, subtitle: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .center
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let maxWidth = max(140, UIScreen.main.bounds.width - 120)
        let container = UIView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: maxWidth)
        ])

        return container
    }

    @objc private func toggleChrome() {
        chromeHidden.toggle()
        navigationController?.setNavigationBarHidden(chromeHidden, animated: true)
        galleryFooterBar.isHidden = chromeHidden
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showAdjacentMedia(direction: UIPageViewController.NavigationDirection) {
        guard let current = getCurrentPageViewController(),
              let index = galleryIndex(of: current.message) else { return }

        let nextIndex = direction == .forward ? index + 1 : index - 1
        guard galleryMessages.indices.contains(nextIndex) else { return }

        let page = NCMediaViewerPageViewController(message: galleryMessages[nextIndex], account: account)
        page.delegate = self
        pageController.setViewControllers([page], direction: direction, animated: true) { [weak self] completed in
            guard let self, completed else { return }
            self.updateChrome(for: page)
        }
    }

    // MARK: - PageViewController data source

    func getAllFileMessages() -> RLMResults<AnyObject>? {
        guard let accountId = self.initialMessage.accountId else { return nil }

        let query = NSPredicate(format: "accountId = %@ AND token = %@ AND messageParametersJSONString contains[cd] %@", accountId, self.initialMessage.token, "\"file\":")
        let messages = NCChatMessage.objects(with: query).sortedResults(usingKeyPath: "messageId", ascending: true)

        return messages
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let currentPage = viewController as? NCMediaViewerPageViewController,
              let index = galleryIndex(of: currentPage.message),
              index > 0
        else { return nil }

        let mediaPageViewController = NCMediaViewerPageViewController(message: galleryMessages[index - 1], account: account)
        mediaPageViewController.delegate = self
        return mediaPageViewController
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let currentPage = viewController as? NCMediaViewerPageViewController,
              let index = galleryIndex(of: currentPage.message),
              index < galleryMessages.count - 1
        else { return nil }

        let mediaPageViewController = NCMediaViewerPageViewController(message: galleryMessages[index + 1], account: account)
        mediaPageViewController.delegate = self
        return mediaPageViewController
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let mediaPageViewController = getCurrentPageViewController() else { return }
        updateChrome(for: mediaPageViewController)
    }

    // MARK: - NCMediaViewerPageViewController delegate

    func mediaViewerPageZoomDidChange(_ controller: NCMediaViewerPageViewController, _ scale: Double) {
        // Prevent the scrollView interfering with our pan gesture recognizer when the view is zoomed
        // Also disable dismissal gesture when the view is zoomed

        guard let navController = self.navigationController as? CustomPresentableNavigationController else { return }

        if scale == 1 {
            pageController.enableSwipeGesture()
            navController.dismissalGestureEnabled = true
            edgeTapEnabled = true
        } else {
            pageController.disableSwipeGesture()
            navController.dismissalGestureEnabled = false
            edgeTapEnabled = false
        }
    }

    func mediaViewerPageMediaDidLoad(_ controller: NCMediaViewerPageViewController) {
        if let mediaPageViewController = self.getCurrentPageViewController(), mediaPageViewController.isEqual(controller) {
            self.shareFooterButton.isEnabled = true
            self.showMessageFooterButton.isEnabled = true
            self.updateFooterLayout(for: mediaPageViewController)
        }
    }
}
