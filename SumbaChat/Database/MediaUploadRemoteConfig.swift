//
// SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Talk capabilities hook for SumbaChat remote client settings.
///
/// Compression preferences remain local (`NCUserDefaults` + Debug profiles).
/// Update policy lives in `SumbaChatClientConfig` (`config.sumbachat-client`).
///
/// Invoked from `NCDatabaseManager.setTalkCapabilities` on initial load and
/// whenever `x-nextcloud-talk-hash` changes.
enum MediaUploadRemoteConfig {

    static func applyIfPresent(from capabilitiesDict: [AnyHashable: Any]) {
        SumbaChatClientConfig.applyIfPresent(from: capabilitiesDict)
    }
}
