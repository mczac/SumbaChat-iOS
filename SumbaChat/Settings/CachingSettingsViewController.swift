//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import SDWebImage

/// Settings → Advanced → Caching: usage bars for chat downloads vs other stores, plus clear actions.
final class CachingSettingsViewController: UITableViewController, UITextFieldDelegate {

    private enum Section: Int, CaseIterable {
        case overview = 0
        case chatCache
        case otherStorage
    }

    private enum ChatRow: Int, CaseIterable {
        case images = 0
        case videos
        case documents
        case cacheLimit
    }

    private enum OtherRow: Int, CaseIterable {
        case uploadStaging = 0
        case convertCache
        case shareThumbs
        case systemPreviews
    }

    private let colorImages = UIColor.systemBlue
    private let colorVideos = UIColor.systemTeal
    private let colorDocuments = UIColor.systemIndigo
    private let colorUpload = UIColor.systemOrange
    private let colorConvert = UIColor.systemBrown
    /// Distinct from bar track / grey legends so small segments stay visible.
    private let colorThumbs = UIColor.systemPink
    private let colorPreviews = UIColor.systemCyan

    private let minimumMegabytes: Int64 = 512
    private let maximumMegabytes: Int64 = 50 * 1024 // 50 GB

    private var imagesBytes: Int64 = 0
    private var videosBytes: Int64 = 0
    private var documentsBytes: Int64 = 0
    private var uploadBytes: Int64 = 0
    private var convertBytes: Int64 = 0
    private var thumbsBytes: Int64 = 0
    private var previewsBytes: Int64 = 0

    private var chatTotal: Int64 { imagesBytes + videosBytes + documentsBytes }
    private var otherTotal: Int64 { uploadBytes + convertBytes + thumbsBytes + previewsBytes }
    private var cacheLimitBytes: Int64 { NCUserDefaults.fileCacheMaxBytes() }

    private lazy var cacheLimitField: UITextField = {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.textAlignment = .right
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = .label
        field.delegate = self
        field.accessibilityLabel = NSLocalizedString("Cache limit in megabytes", comment: "")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.addTarget(self, action: #selector(cacheLimitEditingEnded), for: .editingDidEnd)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: NSLocalizedString("Done", comment: ""),
                style: .done,
                target: self,
                action: #selector(cacheLimitDoneTapped)
            )
        ]
        field.inputAccessoryView = toolbar
        return field
    }()

    private lazy var cacheLimitMBLabel: UILabel = {
        let mbLabel = UILabel()
        mbLabel.text = NSLocalizedString("MB", comment: "Megabytes unit")
        mbLabel.font = .preferredFont(forTextStyle: .body)
        mbLabel.textColor = .secondaryLabel
        mbLabel.setContentHuggingPriority(.required, for: .horizontal)
        mbLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        return mbLabel
    }()

    private lazy var cacheLimitAccessory: UIStackView = {
        cacheLimitField.translatesAutoresizingMaskIntoConstraints = false
        // Narrow phones (16e): keep the control compact so "Cache limit" stays on one line.
        let width = cacheLimitField.widthAnchor.constraint(equalToConstant: 64)
        width.priority = .defaultHigh
        width.isActive = true

        let stack = UIStackView(arrangedSubviews: [cacheLimitField, cacheLimitMBLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }()

    /// `accessoryView` needs an explicit size; otherwise the MB field wraps/overlaps on narrow widths.
    private func sizedCacheLimitAccessory() -> UIView {
        let stack = cacheLimitAccessory
        stack.layoutIfNeeded()
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: UIView.layoutFittingCompressedSize.width, height: 44),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .required
        )
        stack.bounds = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: max(44, ceil(size.height))))
        return stack
    }

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Caching", comment: "Settings screen for cache usage")
        NCAppBranding.styleViewController(self)
        tableView.register(CacheOverviewCell.self, forCellReuseIdentifier: CacheOverviewCell.reuseId)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        refreshUsage()
        syncCacheLimitField()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshUsage()
        syncCacheLimitField()
        tableView.reloadData()
    }

    private func syncCacheLimitField() {
        let megabytes = max(minimumMegabytes, cacheLimitBytes / (1024 * 1024))
        cacheLimitField.text = "\(megabytes)"
    }

    private func refreshUsage() {
        let attachments = MediaUploadDiskStore.attachmentCacheUsage()
        imagesBytes = attachments.images
        videosBytes = attachments.videos
        documentsBytes = attachments.documents
        uploadBytes = MediaUploadDiskStore.uploadStagingUsageBytes()
        convertBytes = MediaUploadDiskStore.convertCacheUsageBytes()
        thumbsBytes = MediaUploadDiskStore.thumbsCacheUsageBytes()
        let sd = Int64(SDImageCache.shared.totalDiskSize())
        let url = Int64(URLCache.shared.currentDiskUsage)
        previewsBytes = max(0, sd) + max(0, url)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .overview: return 1
        case .chatCache: return ChatRow.allCases.count
        case .otherStorage: return OtherRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .overview: return nil
        case .chatCache: return NSLocalizedString("Chat cache", comment: "Cached chat attachments under Cache limit")
        case .otherStorage: return NSLocalizedString("Other storage", comment: "Caches not counted in Cache limit")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .chatCache:
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Swipe a row to clear. Cache limit is in megabytes (minimum %lld MB). Oldest files are removed automatically when nearly full.",
                    comment: "Footer under chat cache rows; %lld is minimum MB"
                ),
                minimumMegabytes
            )
        case .otherStorage:
            return NSLocalizedString(
                "These stores are not part of Cache limit. Swipe to clear individually.",
                comment: "Footer under other storage rows"
            )
        case .overview:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .overview:
            let cell = tableView.dequeueReusableCell(withIdentifier: CacheOverviewCell.reuseId, for: indexPath) as! CacheOverviewCell
            let limit = max(1, cacheLimitBytes)
            let chatUsed = chatTotal
            cell.configure(
                chatTitle: NSLocalizedString("Chat cache", comment: ""),
                chatSummary: String.localizedStringWithFormat(
                    NSLocalizedString("%@ of %@", comment: "Cache usage of limit; e.g. 57 MB of 3 GB"),
                    MediaUploadDiskStore.formatCacheBytes(chatUsed),
                    MediaUploadDiskStore.formatCacheBytes(limit)
                ),
                chatItems: [
                    CacheUsageItem(title: NSLocalizedString("Images", comment: ""), bytes: imagesBytes, color: colorImages),
                    CacheUsageItem(title: NSLocalizedString("Videos", comment: ""), bytes: videosBytes, color: colorVideos),
                    CacheUsageItem(title: NSLocalizedString("Documents", comment: ""), bytes: documentsBytes, color: colorDocuments)
                ],
                chatCapacity: max(limit, chatUsed),
                otherTitle: NSLocalizedString("Other storage", comment: ""),
                otherSummary: MediaUploadDiskStore.formatCacheBytes(otherTotal),
                otherItems: [
                    CacheUsageItem(title: NSLocalizedString("Upload", comment: "Legend: upload staging"), bytes: uploadBytes, color: colorUpload),
                    CacheUsageItem(title: NSLocalizedString("Encoding", comment: "Legend: encoding/convert cache"), bytes: convertBytes, color: colorConvert),
                    CacheUsageItem(title: NSLocalizedString("Thumbs", comment: "Legend: share thumbs"), bytes: thumbsBytes, color: colorThumbs),
                    CacheUsageItem(title: NSLocalizedString("Previews", comment: "Legend: system previews"), bytes: previewsBytes, color: colorPreviews)
                ],
                otherCapacity: max(otherTotal, 1)
            )
            return cell

        case .chatCache:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.accessoryView = nil
            cell.selectionStyle = .default
            switch ChatRow(rawValue: indexPath.row)! {
            case .images:
                config.text = NSLocalizedString("Cached Images", comment: "")
                config.secondaryText = MediaUploadDiskStore.formatCacheBytes(imagesBytes)
                config.image = coloredIcon("photo", colorImages)
            case .videos:
                config.text = NSLocalizedString("Cached Videos", comment: "")
                config.secondaryText = MediaUploadDiskStore.formatCacheBytes(videosBytes)
                config.image = coloredIcon("video", colorVideos)
            case .documents:
                config.text = NSLocalizedString("Cached Documents", comment: "")
                config.secondaryText = MediaUploadDiskStore.formatCacheBytes(documentsBytes)
                config.image = coloredIcon("doc", colorDocuments)
            case .cacheLimit:
                config.text = NSLocalizedString("Cache limit", comment: "")
                config.secondaryText = nil
                config.textProperties.numberOfLines = 1
                config.textProperties.lineBreakMode = .byTruncatingTail
                config.image = coloredIcon("internaldrive", .systemGray)
                // Prefer side-by-side so the title does not wrap under the MB field on 16e-width.
                config.prefersSideBySideTextAndSecondaryText = true
                cell.accessoryView = sizedCacheLimitAccessory()
                cell.selectionStyle = .none
            }
            cell.contentConfiguration = config
            return cell

        case .otherStorage:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 2
            cell.accessoryType = .none
            cell.accessoryView = nil
            cell.selectionStyle = .default
            switch OtherRow(rawValue: indexPath.row)! {
            case .uploadStaging:
                config.text = NSLocalizedString("Upload staging", comment: "")
                config.secondaryText = String.localizedStringWithFormat(
                    NSLocalizedString("%@ · soft cap %@", comment: "Size and soft cap"),
                    MediaUploadDiskStore.formatCacheBytes(uploadBytes),
                    MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.uploadStagingMaxBytes)
                )
                config.image = coloredIcon("arrow.up.circle", colorUpload)
            case .convertCache:
                config.text = NSLocalizedString("Encoding cache", comment: "Cached re-encoded media for reuse on send")
                config.secondaryText = String.localizedStringWithFormat(
                    NSLocalizedString("%@ · soft cap %@", comment: "Size and soft cap"),
                    MediaUploadDiskStore.formatCacheBytes(convertBytes),
                    MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.convertCacheMaxBytes)
                )
                config.image = coloredIcon("arrow.triangle.2.circlepath", colorConvert)
            case .shareThumbs:
                config.text = NSLocalizedString("Share thumbs", comment: "")
                config.secondaryText = String.localizedStringWithFormat(
                    NSLocalizedString("%@ · cleared with staging", comment: "Size note for share thumbs"),
                    MediaUploadDiskStore.formatCacheBytes(thumbsBytes)
                )
                config.image = coloredIcon("rectangle.grid.2x2", colorThumbs)
            case .systemPreviews:
                config.text = NSLocalizedString("System previews", comment: "")
                config.secondaryText = String.localizedStringWithFormat(
                    NSLocalizedString("%@ · avatars & chat previews", comment: "Size note for system previews"),
                    MediaUploadDiskStore.formatCacheBytes(previewsBytes)
                )
                config.image = coloredIcon("photo.on.rectangle", colorPreviews)
            }
            cell.contentConfiguration = config
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if Section(rawValue: indexPath.section) == .chatCache,
           ChatRow(rawValue: indexPath.row) == .cacheLimit {
            cacheLimitField.becomeFirstResponder()
        }
    }

    // MARK: - Cache limit (inline MB)

    @objc private func cacheLimitDoneTapped() {
        cacheLimitField.resignFirstResponder()
    }

    @objc private func cacheLimitEditingEnded() {
        commitCacheLimitFromField()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard textField === cacheLimitField else { return }
        commitCacheLimitFromField()
    }

    private func commitCacheLimitFromField() {
        guard let text = cacheLimitField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let megabytes = Int64(text) else {
            syncCacheLimitField()
            presentInvalidCacheLimitAlert()
            return
        }
        let clamped = min(maximumMegabytes, max(minimumMegabytes, megabytes))
        cacheLimitField.text = "\(clamped)"
        let bytes = clamped * 1024 * 1024
        guard bytes != cacheLimitBytes else {
            // Still refresh overview in case display was stale.
            tableView.reloadSections(IndexSet(integer: Section.overview.rawValue), with: .none)
            return
        }
        NCUserDefaults.setFileCacheMaxBytes(bytes)
        DispatchQueue.global(qos: .utility).async {
            NCChatFileController.enforceCacheSizeLimit()
            DispatchQueue.main.async { [weak self] in
                self?.refreshUsage()
                self?.tableView.reloadData()
            }
        }
    }

    private func presentInvalidCacheLimitAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("Invalid size", comment: ""),
            message: String.localizedStringWithFormat(
                NSLocalizedString("Enter a whole number of megabytes (at least %lld).", comment: ""),
                minimumMegabytes
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let clear = clearAction(for: indexPath) else { return nil }
        let action = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, done in
            self?.confirmClear(clear)
            done(true)
        }
        action.image = UIImage(systemName: "trash")
        action.backgroundColor = .systemRed
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    // MARK: - Clear

    private struct ClearSpec {
        let title: String
        let message: String
        let run: () -> Void
    }

    private func clearAction(for indexPath: IndexPath) -> ClearSpec? {
        switch Section(rawValue: indexPath.section)! {
        case .overview:
            return nil
        case .chatCache:
            switch ChatRow(rawValue: indexPath.row)! {
            case .images:
                return ClearSpec(
                    title: NSLocalizedString("Clear cached images?", comment: ""),
                    message: NSLocalizedString(
                        "Removes downloaded image attachments only. Avatars and chat previews are under System previews.",
                        comment: ""
                    )
                ) { [weak self] in
                    MediaUploadDiskStore.clearAttachmentCache(kind: .images)
                    self?.reloadAfterClear()
                }
            case .videos:
                return ClearSpec(
                    title: NSLocalizedString("Clear cached videos?", comment: ""),
                    message: NSLocalizedString(
                        "Removes downloaded video attachments only. Encoded reuse is under Encoding cache.",
                        comment: ""
                    )
                ) { [weak self] in
                    MediaUploadDiskStore.clearAttachmentCache(kind: .videos)
                    self?.reloadAfterClear()
                }
            case .documents:
                return ClearSpec(
                    title: NSLocalizedString("Clear cached documents?", comment: ""),
                    message: NSLocalizedString("Do you really want to clear the document cache?", comment: "")
                ) { [weak self] in
                    MediaUploadDiskStore.clearAttachmentCache(kind: .documents)
                    self?.reloadAfterClear()
                }
            case .cacheLimit:
                return nil
            }
        case .otherStorage:
            switch OtherRow(rawValue: indexPath.row)! {
            case .uploadStaging:
                return ClearSpec(
                    title: NSLocalizedString("Clear upload staging?", comment: ""),
                    message: String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Share send staging. Soft cap %@. Also clears share thumbs. Currently %@.",
                            comment: ""
                        ),
                        MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.uploadStagingMaxBytes),
                        MediaUploadDiskStore.formatCacheBytes(uploadBytes)
                    )
                ) { [weak self] in
                    if MediaUploadDiskStore.isUploadSessionActive() {
                        self?.presentShareInProgressAlert()
                        return
                    }
                    if !MediaUploadDiskStore.clearUploadStagingCaches() {
                        self?.presentShareInProgressAlert()
                    }
                    self?.reloadAfterClear()
                }
            case .convertCache:
                return ClearSpec(
                    title: NSLocalizedString("Clear encoding cache?", comment: ""),
                    message: String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Encoded reuse cache. Soft cap %@. Cleared entries must re-encode on next send. Currently %@.",
                            comment: ""
                        ),
                        MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.convertCacheMaxBytes),
                        MediaUploadDiskStore.formatCacheBytes(convertBytes)
                    )
                ) { [weak self] in
                    MediaUploadDiskStore.clearConvertCache()
                    self?.reloadAfterClear()
                }
            case .shareThumbs:
                return ClearSpec(
                    title: NSLocalizedString("Clear share thumbs?", comment: ""),
                    message: String.localizedStringWithFormat(
                        NSLocalizedString("Share-sheet image thumbs. Currently %@.", comment: ""),
                        MediaUploadDiskStore.formatCacheBytes(thumbsBytes)
                    )
                ) { [weak self] in
                    MediaUploadDiskStore.clearThumbsCache()
                    self?.reloadAfterClear()
                }
            case .systemPreviews:
                return ClearSpec(
                    title: NSLocalizedString("Clear system previews?", comment: ""),
                    message: String.localizedStringWithFormat(
                        NSLocalizedString("Avatars, chat file previews, and HTTP cache. Currently %@.", comment: ""),
                        MediaUploadDiskStore.formatCacheBytes(previewsBytes)
                    )
                ) { [weak self] in
                    URLCache.shared.removeAllCachedResponses()
                    SDImageCache.shared.clearMemory()
                    SDImageCache.shared.clearDisk {
                        MediaUploadTrace.log("CACHE clear system-previews (SDImageCache + URLCache)")
                        DispatchQueue.main.async {
                            self?.reloadAfterClear()
                        }
                    }
                }
            }
        }
    }

    private func confirmClear(_ spec: ClearSpec) {
        let alert = UIAlertController(title: spec.title, message: spec.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
            spec.run()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    private func presentShareInProgressAlert() {
        let blocked = UIAlertController(
            title: NSLocalizedString("Share in progress", comment: ""),
            message: NSLocalizedString(
                "Upload staging is in use by an active share session. Finish or cancel the share, then try again.",
                comment: ""
            ),
            preferredStyle: .alert
        )
        blocked.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(blocked, animated: true)
    }

    private func reloadAfterClear() {
        refreshUsage()
        tableView.reloadData()
    }

    private func coloredIcon(_ systemName: String, _ color: UIColor) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        return UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

// MARK: - Overview UI

private struct CacheUsageItem {
    let title: String
    let bytes: Int64
    let color: UIColor
}

private final class CacheOverviewCell: UITableViewCell {
    static let reuseId = "CacheOverviewCell"

    private let stack = UIStackView()
    private let chatTitleLabel = UILabel()
    private let chatSummaryLabel = UILabel()
    private let chatBar = CacheSegmentedBarView()
    private let chatLegend = CacheLegendView()
    private let otherTitleLabel = UILabel()
    private let otherSummaryLabel = UILabel()
    private let otherBar = CacheSegmentedBarView()
    private let otherLegend = CacheLegendView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        styleTitle(chatTitleLabel)
        styleSummary(chatSummaryLabel)
        styleTitle(otherTitleLabel)
        styleSummary(otherSummaryLabel)

        stack.addArrangedSubview(chatTitleLabel)
        stack.addArrangedSubview(chatSummaryLabel)
        stack.addArrangedSubview(chatBar)
        stack.addArrangedSubview(chatLegend)
        stack.setCustomSpacing(20, after: chatLegend)
        stack.addArrangedSubview(otherTitleLabel)
        stack.addArrangedSubview(otherSummaryLabel)
        stack.addArrangedSubview(otherBar)
        stack.addArrangedSubview(otherLegend)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -6),
            chatBar.heightAnchor.constraint(equalToConstant: 12),
            otherBar.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func styleTitle(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
    }

    private func styleSummary(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
    }

    func configure(chatTitle: String,
                   chatSummary: String,
                   chatItems: [CacheUsageItem],
                   chatCapacity: Int64,
                   otherTitle: String,
                   otherSummary: String,
                   otherItems: [CacheUsageItem],
                   otherCapacity: Int64) {
        chatTitleLabel.text = chatTitle
        chatSummaryLabel.text = chatSummary
        chatBar.setItems(chatItems, capacity: chatCapacity)
        chatLegend.setItems(chatItems)

        otherTitleLabel.text = otherTitle
        otherSummaryLabel.text = otherSummary
        otherBar.setItems(otherItems, capacity: otherCapacity)
        otherLegend.setItems(otherItems)
    }
}

private final class CacheSegmentedBarView: UIView {
    private var items: [CacheUsageItem] = []
    private var capacity: Int64 = 1
    private var segmentLayers: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        clipsToBounds = true
        backgroundColor = .tertiarySystemFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setItems(_ items: [CacheUsageItem], capacity: Int64) {
        self.items = items
        self.capacity = max(1, capacity)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        segmentLayers.forEach { $0.removeFromSuperlayer() }
        segmentLayers.removeAll()

        let cap = CGFloat(capacity)
        var x: CGFloat = 0
        for item in items where item.bytes > 0 {
            let fraction = min(1, CGFloat(item.bytes) / cap)
            let width = max(2, bounds.width * fraction)
            if x >= bounds.width { break }
            let layer = CALayer()
            layer.backgroundColor = item.color.cgColor
            let w = min(width, bounds.width - x)
            layer.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
            self.layer.addSublayer(layer)
            segmentLayers.append(layer)
            x += w
        }
    }
}

private final class CacheLegendView: UIView {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setItems(_ items: [CacheUsageItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Two columns of legend rows.
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.distribution = .fillEqually
        rowStack.spacing = 8
        stack.addArrangedSubview(rowStack)

        let left = UIStackView()
        left.axis = .vertical
        left.spacing = 6
        let right = UIStackView()
        right.axis = .vertical
        right.spacing = 6
        rowStack.addArrangedSubview(left)
        rowStack.addArrangedSubview(right)

        for (index, item) in items.enumerated() {
            let target = index % 2 == 0 ? left : right
            target.addArrangedSubview(makeRow(item))
        }
    }

    private func makeRow(_ item: CacheUsageItem) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center

        let swatch = UIView()
        swatch.backgroundColor = item.color
        swatch.layer.cornerRadius = 3.5
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 7),
            swatch.heightAnchor.constraint(equalToConstant: 7)
        ])

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.text = "\(item.title)  \(MediaUploadDiskStore.formatCacheBytes(item.bytes))"
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(swatch)
        row.addArrangedSubview(label)
        return row
    }
}
