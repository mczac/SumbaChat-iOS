//
// SPDX-FileCopyrightText: 2023 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

@objcMembers
public class NCNotification: NSObject {

    public var notificationId: Int
    public var app: String?
    public var objectId: String
    public var objectType: String
    public var subject: String
    public var subjectRich: String
    public var subjectRichParameters: [AnyHashable: Any]
    public var message: String
    public var messageRich: String
    public var messageRichParameters: [AnyHashable: Any]
    public var actions: [[String: Any]]
    public var datetime: Date?

    init?(dictionary dict: [String: Any]?) {
        guard let dict else { return nil }

        self.notificationId = dict["notification_id"] as? Int ?? 0
        self.app = dict["app"] as? String
        self.objectId = dict["object_id"] as? String ?? ""
        self.objectType = dict["object_type"] as? String ?? ""
        self.subject = dict["subject"] as? String ?? ""
        self.subjectRich = dict["subjectRich"] as? String ?? ""
        self.message = dict["message"] as? String ?? ""
        self.messageRich = dict["messageRich"] as? String ?? ""
        self.actions = dict["actions"] as? [[String: Any]] ?? [[:]]

        self.subjectRichParameters = dict["subjectRichParameters"] as? [AnyHashable: Any] ?? [:]
        self.messageRichParameters = dict["messageRichParameters"] as? [AnyHashable: Any] ?? [:]

        if let datetime = dict["datetime"] as? String {
            let formatter = ISO8601DateFormatter()
            self.datetime = formatter.date(from: datetime)
        }
    }

    public var notificationType: NCNotificationType {
        switch objectType {
        case "chat":
            return .chat
        case "recording":
            return .recording
        case "call":
            return .call
        case "remote_talk_share":
            return .federation
        default:
            return .room
        }
    }

    public var chatMessageAuthor: String {
        if let userDict = subjectRichParameters["user"] as? [AnyHashable: Any], let userName = userDict["name"] as? String {
            return Self.displayName(forAuthorName: userName, authorId: userDict["id"] as? String, authorType: userDict["type"] as? String)
        }

        if let guestDict = subjectRichParameters["guest"] as? [AnyHashable: Any], let guestName = guestDict["name"] as? String {
            return "\(guestName) (\(NSLocalizedString("guest", comment: "")))"
        }

        return NSLocalizedString("Guest", comment: "")
    }

    /// True when the notification author is a Talk bot (used for push avatar overrides).
    public var isBotAuthor: Bool {
        guard let userDict = subjectRichParameters["user"] as? [AnyHashable: Any] else {
            return false
        }
        if let type = userDict["type"] as? String, type == AttendeeType.bots.rawValue {
            return true
        }
        if let authorId = userDict["id"] as? String, authorId.hasPrefix("bot-") {
            return true
        }
        if let name = userDict["name"] as? String, name.localizedCaseInsensitiveContains("(Bot)") {
            return true
        }
        return false
    }

    /// Sumba Assistant bot shown in chat as Mika — use branded push title/avatar.
    public var isMikaBotAuthor: Bool {
        guard isBotAuthor,
              let userDict = subjectRichParameters["user"] as? [AnyHashable: Any] else {
            return false
        }
        let name = (userDict["name"] as? String ?? "").lowercased()
        let authorId = (userDict["id"] as? String ?? "").lowercased()
        return name.contains("mika") || authorId.contains("mika")
    }

    public static let mikaAssistantDisplayName = "Mika (Sumba Assistant)"

    private static func displayName(forAuthorName name: String, authorId: String?, authorType: String?) -> String {
        let isBot = authorType == AttendeeType.bots.rawValue
            || (authorId?.hasPrefix("bot-") ?? false)
            || name.localizedCaseInsensitiveContains("(Bot)")
        let looksLikeMika = name.lowercased().contains("mika") || (authorId?.lowercased().contains("mika") ?? false)

        if isBot && looksLikeMika {
            return mikaAssistantDisplayName
        }
        if name == "Mika (Bot)" {
            return mikaAssistantDisplayName
        }
        return name
    }

    public var chatMessageTitle: String {
        var title = self.chatMessageAuthor

        // Check if the room has a name
        for match in self.subjectRich.ranges(of: /\{([^}]+)\}/) {
            let parameterKey = self.subjectRich[match].replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")

            if parameterKey == "reaction" {
                return self.subject
            }

            if parameterKey == "call",
                let subjectDict = self.subjectRichParameters["call"] as? [AnyHashable: Any],
                let callName = subjectDict["name"] as? String {

                let inString = NSLocalizedString("in", comment: "")
                title = "\(title) \(inString) \(callName)"
            }

        }

        return title
    }

    public var roomToken: String {
        // Starting with NC 24 objectId additionally contains the messageId: "{roomToken}/{messageId}"
        return objectId.components(separatedBy: "/").first ?? objectId
    }

    /// Chat message id from `object_id` (`{roomToken}/{messageId}` or with thread suffix).
    public var messageId: Int {
        let components = objectId.components(separatedBy: "/")
        guard components.count >= 2 else { return -1 }
        return Int(components[1]) ?? -1
    }

    public var threadId: Int {
        // Starting with Talk 22 objectId additionally contains the threadId: "{roomToken}/{messageId}/{threadId}"
        let components = objectId.components(separatedBy: "/")

        if components.count > 2 {
            return Int(components[2]) ?? -1
        }

        return -1
    }

    public var notificationActions: [NCNotificationAction] {
        return actions.compactMap { NCNotificationAction(dictionary: $0) }
    }
}
