/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class UICKeyChainStore;

extern NSString * const kNCNormalPushTokenKey;
extern NSString * const kNCPushKitTokenKey;

@interface NCKeyChainController : NSObject

@property (nonatomic, copy) UICKeyChainStore *keychain;

+ (instancetype)sharedInstance;
- (void)setToken:(NSString *)token forAccountId:(NSString *)accountId;
- (NSString * _Nullable)tokenForAccountId:(NSString *)accountId;
/// Re-write tokens into the shared keychain-access-group so Share Extension can read them
/// after login (needed when UICKeyChainStore omits access groups on the simulator).
- (void)mirrorStoredTokensForAccountIds:(NSArray<NSString *> *)accountIds;
- (void)setPushNotificationPublicKey:(NSData *)privateKey forAccountId:(NSString *)accountId;
- (NSData * _Nullable)pushNotificationPublicKeyForAccountId:(NSString *)accountId;
- (void)setPushNotificationPrivateKey:(NSData *)privateKey forAccountId:(NSString *)accountId;
- (NSData * _Nullable)pushNotificationPrivateKeyForAccountId:(NSString *)accountId;
- (NSString *)pushTokenSHA512;
- (void)logCombinedPushToken;
- (NSString * _Nullable)combinedPushToken;
- (void)removeAllItems;
/// Removes app-password token and push keypair for one account (leaves other accounts intact).
- (void)removeCredentialsForAccountId:(NSString *)accountId;

@end

NS_ASSUME_NONNULL_END
