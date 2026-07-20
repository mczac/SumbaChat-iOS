//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import QuickLook
import UIKit

/// QLPreviewItem with a middle-stripped title so the extension stays visible.
/// Quick Look always end-truncates its nav title; we can't change that style, only the string.
final class FilePreviewItem: NSObject, QLPreviewItem {

    let previewItemURL: URL?
    let previewItemTitle: String?

    /// Nav bar title width is tight (Done + chevron); keep titles short enough that the extension shows.
    private static let titleMaxLength = 28

    init(filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        self.previewItemURL = url
        self.previewItemTitle = NCUtils.middleTruncatedFileName(url.lastPathComponent, maxLength: Self.titleMaxLength)
        super.init()
    }
}
