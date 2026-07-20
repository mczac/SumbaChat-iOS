//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Wire format for album `referenceId` values (shared by chat UI, share, and push NSE).
/// Format: `sumba-album-{uuid}-{index}-{count}` (1-based index). Single-file sends omit album ids.
enum SumbaMediaAlbumReference {

    static let prefix = "sumba-album-"
    static let maxCount = 50

    struct Ref: Equatable {
        let uuid: String
        let index: Int
        let count: Int

        var referenceId: String {
            "\(SumbaMediaAlbumReference.prefix)\(uuid)-\(index)-\(count)"
        }

        /// Last member carries the optional caption and should be the only push (others silent).
        var isLastMember: Bool {
            index == count
        }
    }

    static func makeAlbumUUID() -> String {
        UUID().uuidString.lowercased()
    }

    static func referenceId(uuid: String, index: Int, count: Int) -> String? {
        guard count >= 2, count <= maxCount, index >= 1, index <= count else { return nil }
        return Ref(uuid: uuid, index: index, count: count).referenceId
    }

    static func parse(_ referenceId: String?) -> Ref? {
        guard let referenceId, referenceId.hasPrefix(prefix) else { return nil }
        let body = String(referenceId.dropFirst(prefix.count))
        // uuid is 36 chars with hyphens; then -index-count
        guard body.count > 38 else { return nil }
        let uuid = String(body.prefix(36))
        let rest = String(body.dropFirst(36))
        guard rest.first == "-" else { return nil }
        let parts = rest.dropFirst().split(separator: "-")
        guard parts.count == 2,
              let index = Int(parts[0]),
              let count = Int(parts[1]),
              count >= 2, count <= maxCount,
              index >= 1, index <= count,
              isUUIDV4(uuid)
        else { return nil }
        return Ref(uuid: uuid, index: index, count: count)
    }

    /// Push body: message first, then count — e.g. `Hey (4 media files)`. No caption → `4 media files`.
    /// (Notification body is plain text; different font sizes aren't supported.)
    static func notificationBody(count: Int, caption: String?) -> String {
        let mediaLabel = String.localizedStringWithFormat(
            NSLocalizedString("%d media files", comment: "Push notification label for a media album; %d is the number of files"),
            count
        )
        if let userText = cleanedUserCaption(caption) {
            return "\(userText) (\(mediaLabel))"
        }
        return mediaLabel
    }

    /// Strip synthetic album summary lines we briefly stored as caption / old push format.
    /// Chat should show only the user's text.
    static func cleanedUserCaption(_ stored: String?) -> String? {
        guard let stored else { return nil }
        var text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "{file}" else { return nil }

        // Old format: "4 media files\nHey"
        let lines = text.components(separatedBy: "\n")
        if let first = lines.first, isMediaFilesOnlyLine(first) {
            text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "{file}" else { return nil }
        }

        // New push format accidentally stored: "Hey (4 media files)"
        if let stripped = stripTrailingMediaFilesSuffix(text) {
            text = stripped
            guard !text.isEmpty else { return nil }
        }

        return text
    }

    private static func isMediaFilesOnlyLine(_ line: String) -> Bool {
        line.range(of: #"^\d+ media files$"#, options: .regularExpression) != nil
    }

    private static func stripTrailingMediaFilesSuffix(_ text: String) -> String? {
        guard let range = text.range(of: #" \(\d+ media files\)$"#, options: .regularExpression) else {
            return nil
        }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUUIDV4(_ value: String) -> Bool {
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
