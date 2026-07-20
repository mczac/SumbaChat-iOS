//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import ObjectiveC
import UIKit

/// Option A album protocol: N Talk file messages grouped by `referenceId`.
/// Format: `sumba-album-{uuid}-{index}-{count}` (1-based index). Single-file sends omit album ids.
enum SumbaMediaAlbum {

    typealias Ref = SumbaMediaAlbumReference.Ref

    static let prefix = SumbaMediaAlbumReference.prefix
    static let maxCount = SumbaMediaAlbumReference.maxCount

    static func makeAlbumUUID() -> String {
        SumbaMediaAlbumReference.makeAlbumUUID()
    }

    static func referenceId(uuid: String, index: Int, count: Int) -> String? {
        SumbaMediaAlbumReference.referenceId(uuid: uuid, index: index, count: count)
    }

    static func parse(_ referenceId: String?) -> Ref? {
        SumbaMediaAlbumReference.parse(referenceId)
    }

    /// Collapse consecutive same-actor album members into one primary (last index) with members attached.
    /// Non-album and incomplete (single-member) groups stay as normal rows.
    static func collapseForDisplay(_ messages: [NCChatMessage]) -> [NCChatMessage] {
        let flat = flattenAndDeduplicate(messages)

        var result: [NCChatMessage] = []
        var i = 0
        while i < flat.count {
            let message = flat[i]
            guard let ref = parse(message.referenceId), message.file() != nil else {
                result.append(message)
                i += 1
                continue
            }

            var group: [NCChatMessage] = [message]
            var j = i + 1
            while j < flat.count {
                let next = flat[j]
                guard let nextRef = parse(next.referenceId),
                      nextRef.uuid == ref.uuid,
                      next.file() != nil,
                      next.actorId == message.actorId
                else { break }
                group.append(next)
                j += 1
            }

            // One slot per album index; prefer highest messageId when duplicates slip through.
            var byIndex: [Int: NCChatMessage] = [:]
            for member in group {
                guard let memberRef = parse(member.referenceId) else { continue }
                if let existing = byIndex[memberRef.index] {
                    if member.messageId >= existing.messageId {
                        byIndex[memberRef.index] = member
                    }
                } else {
                    byIndex[memberRef.index] = member
                }
            }
            // Honor wire count when present (caps runaway groups from bad merges).
            let expectedCount = ref.count
            group = (1...expectedCount).compactMap { byIndex[$0] }
            group.sort { (parse($0.referenceId)?.index ?? 0) < (parse($1.referenceId)?.index ?? 0) }

            if group.count >= 2 {
                let primary = group.last!
                for member in group {
                    clearAlbumState(member)
                    member.sumbaIsAlbumSatellite = (member !== primary)
                }
                primary.sumbaIsAlbumSatellite = false
                primary.sumbaAlbumMembers = group
                result.append(primary)
            } else {
                clearAlbumState(message)
                result.append(message)
            }
            i = j
        }
        return result
    }

    /// Expand nested album primaries and drop duplicate messageIds (history refresh used to multiply members).
    private static func flattenAndDeduplicate(_ messages: [NCChatMessage]) -> [NCChatMessage] {
        var flat: [NCChatMessage] = []
        for message in messages {
            if let members = message.sumbaAlbumMembers, members.count >= 2 {
                // Detach nested state before flattening so a former primary cannot re-expand itself.
                let snapshot = members
                clearAlbumState(message)
                for member in snapshot {
                    clearAlbumState(member)
                    flat.append(member)
                }
            } else {
                clearAlbumState(message)
                flat.append(message)
            }
        }

        var seenMessageIds = Set<Int>()
        var seenTempRefs = Set<String>()
        var deduped: [NCChatMessage] = []
        // Walk newest-first so fresher copies win, then restore chronological order.
        for message in flat.reversed() {
            if message.isTemporary {
                let ref = message.referenceId ?? ""
                if !ref.isEmpty {
                    if seenTempRefs.contains(ref) { continue }
                    seenTempRefs.insert(ref)
                }
            } else if message.messageId > 0 {
                if seenMessageIds.contains(message.messageId) { continue }
                seenMessageIds.insert(message.messageId)
            }
            deduped.append(message)
        }
        return deduped.reversed()
    }

    /// Merge `incoming` into an existing album primary in `section` when uuid matches; returns true if consumed.
    static func mergeIncoming(_ incoming: NCChatMessage, into section: inout [NCChatMessage]) -> Bool {
        guard let incomingRef = parse(incoming.referenceId), incoming.file() != nil else { return false }
        clearAlbumState(incoming)

        for index in section.indices {
            let existing = section[index]
            var pool: [NCChatMessage]
            if let members = existing.sumbaAlbumMembers, members.count >= 2 {
                guard let existingRef = parse(existing.referenceId), existingRef.uuid == incomingRef.uuid else { continue }
                pool = members.map { member in
                    clearAlbumState(member)
                    return member
                }
            } else if let existingRef = parse(existing.referenceId),
                      existingRef.uuid == incomingRef.uuid,
                      existing.file() != nil {
                clearAlbumState(existing)
                pool = [existing]
            } else {
                continue
            }

            if let matchIndex = pool.firstIndex(where: { $0.isSameMessage(incoming) }) {
                pool[matchIndex] = incoming
            } else if pool.contains(where: { parse($0.referenceId)?.index == incomingRef.index }) {
                // Same album slot already filled — replace by index rather than appending.
                if let slot = pool.firstIndex(where: { parse($0.referenceId)?.index == incomingRef.index }) {
                    pool[slot] = incoming
                }
            } else {
                pool.append(incoming)
            }

            let collapsed = collapseForDisplay(pool)
            if collapsed.count == 1 {
                let primary = collapsed[0]
                primary.isGroupMessage = existing.isGroupMessage
                section[index] = primary
            } else {
                section.remove(at: index)
                section.insert(contentsOf: collapsed, at: index)
            }
            return true
        }
        return false
    }

    private static func clearAlbumState(_ message: NCChatMessage) {
        message.sumbaAlbumMembers = nil
        message.sumbaIsAlbumSatellite = false
    }

    /// Mosaic outer size — keep in sync with `fileMessageCellMediaFileMaxPreviewWidth`.
    static let mosaicWidth: CGFloat = 230.0

    static func mosaicSize(forCount count: Int) -> CGSize {
        let width = mosaicWidth
        switch count {
        case 2:
            return CGSize(width: width, height: width * 0.55)
        case 3:
            return CGSize(width: width, height: width * 0.85)
        default:
            return CGSize(width: width, height: width)
        }
    }
}

// MARK: - Transient album state on NCChatMessage (not persisted)

private var sumbaAlbumMembersKey: UInt8 = 0
private var sumbaAlbumSatelliteKey: UInt8 = 0

extension NCChatMessage {
    /// Full album members (sorted by index), set only on the display primary.
    @objc var sumbaAlbumMembers: [NCChatMessage]? {
        get { objc_getAssociatedObject(self, &sumbaAlbumMembersKey) as? [NCChatMessage] }
        set { objc_setAssociatedObject(self, &sumbaAlbumMembersKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Hidden from the table when true (covered by primary mosaic). Prefer collapsing out of arrays instead.
    @objc var sumbaIsAlbumSatellite: Bool {
        get { (objc_getAssociatedObject(self, &sumbaAlbumSatelliteKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &sumbaAlbumSatelliteKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc var sumbaIsAlbumPrimary: Bool {
        (sumbaAlbumMembers?.count ?? 0) >= 2
    }
}
