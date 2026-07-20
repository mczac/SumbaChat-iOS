//
// SPDX-FileCopyrightText: 2022 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import libPhoneNumber

extension UserProfileTableViewController {

    @objc func editButtonPressed() {
        if activeTextField != nil {
            self.waitingForModification = true
            activeTextField?.resignFirstResponder()
            return
        }
        if !isEditable {
            isEditable = true
            self.showDoneButton()
        } else {
            isEditable = false
            self.showEditButton()
        }
        self.refreshProfileTableView()
    }

    func addNewAccount() {
        self.dismiss(animated: true) {
            NCUserInterfaceController.sharedInstance().presentLoginViewController()
        }
    }

    /// Opens login for another Sumba host without logging out of the current account.
    func switchServer() {
        let subdomain = SumbaServerConfiguration.subdomain(fromServerURL: account.server)
            ?? SumbaServerConfiguration.preferredSubdomain
        // Prefer email for login prefill; fall back to Nextcloud username.
        let prefillUser: String? = {
            let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty { return email }
            let user = account.user.trimmingCharacters(in: .whitespacesAndNewlines)
            return user.isEmpty ? nil : user
        }()
        dismiss(animated: true) {
            NCUserInterfaceController.sharedInstance().presentLoginViewController(
                forServerURL: SumbaServerConfiguration.serverURL(subdomain: subdomain),
                withUser: prefillUser
            )
        }
    }

    func showLogoutConfirmationDialog() {
        let confirmDialog = UIAlertController(
            title: NSLocalizedString("Log out", comment: ""),
            message: NSLocalizedString("Do you really want to log out from this account?", comment: ""),
            preferredStyle: .alert
        )
        let confirmAction = UIAlertAction(title: NSLocalizedString("Log out", comment: ""), style: .destructive) { _ in
            self.logout()
        }
        confirmDialog.addAction(confirmAction)
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)
        confirmDialog.addAction(cancelAction)
        self.present(confirmDialog, animated: true, completion: nil)
    }

    func logout() {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        NCSettingsController.sharedInstance().logoutAccount(withAccountId: activeAccount.accountId) { _ in
            NCUserInterfaceController.sharedInstance().presentConversationsList()
            NCConnectionController.shared.checkAppState()
        }
    }

    func presentSetPhoneNumberDialog() {
        let setPhoneNumberDialog = UIAlertController(title: NSLocalizedString("Phone number", comment: ""), message: nil, preferredStyle: .alert)
        let hasPhone = !account.phone.isEmpty
        setPhoneNumberDialog.addTextField { [self] textField in
            let regionCode = NSLocale.current.regionCode
            let countryCode = NBPhoneNumberUtil.sharedInstance().getCountryCode(forRegion: regionCode)
            if let countryCode = countryCode {
                textField.text = "+\(countryCode)"
            }
            if hasPhone {
                textField.text = self.account.phone
            }
            let exampleNumber = try? NBPhoneNumberUtil.sharedInstance().getExampleNumber(regionCode ?? "")
            if let exampleNumber = exampleNumber {
                textField.placeholder = try? NBPhoneNumberUtil.sharedInstance().format(exampleNumber, numberFormat: NBEPhoneNumberFormat.INTERNATIONAL)
                textField.keyboardType = .phonePad
                textField.delegate = self
                textField.tag = self.kPhoneTextFieldTag
            }
        }
        setPhoneAction = UIAlertAction(title: NSLocalizedString("Set", comment: ""), style: .default, handler: { _ in
            let phoneNumber = setPhoneNumberDialog.textFields?[0].text
            if let phoneNumber = phoneNumber {
                self.setPhoneNumber(phoneNumber)
            }
        })
        setPhoneAction.isEnabled = false
        setPhoneNumberDialog.addAction(setPhoneAction)
        if hasPhone {
            let removeAction = UIAlertAction(title: NSLocalizedString("Remove", comment: ""), style: .destructive) { _ in
                self.setPhoneNumber("")
            }
            setPhoneNumberDialog.addAction(removeAction)
        }
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)
        setPhoneNumberDialog.addAction(cancelAction)
        self.present(setPhoneNumberDialog, animated: true, completion: nil)
    }

    func setPhoneNumber(_ phoneNumber: String) {
        self.setModifyingProfileUI()
        NCAPIController.sharedInstance().setUserProfileField(UserProfileField.phone, withValue: phoneNumber, forAccount: account) { error in
            if error != nil {
                self.showProfileModificationErrorForField(inTextField: self.kPhoneTextFieldTag, textField: nil)
            } else {
                self.refreshUserProfile()
            }
            self.removeModifyingProfileUI()
        }
    }
}
