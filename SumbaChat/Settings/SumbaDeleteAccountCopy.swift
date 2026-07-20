//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SafariServices
import UIKit

/// Shared delete-account copy and Privacy Policy link (URL from gitignored `NCAppBrandingLocal.h` → `privacyURL`).
///
/// Account deletion: Settings → Account → Delete account (when `accountRetire.enabled`).
/// User confirms password; server retires via `talk_upload_policy` and revokes the session.
/// Wording aligned with Privacy Policy §5B (profile/access removal) and §5C (project archive retention).
enum SumbaDeleteAccountCopy {

    private static var labelPrefix: String {
        SumbaChatClientConfig.anonymizedLabelPrefix
    }

    private static var retainsProjectData: Bool {
        SumbaChatClientConfig.accountRetireRetainsProjectData
    }

    /// Privacy Policy §5B — profile fields removed and access revoked.
    private static var profileRemovalSummary: String {
        NSLocalizedString(
            "Your profile (name, email, avatar) and login access will be removed immediately.",
            comment: "Delete account: profile and access removal (Privacy Policy §5B)"
        )
    }

    /// Privacy Policy §5C — archived contributions stay visible under anonymized label.
    private static func archiveRetentionDetail() -> String? {
        guard retainsProjectData else { return nil }
        return String(
            format: NSLocalizedString(
                """
                Messages and files you contributed to project chats stay in the archive under “%@”. The text and files you shared remain visible to other participants, disassociated from your name.
                """,
                comment: "Delete account: project archive retention; %@ is anonymized label prefix (Privacy Policy §5C)"
            ),
            labelPrefix
        )
    }

    private static func joinedParagraphs(_ parts: [String?]) -> String {
        parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Footnote under Delete account on the Account screen (keep to ~2 lines).
    static var accountScreenFootnote: String {
        NSLocalizedString(
            "Permanently removes your profile and login access.\nThis cannot be undone.",
            comment: "Delete account: short footnote under button on Account screen"
        )
    }

    /// Pre-flow alert body (Settings → Account → Delete account).
    static var preflowMessage: String {
        NSLocalizedString(
            "This permanently deletes your account and cannot be undone.",
            comment: "Delete account pre-flow alert (short)"
        )
    }

    /// Full explanation on the password confirmation screen (Privacy Policy §5B/§5C).
    static var confirmationMessage: String {
        joinedParagraphs([
            profileRemovalSummary,
            archiveRetentionDetail(),
            NSLocalizedString(
                "This cannot be undone.",
                comment: "Delete account confirmation irreversibility"
            )
        ])
    }

    /// One-line reminder during the countdown (details were on the confirmation screen).
    static var countdownReminder: String? {
        guard retainsProjectData else { return nil }
        return String(
            format: NSLocalizedString(
                "Shared project content stays in the archive under “%@”.",
                comment: "Delete account countdown short reminder; %@ is anonymized label prefix"
            ),
            labelPrefix
        )
    }

    static var successMessage: String {
        if retainsProjectData {
            return NSLocalizedString(
                "Your account has been deleted. You no longer have access. Shared project content remains in the archive under an anonymized name.",
                comment: "Delete account success when project data is retained"
            )
        }
        return NSLocalizedString(
            "Your account has been deleted. You no longer have access.",
            comment: "Delete account success when project data is not retained"
        )
    }

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
        if retainsProjectData,
           let name = anonymizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
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
