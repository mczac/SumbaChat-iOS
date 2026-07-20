/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NCAppBranding : NSObject

// App configuration
extern NSString * const talkAppName;
extern NSString * const filesAppName;
extern NSString * const copyright;
extern NSString * const licenseNotice;
extern NSString * const bundleIdentifier;
extern NSString * const groupIdentifier;
extern NSString * const appsGroupIdentifier;
extern NSString * const pushNotificationServer;
extern NSString * const privacyURL;
extern BOOL const isBrandedApp;
extern BOOL const multiAccountEnabled;
extern BOOL const useAppsGroup;
extern BOOL const forceDomain;
extern NSString * const domain;
/// Parent DNS label for branded login hosts (`{subdomain}.{baseDomain}`).
extern NSString * const brandingBaseDomain;
/// Default subdomain prefill when none is stored locally.
extern NSString * const brandingDefaultSubdomain;
/// Support inbox for Contact us.
extern NSString * const brandingSupportEmail;
extern BOOL const customNavigationLogo;

+ (NSString *)getAppVersionString;
+ (NSString *)userAgent;
+ (NSString *)userAgentForLogin;

// Theming
+ (UIColor *)brandColor;
+ (UIColor *)brandTextColor;
+ (UIColor *)themeColor;
+ (UIColor *)themeTextColor;
+ (UIColor *)elementColor;
+ (UIImage *)navigationLogoImage;
+ (UIColor *)placeholderColor;
+ (UIColor *)backgroundColor;
+ (UIColor *)avatarPlaceholderColor;
+ (UIStatusBarStyle)statusBarStyleForBrandColor;
+ (UIStatusBarStyle)statusBarStyleForThemeColor;
+ (void)styleViewController:(UIViewController *)controller;
+ (UIColor *)getDynamicColor:(UIColor *)lightModeColor withDarkMode:(UIColor *)darkModeColor;

@end

NS_ASSUME_NONNULL_END
