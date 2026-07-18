//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Preset GB choices plus a custom limit entered in megabytes.
final class CacheLimitSettingsViewController: UITableViewController, UITextFieldDelegate {

    private let presetsBytes: [Int64] = [
        1 * 1024 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
        3 * 1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        10 * 1024 * 1024 * 1024
    ]

    private let minimumMegabytes: Int64 = 512
    private let maximumMegabytes: Int64 = 50 * 1024 // 50 GB

    private var selectedBytes: Int64
    private let onChange: (Int64) -> Void

    private lazy var megabytesField: UITextField = {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.textAlignment = .right
        field.placeholder = NSLocalizedString("MB", comment: "Megabytes unit for custom cache limit")
        field.delegate = self
        field.addTarget(self, action: #selector(megabytesChanged), for: .editingChanged)
        return field
    }()

    init(currentBytes: Int64, onChange: @escaping (Int64) -> Void) {
        self.selectedBytes = currentBytes
        self.onChange = onChange
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Cache limit", comment: "")
        NCAppBranding.styleViewController(self)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "preset")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "custom")
        megabytesField.text = "\(max(minimumMegabytes, selectedBytes / (1024 * 1024)))"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Save", comment: ""),
            style: .done,
            target: self,
            action: #selector(saveCustom)
        )
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? presetsBytes.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? NSLocalizedString("Presets", comment: "Cache limit preset section")
            : NSLocalizedString("Custom", comment: "Cache limit custom section")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return NSLocalizedString(
                "When cached chat files exceed 95% of this limit, the oldest files are removed until usage is at 80%.",
                comment: "Footer on cache limit presets"
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Enter a size in megabytes (minimum %lld MB).", comment: "Footer for custom cache limit"),
            minimumMegabytes
        )
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "preset", for: indexPath)
            let bytes = presetsBytes[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = MediaUploadDiskStore.formatCacheBytes(bytes)
            config.secondaryText = NSLocalizedString(
                "Purges oldest files above 95% down to 80%",
                comment: "Subtitle for cache size option"
            )
            cell.contentConfiguration = config
            cell.accessoryType = bytes == selectedBytes ? .checkmark : .none
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "custom", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = NSLocalizedString("Size", comment: "Custom cache limit size row")
        cell.contentConfiguration = config
        megabytesField.frame = CGRect(x: 0, y: 0, width: 120, height: 32)
        cell.accessoryView = megabytesField
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else {
            megabytesField.becomeFirstResponder()
            return
        }
        selectedBytes = presetsBytes[indexPath.row]
        megabytesField.text = "\(selectedBytes / (1024 * 1024))"
        apply(selectedBytes)
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Actions

    @objc private func megabytesChanged() {
        // Checkmark clears when editing a custom value that isn't a preset.
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }

    @objc private func saveCustom() {
        guard let text = megabytesField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let megabytes = Int64(text) else {
            presentInvalidAlert()
            return
        }
        let clamped = min(maximumMegabytes, max(minimumMegabytes, megabytes))
        selectedBytes = clamped * 1024 * 1024
        megabytesField.text = "\(clamped)"
        apply(selectedBytes)
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }

    private func apply(_ bytes: Int64) {
        onChange(bytes)
    }

    private func presentInvalidAlert() {
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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveCustom()
        return true
    }
}
