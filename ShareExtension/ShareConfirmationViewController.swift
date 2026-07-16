//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NextcloudKit
import QuickLook
import SwiftyAttributes
import TOCropViewController
import AVFoundation
import MBProgressHUD

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

        return controller
    }()

    // MARK: - Private var

    private var serverCapabilities: ServerCapabilities
    private var shareType: ShareConfirmationType = .item
    private var shareContentView = UIView()
    private var shareSilently = false
    private var imagePicker: UIImagePickerController?
    private var hud: MBProgressHUD?
    private var objectShareMessage: NCChatMessage?
    private var uploadGroup = DispatchGroup()
    private var uploadFailed = false
    private var uploadErrors: [String] = []
    private var uploadSuccess: [ShareItem] = []
    private var chosenCompressionLevel: MediaUploadCompressionLevel = .moderate
    private var isPreparingForUpload = false
    /// Bumps whenever share items change so stale background size estimates are ignored.
    private var compressionEstimateGeneration: UInt = 0
    /// After a successful upload we clear staged items; don't treat that as user cancel in the share extension.
    private var finishingSuccessfulUpload = false
    /// Share of the annular ring reserved for compression prepare (often longer than upload).
    private let prepareProgressShare: Float = 0.55

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
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for level in [MediaUploadCompressionLevel.none, .moderate, .high] {
            let button = UIButton(type: .system)
            button.tag = level.rawValue
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.layer.cornerRadius = 10
            button.layer.borderWidth = 1
            button.addTarget(self, action: #selector(compressionOptionPressed(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        return stack
    }()

    private lazy var compressionTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = NSLocalizedString("Compression settings", comment: "").uppercased(with: .current)
        let footnoteSize = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        label.font = .systemFont(ofSize: footnoteSize, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var compressionSectionView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [self.compressionTitleLabel, self.compressionOptionsView])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
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

        // iOS 26 floating toolbar buttons hang below the toolbar's layout frame; keep clear space.
        let compressionTopSpacing: CGFloat = {
            if #available(iOS 26, *) {
                return 28
            }
            return 12
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

        if self.shareType == .text {
            // When we are sharing a text, we want to start editing right away
            self.shareTextView.becomeFirstResponder()
        }
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if self.shareType == .text {
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
        // Allow sending media without caption text, but not while preparation is running.
        return !self.shareItemController.shareItems.isEmpty
            && self.shareItemController.preparingItemCount == 0
            && !self.isPreparingForUpload
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
        self.chosenCompressionLevel = level
        self.updateCompressionOptionsUI()
    }

    func cancelButtonPressed() {
        self.delegate?.shareConfirmationViewControllerDidCancel(self)
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
        guard !self.isPreparingForUpload else { return }

        let mode = self.mediaUploadMode
        let mediaCount = self.shareItemController.shareItems.count
        NCLog.log("Media upload Send: mode=\(mode.rawValue) items=\(mediaCount)")

        if mode == .noCompression {
            NCLog.log("Media upload: skipping compression (No Compression)")
            self.startAnimatingSharingIndicator()
            self.showProgressHUD(phase: .uploading(count: mediaCount), progress: 0, overMedia: true)
            self.uploadAndShareFiles()
            return
        }

        self.isPreparingForUpload = true
        self.textView.resignFirstResponder()
        self.startAnimatingSharingIndicator()
        self.showProgressHUD(phase: .preparing, progress: 0, overMedia: true)
        NCLog.log("Media upload: preparing \(mediaCount) item(s) for compression")

        let chosenLevel = self.chosenCompressionLevel
        self.shareItemController.prepareItemsForUpload(levelProvider: { item in
            switch mode {
            case .noCompression:
                return MediaUploadCompressionLevel.none.rawValue
            case .chooseOnUpload:
                return chosenLevel.rawValue
            case .automatic:
                guard let fileURL = item.fileURL else {
                    return MediaUploadCompressionLevel.moderate.rawValue
                }
                let extensionName = fileURL.pathExtension.lowercased()
                let isMedia = item.isImage || MediaUploadPreprocessor.isVideo(fileExtension: extensionName)
                if !isMedia {
                    return MediaUploadCompressionLevel.none.rawValue
                }
                return MediaUploadAutomaticPolicy.compressionLevel(forFileURL: fileURL).rawValue
            @unknown default:
                return MediaUploadCompressionLevel.moderate.rawValue
            }
        }, progress: { [weak self] fraction in
            guard let self else { return }
            self.hud?.progress = fraction * self.prepareProgressShare
            self.applyUploadProgressColors(to: self.hud)
        }, completion: { [weak self] in
            guard let self else { return }
            self.isPreparingForUpload = false
            NCLog.log("Media upload: prepare finished, starting upload of \(self.shareItemController.shareItems.count) item(s)")
            self.hud?.progress = self.prepareProgressShare
            self.showProgressHUD(phase: .uploading(count: self.shareItemController.shareItems.count),
                                 progress: self.prepareProgressShare,
                                 overMedia: true)
            self.uploadAndShareFiles()
        })
    }

    private func title(for level: MediaUploadCompressionLevel) -> String {
        switch level {
        case .none:
            return NSLocalizedString("None", comment: "No media compression")
        case .moderate:
            return NSLocalizedString("Moderate", comment: "Moderate media compression")
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
        // Wait until at least one item is staged so we don't overlap the toolbar with empty Zero KB chips.
        let showQuality = self.mediaUploadMode == .chooseOnUpload
            && self.shareType == .item
            && !self.shareItemController.shareItems.isEmpty

        self.compressionSectionView.isHidden = !showQuality
        self.compressionSectionHeightConstraint?.constant = showQuality ? 82 : 0

        guard showQuality else {
            self.view.layoutIfNeeded()
            return
        }

        // Show cheap on-disk sizes immediately (None). Moderate/High placeholders stay honest-ish
        // from file size until the background estimate finishes — never JPEG-encode on the main
        // thread while multi-select is still staging (that jetsams on iOS 18).
        let items = self.shareItemController.shareItems
        var originalTotal: Int64 = 0
        for item in items {
            guard let fileURL = item.fileURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            originalTotal += size.int64Value
        }
        let placeholder: [MediaUploadCompressionLevel: Int64] = [
            .none: originalTotal,
            .moderate: max(12_288, Int64(Double(originalTotal) * 0.62)),
            .high: max(12_288, Int64(Double(originalTotal) * 0.22))
        ]
        self.applyCompressionChipTitles(estimates: placeholder)

        self.compressionEstimateGeneration &+= 1
        let generation = self.compressionEstimateGeneration
        let urlsAndFlags: [(URL, Bool)] = items.compactMap { item in
            guard let url = item.fileURL else { return nil }
            return (url, item.isImage)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var totals: [MediaUploadCompressionLevel: Int64] = [.none: 0, .moderate: 0, .high: 0]
            for (fileURL, isImage) in urlsAndFlags {
                let counts = MediaUploadPreprocessor.estimatedByteCounts(at: fileURL, treatAsImage: isImage)
                totals[.none, default: 0] += counts.none
                totals[.moderate, default: 0] += counts.moderate
                totals[.high, default: 0] += counts.high
            }
            DispatchQueue.main.async {
                guard generation == self.compressionEstimateGeneration else { return }
                self.applyCompressionChipTitles(estimates: totals)
            }
        }

        self.view.layoutIfNeeded()
    }

    private func applyCompressionChipTitles(estimates: [MediaUploadCompressionLevel: Int64]) {
        let elementColor = NCAppBranding.elementColor()
        for case let button as UIButton in self.compressionOptionsView.arrangedSubviews {
            guard let level = MediaUploadCompressionLevel(rawValue: button.tag) else { continue }
            let estimated = estimates[level] ?? 0
            let title = "\(self.title(for: level))\n\(self.sizeLabel(for: level, estimated: estimated))"
            button.setTitle(title, for: .normal)

            let selected = level == self.chosenCompressionLevel
            button.backgroundColor = selected ? elementColor.withAlphaComponent(0.15) : .secondarySystemBackground
            button.layer.borderColor = (selected ? elementColor : UIColor.separator).cgColor
            button.setTitleColor(selected ? elementColor : .label, for: .normal)
        }
    }

    private func configureCompressionUI() {
        MediaUploadAutomaticPolicy.startMonitoringIfNeeded()
        self.updateCompressionOptionsUI()
    }

    private enum UploadHUDPhase {
        case preparing
        case uploading(count: Int)

        var title: String {
            switch self {
            case .preparing:
                return NSLocalizedString("Preparing…", comment: "Shown while media is compressed before upload")
            case .uploading:
                return NSLocalizedString("Uploading", comment: "Upload progress title; details show file count")
            }
        }

        var details: String {
            switch self {
            case .preparing:
                // Keep a second line so label Y matches the Uploading phase.
                return "\u{00a0}"
            case .uploading(let count):
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

    private func styleStagingHUD(_ hud: MBProgressHUD) {
        hud.bezelView.style = .solidColor
        hud.bezelView.color = .clear
        hud.bezelView.layer.borderWidth = 0
        hud.bezelView.layer.shadowOpacity = 0
        hud.backgroundView.color = .clear
        hud.backgroundView.style = .solidColor
        hud.isSquare = false
        hud.minSize = .zero
        hud.contentColor = .label
        hud.label.textColor = .label
        hud.detailsLabel.textColor = .secondaryLabel
        hud.detailsLabel.text = nil
        hud.removeFromSuperViewOnHide = true
    }

    private func styleUploadHUD(_ hud: MBProgressHUD) {
        hud.bezelView.style = .solidColor
        hud.bezelView.color = .systemBackground
        // Default MBProgressHUD margin is 20. Prior value was 30; add more inset
        // (+10 horizontal / +20 vertical intent — single margin uses the larger vertical bump).
        hud.margin = 50
        hud.isSquare = true
        hud.minSize = CGSize(width: 150, height: 150)
        hud.bezelView.layer.cornerRadius = 14
        // Allow shadow to render outside the bezel; solid fill still covers content.
        hud.bezelView.clipsToBounds = false
        hud.bezelView.layer.masksToBounds = false
        hud.bezelView.layer.borderWidth = 1
        hud.bezelView.layer.borderColor = UIColor.separator.cgColor
        hud.bezelView.layer.shadowColor = UIColor.black.cgColor
        hud.bezelView.layer.shadowOpacity = 0.18
        hud.bezelView.layer.shadowRadius = 14
        hud.bezelView.layer.shadowOffset = CGSize(width: 0, height: 6)
        hud.contentColor = .label
        hud.label.textColor = .label
        hud.detailsLabel.textColor = .secondaryLabel
        hud.detailsLabel.numberOfLines = 1
        hud.removeFromSuperViewOnHide = true
    }

    private func applyUploadProgressColors(to hud: MBProgressHUD?) {
        guard let hud else { return }
        let completed = NCAppBranding.elementColor()
        let remaining = UIColor.tertiarySystemFill

        for subview in hud.bezelView.subviews {
            guard let progressView = subview as? MBRoundProgressView else { continue }
            progressView.progressTintColor = completed
            progressView.backgroundTintColor = remaining
            progressView.setNeedsDisplay()
        }
    }

    private func thickenAnnularStroke(in hud: MBProgressHUD) {
        func bumpLineWidth(in layer: CALayer) {
            if let shape = layer as? CAShapeLayer, shape.fillColor == nil || shape.fillColor == UIColor.clear.cgColor {
                shape.lineWidth = max(shape.lineWidth, 3) + 1
            }
            layer.sublayers?.forEach { bumpLineWidth(in: $0) }
        }
        bumpLineWidth(in: hud.bezelView.layer)
    }

    /// - Parameter overMedia: Pin the HUD to the media preview so upload progress is centered on the image/video.
    private func showProgressHUD(phase: UploadHUDPhase, progress: Float?, indeterminate: Bool = false, overMedia: Bool = false) {
        let hostView: UIView = overMedia ? self.shareCollectionView : self.view

        if let existing = self.hud, existing.superview !== hostView {
            existing.hide(animated: false)
            self.hud = nil
        }

        let hud: MBProgressHUD
        if let existing = self.hud {
            hud = existing
        } else {
            hud = MBProgressHUD.showAdded(to: hostView, animated: true)
            self.hud = hud
        }

        if indeterminate {
            self.styleStagingHUD(hud)
            hud.mode = .indeterminate
            hud.label.text = phase.title
            hud.detailsLabel.text = nil
        } else {
            self.styleUploadHUD(hud)
            hud.mode = .annularDeterminate
            if let progress {
                hud.progress = progress
            }
            hud.label.text = phase.title
            hud.detailsLabel.text = phase.details
            // Progress view is created when mode is set; color it after layout.
            DispatchQueue.main.async {
                self.applyUploadProgressColors(to: hud)
                self.thickenAnnularStroke(in: hud)
            }
        }
    }

    private func hideProgressHUD() {
        self.hud?.hide(animated: true)
        self.hud = nil
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
        guard let hud = self.hud else { return }

        DispatchQueue.main.async {
            var progress: CGFloat = 0.0
            var items = 0

            for shareItem in self.shareItemController.shareItems {
                progress += shareItem.uploadProgress
                items += 1
            }

            let uploadFraction = items > 0 ? Float(progress / CGFloat(items)) : 0
            let prepareShare = self.mediaUploadMode == .noCompression ? 0 : self.prepareProgressShare
            hud.progress = prepareShare + (1 - prepareShare) * uploadFraction
        }
    }

    func uploadAndShareFiles() {
        // TODO: This has no effect on ShareExtension
        let bgTask = BGTaskHelper.startBackgroundTask(withName: "uploadAndShareFiles")

        NCLog.log("Media upload: uploadAndShareFiles started (\(self.shareItemController.shareItems.count) item(s))")

        // Hide keyboard before upload to correctly display the HUD
        self.textView.resignFirstResponder()

        NCIntentController.sharedInstance().donateSendMessageIntent(for: self.room)

        let count = self.shareItemController.shareItems.count
        let prepareShare = self.mediaUploadMode == .noCompression ? Float(0) : self.prepareProgressShare
        self.showProgressHUD(phase: .uploading(count: count), progress: prepareShare, overMedia: true)

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
                if let error {
                    NCLog.log("Probe conversation attachment folder failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.stopAnimatingSharingIndicator()
                        self.hideProgressHUD()
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
            self.stopAnimatingSharingIndicator()
            self.hideProgressHUD()

            // TODO: Do error reporting per item
            if self.uploadErrors.isEmpty {
                self.finishingSuccessfulUpload = true
                self.shareItemController.removeAllItems()
                self.finishingSuccessfulUpload = false
                self.delegate?.shareConfirmationViewControllerDidFinish(self)
            } else {
                // We remove the successfully uploaded items, so only the failed ones are kept
                self.shareItemController.remove(self.uploadSuccess)

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
        NextcloudKit.shared.upload(serverUrlFileName: fileServerURL, fileNameLocalPath: item.filePath) { _ in
            NCLog.log("Media upload: upload task created for \(item.fileName)")
        } progressHandler: { progress in
            item.uploadProgress = progress.fractionCompleted
            self.updateHudProgress()
        } completionHandler: { _, _, _, _, _, _, nkError in
            if nkError.errorCode == 0 {
                NCLog.log("Media upload: \(item.fileName) PUT completed, verifying remote size at \(fileServerURL)")
                NCAPIController.sharedInstance().verifyUploadedFileSize(atServerURL: fileServerURL,
                                                                          minimumBytes: 1,
                                                                          forAccount: self.account) { verified, remoteBytes, verifyError in
                    guard verified else {
                        let reason = verifyError ?? String.localizedStringWithFormat(
                            NSLocalizedString("Server stored “%@” as empty (%lld bytes).", comment: "Upload rejected after PROPFIND shows 0 bytes"),
                            item.fileName,
                            remoteBytes
                        )
                        NCLog.log("Media upload: PROPFIND rejected \(item.fileName) — \(reason)")
                        self.uploadErrors.append(reason)
                        self.uploadGroup.leave()
                        return
                    }

                    NCLog.log("Media upload: \(item.fileName) verified on server (\(remoteBytes) bytes)")
                    self.postUploadedFileToRoom(filePath: filePath, draftFolderPath: draftFolderPath, item: item)
                }
            } else if nkError.errorCode == 404 || nkError.errorCode == 409 {
                NCAPIController.sharedInstance().checkOrCreateAttachmentFolder(forAccount: self.account) { created, _ in
                    if created {
                        self.uploadFile(to: fileServerURL, with: filePath, draftFolderPath: nil, with: item)
                    } else {
                        self.uploadErrors.append(nkError.errorDescription)
                        self.uploadGroup.leave()
                    }
                }
            } else {
                NCLog.log(String(format: "Failed to upload file. Error: %@", nkError.errorDescription))
                self.uploadErrors.append(nkError.errorDescription)
                self.uploadGroup.leave()
            }
        }
    }

    private func postUploadedFileToRoom(filePath: String, draftFolderPath: String?, item: ShareItem) {
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
                    self.collectionViewScrollToEnd()
                }
            }
        } else if mediaType == "public.movie" {
            if let videoUrl = info[.mediaURL] as? URL {
                self.dismiss(animated: true) {
                    self.shareItemController.addItem(with: videoUrl)
                    self.collectionViewScrollToEnd()
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

        self.collectionViewScrollToEnd()
    }

    // MARK: - ScrollView/CollectionView

    public override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: kShareConfirmationCellIdentifier, for: indexPath) as? ShareConfirmationCollectionViewCell
        else { return UICollectionViewCell() }

        let item = self.shareItemController.shareItems[indexPath.row]

        // Setting placeholder here in case we can't generate any other preview
        cell.setPlaceHolderImage(item.placeholderImage)
        cell.setPlaceHolderText(item.fileName)

        let extensionName = item.fileURL?.pathExtension.lowercased() ?? ""
        let isVideo = MediaUploadPreprocessor.isVideo(fileExtension: extensionName)
        cell.setShowsVideoIndicator(isVideo)

        if let fileURL = item.fileURL, NCUtils.isImage(fileExtension: fileURL.pathExtension),
           let image = self.shareItemController.getImageFrom(item) {
            // We're able to get an image directly from the fileURL -> use it
            cell.setPreviewImage(image)
        } else {
            self.generatePreview(for: cell, with: collectionView, with: item)
        }

        return cell
    }

    func generatePreview(for cell: ShareConfirmationCollectionViewCell, with collectionView: UICollectionView, with item: ShareItem) {
        let size = CGSize(width: collectionView.bounds.width, height: collectionView.bounds.height)
        let scale = self.view.window?.screen.scale ?? UIScreen.main.scale

        // updateHandler might be called multiple times, starting from low quality representation to high-quality
        let request = QLThumbnailGenerator.Request(fileAt: item.fileURL, size: size, scale: scale, representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, _, error in
            guard error == nil, let thumbnail else { return }

            DispatchQueue.main.async {
                cell.setPreviewImage(thumbnail.uiImage)
            }
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

    func collectionViewScrollToEnd() {
        if let item = self.shareItemController.shareItems.last {
            self.scroll(to: item, animated: true)
        }
    }

    func scroll(to item: ShareItem, animated: Bool) {
        DispatchQueue.main.async {
            if let indexForItem = self.shareItemController.shareItems.firstIndex(of: item) {
                let indexPath = IndexPath(row: indexForItem, section: 0)

                self.shareCollectionView.scrollToItem(at: indexPath, at: [], animated: animated)
            }
        }
    }

    func getCurrentShareItem() -> ShareItem? {
        let currentIndex = Int(self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.size.width)

        if currentIndex >= self.shareItemController.shareItems.count {
            return nil
        }

        return self.shareItemController.shareItems[currentIndex]
    }

    // MARK: - PageControl

    func pageControlValueChanged() {
        let indexPath = IndexPath(row: self.pageControl.currentPage, section: 0)
        self.shareCollectionView.scrollToItem(at: indexPath, at: [], animated: true)
    }

    func updatePageControlPage() {
        // see: https://stackoverflow.com/a/46181277/2512312
        DispatchQueue.main.async {
            self.pageControl.currentPage = Int(self.shareCollectionView.contentOffset.x / self.shareCollectionView.frame.width)
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

    public func shareItemControllerItemsChanged(_ shareItemController: ShareItemController) {
        DispatchQueue.main.async {
            if shareItemController.shareItems.isEmpty && shareItemController.preparingItemCount == 0 {
                if self.finishingSuccessfulUpload {
                    return
                }
                if let extensionContext = self.extensionContext {
                    let error = NSError(domain: NSCocoaErrorDomain, code: 0)
                    extensionContext.cancelRequest(withError: error)
                } else {
                    self.dismiss(animated: true)
                }
            } else if !shareItemController.shareItems.isEmpty {
                self.shareCollectionView.reloadData()

                // Make sure all changes are fully populated before we update our UI elements
                self.shareCollectionView.layoutIfNeeded()
                self.updateToolbarForCurrentItem()
                self.updateCompressionOptionsUI()
                self.pageControl.numberOfPages = shareItemController.shareItems.count
                self.collectionViewScrollToEnd()

                // Update the text input to check if sending is (not-)possible
                self.textDidUpdate(false)
                self.updateSendButtonEnabledState()
            }

            self.updateStagingProgressHUD()
        }
    }

    public func shareItemControllerPreparingItemsChanged(_ shareItemController: ShareItemController) {
        DispatchQueue.main.async {
            self.updateStagingProgressHUD()
            self.updateSendButtonEnabledState()
            self.textDidUpdate(false)
        }
    }

    /// Progress while copying/staging media into the sheet (before Send).
    private func updateStagingProgressHUD() {
        if self.isPreparingForUpload {
            // Send-path prepare uses the combined annular HUD already shown by prepareMediaThenUpload.
            self.updateSendButtonEnabledState()
            return
        }

        if self.shareItemController.preparingItemCount > 0 {
            self.showProgressHUD(phase: .preparing,
                                 progress: nil,
                                 indeterminate: true,
                                 overMedia: false)
        } else if self.hud?.mode == .indeterminate {
            // Staging finished — dismiss the load spinner whether or not items appeared.
            self.hideProgressHUD()
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
