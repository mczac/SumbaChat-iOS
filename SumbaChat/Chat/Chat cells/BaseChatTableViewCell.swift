//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import MapKit
import SwiftyGif
import SDWebImage

protocol BaseChatTableViewCellDelegate: AnyObject {

    func cellWantsToScroll(to message: NCChatMessage)
    func cellWantsToReply(to message: NCChatMessage)
    func cellDidSelectedReaction(_ reaction: NCChatReaction!, for message: NCChatMessage)

    func cellWants(toDownloadFile fileParameter: NCMessageFileParameter, for message: NCChatMessage)
    func cellHasDownloadedImagePreview(withSize size: CGSize, for message: NCChatMessage)

    func cellWants(toOpenLocation geoLocationRichObject: GeoLocationRichObject)

    func cellWants(toPlayAudioFile message: NCChatMessage)
    func cellWants(toPauseAudioFile fileParameter: NCMessageFileParameter)
    func cellWants(toChangeProgress progress: CGFloat, fromAudioFile fileParameter: NCMessageFileParameter)

    func cellWants(toOpenPoll poll: NCMessageParameter)

    func cellWants(toShowThread message: NCChatMessage)
}

// Common elements
public let chatMessageCellPreviewCornerRadius = 4.0
public let chatMessageCellAvatarHeight = 30.0

// Message cell
public let chatMessageCellIdentifier = "chatMessageCellIdentifier"
public let chatGroupedMessageCellIdentifier = "chatGroupedMessageCellIdentifier"
public let chatReplyMessageCellIdentifier = "chatReplyMessageCellIdentifier"
public let chatMessageCellMinimumHeight = 45.0
public let chatGroupedMessageCellMinimumHeight = 25.0

// File cell
public let fileMessageCellIdentifier = "fileMessageCellIdentifier"
public let fileGroupedMessageCellIdentifier = "fileGroupedMessageCellIdentifier"
public let fileMessageCellMinimumHeight = 50.0
public let fileMessageCellFileMaxPreviewHeight = 120.0
public let fileMessageCellFileMaxPreviewWidth = 230.0
public let fileMessageCellMediaFilePreviewHeight = 230.0
public let fileMessageCellMediaFileMaxPreviewWidth = 230.0
public let fileMessageCellVideoPlayIconSize = 48.0

// Location cell
public let locationMessageCellIdentifier = "locationMessageCellIdentifier"
public let locationGroupedMessageCellIdentifier = "locationGroupedMessageCellIdentifier"
public let locationMessageCellMinimumHeight = 50.0
public let locationMessageCellPreviewHeight = 120.0
public let locationMessageCellPreviewWidth = 240.0

// Voice message cell
public let voiceMessageCellIdentifier = "voiceMessageCellIdentifier"
public let voiceGroupedMessageCellIdentifier = "voiceGroupedMessageCellIdentifier"
public let voiceMessageCellPlayerHeight = 52.0
public let voiceMessageCellPlayerWidth = 450.0

// Poll cell
public let pollMessageCellIdentifier = "pollMessageCellIdentifier"
public let pollGroupedMessageCellIdentifier = "pollGroupedMessageCellIdentifier"

class BaseChatTableViewCell: UITableViewCell, AudioPlayerViewDelegate, ReactionsViewDelegate {

    // TODO: Reset cache when theming changes
    static var bubbleColorCache = NSCache<NSString, UIColor>()

    public weak var delegate: BaseChatTableViewCellDelegate?

    @IBOutlet weak var avatarButton: AvatarButton!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var dateLabel: UILabel!
    @IBOutlet weak var statusView: UIStackView!
    @IBOutlet weak var messageBodyView: UIView!

    @IBOutlet weak var reactionStackView: UIStackView!

    @IBOutlet weak var headerPart: UIView!
    @IBOutlet weak var subheaderPart: UIView!
    @IBOutlet weak var quotePart: UIView!
    @IBOutlet weak var referencePart: UIView!
    @IBOutlet weak var reactionPart: UIView!
    @IBOutlet weak var footerPart: UIView!

    @IBOutlet weak var bubbleView: UIView!
    @IBOutlet weak var bubbleStackView: UIStackView!

    // Since we use different relations depending on the bubble (other user or app user) we setup
    // the constraints programmatically instead of in interface builder
    lazy var leftBubbleConstraints = {
        return [
            bubbleStackView.leadingAnchor.constraint(equalTo: avatarButton.trailingAnchor, constant: 10),
            bubbleStackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -64),

            titleLabel.leadingAnchor.constraint(equalTo: headerPart.leadingAnchor, constant: 0),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerPart.trailingAnchor, constant: 0)
        ]
    }()

    lazy var rightBubbleConstraints = {
        return [
            bubbleStackView.leadingAnchor.constraint(greaterThanOrEqualTo: avatarButton.trailingAnchor, constant: 40),
            bubbleStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),

            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: headerPart.leadingAnchor, constant: 0),
            titleLabel.trailingAnchor.constraint(equalTo: headerPart.trailingAnchor, constant: 0)
        ]
    }()

    lazy var threadRepliesButton: NCButton = {
        let button = NCButton()
        button.setButtonStyle(style: .tertiary)
        button.tintColor = .label
        button.configuration?.image = UIImage(systemName: "arrowshape.turn.up.left")
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
        button.configuration?.imagePadding = 4

        self.reactionStackView.insertArrangedSubview(button, at: 0)

        return button
    }()

    public var message: NCChatMessage?
    public var room: NCRoom?
    public var account: TalkAccount?

    internal var threadTitleLabel: UILabel?
    internal var quotedMessageView: QuotedMessageView?
    internal var reactionView: ReactionsView?
    internal var referenceView: ReferenceView?

    internal var replyGestureRecognizer: DRCellSlideGestureRecognizer?

    // Message cell
    internal var messageTextView: MessageBodyTextView?

    // File cell
    internal var filePreviewImageView: UIImageView?
    internal var filePreviewImageViewHeightConstraint: NSLayoutConstraint?
    internal var filePreviewImageViewWidthConstraint: NSLayoutConstraint?
    internal var fileActivityIndicator: MDCActivityIndicator?
    internal var filePreviewActivityIndicator: MDCActivityIndicator?
    internal var filePreviewPlayIconImageView: UIImageView?
    internal var fileCurrentRequest: SDWebImageCombinedOperation?
    internal var fileDownloadOverlayView: UIView?
    internal var fileDownloadProgressView: UIProgressView?
    internal var fileDownloadLabel: UILabel?
    /// Left-aligned footer cache status (single icon, or album drive/cloud counts).
    internal var cacheHitIconView: UIView?

    // Location cell
    internal var locationPreviewImageView: UIImageView?
    internal var locationMapSnapshooter: MKMapSnapshotter?
    internal var locationPreviewImageViewHeightConstraint: NSLayoutConstraint?
    internal var locationPreviewImageViewWidthConstraint: NSLayoutConstraint?

    // Audio cell
    internal var audioPlayerView: AudioPlayerView?

    // Poll cell
    internal var pollMessageView: PollMessageView?

    override func awakeFromNib() {
        super.awakeFromNib()

        self.commonInit()
    }

    func commonInit() {
        self.headerPart.isHidden = false
        self.subheaderPart.isHidden = true
        self.quotePart.isHidden = true
        self.referencePart.isHidden = true
        self.reactionPart.isHidden = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        self.message = nil
        self.avatarButton.prepareForReuse()
        self.quotedMessageView?.avatarImageView.prepareForReuse()

        self.headerPart.isHidden = false
        self.avatarButton.isHidden = false
        self.subheaderPart.isHidden = true
        self.quotePart.isHidden = true
        self.referencePart.isHidden = true
        self.reactionPart.isHidden = true
        self.threadRepliesButton.isHidden = true

        // There might be a better way to do this, but for now we remove the elements so they don't mess
        // with autolayout even when they are hidden
        self.reactionView?.removeFromSuperview()
        self.reactionView = nil

        self.quotedMessageView?.removeFromSuperview()
        self.quotedMessageView = nil

        self.threadTitleLabel?.removeFromSuperview()
        self.threadTitleLabel = nil

        self.referenceView?.prepareForReuse()

        self.prepareForReuseFileCell()
        self.prepareForReuseAlbumCell()
        self.prepareForReuseLocationCell()
        self.prepareForReuseAudioCell()
        self.removeCacheHitIndicator()

        if let replyGestureRecognizer {
            self.removeGestureRecognizer(replyGestureRecognizer)
            self.replyGestureRecognizer = nil
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func setup(for message: NCChatMessage, inRoom room: NCRoom, forThread thread: NCThread?, withAccount account: TalkAccount) {
        self.message = message
        self.room = room
        self.account = account

        self.avatarButton.setActorAvatar(forMessage: message, withAccount: account)
        self.avatarButton.menu = self.getDeferredUserMenu()
        self.avatarButton.showsMenuAsPrimaryAction = true

        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        self.dateLabel.text = NCUtils.getTime(fromDate: date)

        let isOwnMessage = message.isMessage(from: account.userId)
        let messageActor = message.actor
        let titleLabel = messageActor.attributedDisplayName

        if let lastEditActorDisplayName = message.lastEditActorDisplayName, message.lastEditTimestamp > 0 {
            var editedString = ""

            if message.lastEditActorId == message.actorId, message.lastEditActorType == "users" {
                editedString = NSLocalizedString("edited", comment: "A message was edited")
                editedString = " (\(editedString))"
            } else {
                editedString = NSLocalizedString("edited by", comment: "A message was edited by ...")
                editedString = " (\(editedString) \(lastEditActorDisplayName))"
            }

            let editedAttributedString = editedString.withTextColor(.tertiaryLabel)

            titleLabel.append(editedAttributedString)
        }

        self.titleLabel.attributedText = titleLabel

        let shouldShowDeliveryStatus = NCDatabaseManager.sharedInstance().roomHasTalkCapability(.chatReadStatus, for: room)
        var shouldShowReadStatus = false

        if let roomCapabilities = NCDatabaseManager.sharedInstance().roomTalkCapabilities(for: room) {
            shouldShowReadStatus = !(roomCapabilities.readStatusPrivacy)
        }

        // This check is just a workaround to fix the issue with the deleted parents returned by the API.
        if let parent = message.parent, message.willShowParentMessageInThread(thread) {
            self.showQuotePart()

            self.quotedMessageView?.messageLabel.attributedText = parent.messageForLastMessagePreview()?.prefix(characters: 80).withFont(self.quotedMessageView?.messageLabel.font ?? .preferredFont(forTextStyle: .body))
            self.quotedMessageView?.actorLabel.attributedText = parent.actor.attributedDisplayName
            self.quotedMessageView?.highlighted = parent.isMessage(from: account.userId)
            self.quotedMessageView?.avatarImageView.setActorAvatar(forMessage: parent, withAccount: account)
        }

        if message.isGroupMessage, !message.willShowParentMessageInThread(thread) {
            self.titleLabel.text = ""
            self.headerPart.isHidden = true
            self.avatarButton.isHidden = true
        }

        if isOwnMessage {
            NSLayoutConstraint.deactivate(self.leftBubbleConstraints)
            NSLayoutConstraint.activate(self.rightBubbleConstraints)
        } else {
            NSLayoutConstraint.deactivate(self.rightBubbleConstraints)
            NSLayoutConstraint.activate(self.leftBubbleConstraints)
        }

        var backgroundColor: UIColor? = .secondarySystemBackground

        if isOwnMessage {
            backgroundColor = BaseChatTableViewCell.bubbleColorCache.object(forKey: account.accountId as NSString)

            if backgroundColor == nil {
                backgroundColor = NCAppBranding.elementColorBackground()
                BaseChatTableViewCell.bubbleColorCache.setObject(backgroundColor!, forKey: account.accountId as NSString)
            }

            // Ensure titleLabel does not interfere with width calculation (only on devices, not simulator)
            self.titleLabel.text = ""
            self.headerPart.isHidden = true
            self.avatarButton.isHidden = true
        }

        self.bubbleView.backgroundColor = backgroundColor

        // Make sure the status view is empty, when no delivery state should be set
        self.statusView.subviews.forEach {
            if $0 != dateLabel {
                $0.removeFromSuperview()
            }
        }
        self.removeCacheHitIndicator()

        if message.isDeleting {
            self.setDeliveryState(to: .deleting)
        } else if message.sendingFailed {
            self.setDeliveryState(to: .failed)
        } else if message.isTemporary {
            self.setDeliveryState(to: .sending)
        } else if message.isMessage(from: account.userId), shouldShowDeliveryStatus {
            if room.lastCommonReadMessage >= message.messageId, shouldShowReadStatus {
                self.setDeliveryState(to: .read)
            } else {
                self.setDeliveryState(to: .sent)
            }
        }

        if message.isSilent {
            addSystemImageToStatus("bell.slash")
        }

        if isOwnMessage, message.lastEditTimestamp > 0 {
            addSystemImageToStatus("pencil")
        }

        if message.isPinned {
            addSystemImageToStatus("pin")
        }

        let reactionsArray = message.reactionsArray()

        if !reactionsArray.isEmpty {
            self.showReactionsPart()
            self.reactionView?.updateReactions(reactions: reactionsArray)
        }

        // Show thread title and replies button for the thread original message (if not in a thread view)
        if thread == nil, message.isThreadOriginalMessage() {
            self.showThreadTitle()
            self.showThreadRepliesButton()
        }

        if message.containsURL() {
            self.showReferencePart()

            message.getReferenceData { message, referenceDataRaw, url in
                guard let cellMessage = self.message,
                      let referenceMessage = message,
                      cellMessage.isSameMessage(referenceMessage)
                else { return }

                if referenceDataRaw == nil, let deckCard = cellMessage.deckCard() {
                    // In case we were unable to retrieve reference data (for example if the user has no permissions)
                    // but the message is a shared deck card, we use the shared information to show the deck view
                    self.referenceView?.update(for: deckCard)
                } else if let referenceData = referenceDataRaw as? [String: [String: AnyObject]], let url {
                    self.referenceView?.update(for: referenceData, and: url)
                }
            }
        }

        if message.isReplyable, !message.isDeleting {
            self.addSlideToReplyGestureRecognizer(for: message)
        }

        if message.isVoiceMessage {
            // Audio message
            self.setupForAudioCell(with: message)
            self.updateCacheHitIndicator(for: message, account: account)
        } else if message.poll != nil {
            // Poll message
            self.setupForPollCell(with: message)
        } else if message.file() != nil {
            // File / album message
            if message.sumbaIsAlbumPrimary {
                self.setupForAlbumCell(with: message, with: account)
            } else {
                self.setupForFileCell(with: message, with: account)
            }
            self.updateCacheHitIndicator(for: message, account: account)
        } else if message.geoLocation() != nil {
            // Location message
            self.setupForLocationCell(with: message)
        } else {
            // Normal text message
            self.setupForMessageCell(with: message)
        }

        if message.isDeletedMessage {
            self.statusView.isHidden = true
            self.cacheHitIconView?.isHidden = true
            self.messageTextView?.textColor = .tertiaryLabel
        } else {
            self.statusView.isHidden = false
            self.cacheHitIconView?.isHidden = false
        }

        NotificationCenter.default.addObserver(self, selector: #selector(didChangeIsDownloading(notification:)), name: NSNotification.Name.NCChatFileControllerDidChangeIsDownloading, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didChangeDownloadProgress(notification:)), name: NSNotification.Name.NCChatFileControllerDidChangeDownloadProgress, object: nil)
    }

    func addSystemImageToStatus(_ systemName: String) {
        let view = UIImageView(frame: .init(x: 0, y: 0, width: 20, height: 14))
        let image = UIImage(systemName: systemName)?.withTintColor(.secondaryLabel).withRenderingMode(.alwaysOriginal)

        view.image = NCUtils.renderAspectImage(image: image, ofSize: .init(width: 20, height: 12), centerImage: true)
        view.contentMode = .scaleAspectFit
        view.widthAnchor.constraint(equalToConstant: 20).isActive = true
        view.heightAnchor.constraint(equalToConstant: 14).isActive = true

        self.statusView.addArrangedSubview(view)
    }

    private func removeCacheHitIndicator() {
        cacheHitIconView?.removeFromSuperview()
        cacheHitIconView = nil
    }

    private func isMessageFileCached(_ message: NCChatMessage, account: TalkAccount) -> Bool {
        guard let file = message.file() else { return false }
        let fileName: String
        if !file.name.isEmpty {
            fileName = file.name
        } else if let path = file.path, !path.isEmpty {
            fileName = (path as NSString).lastPathComponent
        } else {
            return false
        }
        let size = Int64(file.size ?? 0)
        return size > 0
            && MediaUploadDiskStore.hasCachedDownload(named: fileName, size: size, accountId: account.accountId)
    }

    /// Left-aligned footer: single-file drive/cloud icon; albums show `drive N · cloud M` (omit zero sides).
    /// Time and delivery checks stay right-aligned in `statusView`.
    private func updateCacheHitIndicator(for message: NCChatMessage, account: TalkAccount) {
        removeCacheHitIndicator()

        guard message.file() != nil else { return }

        let tint = dateLabel.textColor ?? .secondaryLabel
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let container = UIStackView()
        container.axis = .horizontal
        container.alignment = .center
        container.spacing = 3
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "CacheHitIcon"
        container.isHidden = statusView.isHidden
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)

        if message.sumbaIsAlbumPrimary, let members = message.sumbaAlbumMembers, members.count >= 2 {
            var onDisk = 0
            var inCloud = 0
            for member in members {
                if isMessageFileCached(member, account: account) {
                    onDisk += 1
                } else {
                    inCloud += 1
                }
            }

            if onDisk > 0 {
                container.addArrangedSubview(cacheStatusIcon(systemName: "internaldrive", config: symbolConfig, tint: tint))
                container.addArrangedSubview(cacheStatusCountLabel("\(onDisk)", tint: tint))
            }
            if onDisk > 0, inCloud > 0 {
                container.addArrangedSubview(cacheStatusSeparator(tint: tint))
            }
            if inCloud > 0 {
                container.addArrangedSubview(cacheStatusIcon(systemName: "cloud", config: symbolConfig, tint: tint))
                container.addArrangedSubview(cacheStatusCountLabel("\(inCloud)", tint: tint))
            }

            var a11yParts: [String] = []
            if onDisk > 0 {
                a11yParts.append(String.localizedStringWithFormat(
                    NSLocalizedString("%d saved on device", comment: "Album cache: count of locally cached files"),
                    onDisk
                ))
            }
            if inCloud > 0 {
                a11yParts.append(String.localizedStringWithFormat(
                    NSLocalizedString("%d not downloaded", comment: "Album cache: count of remote-only files"),
                    inCloud
                ))
            }
            container.isAccessibilityElement = true
            container.accessibilityLabel = a11yParts.joined(separator: ", ")
        } else {
            let cached = isMessageFileCached(message, account: account)
            let icon = cacheStatusIcon(systemName: cached ? "internaldrive" : "cloud", config: symbolConfig, tint: tint)
            container.addArrangedSubview(icon)
            container.isAccessibilityElement = true
            container.accessibilityLabel = cached
                ? NSLocalizedString("Saved on device", comment: "File is in local download cache")
                : NSLocalizedString("Not downloaded", comment: "File is not in local download cache")
        }

        guard !container.arrangedSubviews.isEmpty else { return }

        footerPart.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: footerPart.leadingAnchor, constant: 10),
            container.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 14),
            // Stay clear of the trailing time/checks cluster on narrow bubbles.
            container.trailingAnchor.constraint(lessThanOrEqualTo: statusView.leadingAnchor, constant: -6)
        ])
        cacheHitIconView = container
    }

    private func cacheStatusIcon(systemName: String, config: UIImage.SymbolConfiguration, tint: UIColor) -> UIImageView {
        let icon = UIImageView(image: UIImage(systemName: systemName, withConfiguration: config))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14)
        ])
        return icon
    }

    private func cacheStatusCountLabel(_ text: String, tint: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = tint
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func cacheStatusSeparator(tint: UIColor) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = tint.withAlphaComponent(0.35)
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 7),
            wrap.heightAnchor.constraint(equalToConstant: 14),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 10),
            line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        return wrap
    }

    func addSlideToReplyGestureRecognizer(for message: NCChatMessage) {
        if let action = DRCellSlideAction(forFraction: 0.2) {
            action.behavior = .pullBehavior
            action.activeColor = .label
            action.inactiveColor = .placeholderText
            action.activeBackgroundColor = self.backgroundColor
            action.inactiveBackgroundColor = self.backgroundColor
            action.icon = UIImage(systemName: "arrowshape.turn.up.left")

            action.willTriggerBlock = { [unowned self] _, _ -> Void in
                self.delegate?.cellWantsToReply(to: message)
            }

            action.didChangeStateBlock = { _, active -> Void in
                if active {
                    // Actuate `Peek` feedback (weak boom)
                    AudioServicesPlaySystemSound(1519)
                }
            }

            let replyGestureRecognizer = DRCellSlideGestureRecognizer()
            self.replyGestureRecognizer = replyGestureRecognizer

            replyGestureRecognizer.leftActionStartPosition = 80
            replyGestureRecognizer.addActions(action)

            self.addGestureRecognizer(replyGestureRecognizer)
        }
    }

    func setDeliveryState(to deliveryState: ChatMessageDeliveryState) {
        if deliveryState == .sending || deliveryState == .deleting {
            let activityIndicator = MDCActivityIndicator(frame: .init(x: 0, y: 0, width: 20, height: 20))

            activityIndicator.radius = 6.0
            activityIndicator.strokeWidth = 1.5
            activityIndicator.cycleColors = [.secondaryLabel]
            activityIndicator.startAnimating()
            activityIndicator.accessibilityIdentifier = "MessageSending"
            activityIndicator.widthAnchor.constraint(equalToConstant: 20).isActive = true

            self.statusView.addArrangedSubview(activityIndicator)

        } else if deliveryState == .failed {
            let errorView = UIImageView(frame: .init(x: 0, y: 0, width: 20, height: 20))
            let errorImage = UIImage(systemName: "exclamationmark.circle")?.withTintColor(.systemRed).withRenderingMode(.alwaysOriginal)

            errorView.image = errorImage
            errorView.contentMode = .scaleAspectFit
            errorView.widthAnchor.constraint(equalToConstant: 20).isActive = true

            self.statusView.addArrangedSubview(errorView)

        } else if deliveryState == .sent || deliveryState == .read {
            let isRead = deliveryState == .read
            let checkImageName = isRead ? "check-all" : "check"
            let checkImage = UIImage(named: checkImageName)?.withRenderingMode(.alwaysTemplate)
            let checkView = UIImageView(frame: .init(x: 0, y: 0, width: 20, height: 20))

            checkView.image = checkImage
            checkView.contentMode = .scaleAspectFit
            // WhatsApp-style: gray single tick when sent, blue double tick when read.
            checkView.tintColor = isRead ? .systemBlue : .secondaryLabel
            checkView.accessibilityIdentifier = isRead ? "MessageRead" : "MessageSent"
            checkView.widthAnchor.constraint(equalToConstant: 20).isActive = true

            self.statusView.addArrangedSubview(checkView)
        }
    }

    // MARK: - SubheaderPart

    func showThreadTitle() {
        self.subheaderPart.isHidden = false

        if self.threadTitleLabel == nil, let threadTitle = message?.threadTitle {
            let threadTitleLabel = UILabel()
            threadTitleLabel.font = .preferredFont(for: .body, weight: .semibold)
            self.threadTitleLabel = threadTitleLabel

            let config = UIImage.SymbolConfiguration(font: threadTitleLabel.font, scale: .small)
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: "bubble.left.and.bubble.right", withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate)

            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " \(threadTitle)"))
            text.addAttribute(.foregroundColor, value: UIColor.label,
                              range: NSRange(location: 0, length: text.length))
            threadTitleLabel.attributedText = text

            threadTitleLabel.translatesAutoresizingMaskIntoConstraints = false

            self.subheaderPart.addSubview(threadTitleLabel)

            NSLayoutConstraint.activate([
                threadTitleLabel.leftAnchor.constraint(equalTo: self.messageBodyView.leftAnchor),
                threadTitleLabel.rightAnchor.constraint(equalTo: self.subheaderPart.rightAnchor, constant: -10),
                threadTitleLabel.topAnchor.constraint(equalTo: self.subheaderPart.topAnchor, constant: 10),
                threadTitleLabel.bottomAnchor.constraint(equalTo: self.subheaderPart.bottomAnchor)
            ])
        }
    }

    // MARK: - QuotePart

    func showQuotePart() {
        self.quotePart.isHidden = false

        if self.quotedMessageView == nil {
            let quotedMessageView = QuotedMessageView()
            self.quotedMessageView = quotedMessageView

            quotedMessageView.translatesAutoresizingMaskIntoConstraints = false

            self.quotePart.addSubview(quotedMessageView)

            NSLayoutConstraint.activate([
                quotedMessageView.leftAnchor.constraint(equalTo: self.messageBodyView.leftAnchor),
                quotedMessageView.rightAnchor.constraint(equalTo: self.quotePart.rightAnchor, constant: -10),
                quotedMessageView.topAnchor.constraint(equalTo: self.quotePart.topAnchor, constant: 10),
                quotedMessageView.bottomAnchor.constraint(equalTo: self.quotePart.bottomAnchor)
            ])

            let quoteTap = UITapGestureRecognizer(target: self, action: #selector(quoteTapped(_:)))
            quotedMessageView.addGestureRecognizer(quoteTap)
        }
    }

    @objc func quoteTapped(_ sender: UITapGestureRecognizer?) {
        if let parent = self.message?.parent {
            self.delegate?.cellWantsToScroll(to: parent)
        }
    }

    // MARK: - ReferencePart

    func showReferencePart() {
        self.referencePart.isHidden = false

        if self.referenceView == nil {
            let referenceView = ReferenceView()
            self.referenceView = referenceView

            referenceView.translatesAutoresizingMaskIntoConstraints = false

            self.referencePart.addSubview(referenceView)

            NSLayoutConstraint.activate([
                referenceView.leftAnchor.constraint(equalTo: self.messageBodyView.leftAnchor),
                referenceView.rightAnchor.constraint(equalTo: self.referencePart.rightAnchor, constant: -10),
                referenceView.topAnchor.constraint(equalTo: self.referencePart.topAnchor),
                referenceView.bottomAnchor.constraint(equalTo: self.referencePart.bottomAnchor, constant: -5)
            ])
        }
    }

    // MARK: - ReactionsPart

    func showThreadRepliesButton() {
        self.threadRepliesButton.addAction { [weak self] in
            guard let self, let message else { return }
            self.delegate?.cellWants(toShowThread: message)
        }

        let replies = message?.threadReplies ?? 0
        if replies > 0 {
            let repliesString = String.localizedStringWithFormat(NSLocalizedString("%d replies", comment: "Replies in a thread"), replies)
            self.threadRepliesButton.setTitle(repliesString, for: .normal)
        } else {
            self.threadRepliesButton.setTitle("Reply", for: .normal)
        }

        self.reactionPart.isHidden = false
        self.threadRepliesButton.isHidden = false
    }

    func showReactionsPart() {
        self.reactionPart.isHidden = false

        if self.reactionView == nil {
            let flowLayout = UICollectionViewFlowLayout()
            flowLayout.scrollDirection = .horizontal

            let reactionView = ReactionsView(frame: .init(x: 0, y: 0, width: 50, height: 30), collectionViewLayout: flowLayout)
            reactionView.reactionsDelegate = self
            self.reactionView = reactionView

            reactionView.translatesAutoresizingMaskIntoConstraints = false

            self.reactionStackView.addArrangedSubview(reactionView)
        }
    }

    // MARK: - ReactionsView Delegate

    func didSelectReaction(reaction: NCChatReaction) {
        if let message = self.message {
            self.delegate?.cellDidSelectedReaction(reaction, for: message)
        }
    }

    // MARK: - Avatar User Menu

    func getDeferredUserMenu() -> UIMenu? {
        guard let message = self.message, let account = message.account
        else { return nil }

        if message.actorType != "users" || message.actorId == account.userId {
            return nil
        }

        // Use an uncached provider so local time is not cached
        let deferredMenuElement = UIDeferredMenuElement.uncached { [weak self] completion in
            self?.getMenuUserAction(for: message) { items in
                completion(items)
            }
        }

        return UIMenu(title: message.actorDisplayName, children: [deferredMenuElement])
    }

    func getMenuUserAction(for message: NCChatMessage, completionBlock: @escaping ([UIMenuElement]) -> Void) {
        guard let account = message.account else { return }

        NCAPIController.sharedInstance().getUserActions(forUser: message.actorId, forAccount: account) { userActionsRaw, error in
            guard error == nil,
                  let userActionsDict = userActionsRaw as? [String: AnyObject],
                  let userActions = userActionsDict["actions"] as? [[String: String]],
                  let userId = userActionsDict["userId"] as? String
            else {
                let errorAction = UIAction(title: NSLocalizedString("No actions available", comment: "")) { _ in }
                errorAction.attributes = .disabled
                completionBlock([errorAction])

                return
            }

            var menuItems: [UIMenuElement] = []

            for userAction in userActions {
                guard let appId = userAction["appId"],
                      let title = userAction["title"],
                      let link = userAction["hyperlink"],
                      let linkEncoded = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                else { continue }

                if appId == "spreed" {
                    let talkAction = UIAction(title: title, image: UIImage(named: "talk-20")?.withRenderingMode(.alwaysTemplate)) { _ in
                        NotificationCenter.default.post(name: NSNotification.Name.NCChatViewControllerTalkToUserNotification, object: self, userInfo: ["actorId": userId])
                    }

                    menuItems.append(talkAction)
                    continue
                }

                let otherAction = UIAction(title: title) { _ in
                    if let actionUrl = URL(string: linkEncoded) {
                        UIApplication.shared.open(actionUrl)
                    }
                }

                if appId == "profile" {
                    otherAction.image = UIImage(systemName: "person")
                } else if appId == "email" {
                    otherAction.image = UIImage(systemName: "envelope")
                } else if appId == "timezone" {
                    otherAction.image = UIImage(systemName: "clock")
                } else if appId == "social" {
                    otherAction.image = UIImage(systemName: "heart")
                }

                menuItems.append(otherAction)
            }

            completionBlock(menuItems)
        }
    }

    // MARK: - File status / download progress

    func clearFileStatusView() {
        self.fileActivityIndicator?.stopAnimating()
        self.fileActivityIndicator?.removeFromSuperview()
        self.fileActivityIndicator = nil
        self.hideFileDownloadOverlay()
    }

    /// Legacy corner spinner — kept for voice/temporary upload when no file preview thumb exists.
    func addActivityIndicator(with progress: Float) {
        self.fileActivityIndicator?.stopAnimating()
        self.fileActivityIndicator?.removeFromSuperview()
        self.fileActivityIndicator = nil

        let fileActivityIndicator = MDCActivityIndicator(frame: .init(x: 0, y: 0, width: 20, height: 20))
        self.fileActivityIndicator = fileActivityIndicator

        fileActivityIndicator.radius = 6
        fileActivityIndicator.strokeWidth = 1.5
        fileActivityIndicator.cycleColors = [.secondaryLabel]

        if progress > 0 {
            fileActivityIndicator.indicatorMode = .determinate
            fileActivityIndicator.setProgress(progress, animated: false)
        }

        fileActivityIndicator.startAnimating()
        fileActivityIndicator.widthAnchor.constraint(equalToConstant: 20).isActive = true
        self.statusView.addArrangedSubview(fileActivityIndicator)
    }

    func updateFileDownloadProgress(with status: NCChatFileStatus) {
        if self.filePreviewImageView != nil {
            self.showFileDownloadOverlay(progress: status.downloadProgress,
                                         completedBytes: status.completedBytes,
                                         totalBytes: status.totalBytes,
                                         canReportProgress: status.canReportProgress)
        } else {
            self.addActivityIndicator(with: status.canReportProgress ? status.downloadProgress : 0)
        }
    }

    private func ensureFileDownloadOverlay() {
        guard let preview = filePreviewImageView, fileDownloadOverlayView == nil else { return }

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.40)
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityIdentifier = "FileDownloadOverlay"

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let progress = UIProgressView(progressViewStyle: .bar)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.28)
        progress.layer.cornerRadius = 1.5
        progress.clipsToBounds = true
        progress.setContentHuggingPriority(.required, for: .vertical)
        progress.setContentCompressionResistancePriority(.required, for: .vertical)

        overlay.addSubview(label)
        overlay.addSubview(progress)
        preview.addSubview(overlay)

        let labelBottom = label.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -6)
        labelBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: preview.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: preview.bottomAnchor),

            progress.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 8),
            progress.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
            progress.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            progress.heightAnchor.constraint(equalToConstant: 3),

            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
            labelBottom,
            label.topAnchor.constraint(greaterThanOrEqualTo: overlay.topAnchor, constant: 4),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor)
        ])

        self.fileDownloadOverlayView = overlay
        self.fileDownloadProgressView = progress
        self.fileDownloadLabel = label
    }

    private func showFileDownloadOverlay(progress: Float, completedBytes: Int64, totalBytes: Int64, canReportProgress: Bool) {
        ensureFileDownloadOverlay()
        fileDownloadOverlayView?.isHidden = false
        filePreviewPlayIconImageView?.isHidden = true

        // Short previews: bar only — label would clip.
        let previewHeight = filePreviewImageView?.bounds.height
            ?? filePreviewImageViewHeightConstraint?.constant
            ?? 0
        let showLabel = previewHeight >= 48
        fileDownloadLabel?.isHidden = !showLabel

        let indeterminate = !canReportProgress || totalBytes <= 0 || progress <= 0
        if indeterminate {
            fileDownloadProgressView?.setProgress(0, animated: false)
            fileDownloadLabel?.text = NSLocalizedString("Loading…", comment: "File download in progress")
        } else {
            fileDownloadProgressView?.setProgress(min(max(progress, 0), 1), animated: true)
            let loaded = NCUtils.readableFileSize(completedBytes)
            let total = NCUtils.readableFileSize(totalBytes)
            if loaded.isEmpty || total.isEmpty {
                fileDownloadLabel?.text = NSLocalizedString("Loading…", comment: "File download in progress")
            } else {
                fileDownloadLabel?.text = String(format: NSLocalizedString("Loading %@ of %@", comment: "File download progress, e.g. Loading 12 MB of 40 MB"), loaded, total)
            }
        }
    }

    private func hideFileDownloadOverlay() {
        fileDownloadOverlayView?.isHidden = true
        fileDownloadProgressView?.setProgress(0, animated: false)
        fileDownloadLabel?.text = nil
    }

    // MARK: - File notifications

    @objc func didChangeIsDownloading(notification: Notification) {
        DispatchQueue.main.async {
            guard let message = self.message else { return }

            // Single-file cell, or any member of an album mosaic.
            let trackedFiles: [NCMessageFileParameter] = {
                if let members = message.sumbaAlbumMembers, members.count >= 2 {
                    return members.compactMap { $0.file() }
                }
                if let file = message.file() {
                    return [file]
                }
                return []
            }()

            guard let receivedStatus = notification.userInfo?["fileStatus"] as? NCChatFileStatus,
                  trackedFiles.contains(where: { $0.parameterId == receivedStatus.fileId })
            else { return }

            let isPrimaryFile = message.file()?.parameterId == receivedStatus.fileId

            if receivedStatus.isDownloading {
                if isPrimaryFile {
                    self.updateFileDownloadProgress(with: receivedStatus)
                }
            } else {
                if isPrimaryFile {
                    self.clearFileStatusView()
                    if let mimetype = message.file()?.mimetype,
                       NCUtils.isVideo(fileType: mimetype),
                       self.filePreviewImageView?.image != nil {
                        self.filePreviewPlayIconImageView?.isHidden = false
                    }
                }
                // Download finished (or cache hit) — refresh drive/cloud counts live.
                if let account = self.account {
                    self.updateCacheHitIndicator(for: message, account: account)
                }
            }
        }
    }

    @objc func didChangeDownloadProgress(notification: Notification) {
        DispatchQueue.main.async {
            // Make sure this notification is really for this cell
            guard let fileParameter = self.message?.file(),
                  let receivedStatus = NCChatFileStatus.getStatus(from: notification, for: fileParameter)
            else { return }

            self.updateFileDownloadProgress(with: receivedStatus)
        }
    }
}
