//
// SPDX-FileCopyrightText: 2022 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import libPhoneNumber

enum ProfileSection: Int {
    case kProfileSectionName = 0
    case kProfileSectionEmail
    case kProfileSectionPhoneNumber
    case kProfileSectionAddress
    case kProfileSectionWebsite
    case kProfileSectionTwitter
    case kProfileSectionSummary
    case kProfileSectionRemoveAccount
}

enum SummaryRow: Int {
    case kSummaryRowEmail = 0
    case kSummaryRowPhoneNumber
    case kSummaryRowAddress
    case kSummaryRowWebsite
    case kSummaryRowTwitter
}

@objcMembers
class UserProfileTableViewController: UITableViewController, DetailedOptionsSelectorTableViewControllerDelegate, TOCropViewControllerDelegate {

    let kNameTextFieldTag       = 99
    let kEmailTextFieldTag      = 98
    let kPhoneTextFieldTag      = 97
    let kAddressTextFieldTag    = 96
    let kWebsiteTextFieldTag    = 95
    let kTwitterTextFieldTag    = 94
    let kAvatarScopeButtonTag   = 93

    let iconConfiguration = UIImage.SymbolConfiguration(pointSize: 18)
    let iconHeaderConfiguration = UIImage.SymbolConfiguration(pointSize: 13)

    var account = TalkAccount()
    var isEditable = Bool()
    var waitingForModification = Bool()
    var editButton = UIBarButtonItem()
    var activeTextField: UITextField?
    var modifyingProfileView = UIActivityIndicatorView()
    var imagePicker: UIImagePickerController?
    var setPhoneAction = UIAlertAction()
    var editableFields = NSArray()
    var showScopes = Bool()
    /// `nil` = still checking; drives green / orange / red on the Switch server row.
    var serverStatus: SumbaServerConfiguration.ServerStatus?

    private lazy var deleteAccountButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Delete account", comment: "")
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 17, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(deleteAccountButtonTapped), for: .touchUpInside)
        return button
    }()

    private lazy var deleteAccountFootnoteLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.text = SumbaDeleteAccountCopy.accountScreenFootnote
        return label
    }()

    private lazy var deleteAccountFooterStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [deleteAccountButton, deleteAccountFootnoteLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        NCAppBranding.styleViewController(self)

        self.navigationItem.title = NSLocalizedString("Account", comment: "")

        self.tableView.tableHeaderView = self.avatarHeaderView()
        self.showEditButton()
        self.getUserProfileEditableFields()

        if let serverCapabilities = NCDatabaseManager.sharedInstance().serverCapabilities(forAccountId: account.accountId) {
            showScopes = serverCapabilities.accountPropertyScopesVersion2
        }

        modifyingProfileView = UIActivityIndicatorView()
        if #unavailable(iOS 26.0) {
            modifyingProfileView.color = NCAppBranding.themeTextColor()
        }

        tableView.keyboardDismissMode = UIScrollView.KeyboardDismissMode.onDrag
        tableView.register(TextFieldTableViewCell.self, forCellReuseIdentifier: TextFieldTableViewCell.identifier)
        NotificationCenter.default.addObserver(self, selector: #selector(userProfileImageUpdated), name: NSNotification.Name.NCUserProfileImageUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accountRetireCapabilitiesUpdated), name: .NCServerCapabilitiesUpdated, object: nil)

        refreshDeleteAccountFooter()

        if navigationController?.viewControllers.first == self {
            let barButtonItem = UIBarButtonItem(title: nil, style: .plain, target: nil, action: nil)
            barButtonItem.primaryAction = UIAction(title: NSLocalizedString("Close", comment: ""), handler: { [unowned self] _ in
                self.dismiss(animated: true)
            })
            self.navigationItem.leftBarButtonItems = [barButtonItem]
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshServerReachability()
        refreshAccountRetireCapabilities()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Workaround to fix label width
        guard let headerView = self.tableView.tableHeaderView as? AvatarEditView else {return}
        guard var labelFrame = headerView.nameLabel?.frame else {return}
        let padding: CGFloat = 16
        labelFrame.origin.x = padding
        labelFrame.size.width = self.tableView.bounds.size.width - padding * 2
        headerView.nameLabel?.frame = labelFrame

        updateDeleteAccountFooterInset()
    }

    private var isDeleteAccountAvailable: Bool {
        SumbaChatClientConfig.accountRetireSupported
    }

    @objc private func accountRetireCapabilitiesUpdated() {
        refreshDeleteAccountFooter()
    }

    private func refreshAccountRetireCapabilities() {
        NCSettingsController.sharedInstance().getCapabilitiesForAccountId(account.accountId) { [weak self] _ in
            self?.refreshDeleteAccountFooter()
        }
    }

    private func ensureDeleteAccountFooterInstalled() {
        guard deleteAccountFooterStack.superview == nil else { return }

        view.addSubview(deleteAccountFooterStack)

        NSLayoutConstraint.activate([
            deleteAccountFooterStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            deleteAccountFooterStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            deleteAccountFooterStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            deleteAccountButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func refreshDeleteAccountFooter() {
        deleteAccountFootnoteLabel.text = SumbaDeleteAccountCopy.accountScreenFootnote

        if isDeleteAccountAvailable {
            ensureDeleteAccountFooterInstalled()
            deleteAccountFooterStack.isHidden = false
        } else {
            deleteAccountFooterStack.isHidden = true
        }

        updateDeleteAccountFooterInset()
    }

    private func updateDeleteAccountFooterInset() {
        guard isDeleteAccountAvailable, deleteAccountFooterStack.superview != nil else {
            if tableView.contentInset.bottom != 0 {
                tableView.contentInset.bottom = 0
                tableView.verticalScrollIndicatorInsets.bottom = 0
            }
            return
        }

        let footerHeight = deleteAccountFooterStack.bounds.height + 24
        if abs(tableView.contentInset.bottom - footerHeight) > 0.5 {
            tableView.contentInset.bottom = footerHeight
            tableView.verticalScrollIndicatorInsets.bottom = footerHeight
        }
    }

    init(withAccount account: TalkAccount) {
        super.init(style: .insetGrouped)
        self.account = account
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return self.getProfileSections().count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let sections = self.getProfileSections()
        let profileSection = sections[section]
        if profileSection == ProfileSection.kProfileSectionSummary.rawValue {
            return self.rowsInSummarySection().count
        }
        if profileSection == ProfileSection.kProfileSectionRemoveAccount.rawValue {
            // Switch server (keep current account) + Log out
            return 2
        }
        return 1
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let sections = self.getProfileSections()
        let profileSection = sections[section]
        switch profileSection {
        case ProfileSection.kProfileSectionName.rawValue,
            ProfileSection.kProfileSectionEmail.rawValue,
            ProfileSection.kProfileSectionPhoneNumber.rawValue,
            ProfileSection.kProfileSectionAddress.rawValue,
            ProfileSection.kProfileSectionWebsite.rawValue,
            ProfileSection.kProfileSectionTwitter.rawValue,
            ProfileSection.kProfileSectionRemoveAccount.rawValue:
            return 40
        case ProfileSection.kProfileSectionSummary.rawValue:
            return 20
        default:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let sections = self.getProfileSections()
        let profileSection = sections[section]
        let headerView = setupViewforHeaderInSection(profileSection: profileSection)
        if headerView.button.tag != 0 {
            return headerView
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let sections = self.getProfileSections()
        let profileSection = sections[section]
        if profileSection == ProfileSection.kProfileSectionEmail.rawValue {
            return NSLocalizedString("For password reset and notifications", comment: "")
        }
        if profileSection == ProfileSection.kProfileSectionRemoveAccount.rawValue {
            // Always show a footer so status changes don’t insert/remove a block and shift Log out.
            // Same copy for all statuses so orange/red keep the “account stays connected” clarity.
            return NSLocalizedString(
                "Tap to sign in on another server. Your current account stays connected.",
                comment: "Footer under Switch server"
            )
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = self.getProfileSections()[indexPath.section]
        switch section {
        case ProfileSection.kProfileSectionName.rawValue:
            return textInputCellWith(text: account.userDisplayName,
                                     tag: kNameTextFieldTag,
                                     interactionEnabled: editableFields.contains(UserProfileField.displayName))
        case ProfileSection.kProfileSectionEmail.rawValue:
            return textInputCellWith(text: account.email,
                                     tag: kEmailTextFieldTag,
                                     interactionEnabled: editableFields.contains(UserProfileField.email),
                                     keyBoardType: .emailAddress,
                                     autocapitalizationType: .none,
                                     placeHolder: NSLocalizedString("Your email address", comment: ""))
        case ProfileSection.kProfileSectionPhoneNumber.rawValue:
            let phoneNumber = try? NBPhoneNumberUtil.sharedInstance().parse(account.phone, defaultRegion: nil)
            let text = (phoneNumber != nil) ? try? NBPhoneNumberUtil.sharedInstance().format(phoneNumber, numberFormat: NBEPhoneNumberFormat.INTERNATIONAL) : nil
            return textInputCellWith(text: text,
                                     tag: kPhoneTextFieldTag,
                                     interactionEnabled: false,
                                     keyBoardType: .phonePad,
                                     autocapitalizationType: .none,
                                     placeHolder: NSLocalizedString("Your phone number", comment: ""))
        case ProfileSection.kProfileSectionAddress.rawValue:
            return textInputCellWith(text: account.address,
                                     tag: kAddressTextFieldTag,
                                     interactionEnabled: editableFields.contains(UserProfileField.address),
                                     placeHolder: NSLocalizedString("Your postal address", comment: ""))
        case ProfileSection.kProfileSectionWebsite.rawValue:
            return textInputCellWith(text: account.website,
                                     tag: kWebsiteTextFieldTag,
                                     interactionEnabled: editableFields.contains(UserProfileField.website),
                                     keyBoardType: .URL,
                                     autocapitalizationType: .none,
                                     placeHolder: NSLocalizedString("Link https://…", comment: ""))
        case ProfileSection.kProfileSectionTwitter.rawValue:
            return textInputCellWith(text: account.twitter,
                                     tag: kTwitterTextFieldTag,
                                     interactionEnabled: editableFields.contains(UserProfileField.twitter),
                                     keyBoardType: .emailAddress,
                                     autocapitalizationType: .none,
                                     placeHolder: NSLocalizedString("Twitter handle @…", comment: ""))
        case ProfileSection.kProfileSectionSummary.rawValue:
            return summaryCellForRow(row: indexPath.row)
        case ProfileSection.kProfileSectionRemoveAccount.rawValue:
            if indexPath.row == 0 {
                return switchServerCell()
            }
            let actionTitle = NSLocalizedString("Log out", comment: "")
            let actionImage = UIImage(systemName: "arrow.right.square")?.applyingSymbolConfiguration(iconConfiguration)
            return actionCellWith(identifier: "RemoveAccountCellIdentifier", text: actionTitle, textColor: .systemRed, image: actionImage, tintColor: .systemRed)
        default:
            break
        }
        return UITableViewCell()
    }

    @objc private func deleteAccountButtonTapped() {
        guard isDeleteAccountAvailable else { return }
        presentDeleteAccountFlow()
    }


    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let sections = getProfileSections()
        let section = sections[indexPath.section]
        if section == ProfileSection.kProfileSectionRemoveAccount.rawValue {
            if indexPath.row == 0 {
                self.switchServer()
            } else {
                self.showLogoutConfirmationDialog()
            }
        } else if section == ProfileSection.kProfileSectionPhoneNumber.rawValue {
            self.presentSetPhoneNumberDialog()
        }
        self.tableView.deselectRow(at: indexPath, animated: true)
    }
}

extension UserProfileTableViewController {

    // MARK: Header View Setup

    func setupViewForSection(headerView: inout HeaderWithButton, title: String, buttonTag: Int, enabled: Bool?, scopeForImage: String) {
        headerView.label.text = title
        headerView.button.tag = buttonTag
        if let enabled = enabled {
            headerView.button.isEnabled = enabled
        }
        headerView.button.setImage(self.imageForScope(scope: scopeForImage)?.applyingSymbolConfiguration(iconHeaderConfiguration), for: .normal)
    }

    func setupViewforHeaderInSection(profileSection: Int) -> HeaderWithButton {
        var headerView = HeaderWithButton()
        headerView.button.addTarget(self, action: #selector(showScopeSelectionDialog(_:)), for: .touchUpInside)

        var shouldEnableNameAndEmailScopeButton = false

        if let serverCapabilities = NCDatabaseManager.sharedInstance().serverCapabilities(forAccountId: account.accountId) {
            shouldEnableNameAndEmailScopeButton = serverCapabilities.accountPropertyScopesFederationEnabled ||
            serverCapabilities.accountPropertyScopesFederatedEnabled || serverCapabilities.accountPropertyScopesPublishedEnabled
        }

        switch profileSection {
        case ProfileSection.kProfileSectionName.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Full name", comment: ""), buttonTag: kNameTextFieldTag,
                                enabled: shouldEnableNameAndEmailScopeButton, scopeForImage: account.userDisplayNameScope)
        case ProfileSection.kProfileSectionEmail.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Email", comment: ""), buttonTag: kEmailTextFieldTag,
                                enabled: shouldEnableNameAndEmailScopeButton, scopeForImage: account.emailScope)
        case ProfileSection.kProfileSectionPhoneNumber.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Phone number", comment: ""), buttonTag: kPhoneTextFieldTag,
                                enabled: nil, scopeForImage: account.phoneScope)
        case ProfileSection.kProfileSectionAddress.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Address", comment: ""), buttonTag: kAddressTextFieldTag,
                                enabled: nil, scopeForImage: account.addressScope)
        case ProfileSection.kProfileSectionWebsite.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Website", comment: ""), buttonTag: kWebsiteTextFieldTag,
                                enabled: nil, scopeForImage: account.websiteScope)
        case ProfileSection.kProfileSectionTwitter.rawValue:
            setupViewForSection(headerView: &headerView, title: NSLocalizedString("Twitter", comment: ""), buttonTag: kTwitterTextFieldTag,
                                enabled: nil, scopeForImage: account.twitterScope)
        default:
            break
        }
        return headerView
    }

    // MARK: Setup cells

    func textInputCellWith(text: String?, tag: Int, interactionEnabled: Bool, keyBoardType: UIKeyboardType = .default, autocapitalizationType: UITextAutocapitalizationType = .sentences, placeHolder: String = "") -> TextFieldTableViewCell {
        let textInputCell: TextFieldTableViewCell = tableView.dequeueOrCreateCell(withIdentifier: TextFieldTableViewCell.identifier)

        textInputCell.textField.delegate = self
        textInputCell.textField.text = text
        textInputCell.textField.tag = tag
        textInputCell.textField.isUserInteractionEnabled = interactionEnabled
        textInputCell.textField.keyboardType = keyBoardType
        textInputCell.textField.autocapitalizationType = autocapitalizationType
        textInputCell.textField.placeholder = placeHolder

        return textInputCell
    }

    func summaryCellForRow(row: Int) -> UITableViewCell {
        let summaryCell = tableView.dequeueReusableCell(withIdentifier: "SummaryCellIdentifier") ?? UITableViewCell(style: .default, reuseIdentifier: "SummaryCellIdentifier")
        let summaryRow = self.rowsInSummarySection()[row]
        switch summaryRow {
        case SummaryRow.kSummaryRowEmail.rawValue:
            summaryCell.textLabel?.text = account.email
            summaryCell.imageView?.image = UIImage(systemName: "envelope")?.applyingSymbolConfiguration(iconConfiguration)
        case SummaryRow.kSummaryRowPhoneNumber.rawValue:
            let phoneNumber = try? NBPhoneNumberUtil.sharedInstance().parse(account.phone, defaultRegion: nil)
            let text = (phoneNumber != nil) ? try? NBPhoneNumberUtil.sharedInstance().format(phoneNumber, numberFormat: NBEPhoneNumberFormat.INTERNATIONAL) : nil
            summaryCell.textLabel?.text = text
            summaryCell.imageView?.image = UIImage(systemName: "iphone")?.applyingSymbolConfiguration(iconConfiguration)
        case SummaryRow.kSummaryRowAddress.rawValue:
            summaryCell.textLabel?.text = account.address
            summaryCell.imageView?.image = UIImage(systemName: "mappin")?.applyingSymbolConfiguration(iconConfiguration)
        case SummaryRow.kSummaryRowWebsite.rawValue:
            summaryCell.textLabel?.text = account.website
            summaryCell.imageView?.image = UIImage(systemName: "network")?.applyingSymbolConfiguration(iconConfiguration)
        case SummaryRow.kSummaryRowTwitter.rawValue:
            summaryCell.textLabel?.text = account.twitter
            summaryCell.imageView?.image = UIImage(named: "twitter")?.withRenderingMode(.alwaysTemplate)
        default:
            break
        }

        summaryCell.imageView?.tintColor = .secondaryLabel

        return summaryCell
    }

    func actionCellWith(identifier: String, text: String, textColor: UIColor, image: UIImage?, tintColor: UIColor) -> UITableViewCell {
        let actionCell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .default, reuseIdentifier: identifier)

        actionCell.textLabel?.text = text
        actionCell.textLabel?.textColor = textColor
        actionCell.imageView?.image = image?.withRenderingMode(.alwaysTemplate)
        actionCell.imageView?.tintColor = tintColor

        return actionCell
    }

    func switchServerCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchServerCellIdentifier")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SwitchServerCellIdentifier")

        cell.textLabel?.text = SumbaServerConfiguration.displayHost(fromServerURL: account.server)
        cell.textLabel?.textColor = .label
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.lineBreakMode = .byTruncatingMiddle
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        switch serverStatus {
        case .online:
            cell.detailTextLabel?.text = NSLocalizedString("SumbaChat server is online", comment: "")
        case .maintenance:
            cell.detailTextLabel?.text = NSLocalizedString("SumbaChat server is under maintenance", comment: "")
        case .offline:
            cell.detailTextLabel?.text = NSLocalizedString("SumbaChat server is offline", comment: "")
        case .none:
            cell.detailTextLabel?.text = NSLocalizedString("Checking server…", comment: "")
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 1
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.imageView?.subviews.forEach { $0.removeFromSuperview() }
        // Align with Email / Log out left icons; status stays on the trailing accessory.
        cell.imageView?.image = UIImage(systemName: "server.rack")?.applyingSymbolConfiguration(iconConfiguration)
        cell.imageView?.tintColor = .secondaryLabel
        cell.accessoryType = .none
        cell.accessoryView = switchServerAccessoryView(status: serverStatus)

        return cell
    }

    /// Trailing accessory: fixed-size status slot (spinner or dot) + disclosure chevron.
    /// Fixed slot size keeps cell layout stable when status resolves.
    private func switchServerAccessoryView(status: SumbaServerConfiguration.ServerStatus?) -> UIView {
        let statusSlotSize: CGFloat = 20
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8

        let statusSlot = UIView()
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusSlot.widthAnchor.constraint(equalToConstant: statusSlotSize),
            statusSlot.heightAnchor.constraint(equalToConstant: statusSlotSize)
        ])

        if let status {
            let dot = UIImageView(image: UIImage(systemName: "circle.fill"))
            dot.translatesAutoresizingMaskIntoConstraints = false
            switch status {
            case .online:
                dot.tintColor = .systemGreen
            case .maintenance:
                dot.tintColor = .systemOrange
            case .offline:
                dot.tintColor = .systemRed
            }
            statusSlot.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 12),
                dot.heightAnchor.constraint(equalToConstant: 12),
                dot.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor)
            ])
        } else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.color = .secondaryLabel
            spinner.startAnimating()
            statusSlot.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor)
            ])
        }
        stack.addArrangedSubview(statusSlot)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(chevron)

        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        stack.bounds = CGRect(origin: .zero, size: size)
        return stack
    }

    func reloadSwitchServerSection() {
        guard let section = getProfileSections().firstIndex(of: ProfileSection.kProfileSectionRemoveAccount.rawValue) else {
            return
        }
        // Row + footer together (footer copy changes with status; all states reserve space).
        tableView.reloadSections(IndexSet(integer: section), with: .none)
    }

    func refreshServerReachability() {
        let previous = serverStatus
        // Keep last known color while re-checking to avoid spinner↔dot flicker on re-entry.
        if previous == nil {
            reloadSwitchServerSection()
        }

        let server = account.server
        SumbaServerConfiguration.checkServerStatus(serverURL: server) { [weak self] status in
            guard let self else { return }
            guard self.serverStatus != status else { return }
            self.serverStatus = status
            self.reloadSwitchServerSection()
        }
    }
}
