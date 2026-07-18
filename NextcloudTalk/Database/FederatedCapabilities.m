/**
 * SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */


#import "FederatedCapabilities.h"

@implementation FederatedCapabilities

+ (NSString *)primaryKey
{
    return @"internalId";
}

+ (BOOL)shouldIncludeInDefaultSchema {
    return YES;
}

@end
