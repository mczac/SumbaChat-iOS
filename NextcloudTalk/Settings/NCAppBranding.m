/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "NCAppBranding.h"

#import "TalkAccount.h"
#import "TalkCapabilities.h"
#import "ServerCapabilities.h"
#import "FederatedCapabilities.h"

#import "NextcloudTalk-Swift.h"

// Local hosts live in gitignored NCAppBrandingLocal.h (copy from *.example.h).
#if __has_include("NCAppBrandingLocal.h")
#import "NCAppBrandingLocal.h"
#else
#define NC_BRANDING_DOMAIN @"https://cloud.example.com"
#define NC_BRANDING_PRIVACY_URL @"https://cloud.example.com/privacy"
#define NC_BRANDING_PUSH_SERVER @"https://push.example.com"
#define NC_BRANDING_PUSH_SERVER_DEBUG @"https://push-dev.example.com"
#endif

typedef enum NCTextColorStyle {
    NCTextColorStyleLight = 0,
    NCTextColorStyleDark
} NCTextColorStyle;

@implementation NCAppBranding

#pragma mark - App configuration

NSString * const talkAppName = @"SumbaChat";
NSString * const filesAppName = @"SumbaFiles";
NSString * const copyright = @"© 2026 Ivan Cursorov and Peter Zakharov";
NSString * const licenseNotice = @"Based on Nextcloud Talk, licensed under GPLv3";
NSString * const bundleIdentifier = @"com.spl.SumbaChat";
NSString * const groupIdentifier = @"group.com.spl.SumbaChat";
NSString * const appsGroupIdentifier = @"group.com.spl.apps";
#if DEBUG
NSString * const pushNotificationServer = NC_BRANDING_PUSH_SERVER_DEBUG;
#else
NSString * const pushNotificationServer = NC_BRANDING_PUSH_SERVER;
#endif
NSString * const privacyURL = NC_BRANDING_PRIVACY_URL;
BOOL const isBrandedApp = YES;
BOOL const multiAccountEnabled = YES;
BOOL const useAppsGroup = NO;
BOOL const forceDomain = YES;
NSString * const domain = NC_BRANDING_DOMAIN;
NSString * const appAlternateVersion = @"";

+ (NSString *)getAppVersionString
{
    if ([appAlternateVersion length] > 0) {
        return appAlternateVersion;
    }

    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return appVersion;
}

#pragma mark - Theming

NSString * const brandColorHex = @"#0082C9";
NSString * const brandTextColorHex = @"#FFFFFF";
BOOL const customNavigationLogo = YES;
BOOL const useServerThemimg = YES;

+ (UIColor *)brandColor
{
    return [NCUtils colorFromHexString:brandColorHex];
}

+ (UIColor *)brandTextColor
{
    return [NCUtils colorFromHexString:brandTextColorHex];
}

+ (UIColor *)themeColor
{
    UIColor *color = [NCUtils colorFromHexString:brandColorHex];
    if (useServerThemimg) {
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
        if (serverCapabilities && serverCapabilities.color) {
            UIColor *themeColor = [NCUtils colorFromHexString:serverCapabilities.color];
            if (themeColor) {
                color = themeColor;
            }
        }
    }
    return color;
}

+ (UIColor *)themeTextColor
{
    UIColor *textColor = [NCUtils colorFromHexString:brandTextColorHex];
    if (useServerThemimg) {
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
        if (serverCapabilities && serverCapabilities.colorText) {
            UIColor *themeTextColor = [NCUtils colorFromHexString:serverCapabilities.colorText];
            if (themeTextColor) {
                textColor = themeTextColor;
            }
        }
    }
    return textColor;
}

+ (UIColor *)elementColor
{
    // Do not check if using server theming or not for now
    // We could check it once we calculate color element locally
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];
    if (serverCapabilities) {
        UIColor *elementColorBright = [NCUtils colorFromHexString:serverCapabilities.colorElementBright];
        UIColor *elementColorDark = [NCUtils colorFromHexString:serverCapabilities.colorElementDark];

        if (elementColorBright && elementColorDark) {
            return [self getDynamicColor:elementColorBright withDarkMode:elementColorDark];
        }

        UIColor *color = [NCUtils colorFromHexString:serverCapabilities.colorElement];
        if (color) {
            return color;
        }
    }
    
    UIColor *elementColor = [NCUtils colorFromHexString:brandColorHex];
    return elementColor;
}

+ (UIColor *)getDynamicColor:(UIColor *)lightModeColor withDarkMode:(UIColor *)darkModeColor
{
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return darkModeColor;
        }
        
        return lightModeColor;
    }];
}

+ (UIImage *)navigationLogoImage
{
    // SumbaChat wave mark (login asset) in the rooms list title bar.
    UIImage *waveLogo = [UIImage imageNamed:@"sumbaLoginLogo"];
    if (waveLogo) {
        // Login asset is ~180pt; nav title bar expects ~navigationLogo size (~24–28pt).
        CGFloat targetHeight = 28.0;
        if (waveLogo.size.height > targetHeight + 0.5) {
            CGFloat scale = targetHeight / waveLogo.size.height;
            CGSize newSize = CGSizeMake(waveLogo.size.width * scale, targetHeight);
            UIGraphicsBeginImageContextWithOptions(newSize, NO, 0);
            [waveLogo drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
            UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (scaled) {
                waveLogo = scaled;
            }
        }
        return [waveLogo imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }

    if (@available(iOS 26.0, *)) {
        if (!customNavigationLogo) {
            return [[UIImage imageNamed:@"navigationLogo"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }

    NSString *imageName = @"navigationLogo";
    if (!customNavigationLogo) {
        if (useServerThemimg && [self textColorStyleForBackgroundColor:[self themeColor]] == NCTextColorStyleDark) {
            imageName = @"navigationLogoDark";
        } else if ([self brandTextColorStyle] == NCTextColorStyleDark) {
            imageName = @"navigationLogoDark";
        }
    }
    return [UIImage imageNamed:imageName];
}

+ (UIColor *)placeholderColor
{
    return [UIColor placeholderTextColor];
}

+ (UIColor *)backgroundColor
{
    return [UIColor systemBackgroundColor];
}

+ (UIColor *)avatarPlaceholderColor
{
    UIColor *light = [NCUtils colorFromHexString:@"#dbdbdb"];
    UIColor *dark = [NCUtils colorFromHexString:@"#3b3b3b"];

    return [self getDynamicColor:light withDarkMode:dark];
}

+ (UIStatusBarStyle)statusBarStyleForBrandColor
{
    return [self statusBarStyleForTextColorStyle:[self brandTextColorStyle]];
}

+ (UIStatusBarStyle)statusBarStyleForThemeColor
{
    if (useServerThemimg) {
        NCTextColorStyle style = [self textColorStyleForBackgroundColor:[self themeColor]];
        return [self statusBarStyleForTextColorStyle:style];
    }
    return [self statusBarStyleForBrandColor];
}

+ (UIStatusBarStyle)statusBarStyleForTextColorStyle:(NCTextColorStyle)style
{
    if (style == NCTextColorStyleDark) {
        return UIStatusBarStyleDarkContent;
    }

    return UIStatusBarStyleLightContent;
}

+ (NCTextColorStyle)brandTextColorStyle
{
    // Dark style when brand text color is black
    if ([brandTextColorHex isEqualToString:@"#000000"]) {
        return NCTextColorStyleDark;
    }
    
    // Light style when brand text color is white
    if ([brandTextColorHex isEqualToString:@"#FFFFFF"]) {
        return NCTextColorStyleLight;
    }
    
    // Check brand-color luma when brand-text-color is neither black nor white
    return [self textColorStyleForBackgroundColor:[self brandColor]];
}

+ (NCTextColorStyle)textColorStyleForBackgroundColor:(UIColor *)color
{
    CGFloat luma = [NCUtils calculateLumaFromColor:color];
    return (luma > 0.6) ? NCTextColorStyleDark : NCTextColorStyleLight;
}

+ (void)styleViewController:(UIViewController *)controller {
    UIColor *themeColor = [NCAppBranding themeColor];

    if (@available(iOS 26.0, *)) {
        controller.navigationController.navigationBar.translucent = YES;
        [controller.view setBackgroundColor:[UIColor systemBackgroundColor]];

        if ([controller isKindOfClass:[UITableViewController class]]) {
            UITableViewController *tableViewController = (UITableViewController *)controller;

            if (tableViewController.tableView.style == UITableViewStyleInsetGrouped) {
                [controller.view setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
            }
        }

        return;
    }

    [controller.navigationController.navigationBar setTitleTextAttributes:@{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]}];
    controller.navigationController.navigationBar.barTintColor = [NCAppBranding themeColor];
    controller.navigationController.navigationBar.tintColor = [NCAppBranding themeTextColor];
    controller.navigationController.navigationBar.translucent = NO;
    controller.tabBarController.tabBar.tintColor = [NCAppBranding themeColor];

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = themeColor;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName:[NCAppBranding themeTextColor]};
    controller.navigationItem.standardAppearance = appearance;
    controller.navigationItem.compactAppearance = appearance;
    controller.navigationItem.scrollEdgeAppearance = appearance;

    // Fix uisearchcontroller animation
    controller.extendedLayoutIncludesOpaqueBars = YES;

    UISearchController *searchController = controller.navigationItem.searchController;

    if (searchController) {
        searchController.searchBar.searchTextField.backgroundColor = [NCUtils searchbarBGColorForColor:themeColor];
        searchController.searchBar.tintColor = [NCAppBranding themeTextColor];
        [searchController.searchBar setScopeBarButtonTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NCAppBranding themeTextColor], NSForegroundColorAttributeName, nil] forState:UIControlStateNormal];
        [searchController.searchBar setScopeBarButtonTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NCAppBranding themeTextColor], NSForegroundColorAttributeName, nil] forState:UIControlStateSelected];
        searchController.searchBar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        controller.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;

        UITextField *searchTextField = [searchController.searchBar valueForKey:@"searchField"];
        UIButton *clearButton = [searchTextField valueForKey:@"_clearButton"];
        searchTextField.tintColor = [NCAppBranding themeTextColor];
        searchTextField.textColor = [NCAppBranding themeTextColor];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Search bar placeholder
            searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:NSLocalizedString(@"Search", nil)
                                                                                    attributes:@{NSForegroundColorAttributeName:[[NCAppBranding themeTextColor] colorWithAlphaComponent:0.5]}];
            // Search bar search icon
            UIImageView *searchImageView = (UIImageView *)searchTextField.leftView;
            searchImageView.image = [searchImageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [searchImageView setTintColor:[[NCAppBranding themeTextColor] colorWithAlphaComponent:0.5]];
            // Search bar search clear button
            UIImage *clearButtonImage = [clearButton.imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [clearButton setImage:clearButtonImage forState:UIControlStateNormal];
            [clearButton setImage:clearButtonImage forState:UIControlStateHighlighted];
            [clearButton setTintColor:[NCAppBranding themeTextColor]];
        });

        [controller setNeedsStatusBarAppearanceUpdate];
    }
}

@end
