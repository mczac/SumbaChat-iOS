//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// TestFlight/debug controls for Low/Medium/High compression and Automatic caps.
final class MediaUploadCompressionDebugViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case engine
        case caps
        case low
        case medium
        case high
        case actions
    }

    /// Rows for a profile when engine is AVAssetWriter.
    private enum WriterProfileRow: Int, CaseIterable {
        case jpegQuality
        case imageMaxEdge
        case videoRate
        case videoMaxMB
        case videoMaxEdge
        case videoFPS
    }

    /// Rows for a profile when engine is ExportSession — video is preset-only.
    private enum PresetProfileRow: Int, CaseIterable {
        case jpegQuality
        case imageMaxEdge
        case exportPreset
    }

    private var settings: MediaUploadDebugSettings

    private var usesWriter: Bool { settings.usesAssetWriter }

    init() {
        self.settings = MediaUploadDebugSettings.shared()
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NCAppBranding.styleViewController(self)
        title = NSLocalizedString("Compression Debug", comment: "")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Save", comment: ""),
                                                            style: .done,
                                                            target: self,
                                                            action: #selector(savePressed))
    }

    @objc private func savePressed() {
        settings.save()
        MediaUploadDebugSettings.invalidateCache()
        settings = MediaUploadDebugSettings.shared()
        let alert = UIAlertController(title: NSLocalizedString("Saved", comment: ""),
                                      message: NSLocalizedString("Compression debug settings apply to the next Send.", comment: ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .engine: return 1
        case .caps: return 2
        case .low, .medium, .high:
            return usesWriter ? WriterProfileRow.allCases.count : PresetProfileRow.allCases.count
        case .actions: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .engine: return NSLocalizedString("Video engine", comment: "")
        case .caps: return NSLocalizedString("Automatic caps", comment: "")
        case .low: return NSLocalizedString("Low compression", comment: "")
        case .medium: return NSLocalizedString("Medium compression", comment: "")
        case .high: return NSLocalizedString("High compression", comment: "")
        case .actions: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .engine:
            return NSLocalizedString("AVAssetWriter: bitrate, size, FPS. ExportSession: pick an Apple preset per level (rate/size/FPS knobs hidden).", comment: "")
        case .caps:
            return NSLocalizedString("Per-file max (X) and package max (Y). Package total always wins. Values in megabytes.", comment: "")
        case .low, .medium, .high:
            if usesWriter {
                return NSLocalizedString("Video rate is MB/s. Max MB caps long clips. Image settings always apply.", comment: "")
            }
            return NSLocalizedString("Video uses the ExportSession preset only. Image JPEG settings still apply.", comment: "")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.textColor = .label

        switch Section(rawValue: indexPath.section)! {
        case .engine:
            cell.textLabel?.text = usesWriter ? "AVAssetWriter (precise)" : "AVAssetExportSession (presets)"
            cell.accessoryType = .disclosureIndicator
        case .caps:
            if indexPath.row == 0 {
                cell.textLabel?.text = String(format: "Per-file max X: %.1f MB", Double(settings.perFileMaxBytes) / 1_048_576)
            } else {
                cell.textLabel?.text = String(format: "Package max Y: %.1f MB", Double(settings.packageMaxBytes) / 1_048_576)
            }
            cell.accessoryType = .disclosureIndicator
        case .low:
            configureProfileRow(cell, profile: settings.low, row: indexPath.row)
        case .medium:
            configureProfileRow(cell, profile: settings.medium, row: indexPath.row)
        case .high:
            configureProfileRow(cell, profile: settings.high, row: indexPath.row)
        case .actions:
            cell.textLabel?.text = NSLocalizedString("Reset to defaults", comment: "")
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    private func configureProfileRow(_ cell: UITableViewCell, profile: MediaUploadProfileConfig, row: Int) {
        cell.accessoryType = .disclosureIndicator
        if usesWriter {
            guard let writerRow = WriterProfileRow(rawValue: row) else {
                cell.textLabel?.text = nil
                return
            }
            switch writerRow {
            case .jpegQuality:
                cell.textLabel?.text = "JPEG quality: \(profile.imageJPEGQuality)"
            case .imageMaxEdge:
                cell.textLabel?.text = "Image max edge: \(profile.imageMaxDimension) px"
            case .videoRate:
                cell.textLabel?.text = String(format: "Video rate: %.3f MB/s", profile.videoRateMBps)
            case .videoMaxMB:
                cell.textLabel?.text = String(format: "Video max: %.1f MB", Double(profile.videoMaxBytes) / 1_048_576)
            case .videoMaxEdge:
                cell.textLabel?.text = "Video max edge: \(profile.videoMaxEdge) px"
            case .videoFPS:
                cell.textLabel?.text = String(format: "Video FPS: %.0f", profile.videoFPS)
            }
        } else {
            guard let presetRow = PresetProfileRow(rawValue: row) else {
                cell.textLabel?.text = nil
                return
            }
            switch presetRow {
            case .jpegQuality:
                cell.textLabel?.text = "JPEG quality: \(profile.imageJPEGQuality)"
            case .imageMaxEdge:
                cell.textLabel?.text = "Image max edge: \(profile.imageMaxDimension) px"
            case .exportPreset:
                cell.textLabel?.text = "Video preset: \(readablePreset(profile.exportPreset))"
            }
        }
    }

    private func readablePreset(_ key: String) -> String {
        switch key {
        case "low": return "LowQuality"
        case "medium": return "MediumQuality"
        case "high": return "HighestQuality"
        case "480p": return "640×480"
        case "540p": return "960×540"
        case "720p": return "1280×720"
        case "1080p": return "1920×1080"
        case "2160p": return "3840×2160"
        default: return key
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .engine:
            presentEnginePicker()
        case .caps:
            if indexPath.row == 0 {
                promptDouble(title: "Per-file max X (MB)", current: Double(settings.perFileMaxBytes) / 1_048_576) { mb in
                    self.settings.perFileMaxBytes = Int64(mb * 1_048_576)
                    self.tableView.reloadData()
                }
            } else {
                promptDouble(title: "Package max Y (MB)", current: Double(settings.packageMaxBytes) / 1_048_576) { mb in
                    self.settings.packageMaxBytes = Int64(mb * 1_048_576)
                    self.tableView.reloadData()
                }
            }
        case .low:
            editProfile(\.low, row: indexPath.row)
        case .medium:
            editProfile(\.medium, row: indexPath.row)
        case .high:
            editProfile(\.high, row: indexPath.row)
        case .actions:
            MediaUploadDebugSettings.resetToDefaults()
            settings = MediaUploadDebugSettings.shared()
            tableView.reloadData()
        }
    }

    private func editProfile(_ keyPath: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>, row: Int) {
        var profile = settings[keyPath: keyPath]
        if usesWriter {
            guard let writerRow = WriterProfileRow(rawValue: row) else { return }
            switch writerRow {
            case .jpegQuality:
                promptInt(title: "JPEG quality (1–100)", current: profile.imageJPEGQuality) {
                    profile.imageJPEGQuality = min(100, max(1, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .imageMaxEdge:
                promptInt(title: "Image max edge (px)", current: profile.imageMaxDimension) {
                    profile.imageMaxDimension = min(8192, max(320, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .videoRate:
                promptDouble(title: "Video rate (MB/s)", current: profile.videoRateMBps) {
                    profile.videoRateMBps = max(0.01, $0)
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .videoMaxMB:
                promptDouble(title: "Video max (MB)", current: Double(profile.videoMaxBytes) / 1_048_576) {
                    profile.videoMaxBytes = Int64(max(1, $0) * 1_048_576)
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .videoMaxEdge:
                promptInt(title: "Video max edge (px)", current: profile.videoMaxEdge) {
                    profile.videoMaxEdge = min(3840, max(320, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .videoFPS:
                promptDouble(title: "Video FPS", current: profile.videoFPS) {
                    profile.videoFPS = min(60, max(1, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            }
        } else {
            guard let presetRow = PresetProfileRow(rawValue: row) else { return }
            switch presetRow {
            case .jpegQuality:
                promptInt(title: "JPEG quality (1–100)", current: profile.imageJPEGQuality) {
                    profile.imageJPEGQuality = min(100, max(1, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .imageMaxEdge:
                promptInt(title: "Image max edge (px)", current: profile.imageMaxDimension) {
                    profile.imageMaxDimension = min(8192, max(320, $0))
                    self.settings[keyPath: keyPath] = profile
                    self.tableView.reloadData()
                }
            case .exportPreset:
                presentPresetPicker(for: keyPath)
            }
        }
    }

    private func presentEnginePicker() {
        let sheet = UIAlertController(title: NSLocalizedString("Video engine", comment: ""), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "AVAssetWriter", style: .default) { _ in
            self.settings.videoEngine = .assetWriter
            self.tableView.reloadData()
        })
        sheet.addAction(UIAlertAction(title: "AVAssetExportSession", style: .default) { _ in
            self.settings.videoEngine = .exportSession
            self.tableView.reloadData()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: Section.engine.rawValue))
        }
        present(sheet, animated: true)
    }

    private func presentPresetPicker(for keyPath: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>) {
        let presets: [(String, String)] = [
            ("low", "LowQuality"),
            ("medium", "MediumQuality"),
            ("high", "HighestQuality"),
            ("480p", "640×480"),
            ("540p", "960×540"),
            ("720p", "1280×720"),
            ("1080p", "1920×1080"),
            ("2160p", "3840×2160")
        ]
        let sheet = UIAlertController(title: "Video preset", message: nil, preferredStyle: .actionSheet)
        for (key, title) in presets {
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                var profile = self.settings[keyPath: keyPath]
                profile.exportPreset = key
                self.settings[keyPath: keyPath] = profile
                self.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(sheet, animated: true)
    }

    private func promptInt(title: String, current: Int, apply: @escaping (Int) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.text = "\(current)" }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
            if let text = alert.textFields?.first?.text, let value = Int(text) {
                apply(value)
            }
        })
        present(alert, animated: true)
    }

    private func promptDouble(title: String, current: Double, apply: @escaping (Double) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .decimalPad; $0.text = String(format: "%g", current) }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
            if let text = alert.textFields?.first?.text, let value = Double(text) {
                apply(value)
            }
        })
        present(alert, animated: true)
    }
}
