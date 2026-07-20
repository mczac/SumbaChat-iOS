//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
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
    /// In-app: compose sheet was dismissed; progress HUD lives on the presenting chat.
    private var composeDismissedForUpload = false
    private var isDismissingComposeForUpload = false
    private weak var progressHostView: UIView?
    private weak var progressHostViewController: UIViewController?
    private var lastProgressPhase: UploadHUDPhase?
    private var lastProgressValue: Float?
    private var lastProgressIndeterminate = false
    private var finishAfterComposeDismiss: (() -> Void)?
    /// Keeps this VC alive after the modal sheet is dismissed until upload ends.
    private static var retainedForUpload: ShareConfirmationViewController?
    /// Share Extension: nav chrome hidden while showing the empty sheet + bottom progress.
    private var extensionProgressChromeActive = false
    private var savedNavigationTitle: String?
    private var savedLeftBarButtonItem: UIBarButtonItem?
    private var savedViewBackgroundColor: UIColor?
    private var savedNavControllerBackgroundColor: UIColor?
    private var savedTableViewBackgroundColor: UIColor?
    private var savedTextInputbarHidden = false
    private var savedUnderlyingViewsHidden: [ObjectIdentifier: Bool] = [:]
    /// Keeps App Group `.upload-session` fresh during long compose (Settings/idle protection).
    private var uploadSessionHeartbeatTimer: Timer?

    /// Avoids re-running chip estimates / CHIPS logs when itemsChanged + preparingChanged redraw the same bag.
    private var compressionEstimateBagKey: String?
    private var cachedCompressionEstimates: [MediaUploadCompressionLevel: Int64] = [:]
    private var cachedCompressionEnabled: Set<MediaUploadCompressionLevel> = []
    private var cachedCompressionHasChoice = false
    private var lastAppliedCompressionSelection: MediaUploadCompressionLevel?
    private var lastAppliedCompressionSizesReady: Bool?
    private var lastAppliedCompressionControlEnabled: Bool?

    /// Serial chat-attach state for multi-file albums (PUTs stay parallel).
    private var albumShareSession: AlbumShareSession?

    private enum ShareConfirmationType {
        case text
        case item
        case objectShare
    }

    private final class AlbumShareSession {
        let albumUUID: String?
        var slots: [AlbumShareSlot]
        var nextPostIndex = 0
        var isPosting = false
        /// Inclusive index from which attaches are skipped (failed PUT/post of an earlier slot).
        var abortFromIndex: Int?

        init(albumUUID: String?, slots: [AlbumShareSlot]) {
            self.albumUUID = albumUUID
            self.slots = slots
        }

        func slotIndex(for item: ShareItem) -> Int? {
            slots.firstIndex { $0.item === item }
        }

        func markAbort(from index: Int) {
            if let existing = abortFromIndex {
                abortFromIndex = min(existing, index)
            } else {
                abortFromIndex = index
            }
        }
    }

    private struct AlbumShareSlot {
        let item: ShareItem
        let referenceId: String?
        var filePath: String?
        var draftFolderPath: String?
        var uploadReady = false
        var uploadFailed = false
        var posted = false
    }

    private enum UploadHUDPhase {
        /// Provider / iCloud / local staging copy (before preview is ready).
        case loadingMedia
        /// Send-path compression. `current` is 1-based; `total` is files being prepared.
        case preparing(current: Int, total: Int)
        /// PUT phase. `current` is 1-based; `total` is files being uploaded.
        case uploading(current: Int, total: Int)

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
            case .preparing(let current, let total), .uploading(let current, let total):
                if total <= 1 {
                    return NSLocalizedString("1 media file", comment: "Upload progress detail for a single file")
                }
                let safeCurrent = min(max(current, 1), total)
                return String.localizedStringWithFormat(
                    NSLocalizedString("%ld of %ld media files", comment: "Upload progress detail while processing file N of M"),
                    safeCurrent,
                    total
                )
            }
        }
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
            // Compose uses a standard (not themed-blue) nav bar — themeTextColor is white.
            indicator.color = NCAppBranding.themeColor()
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

    /// Last applied toolbar enablement — skip no-op updates during staging.
    private var lastToolbarChrome: (canAdd: Bool, canCrop: Bool)?

    /// Plain action row — not `UIToolbar`. iOS 26 Liquid Glass regroups toolbar items into
    /// capsules and the trash icon vanishes/reappears while media stages.
    private lazy var itemToolbar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .clear
        bar.isOpaque = false

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [
            removeItemButton,
            spacer,
            cropItemButton,
            addItemButton
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            removeItemButton.widthAnchor.constraint(equalToConstant: 44),
            removeItemButton.heightAnchor.constraint(equalToConstant: 44),
            cropItemButton.widthAnchor.constraint(equalToConstant: 44),
            cropItemButton.heightAnchor.constraint(equalToConstant: 44),
            addItemButton.widthAnchor.constraint(equalToConstant: 44),
            addItemButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        return bar
    }()

    private lazy var removeItemButton: UIButton = {
        makeToolbarIconButton(systemName: "trash", action: #selector(removeItemButtonPressed))
    }()

    private lazy var cropItemButton: UIButton = {
        makeToolbarIconButton(systemName: "crop.rotate", action: #selector(cropItemButtonPressed))
    }()

    private lazy var addItemButton: UIButton = {
        let button = makeToolbarIconButton(systemName: "plus", action: nil)

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
        button.showsMenuAsPrimaryAction = true

        return button
    }()

    private func makeToolbarIconButton(systemName: String, action: Selector?) -> UIButton {
        // `.custom` — `.system` still picks up iOS 26 glass chrome on some hosts.
        let button = UIButton(type: .custom)
        let image = UIImage(systemName: systemName)?.withRenderingMode(.alwaysTemplate)
        button.setImage(image, for: .normal)
        // System label — black in light / white in dark (not brand template blue).
        button.tintColor = .label
        button.backgroundColor = .clear
        button.adjustsImageWhenHighlighted = false
        button.translatesAutoresizingMaskIntoConstraints = false
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        return button
    }

    private static let compressionSegmentLevels: [MediaUploadCompressionLevel] = [.none, .low, .medium, .high]

    /// Standard segmented control (Apple “tab” iterator) for Manual compression levels.
    private lazy var compressionSegmentedControl: UISegmentedControl = {
        let items = Self.compressionSegmentLevels.map { self.title(for: $0) }
        let control = UISegmentedControl(items: items)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = MediaUploadCompressionLevel.medium.rawValue
        control.apportionsSegmentWidthsByContent = false
        control.addTarget(self, action: #selector(compressionSegmentChanged(_:)), for: .valueChanged)
        control.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return control
    }()

    private lazy var compressionTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = NSLocalizedString("Select Media Compression", comment: "Share sheet section header above compression quality control")
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        label.font = UIFont.systemFont(ofSize: footnote.pointSize, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        return label
    }()

    private lazy var compressionSectionView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [self.compressionTitleLabel, self.compressionSegmentedControl])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
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
        // Register immediately — staging can call reload/layout before viewDidLoad finishes,
        // and viewDidLoad used to early-return when the keychain token was missing (SIGABRT on dequeue).
        Self.registerShareConfirmationCell(on: collectionView)
        return collectionView
    }()

    private static func registerShareConfirmationCell(on collectionView: UICollectionView) {
        let bundle = Bundle(for: ShareConfirmationCollectionViewCell.self)
        collectionView.register(
            UINib(nibName: kShareConfirmationTableCellNibName, bundle: bundle),
            forCellWithReuseIdentifier: kShareConfirmationCellIdentifier
        )
    }

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

        // Compression first (primary Manual decision), then quiet edit actions, then media.
        NSLayoutConstraint.activate([
            self.compressionSectionView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor, constant: 12),
            self.compressionSectionView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor, constant: -12),

            self.itemToolbar.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
            self.itemToolbar.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
            self.itemToolbar.heightAnchor.constraint(equalToConstant: 44),
            self.itemToolbar.topAnchor.constraint(equalTo: self.compressionSectionView.bottomAnchor, constant: 4)
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

                self.compressionSectionView.topAnchor.constraint(equalTo: self.toLabelView.bottomAnchor, constant: 8)
            ])
        } else {
            // On iOS 26 we don't have a toLabel anymore, so we need to constraint to the safe area as well
            NSLayoutConstraint.activate([
                self.shareTextView.topAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.topAnchor),

                self.compressionSectionView.topAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.topAnchor, constant: 8)
            ])
        }

        NSLayoutConstraint.activate([
            self.shareCollectionView.leftAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.leftAnchor),
            self.shareCollectionView.rightAnchor.constraint(equalTo: self.shareContentView.safeAreaLayoutGuide.rightAnchor),
            self.shareCollectionView.topAnchor.constraint(equalTo: self.itemToolbar.bottomAnchor, constant: 4),
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
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeColor()
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

        // Drop any upload card kept alive from a prior share in this process (warm extension).
        if let previous = Self.retainedForUpload, previous !== self {
            previous.hideProgressAlert(animated: false)
            previous.releaseUploadRetention()
        }

        // Always wire UI first — never return before cell registration / chrome setup.
        Self.registerShareConfirmationCell(on: self.shareCollectionView)
        self.shareCollectionView.delegate = self

        if #unavailable(iOS 26) {
            let localizedToString = NSLocalizedString("To:", comment: "TRANSLATORS this is for sending something 'to' a user. E.g. 'To: John Doe'")
            let toString = localizedToString.withFont(.boldSystemFont(ofSize: 15)).withTextColor(.tertiaryLabel)
            let roomString = self.room.displayName.withFont(.systemFont(ofSize: 15)).withTextColor(.label)
            self.toLabel.attributedText = toString + NSAttributedString(string: " ") + roomString
        } else {
            self.navigationItem.title = self.room.displayName
        }

        self.configureCompressionUI()

        // Configure communication lib (token shared via main-app keychain access group).
        guard let userToken = NCKeyChainController.sharedInstance().token(forAccountId: self.account.accountId) else {
            NCLog.log("ShareConfirmation: missing keychain token for \(self.account.accountId) — open SumbaChat once after login, then retry share")
            return
        }
        NCLog.log("ShareConfirmation: keychain token OK for \(self.account.accountId) (len=\(userToken.count))")
        let userAgent = NCAppBranding.userAgent()

        NextcloudKit.shared.setup(account: self.account.accountId,
                                  user: self.account.user,
                                  userId: self.account.userId,
                                  password: userToken,
                                  urlBase: self.account.server,
                                  userAgent: userAgent,
                                  nextcloudVersion: self.serverCapabilities.versionMajor,
                                  delegate: self)
    }

    public override func viewWillAppear(_ animated: Bool) {
        // Add the cancel button in viewWillAppear, so that the caller can change the isModal property after initialization
        if self.isModal {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(self.cancelButtonPressed))
            cancelButton.accessibilityHint = NSLocalizedString("Double tap to dismiss sharing options", comment: "")

            self.navigationItem.leftBarButtonItem = cancelButton

            if #unavailable(iOS 26) {
                // Standard nav bar — system label (black/white), not brand blue.
                self.navigationItem.leftBarButtonItem?.tintColor = .label
            }
        }

        var captionAllowed = NCDatabaseManager.sharedInstance().serverHasTalkCapability(.mediaCaption, forAccountId: account.accountId)
        captionAllowed = captionAllowed && self.shareType == .item

        if !captionAllowed {
            self.navigationItem.rightBarButtonItem = self.sendButton
            if #unavailable(iOS 26) {
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeColor()
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

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // Re-bake compression chip images — light/dark text is painted into bitmaps.
        self.lastAppliedCompressionSelection = nil
        self.updateCompressionOptionsUI()
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
        // Keep the icon visible when only one item remains; ignore taps instead of disabling.
        guard self.shareItemController.shareItems.count > 1,
              let item = self.getCurrentShareItem() else { return }
        self.shareItemController.remove(item)
    }

    func cropItemButtonPressed() {
        if let item = self.getCurrentShareItem(),
           let image = self.shareItemController.getImageFrom(item) {

            let cropViewController = TOCropViewController(image: image)
            cropViewController.delegate = self
            self.present(cropViewController, animated: true)
        }
    }

    @objc private func compressionSegmentChanged(_ sender: UISegmentedControl) {
        let index = sender.selectedSegmentIndex
        guard index >= 0,
              index < Self.compressionSegmentLevels.count else { return }

        let level = Self.compressionSegmentLevels[index]

        // Use cached enablement once sizes are ready — don't re-run bag heuristics on every tap.
        guard sender.isEnabledForSegment(at: index) else {
            sender.selectedSegmentIndex = self.chosenCompressionLevel.rawValue
            return
        }
        if self.lastAppliedCompressionSizesReady == true,
           !self.cachedCompressionEnabled.contains(level) {
            sender.selectedSegmentIndex = self.chosenCompressionLevel.rawValue
            return
        }

        self.chosenCompressionLevel = level
        self.lastAppliedCompressionSelection = level
        sender.selectedSegmentIndex = level.rawValue
        // Refresh two-line images so the selected segment uses contrasting (white) text.
        self.applyCompressionSegmentTitles(estimates: self.cachedCompressionEstimates,
                                           enabled: self.lastAppliedCompressionSizesReady == true
                                               ? self.cachedCompressionEnabled
                                               : Set(Self.compressionSegmentLevels),
                                           sizesReady: self.lastAppliedCompressionSizesReady == true)
    }

    /// Nav-bar Cancel — leave SumbaChat and return to the host (Photos / chat).
    func cancelButtonPressed() {
        self.leaveShareFlow(reason: "nav-cancel")
    }

    /// Progress-card Cancel — abort prepare/upload and return to compose (previews + compression).
    /// If compose was already dismissed (in-app HUD on chat), leave the share flow instead.
    private func cancelUploadAndReturnToCompose() {
        guard self.isPreparingForUpload || self.isUploadingMedia || self.isInSendProgressMode || self.progressAlert != nil else {
            return
        }
        if self.composeDismissedForUpload {
            self.leaveShareFlow(reason: "upload-cancel-no-compose")
            return
        }

        NCLog.log("Media upload: user cancelled — return to compose")
        MediaUploadTrace.log("SEND cancel abort — return to compose")

        let uploadInFlight = self.isUploadingMedia || !self.uploadTasks.isEmpty
        self.abortMediaFlowWork()
        self.hideProgressAlert()
        self.uploadErrors.removeAll()
        self.uploadSuccess.removeAll()

        if uploadInFlight {
            // Keep `mediaFlowCancelled` until uploadGroup.notify so a late completion
            // doesn't treat the aborted run as success. Cleared there.
            MediaUploadDiskStore.scheduleClearSessionScratchCaches(
                reason: "upload-cancel-compose",
                afterDelay: MediaUploadDiskStore.scratchClearAfterCancelDelay
            )
        } else {
            MediaUploadDiskStore.clearSessionScratchCaches(reason: "upload-cancel-compose", wait: false)
            self.mediaFlowCancelled = false
        }

        self.exitSendProgressMode()
        self.updateCompressionOptionsUI()
        self.updateSendButtonEnabledState()
    }

    /// Stop prepare/upload work. Does not change compose chrome — caller decides leave vs restore.
    private func abortMediaFlowWork() {
        self.mediaFlowCancelled = true
        self.shareItemController.cancelPreparation()
        for task in self.uploadTasks {
            task.cancel()
        }
        self.uploadTasks.removeAll()
        self.isPreparingForUpload = false
        self.isUploadingMedia = false
        self.suppressMediaPreviews = false
    }

    private func leaveShareFlow(reason: String) {
        NCLog.log("Media upload: leaving share flow (\(reason))")
        let wasUploading = self.isUploadingMedia || !self.uploadTasks.isEmpty
        self.stopUploadSessionHeartbeat()
        self.abortMediaFlowWork()
        self.hideProgressAlert(animated: false)
        self.isInSendProgressMode = false
        self.restoreExtensionProgressChromeIfNeeded()
        if wasUploading {
            MediaUploadDiskStore.scheduleClearSessionScratchCaches(
                reason: "sheet-dismiss",
                afterDelay: MediaUploadDiskStore.scratchClearAfterCancelDelay
            )
        } else {
            MediaUploadDiskStore.clearSessionScratchCaches(reason: "sheet-dismiss", wait: false)
        }
        let notifyCancel = { [weak self] in
            guard let self else { return }
            self.restoreExtensionProgressChromeIfNeeded()
            self.releaseUploadRetention()
            self.delegate?.shareConfirmationViewControllerDidCancel(self)
        }
        runWhenComposeDismissSettled(notifyCancel)
    }

    /// Drop heavy preview bitmaps before encode/upload (jetsam). Does not blank the UI.
    private func releaseComposePreviewsForUpload() {
        self.isInSendProgressMode = true
        self.textView.resignFirstResponder()
        self.suppressMediaPreviews = true
        for item in self.shareItemController.shareItems {
            item.placeholderImage = nil
        }
        MediaUploadTrace.logSync("SEND progress-mode previews released items=\(self.shareItemController.shareItems.count)")
    }

    /// Blank the sheet while showing bottom progress (share extension).
    /// Keeps the VC presented so Cancel can restore compose. Clears opaque chrome so
    /// Photos shows through behind the progress card.
    ///
    /// iOS 26: clearing only our VC views is not enough — the system share-sheet container
    /// stays opaque white (Apple FB20934974). Walk superviews and clear those too.
    private func hideComposeChromeForUploadProgress() {
        self.shareContentView.isHidden = true
        self.navigationItem.rightBarButtonItem = nil

        if !extensionProgressChromeActive {
            extensionProgressChromeActive = true
            savedNavigationTitle = navigationItem.title
            savedLeftBarButtonItem = navigationItem.leftBarButtonItem
            savedViewBackgroundColor = view.backgroundColor
            savedNavControllerBackgroundColor = navigationController?.view.backgroundColor
            savedTableViewBackgroundColor = tableView?.backgroundColor
            savedTextInputbarHidden = textInputbar.isHidden
            savedUnderlyingViewsHidden.removeAll()

            navigationItem.title = nil
            navigationItem.leftBarButtonItem = nil
            navigationController?.setNavigationBarHidden(true, animated: false)
            setTextInputbarHidden(true, animated: false)

            // Clear every opaque surface in our stack so the host app is visible.
            view.isOpaque = false
            view.backgroundColor = .clear
            tableView?.isOpaque = false
            tableView?.backgroundColor = .clear
            tableView?.isHidden = true
            textInputbar.isHidden = true
            textInputbar.backgroundColor = .clear

            if let navView = navigationController?.view {
                navView.isOpaque = false
                navView.backgroundColor = .clear
            }
            // Room list (and any other VC under us) would otherwise paint white over Photos.
            for vc in navigationController?.viewControllers ?? [] where vc !== self {
                let id = ObjectIdentifier(vc)
                savedUnderlyingViewsHidden[id] = vc.view.isHidden
                vc.view.isHidden = true
            }
        }
        clearShareSheetContainerBackgroundsIfNeeded()
        MediaUploadTrace.logSync("SEND progress-mode compose hidden (bottom-compact, clear sheet)")
    }

    /// iOS 26 share extension: system sheet wrappers ignore `.clear` on the VC alone.
    private func clearShareSheetContainerBackgroundsIfNeeded() {
        guard isAppExtensionProcess else { return }
        var node: UIView? = view
        while let current = node {
            current.isOpaque = false
            current.backgroundColor = .clear
            node = current.superview
        }
        if #available(iOS 26.1, *) {
            // Empty color effect → no Liquid Glass fill on the sheet container.
            navigationController?.sheetPresentationController?.backgroundEffect = UIColorEffect()
            sheetPresentationController?.backgroundEffect = UIColorEffect()
        }
    }

    private func restoreExtensionProgressChromeIfNeeded() {
        guard extensionProgressChromeActive else { return }
        extensionProgressChromeActive = false
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationItem.title = savedNavigationTitle
        navigationItem.leftBarButtonItem = savedLeftBarButtonItem

        view.isOpaque = true
        view.backgroundColor = savedViewBackgroundColor
        tableView?.isOpaque = true
        tableView?.backgroundColor = savedTableViewBackgroundColor
        tableView?.isHidden = false
        textInputbar.backgroundColor = nil
        setTextInputbarHidden(savedTextInputbarHidden, animated: false)

        if let navView = navigationController?.view {
            navView.isOpaque = true
            navView.backgroundColor = savedNavControllerBackgroundColor ?? .systemBackground
        }
        for vc in navigationController?.viewControllers ?? [] where vc !== self {
            let id = ObjectIdentifier(vc)
            vc.view.isHidden = savedUnderlyingViewsHidden[id] ?? false
        }

        savedNavigationTitle = nil
        savedLeftBarButtonItem = nil
        savedViewBackgroundColor = nil
        savedNavControllerBackgroundColor = nil
        savedTableViewBackgroundColor = nil
        savedUnderlyingViewsHidden.removeAll()
    }

    private var isAppExtensionProcess: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    private var progressAlertHostView: UIView {
        progressHostView ?? view
    }

    private func releaseUploadRetention() {
        if Self.retainedForUpload === self {
            Self.retainedForUpload = nil
        }
        progressHostView = nil
        progressHostViewController = nil
        finishAfterComposeDismiss = nil
        isDismissingComposeForUpload = false
        composeDismissedForUpload = false
    }

    private func runWhenComposeDismissSettled(_ work: @escaping () -> Void) {
        if isDismissingComposeForUpload {
            finishAfterComposeDismiss = work
        } else {
            work()
        }
    }

    /// In-app modal: dismiss compose, host HUD on chat. Share Extension keeps the sheet.
    @discardableResult
    private func dismissComposeThenShowProgress(phase: UploadHUDPhase, progress: Float?, indeterminate: Bool) -> Bool {
        guard !isAppExtensionProcess, isModal, !composeDismissedForUpload else { return false }
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        guard let presenter else { return false }

        composeDismissedForUpload = true
        isDismissingComposeForUpload = true
        Self.retainedForUpload = self
        // Prefer the window: chat `view` sits under the modal, so a HUD parented there is
        // invisible until dismiss — and UIView animations on an off-window host can stick at alpha 0.
        progressHostView = presenter.view.window ?? view.window ?? presenter.view
        progressHostViewController = presenter

        showProgressAlert(phase: phase, progress: progress, indeterminate: indeterminate)

        let toDismiss: UIViewController = navigationController ?? self
        MediaUploadTrace.logSync(
            "SEND dismiss compose + HUD host=\(type(of: progressHostView!)) inWindow=\(progressHostView?.window != nil)"
        )
        toDismiss.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.isDismissingComposeForUpload = false
            // Re-assert on the (now visible) chat window after dismiss settles.
            if let host = self.progressHostView ?? presenter.view.window ?? presenter.view {
                self.progressHostView = host
                if let phase = self.lastProgressPhase {
                    self.showProgressAlert(phase: phase,
                                           progress: self.lastProgressValue,
                                           indeterminate: self.lastProgressIndeterminate)
                }
            }
            if let finish = self.finishAfterComposeDismiss {
                self.finishAfterComposeDismiss = nil
                finish()
            }
        }
        return true
    }

    /// Begin progress UI: in-app dismisses sheet then HUD on chat; appex blanks sheet + bottom card.
    private func beginUploadProgressUI(phase: UploadHUDPhase, progress: Float?, indeterminate: Bool) {
        if dismissComposeThenShowProgress(phase: phase, progress: progress, indeterminate: indeterminate) {
            return
        }
        if isAppExtensionProcess {
            hideComposeChromeForUploadProgress()
        } else {
            // In-app fallback if dismiss wasn't possible — hide compose under centered HUD.
            setTextInputbarHidden(true, animated: false)
            shareContentView.isHidden = true
            navigationItem.rightBarButtonItem = nil
        }
        showProgressAlert(phase: phase, progress: progress, indeterminate: indeterminate)
    }

    /// Restore compose after a failed/cancelled send (or leave flow on success/host cancel).
    private func exitSendProgressMode() {
        // Even if the flag was cleared by a race, still restore clear-sheet chrome + compose.
        self.isInSendProgressMode = false
        self.restoreExtensionProgressChromeIfNeeded()
        self.shareContentView.isHidden = false
        self.suppressMediaPreviews = false
        self.shareCollectionView.isUserInteractionEnabled = true
        self.compressionSegmentedControl.isUserInteractionEnabled = true

        let captionAllowed = NCDatabaseManager.sharedInstance().serverHasTalkCapability(.mediaCaption, forAccountId: account.accountId)
            && self.shareType == .item
        if captionAllowed {
            self.setTextInputbarHidden(false, animated: false)
        } else {
            self.setTextInputbarHidden(true, animated: false)
            self.navigationItem.rightBarButtonItem = self.sendButton
            if #unavailable(iOS 26) {
                self.navigationItem.rightBarButtonItem?.tintColor = NCAppBranding.themeColor()
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

        MediaUploadHaptics.prepare()
        MediaUploadHaptics.sendStarted()

        // Drop preview bitmaps; in-app dismisses the sheet then shows HUD on chat.
        self.releaseComposePreviewsForUpload()

        if mode == .noCompression {
            MediaUploadTrace.log("SEND decision=skip-compress (No Compression) — upload originals")
            for item in self.shareItemController.shareItems {
                let bytes = MediaUploadPreprocessor.fileSizePublic(at: item.fileURL)
                MediaUploadTrace.log("PLAN \(item.fileName ?? "unknown") level=none(original) original=\(MediaUploadTrace.mb(bytes)) estimate=n/a")
            }
            self.beginUploadProgressUI(phase: .uploading(current: 1, total: mediaCount), progress: 0, indeterminate: false)
            self.uploadAndShareFiles()
            return
        }

        self.isPreparingForUpload = true
        self.beginUploadProgressUI(phase: .preparing(current: 1, total: mediaCount), progress: 0, indeterminate: false)

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
        }, progress: { [weak self] fraction, current, total in
            guard let self, !self.mediaFlowCancelled else { return }
            let prepareTotal = total > 0 ? total : mediaCount
            let prepareCurrent = total > 0 ? current : 1
            self.showProgressAlert(phase: .preparing(current: prepareCurrent, total: prepareTotal),
                                   progress: fraction * self.prepareProgressShare,
                                   indeterminate: false)
        }, completion: { [weak self] in
            guard let self else { return }
            // Keep isPreparingForUpload true until upload path is entered — no preview regen window.
            if self.mediaFlowCancelled {
                NCLog.logSync("Media upload: prepare finished after cancel — skipping upload")
                self.isPreparingForUpload = false
                self.isUploadingMedia = false
                self.suppressMediaPreviews = false
                self.hideProgressAlert()
                // Compose restore already done by cancelUploadAndReturnToCompose when applicable.
                if self.isInSendProgressMode {
                    self.exitSendProgressMode()
                } else {
                    self.restoreExtensionProgressChromeIfNeeded()
                }
                self.mediaFlowCancelled = false
                self.updateSendButtonEnabledState()
                return
            }
            for item in self.shareItemController.shareItems {
                let bytes = MediaUploadPreprocessor.fileSizePublic(at: item.fileURL)
                MediaUploadTrace.logSync("PREPARE done \(item.fileName ?? "unknown") uploadBytes=\(MediaUploadTrace.mb(bytes))")
            }
            MediaUploadTrace.logSync("PREPARE finished → upload \(self.shareItemController.shareItems.count) item(s) (maxConcurrentPUTs=\(MediaUploadDiskStore.maxConcurrentUploads))")
            let uploadTotal = self.shareItemController.shareItems.count
            self.showProgressAlert(phase: .uploading(current: 1, total: uploadTotal),
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
                    self.suppressMediaPreviews = false
                    self.hideProgressAlert()
                    if self.isInSendProgressMode {
                        self.exitSendProgressMode()
                    } else {
                        self.restoreExtensionProgressChromeIfNeeded()
                    }
                    self.mediaFlowCancelled = false
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
        let localized: String
        switch level {
        case .none:
            localized = NSLocalizedString("None", comment: "No media compression")
        case .low:
            localized = NSLocalizedString("Low", comment: "Low media compression")
        case .medium:
            localized = NSLocalizedString("Medium", comment: "Medium media compression")
        case .high:
            localized = NSLocalizedString("High", comment: "High media compression")
        @unknown default:
            return ""
        }
        return localized.uppercased(with: .current)
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

    private func compressionBagFingerprint(urls: [URL], loading: Bool) -> String {
        if loading { return "loading" }
        let parts: [String] = urls.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            return "\(url.path)=\(size)"
        }
        return parts.sorted().joined(separator: "\n")
    }

    private func invalidateCompressionEstimateCache() {
        self.compressionEstimateBagKey = nil
        self.cachedCompressionEstimates = [:]
        self.cachedCompressionEnabled = []
        self.cachedCompressionHasChoice = false
        self.lastAppliedCompressionSelection = nil
        self.lastAppliedCompressionSizesReady = nil
        self.lastAppliedCompressionControlEnabled = nil
    }

    private func updateCompressionOptionsUI() {
        // Keep the section visible (and height reserved) for Manual mode so the control appearing
        // later doesn't shift the media pager. While staging, show disabled segments with "–".
        let showQuality = self.mediaUploadMode == .chooseOnUpload && self.shareType == .item

        self.compressionSectionView.isHidden = !showQuality
        // Caption + spacing + 52pt two-line segmented control.
        self.compressionSectionHeightConstraint?.constant = showQuality ? 78 : 0

        guard showQuality else {
            self.invalidateCompressionEstimateCache()
            self.view.layoutIfNeeded()
            return
        }

        let loading = self.shareItemController.isBusyLoadingMedia
        let items = self.shareItemController.shareItems
        let urls = items.compactMap(\.fileURL)
        let bagKey = self.compressionBagFingerprint(urls: urls, loading: loading)

        // Estimates need staged files — avoid mid-copy JPEG/AVAsset work.
        // Keep chips fully visible with "–" sizes while staging (never dim/hide the section).
        guard !loading, !urls.isEmpty else {
            self.compressionEstimateBagKey = nil
            self.applyCompressionSegmentTitles(estimates: [:],
                                               enabled: Set(Self.compressionSegmentLevels),
                                               sizesReady: false)
            self.view.layoutIfNeeded()
            return
        }

        let estimates: [MediaUploadCompressionLevel: Int64]
        let enabled: Set<MediaUploadCompressionLevel>
        let hasCompressChoice: Bool
        let bagChanged = bagKey != self.compressionEstimateBagKey

        if bagChanged {
            // One estimate pass: label totals + any-item enablement (Send keeps original for non-winners).
            let bag = MediaUploadPreprocessor.bagCompressionEstimates(forFileURLs: urls)
            let totals = bag.totals
            estimates = [
                .none: totals.none,
                .low: totals.low,
                .medium: totals.medium,
                .high: totals.high
            ]
            enabled = bag.enabled
            hasCompressChoice = enabled.contains(.low) || enabled.contains(.medium) || enabled.contains(.high)

            self.compressionEstimateBagKey = bagKey
            self.cachedCompressionEstimates = estimates
            self.cachedCompressionEnabled = enabled
            self.cachedCompressionHasChoice = hasCompressChoice

            // Original already smaller/better than Low/Med/High → only NONE stays selectable.
            if !enabled.contains(self.chosenCompressionLevel) {
                if self.chosenCompressionLevel != .none {
                    MediaUploadTrace.log("CHIPS selected=\(MediaUploadTrace.levelName(self.chosenCompressionLevel)) not useful → fall back to none")
                }
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
            for (url, per) in zip(urls, bag.perItem) {
                MediaUploadTrace.log(String(format:
                    "CHIPS item %@ original=%@ est low=%@ med=%@ high=%@",
                    url.lastPathComponent,
                    MediaUploadTrace.mb(per.none),
                    MediaUploadTrace.mb(per.low),
                    MediaUploadTrace.mb(per.medium),
                    MediaUploadTrace.mb(per.high)))
            }
        } else {
            estimates = self.cachedCompressionEstimates
            enabled = self.cachedCompressionEnabled
            hasCompressChoice = self.cachedCompressionHasChoice

            if !enabled.contains(self.chosenCompressionLevel) {
                self.chosenCompressionLevel = .none
            }

            // Same bag + same selection already painted — skip UI work from items/preparing redraws.
            if self.lastAppliedCompressionSizesReady == true,
               self.lastAppliedCompressionControlEnabled == hasCompressChoice,
               self.lastAppliedCompressionSelection == self.chosenCompressionLevel {
                return
            }
        }

        self.applyCompressionSegmentTitles(estimates: estimates,
                                           enabled: enabled,
                                           sizesReady: true)
        self.view.layoutIfNeeded()
    }

    private func applyCompressionSegmentTitles(estimates: [MediaUploadCompressionLevel: Int64],
                                               enabled: Set<MediaUploadCompressionLevel>,
                                               sizesReady: Bool) {
        let control = self.compressionSegmentedControl
        let traits = self.traitCollection
        let unselectedColor = self.compressionSegmentUnselectedTextColor(for: traits)
        let disabledColor = unselectedColor.withAlphaComponent(0.35)

        // System segmented styling; selected thumb uses brand tint.
        control.selectedSegmentTintColor = NCAppBranding.elementColor()
        // Transparent glyph images are templated unless alwaysOriginal sticks — keep tint readable
        // if UIKit still tints, and drive title attributes for the same states.
        control.tintColor = unselectedColor
        control.setTitleTextAttributes([.foregroundColor: unselectedColor], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: disabledColor], for: .disabled)

        // Keep a selection highlighted while sizes load (dashes under labels).
        let selectedIndex: Int
        if sizesReady {
            let index = self.chosenCompressionLevel.rawValue
            if index >= 0,
               index < control.numberOfSegments,
               enabled.contains(Self.compressionSegmentLevels[index]) {
                control.selectedSegmentIndex = index
                selectedIndex = index
            } else {
                control.selectedSegmentIndex = MediaUploadCompressionLevel.none.rawValue
                self.chosenCompressionLevel = .none
                selectedIndex = MediaUploadCompressionLevel.none.rawValue
            }
        } else {
            let index = min(max(self.chosenCompressionLevel.rawValue, 0), control.numberOfSegments - 1)
            control.selectedSegmentIndex = index
            selectedIndex = index
        }

        // UISegmentedControl truncates `setTitle` newlines — render level + estimate as images.
        let segmentWidth = max(64, floor((max(control.bounds.width, 320) - 8) / CGFloat(Self.compressionSegmentLevels.count)))

        for (index, level) in Self.compressionSegmentLevels.enumerated() {
            let levelTitle = self.title(for: level)
            let sizeTitle: String
            let isEnabled: Bool
            if sizesReady {
                let estimated = estimates[level] ?? 0
                sizeTitle = self.sizeLabel(for: level, estimated: estimated)
                isEnabled = enabled.contains(level)
            } else {
                sizeTitle = "–"
                // Fully interactive-looking while estimates load; sizes fill in when ready.
                isEnabled = true
            }

            let isSelected = index == selectedIndex
            let foreground: UIColor
            let sizeAlpha: CGFloat
            if !isEnabled {
                // Title and size share the same muted color (sizeAlpha 1 = no extra brightening).
                foreground = disabledColor
                sizeAlpha = 1.0
            } else if isSelected {
                // Selected thumb is brand blue in light and dark.
                foreground = .white
                sizeAlpha = 0.95
            } else {
                foreground = unselectedColor
                sizeAlpha = 0.72
            }

            control.setTitle(nil, forSegmentAt: index)
            control.setImage(
                self.compressionSegmentImage(
                    levelTitle: levelTitle,
                    sizeTitle: sizeTitle,
                    foreground: foreground,
                    sizeAlpha: sizeAlpha,
                    width: segmentWidth,
                    traits: traits
                ),
                forSegmentAt: index
            )
            control.setEnabled(isEnabled, forSegmentAt: index)
        }

        // Chips stay fully visible. When original already wins, only NONE is enabled —
        // Low/Med/High are disabled individually (never dim/disable the whole control).
        control.isEnabled = true
        self.compressionSectionView.alpha = 1.0
        self.compressionTitleLabel.textColor = .secondaryLabel

        if !sizesReady {
            self.lastAppliedCompressionSizesReady = false
            self.lastAppliedCompressionControlEnabled = false
            self.lastAppliedCompressionSelection = self.chosenCompressionLevel
            return
        }

        self.lastAppliedCompressionSizesReady = true
        self.lastAppliedCompressionControlEnabled = enabled.contains(.low)
            || enabled.contains(.medium)
            || enabled.contains(.high)
        self.lastAppliedCompressionSelection = self.chosenCompressionLevel
    }

    /// Non-dynamic colors for baked segment images (`.label` can resolve wrong at render time).
    private func compressionSegmentUnselectedTextColor(for traits: UITraitCollection) -> UIColor {
        let style = traits.userInterfaceStyle
        if style == .dark {
            return .white
        }
        // Light (and unspecified): dark text on the system light segment track.
        return UIColor(white: 0.12, alpha: 1.0)
    }

    /// Two-line segment content. `UISegmentedControl` does not display `\n` in `setTitle`.
    private func compressionSegmentImage(levelTitle: String,
                                         sizeTitle: String,
                                         foreground: UIColor,
                                         sizeAlpha: CGFloat,
                                         width: CGFloat,
                                         traits: UITraitCollection) -> UIImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 1

        let levelFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let sizeFont = UIFont.systemFont(ofSize: 10, weight: .medium)
        // Bake resolved colors — dynamic UIColors in bitmaps often flip to the wrong style.
        let titleColor = foreground.resolvedColor(with: traits)
        // Multiply alpha (don't replace): disabled titles are already ~0.35; replacing with
        // sizeAlpha 1.0 was painting sizes fully opaque white.
        let detailColor = titleColor.withAlphaComponent(titleColor.cgColor.alpha * sizeAlpha)

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: levelTitle + "\n", attributes: [
            .font: levelFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph
        ]))
        text.append(NSAttributedString(string: sizeTitle, attributes: [
            .font: sizeFont,
            .foregroundColor: detailColor,
            .paragraphStyle: paragraph
        ]))

        let height: CGFloat = 36
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            let maxTextSize = CGSize(width: width - 4, height: height)
            let textHeight = ceil(text.boundingRect(
                with: maxTextSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            let originY = max(0, (height - textHeight) / 2)
            let textBounds = CGRect(x: 2, y: originY, width: width - 4, height: textHeight)
            text.draw(with: textBounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        // Rewrap so UISegmentedControl cannot treat the transparent glyph as a template (white tint).
        if let cgImage = image.cgImage {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
                .withRenderingMode(.alwaysOriginal)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func configureCompressionUI() {
        MediaUploadAutomaticPolicy.startMonitoringIfNeeded()
        self.updateCompressionOptionsUI()
    }

    private func progressAlertStyle(for phase: UploadHUDPhase) -> MediaUploadProgressAlert.Style {
        switch phase {
        case .loadingMedia:
            // Always centered. The branded bottom card is Send-path only — using it during
            // staging looked like a leftover "Uploading…" sheet from a prior share session.
            return .centeredAlert
        case .preparing, .uploading:
            // Share Extension: branded bottom card over Photos. In-app: centered on chat/compose.
            if isAppExtensionProcess, !composeDismissedForUpload, progressHostView == nil {
                return .bottomCompactBranded
            }
            return .centeredAlert
        }
    }

    private func showProgressAlert(phase: UploadHUDPhase, progress: Float?, indeterminate: Bool) {
        lastProgressPhase = phase
        lastProgressValue = progress
        lastProgressIndeterminate = indeterminate

        let host = progressAlertHostView
        let style = progressAlertStyle(for: phase)
        let alert: MediaUploadProgressAlert
        if let existing = self.progressAlert, existing.style == style {
            alert = existing
            alert.present(on: host, animated: false)
        } else {
            self.progressAlert?.dismiss(animated: false)
            alert = MediaUploadProgressAlert(style: style)
            self.progressAlert = alert
            alert.present(on: host, animated: true)
        }

        alert.onCancel = { [weak self] in
            guard let self else { return }
            if case .loadingMedia = self.lastProgressPhase {
                // Abandon pick/staging — same as nav Cancel (no prepare/upload in flight yet).
                self.leaveShareFlow(reason: "loading-cancel")
            } else {
                self.cancelUploadAndReturnToCompose()
            }
        }

        alert.update(title: phase.title,
                     message: phase.details,
                     progress: progress,
                     indeterminate: indeterminate,
                     showsCancel: true)
    }

    private func hideProgressAlert(animated: Bool = true) {
        lastProgressPhase = nil
        lastProgressValue = nil
        lastProgressIndeterminate = false
        let alert = self.progressAlert
        self.progressAlert = nil
        alert?.dismiss(animated: animated)
    }

    private func presentUploadFailureOnHost(message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Upload failed", comment: ""),
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        if let host = progressHostViewController {
            host.present(alert, animated: true)
        } else if presentedViewController == nil, view.window != nil {
            present(alert, animated: true)
        }
    }

    /// Record a user-facing upload error. Technical detail stays in logs only.
    private func recordUploadError(code: Int = 0, fileName: String? = nil, technical: String? = nil) {
        if let technical, !technical.isEmpty {
            NCLog.log("Media upload error (UI sanitized): \(technical)")
        }
        let message = NCAPIController.userFacingFileUploadError(code: code)
        if let fileName, !fileName.isEmpty, code != 429, code != 401, code != 403, code != 413, code != 507 {
            uploadErrors.append(String.localizedStringWithFormat(
                NSLocalizedString("Couldn't upload “%@”. Try again.", comment: "Per-file upload failure"),
                fileName
            ))
        } else {
            uploadErrors.append(message)
        }
    }

    private func presentRecordedUploadFailures() {
        // Deduplicate (e.g. two files both hit 429) so the alert stays readable.
        var seen = Set<String>()
        let unique = uploadErrors.filter { seen.insert($0).inserted }
        let message: String
        if unique.count == 1, uploadErrors.count > 1 {
            message = String.localizedStringWithFormat(
                NSLocalizedString("%ld files couldn't be uploaded.\n%@", comment: "Multiple uploads failed with the same reason"),
                uploadErrors.count,
                unique[0]
            )
        } else {
            message = unique.joined(separator: "\n")
        }
        presentUploadFailureOnHost(message: message)
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
            let items = self.shareItemController.shareItems
            let total = items.count
            guard total > 0 else { return }

            var progressSum: CGFloat = 0
            var completed = 0
            for shareItem in items {
                progressSum += shareItem.uploadProgress
                if shareItem.uploadProgress >= 1.0 - .ulpOfOne {
                    completed += 1
                }
            }

            let uploadFraction = Float(progressSum / CGFloat(total))
            let prepareShare = self.mediaUploadMode == .noCompression ? 0 : self.prepareProgressShare
            let current = completed >= total ? total : max(1, completed + 1)
            self.showProgressAlert(phase: .uploading(current: current, total: total),
                                   progress: prepareShare + (1 - prepareShare) * uploadFraction,
                                   indeterminate: false)
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
        self.showProgressAlert(phase: .uploading(current: 1, total: count), progress: prepareShare, indeterminate: false)

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
                        self.isInSendProgressMode = false
                        let message = NSLocalizedString("Could not prepare upload folder", comment: "")
                        let settle = {
                            self.hideProgressAlert()
                            if self.composeDismissedForUpload {
                                self.presentUploadFailureOnHost(message: message)
                                self.releaseUploadRetention()
                            } else {
                                self.exitSendProgressMode()
                                self.presentUploadFailureOnHost(message: message)
                            }
                            bgTask.stopBackgroundTask()
                        }
                        self.runWhenComposeDismissSettled(settle)
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

        // Re-assert NK credentials right before PROPFIND/PUT (appex can race session setup).
        NCAPIController.sharedInstance().setupNCCommunication(forAccount: self.account)
        if let token = NCKeyChainController.sharedInstance().token(forAccountId: self.account.accountId) {
            NextcloudKit.shared.setup(account: self.account.accountId,
                                      user: self.account.user,
                                      userId: self.account.userId,
                                      password: token,
                                      urlBase: self.account.server,
                                      userAgent: NCAppBranding.userAgent(),
                                      nextcloudVersion: self.serverCapabilities.versionMajor,
                                      delegate: self)
            NCLog.log("Media upload: NK ready user=\(self.account.user) userId=\(self.account.userId) server=\(self.account.server) attachments=\(self.serverCapabilities.attachmentsFolder)")
        }

        var uploadables: [ShareItem] = []
        for shareItem in self.shareItemController.shareItems {
            let byteCount = (try? FileManager.default.attributesOfItem(atPath: shareItem.filePath)[.size] as? NSNumber)?.int64Value ?? 0
            if byteCount == 0 {
                let name = shareItem.fileName ?? "file"
                let path = shareItem.filePath ?? "?"
                NCLog.log("Media upload: refusing 0-byte upload for \(name) at \(path)")
                self.uploadErrors.append(String.localizedStringWithFormat(
                    NSLocalizedString("“%@” is empty and was not uploaded.", comment: "Upload aborted because staged file has 0 bytes"),
                    name
                ))
                continue
            }
            uploadables.append(shareItem)
        }

        let albumCount = uploadables.count
        let canStampAlbum = albumCount >= 2
            && NCDatabaseManager.sharedInstance().serverHasTalkCapability(.chatReferenceId, forAccountId: self.account.accountId)
        let albumUUID = canStampAlbum ? SumbaMediaAlbum.makeAlbumUUID() : nil
        var slots: [AlbumShareSlot] = []
        for (offset, item) in uploadables.enumerated() {
            let referenceId: String?
            if let albumUUID {
                referenceId = SumbaMediaAlbum.referenceId(uuid: albumUUID, index: offset + 1, count: albumCount)
            } else {
                referenceId = nil
            }
            slots.append(AlbumShareSlot(item: item, referenceId: referenceId))
        }
        self.albumShareSession = AlbumShareSession(albumUUID: albumUUID, slots: slots)
        if let albumUUID {
            NCLog.log("Media upload: album \(albumUUID) count=\(albumCount) — parallel PUT, serial attach")
        }

        for shareItem in uploadables {
            let byteCount = (try? FileManager.default.attributesOfItem(atPath: shareItem.filePath)[.size] as? NSNumber)?.int64Value ?? 0
            let uploadName = shareItem.fileName ?? "file"
            let uploadPath = shareItem.filePath ?? "?"
            NCLog.log("Media upload: uploading \(uploadName) (\(byteCount) bytes) from \(uploadPath)")

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
                    self.uploadErrors.append(NSLocalizedString("Couldn't prepare the upload. Try again.", comment: "User-facing missing server path"))
                    self.markAlbumSlotUploadFailed(for: shareItem)
                    self.uploadGroup.leave()
                }
            } else {
                NCAPIController.sharedInstance().uniqueNameForFileUpload(withName: shareItem.fileName, isOriginalName: true, forAccount: self.account) { fileServerURL, fileServerPath, errorCode, errorDescription in
                    if let fileServerURL, let fileServerPath {
                        self.uploadFile(to: fileServerURL, with: fileServerPath, draftFolderPath: nil, with: shareItem)
                    } else {
                        NCLog.log(String(format: "Error finding unique upload name. code=%ld Error: %@", errorCode, errorDescription ?? "Unknown error"))
                        // errorDescription is already user-facing from NCAPIController.
                        self.uploadErrors.append(errorDescription ?? NCAPIController.userFacingFileUploadError(code: errorCode))
                        self.markAlbumSlotUploadFailed(for: shareItem)
                        self.uploadGroup.leave()
                    }
                }
            }
        }

        self.uploadGroup.notify(queue: .main) {
            self.isUploadingMedia = false
            self.isPreparingForUpload = false
            self.uploadTasks.removeAll()
            self.albumShareSession = nil

            let settle: () -> Void = { [weak self] in
                guard let self else { return }
                // Instant dismiss so the branded card cannot flash into the next share session.
                self.hideProgressAlert(animated: false)

                if self.mediaFlowCancelled {
                    NCLog.log("Media upload: upload group finished after cancel — suppressing result UI")
                    self.hideProgressAlert(animated: false)
                    if self.composeDismissedForUpload {
                        // In-app: compose already gone — finish leave cleanup.
                        self.isInSendProgressMode = false
                        self.restoreExtensionProgressChromeIfNeeded()
                        self.releaseUploadRetention()
                    } else if self.isInSendProgressMode {
                        // Race: cancel path hadn't restored compose yet.
                        self.exitSendProgressMode()
                    } else {
                        self.restoreExtensionProgressChromeIfNeeded()
                    }
                    self.mediaFlowCancelled = false
                    self.updateSendButtonEnabledState()
                    bgTask.stopBackgroundTask()
                    return
                }

                // TODO: Do error reporting per item
                if self.uploadErrors.isEmpty {
                    self.isInSendProgressMode = false
                    self.finishingSuccessfulUpload = true
                    self.shareItemController.removeAllItems()
                    self.finishingSuccessfulUpload = false
                    MediaUploadHaptics.uploadSucceeded()
                    self.releaseUploadRetention()
                    self.delegate?.shareConfirmationViewControllerDidFinish(self)
                } else if self.composeDismissedForUpload {
                    // Compose sheet already gone — surface the error on the chat host.
                    self.isInSendProgressMode = false
                    MediaUploadHaptics.uploadFailed()
                    self.presentRecordedUploadFailures()
                    self.releaseUploadRetention()
                } else {
                    // Keep failed items and restore compose so the user can retry or Cancel out.
                    self.shareItemController.remove(self.uploadSuccess)
                    self.exitSendProgressMode()
                    self.updateCompressionOptionsUI()
                    MediaUploadHaptics.uploadFailed()
                    self.presentRecordedUploadFailures()
                }

                bgTask.stopBackgroundTask()
            }
            self.runWhenComposeDismissSettled(settle)
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
                            let technical = verifyError ?? "empty remote file bytes=\(remoteBytes)"
                            MediaUploadTrace.log("UPLOAD FAIL \(uploadName) PROPFIND \(technical)")
                            NCLog.log("Media upload: PROPFIND rejected \(uploadName) — \(technical)")
                            self.recordUploadError(fileName: uploadName, technical: technical)
                            self.markAlbumSlotUploadFailed(for: item)
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
                        self.enqueueAlbumPost(filePath: filePath, draftFolderPath: draftFolderPath, item: item)
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
                            self.recordUploadError(code: nkError.errorCode, fileName: uploadName, technical: nkError.errorDescription)
                            self.markAlbumSlotUploadFailed(for: item)
                            self.uploadGroup.leave()
                        }
                    }
                } else {
                    MediaUploadTrace.log("UPLOAD FAIL \(uploadName) code=\(nkError.errorCode) \(nkError.errorDescription)")
                    NCLog.log(String(format: "Failed to upload file. Error: %@", nkError.errorDescription))
                    self.recordUploadError(code: nkError.errorCode, fileName: uploadName, technical: nkError.errorDescription)
                    self.markAlbumSlotUploadFailed(for: item)
                    self.uploadGroup.leave()
                }
            }
        }
    }

    private func markAlbumSlotUploadFailed(for item: ShareItem) {
        guard let session = self.albumShareSession,
              let index = session.slotIndex(for: item)
        else { return }
        session.slots[index].uploadFailed = true
        // Skip this slot and later attaches so caption/order stay coherent.
        session.markAbort(from: index)
        self.drainAlbumPosts()
    }

    /// Mark upload ready and post in index order (never attach out of order).
    private func enqueueAlbumPost(filePath: String, draftFolderPath: String?, item: ShareItem) {
        if self.mediaFlowCancelled {
            MediaUploadTrace.log("UPLOAD abort post \(item.fileName ?? "?") (cancelled)")
            self.uploadGroup.leave()
            return
        }

        guard let session = self.albumShareSession,
              let index = session.slotIndex(for: item)
        else {
            // Fallback: post immediately (should not happen for normal send path).
            self.postUploadedFileToRoom(filePath: filePath, draftFolderPath: draftFolderPath, item: item, referenceId: nil) { _ in
                self.uploadGroup.leave()
            }
            return
        }

        session.slots[index].filePath = filePath
        session.slots[index].draftFolderPath = draftFolderPath
        session.slots[index].uploadReady = true
        NCLog.log("Media upload: PUT ready for attach index=\(index + 1)/\(session.slots.count) \(item.fileName ?? "file")")
        self.drainAlbumPosts()
    }

    private func drainAlbumPosts() {
        guard let session = self.albumShareSession, !session.isPosting else { return }

        while session.nextPostIndex < session.slots.count {
            if self.mediaFlowCancelled {
                // Leave every remaining entered upload that is waiting on attach.
                for index in session.nextPostIndex..<session.slots.count where session.slots[index].uploadReady && !session.slots[index].posted {
                    session.slots[index].posted = true
                    self.uploadGroup.leave()
                }
                return
            }

            let index = session.nextPostIndex
            var slot = session.slots[index]

            // PUT already failed — enter/leave handled by upload path; advance drain.
            if slot.uploadFailed {
                session.nextPostIndex += 1
                continue
            }

            if let abortFrom = session.abortFromIndex, index >= abortFrom {
                if slot.uploadReady && !slot.posted {
                    NCLog.log("Media upload: skipping attach for \(slot.item.fileName ?? "file") (album aborted)")
                    self.uploadErrors.append(String.localizedStringWithFormat(
                        NSLocalizedString("“%@” was not shared because an earlier file failed.", comment: "Album attach aborted after prior failure"),
                        slot.item.fileName ?? "file"
                    ))
                    slot.posted = true
                    session.slots[index] = slot
                    session.nextPostIndex += 1
                    self.uploadGroup.leave()
                    continue
                }
                // Still uploading — wait until PUT finishes, then skip.
                return
            }

            guard slot.uploadReady, !slot.posted else { return }

            session.isPosting = true
            let referenceId = slot.referenceId
            let filePath = slot.filePath ?? ""
            let draftFolderPath = slot.draftFolderPath
            let item = slot.item

            NCLog.log("Media upload: attaching index=\(index + 1)/\(session.slots.count) ref=\(referenceId ?? "nil") \(item.fileName ?? "file")")
            self.postUploadedFileToRoom(filePath: filePath, draftFolderPath: draftFolderPath, item: item, referenceId: referenceId) { success in
                session.isPosting = false
                session.slots[index].posted = true
                session.nextPostIndex += 1
                if !success {
                    session.markAbort(from: index + 1)
                }
                self.uploadGroup.leave()
                self.drainAlbumPosts()
            }
            return
        }
    }

    private func postUploadedFileToRoom(filePath: String,
                                        draftFolderPath: String?,
                                        item: ShareItem,
                                        referenceId: String?,
                                        completion: @escaping (_ success: Bool) -> Void) {
        if self.mediaFlowCancelled {
            MediaUploadTrace.log("UPLOAD abort post \(item.fileName ?? "?") (cancelled)")
            completion(false)
            return
        }

        var talkMetaData: [String: Any] = [:]

        let itemCaption = item.caption.trimmingCharacters(in: .whitespacesAndNewlines)

        // Album: only the last member notifies (1 push for N files). Earlier members are silent.
        // Requires media-caption on the server (same capability as talkMetaData.silent).
        let albumRef = SumbaMediaAlbum.parse(referenceId)
        let silentAlbumMember = albumRef.map { !$0.isLastMember } ?? false
        let silent = self.shareSilently || silentAlbumMember
        if silent {
            talkMetaData["silent"] = true
        }

        // Last album member: store push-ready caption (`Yo (3 media files)`) so the server
        // notification body is correct without relying on the NSE. Chat strips the suffix.
        if let albumRef, albumRef.isLastMember {
            let body = SumbaMediaAlbumReference.notificationBody(count: albumRef.count, caption: itemCaption.isEmpty ? nil : itemCaption)
            talkMetaData["caption"] = body
            NCLog.log("Media upload: album attach \(albumRef.index)/\(albumRef.count) silent=\(silent) pushCaption=\(body.debugDescription) \(item.fileName ?? "file")")
        } else if !itemCaption.isEmpty {
            talkMetaData["caption"] = itemCaption
            if let albumRef {
                NCLog.log("Media upload: album attach \(albumRef.index)/\(albumRef.count) silent=\(silent) (albumMember=\(silentAlbumMember) shareSilent=\(self.shareSilently)) \(item.fileName ?? "file")")
            }
        } else if let albumRef {
            NCLog.log("Media upload: album attach \(albumRef.index)/\(albumRef.count) silent=\(silent) (albumMember=\(silentAlbumMember) shareSilent=\(self.shareSilently)) \(item.fileName ?? "file")")
        } else if silent {
            NCLog.log("Media upload: attach silent=\(silent) \(item.fileName ?? "file")")
        }

        if let thread = self.thread {
            talkMetaData["threadId"] = thread.threadId
        }

        if let draftFolderPath {
            NCAPIController.sharedInstance().postConversationAttachment(inRoom: self.room.token,
                                                                        filePath: draftFolderPath,
                                                                        fileName: item.fileName,
                                                                        referenceId: referenceId,
                                                                        talkMetaData: talkMetaData,
                                                                        forAccount: self.account) { error in
                if self.mediaFlowCancelled {
                    // Request may already have reached the server; do not count as local success.
                    MediaUploadTrace.log("UPLOAD abort post-callback \(item.fileName ?? "?") (cancelled)")
                    completion(false)
                    return
                }
                if let error {
                    NCLog.log("Failed to post attachment. Error: \(error.localizedDescription)")
                    self.recordUploadError(fileName: item.fileName, technical: error.localizedDescription)
                    completion(false)
                } else {
                    NCLog.log("Media upload: posted attachment \(item.fileName ?? "file") to room \(self.room.token ?? "?") ref=\(referenceId ?? "nil")")
                    self.uploadSuccess.append(item)
                    completion(true)
                }
            }
        } else {
            NCAPIController.sharedInstance().shareFileOrFolder(forAccount: self.account,
                                                               atPath: filePath,
                                                               toRoom: self.room.token,
                                                               withTalkMetaData: talkMetaData,
                                                               withReferenceId: referenceId) { error in
                if self.mediaFlowCancelled {
                    MediaUploadTrace.log("UPLOAD abort share-callback \(item.fileName ?? "?") (cancelled)")
                    completion(false)
                    return
                }
                if let error {
                    NCLog.log(String(format: "Failed to share file. Error: %@", error.localizedDescription))
                    self.recordUploadError(fileName: item.fileName, technical: error.localizedDescription)
                    completion(false)
                } else {
                    NCLog.log("Media upload: shared \(item.fileName ?? "file") to room \(self.room.token ?? "?") ref=\(referenceId ?? "nil")")
                    self.uploadSuccess.append(item)
                    completion(true)
                }
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
        // Sequential staging briefly has count==1 then count==N; dimming trash for that window
        // reads as a blink when the first preview appears. Keep trash at full opacity always —
        // `removeItemButtonPressed` already no-ops when only one item remains.
        UIView.performWithoutAnimation {
            self.removeItemButton.tintColor = .label
            self.removeItemButton.alpha = 1.0
            self.removeItemButton.isUserInteractionEnabled = true
        }

        // Freeze crop/add chrome while providers are still streaming in — flipping canCrop as
        // each file becomes an image also flickers those icons.
        if self.shareItemController.isBusyLoadingMedia {
            return
        }

        let itemCount = self.shareItemController.shareItems.count
        let canAdd = itemCount < 20
        let canCrop = self.getCurrentShareItem()?.isImage == true
        if let last = lastToolbarChrome,
           last.canAdd == canAdd,
           last.canCrop == canCrop {
            return
        }
        lastToolbarChrome = (canAdd: canAdd, canCrop: canCrop)

        // Dim via alpha only — never UIControl.isEnabled (iOS 26 glass makes icons vanish).
        UIView.performWithoutAnimation {
            self.cropItemButton.tintColor = .label
            self.cropItemButton.alpha = canCrop ? 1.0 : 0.35
            self.cropItemButton.isUserInteractionEnabled = canCrop

            self.addItemButton.tintColor = .label
            self.addItemButton.alpha = canAdd ? 1.0 : 0.35
            self.addItemButton.isUserInteractionEnabled = canAdd
        }
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
                // Apply crop/add enablement that was frozen while providers streamed in.
                self.lastToolbarChrome = nil
                self.updateToolbarForCurrentItem()
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
            // Centered "Loading media…" (not the branded Send card).
            self.showProgressAlert(phase: .loadingMedia, progress: nil, indeterminate: true)
        } else if self.progressAlert != nil, !self.isInSendProgressMode {
            // Load/staging finished — dismiss whether or not items appeared.
            // Also clears a warm-extension leftover if somehow still attached.
            self.hideProgressAlert(animated: true)
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
