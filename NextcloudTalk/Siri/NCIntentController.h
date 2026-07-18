/**
 * SPDX-FileCopyrightText: 2021 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Intents/INSendMessageIntent.h>
#import <Intents/INSendMessageIntent+UserNotifications.h>

#import "NCRoom.h"

typedef void (^GetInteractionForRoomCompletionBlock)(INSendMessageIntent *sendMessageIntent);

@interface NCIntentController : NSObject

+ (instancetype)sharedInstance;

- (void)donateSendMessageIntentForRoom:(NCRoom *)room;
- (void)getInteractionForRoom:(NCRoom *)room withTitle:(NSString *)title withCompletionBlock:(GetInteractionForRoomCompletionBlock)block;
/// Prefer `avatarImage` when non-nil (e.g. Mika bot); otherwise load the room avatar.
- (void)getInteractionForRoom:(NCRoom *)room withTitle:(NSString *)title avatarImage:(UIImage * _Nullable)avatarImage withCompletionBlock:(GetInteractionForRoomCompletionBlock)block;

@end
