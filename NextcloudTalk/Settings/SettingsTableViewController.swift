//
// SPDX-FileCopyrightText: 2022 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import NextcloudKit
import SafariServices
import SwiftUI
import ReplayKit
import SDWebImage
import libPhoneNumber

enum SettingsSection: Int {
    case kSettingsSectionUser = 0
    case kSettingsSectionUserStatus
    case kSettingsSectionAccountSettings
    case kSettingsSectionOtherAccounts
    case kSettingsSectionConfiguration
    case kSettingsSectionDebug
    case kSettingsSectionAdvanced
    case kSettingsSectionAbout
}

enum AccountSettingsOptions: Int {
    case kAccountSettingsReadStatusPrivacy = 0
    case kAccountSettingsTypingPrivacy
    case kAccountSettingsContactsSync
    case kAccountSettingsRecents
}

enum ConfigurationSectionOption: Int {
    case kConfigurationSectionOptionUploadMedia = 0
    case kConfigurationSectionOptionVideo
}

enum AdvancedSectionOption: Int {
    case kAdvancedSectionOptionDiagnostics = 0
    case kAdvancedSectionOptionCachedImages
    case kAdvancedSectionOptionCachedVideos
    case kAdvancedSectionOptionCachedDocuments
    case kAdvancedSectionOptionCacheLimit
    /// Separate from Cache limit — share Send staging (`upload/`, soft 512 MB).
    case kAdvancedSectionOptionUploadStaging
    /// Encode reuse (`convert/`, soft 512 MB).
    case kAdvancedSectionOptionConvertCache
    /// Share-sheet image thumbs (`thumbs/`).
    case kAdvancedSectionOptionShareThumbs
    /// SDImageCache + URLCache (avatars / server previews).
    case kAdvancedSectionOptionSystemPreviews
    case kAdvancedSectionOptionCallFromOldAccount
}

enum AboutSection: Int {
    case kAboutSectionPrivacy = 0
    case kAboutSectionSourceCode
}

class SettingsTableViewController: UITableViewController, UITextFieldDelegate, UserStatusViewDelegate, CallsFromOldAccountViewControllerDelegate, DetailedOptionsSelectorTableViewControllerDelegate {
    let kPhoneTextFieldTag = 99

    var activeUserStatus: NCUserStatus?
    var readStatusSwitch = UISwitch()
    var typingIndicatorSwitch = UISwitch()
    var contactSyncSwitch = UISwitch()
    var setPhoneAction: UIAlertAction?
    var includeInRecentsSwitch = UISwitch()

    var totalImageCacheSize: Int64 = 0
    var totalVideoCacheSize: Int64 = 0
    var totalDocumentCacheSize: Int64 = 0
    var totalUploadStagingSize: Int64 = 0
    var totalConvertCacheSize: Int64 = 0
    var totalShareThumbsSize: Int64 = 0
    var totalSystemPreviewsSize: Int64 = 0

    var activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
    var inactiveAccounts = NCDatabaseManager.sharedInstance().inactiveAccounts()
    var serverCapabilities: ServerCapabilities? {
        // Since NCDatabaseManager already caches the capabilities, we don't need a lazy var here
        NCDatabaseManager.sharedInstance().serverCapabilities(forAccountId: activeAccount.accountId)
    }

    lazy var profilePictures: [String: UIImage] = {
        var result: [String: UIImage] = [:]

        for account in NCDatabaseManager.sharedInstance().allAccounts() {
            if let image = NCAPIController.sharedInstance().userProfileImage(forAccount: account, withStyle: self.traitCollection.userInterfaceStyle) {
                result[account.accountId] = image
            }
        }

        return result
    }()

    @IBOutlet weak var cancelButton: UIBarButtonItem!

    override func viewDidLoad() {
        super.viewDidLoad()

        NCAppBranding.styleViewController(self)

        self.navigationItem.title = NSLocalizedString("Settings", comment: "")

        if #unavailable(iOS 26.0) {
            self.cancelButton.tintColor = NCAppBranding.themeTextColor()
        }

        contactSyncSwitch.frame = .zero
        contactSyncSwitch.addTarget(self, action: #selector(contactSyncValueChanged(_:)), for: .valueChanged)

        readStatusSwitch.frame = .zero
        readStatusSwitch.addTarget(self, action: #selector(readStatusValueChanged(_:)), for: .valueChanged)

        includeInRecentsSwitch.frame = .zero
        includeInRecentsSwitch.addTarget(self, action: #selector(includeInRecentsValueChanged(_:)), for: .valueChanged)

        typingIndicatorSwitch.frame = .zero
        typingIndicatorSwitch.addTarget(self, action: #selector(typingIndicatorValueChanged(_:)), for: .valueChanged)

        NotificationCenter.default.addObserver(self, selector: #selector(appStateHasChanged(notification:)), name: NSNotification.Name.NCAppStateHasChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contactsHaveBeenUpdated(notification:)), name: NSNotification.Name.NCContactsManagerContactsUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(contactsAccessHasBeenUpdated(notification:)), name: NSNotification.Name.NCContactsManagerContactsAccessUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userProfileImageUpdated), name: NSNotification.Name.NCUserProfileImageUpdated, object: nil)

        self.updateCacheUsageSizes()

        self.adaptInterfaceForAppState(appState: NCConnectionController.shared.appState)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateCacheUsageSizes()
        if let advanced = getSettingsSections().firstIndex(of: SettingsSection.kSettingsSectionAdvanced.rawValue) {
            tableView.reloadSections(IndexSet(integer: advanced), with: .none)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }

    @IBAction func cancelButtonPressed(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    func getSettingsSections() -> [Int] {
        var sections = [Int]()

        // Active user section
        sections.append(SettingsSection.kSettingsSectionUser.rawValue)

        // User status section
        if serverCapabilities?.userStatus ?? false {
            sections.append(SettingsSection.kSettingsSectionUserStatus.rawValue)
        }

        // Account settings section
        sections.append(SettingsSection.kSettingsSectionAccountSettings.rawValue)

        // Other accounts section
        if !inactiveAccounts.isEmpty {
            sections.append(SettingsSection.kSettingsSectionOtherAccounts.rawValue)
        }

        // Compression section
        sections.append(SettingsSection.kSettingsSectionConfiguration.rawValue)

        // Debug compression controls (Build 9 — visible in TestFlight)
        sections.append(SettingsSection.kSettingsSectionDebug.rawValue)

        // Advanced section
        sections.append(SettingsSection.kSettingsSectionAdvanced.rawValue)

        // About section
        sections.append(SettingsSection.kSettingsSectionAbout.rawValue)
        return sections
    }

    func getAccountSettingsSectionOptions() -> [Int] {
        var options = [Int]()

        // Read status privacy setting
        if NCDatabaseManager.sharedInstance().serverHasTalkCapability(.chatReadStatus) {
            options.append(AccountSettingsOptions.kAccountSettingsReadStatusPrivacy.rawValue)
        }

        // Typing indicator privacy setting
        if NCDatabaseManager.sharedInstance().serverHasTalkCapability(.typingIndicators) {
            options.append(AccountSettingsOptions.kAccountSettingsTypingPrivacy.rawValue)
        }

        // Contacts sync
        if NCDatabaseManager.sharedInstance().serverHasTalkCapability(.phonebookSearch) {
            options.append(AccountSettingsOptions.kAccountSettingsContactsSync.rawValue)
        }

        // Include calls in call history
        options.append(AccountSettingsOptions.kAccountSettingsRecents.rawValue)

        return options
    }

    func getConfigurationSectionOptions() -> [Int] {
        var options = [Int]()

        // Upload media compression
        options.append(ConfigurationSectionOption.kConfigurationSectionOptionUploadMedia.rawValue)

        // Call video quality
        options.append(ConfigurationSectionOption.kConfigurationSectionOptionVideo.rawValue)

        return options
    }

    func getAdvancedSectionOptions() -> [Int] {
        var options = [Int]()

        // Diagnostics
        options.append(AdvancedSectionOption.kAdvancedSectionOptionDiagnostics.rawValue)

        // Caches
        options.append(AdvancedSectionOption.kAdvancedSectionOptionCachedImages.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionCachedVideos.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionCachedDocuments.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionCacheLimit.rawValue)
        // After Cache limit — caches outside the download/ pool (full coverage).
        options.append(AdvancedSectionOption.kAdvancedSectionOptionUploadStaging.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionConvertCache.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionShareThumbs.rawValue)
        options.append(AdvancedSectionOption.kAdvancedSectionOptionSystemPreviews.rawValue)

        // Received calls from old accounts
        if NCSettingsController.sharedInstance().didReceiveCallsFromOldAccount() {
            options.append(AdvancedSectionOption.kAdvancedSectionOptionCallFromOldAccount.rawValue)
        }

        return options
    }

    func getAboutSectionOptions() -> [Int] {
        var options = [Int]()

        // Privacy
        options.append(AboutSection.kAboutSectionPrivacy.rawValue)

        // Source code
        if !isBrandedApp.boolValue {
            options.append(AboutSection.kAboutSectionSourceCode.rawValue)
        }

        return options
    }

    func getSectionForSettingsSection(section: SettingsSection) -> Int {
        let section = getSettingsSections().firstIndex(of: section.rawValue)
        return section ?? 0
    }

    func getIndexPathForConfigurationOption(option: ConfigurationSectionOption) -> IndexPath {
        let section = getSectionForSettingsSection(section: SettingsSection.kSettingsSectionConfiguration)
        let row = getConfigurationSectionOptions().firstIndex(of: option.rawValue)
        return IndexPath(row: row ?? 0, section: section)
    }

    // MARK: - User Profile

    func refreshUserProfile() {
        NCSettingsController.sharedInstance().getUserProfile(forAccountId: activeAccount.accountId) { _ in
            self.tableView.reloadData()
        }
        self.getActiveUserStatus()
    }

    func getActiveUserStatus() {
        NCAPIController.sharedInstance().getUserStatus(forAccount: activeAccount) { userStatus in
            if let userStatus {
                self.activeUserStatus = userStatus
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Notifications

    @objc func appStateHasChanged(notification: NSNotification) {
        let appState = notification.userInfo?["appState"]
        if let rawAppState = appState as? Int, let appState = AppState(rawValue: rawAppState) {
            self.adaptInterfaceForAppState(appState: appState)
        }
    }

    @objc func contactsHaveBeenUpdated(notification: NSNotification) {
        DispatchQueue.main.async {
            self.activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
            self.tableView.reloadData()
        }
    }

    @objc func contactsAccessHasBeenUpdated(notification: NSNotification) {
        DispatchQueue.main.async {
            self.activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
            self.tableView.reloadData()
        }
    }

    @objc func userProfileImageUpdated(notification: NSNotification) {
        self.tableView.reloadSections(IndexSet(integer: SettingsSection.kSettingsSectionUser.rawValue), with: .none)
    }

    // MARK: - User Interface

    func adaptInterfaceForAppState(appState: AppState) {
        switch appState {
        case .ready:
            refreshUserProfile()
        default:
            break
        }
    }

    // MARK: - Profile actions

    func userProfilePressed() {
        let userProfileVC = UserProfileTableViewController(withAccount: activeAccount)
        self.navigationController?.pushViewController(userProfileVC, animated: true)
    }

    // MARK: - User Status (SwiftUI)

    func presentUserStatusOptions() {
        if let activeUserStatus = activeUserStatus {
            var userStatusView = UserStatusSwiftUIView(userStatus: activeUserStatus)
            userStatusView.delegate = self
            let hostingController = UIHostingController(rootView: userStatusView)
            self.present(hostingController, animated: true)
        }
    }

    func userStatusViewDidDisappear() {
        self.getActiveUserStatus()
    }

    // MARK: - User phone number

    func checkUserPhoneNumber() {
        NCSettingsController.sharedInstance().getUserProfile(forAccountId: activeAccount.accountId) { _ in
            if self.activeAccount.phone.isEmpty {
                self.presentSetPhoneNumberDialog()
            }
        }
    }

    func presentSetPhoneNumberDialog() {
        let alertTitle = NSLocalizedString("Phone number", comment: "")
        let alertMessage = NSLocalizedString("You can set your phone number so other users will be able to find you", comment: "")
        let setPhoneNumberDialog = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)

        setPhoneNumberDialog.addTextField { [self] textField in
            let location = NSLocale.current.regionCode
            let countryCode = NBPhoneNumberUtil.sharedInstance().getCountryCode(forRegion: location)
            if let countryCode = countryCode {
                textField.text = "+\(countryCode)"
            }
            if let exampleNumber = try? NBPhoneNumberUtil.sharedInstance().getExampleNumber(location) {
                textField.placeholder = try? NBPhoneNumberUtil.sharedInstance().format(exampleNumber, numberFormat: NBEPhoneNumberFormat.INTERNATIONAL)
            }
            textField.keyboardType = .phonePad
            textField.delegate = self
            textField.tag = kPhoneTextFieldTag
        }
        setPhoneAction = UIAlertAction(title: NSLocalizedString("Set", comment: ""), style: .default, handler: { _ in
            guard let phoneNumber = setPhoneNumberDialog.textFields?[0].text else { return }

            NCAPIController.sharedInstance().setUserProfileField(UserProfileField.phone, withValue: phoneNumber, forAccount: self.activeAccount) { error in
                if error != nil {
                    self.presentPhoneNumberErrorDialog(phoneNumber: phoneNumber)
                    print("Error setting phone number ", error ?? "")
                } else {
                    NotificationPresenter.shared().present(text: NSLocalizedString("Phone number set successfully", comment: ""), dismissAfterDelay: 5.0, includedStyle: .success)
                }
                self.refreshUserProfile()
            }
        })
        if let setPhoneAction = setPhoneAction {
            setPhoneAction.isEnabled = false
            setPhoneNumberDialog.addAction(setPhoneAction)
        }
        let cancelAction = UIAlertAction(title: NSLocalizedString("Skip", comment: ""), style: .default) { _ in
            self.refreshUserProfile()
        }
        setPhoneNumberDialog.addAction(cancelAction)
        self.present(setPhoneNumberDialog, animated: true, completion: nil)
    }

    func presentPhoneNumberErrorDialog(phoneNumber: String) {
        let alertTitle = NSLocalizedString("Could not set phone number", comment: "")
        var alertMessage = NSLocalizedString("An error occurred while setting phone number", comment: "")
        let failedPhoneNumber = try? NBPhoneNumberUtil.sharedInstance().parse(phoneNumber, defaultRegion: nil)
        if let formattedPhoneNumber = try? NBPhoneNumberUtil.sharedInstance().format(failedPhoneNumber, numberFormat: NBEPhoneNumberFormat.INTERNATIONAL) {
            alertMessage = NSLocalizedString("An error occurred while setting \(formattedPhoneNumber) as phone number", comment: "")
        }

        let failedPhoneNumberDialog = UIAlertController(
            title: alertTitle,
            message: alertMessage,
            preferredStyle: .alert)

        let retryAction = UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
            self.presentSetPhoneNumberDialog()
        }
        failedPhoneNumberDialog.addAction(retryAction)

        let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil)
        failedPhoneNumberDialog.addAction(cancelAction)

        self.present(failedPhoneNumberDialog, animated: true, completion: nil)
    }

    // MARK: UITextField delegate

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if textField.tag == kPhoneTextFieldTag {
            let inputPhoneNumber = (textField.text as NSString?)?.replacingCharacters(in: range, with: string)
            let phoneNumber = try? NBPhoneNumberUtil.sharedInstance().parse(inputPhoneNumber, defaultRegion: nil)
            setPhoneAction?.isEnabled = NBPhoneNumberUtil.sharedInstance().isValidNumber(phoneNumber)
        }
        return true
    }

    // MARK: - Configuration

    private let mediaUploadModeSenderId = "mediaUploadMode"
    private let videoResolutionSenderId = "videoResolution"

    func presentUploadMediaModeSelector() {
        let currentMode = MediaUploadMode(rawValue: Int(NCUserDefaults.mediaUploadMode())) ?? .automatic
        let modes: [(MediaUploadMode, String, String)] = [
            (.noCompression,
             NSLocalizedString("None", comment: "No media compression"),
             NSLocalizedString("Upload originals without compressing", comment: "Subtitle for None media compression mode")),
            (.automatic,
             NSLocalizedString("Automatic", comment: "Automatic media compression"),
             NSLocalizedString("Per file: best quality that stays under the max file size (with estimate margin)", comment: "Subtitle for Automatic media compression mode")),
            (.chooseOnUpload,
             NSLocalizedString("Manual", comment: "Choose compression level when uploading"),
             NSLocalizedString("Choose None, Low, Medium, or High on each send", comment: "Subtitle for Manual media compression mode"))
        ]

        let options: [DetailedOption] = modes.map { mode, title, subtitle in
            let option = DetailedOption()
            option.identifier = "\(mode.rawValue)"
            option.title = title
            option.subtitle = subtitle
            option.selected = mode == currentMode
            return option
        }

        guard let selector = DetailedOptionsSelectorTableViewController(options: options,
                                                                        forSenderIdentifier: mediaUploadModeSenderId,
                                                                        andStyle: .insetGrouped) else { return }
        selector.title = NSLocalizedString("Media Compression", comment: "")
        selector.footerText = NSLocalizedString(
            "Manual shows estimated sizes before send (bitrate × duration for Bitrate engine). Videos encode one-at-a-time.",
            comment: "Footer on Media Compression mode picker"
        )
        selector.delegate = self
        navigationController?.pushViewController(selector, animated: true)
    }

    func presentVideoResoultionsSelector() {
        let videoResolutions = NCSettingsController.sharedInstance().videoSettingsModel.availableVideoResolutions()
        let storedResolution = NCSettingsController.sharedInstance().videoSettingsModel.currentVideoResolutionSettingFromStore()

        let options: [DetailedOption] = videoResolutions.map { resolution in
            let option = DetailedOption()
            option.identifier = resolution
            option.title = NCSettingsController.sharedInstance().videoSettingsModel.readableResolution(resolution)
            option.selected = resolution == storedResolution
            return option
        }

        guard let selector = DetailedOptionsSelectorTableViewController(options: options,
                                                                        forSenderIdentifier: videoResolutionSenderId,
                                                                        andStyle: .insetGrouped) else { return }
        selector.title = NSLocalizedString("Video Call Quality", comment: "")
        selector.delegate = self
        navigationController?.pushViewController(selector, animated: true)
    }

    func presentCacheLimitSettings() {
        let controller = CacheLimitSettingsViewController(currentBytes: NCUserDefaults.fileCacheMaxBytes()) { [weak self] bytes in
            NCUserDefaults.setFileCacheMaxBytes(bytes)
            DispatchQueue.global(qos: .utility).async {
                NCChatFileController.enforceCacheSizeLimit()
                DispatchQueue.main.async {
                    self?.updateCacheUsageSizes()
                    self?.tableView.reloadData()
                }
            }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    func detailedOptionsSelector(_ viewController: DetailedOptionsSelectorTableViewController!,
                                 didSelectOptionWithIdentifier option: DetailedOption!) {
        guard let option else { return }
        let senderId = viewController.senderId ?? ""

        if senderId == mediaUploadModeSenderId,
           let raw = Int(option.identifier ?? ""),
           let mode = MediaUploadMode(rawValue: raw) {
            NCUserDefaults.setMediaUploadMode(mode.rawValue)
            let indexPath = getIndexPathForConfigurationOption(option: .kConfigurationSectionOptionUploadMedia)
            tableView.reloadRows(at: [indexPath], with: .none)
        } else if senderId == videoResolutionSenderId, let resolution = option.identifier {
            NCSettingsController.sharedInstance().videoSettingsModel.storeVideoResolutionSetting(resolution)
            let indexPath = getIndexPathForConfigurationOption(option: .kConfigurationSectionOptionVideo)
            tableView.reloadRows(at: [indexPath], with: .none)
        }

        navigationController?.popViewController(animated: true)
    }

    func detailedOptionsSelectorWasCancelled(_ viewController: DetailedOptionsSelectorTableViewController!) {
        navigationController?.popViewController(animated: true)
    }

    @objc func contactSyncValueChanged(_ sender: Any?) {
        NCSettingsController.sharedInstance().setContactSync(contactSyncSwitch.isOn)
        if contactSyncSwitch.isOn {
            if !NCContactsManager.sharedInstance().isContactAccessDetermined() {
                NCContactsManager.sharedInstance().requestContactsAccess { granted in
                    if granted {
                        self.checkUserPhoneNumber()
                        NCContactsManager.sharedInstance().searchInServer(forAddressBookContacts: true)
                    }
                }
            } else if NCContactsManager.sharedInstance().isContactAccessAuthorized() {
                self.checkUserPhoneNumber()
                NCContactsManager.sharedInstance().searchInServer(forAddressBookContacts: true)
            }
        } else {
            NCContactsManager.sharedInstance().removeStoredContacts()
        }
        // Reload to update configuration section footer
        self.tableView.reloadData()
    }

    @objc func readStatusValueChanged(_ sender: Any?) {
        readStatusSwitch.isEnabled = false

        NCAPIController.sharedInstance().setReadStatusPrivacySettingEnabled(!readStatusSwitch.isOn, forAccount: activeAccount) { error in
            if error == nil {
                NCSettingsController.sharedInstance().getCapabilitiesForAccountId(self.activeAccount.accountId) { error in
                    if error == nil {
                        self.readStatusSwitch.isEnabled = true
                        self.tableView.reloadData()
                    } else {
                        self.showReadStatusModificationError()
                    }
                }
            } else {
                self.showReadStatusModificationError()
            }
        }
    }

    func showReadStatusModificationError() {
        readStatusSwitch.isEnabled = true
        self.tableView.reloadData()
        let errorDialog = UIAlertController(
            title: NSLocalizedString("An error occurred changing read status setting", comment: ""),
            message: nil,
            preferredStyle: .alert)
        let okAction = UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil)
        errorDialog.addAction(okAction)
        self.present(errorDialog, animated: true, completion: nil)
    }

    @objc func typingIndicatorValueChanged(_ sender: Any?) {
        typingIndicatorSwitch.isEnabled = false

        NCAPIController.sharedInstance().setTypingPrivacySettingEnabled(!typingIndicatorSwitch.isOn, forAccount: activeAccount) { error in
            if error == nil {
                NCSettingsController.sharedInstance().getCapabilitiesForAccountId(self.activeAccount.accountId) { error in
                    if error == nil {
                        self.typingIndicatorSwitch.isEnabled = true
                        self.tableView.reloadData()
                    } else {
                        self.showTypeIndicatorModificationError()
                    }
                }
            } else {
                self.showTypeIndicatorModificationError()
            }
        }
    }

    func showTypeIndicatorModificationError() {
        self.typingIndicatorSwitch.isEnabled = true
        self.tableView.reloadData()
        let errorDialog = UIAlertController(
            title: NSLocalizedString("An error occurred changing typing privacy setting", comment: ""),
            message: nil,
            preferredStyle: .alert)
        let okAction = UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil)
        errorDialog.addAction(okAction)
        self.present(errorDialog, animated: true, completion: nil)
    }

    @objc func includeInRecentsValueChanged(_ sender: Any?) {
        NCUserDefaults.setIncludeCallsInRecentsEnabled(includeInRecentsSwitch.isOn)
        CallKitManager.sharedInstance().setIncludeInRecents(toValue: includeInRecentsSwitch.isOn)
    }

    // MARK: - Advanced actions

    func diagnosticsPressed() {
        let diagnosticsVC = DiagnosticsTableViewController(withAccount: activeAccount)

        self.navigationController?.pushViewController(diagnosticsVC, animated: true)
    }

    func cachedImagesPressed() {
        let clearCacheDialog = UIAlertController(
            title: NSLocalizedString("Clear cache", comment: ""),
            message: NSLocalizedString(
                "Clear downloaded image attachments only (download/). Avatars and chat previews are under System previews.",
                comment: ""
            ),
            preferredStyle: .alert)

        let clearAction = UIAlertAction(title: NSLocalizedString("Clear cache", comment: ""), style: .destructive) { _ in
            MediaUploadDiskStore.clearAttachmentCache(kind: .images)
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        }
        clearCacheDialog.addAction(clearAction)

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)
        clearCacheDialog.addAction(cancelAction)

        self.present(clearCacheDialog, animated: true, completion: nil)
    }

    func cachedVideosPressed() {
        let clearCacheDialog = UIAlertController(
            title: NSLocalizedString("Clear cache", comment: ""),
            message: NSLocalizedString(
                "Clear downloaded video attachments only (download/). Encoded reuse is under Convert cache.",
                comment: ""
            ),
            preferredStyle: .alert)

        let clearAction = UIAlertAction(title: NSLocalizedString("Clear cache", comment: ""), style: .destructive) { _ in
            MediaUploadDiskStore.clearAttachmentCache(kind: .videos)
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        }
        clearCacheDialog.addAction(clearAction)
        clearCacheDialog.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(clearCacheDialog, animated: true)
    }

    func cachedDocumentsPressed() {
        let clearCacheDialog = UIAlertController(
            title: NSLocalizedString("Clear cache", comment: ""),
            message: NSLocalizedString("Do you really want to clear the document cache?", comment: ""),
            preferredStyle: .alert)

        let clearAction = UIAlertAction(title: NSLocalizedString("Clear cache", comment: ""), style: .destructive) { _ in
            MediaUploadDiskStore.clearAttachmentCache(kind: .documents)
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        }
        clearCacheDialog.addAction(clearAction)

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)
        clearCacheDialog.addAction(cancelAction)

        self.present(clearCacheDialog, animated: true, completion: nil)
    }

    func uploadStagingPressed() {
        if MediaUploadDiskStore.isUploadSessionActive() {
            let blocked = UIAlertController(
                title: NSLocalizedString("Share in progress", comment: ""),
                message: NSLocalizedString(
                    "Upload staging is in use by an active share session. Finish or cancel the share, then try again.",
                    comment: "Cannot clear upload/ while Share Extension holds session marker"
                ),
                preferredStyle: .alert
            )
            blocked.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            present(blocked, animated: true)
            return
        }

        let cap = MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.uploadStagingMaxBytes)
        let used = MediaUploadDiskStore.formatCacheBytes(totalUploadStagingSize)
        let message = String.localizedStringWithFormat(
            NSLocalizedString(
                "Share send staging (upload/). Soft cap %@ — not part of Cache limit. Also clears share thumbs. Auto-cleared after send, Cancel, or on the next share session. Currently %@.",
                comment: "Confirm clear upload staging; first %@ is cap, second is current size"
            ),
            cap,
            used
        )
        let clearCacheDialog = UIAlertController(
            title: NSLocalizedString("Clear upload staging?", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        let clearAction = UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
            let cleared = MediaUploadDiskStore.clearUploadStagingCaches()
            if !cleared {
                let blocked = UIAlertController(
                    title: NSLocalizedString("Share in progress", comment: ""),
                    message: NSLocalizedString(
                        "Upload staging is in use by an active share session. Finish or cancel the share, then try again.",
                        comment: "Cannot clear upload/ while Share Extension holds session marker"
                    ),
                    preferredStyle: .alert
                )
                blocked.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                self.present(blocked, animated: true)
            }
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        }
        clearCacheDialog.addAction(clearAction)
        clearCacheDialog.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(clearCacheDialog, animated: true)
    }

    func convertCachePressed() {
        let cap = MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.convertCacheMaxBytes)
        let used = MediaUploadDiskStore.formatCacheBytes(totalConvertCacheSize)
        let message = String.localizedStringWithFormat(
            NSLocalizedString(
                "Encoded reuse cache (convert/). Soft cap %@ — not part of Cache limit. Cleared entries must re-encode on next send. Currently %@.",
                comment: "Confirm clear convert cache; first %@ is cap, second is current size"
            ),
            cap,
            used
        )
        let alert = UIAlertController(
            title: NSLocalizedString("Clear convert cache?", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
            MediaUploadDiskStore.clearConvertCache()
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    func shareThumbsPressed() {
        let used = MediaUploadDiskStore.formatCacheBytes(totalShareThumbsSize)
        let message = String.localizedStringWithFormat(
            NSLocalizedString(
                "Share-sheet image thumbs (thumbs/). Not part of Cache limit. Also cleared with Upload staging. Currently %@.",
                comment: "Confirm clear share thumbs; %@ is current size"
            ),
            used
        )
        let alert = UIAlertController(
            title: NSLocalizedString("Clear share thumbs?", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
            MediaUploadDiskStore.clearThumbsCache()
            self.updateCacheUsageSizes()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    func systemPreviewsPressed() {
        let used = MediaUploadDiskStore.formatCacheBytes(totalSystemPreviewsSize)
        let message = String.localizedStringWithFormat(
            NSLocalizedString(
                "Avatars, chat file previews, and HTTP cache (SDImageCache + URLCache). Not part of Cache limit. Currently %@.",
                comment: "Confirm clear system previews; %@ is current size"
            ),
            used
        )
        let alert = UIAlertController(
            title: NSLocalizedString("Clear system previews?", comment: ""),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
            URLCache.shared.removeAllCachedResponses()
            SDImageCache.shared.clearMemory()
            SDImageCache.shared.clearDisk {
                MediaUploadTrace.log("CACHE clear system-previews (SDImageCache + URLCache)")
                self.updateCacheUsageSizes()
                self.tableView.reloadData()
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    func callsFromOldAccountPressed() {
        let vc = CallsFromOldAccountViewController()
        vc.delegate = self

        self.navigationController?.pushViewController(vc, animated: true)
    }

    func callsFromOldAccountWarningAcknowledged() {
        self.tableView.reloadData()
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return getSettingsSections().count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let sections = getSettingsSections()
        let settingsSection = sections[section]

        switch settingsSection {
        case SettingsSection.kSettingsSectionUser.rawValue:
            return 1
        case SettingsSection.kSettingsSectionUserStatus.rawValue:
            return 1
        case SettingsSection.kSettingsSectionAccountSettings.rawValue:
            return getAccountSettingsSectionOptions().count
        case SettingsSection.kSettingsSectionConfiguration.rawValue:
            return getConfigurationSectionOptions().count
        case SettingsSection.kSettingsSectionDebug.rawValue:
            return 3
        case SettingsSection.kSettingsSectionAdvanced.rawValue:
            return getAdvancedSectionOptions().count
        case SettingsSection.kSettingsSectionAbout.rawValue:
            return getAboutSectionOptions().count
        case SettingsSection.kSettingsSectionOtherAccounts.rawValue:
            return inactiveAccounts.count
        default:
            break
        }
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let sections = getSettingsSections()
        let settingsSection = sections[section]

        switch settingsSection {
        case SettingsSection.kSettingsSectionOtherAccounts.rawValue:
            return NSLocalizedString("Other accounts", comment: "")
        case SettingsSection.kSettingsSectionConfiguration.rawValue:
            return NSLocalizedString("Compression", comment: "")
        case SettingsSection.kSettingsSectionDebug.rawValue:
            return NSLocalizedString("Debug", comment: "")
        case SettingsSection.kSettingsSectionAdvanced.rawValue:
            return NSLocalizedString("Advanced", comment: "")
        case SettingsSection.kSettingsSectionAbout.rawValue:
            return NSLocalizedString("About", comment: "")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        applyAppleStyleSectionHeader(view, title: self.tableView(tableView, titleForHeaderInSection: section))
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let sections = getSettingsSections()
        let settingsSection = sections[section]

        if settingsSection == SettingsSection.kSettingsSectionAbout.rawValue {
            let version = NCAppBranding.getAppVersionString() ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            return "\(copyright), version \(version), build \(build)\n\(licenseNotice)"
        }

        if settingsSection == SettingsSection.kSettingsSectionAccountSettings.rawValue && contactSyncSwitch.isOn {
            if NCContactsManager.sharedInstance().isContactAccessDetermined() && !NCContactsManager.sharedInstance().isContactAccessAuthorized() {
                return NSLocalizedString("Contact access has been denied", comment: "")
            }
            if activeAccount.lastContactSync > 0 {
                let lastUpdate = Date(timeIntervalSince1970: TimeInterval(activeAccount.lastContactSync))
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short
                return NSLocalizedString("Last sync", comment: "") + ": " + dateFormatter.string(from: lastUpdate)
            }
        }

        if settingsSection == SettingsSection.kSettingsSectionUser.rawValue && contactSyncSwitch.isOn {
            if activeAccount.phone.isEmpty {
                let missingPhoneString = NSLocalizedString("Missing phone number information", comment: "")
                return "⚠ " + missingPhoneString
            }
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let sections = getSettingsSections()
        let settingsSection = sections[indexPath.section]

        switch settingsSection {
        case SettingsSection.kSettingsSectionUser.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "UserProfileCellIdentifier", style: .subtitle)
            cell.textLabel?.text = activeAccount.userDisplayName
            cell.textLabel?.font = .preferredFont(for: .title2, weight: .medium)
            cell.detailTextLabel?.text = activeAccount.server.replacingOccurrences(of: "https://", with: "")
            cell.detailTextLabel?.lineBreakMode = .byCharWrapping
            cell.imageView?.image = self.getProfilePicture(for: activeAccount)?.cropToCircle(withSize: CGSize(width: 60, height: 60))
            cell.accessoryType = .disclosureIndicator
            return cell

        case SettingsSection.kSettingsSectionUserStatus.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "UserStatusCellIdentifier", style: .subtitle)
            if activeUserStatus != nil {
                cell.textLabel?.text = activeUserStatus!.readableUserStatus()
                let statusMessage = activeUserStatus!.readableUserStatusMessage()
                if !statusMessage.isEmpty {
                    cell.textLabel?.text = statusMessage
                }
                if activeUserStatus!.status == kUserStatusDND {
                    cell.detailTextLabel?.text = NSLocalizedString("All notifications are muted", comment: "")
                }
                let statusImage = activeUserStatus!.getSFUserStatusIcon()
                cell.imageView?.image = statusImage
            } else {
                cell.textLabel?.text = NSLocalizedString("Fetching status …", comment: "")
            }
            return cell

        case SettingsSection.kSettingsSectionAccountSettings.rawValue:
            return userSettingsCell(for: indexPath)

        case SettingsSection.kSettingsSectionOtherAccounts.rawValue:
            return userAccountsCell(for: indexPath)

        case SettingsSection.kSettingsSectionConfiguration.rawValue:
            return sectionConfigurationCell(for: indexPath)

        case SettingsSection.kSettingsSectionDebug.rawValue:
            if indexPath.row == 0 {
                let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "DebugCompressionCell", style: .default)
                cell.textLabel?.text = NSLocalizedString("Media Compression Settings", comment: "")
                cell.detailTextLabel?.text = nil
                cell.accessoryType = .disclosureIndicator
                cell.setColoredSettingsIcon(systemName: "slider.horizontal.3", backgroundColor: SettingsIconColor.orange)
                return cell
            }
            if indexPath.row == 1 {
                let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "DebugCompressionAlgoCell", style: .default)
                cell.textLabel?.text = NSLocalizedString("Compression Algo", comment: "Debug: explanation of compression algorithm")
                cell.detailTextLabel?.text = nil
                cell.accessoryType = .disclosureIndicator
                cell.setColoredSettingsIcon(systemName: "chevron.left.forwardslash.chevron.right", backgroundColor: SettingsIconColor.gray)
                return cell
            }
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "DebugCachePolicyCell", style: .default)
            cell.textLabel?.text = NSLocalizedString("Cache Policy", comment: "Debug: explanation of media caches")
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .disclosureIndicator
            cell.setColoredSettingsIcon(systemName: "internaldrive", backgroundColor: SettingsIconColor.gray)
            return cell

        case SettingsSection.kSettingsSectionAdvanced.rawValue:
            return advancedCell(for: indexPath)

        case SettingsSection.kSettingsSectionAbout.rawValue:
            return sectionAboutCell(for: indexPath)

        default:
            return UITableViewCell()
        }
    }

    func didSelectOtherAccountSectionCell(for indexPath: IndexPath) {
        if let account = inactiveAccounts[indexPath.row] as? TalkAccount {
            NCSettingsController.sharedInstance().setActiveAccountWithAccountId(account.accountId)
        }
    }

    func didSelectAccountSettingsSectionCell(for indexPath: IndexPath) {
        let options = getAccountSettingsSectionOptions()
        let option = options[indexPath.row]
        switch option {
        case AccountSettingsOptions.kAccountSettingsContactsSync.rawValue:
            NCContactsManager.sharedInstance().searchInServer(forAddressBookContacts: true)
        default:
            break
        }
    }

    func didSelectSettingsSectionCell(for indexPath: IndexPath) {
        let options = getConfigurationSectionOptions()
        let option = options[indexPath.row]
        switch option {
        case ConfigurationSectionOption.kConfigurationSectionOptionUploadMedia.rawValue:
            self.presentUploadMediaModeSelector()
        case ConfigurationSectionOption.kConfigurationSectionOptionVideo.rawValue:
            self.presentVideoResoultionsSelector()
        default:
            break
        }
    }

    func didSelectAdvancedSectionCell(for indexPath: IndexPath) {
        let options = getAdvancedSectionOptions()
        let option = options[indexPath.row]
        switch option {
        case AdvancedSectionOption.kAdvancedSectionOptionDiagnostics.rawValue:
            self.diagnosticsPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionCachedImages.rawValue:
            self.cachedImagesPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionCachedVideos.rawValue:
            self.cachedVideosPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionCachedDocuments.rawValue:
            self.cachedDocumentsPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionCacheLimit.rawValue:
            self.presentCacheLimitSettings()
        case AdvancedSectionOption.kAdvancedSectionOptionUploadStaging.rawValue:
            self.uploadStagingPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionConvertCache.rawValue:
            self.convertCachePressed()
        case AdvancedSectionOption.kAdvancedSectionOptionShareThumbs.rawValue:
            self.shareThumbsPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionSystemPreviews.rawValue:
            self.systemPreviewsPressed()
        case AdvancedSectionOption.kAdvancedSectionOptionCallFromOldAccount.rawValue:
            self.callsFromOldAccountPressed()
        default:
            break
        }
    }

    func didSelectAboutSectionCell(for indexPath: IndexPath) {
        let options = getAboutSectionOptions()
        let option = options[indexPath.row]
        switch option {
        case AboutSection.kAboutSectionPrivacy.rawValue:
            if let url = URL(string: privacyURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                let safariVC = SFSafariViewController(url: url)
                self.present(safariVC, animated: true, completion: nil)
            }
        case AboutSection.kAboutSectionSourceCode.rawValue:
            let safariVC = SFSafariViewController(url: URL(string: "https://github.com/nextcloud/talk-ios")!)
            self.present(safariVC, animated: true, completion: nil)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let sections = getSettingsSections()
        let settingsSection = sections[indexPath.section]
        switch settingsSection {
        case SettingsSection.kSettingsSectionUser.rawValue:
            self.userProfilePressed()

        case SettingsSection.kSettingsSectionUserStatus.rawValue:
            self.presentUserStatusOptions()

        case SettingsSection.kSettingsSectionAccountSettings.rawValue:
            self.didSelectAccountSettingsSectionCell(for: indexPath)

        case SettingsSection.kSettingsSectionOtherAccounts.rawValue:
            self.didSelectOtherAccountSectionCell(for: indexPath)

        case SettingsSection.kSettingsSectionConfiguration.rawValue:
            self.didSelectSettingsSectionCell(for: indexPath)

        case SettingsSection.kSettingsSectionDebug.rawValue:
            if indexPath.row == 0 {
                let debugVC = MediaUploadCompressionDebugViewController()
                self.navigationController?.pushViewController(debugVC, animated: true)
            } else if indexPath.row == 1 {
                let algoVC = MediaUploadCompressionAlgoViewController()
                self.navigationController?.pushViewController(algoVC, animated: true)
            } else {
                let policyVC = MediaUploadCachePolicyViewController()
                self.navigationController?.pushViewController(policyVC, animated: true)
            }

        case SettingsSection.kSettingsSectionAdvanced.rawValue:
            self.didSelectAdvancedSectionCell(for: indexPath)

        case SettingsSection.kSettingsSectionAbout.rawValue:
            didSelectAboutSectionCell(for: indexPath)

        default:
            break
        }
        self.tableView.deselectRow(at: indexPath, animated: true)
    }
}

extension SettingsTableViewController {

    func userSettingsCell(for indexPath: IndexPath) -> UITableViewCell {
        let userSettingsCellIdentifier = "UserSettingsCellIdentifier"

        let options = getAccountSettingsSectionOptions()
        let option = options[indexPath.row]

        switch option {
        case AccountSettingsOptions.kAccountSettingsReadStatusPrivacy.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: userSettingsCellIdentifier, style: .subtitle)
            cell.textLabel?.text = NSLocalizedString("Read status", comment: "")
            cell.setColoredSettingsIcon(image: UIImage(named: "check-all"), backgroundColor: SettingsIconColor.red)
            cell.accessoryView = readStatusSwitch
            readStatusSwitch.isOn = !(serverCapabilities?.readStatusPrivacy ?? true)
            cell.selectionStyle = .none
            return cell

        case AccountSettingsOptions.kAccountSettingsTypingPrivacy.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: userSettingsCellIdentifier, style: .subtitle)
            cell.textLabel?.text = NSLocalizedString("Typing indicator", comment: "")
            cell.setColoredSettingsIcon(systemName: "rectangle.and.pencil.and.ellipsis", backgroundColor: SettingsIconColor.red)
            cell.accessoryView = typingIndicatorSwitch
            typingIndicatorSwitch.isOn = !(serverCapabilities?.typingPrivacy ?? true)
            cell.selectionStyle = .none

            let externalSignalingController = NCSettingsController.sharedInstance().externalSignalingController(forAccountId: activeAccount.accountId)
            if externalSignalingController == nil {
                cell.detailTextLabel?.text = NSLocalizedString("Typing indicators are only available when using a high performance backend (HPB)",
                                                               comment: "")
            }

            return cell

        case AccountSettingsOptions.kAccountSettingsContactsSync.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: userSettingsCellIdentifier, style: .subtitle)
            cell.textLabel?.text = NSLocalizedString("Phone number integration", comment: "")
            cell.detailTextLabel?.text = NSLocalizedString("Match system contacts", comment: "")
            cell.setColoredSettingsIcon(systemName: "iphone", backgroundColor: SettingsIconColor.green)
            cell.accessoryView = contactSyncSwitch
            contactSyncSwitch.isOn = NCSettingsController.sharedInstance().isContactSyncEnabled()
            cell.selectionStyle = .none
            return cell

        case AccountSettingsOptions.kAccountSettingsRecents.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: userSettingsCellIdentifier, style: .default)
            cell.textLabel?.text = NSLocalizedString("Include calls in call history", comment: "")
            cell.setColoredSettingsIcon(systemName: "clock.arrow.circlepath", backgroundColor: SettingsIconColor.green)
            cell.selectionStyle = .none
            cell.accessoryView = includeInRecentsSwitch
            includeInRecentsSwitch.isOn = NCUserDefaults.includeCallsInRecents()
            return cell

        default:
            return UITableViewCell()
        }
    }

    func userAccountsCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let account = inactiveAccounts[indexPath.row] as? TalkAccount else { return UITableViewCell() }

        let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "AccountCellIdentifier", style: .subtitle)
        cell.textLabel?.text = account.userDisplayName
        cell.detailTextLabel?.text = account.server.replacingOccurrences(of: "https://", with: "")
        cell.detailTextLabel?.lineBreakMode = .byCharWrapping

        if let accountImage = self.getProfilePicture(for: account) {
            cell.setSettingsImage(image: NCUtils.roundedImage(fromImage: accountImage), renderingMode: .alwaysOriginal)
        }

        if account.unreadBadgeNumber > 0 {
            let badgeView = BadgeView(frame: .zero)
            badgeView.badgeColor = NCAppBranding.themeColor()
            badgeView.badgeTextColor = NCAppBranding.themeTextColor()
            badgeView.setBadgeNumber(account.unreadBadgeNumber)
            cell.accessoryView = badgeView
        }

        return cell
    }

    func sectionConfigurationCell(for indexPath: IndexPath) -> UITableViewCell {
        // value1 style is fixed at creation — keep a dedicated reuse id for selection rows.
        let configurationValueCellIdentifier = "ConfigurationValueCellIdentifier"

        let options = getConfigurationSectionOptions()
        let option = options[indexPath.row]

        switch option {
        case ConfigurationSectionOption.kConfigurationSectionOptionUploadMedia.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: configurationValueCellIdentifier, style: .value1)
            cell.textLabel?.text = NSLocalizedString("Media Compression", comment: "")
            cell.setColoredSettingsIcon(systemName: "arrow.up.circle", backgroundColor: SettingsIconColor.blue)
            cell.detailTextLabel?.text = self.readableMediaUploadMode(MediaUploadMode(rawValue: Int(NCUserDefaults.mediaUploadMode())) ?? .automatic)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
            return cell

        case ConfigurationSectionOption.kConfigurationSectionOptionVideo.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: configurationValueCellIdentifier, style: .value1)
            cell.textLabel?.text = NSLocalizedString("Video Call Quality", comment: "")
            cell.setColoredSettingsIcon(systemName: "video", backgroundColor: SettingsIconColor.green)

            let resolution = NCSettingsController.sharedInstance().videoSettingsModel.currentVideoResolutionSettingFromStore()
            cell.detailTextLabel?.text = NCSettingsController.sharedInstance().videoSettingsModel.readableResolution(resolution)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
            return cell

        default:
            return UITableViewCell()
        }
    }

    func readableMediaUploadMode(_ mode: MediaUploadMode) -> String {
        switch mode {
        case .noCompression:
            return NSLocalizedString("None", comment: "No media compression")
        case .automatic:
            return NSLocalizedString("Automatic", comment: "Automatic media compression")
        case .chooseOnUpload:
            return NSLocalizedString("Manual", comment: "Choose compression level when uploading")
        @unknown default:
            return NSLocalizedString("Automatic", comment: "")
        }
    }

    func advancedCell(for indexPath: IndexPath) -> UITableViewCell {
        let advancedCellIdentifier = "AdvancedCellIdentifier"

        let options = getAdvancedSectionOptions()
        let option = options[indexPath.row]

        switch option {
        case AdvancedSectionOption.kAdvancedSectionOptionDiagnostics.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: advancedCellIdentifier, style: .default)
            cell.textLabel?.text = NSLocalizedString("Diagnostics", comment: "")
            cell.setColoredSettingsIcon(systemName: "gear", backgroundColor: SettingsIconColor.orange)
            cell.accessoryType = .disclosureIndicator
            return cell

        case AdvancedSectionOption.kAdvancedSectionOptionCallFromOldAccount.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: advancedCellIdentifier, style: .default)
            cell.textLabel?.text = NSLocalizedString("Calls from old accounts", comment: "")
            cell.setColoredSettingsIcon(systemName: "exclamationmark.triangle.fill", backgroundColor: SettingsIconColor.yellow)
            cell.accessoryType = .disclosureIndicator
            return cell

        case AdvancedSectionOption.kAdvancedSectionOptionCachedImages.rawValue:
            return self.cacheUsageCell(
                tableView: tableView,
                title: NSLocalizedString("Cached Images", comment: ""),
                systemName: "photo",
                bytes: self.totalImageCacheSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionCachedVideos.rawValue:
            return self.cacheUsageCell(
                tableView: tableView,
                title: NSLocalizedString("Cached Videos", comment: ""),
                systemName: "video",
                bytes: self.totalVideoCacheSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionCachedDocuments.rawValue:
            return self.cacheUsageCell(
                tableView: tableView,
                title: NSLocalizedString("Cached Documents", comment: ""),
                systemName: "doc",
                bytes: self.totalDocumentCacheSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionCacheLimit.rawValue:
            let advancedValueCellIdentifier = "AdvancedValueCellIdentifier"
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: advancedValueCellIdentifier, style: .value1)
            cell.textLabel?.text = NSLocalizedString("Cache limit", comment: "")
            cell.detailTextLabel?.text = MediaUploadDiskStore.formatCacheBytes(NCUserDefaults.fileCacheMaxBytes())
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.setColoredSettingsIcon(systemName: "internaldrive", backgroundColor: SettingsIconColor.gray)
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
            return cell

        case AdvancedSectionOption.kAdvancedSectionOptionUploadStaging.rawValue:
            return self.specialCacheCell(
                title: NSLocalizedString("Upload staging", comment: "Share send temporary upload/ cache"),
                subtitle: String.localizedStringWithFormat(
                    NSLocalizedString("Separate from Cache limit · soft cap %@", comment: "Subtitle under Upload staging; %@ is e.g. 512 MB"),
                    MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.uploadStagingMaxBytes)
                ),
                systemName: "arrow.up.circle",
                iconColor: SettingsIconColor.orange,
                bytes: self.totalUploadStagingSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionConvertCache.rawValue:
            return self.specialCacheCell(
                title: NSLocalizedString("Convert cache", comment: "Encoded media reuse cache"),
                subtitle: String.localizedStringWithFormat(
                    NSLocalizedString("Encode reuse · soft cap %@", comment: "Subtitle under Convert cache; %@ is e.g. 512 MB"),
                    MediaUploadDiskStore.formatCacheBytes(MediaUploadDiskStore.convertCacheMaxBytes)
                ),
                systemName: "arrow.triangle.2.circlepath",
                iconColor: SettingsIconColor.orange,
                bytes: self.totalConvertCacheSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionShareThumbs.rawValue:
            return self.specialCacheCell(
                title: NSLocalizedString("Share thumbs", comment: "Share sheet image thumbnail cache"),
                subtitle: NSLocalizedString("Share-sheet previews · cleared with staging", comment: "Subtitle under Share thumbs"),
                systemName: "rectangle.grid.2x2",
                iconColor: SettingsIconColor.gray,
                bytes: self.totalShareThumbsSize
            )

        case AdvancedSectionOption.kAdvancedSectionOptionSystemPreviews.rawValue:
            return self.specialCacheCell(
                title: NSLocalizedString("System previews", comment: "SDImageCache and URLCache"),
                subtitle: NSLocalizedString("Avatars & chat previews · not Cache limit", comment: "Subtitle under System previews"),
                systemName: "photo.on.rectangle",
                iconColor: SettingsIconColor.gray,
                bytes: self.totalSystemPreviewsSize
            )

        default:
            return UITableViewCell()
        }
    }

    private func specialCacheCell(title: String,
                                  subtitle: String,
                                  systemName: String,
                                  iconColor: UIColor,
                                  bytes: Int64) -> UITableViewCell {
        let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "AdvancedSpecialCacheCell", style: .subtitle)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = subtitle
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        cell.setColoredSettingsIcon(systemName: systemName, backgroundColor: iconColor)
        let byteCounterLabel = UILabel()
        byteCounterLabel.text = MediaUploadDiskStore.formatCacheBytes(bytes)
        byteCounterLabel.textColor = .secondaryLabel
        byteCounterLabel.sizeToFit()
        cell.accessoryView = byteCounterLabel
        cell.accessoryType = .none
        return cell
    }

    func sectionAboutCell(for indexPath: IndexPath) -> UITableViewCell {
        let aboutCellIdentifier = "AboutCellIdentifier"

        let options = getAboutSectionOptions()
        let option = options[indexPath.row]

        switch option {
        case AboutSection.kAboutSectionPrivacy.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: aboutCellIdentifier, style: .default)
            cell.textLabel?.text = NSLocalizedString("Privacy", comment: "")
            cell.setColoredSettingsIcon(systemName: "lock.shield", backgroundColor: SettingsIconColor.gray)
            cell.accessoryType = .disclosureIndicator
            return cell

        case AboutSection.kAboutSectionSourceCode.rawValue:
            let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: aboutCellIdentifier, style: .default)
            cell.textLabel?.text = NSLocalizedString("Get source code", comment: "")
            cell.setColoredSettingsIcon(image: UIImage(named: "github"), backgroundColor: SettingsIconColor.purple)
            cell.accessoryType = .disclosureIndicator
            return cell

        default:
            return UITableViewCell()
        }
    }

    // UIImage should be optional because userProfileImage (objC) can return a nil value
    func getProfilePicture(for account: TalkAccount) -> UIImage? {
        if let avatar = self.profilePictures[account.accountId] {
            return avatar
        }

        return NCAPIController.sharedInstance().userProfileImage(forAccount: account, withStyle: self.traitCollection.userInterfaceStyle)
    }

    private func cacheUsageCell(tableView: UITableView, title: String, systemName: String, bytes: Int64) -> UITableViewCell {
        let cell: SettingsTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: "AdvancedCellIdentifier", style: .default)
        cell.textLabel?.text = title
        cell.setColoredSettingsIcon(systemName: systemName, backgroundColor: SettingsIconColor.blue)
        let byteCounterLabel = UILabel()
        byteCounterLabel.text = MediaUploadDiskStore.formatCacheBytes(bytes)
        byteCounterLabel.textColor = .secondaryLabel
        byteCounterLabel.sizeToFit()
        cell.accessoryView = byteCounterLabel
        cell.accessoryType = .none
        return cell
    }

    func updateCacheUsageSizes() {
        // download/ — same pool as Cache limit (I + V + D).
        let attachments = MediaUploadDiskStore.attachmentCacheUsage()
        self.totalImageCacheSize = attachments.images
        self.totalVideoCacheSize = attachments.videos
        self.totalDocumentCacheSize = attachments.documents
        // Outside Cache limit (listed after Cache limit in Advanced).
        self.totalUploadStagingSize = MediaUploadDiskStore.uploadStagingUsageBytes()
        self.totalConvertCacheSize = MediaUploadDiskStore.convertCacheUsageBytes()
        self.totalShareThumbsSize = MediaUploadDiskStore.thumbsCacheUsageBytes()
        let sd = Int64(SDImageCache.shared.totalDiskSize())
        let url = Int64(URLCache.shared.currentDiskUsage)
        self.totalSystemPreviewsSize = max(0, sd) + max(0, url)
    }
}
