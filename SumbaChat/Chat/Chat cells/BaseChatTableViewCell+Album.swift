//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import ObjectiveC
import SDWebImage

extension BaseChatTableViewCell {

    private static var albumMosaicViewKey: UInt8 = 0
    private static var albumMosaicHeightKey: UInt8 = 0
    private static var albumMosaicWidthKey: UInt8 = 0
    private static var albumTileRequestsKey: UInt8 = 0

    private var albumMosaicView: UIView? {
        get { objc_getAssociatedObject(self, &Self.albumMosaicViewKey) as? UIView }
        set { objc_setAssociatedObject(self, &Self.albumMosaicViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var albumMosaicHeightConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.albumMosaicHeightKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.albumMosaicHeightKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var albumMosaicWidthConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.albumMosaicWidthKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.albumMosaicWidthKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var albumTileRequests: [SDWebImageCombinedOperation] {
        get { (objc_getAssociatedObject(self, &Self.albumTileRequestsKey) as? [SDWebImageCombinedOperation]) ?? [] }
        set { objc_setAssociatedObject(self, &Self.albumTileRequestsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func setupForAlbumCell(with message: NCChatMessage, with account: TalkAccount) {
        guard let members = message.sumbaAlbumMembers, members.count >= 2 else {
            self.setupForFileCell(with: message, with: account)
            return
        }

        // Hide single-file preview chrome when reusing a file cell.
        self.filePreviewImageView?.isHidden = true
        self.filePreviewPlayIconImageView?.isHidden = true
        self.filePreviewActivityIndicator?.isHidden = true
        self.filePreviewImageViewHeightConstraint?.constant = 0
        self.filePreviewImageViewWidthConstraint?.constant = 0

        if self.messageTextView == nil {
            let messageTextView = MessageBodyTextView()
            messageTextView.translatesAutoresizingMaskIntoConstraints = false
            self.messageBodyView.addSubview(messageTextView)
            self.messageTextView = messageTextView
        }

        if self.albumMosaicView == nil {
            let mosaic = UIView()
            mosaic.translatesAutoresizingMaskIntoConstraints = false
            mosaic.layer.cornerRadius = chatMessageCellPreviewCornerRadius
            mosaic.layer.masksToBounds = true
            mosaic.backgroundColor = .secondarySystemFill
            self.messageBodyView.addSubview(mosaic)
            self.albumMosaicView = mosaic

            let height = mosaic.heightAnchor.constraint(equalToConstant: SumbaMediaAlbum.mosaicWidth)
            let width = mosaic.widthAnchor.constraint(equalToConstant: SumbaMediaAlbum.mosaicWidth)
            self.albumMosaicHeightConstraint = height
            self.albumMosaicWidthConstraint = width

            NSLayoutConstraint.activate([
                mosaic.leftAnchor.constraint(equalTo: self.messageBodyView.leftAnchor),
                mosaic.topAnchor.constraint(equalTo: self.messageBodyView.topAnchor),
                mosaic.rightAnchor.constraint(lessThanOrEqualTo: self.messageBodyView.rightAnchor),
                height,
                width
            ])
        }

        self.albumMosaicView?.isHidden = false
        if let mosaic = self.albumMosaicView, let messageTextView = self.messageTextView {
            self.rebindMessageTextView(below: mosaic, messageTextView: messageTextView)
        }

        let mosaicSize = SumbaMediaAlbum.mosaicSize(forCount: members.count)
        self.albumMosaicHeightConstraint?.constant = mosaicSize.height
        self.albumMosaicWidthConstraint?.constant = mosaicSize.width

        guard let messageTextView = self.messageTextView else { return }
        // Same body font as other chat messages. Only strip obsolete synthetic "N media files" caption prefixes.
        let raw = (message.message as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let userCaption = SumbaMediaAlbumReference.cleanedUserCaption(message.message), userCaption == raw {
            messageTextView.attributedText = message.parsedMarkdownForChat()
            messageTextView.dataDetectorTypes = .all
        } else if let userCaption = SumbaMediaAlbumReference.cleanedUserCaption(message.message) {
            let attributed = NSMutableAttributedString(string: userCaption)
            attributed.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: NSRange(location: 0, length: attributed.length))
            attributed.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: attributed.length))
            messageTextView.attributedText = message.isMarkdownMessage
                ? SwiftMarkdownObjCBridge.parseMarkdown(markdownString: attributed)
                : attributed
            messageTextView.dataDetectorTypes = .all
        } else {
            messageTextView.attributedText = nil
            messageTextView.dataDetectorTypes = []
        }

        self.reloadAlbumMosaic(members: members, size: mosaicSize, account: account)
    }

    func prepareForReuseAlbumCell() {
        for request in self.albumTileRequests {
            request.cancel()
        }
        self.albumTileRequests = []
        self.albumMosaicView?.subviews.forEach { $0.removeFromSuperview() }
        self.hideAlbumMosaicChrome()
        self.filePreviewImageView?.isHidden = false
    }

    func hideAlbumMosaicChrome() {
        self.albumMosaicView?.isHidden = true
    }

    func rebindMessageTextViewBelowFilePreview(_ filePreview: UIView, messageTextView: UIView) {
        self.rebindMessageTextView(below: filePreview, messageTextView: messageTextView)
    }

    /// Drop prior caption constraints and pin under `anchor`.
    private func rebindMessageTextView(below anchor: UIView, messageTextView: UIView) {
        for constraint in self.messageBodyView.constraints {
            let first = constraint.firstItem as? UIView
            let second = constraint.secondItem as? UIView
            let involvesText = first === messageTextView || second === messageTextView
            if involvesText {
                constraint.isActive = false
            }
        }

        NSLayoutConstraint.activate([
            messageTextView.leftAnchor.constraint(equalTo: self.messageBodyView.leftAnchor),
            messageTextView.rightAnchor.constraint(equalTo: self.messageBodyView.rightAnchor),
            messageTextView.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 10),
            messageTextView.bottomAnchor.constraint(equalTo: self.messageBodyView.bottomAnchor)
        ])
    }

    private func reloadAlbumMosaic(members: [NCChatMessage], size: CGSize, account: TalkAccount) {
        for request in self.albumTileRequests {
            request.cancel()
        }
        self.albumTileRequests = []

        guard let mosaic = self.albumMosaicView else { return }
        mosaic.subviews.forEach { $0.removeFromSuperview() }

        let frames = Self.albumTileFrames(count: members.count, in: size)
        let visibleCount = min(members.count, frames.count)
        var operations: [SDWebImageCombinedOperation] = []

        for index in 0..<visibleCount {
            let member = members[index]
            let frame = frames[index]
            let tile = UIImageView(frame: frame)
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = .tertiarySystemFill
            tile.isUserInteractionEnabled = true
            tile.tag = index
            let tap = UITapGestureRecognizer(target: self, action: #selector(albumTileTapped(_:)))
            tile.addGestureRecognizer(tap)
            mosaic.addSubview(tile)

            if let file = member.file(), file.previewAvailable {
                let fileId = file.parameterId
                let requestedHeight = Int(3 * fileMessageCellFileMaxPreviewHeight)
                if let operation = NCAPIController.sharedInstance().getPreviewForFile(fileId,
                                                                                        width: -1,
                                                                                        height: requestedHeight,
                                                                                        forAccount: account,
                                                                                        completionBlock: { [weak tile] image, error in
                    guard error == nil, let image else { return }
                    DispatchQueue.main.async {
                        tile?.image = image
                    }
                }) {
                    operations.append(operation)
                }
            } else if let mimetype = member.file()?.mimetype {
                let imageName = NCUtils.previewImage(forMimeType: mimetype)
                tile.image = UIImage(named: imageName)
            }

            if let mimetype = member.file()?.mimetype, NCUtils.isVideo(fileType: mimetype) {
                let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
                play.tintColor = UIColor.white.withAlphaComponent(0.9)
                play.translatesAutoresizingMaskIntoConstraints = false
                tile.addSubview(play)
                NSLayoutConstraint.activate([
                    play.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                    play.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                    play.widthAnchor.constraint(equalToConstant: 28),
                    play.heightAnchor.constraint(equalToConstant: 28)
                ])
            }

            if index == visibleCount - 1, members.count > visibleCount {
                let overlay = UILabel(frame: frame)
                overlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
                overlay.textColor = .white
                overlay.textAlignment = .center
                overlay.font = .systemFont(ofSize: 22, weight: .semibold)
                overlay.text = "+\(members.count - visibleCount)"
                overlay.isUserInteractionEnabled = false
                mosaic.addSubview(overlay)
            }
        }

        self.albumTileRequests = operations
    }

    @objc private func albumTileTapped(_ gesture: UITapGestureRecognizer) {
        guard let tile = gesture.view,
              let members = self.message?.sumbaAlbumMembers,
              tile.tag >= 0, tile.tag < members.count
        else { return }
        let member = members[tile.tag]
        guard let fileParameter = member.file(),
              fileParameter.path != nil, fileParameter.link != nil
        else { return }
        self.delegate?.cellWants(toDownloadFile: fileParameter, for: member)
    }

    /// Up to 4 visible tiles; remainder shown as +N on the last tile.
    private static func albumTileFrames(count: Int, in size: CGSize) -> [CGRect] {
        let spacing: CGFloat = 2
        let w = size.width
        let h = size.height

        switch count {
        case 2:
            let tileW = (w - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: tileW, height: h),
                CGRect(x: tileW + spacing, y: 0, width: tileW, height: h)
            ]
        case 3:
            let topH = (h - spacing) * 0.55
            let bottomH = h - spacing - topH
            let bottomW = (w - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: w, height: topH),
                CGRect(x: 0, y: topH + spacing, width: bottomW, height: bottomH),
                CGRect(x: bottomW + spacing, y: topH + spacing, width: bottomW, height: bottomH)
            ]
        default:
            let tileW = (w - spacing) / 2
            let tileH = (h - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: tileW, height: tileH),
                CGRect(x: tileW + spacing, y: 0, width: tileW, height: tileH),
                CGRect(x: 0, y: tileH + spacing, width: tileW, height: tileH),
                CGRect(x: tileW + spacing, y: tileH + spacing, width: tileW, height: tileH)
            ]
        }
    }
}
