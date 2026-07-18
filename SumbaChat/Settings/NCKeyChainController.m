/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "NCKeyChainController.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#import "NCAppBranding.h"
#import "SumbaChat-Swift.h"

@import UICKeyChainStore;

@implementation NCKeyChainController

NSString * const kNCTokenKey                    = @"ncToken";
NSString * const kNCNormalPushTokenKey          = @"ncNormalPushToken";
NSString * const kNCPushKitTokenKey             = @"ncPushKitToken";
NSString * const kNCPNPublicKey                 = @"ncPNPublicKey";
NSString * const kNCPNPrivateKey                = @"ncPNPrivateKey";

+ (NCKeyChainController *)sharedInstance
{
    static dispatch_once_t once;
    static NCKeyChainController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _keychain = [UICKeyChainStore keyChainStoreWithService:bundleIdentifier accessGroup:groupIdentifier];
    }
    return self;
}

/// Main-app keychain access group (`TeamID.com.spl.SumbaChat`).
/// UICKeyChainStore omits `kSecAttrAccessGroup` on the simulator, so the app and
/// appex otherwise use isolated default groups and the extension cannot read the token.
- (NSString *)mainAppKeychainAccessGroup
{
    static NSString *accessGroup;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *prefix = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"AppIdentifierPrefix"];
        if (prefix.length == 0) {
            // DEVELOPMENT_TEAM in the Xcode project.
            prefix = @"62KF2CDFQ2.";
        }
        if (![prefix hasSuffix:@"."]) {
            prefix = [prefix stringByAppendingString:@"."];
        }
        accessGroup = [prefix stringByAppendingString:bundleIdentifier];
    });
    return accessGroup;
}

- (NSString *)secItemStringForKey:(NSString *)key accessGroup:(NSString *)accessGroup
{
    if (key.length == 0 || accessGroup.length == 0) {
        return nil;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: bundleIdentifier,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) {
        return nil;
    }

    NSData *data = CFBridgingRelease(result);
    if (data.length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)setSecItemString:(NSString *)value forKey:(NSString *)key accessGroup:(NSString *)accessGroup
{
    if (key.length == 0 || accessGroup.length == 0) {
        return NO;
    }

    NSDictionary *base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: bundleIdentifier,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecAttrAccessGroup: accessGroup
    };

    SecItemDelete((__bridge CFDictionaryRef)base);

    if (value.length == 0) {
        return YES;
    }

    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    return status == errSecSuccess;
}

- (void)setToken:(NSString *)token forAccountId:(NSString *)accountId
{
    NSString *key = [NSString stringWithFormat:@"%@-%@", kNCTokenKey, accountId];
    [_keychain setString:token forKey:key];
    // Always mirror into the main-app access group so extensions can read on simulator
    // (and on device when entitled via keychain-access-groups).
    [self setSecItemString:token forKey:key accessGroup:[self mainAppKeychainAccessGroup]];
}

- (NSString *)tokenForAccountId:(NSString *)accountId
{
    NSString *key = [NSString stringWithFormat:@"%@-%@", kNCTokenKey, accountId];
    NSString *token = [_keychain stringForKey:key];
    if (token.length > 0) {
        return token;
    }

    token = [self secItemStringForKey:key accessGroup:[self mainAppKeychainAccessGroup]];
    if (token.length > 0) {
        return token;
    }

    return nil;
}

- (void)mirrorStoredTokensForAccountIds:(NSArray<NSString *> *)accountIds
{
    NSString *accessGroup = [self mainAppKeychainAccessGroup];
    for (NSString *accountId in accountIds) {
        if (accountId.length == 0) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@-%@", kNCTokenKey, accountId];
        NSString *token = [_keychain stringForKey:key];
        if (token.length == 0) {
            token = [self secItemStringForKey:key accessGroup:accessGroup];
        }
        if (token.length > 0) {
            [self setSecItemString:token forKey:key accessGroup:accessGroup];
        }
    }
}

- (void)setPushNotificationPublicKey:(NSData *)privateKey forAccountId:(NSString *)accountId
{
    [_keychain setData:privateKey forKey:[NSString stringWithFormat:@"%@-%@", kNCPNPublicKey, accountId]];
}

- (NSData *)pushNotificationPublicKeyForAccountId:(NSString *)accountId
{
    return [_keychain dataForKey:[NSString stringWithFormat:@"%@-%@", kNCPNPublicKey, accountId]];
}

- (void)setPushNotificationPrivateKey:(NSData *)privateKey forAccountId:(NSString *)accountId
{
    [_keychain setData:privateKey forKey:[NSString stringWithFormat:@"%@-%@", kNCPNPrivateKey, accountId]];
}

- (NSData *)pushNotificationPrivateKeyForAccountId:(NSString *)accountId
{
    return [_keychain dataForKey:[NSString stringWithFormat:@"%@-%@", kNCPNPrivateKey, accountId]];
}

- (NSString *)pushTokenSHA512
{
    NSString *token = [self combinedPushToken];

    if (!token) {
        return nil;
    }

    return [self createSHA512:token];
}

- (void)logCombinedPushToken
{
    NSString *normalPushToken = [_keychain stringForKey:kNCNormalPushTokenKey];
    NSString *pushKitToken = [_keychain stringForKey:kNCPushKitTokenKey];

    if (normalPushToken && [normalPushToken length] >= 10) {
        [NCLog log:[NSString stringWithFormat:@"Push notification, normal push token: %@... length %ld", [normalPushToken substringToIndex:10], [normalPushToken length]]];
    } else {
        [NCLog log:@"Push notification, normal push token length < 10"];
    }

    if (pushKitToken && [pushKitToken length] >= 10) {
        [NCLog log:[NSString stringWithFormat:@"Push notification, pushKit token: %@... length %ld", [pushKitToken substringToIndex:10], [pushKitToken length]]];
    } else {
        [NCLog log:@"Push notification, pushKit token length < 10"];
    }
}

- (NSString *)combinedPushToken
{
    NSString *normalPushToken = [_keychain stringForKey:kNCNormalPushTokenKey];
    NSString *pushKitToken = [_keychain stringForKey:kNCPushKitTokenKey];

    if (!normalPushToken || !pushKitToken) {
        return nil;
    }

    if ([NCUtils isiOSAppOnMac]) {
        // As CallKit is not supported on MacOS, we only supply the
        // normal push token, to generate local notifications for calls
        return normalPushToken;
    }

    return [NSString stringWithFormat:@"%@ %@", normalPushToken, pushKitToken];
}

- (void)removeAllItems
{
    [UICKeyChainStore removeAllItemsForService:bundleIdentifier accessGroup:groupIdentifier];
}

#pragma mark - Utils

- (NSString *)createSHA512:(NSString *)string
{
    const char *cstr = [string cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:cstr length:string.length];
    uint8_t digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(data.bytes, (unsigned int)data.length, digest);
    NSMutableString* output = [NSMutableString  stringWithCapacity:CC_SHA512_DIGEST_LENGTH * 2];
    
    for(int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];
    return output;
}

@end
