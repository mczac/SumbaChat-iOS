//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@objcMembers public class NCChatFileStatus: NSObject {

    public var fileId: String
    public var fileName: String
    public var filePath: String
    public var fileLocalPath: String?
    public var isDownloading: Bool = false
    public var canReportProgress: Bool = false
    public var downloadProgress: Float = 0
    public var completedBytes: Int64 = 0
    public var totalBytes: Int64 = 0

    init(fileId: String, fileName: String, filePath: String, fileLocalPath: String? = nil) {
        self.fileId = fileId
        self.fileName = fileName
        self.filePath = filePath
        self.fileLocalPath = fileLocalPath
    }

    public func isStatus(for messageFileParameter: NCMessageFileParameter) -> Bool {
        return self.fileId == messageFileParameter.parameterId && self.filePath == messageFileParameter.path
    }

    public static func getStatus(from notification: Notification, for messageFileParameter: NCMessageFileParameter) -> NCChatFileStatus? {
        guard let receivedStatus = notification.userInfo?["fileStatus"] as? NCChatFileStatus else { return nil }
        if receivedStatus.isStatus(for: messageFileParameter) {
            return receivedStatus
        }
        // Talk `path` and DAV-relative path can differ; fileId is the stable match for UI.
        if receivedStatus.fileId == messageFileParameter.parameterId {
            return receivedStatus
        }
        return nil
    }
}
