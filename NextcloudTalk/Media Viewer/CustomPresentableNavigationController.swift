//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
// SPDX-License-Identifier: GPL-3.0-or-later
//

class CustomPresentableNavigationController: UINavigationController, CustomPresentable {
    var dismissalGestureEnabled: Bool = true
    var transitionManager: UIViewControllerTransitioningDelegate?
}
