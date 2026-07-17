//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// TestFlight/debug controls for Low/Medium/High compression and Automatic caps.
final class MediaUploadCompressionDebugViewController: UITableViewController, DetailedOptionsSelectorTableViewControllerDelegate {

    private enum Section: Int, CaseIterable {
        case engine
        case caps
        case lowPhoto
        case lowVideo
        case mediumPhoto
        case mediumVideo
        case highPhoto
        case highVideo
        case actions
    }

    private enum PhotoRow: Int, CaseIterable {
        case jpegQuality
        case imageMaxEdge
    }

    private enum PresetVideoRow: Int, CaseIterable {
        case exportPreset
    }

    private enum WriterVideoRow: Int, CaseIterable {
        case videoRate
        case videoMaxMB
        case videoMaxEdge
        case videoFPS
    }

    private var profileVideoRowCount: Int {
        usesWriter ? WriterVideoRow.allCases.count : PresetVideoRow.allCases.count
    }

    private var settings: MediaUploadDebugSettings
    private var pendingPresetProfile: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>?
    private var pendingChoiceHandler: ((String) -> Void)?

    private var usesWriter: Bool { settings.usesAssetWriter }

    private let presetSenderId = "exportPreset.pick"
    private let choiceSenderId = "choice.pick"

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
        title = NSLocalizedString("Media Compression Settings", comment: "")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Clear a Cancel item that older DetailedOptionsSelector builds may have
        // written onto this VC via navigationBar.topItem (broke system Back).
        navigationItem.leftBarButtonItem = nil
        let hasSelector = navigationController?.viewControllers.contains(where: { $0 is DetailedOptionsSelectorTableViewController }) ?? false
        if !hasSelector {
            pendingPresetProfile = nil
            pendingChoiceHandler = nil
        }
    }

    /// Apple Settings style: changing a value writes it immediately (no Save).
    private func persistAndReload() {
        settings.save()
        MediaUploadDebugSettings.invalidateCache()
        settings = MediaUploadDebugSettings.shared()
        tableView.reloadData()
    }

    private func profileKeyPath(for section: Section) -> ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>? {
        switch section {
        case .lowPhoto, .lowVideo: return \.low
        case .mediumPhoto, .mediumVideo: return \.medium
        case .highPhoto, .highVideo: return \.high
        default: return nil
        }
    }

    private func isPhotoSection(_ section: Section) -> Bool {
        switch section {
        case .lowPhoto, .mediumPhoto, .highPhoto: return true
        default: return false
        }
    }

    private func isVideoSection(_ section: Section) -> Bool {
        switch section {
        case .lowVideo, .mediumVideo, .highVideo: return true
        default: return false
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .engine: return 2
        case .caps: return 2
        case .lowPhoto, .mediumPhoto, .highPhoto:
            return PhotoRow.allCases.count
        case .lowVideo, .mediumVideo, .highVideo:
            return profileVideoRowCount
        case .actions: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .engine: return NSLocalizedString("Video engine", comment: "")
        case .caps: return NSLocalizedString("Automatic caps", comment: "")
        case .lowPhoto: return NSLocalizedString("Low compression", comment: "")
        case .mediumPhoto: return NSLocalizedString("Medium compression", comment: "")
        case .highPhoto: return NSLocalizedString("High compression", comment: "")
        case .lowVideo, .mediumVideo, .highVideo, .actions: return nil
        }
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        applyAppleStyleSectionHeader(view, title: self.tableView(tableView, titleForHeaderInSection: section))
    }

    /// Keep photo + video cards visually paired: no title on video, tight gap after photo.
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section = Section(rawValue: section)!
        if isVideoSection(section) {
            return 8
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if isVideoSection(Section(rawValue: section)!) {
            return UIView()
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        let section = Section(rawValue: section)!
        if isPhotoSection(section) {
            return 8
        }
        if isVideoSection(section) {
            return .leastNormalMagnitude
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let section = Section(rawValue: section)!
        if isPhotoSection(section) || isVideoSection(section) {
            return UIView()
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .engine:
            return NSLocalizedString(
                "Presets use Apple export presets. Bitrate uses AVAssetWriter with rate, size, and FPS controls.",
                comment: ""
            )
        case .caps:
            return NSLocalizedString(
                "These limits apply only when Automatic compression is selected. Per-file and package totals are in megabytes; package total always wins.",
                comment: ""
            )
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = Section(rawValue: indexPath.section)!
        let isEngineRow = section == .engine

        // value1 / subtitle styles are fixed at creation — use dedicated reuse ids.
        let cell: UITableViewCell
        if isEngineRow {
            cell = tableView.dequeueOrCreateCell(withIdentifier: "subtitleCell", style: .subtitle)
        } else if section == .actions {
            cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        } else {
            cell = tableView.dequeueOrCreateCell(withIdentifier: "valueCell", style: .value1)
        }

        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.text = nil
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2

        switch section {
        case .engine:
            if indexPath.row == 0 {
                cell.textLabel?.text = NSLocalizedString("Presets", comment: "")
                cell.detailTextLabel?.text = "AVAssetExportSession"
                cell.accessoryType = usesWriter ? .none : .checkmark
            } else {
                cell.textLabel?.text = NSLocalizedString("Bitrate", comment: "")
                cell.detailTextLabel?.text = "AVAssetWriter"
                cell.accessoryType = usesWriter ? .checkmark : .none
            }
        case .caps:
            if indexPath.row == 0 {
                cell.textLabel?.text = NSLocalizedString("Per file max size", comment: "")
                cell.detailTextLabel?.text = String(format: "%.1f MB", Double(settings.perFileMaxBytes) / 1_048_576)
            } else {
                cell.textLabel?.text = NSLocalizedString("Package max size", comment: "")
                cell.detailTextLabel?.text = String(format: "%.1f MB", Double(settings.packageMaxBytes) / 1_048_576)
            }
            cell.accessoryType = .disclosureIndicator
        case .lowPhoto, .mediumPhoto, .highPhoto:
            guard let keyPath = profileKeyPath(for: section) else { break }
            configurePhotoRow(cell, profile: settings[keyPath: keyPath], row: indexPath.row)
        case .lowVideo, .mediumVideo, .highVideo:
            guard let keyPath = profileKeyPath(for: section) else { break }
            configureVideoRow(cell, profile: settings[keyPath: keyPath], row: indexPath.row)
        case .actions:
            cell.textLabel?.text = NSLocalizedString("Reset to defaults", comment: "")
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    private func configurePhotoRow(_ cell: UITableViewCell, profile: MediaUploadProfileConfig, row: Int) {
        cell.accessoryType = .disclosureIndicator
        guard let photoRow = PhotoRow(rawValue: row) else {
            cell.textLabel?.text = nil
            return
        }
        switch photoRow {
        case .jpegQuality:
            cell.textLabel?.text = NSLocalizedString("JPEG quality", comment: "")
            cell.detailTextLabel?.text = "\(profile.imageJPEGQuality)"
        case .imageMaxEdge:
            cell.textLabel?.text = NSLocalizedString("Image max edge", comment: "")
            cell.detailTextLabel?.text = "\(profile.imageMaxDimension) px"
        }
    }

    private func configureVideoRow(_ cell: UITableViewCell, profile: MediaUploadProfileConfig, row: Int) {
        cell.accessoryType = .disclosureIndicator
        if usesWriter {
            guard let videoRow = WriterVideoRow(rawValue: row) else {
                cell.textLabel?.text = nil
                return
            }
            switch videoRow {
            case .videoRate:
                cell.textLabel?.text = NSLocalizedString("Video rate", comment: "")
                cell.detailTextLabel?.text = String(format: "%.3f MB/s", profile.videoRateMBps)
            case .videoMaxMB:
                cell.textLabel?.text = NSLocalizedString("Video max", comment: "")
                cell.detailTextLabel?.text = String(format: "%.1f MB", Double(profile.videoMaxBytes) / 1_048_576)
            case .videoMaxEdge:
                cell.textLabel?.text = NSLocalizedString("Video max edge", comment: "")
                cell.detailTextLabel?.text = "\(profile.videoMaxEdge) px"
            case .videoFPS:
                cell.textLabel?.text = NSLocalizedString("Video FPS", comment: "")
                cell.detailTextLabel?.text = String(format: "%.0f", profile.videoFPS)
            }
        } else {
            cell.textLabel?.text = NSLocalizedString("Video preset", comment: "")
            cell.detailTextLabel?.text = MediaUploadDebugSettings.readableAVExportPreset(profile.exportPreset)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let section = Section(rawValue: indexPath.section)!
        switch section {
        case .engine:
            let chooseWriter = indexPath.row == 1
            guard chooseWriter != usesWriter else { return }
            settings.videoEngine = chooseWriter ? .assetWriter : .exportSession
            persistAndReload()
        case .caps:
            if indexPath.row == 0 {
                pushMegabyteChoices(
                    title: NSLocalizedString("Per file max size", comment: ""),
                    currentMB: Double(settings.perFileMaxBytes) / 1_048_576,
                    values: [10, 20, 25, 30, 40, 50, 75, 100, 150, 200, 250, 500]
                ) { mb in
                    self.settings.perFileMaxBytes = Int64(mb * 1_048_576)
                    self.persistAndReload()
                }
            } else {
                pushMegabyteChoices(
                    title: NSLocalizedString("Package max size", comment: ""),
                    currentMB: Double(settings.packageMaxBytes) / 1_048_576,
                    values: [25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000]
                ) { mb in
                    self.settings.packageMaxBytes = Int64(mb * 1_048_576)
                    self.persistAndReload()
                }
            }
        case .lowPhoto, .mediumPhoto, .highPhoto:
            guard let keyPath = profileKeyPath(for: section) else { return }
            editPhoto(keyPath, row: indexPath.row)
        case .lowVideo, .mediumVideo, .highVideo:
            guard let keyPath = profileKeyPath(for: section) else { return }
            editVideo(keyPath, row: indexPath.row)
        case .actions:
            MediaUploadDebugSettings.resetToDefaults()
            settings = MediaUploadDebugSettings.shared()
            tableView.reloadData()
        }
    }

    private func editPhoto(_ keyPath: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>, row: Int) {
        let profile = settings[keyPath: keyPath]
        guard let photoRow = PhotoRow(rawValue: row) else { return }
        switch photoRow {
        case .jpegQuality:
            pushIntChoices(title: "JPEG quality", current: profile.imageJPEGQuality,
                           values: [40, 50, 60, 70, 75, 80, 85, 90, 95, 100],
                           unit: nil) { value in
                var updated = self.settings[keyPath: keyPath]
                updated.imageJPEGQuality = min(100, max(1, value))
                self.settings[keyPath: keyPath] = updated
                self.persistAndReload()
            }
        case .imageMaxEdge:
            pushIntChoices(title: "Image max edge", current: profile.imageMaxDimension,
                           values: [640, 960, 1280, 1600, 1920, 2560, 3840, 4096, 8192],
                           unit: "px") { value in
                var updated = self.settings[keyPath: keyPath]
                updated.imageMaxDimension = min(8192, max(320, value))
                self.settings[keyPath: keyPath] = updated
                self.persistAndReload()
            }
        }
    }

    private func editVideo(_ keyPath: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>, row: Int) {
        let profile = settings[keyPath: keyPath]
        if usesWriter {
            guard let videoRow = WriterVideoRow(rawValue: row) else { return }
            switch videoRow {
            case .videoRate:
                pushDoubleChoices(title: "Video rate", current: profile.videoRateMBps,
                                  values: [0.05, 0.1, 0.15, 0.25, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0],
                                  unit: "MB/s", format: "%.3f") { value in
                    var updated = self.settings[keyPath: keyPath]
                    updated.videoRateMBps = max(0.01, value)
                    self.settings[keyPath: keyPath] = updated
                    self.persistAndReload()
                }
            case .videoMaxMB:
                pushMegabyteChoices(title: "Video max size",
                                    currentMB: Double(profile.videoMaxBytes) / 1_048_576,
                                    values: [5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200]) { mb in
                    var updated = self.settings[keyPath: keyPath]
                    updated.videoMaxBytes = Int64(max(1, mb) * 1_048_576)
                    self.settings[keyPath: keyPath] = updated
                    self.persistAndReload()
                }
            case .videoMaxEdge:
                pushIntChoices(title: "Video max edge", current: profile.videoMaxEdge,
                               values: [480, 640, 720, 960, 1080, 1280, 1440, 1920, 2560, 3840],
                               unit: "px") { value in
                    var updated = self.settings[keyPath: keyPath]
                    updated.videoMaxEdge = min(3840, max(320, value))
                    self.settings[keyPath: keyPath] = updated
                    self.persistAndReload()
                }
            case .videoFPS:
                pushDoubleChoices(title: "Video FPS", current: profile.videoFPS,
                                  values: [15, 20, 24, 25, 30, 48, 50, 60],
                                  unit: "fps", format: "%.0f") { value in
                    var updated = self.settings[keyPath: keyPath]
                    updated.videoFPS = min(60, max(1, value))
                    self.settings[keyPath: keyPath] = updated
                    self.persistAndReload()
                }
            }
        } else {
            presentPresetPicker(for: keyPath)
        }
    }

    // MARK: - Pushed choice sheets

    private func pushIntChoices(title: String, current: Int, values: [Int], unit: String?, apply: @escaping (Int) -> Void) {
        var list = values
        if !list.contains(current) {
            list.append(current)
            list.sort()
        }
        let choices: [(String, String, String?)] = list.map { value in
            let label = unit.map { "\(value) \($0)" } ?? "\(value)"
            return ("\(value)", label, nil)
        }
        pushChoices(title: title, selectedId: "\(current)", choices: choices) { id in
            guard let value = Int(id) else { return }
            apply(value)
        }
    }

    private func pushDoubleChoices(title: String, current: Double, values: [Double], unit: String, format: String, apply: @escaping (Double) -> Void) {
        var list = values
        if !list.contains(where: { abs($0 - current) < 0.0001 }) {
            list.append(current)
            list.sort()
        }
        let choices: [(String, String, String?)] = list.map { value in
            let id = String(format: format, value)
            return (id, "\(id) \(unit)", nil)
        }
        let selectedId = String(format: format, current)
        pushChoices(title: title, selectedId: selectedId, choices: choices) { id in
            guard let value = Double(id) else { return }
            apply(value)
        }
    }

    private func pushMegabyteChoices(title: String, currentMB: Double, values: [Double], apply: @escaping (Double) -> Void) {
        pushDoubleChoices(title: title, current: currentMB, values: values, unit: "MB", format: "%.1f", apply: apply)
    }

    private func pushChoices(title: String,
                             selectedId: String,
                             choices: [(id: String, title: String, subtitle: String?)],
                             apply: @escaping (String) -> Void) {
        pendingChoiceHandler = apply
        pendingPresetProfile = nil
        let options: [DetailedOption] = choices.map { id, title, subtitle in
            let option = DetailedOption()
            option.identifier = id
            option.title = title
            option.subtitle = subtitle
            option.selected = id == selectedId
            return option
        }
        guard let selector = DetailedOptionsSelectorTableViewController(options: options,
                                                                        forSenderIdentifier: choiceSenderId,
                                                                        andStyle: .insetGrouped) else { return }
        selector.title = title
        selector.delegate = self
        navigationController?.pushViewController(selector, animated: true)
    }

    private func presentPresetPicker(for keyPath: ReferenceWritableKeyPath<MediaUploadDebugSettings, MediaUploadProfileConfig>) {
        pendingChoiceHandler = nil
        pendingPresetProfile = keyPath
        let current = settings[keyPath: keyPath].exportPreset
        let presets = ["low", "medium", "high", "480p", "540p", "720p", "1080p", "2160p"]
        let options: [DetailedOption] = presets.map { key in
            let option = DetailedOption()
            option.identifier = key
            option.title = MediaUploadDebugSettings.readableAVExportPreset(key)
            option.subtitle = MediaUploadDebugSettings.guestimatedExportPresetLabel(key)
            option.selected = key == current
            return option
        }
        guard let selector = DetailedOptionsSelectorTableViewController(options: options,
                                                                        forSenderIdentifier: presetSenderId,
                                                                        andStyle: .insetGrouped) else { return }
        selector.title = NSLocalizedString("Video preset", comment: "")
        selector.footerText = NSLocalizedString(
            "Shows the Apple AVAssetExportPreset constant. Low / Medium / High compression are aggressiveness levels — not the same as LowQuality / MediumQuality / HighestQuality.",
            comment: ""
        )
        selector.delegate = self
        navigationController?.pushViewController(selector, animated: true)
    }

    func detailedOptionsSelector(_ viewController: DetailedOptionsSelectorTableViewController!,
                                 didSelectOptionWithIdentifier option: DetailedOption!) {
        guard let option, let id = option.identifier else { return }
        let senderId = viewController.senderId ?? ""

        if senderId == presetSenderId, let keyPath = pendingPresetProfile {
            var profile = settings[keyPath: keyPath]
            profile.exportPreset = id
            settings[keyPath: keyPath] = profile
            pendingPresetProfile = nil
            persistAndReload()
        } else if senderId == choiceSenderId, let handler = pendingChoiceHandler {
            pendingChoiceHandler = nil
            handler(id)
        }

        navigationController?.popViewController(animated: true)
    }

    func detailedOptionsSelectorWasCancelled(_ viewController: DetailedOptionsSelectorTableViewController!) {
        pendingPresetProfile = nil
        pendingChoiceHandler = nil
        navigationController?.popViewController(animated: true)
    }
}
