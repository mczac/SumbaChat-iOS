//
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Applies iOS Settings–style section headers: sentence case (no all-caps), system size.
func applyAppleStyleSectionHeader(_ view: UIView, title: String?) {
    guard let header = view as? UITableViewHeaderFooterView, let title, !title.isEmpty else { return }

    var content = UIListContentConfiguration.groupedHeader()
    content.text = title
    content.textProperties.transform = .none
    header.contentConfiguration = content
}
