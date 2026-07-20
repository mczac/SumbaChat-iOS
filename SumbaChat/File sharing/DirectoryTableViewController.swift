//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import QuickLook
import UIKit
import NextcloudKit
import PassKit

class DirectoryTableViewController: UITableViewController, UISearchResultsUpdating, NCChatFileControllerDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate, VLCKitVideoViewControllerDelegate {

    /// Share into a conversation vs browse/preview only (account menu).
    enum Mode {
        case share
        case browse
    }

    /// Shared when pushing into subfolders so the type filter stays applied.
    /// Icons match `NCChatMessage.messageIconName` (SF Symbols used in chat previews).
    enum FileTypeFilter: Int {
        case all
        case videos
        case audio
        case images
        case documents

        var title: String {
            switch self {
            case .all:
                return NSLocalizedString("All", comment: "File type filter: show all files")
            case .videos:
                return NSLocalizedString("Videos", comment: "File type filter: videos only")
            case .audio:
                return NSLocalizedString("Audio", comment: "File type filter: audio only (includes voice recordings)")
            case .images:
                return NSLocalizedString("Images", comment: "File type filter: images only")
            case .documents:
                return NSLocalizedString("Documents", comment: "File type filter: documents only")
            }
        }

        var systemImageName: String {
            switch self {
            case .all:
                return "square.grid.2x2"
            case .videos:
                return "movieclapper"
            case .audio:
                return "music.note"
            case .images:
                return "photo"
            case .documents:
                return "doc"
            }
        }
    }

    private struct FileListSection {
        let title: String?
        let items: [NKFile]
    }

    private let path: String
    private let token: String
    private let threadId: Int
    private let mode: Mode

    private var userHomePath = ""
    /// Full folder listing from the server (unfiltered).
    private var allItemsInDirectory: [NKFile] = []
    /// Sorted + filtered sections shown in the table.
    private var sections: [FileListSection] = []
    private var fileTypeFilter: FileTypeFilter
    private var nameSearchText: String = ""
    private var sortingButton: UIBarButtonItem?
    private var filterButton: UIBarButtonItem?
    private var searchController: UISearchController!
    private let directoryBackgroundView = PlaceholderView()
    private let sharingFileView = UIActivityIndicatorView()
    private var previewControllerFilePath = ""
    private var isPreviewControllerShown = false

    /// Conversation share picker (existing chat attach flow).
    convenience init(path: String, inRoom token: String, andThread threadId: Int, fileTypeFilter: FileTypeFilter = .all) {
        self.init(path: path, inRoom: token, andThread: threadId, mode: .share, fileTypeFilter: fileTypeFilter)
    }

    /// Account-menu browser: navigate folders, preview files, no share.
    convenience init(browsePath path: String = "", fileTypeFilter: FileTypeFilter = .all) {
        self.init(path: path, inRoom: "", andThread: 0, mode: .browse, fileTypeFilter: fileTypeFilter)
    }

    private init(path: String, inRoom token: String, andThread threadId: Int, mode: Mode, fileTypeFilter: FileTypeFilter) {
        self.path = path
        self.token = token
        self.threadId = threadId
        self.mode = mode
        self.fileTypeFilter = fileTypeFilter

        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        userHomePath = NCAPIController.sharedInstance().filesPath(forAccount: activeAccount)

        configureSearchController()
        configureNavigationBar()

        if #available(iOS 26.0, *) {
            sharingFileView.color = .label
        } else {
            sharingFileView.color = NCAppBranding.themeTextColor()
        }

        self.tableView.tableFooterView = UIView(frame: .zero)

        // Directory placeholder view
        directoryBackgroundView.setImage(UIImage(named: "folder-placeholder"))
        directoryBackgroundView.placeholderTextView.text = NSLocalizedString("No files in here", comment: "")
        directoryBackgroundView.placeholderView.isHidden = true
        directoryBackgroundView.loadingView.startAnimating()
        self.tableView.backgroundView = directoryBackgroundView

        NCAppBranding.styleViewController(self)

        self.tableView.separatorInset = UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)

        self.tableView.register(UINib(nibName: DirectoryTableViewCell.nibName, bundle: nil), forCellReuseIdentifier: DirectoryTableViewCell.identifier)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        getItemsInDirectory()
    }

    @objc private func cancelButtonPressed() {
        self.dismiss(animated: true)
    }

    @objc private func shareButtonPressed() {
        showConfirmationDialogForSharingItem(withPath: path,
                                             andName: (path as NSString).lastPathComponent,
                                             isDirectory: true)
    }

    private static let sortMenuSubtitleReserved = "\u{2007}"

    /// Rounded tile so menu glyphs (e.g. `textformat.abc` on iOS 26) read as icons, not part of the title.
    private static func sortMenuIcon(systemName: String) -> UIImage? {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: symbolConfig) else {
            return UIImage(systemName: systemName)
        }

        let tileSize = CGSize(width: 28, height: 28)
        let renderer = UIGraphicsImageRenderer(size: tileSize)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: tileSize)
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 7).fill()

            let tinted = symbol.withTintColor(.label, renderingMode: .alwaysOriginal)
            let drawRect = CGRect(
                x: (tileSize.width - tinted.size.width) / 2,
                y: (tileSize.height - tinted.size.height) / 2,
                width: tinted.size.width,
                height: tinted.size.height
            )
            tinted.draw(in: drawRect)
        }
    }

    private func sortDirectionSubtitle(for sorting: NCPreferredFileSorting, ascending: Bool) -> String {
        switch sorting {
        case .alphabeticalSorting:
            return ascending
                ? NSLocalizedString("A to Z", comment: "File browser name sort: ascending")
                : NSLocalizedString("Z to A", comment: "File browser name sort: descending")
        case .modificationDateSorting:
            return ascending
                ? NSLocalizedString("Earliest first", comment: "File browser date sort: oldest first")
                : NSLocalizedString("Latest first", comment: "File browser date sort: newest first")
        @unknown default:
            return Self.sortMenuSubtitleReserved
        }
    }

    private func addMenuToSortingButton() {
        let settings = NCSettingsController.sharedInstance()
        let preferredSorting = settings.getPreferredFileSorting()
        let ascending = settings.isPreferredFileSortingAscending()

        // One row per criterion; tap again toggles direction via subtitle only.
        let criteria: [(sorting: NCPreferredFileSorting, title: String, image: String)] = [
            (.alphabeticalSorting,
             NSLocalizedString("Name", comment: "File browser sort criterion"),
             "textformat.abc"),
            (.modificationDateSorting,
             NSLocalizedString("Date", comment: "File browser sort criterion"),
             "calendar")
        ]

        let actions: [UIAction] = criteria.map { item in
            let isSelected = preferredSorting == item.sorting
            let subtitle = isSelected
                ? sortDirectionSubtitle(for: item.sorting, ascending: ascending)
                : Self.sortMenuSubtitleReserved

            let action = UIAction(
                title: item.title,
                subtitle: subtitle,
                image: Self.sortMenuIcon(systemName: item.image),
                attributes: .keepsMenuPresented
            ) { [weak self] _ in
                guard let self else { return }
                if settings.getPreferredFileSorting() == item.sorting {
                    settings.setPreferredFileSortingAscending(!settings.isPreferredFileSortingAscending())
                } else {
                    settings.setPreferredFileSorting(item.sorting)
                    // Name → A to Z; Date → Latest first.
                    settings.setPreferredFileSortingAscending(item.sorting == .alphabeticalSorting)
                }
                self.applyFilterAndSort()
            }
            action.state = isSelected ? .on : .off
            return action
        }

        sortingButton?.menu = UIMenu(
            title: NSLocalizedString("Sorted by", comment: "File browser sort menu title"),
            children: actions
        )
    }

    private func addMenuToFilterButton() {
        let filters: [FileTypeFilter] = [.all, .videos, .audio, .images, .documents]
        let actions = filters.map { filter -> UIAction in
            let action = UIAction(title: filter.title, image: UIImage(systemName: filter.systemImageName)) { [weak self] _ in
                guard let self, self.fileTypeFilter != filter else { return }
                self.fileTypeFilter = filter
                self.applyFilterAndSort()
                self.updateFilterButtonAppearance()
            }
            action.state = fileTypeFilter == filter ? .on : .off
            return action
        }
        filterButton?.menu = UIMenu(title: NSLocalizedString("Filter", comment: "File browser type filter menu"),
                                    children: actions)
    }

    private func updateFilterButtonAppearance() {
        let imageName = fileTypeFilter == .all
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
        filterButton?.image = UIImage(systemName: imageName)
        filterButton?.accessibilityLabel = NSLocalizedString("Filter files", comment: "")
        addMenuToFilterButton()
    }

    // MARK: - Files

    private func getItemsInDirectory() {
        NCAPIController.sharedInstance().readFolder(forAccount: NCDatabaseManager.sharedInstance().activeAccount(), atPath: path, withDepth: "1") { [weak self] items, error in
            guard let self, let items, error == nil else { return }

            let currentDirectory = self.path.isEmpty ? "/" : (self.path as NSString).lastPathComponent
            var itemsInDirectory: [NKFile] = []

            for item in items {
                var itemPath = item.path.replacingOccurrences(of: self.userHomePath, with: "")

                // When nextcloud is installed in a subdirectory, it's not enough to replace the userHomePath,
                // because the subdirectory would get a part of the itemPath (see https://github.com/nextcloud/talk-ios/issues/996)
                let itemPathParts = item.path.components(separatedBy: self.userHomePath)
                if itemPathParts.count > 1 {
                    itemPath = itemPathParts[1]
                }

                if (itemPath as NSString).lastPathComponent == currentDirectory, !item.e2eEncrypted {
                    itemsInDirectory.append(item)
                }
            }

            self.allItemsInDirectory = itemsInDirectory
            self.applyFilterAndSort()

            self.directoryBackgroundView.loadingView.stopAnimating()
            self.directoryBackgroundView.loadingView.isHidden = true
            self.updatePlaceholderVisibility()
        }
    }

    private func applyFilterAndSort() {
        let query = nameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hideFoldersForTypeFilter = fileTypeFilter != .all

        var filtered = allItemsInDirectory.filter { item in
            if !query.isEmpty,
               item.fileName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }

            // Type filters hide folders (attachment pick). Name search keeps matching folders for navigation.
            if item.directory {
                if hideFoldersForTypeFilter {
                    return !query.isEmpty
                }
                return true
            }

            switch fileTypeFilter {
            case .all:
                return true
            case .videos:
                return NCUtils.isVideo(fileType: item.contentType)
            case .audio:
                return NCUtils.isAudio(fileType: item.contentType)
            case .images:
                return NCUtils.isImage(fileType: item.contentType)
            case .documents:
                return NCUtils.isDocument(fileType: item.contentType)
            }
        }

        let settings = NCSettingsController.sharedInstance()
        let sortByName = settings.getPreferredFileSorting() == .alphabeticalSorting
        let ascending = settings.isPreferredFileSortingAscending()

        if sortByName {
            filtered.sort { lhs, rhs in
                let result = lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName)
                return ascending ? (result == .orderedAscending) : (result == .orderedDescending)
            }
            sections = filtered.isEmpty ? [] : [FileListSection(title: nil, items: filtered)]
        } else {
            filtered.sort { lhs, rhs in
                let lhsDate = lhs.date as Date
                let rhsDate = rhs.date as Date
                if lhsDate == rhsDate {
                    let result = lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName)
                    return result == .orderedAscending
                }
                return ascending ? (lhsDate < rhsDate) : (lhsDate > rhsDate)
            }
            sections = Self.daySections(from: filtered)
        }

        addMenuToSortingButton()
        addMenuToFilterButton()
        updatePlaceholderVisibility()
        tableView.reloadData()
    }

    /// Group already-sorted items into calendar-day sections (sticky via UITableView headers).
    private static func daySections(from items: [NKFile]) -> [FileListSection] {
        guard !items.isEmpty else { return [] }

        let calendar = Calendar.current
        var result: [FileListSection] = []
        var currentDay: Date?
        var currentItems: [NKFile] = []

        for item in items {
            let day = calendar.startOfDay(for: item.date as Date)
            if currentDay == nil {
                currentDay = day
            }
            if day != currentDay {
                if let currentDay, !currentItems.isEmpty {
                    result.append(FileListSection(title: NCUtils.fileListDaySectionTitle(from: currentDay), items: currentItems))
                }
                currentDay = day
                currentItems = [item]
            } else {
                currentItems.append(item)
            }
        }

        if let currentDay, !currentItems.isEmpty {
            result.append(FileListSection(title: NCUtils.fileListDaySectionTitle(from: currentDay), items: currentItems))
        }

        return result
    }

    private func item(at indexPath: IndexPath) -> NKFile? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.row) else {
            return nil
        }
        return sections[indexPath.section].items[indexPath.row]
    }

    private func updatePlaceholderVisibility() {
        let hasRows = sections.contains { !$0.items.isEmpty }
        directoryBackgroundView.placeholderView.isHidden = hasRows
        let hasNameQuery = !nameSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if fileTypeFilter == .all && !hasNameQuery {
            directoryBackgroundView.placeholderTextView.text = NSLocalizedString("No files in here", comment: "")
        } else {
            directoryBackgroundView.placeholderTextView.text = NSLocalizedString("No matching files", comment: "")
        }
    }

    private func shareFile(withPath path: String) {
        setSharingFileUI()

        var talkMetaData: [String: Any] = [:]
        if threadId > 0 {
            talkMetaData["threadId"] = threadId
        }

        NCAPIController.sharedInstance().shareFileOrFolder(forAccount: NCDatabaseManager.sharedInstance().activeAccount(), atPath: path, toRoom: token, withTalkMetaData: talkMetaData, withReferenceId: nil) { [weak self] error in
            guard let self else { return }

            if let error {
                self.removeSharingFileUI()
                self.showErrorSharingItem()
                print("Error sharing file or folder: \(error)")
            } else {
                self.dismiss(animated: true)
            }
        }
    }

    // MARK: - Utils

    private func configureSearchController() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = NSLocalizedString("Search by name", comment: "SumbaFiles browser search placeholder")
        searchController.searchBar.autocapitalizationType = .none
        self.searchController = searchController
        self.navigationItem.searchController = searchController
        self.navigationItem.preferredSearchBarPlacement = .stacked
        self.definesPresentationContext = true
    }

    private func configureNavigationBar() {
        let sortingButton = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), style: .plain, target: self, action: nil)
        self.sortingButton = sortingButton
        addMenuToSortingButton()

        let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), style: .plain, target: self, action: nil)
        self.filterButton = filterButton
        updateFilterButtonAppearance()

        // Keep search attached across sharing-spinner resets of the right bar items.
        self.navigationItem.searchController = searchController

        // Home folder
        if path.isEmpty {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonPressed))
            self.navigationItem.rightBarButtonItems = [sortingButton, filterButton]

            if mode == .browse {
                self.navigationItem.title = NSLocalizedString("SumbaFiles", comment: "Browse SumbaFiles navigation title")
                self.navigationItem.titleView = nil
            } else {
                let navigationLogo = UIImage(systemName: "house")
                let navigationImageView = UIImageView(image: navigationLogo)
                navigationImageView.image = navigationImageView.image?.withRenderingMode(.alwaysTemplate)
                if #available(iOS 26.0, *) {
                    navigationImageView.tintColor = .label
                } else {
                    navigationImageView.tintColor = NCAppBranding.themeTextColor()
                }
                self.navigationItem.titleView = navigationImageView
            }

            let backImage = UIImage(systemName: "house")
            self.navigationItem.backBarButtonItem = UIBarButtonItem(image: backImage, style: .plain, target: nil, action: nil)
            // Other directories
        } else {
            if mode == .share {
                let shareButton = UIBarButtonItem(image: UIImage(named: "sharing"), style: .plain, target: self, action: #selector(shareButtonPressed))
                self.navigationItem.rightBarButtonItems = [sortingButton, filterButton, shareButton]
            } else {
                self.navigationItem.rightBarButtonItems = [sortingButton, filterButton]
            }

            self.navigationItem.title = (path as NSString).lastPathComponent
        }
    }

    // MARK: - UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        nameSearchText = searchController.searchBar.text ?? ""
        applyFilterAndSort()
    }

    private func setSharingFileUI() {
        sharingFileView.startAnimating()
        self.navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: sharingFileView)]
        self.navigationController?.navigationBar.isUserInteractionEnabled = false
        self.tableView.isUserInteractionEnabled = false
    }

    private func removeSharingFileUI() {
        sharingFileView.stopAnimating()
        configureNavigationBar()
        self.navigationController?.navigationBar.isUserInteractionEnabled = true
        self.tableView.isUserInteractionEnabled = true
    }

    private func showConfirmationDialogForSharingItem(withPath path: String, andName name: String, isDirectory: Bool) {
        let title = isDirectory
            ? NSLocalizedString("Share Folder", comment: "Confirm sharing a folder into the conversation")
            : NSLocalizedString("Share File", comment: "Confirm sharing a file into the conversation")
        let message = String(
            format: NSLocalizedString("Do you want to share '%@' in the conversation?", comment: ""),
            NCUtils.middleTruncatedFileName(name)
        )
        let confirmDialog = UIAlertController(title: title, message: message, preferredStyle: .alert)
        confirmDialog.addAction(UIAlertAction(title: NSLocalizedString("Share", comment: ""), style: .default) { [weak self] _ in
            self?.shareFile(withPath: path)
        })
        confirmDialog.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        self.present(confirmDialog, animated: true)
    }

    private func showErrorSharingItem() {
        let confirmDialog = UIAlertController(title: NSLocalizedString("Could not share file", comment: ""),
                                              message: NSLocalizedString("An error occurred while sharing the file", comment: ""),
                                              preferredStyle: .alert)
        confirmDialog.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        self.present(confirmDialog, animated: true)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        return sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections.indices.contains(section) else { return nil }
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return DirectoryTableViewCell.cellHeight
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: DirectoryTableViewCell.identifier) as? DirectoryTableViewCell ??
                   DirectoryTableViewCell(style: .default, reuseIdentifier: DirectoryTableViewCell.identifier)

        guard let item = item(at: indexPath) else {
            return cell
        }

        // Name (middle-truncated in the cell) + size · relative date
        cell.fileNameLabel.text = item.fileName
        if item.directory {
            cell.fileInfoLabel.text = NCUtils.relativeTimeFromDate(date: item.date as Date)
        } else {
            cell.fileInfoLabel.text = NCUtils.fileListSubtitle(size: item.size, date: item.date as Date)
        }

        // Icon or preview
        if item.directory {
            cell.fileImageView.image = UIImage(named: "folder")
        } else if item.hasPreview {
            cell.fileImageView.setPreview(forFileId: item.fileId, withWidth: 40, withHeight: 40, usingAccount: NCDatabaseManager.sharedInstance().activeAccount())
        } else {
            cell.fileImageView.image = UIImage(named: NCUtils.previewImage(forMimeType: item.contentType))
        }

        // Disclosure indicator
        cell.accessoryType = item.directory ? .disclosureIndicator : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else {
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }

        let selectedItemPath = "\(path)/\(item.fileName)"

        if item.directory {
            let directoryVC = DirectoryTableViewController(path: selectedItemPath,
                                                           inRoom: token,
                                                           andThread: threadId,
                                                           mode: mode,
                                                           fileTypeFilter: fileTypeFilter)
            self.navigationController?.pushViewController(directoryVC, animated: true)
        } else if mode == .browse {
            previewFile(item, at: selectedItemPath, cell: tableView.cellForRow(at: indexPath) as? DirectoryTableViewCell)
        } else {
            showConfirmationDialogForSharingItem(withPath: selectedItemPath, andName: item.fileName, isDirectory: false)
        }

        tableView.deselectRow(at: indexPath, animated: true)
    }

    // MARK: - Browse preview

    private func previewFile(_ item: NKFile, at path: String, cell: DirectoryTableViewCell?) {
        let account = NCDatabaseManager.sharedInstance().activeAccount()
        let fileId = item.fileId
        guard !fileId.isEmpty else {
            presentPreviewUnavailable()
            return
        }

        if let cell {
            let parameter = NCMessageFileParameter(dictionary: [
                "id": fileId,
                "name": item.fileName,
                "type": "file",
                "path": path,
                "mimetype": item.contentType,
                "size": item.size,
                "preview-available": item.hasPreview ? "yes" : "no"
            ])
            cell.fileParameter = parameter
        }

        let downloader = NCChatFileController(account: account)
        downloader.delegate = self
        downloader.downloadFile(withFileId: fileId)
    }

    private func presentPreviewUnavailable() {
        let alert = UIAlertController(title: NSLocalizedString("Unable to load file", comment: ""),
                                      message: NSLocalizedString("This file cannot be previewed.", comment: ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    func fileControllerDidLoadFile(_ fileController: NCChatFileController, with fileStatus: NCChatFileStatus) {
        DispatchQueue.main.async {
            if self.isPreviewControllerShown {
                return
            }

            guard let fileLocalPath = fileStatus.fileLocalPath else { return }

            self.previewControllerFilePath = fileLocalPath
            self.isPreviewControllerShown = true

            let fileExtension = URL(fileURLWithPath: fileLocalPath).pathExtension.lowercased()

            if VLCKitVideoViewController.supportedFileExtensions.contains(fileExtension) {
                let vlcViewController = VLCKitVideoViewController(filePath: fileLocalPath)
                vlcViewController.delegate = self
                vlcViewController.modalPresentationStyle = .fullScreen
                self.present(vlcViewController, animated: true)
                return
            }

            if fileExtension == "pkpass" {
                if let passData = try? Data(contentsOf: URL(fileURLWithPath: fileLocalPath)),
                   let pass = try? PKPass(data: passData),
                   let addPassVC = PKAddPassesViewController(pass: pass) {
                    self.present(addPassVC, animated: true)
                    self.isPreviewControllerShown = false
                    return
                }
            }

            let previewController = QLPreviewController()
            previewController.dataSource = self
            previewController.delegate = self
            self.present(previewController, animated: true)
        }
    }

    func fileControllerDidFailLoadingFile(_ fileController: NCChatFileController, withFileId fileId: String, withErrorDescription errorDescription: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: NSLocalizedString("Unable to load file", comment: ""),
                                          message: errorDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            self.present(alert, animated: true)
        }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        return FilePreviewItem(filePath: previewControllerFilePath)
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        isPreviewControllerShown = false
    }

    func vlckitVideoViewControllerDismissed(_ controller: VLCKitVideoViewController) {
        isPreviewControllerShown = false
    }
}
