//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NextcloudKit
import QuickLook
import SwiftyAttributes
import TOCropViewController
import AVFoundation

@objc public protocol ShareConfirmationViewControllerDelegate {
    @objc func shareConfirmationViewControllerDidFail(_ viewController: ShareConfirmationViewController)
    @objc func shareConfirmationViewControllerDidFinish(_ viewController: ShareConfirmationViewController)
    @objc func shareConfirmationViewControllerDidCancel(_ viewController: ShareConfirmationViewController)
}

@objcMembers public class ShareConfirmationViewController: InputbarViewController,
                                                           NKCommonDelegate,
                                                           ShareItemControllerDelegate,
                                                           UIImagePickerControllerDelegate,
                                                           UIDocumentPickerDelegate,
                                                           UINavigationControllerDelegate,
                                                           UICollectionViewDelegateFlowLayout,
                                                           TOCropViewControllerDelegate,
                                                           QLPreviewControllerDataSource,
                                                           QLPreviewControllerDelegate {

    // MARK: - Public var

    public var isModal: Bool = false
    public var forwardingMessage: Bool = false

    public weak var delegate: ShareConfirmationViewControllerDelegate?

    public lazy var shareItemController: ShareItemController = {
        // Stage originals; compress on Send based on user Upload Media mode.
        let controller = ShareItemController(mediaUploadCompressionSettings: MediaUploadCompressionSettings(level: .none))
        controller.delegate = self
        controller.accountId = self.account.accountId

        return controller
    }()

    // MARK: - Private var

    private var serverCapabilities: ServerCapabilities
    private var shareType: ShareConfirmationType = .item
    private var shareContentView = UIView()
    private var shareSilently = false
    private var imagePicker: UIImagePickerController?
    private var progressAlert: MediaUploadProgressAlert?
    private var objectShareMessage: NCChatMessage?
    private var uploadGroup = DispatchGroup()
    private var uploadFailed = false
    private var uploadErrors: [String] = []
    private var uploadSuccess: [ShareItem] = []
    private var chosenCompressionLevel: MediaUploadCompressionLevel = .medium
    private var isPreparingForUpload = false {
        didSet { self.updateSheetDismissLock() }
    }
    /// True from Send until upload finishes/fails — blocks double-Send (seen on iOS 18 Manual).
    private var isUploadingMedia = false {
        didSet { self.updateSheetDismissLock() }
    }
    /// Skip QL / large image decode while compressing or uploading (jetsam mitigation).
    private var suppressMediaPreviews = false
    /// Object identities currently shown in the pager — used to insert/delete pages without reload flash.
    private var pagerItemIdentities: [ObjectIdentifier] = []
    /// Set when the user hits Cancel during prepare/upload — prepare completion must not start PUT.
    private var mediaFlowCancelled = false
    /// In-flight NextcloudKit upload tasks so Cancel can stop the network side too.
    private var uploadTasks: [URLSessionTask] = []
    /// After a successful upload we clear staged items; don't treat that as user cancel in the share extension.
    private var finishingSuccessfulUpload = false
    /// Avoid stacking multiple "couldn't load" alerts while several attachments fail.
    private var isPresentingStagingFailureAlert = false
    /// Share of the determinate bar reserved for compression prepare (often longer than upload).
    private let prepareProgressShare: Float = 0.55
    /// True while Send has swapped compose UI for the progress surface.
    private var isInSendProgressMode = false
    /// Keeps App Group `.upload-session` fresh during long compose (Settings/idle protection).
    private var uploadSessionHeartbeatTimer: Timer?

    private enum ShareConfirmationType {
        case text
        case item
        case objectShare
    }

    // MARK: - UI Controls

    private lazy var sendButton: UIBarButtonItem = {
        let sendButton = UIBarButtonItem(title: NSLocalizedString("Send", comment: ""), style: .done, target: self, action: #selector(sendButtonPressed))
        sendButton.accessibilityHint = NSLocalizedString("Double tap to share with selected conversations", comment: "")
        return sendButton
    }()

    private lazy var sharingIndicatorView: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView()

        if #unavailable(iOS 26.0) {
            indicator.color = NCAppBranding.themeTextColor()
        }

        return indicator
    }()

    private lazy var toLabel: UILabel = {
        var label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false

        return label
    }()

    private lazy var toLabelView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.addSubview(self.toLabel)

        NSLayoutConstraint.activate([
            self.toLabel.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 20),
            self.toLabel.rightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.rightAnchor, constant: -20),
            self.toLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            self.toLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        return view
    }()

    private lazy var itemToolbar: UIToolbar = {
        let toolbar = UIToolbar(frame: .init(x: 0, y: 0, width: 100, height: 44))

        toolbar.barTintColor = .systemBackground
        toolbar.isTranslucent = false

        if #unavailable(iOS 26) {
            toolbar.setItems([removeItemButton, UIBarButtonItem(systemItem: .flexibleSpace), cropItemButton, previewItemButton, addItemButton], animated: false)
        } else {
            toolbar.setItems([UIBarButtonItem(systemItem: .flexibleSpace), removeItemButton, UIBarButtonItem(systemItem: .fixedSpace), cropItemButton, previewItemButton, addItemButton], animated: false)
        }

        toolbar.translatesAutoresizingMaskIntoConstraints = false

        return toolbar
    }()

    private lazy var removeItemButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: .init(systemName: "trash"))
        button.width = 56
        button.target = self
        button.action = #selector(removeItemButtonPressed)

        return button
    }()

    private lazy var cropItemButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: .init(systemName: "crop.rotate"))
        button.width = 56
        button.target = self
        button.action = #selector(cropItemButtonPressed)

        return button
    }()

    private lazy var previewItemButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: .init(systemName: "eye"))
        button.width = 56
        button.target = self
        button.action = #selector(previewItemButtonPressed)

        return button
    }()

    private lazy var addItemButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: .init(systemName: "plus"))
        button.width = 56

        var items: [UIAction] = []

        let cameraAction = UIAction(title: NSLocalizedString("Camera", comment: ""), image: UIImage(systemName: "camera")) { [unowned self] _ in
            self.textView.resignFirstResponder()
            self.checkAndPresentCamera()
        }

        let photoLibraryAction = UIAction(title: NSLocalizedString("Photo Library", comment: ""), image: UIImage(systemName: "photo")) { [unowned self] _ in
            self.textView.resignFirstResponder()
            self.presentPhotoLibrary()
        }

        let filesAction = UIAction(title: NSLocalizedString("Files", comment: ""), image: UIImage(systemName: "doc")) { [unowned self] _ in
            self.textView.resignFirstResponder()
            self.presentDocumentPicker()
        }

#if !APP_EXTENSION
        // Camera access is not available in app extensions
        // https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(cameraAction)
        }
#endif

        items.append(photoLibraryAction)
        items.append(filesAction)

        button.menu = UIMenu(children: items)

        return button
    }()

    private lazy var compressionOptionsView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for level in [MediaUploadCompressionLevel.none, .low, .medium, .high] {
            let button = UIButton(type: .system)
            button.tag = level.rawValue
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.lineBreakMode = .byClipping
            button.layer.cornerRadius = 8
            button.layer.borderWidth = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 2, bottom: 5, right: 2)
            button.addTarget(self, action: #selector(compressionOptionPressed(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        return stack
    }()

    private lazy var compressionTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        // Sentence case — chip sizes already communicate “est. size”; all-caps shouted redundancy.
        label.text = NSLocalizedString("Compression", comment: "Share sheet section header above compression quality chips")
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var compressionSectionView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [self.compressionTitleLabel, self.compressionOptionsView])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    private var compressionSectionHeightConstraint: NSLayoutConstraint?

    private lazy var shareCollectionViewLayout: UICollectionViewFlowLayout = {
        // Make sure that we use a layout that invalidates itself when the bounds changed
        let layout = BoundsChangedFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        return layout
    }()

    private lazy var shareCollectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .init(x: 0, y: 0, width: 10, height: 10), collectionViewLayout: self.shareCollectionViewLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.backgroundColor = .systemBackground
        return collectionView
    }()

    private lazy var shareTextView: UITextView = {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isHidden = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        return textView
    }()

    private lazy var pageControl: UIPageControl = {
        let pageControl = UIPageControl()
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.currentPageIndicatorTintColor = NCAppBranding.elementColor()
        pageControl.pageIndicatorTintColor = NCAppBranding.placeholderColor()
        pageControl.hidesForSinglePage = true
        pageControl.numberOfPages = 1
        pageControl.addTarget(self, action: #selector(pageControlValueChanged), for: .valueChanged)

        return pageControl
    }()

    // MARK: - Init.

    public init?(room: NCRoom, thread: NCThread?, account: TalkAccount, serverCapabilities: ServerCapabilities) {
        self.serverCapabilities = serverCapabilities

        super.init(forRoom: room, withAccount: account, withView: self.shareContentView)
        self.thread = thread

        self.shareContentView.addSubview(self.shareCollectionView)
        self.shareContentView.addSubview(self.pageControl)
        self.shareContentView.addSubview(self.shareTextView)
        self.shareContentView.addSubview(self.itemToolbar)
        self.shareContentView.addSubview(self.compressionSectionView)

        NSLayoutConstraint.activate([
            self.shareTextView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor, constant: 20),
            self.shareTextView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor, constant: -20),
            self.shareTextView.bottomAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        // Keep chips close to the toolbar (iOS 18 look); leave a little room for iOS 26 glass buttons.
        let compressionTopSpacing: CGFloat = {
            if #available(iOS 26, *) {
                return 10
            }
            return 8
        }()

        NSLayoutConstraint.activate([
            self.itemToolbar.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
            self.itemToolbar.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
            self.itemToolbar.heightAnchor.constraint(equalToConstant: 44),

            self.compressionSectionView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor, constant: 12),
            self.compressionSectionView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor, constant: -12),
            self.compressionSectionView.topAnchor.constraint(equalTo: self.itemToolbar.bottomAnchor, constant: compressionTopSpacing)
        ])

        let compressionHeight = self.compressionSectionView.heightAnchor.constraint(equalToConstant: 0)
        compressionHeight.isActive = true
        self.compressionSectionHeightConstraint = compressionHeight

        if #unavailable(iOS 26) {
            self.shareContentView.addSubview(self.toLabelView)

            NSLayoutConstraint.activate([
                self.toLabelView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
                self.toLabelView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
                self.toLabelView.topAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.topAnchor),
                self.toLabelView.heightAnchor.constraint(equalToConstant: 36),

                self.shareTextView.topAnchor.constraint(equalTo: self.toLabelView.bottomAnchor, constant: 20),

                self.itemToolbar.topAnchor.constraint(equalTo: self.toLabelView.bottomAnchor)
            ])
        } else {
            // On iOS 26 we don't have a toLabel anymore, so we need to constraint to the safe area as well
            NSLayoutConstraint.activate([
                self.shareTextView.topAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.topAnchor),

                self.itemToolbar.topAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.topAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            self.shareCollectionView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
            self.shareCollectionView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
            self.shareCollectionView.topAnchor.constraint(equalTo: self.compressionSectionView.bottomAnchor, constant: 8),
            self.shareCollectionView.bottomAnchor.constraint(equalTo: self.pageControl.topAnchor, constant: -8),

            self.pageControl.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
            self.pageControl.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
            self.pageControl.heightAnchor.constraint(equalToConstant: 26),
            self.pageControl.bottomAnchor.constraint(equalTo: self.textInputbar.topAnchor)
        ])
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func shareText(_ sharedText: String) {
        self.shareType = .text

        DispatchQueue.main.async {
            self.setTextInputbarHidden(true, animated: false)
            self.shareCollectionView.isHidden = true
            self.itemToolbar.isHidden = true
            self.compressionSectionView.isHidden = true
            self.compressionSectionHeightConstraint?.constant = 0
            self.shareTextView.isHidden = false
            self.shareTextView.text = sharedText

            // When an item of type "public.url" or "public.plain-text" is shared,
            // we switch to text-sharing after viewWillAppear, so we need to add the sendButton here as well
            self.navigationItem.rightBarButtonItem = self.sendButton

            if #unavailable(iOS 26.0) {
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeTextColor()
            }
        }
    }

    public func shareObjectShareMessage(_ objectShareMessage: NCChatMessage) {
        self.shareType = .objectShare

        DispatchQueue.main.async {
            self.setTextInputbarHidden(true, animated: false)
            self.shareCollectionView.isHidden = true
            self.itemToolbar.isHidden = true
            self.compressionSectionView.isHidden = true
            self.compressionSectionHeightConstraint?.constant = 0
            self.shareTextView.isHidden = false
            self.shareTextView.isUserInteractionEnabled = false
            self.shareTextView.text = objectShareMessage.parsedMessage().string
            self.objectShareMessage = objectShareMessage
        }
    }

    // MARK: - View lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Configure communication lib
        guard let userToken = NCKeyChainController.sharedInstance().token(forAccountId: self.account.accountId) else { return }
        let userAgent = "Mozilla/5.0 (iOS) Nextcloud-Talk v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "Unknown")"

        NextcloudKit.shared.setup(account: self.account.accountId,
                                  user: self.account.user,
                                  userId: self.account.userId,
                                  password: userToken,
                                  urlBase: self.account.server,
                                  userAgent: userAgent,
                                  nextcloudVersion: self.serverCapabilities.versionMajor,
                                  delegate: self)

        if #unavailable(iOS 26) {
            let localizedToString = NSLocalizedString("To:", comment: "TRANSLATORS this is for sending something 'to' a user. E.g. 'To: John Doe'")
            let toString = localizedToString.withFont(.boldSystemFont(ofSize: 15)).withTextColor(.tertiaryLabel)
            let roomString = self.room.displayName.withFont(.systemFont(ofSize: 15)).withTextColor(.label)
            self.toLabel.attributedText = toString + NSAttributedString(string: " ") + roomString
        } else {
            self.navigationItem.title = self.room.displayName
        }

        let bundle = Bundle(for: ShareConfirmationCollectionViewCell.self)
        self.shareCollectionView.register(UINib(nibName: kShareConfirmationTableCellNibName, bundle: bundle), forCellWithReuseIdentifier: kShareConfirmationCellIdentifier)
        self.shareCollectionView.delegate = self
        self.configureCompressionUI()
    }

    public override func viewWillAppear(_ animated: Bool) {
        // Add the cancel button in viewWillAppear, so that the caller can change the isModal property after initialization
        if self.isModal {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(self.cancelButtonPressed))
            cancelButton.accessibilityHint = NSLocalizedString("Double tap to dismiss sharing options", comment: "")

            self.navigationItem.leftBarButtonItem = cancelButton

            if #unavailable(iOS 26) {
                self.navigationItem.leftBarButtonItem?.tintColor = NCAppBranding.themeTextColor()
            }
        }

        var captionAllowed = NCDatabaseManager.sharedInstance().serverHasTalkCapability(.mediaCaption, forAccountId: account.accountId)
        captionAllowed = captionAllowed && self.shareType == .item

        if !captionAllowed {
            self.navigationItem.rightBarButtonItem = self.sendButton
            if #unavailable(iOS 26) {
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeTextColor()
            }
            self.setTextInputbarHidden(true, animated: false)
        } else {
            let silentSendAction = UIAction(title: NSLocalizedString("Send without notification", comment: ""), image: UIImage(systemName: "bell.slash")) { [unowned self] _ in
                self.silentSendPressed()
            }

            self.rightButton.menu = UIMenu(children: [silentSendAction])
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Provider load may have started before presentation — re-assert Loading media… HUD.
        self.updateStagingProgressHUD()
        self.startUploadSessionHeartbeat()

        if self.shareType == .text {
            // When we are sharing a text, we want to start editing right away
            self.shareTextView.becomeFirstResponder()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.stopUploadSessionHeartbeat()
    }

    private func startUploadSessionHeartbeat() {
        self.stopUploadSessionHeartbeat()
        MediaUploadDiskStore.touchUploadSession()
        let interval = MediaUploadDiskStore.uploadSessionHeartbeatInterval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MediaUploadDiskStore.touchUploadSession()
        }
        // Avoid coalescing with tracking runs that can delay fire while scrolling.
        timer.tolerance = min(30, interval / 5)
        RunLoop.main.add(timer, forMode: .common)
        self.uploadSessionHeartbeatTimer = timer
    }

    private func stopUploadSessionHeartbeat() {
        self.uploadSessionHeartbeatTimer?.invalidate()
        self.uploadSessionHeartbeatTimer = nil
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if self.shareType == .text {
            return
        }

        // Don't flash the media pager back on while Preparing/Uploading.
        if self.isInSendProgressMode || self.isPreparingForUpload || self.isUploadingMedia {
            self.shareCollectionView.collectionViewLayout.invalidateLayout()
            return
        }

        self.shareCollectionView.isHidden = true

        // Invalidate layout to remove warning about item size must be less than UICollectionView
        self.shareCollectionView.collectionViewLayout.invalidateLayout()
        let currentItem = self.getCurrentShareItem()

        coordinator.animate { _ in
            // Invalidate the view now so cell size is correctly calculated
            // The size of the collection view is correct at this moment
            self.shareCollectionView.collectionViewLayout.invalidateLayout()
        } completion: { _ in
            // Scroll to the element and make collection view appear
            if let currentItem {
                self.scroll(to: currentItem, animated: false)
            }

            self.shareCollectionView.isHidden = false
        }
    }

    override func setTitleView() {
        // We don't want a titleView in this case
    }

    public override func canPressRightButton() -> Bool {
        // Allow sending media without caption text, but not while load/prepare/upload is running.
        return !self.shareItemController.shareItems.isEmpty
            && !self.shareItemController.isBusyLoadingMedia
            && !self.isPreparingForUpload
            && !self.isUploadingMedia
    }

    // MARK: - Button Actions

    func removeItemButtonPressed() {
        if let item = self.getCurrentShareItem() {
            self.shareItemController.remove(item)
        }
    }

    func cropItemButtonPressed() {
        if let item = self.getCurrentShareItem(),
           let image = self.shareItemController.getImageFrom(item) {

            let cropViewController = TOCropViewController(image: image)
            cropViewController.delegate = self
            self.present(cropViewController, animated: true)
        }
    }

    func previewItemButtonPressed() {
        self.previewCurrentItem()
    }

    @objc private func compressionOptionPressed(_ sender: UIButton) {
        guard let level = MediaUploadCompressionLevel(rawValue: sender.tag) else { return }
        let urls = self.shareItemController.shareItems.compactMap(\.fileURL)
        guard MediaUploadDebugSettings.compressionLevelLikelyUseful(level, forFileURLs: urls) else { return }
        self.chosenCompressionLevel = level
        self.updateCompressionOptionsUI()
    }

    func cancelButtonPressed() {
        // Telegram-style: abort in-flight work (if any) and leave the flow (chat / host app).
        let wasUploading = self.isUploadingMedia || !self.uploadTasks.isEmpty
        self.stopUploadSessionHeartbeat()
        self.cancelMediaFlowIfNeeded()
        if wasUploading {
            // Let cancelled URLSession tasks release upload/ paths before force wipe.
            MediaUploadDiskStore.scheduleClearSessionScratchCaches(
                reason: "sheet-dismiss",
                afterDelay: MediaUploadDiskStore.scratchClearAfterCancelDelay
            )
        } else {
            MediaUploadDiskStore.clearSessionScratchCaches(reason: "sheet-dismiss", wait: false)
        }
        self.delegate?.shareConfirmationViewControllerDidCancel(self)
    }

    /// Stops compression/upload work started by Send. Safe if nothing is in flight.
    private func cancelMediaFlowIfNeeded() {
        guard self.isPreparingForUpload || self.isUploadingMedia else { return }

        NCLog.log("Media upload: user cancelled during prepare/upload")
        MediaUploadTrace.log("SEND cancel abort — leave flow")
        self.mediaFlowCancelled = true
        self.shareItemController.cancelPreparation()
        for task in self.uploadTasks {
            task.cancel()
        }
        self.uploadTasks.removeAll()
        self.isPreparingForUpload = false
        self.isUploadingMedia = false
        self.isInSendProgressMode = false
        self.suppressMediaPreviews = false
        self.hideProgressAlert()
        self.updateSendButtonEnabledState()
    }

    /// Hide compose chrome and drop heavy preview bitmaps for the Send → progress surface.
    private func enterSendProgressMode() {
        self.isInSendProgressMode = true
        self.textView.resignFirstResponder()
        self.setTextInputbarHidden(true, animated: false)
        self.shareContentView.isHidden = true
        self.navigationItem.rightBarButtonItem = nil
        self.suppressMediaPreviews = true
        for item in self.shareItemController.shareItems {
            item.placeholderImage = nil
        }
        MediaUploadTrace.logSync("SEND progress-mode compose hidden items=\(self.shareItemController.shareItems.count)")
    }

    /// Restore compose after a failed send (Cancel/success dismiss instead).
    private func exitSendProgressMode() {
        guard self.isInSendProgressMode else { return }
        self.isInSendProgressMode = false
        self.shareContentView.isHidden = false
        self.suppressMediaPreviews = false
        self.shareCollectionView.isUserInteractionEnabled = true
        self.compressionOptionsView.isUserInteractionEnabled = true

        let captionAllowed = NCDatabaseManager.sharedInstance().serverHasTalkCapability(.mediaCaption, forAccountId: account.accountId)
            && self.shareType == .item
        if captionAllowed {
            self.setTextInputbarHidden(false, animated: false)
        } else {
            self.setTextInputbarHidden(true, animated: false)
            self.navigationItem.rightBarButtonItem = self.sendButton
            if #unavailable(iOS 26) {
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeTextColor()
            }
        }
        self.shareCollectionView.reloadData()
        self.updateSendButtonEnabledState()
    }

    /// Swipe-to-dismiss does not run Cancel — block it while prepare/upload is in flight.
    private func updateSheetDismissLock() {
        let locked = self.isPreparingForUpload || self.isUploadingMedia
        self.isModalInPresentation = locked
        self.navigationController?.isModalInPresentation = locked
    }

    func sendButtonPressed() {
        self.sendCurrent(silently: false)
    }

    public override func didPressRightButton(_ sender: Any?) {
        self.sendCurrent(silently: false)
    }

    func silentSendPressed() {
        self.sendCurrent(silently: true)
    }

    func sendCurrent(silently: Bool) {
        self.shareSilently = silently

        if self.shareType == .text {
            self.sendSharedText()
            self.startAnimatingSharingIndicator()
            return
        } else if self.shareType == .objectShare {
            self.sendObjectShare()
            self.startAnimatingSharingIndicator()
            return
        }

        self.prepareMediaThenUpload()
    }

    private var mediaUploadMode: MediaUploadMode {
        MediaUploadMode(rawValue: Int(NCUserDefaults.mediaUploadMode())) ?? .automatic
    }

    private func prepareMediaThenUpload() {
        guard !self.isPreparingForUpload, !self.isUploadingMedia else {
            NCLog.log("Media upload: ignoring Send — already preparing/uploading")
            return
        }

        let mode = self.mediaUploadMode
        let mediaCount = self.shareItemController.shareItems.count
        let debug = MediaUploadDebugSettings.shared()
        MediaUploadTrace.logSync("SEND begin mode=\(MediaUploadTrace.modeName(mode)) items=\(mediaCount) settings={\(MediaUploadTrace.settingsSnapshot())}")

        self.mediaFlowCancelled = false
        self.uploadTasks.removeAll()
        self.isUploadingMedia = true
        self.updateSendButtonEnabledState()
        // Keep cross-process staging lock fresh for the duration of Send.
        MediaUploadDiskStore.touchUploadSession()

        // Drop compose UI (memory + cleaner progress surface). Cancel leaves the flow.
        self.enterSendProgressMode()

        if mode == .noCompression {
            MediaUploadTrace.log("SEND decision=skip-compress (No Compression) — upload originals")
            for item in self.shareItemController.shareItems {
                let bytes = MediaUploadPreprocessor.fileSizePublic(at: item.fileURL)
                MediaUploadTrace.log("PLAN \(item.fileName ?? "unknown") level=none(original) original=\(MediaUploadTrace.mb(bytes)) estimate=n/a")
            }
            self.showProgressAlert(phase: .uploading(count: mediaCount), progress: 0, indeterminate: false)
            self.uploadAndShareFiles()
            return
        }

        self.isPreparingForUpload = true
        self.showProgressAlert(phase: .preparing(count: mediaCount), progress: 0, indeterminate: false)

        let chosenLevel = self.chosenCompressionLevel
        let autoURLs = self.shareItemController.shareItems.compactMap(\.fileURL)
        let autoLevels = mode == .automatic
            ? MediaUploadAutomaticPolicy.compressionLevels(forFileURLs: autoURLs)
            : []
        var autoLevelByPath: [String: MediaUploadCompressionLevel] = [:]
        for (url, level) in zip(autoURLs, autoLevels) {
            autoLevelByPath[url.path] = level
        }

        if mode == .chooseOnUpload {
            MediaUploadTrace.log("SEND decision=manual chip=\(MediaUploadTrace.levelName(chosenLevel))")
        } else if mode == .automatic {
            let cap = MediaUploadAutomaticPolicy.automaticFileMaxBytes
            MediaUploadTrace.log(String(format:
                "SEND decision=automatic cap=%@ photoMargin=%.0f%% videoMargin=%.0f%% (accept if estimate×(1+margin)<cap)",
                MediaUploadTrace.mb(cap),
                debug.automaticPhotoEstimateMarginPercent,
                debug.automaticVideoEstimateMarginPercent))
        }

        for item in self.shareItemController.shareItems {
            guard let fileURL = item.fileURL else { continue }
            let level: MediaUploadCompressionLevel
            switch mode {
            case .chooseOnUpload: level = chosenLevel
            case .automatic: level = autoLevelByPath[fileURL.path] ?? .medium
            default: level = .none
            }
            let original = MediaUploadPreprocessor.fileSizePublic(at: fileURL)
            let estimate = level == .none
                ? original
                : MediaUploadPreprocessor.estimatedByteCount(at: fileURL, level: level)
            let name = item.fileName ?? "unknown"
            MediaUploadTrace.log("PLAN \(name) level=\(MediaUploadTrace.levelName(level)) original=\(MediaUploadTrace.mb(original)) estimate=\(MediaUploadTrace.mb(estimate))")
        }

        self.shareItemController.prepareItemsForUpload(levelProvider: { item in
            switch mode {
            case .noCompression:
                return MediaUploadCompressionLevel.none.rawValue
            case .chooseOnUpload:
                return chosenLevel.rawValue
            case .automatic:
                guard let fileURL = item.fileURL else {
                    return MediaUploadCompressionLevel.medium.rawValue
                }
                let extensionName = fileURL.pathExtension.lowercased()
                let isMedia = item.isImage || MediaUploadPreprocessor.isVideo(fileExtension: extensionName)
                if !isMedia {
                    return MediaUploadCompressionLevel.none.rawValue
                }
                return (autoLevelByPath[fileURL.path] ?? .medium).rawValue
            @unknown default:
                return MediaUploadCompressionLevel.medium.rawValue
            }
        }, progress: { [weak self] fraction in
            guard let self, !self.mediaFlowCancelled else { return }
            self.progressAlert?.setProgress(fraction * self.prepareProgressShare, animated: true)
        }, completion: { [weak self] in
            guard let self else { return }
            // Keep isPreparingForUpload true until upload path is entered — no preview regen window.
            if self.mediaFlowCancelled {
                NCLog.logSync("Media upload: prepare finished after cancel — skipping upload")
                self.isPreparingForUpload = false
                self.isUploadingMedia = false
                self.isInSendProgressMode = false
                self.suppressMediaPreviews = false
                self.hideProgressAlert()
                self.updateSendButtonEnabledState()
                return
            }
            for item in self.shareItemController.shareItems {
                let bytes = MediaUploadPreprocessor.fileSizePublic(at: item.fileURL)
                MediaUploadTrace.logSync("PREPARE done \(item.fileName ?? "unknown") uploadBytes=\(MediaUploadTrace.mb(bytes))")
            }
            MediaUploadTrace.logSync("PREPARE finished → upload \(self.shareItemController.shareItems.count) item(s) (maxConcurrentPUTs=\(MediaUploadDiskStore.maxConcurrentUploads))")
            self.showProgressAlert(phase: .uploading(count: self.shareItemController.shareItems.count),
                                   progress: self.prepareProgressShare,
                                   indeterminate: false)
            // Brief yield so AVFoundation settles before kicking off N parallel PUTs.
            // Keep isPreparingForUpload true across this gap (together with isUploadingMedia).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if self.mediaFlowCancelled {
                    NCLog.logSync("Media upload: upload start skipped — cancelled during handoff")
                    self.isPreparingForUpload = false
                    self.isUploadingMedia = false
                    self.isInSendProgressMode = false
                    self.suppressMediaPreviews = false
                    self.hideProgressAlert()
                    self.updateSendButtonEnabledState()
                    return
                }
                NCLog.logSync("Media upload: handoff → uploadAndShareFiles")
                self.isPreparingForUpload = false
                self.uploadAndShareFiles()
            }
        })
    }

    private func title(for level: MediaUploadCompressionLevel) -> String {
        switch level {
        case .none:
            return NSLocalizedString("None", comment: "No media compression")
        case .low:
            return NSLocalizedString("Low", comment: "Low media compression")
        case .medium:
            return NSLocalizedString("Medium", comment: "Medium media compression")
        case .high:
            return NSLocalizedString("High", comment: "High media compression")
        @unknown default:
            return ""
        }
    }

    private func sizeLabel(for level: MediaUploadCompressionLevel, estimated: Int64) -> String {
        guard estimated > 0 else {
            return "–"
        }
        let sizeNote = MediaUploadPreprocessor.formattedByteCount(estimated)
        if level == .none {
            return sizeNote
        }
        return "~\(sizeNote)"
    }

    private func updateCompressionOptionsUI() {
        // Keep the section visible (and height reserved) for Manual mode so chips appearing
        // later don't shift the media pager. While staging, show disabled chips with "–".
        let showQuality = self.mediaUploadMode == .chooseOnUpload && self.shareType == .item

        self.compressionSectionView.isHidden = !showQuality
        self.compressionSectionHeightConstraint?.constant = showQuality ? 78 : 0

        guard showQuality else {
            self.view.layoutIfNeeded()
            return
        }

        let loading = self.shareItemController.isBusyLoadingMedia
        let items = self.shareItemController.shareItems
        let urls = items.compactMap(\.fileURL)

        // Estimates need staged files — avoid mid-copy JPEG/AVAsset work.
        guard !loading, !urls.isEmpty else {
            self.applyCompressionChipTitles(estimates: [:], enabled: [], sizesReady: false)
            self.view.layoutIfNeeded()
            return
        }

        // One estimate pass for chip sizes + enablement (avoids 6× MediaUploadHeuristic per level).
        let totals = MediaUploadPreprocessor.cheapEstimatedByteCounts(forFileURLs: urls)
        let estimates: [MediaUploadCompressionLevel: Int64] = [
            .none: totals.none,
            .low: totals.low,
            .medium: totals.medium,
            .high: totals.high
        ]
        let enabled = MediaUploadPreprocessor.compressionLevelsUsefulFromEstimates(totals)

        // If the selected level can't shrink, fall back to None.
        if !enabled.contains(self.chosenCompressionLevel) {
            MediaUploadTrace.log("CHIPS selected=\(MediaUploadTrace.levelName(self.chosenCompressionLevel)) not useful → fall back to none")
            self.chosenCompressionLevel = .none
        }

        MediaUploadTrace.log(String(format:
            "CHIPS bag n=%ld totals none=%@ low=%@ med=%@ high=%@ enabled=%@ selected=%@",
            items.count,
            MediaUploadTrace.mb(totals.none),
            MediaUploadTrace.mb(totals.low),
            MediaUploadTrace.mb(totals.medium),
            MediaUploadTrace.mb(totals.high),
            enabled.map { MediaUploadTrace.levelName($0) }.sorted().joined(separator: ","),
            MediaUploadTrace.levelName(self.chosenCompressionLevel)))
        for url in urls {
            let per = MediaUploadPreprocessor.cheapEstimatedByteCounts(at: url)
            MediaUploadTrace.log(String(format:
                "CHIPS item %@ original=%@ est low=%@ med=%@ high=%@",
                url.lastPathComponent,
                MediaUploadTrace.mb(per.none),
                MediaUploadTrace.mb(per.low),
                MediaUploadTrace.mb(per.medium),
                MediaUploadTrace.mb(per.high)))
        }
        self.applyCompressionChipTitles(estimates: estimates, enabled: enabled, sizesReady: true)
        self.view.layoutIfNeeded()
    }

    private func applyCompressionChipTitles(estimates: [MediaUploadCompressionLevel: Int64],
                                            enabled: Set<MediaUploadCompressionLevel>,
                                            sizesReady: Bool) {
        let elementColor = NCAppBranding.elementColor()
        let captionPoint = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let levelFont = UIFont.systemFont(ofSize: captionPoint, weight: .semibold)
        let sizeFont = UIFont.systemFont(ofSize: max(10, captionPoint - 1), weight: .regular)

        for case let button as UIButton in self.compressionOptionsView.arrangedSubviews {
            guard let level = MediaUploadCompressionLevel(rawValue: button.tag) else { continue }
            // Title case saves horizontal space vs ALL CAPS on a 4-up row.
            let levelTitle = self.title(for: level)
            let sizeTitle: String
            let isEnabled: Bool
            if sizesReady {
                let estimated = estimates[level] ?? 0
                sizeTitle = self.sizeLabel(for: level, estimated: estimated)
                isEnabled = enabled.contains(level)
            } else {
                sizeTitle = "–"
                isEnabled = false
            }

            button.isEnabled = isEnabled
            button.alpha = isEnabled ? 1.0 : 0.4

            let selected = isEnabled && level == self.chosenCompressionLevel
            let titleColor: UIColor
            if selected {
                button.backgroundColor = elementColor
                button.layer.borderColor = elementColor.cgColor
                titleColor = .white
            } else {
                button.backgroundColor = .secondarySystemBackground
                button.layer.borderColor = UIColor.separator.cgColor
                titleColor = isEnabled ? .label : .tertiaryLabel
            }

            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(string: levelTitle + "\n", attributes: [
                .font: levelFont,
                .foregroundColor: titleColor,
                .paragraphStyle: Self.centeredChipParagraphStyle
            ]))
            attributed.append(NSAttributedString(string: sizeTitle, attributes: [
                .font: sizeFont,
                .foregroundColor: titleColor,
                .paragraphStyle: Self.centeredChipParagraphStyle
            ]))
            button.setAttributedTitle(attributed, for: .normal)
            button.setTitleColor(titleColor, for: .normal)
        }
    }

    private static let centeredChipParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return style
    }()

    private func configureCompressionUI() {
        MediaUploadAutomaticPolicy.startMonitoringIfNeeded()
        self.updateCompressionOptionsUI()
    }

    private enum UploadHUDPhase {
        /// Provider / iCloud / local staging copy (before preview is ready).
        case loadingMedia
        /// Send-path compression.
        case preparing(count: Int)
        case uploading(count: Int)

        var title: String {
            switch self {
            case .loadingMedia:
                return NSLocalizedString("Loading media…", comment: "Shown while shared/picked media is loaded from Photos or another app")
            case .preparing:
                return NSLocalizedString("Preparing…", comment: "Shown while media is compressed before upload")
            case .uploading:
                return NSLocalizedString("Uploading…", comment: "Upload progress title; details show file count")
            }
        }

        var details: String {
            switch self {
            case .loadingMedia:
                return NSLocalizedString("Please wait…", comment: "Detail under Loading media progress alert")
            case .preparing(let count), .uploading(let count):
                if count == 1 {
                    return NSLocalizedString("1 media file", comment: "Upload progress detail for a single file")
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("%ld media files", comment: "Upload progress detail for multiple files"),
                    count
                )
            }
        }
    }

    private func showProgressAlert(phase: UploadHUDPhase, progress: Float?, indeterminate: Bool) {
        let alert: MediaUploadProgressAlert
        if let existing = self.progressAlert {
            alert = existing
        } else {
            alert = MediaUploadProgressAlert()
            alert.onCancel = { [weak self] in
                self?.cancelButtonPressed()
            }
            self.progressAlert = alert
            alert.present(on: self.view, animated: true)
        }

        alert.update(title: phase.title,
                     message: phase.details,
                     progress: progress,
                     indeterminate: indeterminate,
                     showsCancel: true)
    }

    private func hideProgressAlert() {
        self.progressAlert?.dismiss(animated: true)
        self.progressAlert = nil
    }

    // MARK: - Add additional items

    func checkAndPresentCamera() {
        // https://stackoverflow.com/a/20464727/2512312
        let mediaType = AVMediaType.video
        let authStatus = AVCaptureDevice.authorizationStatus(for: mediaType)

        if authStatus == AVAuthorizationStatus.authorized {
            self.presentCamera()
            return
        } else if authStatus == AVAuthorizationStatus.notDetermined {
            AVCaptureDevice.requestAccess(for: mediaType, completionHandler: { (granted: Bool) in
                if granted {
                    self.presentCamera()
                }
            })
            return
        }

        let alert = UIAlertController(title: NSLocalizedString("Could not access camera", comment: ""),
                                      message: NSLocalizedString("Camera access is not allowed. Check your settings.", comment: ""),
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        self.present(alert, animated: true)
    }

    func presentCamera() {
        DispatchQueue.main.async {
            self.imagePicker = UIImagePickerController()

            if let imagePicker = self.imagePicker,
               let sourceType = UIImagePickerController.availableMediaTypes(for: imagePicker.sourceType) {
                imagePicker.sourceType = .camera
                imagePicker.cameraFlashMode = UIImagePickerController.CameraFlashMode(rawValue: NCUserDefaults.preferredCameraFlashMode()) ?? .off
                imagePicker.mediaTypes = sourceType
                imagePicker.delegate = self
                self.present(imagePicker, animated: true)
            }
        }
    }

    func presentPhotoLibrary() {
        self.imagePicker = UIImagePickerController()

        if let imagePicker = self.imagePicker {
            imagePicker.sourceType = .photoLibrary
            imagePicker.mediaTypes = UIImagePickerController.availableMediaTypes(for: .photoLibrary) ?? []
            imagePicker.delegate = self
            self.present(imagePicker, animated: true)
        }
    }

    func presentDocumentPicker() {
        DispatchQueue.main.async {
            let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            documentPicker.delegate = self
            self.present(documentPicker, animated: true)
        }
    }

    // MARK: - Actions

    func sendSharedText() {
        NCAPIController.sharedInstance().sendChatMessage(self.shareTextView.text, toRoom: self.room.token, threadTitle: nil, replyTo: -1, referenceId: nil, silently: false, forAccount: self.account) { error in
            if let error {
                NCLog.log(String(format: "Failed to share text. Error: %@", error.localizedDescription))
                self.delegate?.shareConfirmationViewControllerDidFail(self)
            } else {
                NCIntentController.sharedInstance().donateSendMessageIntent(for: self.room)
                self.delegate?.shareConfirmationViewControllerDidFinish(self)
            }

            self.stopAnimatingSharingIndicator()
        }
    }

    func sendObjectShare() {
        guard let richObjectFromObjectShare = objectShareMessage?.richObjectFromObjectShare else { return }

        NCAPIController.sharedInstance().shareRichObject(richObjectFromObjectShare, inRoom: self.room.token, forAccount: self.account) { error in
            if let error {
                NCLog.log(String(format: "Failed to share rich object. Error: %@", error.localizedDescription))
                self.delegate?.shareConfirmationViewControllerDidFail(self)
            } else {
                NCIntentController.sharedInstance().donateSendMessageIntent(for: self.room)
                self.delegate?.shareConfirmationViewControllerDidFinish(self)
            }
            self.stopAnimatingSharingIndicator()
        }
    }

    func updateHudProgress() {
        guard self.progressAlert != nil else { return }

        DispatchQueue.main.async {
            var progress: CGFloat = 0.0
            var items = 0

            for shareItem in self.shareItemController.shareItems {
                progress += shareItem.uploadProgress
                items += 1
            }

            let uploadFraction = items > 0 ? Float(progress / CGFloat(items)) : 0
            let prepareShare = self.mediaUploadMode == .noCompression ? 0 : self.prepareProgressShare
            self.progressAlert?.setProgress(prepareShare + (1 - prepareShare) * uploadFraction, animated: true)
        }
    }

    func uploadAndShareFiles() {
        // TODO: This has no effect on ShareExtension
        let bgTask = BGTaskHelper.startBackgroundTask(withName: "uploadAndShareFiles")

        if self.mediaFlowCancelled {
            NCLog.log("Media upload: uploadAndShareFiles skipped — cancelled")
            self.isUploadingMedia = false
            bgTask.stopBackgroundTask()
            return
        }

        NCLog.logSync("Media upload: uploadAndShareFiles started (\(self.shareItemController.shareItems.count) item(s))")

        self.textView.resignFirstResponder()

        NCIntentController.sharedInstance().donateSendMessageIntent(for: self.room)

        let count = self.shareItemController.shareItems.count
        let prepareShare = self.mediaUploadMode == .noCompression ? Float(0) : self.prepareProgressShare
        self.showProgressAlert(phase: .uploading(count: count), progress: prepareShare, indeterminate: false)

        self.uploadGroup = DispatchGroup()
        self.uploadErrors = []
        self.uploadSuccess = []

        // Add caption to last shareItem
        if let shareItem = self.shareItemController.shareItems.last {
            if NCDatabaseManager.sharedInstance().serverHasTalkCapability(.mediaCaption, forAccountId: self.account.accountId) {
                let messageParameters = self.mentionsDict.asJSONString() ?? ""
                let message = NCChatMessage()
                message.message = self.replaceMentionsDisplayNamesWithMentionsKeysInMessage(message: self.textView.text, parameters: messageParameters)
                message.messageParametersJSONString = messageParameters

                shareItem.caption = message.sendingMessage
            }
        }

        // Check if conversation subfolders feature is supported
        if room.supportsConversationSubfolders {
            let fileNames = self.shareItemController.shareItems.compactMap { $0.fileName }
            NCAPIController.sharedInstance().probeConversationAttachmentFolder(inRoom: self.room.token, withFileNames: fileNames, forAccount: self.account) { draftFolder, _, error in
                if self.mediaFlowCancelled {
                    DispatchQueue.main.async {
                        self.isUploadingMedia = false
                        self.suppressMediaPreviews = false
                        self.shareCollectionView.isUserInteractionEnabled = true
                        bgTask.stopBackgroundTask()
                    }
                    return
                }
                if let error {
                    NCLog.log("Probe conversation attachment folder failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isUploadingMedia = false
                        self.isPreparingForUpload = false
                        self.hideProgressAlert()
                        self.exitSendProgressMode()
                        bgTask.stopBackgroundTask()
                        let alert = UIAlertController(
                            title: NSLocalizedString("Upload failed", comment: ""),
                            message: NSLocalizedString("Could not prepare upload folder", comment: ""),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                        self.present(alert, animated: true)
                    }
                    return
                }
                self.startUploads(draftFolderPath: draftFolder, bgTask: bgTask)
            }
        } else {
            self.startUploads(draftFolderPath: nil, bgTask: bgTask)
        }
    }

    private func startUploads(draftFolderPath: String?, bgTask: BGTaskHelper) {
        if self.mediaFlowCancelled {
            self.isUploadingMedia = false
            bgTask.stopBackgroundTask()
            return
        }

        for shareItem in self.shareItemController.shareItems {
            let byteCount = (try? FileManager.default.attributesOfItem(atPath: shareItem.filePath)[.size] as? NSNumber)?.int64Value ?? 0
            if byteCount == 0 {
                NCLog.log("Media upload: refusing 0-byte upload for \(shareItem.fileName) at \(shareItem.filePath)")
                self.uploadErrors.append(String.localizedStringWithFormat(
                    NSLocalizedString("“%@” is empty and was not uploaded.", comment: "Upload aborted because staged file has 0 bytes"),
                    shareItem.fileName
                ))
                continue
            }
            NCLog.log("Media upload: uploading \(shareItem.fileName) (\(byteCount) bytes) from \(shareItem.filePath)")

            self.uploadGroup.enter()

            if let draftFolderPath {
                let fileExtension = shareItem.fileURL.pathExtension
                let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
                let tempName = UUID().uuidString + extensionSuffix
                let draftPath = "\(draftFolderPath)/\(tempName)"
                let fileServerPath = "/\(draftPath)"

                if let fileServerURL = NCAPIController.sharedInstance().serverFileURL(forfilePath: fileServerPath, forAccount: account) {
                    self.uploadFile(to: fileServerURL, with: fileServerPath, draftFolderPath: draftPath, with: shareItem)
                } else {
                    NCLog.log("Error creating server path for upload")
                    self.uploadErrors.append(NSLocalizedString("Error creating server path for upload", comment: ""))
                    self.uploadGroup.leave()
                }
            } else {
                NCAPIController.sharedInstance().uniqueNameForFileUpload(withName: shareItem.fileName, isOriginalName: true, forAccount: self.account) { fileServerURL, fileServerPath, _, errorDescription in
                    if let fileServerURL, let fileServerPath {
                        self.uploadFile(to: fileServerURL, with: fileServerPath, draftFolderPath: nil, with: shareItem)
                    } else {
                        NCLog.log(String(format: "Error finding unique upload name. Error: %@", errorDescription ?? "Unknown error"))
                        self.uploadErrors.append(errorDescription ?? "Unknown error")
                        self.uploadGroup.leave()
                    }
                }
            }
        }

        self.uploadGroup.notify(queue: .main) {
            self.isUploadingMedia = false
            self.isPreparingForUpload = false
            self.uploadTasks.removeAll()
            self.hideProgressAlert()

            if self.mediaFlowCancelled {
                NCLog.log("Media upload: upload group finished after cancel — suppressing result UI")
                self.isInSendProgressMode = false
                bgTask.stopBackgroundTask()
                return
            }

            // TODO: Do error reporting per item
            if self.uploadErrors.isEmpty {
                self.isInSendProgressMode = false
                self.finishingSuccessfulUpload = true
                self.shareItemController.removeAllItems()
                self.finishingSuccessfulUpload = false
                self.delegate?.shareConfirmationViewControllerDidFinish(self)
            } else {
                // Keep failed items and restore compose so the user can retry or Cancel out.
                self.shareItemController.remove(self.uploadSuccess)
                self.exitSendProgressMode()
                self.updateCompressionOptionsUI()

                let alert = UIAlertController(title: NSLocalizedString("Upload failed", comment: ""),
                                              message: self.uploadErrors.joined(separator: "\n"),
                                              preferredStyle: .alert)

                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))

                self.present(alert, animated: true)
            }

            bgTask.stopBackgroundTask()
        }
    }

    func uploadFile(to fileServerURL: String, with filePath: String, draftFolderPath: String?, with item: ShareItem) {
        if self.mediaFlowCancelled {
            self.uploadGroup.leave()
            return
        }

        // Bound concurrent PUTs (encodes are already serial).
        let uploadName = item.fileName ?? "unknown"
        let localBytes = MediaUploadPreprocessor.fileSizePublic(at: URL(fileURLWithPath: item.filePath))
        MediaUploadUploadGate.shared.acquire(label: uploadName) { finished in
            if self.mediaFlowCancelled {
                finished()
                self.uploadGroup.leave()
                return
            }

            MediaUploadTrace.log("UPLOAD start \(uploadName) \(MediaUploadTrace.mb(localBytes)) → \(fileServerURL)")
            NextcloudKit.shared.upload(serverUrlFileName: fileServerURL, fileNameLocalPath: item.filePath) { task in
                NCLog.log("Media upload: upload task created for \(uploadName)")
                self.uploadTasks.append(task)
                if self.mediaFlowCancelled {
                    task.cancel()
                }
            } progressHandler: { progress in
                guard !self.mediaFlowCancelled else { return }
                item.uploadProgress = progress.fractionCompleted
                self.updateHudProgress()
            } completionHandler: { _, _, _, _, _, _, nkError in
                defer { finished() }

                if self.mediaFlowCancelled {
                    self.uploadGroup.leave()
                    return
                }
                if nkError.errorCode == 0 {
                    NCLog.log("Media upload: \(uploadName) PUT completed, verifying remote size at \(fileServerURL)")
                    NCAPIController.sharedInstance().verifyUploadedFileSize(atServerURL: fileServerURL,
                                                                              minimumBytes: 1,
                                                                              forAccount: self.account) { verified, remoteBytes, remoteDate, verifyError in
                        // Cancel can land after PUT while PROPFIND is in flight — do not promote/share.
                        if self.mediaFlowCancelled {
                            MediaUploadTrace.log("UPLOAD abort \(uploadName) after PROPFIND (cancelled)")
                            self.uploadGroup.leave()
                            return
                        }
                        guard verified else {
                            let reason = verifyError ?? String.localizedStringWithFormat(
                                NSLocalizedString("Server stored “%@” as empty (%lld bytes).", comment: "Upload rejected after PROPFIND shows 0 bytes"),
                                uploadName,
                                remoteBytes
                            )
                            MediaUploadTrace.log("UPLOAD FAIL \(uploadName) PROPFIND \(reason)")
                            NCLog.log("Media upload: PROPFIND rejected \(uploadName) — \(reason)")
                            self.uploadErrors.append(reason)
                            self.uploadGroup.leave()
                            return
                        }

                        MediaUploadTrace.log("UPLOAD OK \(uploadName) local=\(MediaUploadTrace.mb(localBytes)) remote=\(MediaUploadTrace.mb(remoteBytes))")
                        let serverName = (fileServerURL as NSString).lastPathComponent
                        _ = MediaUploadDiskStore.promoteUploadedFile(atPath: item.filePath,
                                                                 accountId: self.account.accountId,
                                                                 serverFileName: serverName,
                                                                 remoteBytes: remoteBytes,
                                                                 remoteModificationDate: remoteDate)
                        self.postUploadedFileToRoom(filePath: filePath, draftFolderPath: draftFolderPath, item: item)
                    }
                } else if nkError.errorCode == 404 || nkError.errorCode == 409 {
                    MediaUploadTrace.log("UPLOAD retry \(uploadName) code=\(nkError.errorCode) (ensure folder)")
                    NCAPIController.sharedInstance().checkOrCreateAttachmentFolder(forAccount: self.account) { created, _ in
                        if self.mediaFlowCancelled {
                            MediaUploadTrace.log("UPLOAD abort \(uploadName) folder-retry (cancelled)")
                            self.uploadGroup.leave()
                            return
                        }
                        if created {
                            // Retry acquires its own gate slot; release this one via defer above.
                            self.uploadFile(to: fileServerURL, with: filePath, draftFolderPath: nil, with: item)
                        } else {
                            MediaUploadTrace.log("UPLOAD FAIL \(uploadName) code=\(nkError.errorCode) folder-create \(nkError.errorDescription)")
                            self.uploadErrors.append(nkError.errorDescription)
                            self.uploadGroup.leave()
                        }
                    }
                } else {
                    MediaUploadTrace.log("UPLOAD FAIL \(uploadName) code=\(nkError.errorCode) \(nkError.errorDescription)")
                    NCLog.log(String(format: "Failed to upload file. Error: %@", nkError.errorDescription))
                    self.uploadErrors.append(nkError.errorDescription)
                    self.uploadGroup.leave()
                }
            }
        }
    }

    private func postUploadedFileToRoom(filePath: String, draftFolderPath: String?, item: ShareItem) {
        if self.mediaFlowCancelled {
            MediaUploadTrace.log("UPLOAD abort post \(item.fileName ?? "?") (cancelled)")
            self.uploadGroup.leave()
            return
        }

        var talkMetaData: [String: Any] = [:]

        let itemCaption = item.caption.trimmingCharacters(in: .whitespaces)
        if !itemCaption.isEmpty {
            talkMetaData["caption"] = itemCaption
        }

        if self.shareSilently {
            talkMetaData["silent"] = self.shareSilently
        }

        if let thread = self.thread {
            talkMetaData["threadId"] = thread.threadId
        }

        if let draftFolderPath {
            NCAPIController.sharedInstance().postConversationAttachment(inRoom: self.room.token,
                                                                        filePath: draftFolderPath,
                                                                        fileName: item.fileName,
                                                                        referenceId: nil,
                                                                        talkMetaData: talkMetaData,
                                                                        forAccount: self.account) { error in
                if self.mediaFlowCancelled {
                    // Request may already have reached the server; do not count as local success.
                    MediaUploadTrace.log("UPLOAD abort post-callback \(item.fileName ?? "?") (cancelled)")
                    self.uploadGroup.leave()
                    return
                }
                if let error {
                    NCLog.log("Failed to post attachment. Error: \(error.localizedDescription)")
                    self.uploadErrors.append(error.localizedDescription)
                } else {
                    NCLog.log("Media upload: posted attachment \(item.fileName) to room \(self.room.token)")
                    self.uploadSuccess.append(item)
                }

                self.uploadGroup.leave()
            }
        } else {
            NCAPIController.sharedInstance().shareFileOrFolder(forAccount: self.account,
                                                               atPath: filePath,
                                                               toRoom: self.room.token,
                                                               withTalkMetaData: talkMetaData,
                                                               withReferenceId: nil) { error in
                if self.mediaFlowCancelled {
                    MediaUploadTrace.log("UPLOAD abort share-callback \(item.fileName ?? "?") (cancelled)")
                    self.uploadGroup.leave()
                    return
                }
                if let error {
                    NCLog.log(String(format: "Failed to share file. Error: %@", error.localizedDescription))
                    self.uploadErrors.append(error.localizedDescription)
                } else {
                    NCLog.log("Media upload: shared \(item.fileName) to room \(self.room.token)")
                    self.uploadSuccess.append(item)
                }

                self.uploadGroup.leave()
            }
        }
    }

    // MARK: - User Interface

    func startAnimatingSharingIndicator() {
        DispatchQueue.main.async {
            self.sharingIndicatorView.startAnimating()
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: self.sharingIndicatorView)
        }
    }

    func stopAnimatingSharingIndicator() {
        DispatchQueue.main.async {
            self.sharingIndicatorView.stopAnimating()
            self.navigationItem.rightBarButtonItem = self.sendButton
        }
    }

    func updateToolbarForCurrentItem() {
        if let item = self.getCurrentShareItem() {
            UIView.transition(with: self.itemToolbar, duration: 0.3, options: .transitionCrossDissolve) {
                self.cropItemButton.isEnabled = item.isImage
                self.previewItemButton.isEnabled = QLPreviewController.canPreview(item.fileURL as QLPreviewItem)
                self.addItemButton.isEnabled = self.shareItemController.shareItems.count < 20
            }
        } else {
            self.cropItemButton.isEnabled = false
            self.previewItemButton.isEnabled = false
        }

        self.removeItemButton.isEnabled = self.shareItemController.shareItems.count > 1
        self.removeItemButton.tintColor = self.shareItemController.shareItems.count > 1 ? nil : .clear
    }

    // MARK: - UIImagePickerController Delegate

    public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        self.saveImagePickerSettings(picker)

        guard let mediaType = info[.mediaType] as? String else { return }

        if mediaType == "public.image" {
            if let image = info[.originalImage] as? UIImage {
                self.dismiss(animated: true) {
                    self.shareItemController.addItem(with: image)
                    // Stay on the current page — no animated jump to the newly added item.
                }
            }
        } else if mediaType == "public.movie" {
            if let videoUrl = info[.mediaURL] as? URL {
                self.dismiss(animated: true) {
                    self.shareItemController.addItem(with: videoUrl)
                }
            }
        }

    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.saveImagePickerSettings(picker)
        self.dismiss(animated: true)
    }

    func saveImagePickerSettings(_ picker: UIImagePickerController) {
        if picker.sourceType == .camera && picker.cameraCaptureMode == .photo {
            NCUserDefaults.setPreferredCameraFlashMode(picker.cameraFlashMode.rawValue)
        }
    }

    // MARK: - UIDocumentPickerViewController Delegate

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for documentURL in urls {
            self.shareItemController.addItem(with: documentURL)
        }
        // Stay on the current page while additional files stage in.
    }

    // MARK: - ScrollView/CollectionView

    public override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: kShareConfirmationCellIdentifier, for: indexPath) as? ShareConfirmationCollectionViewCell
        else { return UICollectionViewCell() }

        let item = self.shareItemController.shareItems[indexPath.row]

        let extensionName = item.fileURL?.pathExtension.lowercased() ?? ""
        let isVideo = MediaUploadPreprocessor.isVideo(fileExtension: extensionName)
        let isImage = NCUtils.isImage(fileExtension: extensionName)
        cell.setShowsVideoIndicator(isVideo)

        // During Send, keep whatever preview is already on screen — do not clear or re-decode.
        if self.suppressMediaPreviews || self.isPreparingForUpload || self.isUploadingMedia {
            if cell.previewView.image == nil {
                // Avoid the XIB’s top-left 120×120 file icon flash on media pages.
                if isImage || isVideo {
                    cell.hidePlaceholderChrome()
                } else {
                    cell.setPlaceHolderImage(item.placeholderImage)
                    cell.setPlaceHolderText(item.fileName)
                }
            }
            return cell
        }

        if isImage || isVideo {
            // Placeholder sits at a fixed 120×120 top-left in the XIB — showing it before
            // the full-bleed preview lands looks like a corner blink, then a jump.
            cell.hidePlaceholderChrome()
        } else {
            cell.setPlaceHolderImage(item.placeholderImage)
            cell.setPlaceHolderText(item.fileName)
        }

        if let fileURL = item.fileURL, isImage {
            // Keep preview decode modest — multi-attachment sheets already hold several bitmaps.
            let maxDimension: CGFloat = 1024
            if let image = MediaUploadPreprocessor.previewImage(at: fileURL, maxDimension: maxDimension) {
                cell.setPreviewImage(image)
            } else if let image = self.shareItemController.getImageFrom(item) {
                cell.setPreviewImage(image)
            } else {
                self.generatePreview(for: cell, with: collectionView, with: item)
            }
        } else {
            self.generatePreview(for: cell, with: collectionView, with: item)
        }

        return cell
    }

    func generatePreview(for cell: ShareConfirmationCollectionViewCell, with collectionView: UICollectionView, with item: ShareItem) {
        // Cap thumb size — full collection bounds × screen scale was retaining ~10MB+ bitmaps per video page.
        let maxSide: CGFloat = 320
        let bounds = collectionView.bounds
        let longSide = max(bounds.width, bounds.height)
        let scaleFactor = longSide > maxSide ? maxSide / longSide : 1
        let size = CGSize(
            width: max(1, (bounds.width * scaleFactor).rounded(.down)),
            height: max(1, (bounds.height * scaleFactor).rounded(.down))
        )
        let scale: CGFloat = 1

        // updateHandler might be called multiple times, starting from low quality representation to high-quality
        let request = QLThumbnailGenerator.Request(fileAt: item.fileURL, size: size, scale: scale, representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] thumbnail, _, error in
            guard error == nil, let thumbnail else { return }

            DispatchQueue.main.async {
                guard let self, !self.suppressMediaPreviews, !self.isPreparingForUpload, !self.isUploadingMedia else { return }
                cell.setPreviewImage(thumbnail.uiImage)
            }
        }
    }

    /// Frees heavy pager bitmaps before / during serial video encode.
    func releaseDecodedPreviewsForCompression() {
        guard let collectionView else { return }
        for case let cell as ShareConfirmationCollectionViewCell in collectionView.visibleCells {
            cell.releaseDecodedPreview()
        }
    }

    public override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.shareItemController.shareItems.count
    }

    public override func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.bounds.width, height: collectionView.bounds.height)
    }

    public override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if self.textView.isFirstResponder {
            self.textView.resignFirstResponder()
        } else {
            self.previewCurrentItem()
        }
    }

    public override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.updatePageControlPage()
    }

    public override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        self.updatePageControlPage()
    }

    /// Used when the user explicitly adds another attachment (camera / Files).
    /// Intentionally does not scroll — new items stage silently on the current page.
    func collectionViewScrollToEnd() {
        // Kept for ObjC / callers; scrolling to the new last page caused a visible “fly-in” glitch.
    }

    func scroll(to item: ShareItem, animated: Bool) {
        guard let indexForItem = self.shareItemController.shareItems.firstIndex(of: item) else { return }
        self.scrollToPage(indexForItem, animated: animated)
    }

    private func currentPageIndex() -> Int {
        let width = self.shareCollectionView.bounds.width
        guard width > 0.5 else {
            return self.pageControl.currentPage
        }
        return Int(round(self.shareCollectionView.contentOffset.x / width))
    }

    private func scrollToPage(_ page: Int, animated: Bool) {
        let count = self.shareItemController.shareItems.count
        guard count > 0 else { return }
        let clamped = min(max(page, 0), count - 1)
        let indexPath = IndexPath(item: clamped, section: 0)

        let apply = {
            self.shareCollectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)
            self.pageControl.currentPage = clamped
            if !animated {
                self.updateToolbarForCurrentItem()
            }
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func getCurrentShareItem() -> ShareItem? {
        let items = self.shareItemController.shareItems
        guard !items.isEmpty else { return nil }
        let currentIndex = min(max(self.currentPageIndex(), 0), items.count - 1)
        return items[currentIndex]
    }

    // MARK: - PageControl

    func pageControlValueChanged() {
        self.scrollToPage(self.pageControl.currentPage, animated: true)
    }

    func updatePageControlPage() {
        // see: https://stackoverflow.com/a/46181277/2512312
        DispatchQueue.main.async {
            self.pageControl.currentPage = self.currentPageIndex()
            self.updateToolbarForCurrentItem()
        }
    }

    // MARK: - PreviewController

    func previewCurrentItem() {
        self.textView.resignFirstResponder()
        guard let item = self.getCurrentShareItem(),
              let fileURL = item.fileURL,
              QLPreviewController.canPreview(fileURL as QLPreviewItem)
        else { return }

        let preview = QLPreviewController()
        preview.dataSource = self
        preview.delegate = self

        NCAppBranding.styleViewController(preview)
        NCAppBranding.styleViewController(self)

        self.navigationController?.pushViewController(preview, animated: true)
    }

    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        // Don't use index here, as this relates to numberOfPreviewItems
        // When we have numberOfPreviewItems > 1 this will show an additional list of items
        guard let item = self.getCurrentShareItem(),
              let fileURL = item.fileURL
        else { return URL(fileURLWithPath: "") as QLPreviewItem }

        return fileURL as QLPreviewItem
    }

    public func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        return .createCopy
    }

    public func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
        if let item = self.getCurrentShareItem() {
            self.shareItemController.update(item, with: modifiedContentsURL)
        }
    }

    // MARK: - ShareItemController Delegate

    public func shareItemControllerShouldReleaseHeavyPreviews(_ shareItemController: ShareItemController) {
        // Drop in-memory pager bitmaps (compose is hidden during Send progress mode).
        suppressMediaPreviews = true
        for item in shareItemController.shareItems {
            item.placeholderImage = nil
        }
        if self.isInSendProgressMode {
            MediaUploadTrace.logSync(String(format:
                "JETSAM releaseHeavyPreviews progress-mode items=%ld avail=%.0fMB",
                shareItemController.shareItems.count,
                MediaUploadMemoryGateObjC.availableMegabytes()))
            return
        }
        var thumbHits = 0
        for item in shareItemController.shareItems {
            if let path = item.filePath, let thumb = MediaUploadDiskStore.loadThumb(forStagingPath: path) {
                item.placeholderImage = thumb
                thumbHits += 1
            }
        }
        MediaUploadTrace.logSync(String(format:
            "JETSAM releaseHeavyPreviews items=%ld diskThumbs=%ld avail=%.0fMB",
            shareItemController.shareItems.count,
            thumbHits,
            MediaUploadMemoryGateObjC.availableMegabytes()))
        shareCollectionView.reloadData()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.suppressMediaPreviews = false
        }
    }

    public func shareItemControllerItemsChanged(_ shareItemController: ShareItemController) {
        DispatchQueue.main.async {
            // Never dismiss while provider load / staging is still in flight (empty sheet during iCloud).
            if shareItemController.shareItems.isEmpty
                && !shareItemController.isBusyLoadingMedia
                && !self.isPreparingForUpload
                && !self.isUploadingMedia {
                if self.finishingSuccessfulUpload {
                    return
                }
                // Failure alert owns dismiss when load failed with zero items.
                if self.isPresentingStagingFailureAlert {
                    self.updateStagingProgressHUD()
                    return
                }
                NCLog.log("ShareConfirmation: items empty — cancelling share sheet")
                self.pagerItemIdentities = []
                if let extensionContext = self.extensionContext {
                    let error = NSError(domain: NSCocoaErrorDomain, code: 0)
                    extensionContext.cancelRequest(withError: error)
                } else {
                    self.dismiss(animated: true)
                }
            } else if !shareItemController.shareItems.isEmpty {
                // Mid-Send compress rewrites file URLs — skip pager reload (thumbnail regen jetsams).
                if self.isPreparingForUpload || self.isUploadingMedia {
                    self.updateToolbarForCurrentItem()
                    self.textDidUpdate(false)
                    self.updateSendButtonEnabledState()
                    self.updateStagingProgressHUD()
                    return
                }

                // Stay on the page the user is viewing. Incremental insert/delete avoids the
                // brief empty-icon flash from reloadData as each file stages.
                let preservedPage = self.shareCollectionView.numberOfItems(inSection: 0) == 0
                    ? 0
                    : self.currentPageIndex()
                self.syncShareCollectionPager(preservingPage: preservedPage)

                self.updateCompressionOptionsUI()

                // Update the text input to check if sending is (not-)possible
                self.textDidUpdate(false)
                self.updateSendButtonEnabledState()
            }

            self.updateStagingProgressHUD()
        }
    }

    /// Diffs `shareItems` against the pager and inserts/deletes pages instead of `reloadData`.
    private func syncShareCollectionPager(preservingPage preservedPage: Int) {
        let items = self.shareItemController.shareItems
        let newIds = items.map { ObjectIdentifier($0) }
        let oldIds = self.pagerItemIdentities
        let collectionCount = self.shareCollectionView.numberOfItems(inSection: 0)

        // Keep snapshot aligned if the collection was emptied elsewhere.
        if items.isEmpty {
            if collectionCount > 0 {
                UIView.performWithoutAnimation {
                    self.shareCollectionView.reloadData()
                    self.shareCollectionView.layoutIfNeeded()
                }
            }
            self.pagerItemIdentities = []
            self.pageControl.numberOfPages = 0
            return
        }

        let applyPageAndChrome = {
            let newCount = items.count
            self.pageControl.numberOfPages = newCount
            let targetPage = min(max(preservedPage, 0), newCount - 1)
            let width = self.shareCollectionView.bounds.width
            if width > 0.5 {
                self.shareCollectionView.setContentOffset(
                    CGPoint(x: CGFloat(targetPage) * width, y: 0),
                    animated: false
                )
            }
            self.pageControl.currentPage = targetPage
            self.updateToolbarForCurrentItem()
            self.pagerItemIdentities = newIds
        }

        // Pure append (staging): insert only the new trailing pages.
        let isPureAppend = collectionCount == oldIds.count
            && newIds.count > oldIds.count
            && Array(newIds.prefix(oldIds.count)) == oldIds

        if isPureAppend {
            let indexPaths = (oldIds.count..<newIds.count).map { IndexPath(item: $0, section: 0) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation {
                self.shareCollectionView.performBatchUpdates({
                    self.shareCollectionView.insertItems(at: indexPaths)
                }, completion: nil)
                self.shareCollectionView.layoutIfNeeded()
                applyPageAndChrome()
            }
            CATransaction.commit()
            return
        }

        // Removals / reorder / identity mismatch: delete missing, then insert new if needed.
        if collectionCount == oldIds.count, newIds != oldIds {
            let newIdSet = Set(newIds)
            let deletePaths = oldIds.enumerated().compactMap { index, id -> IndexPath? in
                newIdSet.contains(id) ? nil : IndexPath(item: index, section: 0)
            }
            // After deletes, remaining old ids in order:
            let remainingOld = oldIds.filter { newIdSet.contains($0) }
            let insertPaths: [IndexPath]
            if remainingOld == Array(newIds.prefix(remainingOld.count)) {
                insertPaths = (remainingOld.count..<newIds.count).map { IndexPath(item: $0, section: 0) }
            } else {
                // Structural mismatch — fall through to full reload.
                self.reloadShareCollectionPager(preservingPage: preservedPage, newIds: newIds)
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation {
                self.shareCollectionView.performBatchUpdates({
                    if !deletePaths.isEmpty {
                        self.shareCollectionView.deleteItems(at: deletePaths)
                    }
                    if !insertPaths.isEmpty {
                        self.shareCollectionView.insertItems(at: insertPaths)
                    }
                }, completion: nil)
                self.shareCollectionView.layoutIfNeeded()
                applyPageAndChrome()
            }
            CATransaction.commit()
            return
        }

        // Same identities (e.g. crop/update) or first paint / desync: targeted reload.
        if newIds == oldIds, collectionCount == newIds.count {
            let visible = self.shareCollectionView.indexPathsForVisibleItems
            if !visible.isEmpty {
                UIView.performWithoutAnimation {
                    self.shareCollectionView.reloadItems(at: visible)
                    self.shareCollectionView.layoutIfNeeded()
                    applyPageAndChrome()
                }
            } else {
                applyPageAndChrome()
            }
            return
        }

        self.reloadShareCollectionPager(preservingPage: preservedPage, newIds: newIds)
    }

    private func reloadShareCollectionPager(preservingPage preservedPage: Int, newIds: [ObjectIdentifier]) {
        let newCount = newIds.count
        let targetPage = min(max(preservedPage, 0), max(newCount - 1, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.shareCollectionView.reloadData()
            self.shareCollectionView.collectionViewLayout.invalidateLayout()
            self.shareCollectionView.layoutIfNeeded()
            self.pageControl.numberOfPages = newCount
            let width = self.shareCollectionView.bounds.width
            if width > 0.5, newCount > 0 {
                self.shareCollectionView.setContentOffset(
                    CGPoint(x: CGFloat(targetPage) * width, y: 0),
                    animated: false
                )
            }
            self.pageControl.currentPage = targetPage
            self.updateToolbarForCurrentItem()
        }
        CATransaction.commit()
        self.pagerItemIdentities = newIds
    }

    public func shareItemControllerPreparingItemsChanged(_ shareItemController: ShareItemController) {
        DispatchQueue.main.async {
            self.updateStagingProgressHUD()
            self.updateSendButtonEnabledState()
            self.textDidUpdate(false)
            // Load + staging finished — reveal Choose-on-upload chips without mid-copy JPEG work.
            if !shareItemController.isBusyLoadingMedia
                && !self.isPreparingForUpload
                && !self.isUploadingMedia {
                self.updateCompressionOptionsUI()
            }
        }
    }

    public func shareItemController(_ shareItemController: ShareItemController, didFailToStageItemsWithNames fileNames: [String]) {
        DispatchQueue.main.async {
            self.presentStagingFailureAlert(for: fileNames, remainingItemCount: shareItemController.shareItems.count)
        }
    }

    private func presentStagingFailureAlert(for fileNames: [String], remainingItemCount: Int) {
        guard !fileNames.isEmpty, !self.isPresentingStagingFailureAlert else { return }
        self.isPresentingStagingFailureAlert = true

        let title = NSLocalizedString("Couldn't load file", comment: "Alert title when a shared attachment could not be staged")
        let message: String
        if fileNames.count == 1 {
            message = String.localizedStringWithFormat(
                NSLocalizedString("“%@” isn't available. It may still be in iCloud or need a network connection. Try again after it finishes downloading in Photos.", comment: "Alert when one shared file could not be loaded"),
                fileNames[0]
            )
        } else {
            let listed = fileNames.prefix(3).joined(separator: "\n")
            let suffix = fileNames.count > 3
                ? String.localizedStringWithFormat(
                    NSLocalizedString("\nand %ld more", comment: "More failed file names truncated"),
                    fileNames.count - 3
                )
                : ""
            message = String.localizedStringWithFormat(
                NSLocalizedString("These files aren't available (they may still be in iCloud):\n%@%@", comment: "Alert when multiple shared files could not be loaded"),
                listed,
                suffix
            )
        }

        NCLog.log("ShareConfirmation: presenting staging failure for \(fileNames.count) item(s), remaining=\(remainingItemCount)")

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { [weak self] _ in
            guard let self else { return }
            self.isPresentingStagingFailureAlert = false
            // Nothing left to send — leave the share sheet the same way Cancel would.
            if remainingItemCount == 0 && self.shareItemController.shareItems.isEmpty {
                self.delegate?.shareConfirmationViewControllerDidCancel(self)
            }
        })
        self.present(alert, animated: true)
    }

    /// Progress while loading from Photos/share provider or staging into the sheet (before Send).
    private func updateStagingProgressHUD() {
        if self.isPreparingForUpload || self.isUploadingMedia {
            // Send-path Preparing/Uploading owns the progress alert.
            self.updateSendButtonEnabledState()
            return
        }

        if self.shareItemController.isBusyLoadingMedia {
            self.showProgressAlert(phase: .loadingMedia, progress: nil, indeterminate: true)
        } else if self.progressAlert != nil {
            // Load/staging finished — dismiss whether or not items appeared.
            self.hideProgressAlert()
        }

        self.updateSendButtonEnabledState()
    }

    private func updateSendButtonEnabledState() {
        self.sendButton.isEnabled = self.canPressRightButton()
    }

    // MARK: - TOCropViewController Delegate

    public func cropViewController(_ cropViewController: TOCropViewController, didCropTo image: UIImage, with cropRect: CGRect, angle: Int) {
        if let item = self.getCurrentShareItem() {
            self.shareItemController.update(item, with: image)

            // Fixes bug on iPad where collectionView is scrolled between two pages
            self.scroll(to: item, animated: true)
        }

        // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
        cropViewController.transitioningDelegate = nil
        cropViewController.dismiss(animated: true)
    }

    public func cropViewController(_ cropViewController: TOCropViewController, didFinishCancelled cancelled: Bool) {
        if let item = self.getCurrentShareItem() {
            self.scroll(to: item, animated: true)
        }

        // Fixes weird iOS 13 bug: https://github.com/TimOliver/TOCropViewController/issues/365
        cropViewController.transitioningDelegate = nil
        cropViewController.dismiss(animated: true)
    }

    // MARK: - NKCommon Delegate

    public func authenticationChallenge(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The pinning check
        if CCCertificate.sharedManager().checkTrustedChallenge(challenge) {
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

}
