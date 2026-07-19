//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import NextcloudKit

class DirectoryTableViewController: UITableViewController, UISearchResultsUpdating {

    private enum FileTypeFilter: Int {
        case all
        case video
        case audio
        case documents

        var title: String {
            switch self {
            case .all:
                return NSLocalizedString("All", comment: "File type filter: show all files")
            case .video:
                return NSLocalizedString("Video", comment: "File type filter: videos only")
            case .audio:
                return NSLocalizedString("Audio", comment: "File type filter: audio only")
            case .documents:
                return NSLocalizedString("Documents", comment: "File type filter: documents only")
            }
        }

        var systemImageName: String {
            switch self {
            case .all:
                return "square.grid.2x2"
            case .video:
                return "video"
            case .audio:
                return "waveform"
            case .documents:
                return "doc"
            }
        }
    }

    private let path: String
    private let token: String
    private let threadId: Int

    private var userHomePath = ""
    /// Full folder listing from the server (unfiltered).
    private var allItemsInDirectory: [NKFile] = []
    /// Sorted + type/name-filtered rows shown in the table.
    private var itemsInDirectory: [NKFile] = []
    private var fileTypeFilter: FileTypeFilter
    private var nameSearchText: String = ""
    private var sortingButton: UIBarButtonItem?
    private var filterButton: UIBarButtonItem?
    private var searchController: UISearchController!
    private let directoryBackgroundView = PlaceholderView()
    private let sharingFileView = UIActivityIndicatorView()

    init(path: String, inRoom token: String, andThread threadId: Int, fileTypeFilter: FileTypeFilter = .all) {
        self.path = path
        self.token = token
        self.threadId = threadId
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
        showConfirmationDialogForSharingItem(withPath: path, andName: (path as NSString).lastPathComponent)
    }

    private func addMenuToSortingButton() {
        let preferredSorting = NCSettingsController.sharedInstance().getPreferredFileSorting()

        let alphabeticalAction = UIAction(title: NSLocalizedString("Alphabetical order", comment: ""), image: UIImage(systemName: "character.square")) { [weak self] _ in
            NCSettingsController.sharedInstance().setPreferredFileSorting(.alphabeticalSorting)
            self?.applyFilterAndSort()
        }

        alphabeticalAction.state = preferredSorting == .alphabeticalSorting ? .on : .off

        let modificationDateAction = UIAction(title: NSLocalizedString("Modification date", comment: ""), image: UIImage(systemName: "clock")) { [weak self] _ in
            NCSettingsController.sharedInstance().setPreferredFileSorting(.modificationDateSorting)
            self?.applyFilterAndSort()
        }

        modificationDateAction.state = preferredSorting == .modificationDateSorting ? .on : .off

        sortingButton?.menu = UIMenu(children: [alphabeticalAction, modificationDateAction])
    }

    private func addMenuToFilterButton() {
        let filters: [FileTypeFilter] = [.all, .video, .audio, .documents]
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

        var filtered = allItemsInDirectory.filter { item in
            if !query.isEmpty,
               item.fileName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }

            // Folders stay visible for navigation (unless excluded by name search above).
            if item.directory {
                return true
            }

            switch fileTypeFilter {
            case .all:
                return true
            case .video:
                return NCUtils.isVideo(fileType: item.contentType)
            case .audio:
                return NCUtils.isAudio(fileType: item.contentType)
            case .documents:
                return NCUtils.isDocument(fileType: item.contentType)
            }
        }

        if NCSettingsController.sharedInstance().getPreferredFileSorting() == .alphabeticalSorting {
            filtered.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        } else {
            filtered.sort { ($0.date as Date) > ($1.date as Date) }
        }

        itemsInDirectory = filtered
        addMenuToSortingButton()
        addMenuToFilterButton()
        updatePlaceholderVisibility()
        tableView.reloadData()
    }

    private func updatePlaceholderVisibility() {
        let hasRows = !itemsInDirectory.isEmpty
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

            let navigationLogo = UIImage(systemName: "house")
            let navigationImageView = UIImageView(image: navigationLogo)
            navigationImageView.image = navigationImageView.image?.withRenderingMode(.alwaysTemplate)
            if #available(iOS 26.0, *) {
                navigationImageView.tintColor = .label
            } else {
                navigationImageView.tintColor = NCAppBranding.themeTextColor()
            }
            self.navigationItem.titleView = navigationImageView

            self.navigationItem.backBarButtonItem = UIBarButtonItem(image: navigationLogo, style: .plain, target: nil, action: nil)
            // Other directories
        } else {
            let shareButton = UIBarButtonItem(image: UIImage(named: "sharing"), style: .plain, target: self, action: #selector(shareButtonPressed))
            self.navigationItem.rightBarButtonItems = [sortingButton, filterButton, shareButton]

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

    private func showConfirmationDialogForSharingItem(withPath path: String, andName name: String) {
        let confirmDialog = UIAlertController(title: name,
                                              message: String(format: NSLocalizedString("Do you want to share '%@' in the conversation?", comment: ""), name),
                                              preferredStyle: .alert)
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
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return itemsInDirectory.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return DirectoryTableViewCell.cellHeight
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = itemsInDirectory[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: DirectoryTableViewCell.identifier) as? DirectoryTableViewCell ??
                   DirectoryTableViewCell(style: .default, reuseIdentifier: DirectoryTableViewCell.identifier)

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
        let item = itemsInDirectory[indexPath.row]
        let selectedItemPath = "\(path)/\(item.fileName)"

        if item.directory {
            let directoryVC = DirectoryTableViewController(path: selectedItemPath,
                                                           inRoom: token,
                                                           andThread: threadId,
                                                           fileTypeFilter: fileTypeFilter)
            self.navigationController?.pushViewController(directoryVC, animated: true)
        } else {
            showConfirmationDialogForSharingItem(withPath: selectedItemPath, andName: item.fileName)
        }

        tableView.deselectRow(at: indexPath, animated: true)
    }
}
