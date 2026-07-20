//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

class LogfilesTableViewController: UITableViewController {

    private var logfiles: [URL] = []

    private let cellIdentifier = "LogfileCellIdentifier"

    private lazy var selectBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Select", comment: ""), style: .plain, target: self, action: #selector(selectButtonPressed))
    private lazy var exportBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(exportButtonPressed))

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NCAppBranding.styleViewController(self)

        self.navigationItem.title = NSLocalizedString("Logs", comment: "")

        self.tableView.register(SubtitleTableViewCell.self, forCellReuseIdentifier: cellIdentifier)
        self.tableView.allowsMultipleSelectionDuringEditing = true

        // Prunes files older than NCLog.retentionDays, then lists what remains.
        self.logfiles = NCLog.getLogfiles()

        if !logfiles.isEmpty {
            self.navigationItem.rightBarButtonItem = selectBarButtonItem
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String.localizedStringWithFormat(
            NSLocalizedString("Logs are kept for %d days, then deleted automatically.", comment: "Diagnostics logs retention footer"),
            NCLog.retentionDays
        )
    }

    // MARK: - Editing / selection

    @objc func selectButtonPressed() {
        setEditing(!isEditing, animated: true)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)

        if editing {
            selectBarButtonItem.title = NSLocalizedString("Cancel", comment: "")
        } else {
            selectBarButtonItem.title = NSLocalizedString("Select", comment: "")
        }

        updateExportButton()
    }

    private func updateExportButton() {
        let selectedCount = tableView.indexPathsForSelectedRows?.count ?? 0

        // Offer the export action next to the cancel button once at least one logfile is selected
        if isEditing, selectedCount > 0 {
            self.navigationItem.rightBarButtonItems = [selectBarButtonItem, exportBarButtonItem]
        } else {
            self.navigationItem.rightBarButtonItems = [selectBarButtonItem]
        }
    }

    @objc func exportButtonPressed() {
        guard let selectedIndexPaths = tableView.indexPathsForSelectedRows, !selectedIndexPaths.isEmpty else { return }

        let selectedFiles = selectedIndexPaths.map { logfiles[$0.row] }

        let activityViewController = UIActivityViewController(activityItems: selectedFiles, applicationActivities: nil)
        activityViewController.popoverPresentationController?.barButtonItem = exportBarButtonItem
        activityViewController.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed {
                self?.setEditing(false, animated: true)
            }
        }

        self.present(activityViewController, animated: true)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return logfiles.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath)
        let logfile = logfiles[indexPath.row]

        cell.textLabel?.text = logfile.lastPathComponent

        var subtitleComponents: [String] = []

        if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: logfile.path) {
            if let modificationDate = fileAttributes[.modificationDate] as? Date {
                subtitleComponents.append(NCUtils.readableDate(fromDate: modificationDate))
            }

            if let fileSize = fileAttributes[.size] as? Int64 {
                subtitleComponents.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
            }
        }

        cell.detailTextLabel?.text = subtitleComponents.isEmpty ? nil : subtitleComponents.joined(separator: " · ")

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing {
            updateExportButton()
            return
        }

        tableView.deselectRow(at: indexPath, animated: true)
        let viewer = LogfileViewerViewController(fileURL: logfiles[indexPath.row])
        navigationController?.pushViewController(viewer, animated: true)
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditing {
            updateExportButton()
        }
    }
}
