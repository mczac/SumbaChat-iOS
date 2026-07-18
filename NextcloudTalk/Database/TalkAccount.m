/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "TalkAccount.h"

@implementation TalkAccount

+ (NSString *)primaryKey
{
    return @"accountId";
}

@end
