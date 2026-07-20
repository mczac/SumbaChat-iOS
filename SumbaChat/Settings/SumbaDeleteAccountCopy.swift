//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SafariServices
import UIKit

/// Shared delete-account copy and Privacy Policy link (URL from gitignored `NCAppBrandingLocal.h` → `privacyURL`).
///
/// App Review notes (paste-ready):
/// Account deletion: Settings → Account → Delete account. User confirms password; server revokes
/// access and removes personal profile data. Project messages and shared files remain on our
/// private Nextcloud archive under an anonymized label (“Former Team Member”), as stated in the
/// Privacy Policy URL configured in NCAppBrandingLocal.h (`privacyURL`).
enum SumbaDeleteAccountCopy {

    private static var labelPrefix: String {
        SumbaChatClientConfig.anonymizedLabelPrefix
    }

    /// Footnote under the Account screen delete button (aligned with Privacy Policy).
    static var accountScreenFootnote: String {
        String(
            format: NSLocalizedString(
                """
                All your personal identifiable data will be deleted immediately. Shared project messages and files stay archived under “%@”, as described in our Privacy Policy.
                """,
                comment: "Delete account footnote on Account screen; %@ is anonymized label prefix"
            ),
            labelPrefix
        )
    }

    /// Pre-flow alert body (Settings → Account → Delete account).
    static var preflowMessage: String {
        String(
            format: NSLocalizedString(
                """
                All your personal identifiable data will be deleted immediately. Access to SumbaChat is revoked.
                Messages and files you contributed to project repositories remain archived under “%@”, as described in our Privacy Policy.
                """,
                comment: "Delete account pre-flow alert; %@ is anonymized label prefix"
            ),
            labelPrefix
        )
    }

    /// Short retention bullet for password + countdown screens (not deleted yet).
    static var retentionBullet: String {
        String(
            format: NSLocalizedString(
                "If you continue, all your personal identifiable data will be deleted immediately. Shared project messages and files will stay archived under “%@”.",
                comment: "Delete account short retention notice before deletion; %@ is anonymized label prefix"
            ),
            labelPrefix
        )
    }

    static let successMessage = NSLocalizedString(
        "Your account has been deleted. You no longer have access. Shared project content remains archived under an anonymized name.",
        comment: "Delete account success"
    )

    static let alreadyRetiredMessage = NSLocalizedString(
        "This account was already deleted.",
        comment: "Delete account success when alreadyRetired=true"
    )

    static let privacyPolicyActionTitle = NSLocalizedString("Privacy Policy", comment: "")

    /// Opens `privacyURL` (from local branding). Optionally attaches XOR `uid` while still logged in.
    static func openPrivacyPolicy(from presenter: UIViewController, userId: String? = nil) {
        let trimmedUserId = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = (trimmedUserId?.isEmpty == false) ? trimmedUserId : nil
        guard let url = SumbaPrivacyUidEncoder.privacyPolicyURL(baseURL: privacyURL, userId: uid),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        let safari = SFSafariViewController(url: url)
        presenter.present(safari, animated: true)
    }

    static func successSubtitle(anonymizedDisplayName: String?, alreadyRetired: Bool) -> String {
        var parts: [String] = [alreadyRetired ? alreadyRetiredMessage : successMessage]
        if let name = anonymizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(String(
                format: NSLocalizedString(
                    "Archived as “%@”.",
                    comment: "Delete account success; %@ is anonymizedDisplayName from server"
                ),
                name
            ))
        }
        return parts.joined(separator: "\n\n")
    }
}
