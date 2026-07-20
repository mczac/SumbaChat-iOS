//
// SPDX-FileCopyrightText: 2026 Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

#if DEMO_SCREENSHOTS

/// Seeds neutral Sumba Project demo conversations for App Store screenshots.
enum DemoScreenshotSeeder {

    private static var isSeeding = false
    private static var didSeedThisLaunch = false

    static func seedIfNeeded(for account: TalkAccount, completion: (() -> Void)? = nil) {
        guard DemoScreenshotController.isEnabled, !isSeeding else {
            completion?()
            return
        }

        isSeeding = true

        DemoScreenshotImageStore.prepareAssets {
            clearConversationData(for: account.accountId)
            seedRooms(for: account)
            didSeedThisLaunch = true
            isSeeding = false
            completion?()
        }
    }

    static var hasSeededThisLaunch: Bool { didSeedThisLaunch }

    private static func clearConversationData(for accountId: String) {
        let realm = RLMRealm.default()
        try? realm.transaction {
            let roomQuery = NSPredicate(format: "accountId = %@", accountId)
            for case let room as NCRoom in NCRoom.objects(with: roomQuery) {
                let scoped = NSPredicate(format: "accountId = %@ AND token = %@", accountId, room.token)
                realm.deleteObjects(NCChatMessage.objects(with: scoped))
                realm.deleteObjects(NCChatBlock.objects(with: scoped))
                let threadsQuery = NSPredicate(format: "accountId = %@ AND roomToken = %@", accountId, room.token)
                realm.deleteObjects(NCThread.objects(with: threadsQuery))
            }
            realm.deleteObjects(NCRoom.objects(with: roomQuery))
        }
    }

    private static func seedRooms(for account: TalkAccount) {
        let now = Int(Date().timeIntervalSince1970)
        let specs: [DemoRoomSpec] = [
            DemoRoomSpec(
                token: "demo-infra",
                displayName: "Solar & Water Infrastructure",
                lastPreview: "Flow test is scheduled for Thursday.",
                lastActivityOffset: 0,
                messages: heroConversation(for: account, baseTimestamp: now - 3600)
            ),
            DemoRoomSpec(
                token: "demo-site",
                displayName: "Sumba Project — Site Works",
                lastPreview: "Concrete pour for Block C completed on schedule.",
                lastActivityOffset: 7200,
                messages: [previewMessage(account: account, token: "demo-site", id: 2001, offset: 7200, actorId: "demo-civil", actorName: "Budi Santoso", text: "Concrete pour for Block C completed on schedule.")]
            ),
            DemoRoomSpec(
                token: "demo-villa",
                displayName: "Hospitality — Villa Fit-Out",
                lastPreview: "Pool deck mock-up approved for Menara villa.",
                lastActivityOffset: 14_400,
                messages: [previewMessage(account: account, token: "demo-villa", id: 3001, offset: 14_400, actorId: "demo-maria", actorName: "Maria Chen", text: "Pool deck mock-up approved for Menara villa.")]
            ),
            DemoRoomSpec(
                token: "demo-partners",
                displayName: "Partner Coordination",
                lastPreview: "Landscape drawings uploaded for review.",
                lastActivityOffset: 28_800,
                messages: [previewMessage(account: account, token: "demo-partners", id: 4001, offset: 28_800, actorId: "demo-andreas", actorName: "Andreas Weber", text: "Landscape drawings uploaded for review.")]
            ),
            DemoRoomSpec(
                token: "demo-field",
                displayName: "Field Contractors",
                lastPreview: "Crew roster confirmed for well testing.",
                lastActivityOffset: 43_200,
                messages: [previewMessage(account: account, token: "demo-field", id: 5001, offset: 43_200, actorId: "demo-siti", actorName: "Siti Rahayu", text: "Crew roster confirmed for well testing.")]
            ),
            DemoRoomSpec(
                token: "demo-env",
                displayName: "Environmental Review",
                lastPreview: "Ecology walk-through scheduled for Thursday.",
                lastActivityOffset: 86_400,
                messages: [previewMessage(account: account, token: "demo-env", id: 6001, offset: 86_400, actorId: "demo-ecology", actorName: "Dr. Lena Hartono", text: "Ecology walk-through scheduled for Thursday.")]
            ),
            DemoRoomSpec(
                token: "demo-guest",
                displayName: "Guest Experience Planning",
                lastPreview: "Draft hospitality briefing notes are ready.",
                lastActivityOffset: 172_800,
                messages: [previewMessage(account: account, token: "demo-guest", id: 7001, offset: 172_800, actorId: "demo-guest-lead", actorName: "James Okonkwo", text: "Draft hospitality briefing notes are ready.")]
            )
        ]

        let realm = RLMRealm.default()
        try? realm.transaction {
            for spec in specs {
                guard let room = makeRoom(spec: spec, account: account, now: now) else { continue }
                realm.add(room)

                let chatController = NCChatController(for: room)
                let messageDicts = spec.messages.map { $0 as [AnyHashable: Any] }
                chatController?.storeMessages(messageDicts, with: realm)

                guard let lastMessage = spec.messages.last,
                      let parsed = NCChatMessage(dictionary: lastMessage, andAccountId: account.accountId) else { continue }

                let block = NCChatBlock()
                block.internalId = room.internalId
                block.accountId = account.accountId
                block.token = spec.token
                block.threadId = 0
                block.oldestMessageId = spec.messages.first?["id"] as? Int ?? parsed.messageId
                block.newestMessageId = parsed.messageId
                block.hasHistory = true
                realm.add(block)

                if let managedRoom = NCRoom.objects(where: "internalId = %@", room.internalId).firstObject() as? NCRoom {
                    managedRoom.lastMessageId = parsed.internalId
                    managedRoom.lastActivity = parsed.timestamp
                    managedRoom.lastReadMessage = parsed.messageId
                    managedRoom.lastCommonReadMessage = parsed.messageId
                    managedRoom.unreadMessages = 0
                }
            }
        }
    }

    private static func makeRoom(spec: DemoRoomSpec, account: TalkAccount, now: Int) -> NCRoom? {
        let dict: [String: Any] = [
            "token": spec.token,
            "type": NCRoomType.group.rawValue,
            "name": spec.token,
            "displayName": spec.displayName,
            "objectType": "",
            "objectId": "",
            "participantType": NCParticipantType.owner.rawValue,
            "participantFlags": 0,
            "readOnly": NCRoomReadOnlyState.readWrite.rawValue,
            "hasPassword": false,
            "hasCall": false,
            "callStartTime": 0,
            "callRecording": 0,
            "canStartCall": true,
            "lastActivity": now - spec.lastActivityOffset,
            "lastReadMessage": 0,
            "unreadMessages": 0,
            "unreadMention": false,
            "unreadMentionDirect": false,
            "isFavorite": spec.token == "demo-infra",
            "notificationLevel": NCRoomNotificationLevel.default.rawValue,
            "notificationCalls": true,
            "canLeaveConversation": true,
            "canDeleteConversation": false,
            "permissions": NCPermission.chat.rawValue | NCPermission.react.rawValue | NCPermission.startCall.rawValue | NCPermission.joinCall.rawValue | NCPermission.canPublishAudio.rawValue | NCPermission.canPublishVideo.rawValue,
            "mentionPermissions": NCRoomMentionPermissions.everyone.rawValue,
            "isArchived": false,
            "isImportant": false,
            "isSensitive": false
        ]
        return NCRoom(dictionary: dict, andAccountId: account.accountId)
    }

    private static func heroConversation(for account: TalkAccount, baseTimestamp: Int) -> [[String: Any]] {
        [
            textMessage(account: account, token: "demo-infra", id: 1001, timestamp: baseTimestamp, actorId: account.userId, actorName: account.userDisplayName, text: "Morning team — progress photos from the north plot."),
            textMessage(account: account, token: "demo-infra", id: 1002, timestamp: baseTimestamp + 240, actorId: "demo-andreas", actorName: "Andreas Weber", text: "Thanks. Please confirm the solar array footing layout before we pour."),
            textMessage(account: account, token: "demo-infra", id: 1003, timestamp: baseTimestamp + 480, actorId: account.userId, actorName: account.userDisplayName, text: "Footings match the revised plan. Civil signed off yesterday."),
            textMessage(account: account, token: "demo-infra", id: 1004, timestamp: baseTimestamp + 900, actorId: "demo-siti", actorName: "Siti Rahayu", text: "Water well drilling reached 42 m today. Flow test is scheduled for Thursday."),
            fileMessage(account: account, token: "demo-infra", id: 1005, timestamp: baseTimestamp + 1200, actorId: account.userId, actorName: account.userDisplayName, fileId: "demo-file-solar", fileName: "north-plot-solar-layout.jpg", width: 1200, height: 675),
            textMessage(account: account, token: "demo-infra", id: 1006, timestamp: baseTimestamp + 1500, actorId: "demo-andreas", actorName: "Andreas Weber", text: "Strong progress on both workstreams."),
            fileMessage(account: account, token: "demo-infra", id: 1007, timestamp: baseTimestamp + 1800, actorId: "demo-siti", actorName: "Siti Rahayu", fileId: "demo-file-water", fileName: "well-site-water-reserve.webp", width: 768, height: 1152),
            textMessage(account: account, token: "demo-infra", id: 1008, timestamp: baseTimestamp + 2100, actorId: account.userId, actorName: account.userDisplayName, text: "I'll share the hospitality fit-out timeline in the villa channel.")
        ]
    }

    private static func previewMessage(account: TalkAccount, token: String, id: Int, offset: Int, actorId: String, actorName: String, text: String) -> [String: Any] {
        textMessage(
            account: account,
            token: token,
            id: id,
            timestamp: Int(Date().timeIntervalSince1970) - offset,
            actorId: actorId,
            actorName: actorName,
            text: text
        )
    }

    private static func textMessage(account: TalkAccount, token: String, id: Int, timestamp: Int, actorId: String, actorName: String, text: String) -> [String: Any] {
        [
            "id": id,
            "token": token,
            "actorType": "users",
            "actorId": actorId,
            "actorDisplayName": actorName,
            "message": text,
            "messageType": "comment",
            "timestamp": timestamp,
            "isReplyable": true,
            "markdown": false,
            "silent": false
        ]
    }

    private static func fileMessage(account: TalkAccount, token: String, id: Int, timestamp: Int, actorId: String, actorName: String, fileId: String, fileName: String, width: Int, height: Int) -> [String: Any] {
        [
            "id": id,
            "token": token,
            "actorType": "users",
            "actorId": actorId,
            "actorDisplayName": actorName,
            "message": "{file}",
            "messageType": "comment",
            "timestamp": timestamp,
            "isReplyable": true,
            "markdown": false,
            "silent": false,
            "messageParameters": [
                "actor": [
                    "type": "user",
                    "id": actorId,
                    "name": actorName
                ],
                "file": [
                    "type": "file",
                    "id": fileId,
                    "name": fileName,
                    "path": "Demo/\(fileName)",
                    "link": "https://test.sumba.travel/demo/\(fileName)",
                    "mimetype": fileName.hasSuffix(".webp") ? "image/webp" : "image/jpeg",
                    "preview-available": "yes",
                    "width": width,
                    "height": height
                ]
            ]
        ]
    }

    private struct DemoRoomSpec {
        let token: String
        let displayName: String
        let lastPreview: String
        let lastActivityOffset: Int
        let messages: [[String: Any]]
    }
}

#endif
