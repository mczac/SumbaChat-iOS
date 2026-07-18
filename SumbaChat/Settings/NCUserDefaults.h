//
/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NCUserDefaults : NSObject

+ (void)setPreferredCameraFlashMode:(NSInteger)flashMode;
+ (NSInteger)preferredCameraFlashMode;
+ (void)setBackgroundBlurEnabled:(BOOL)enabled;
+ (BOOL)backgroundBlurEnabled;
+ (void)setIncludeCallsInRecentsEnabled:(BOOL)enabled;
+ (BOOL)includeCallsInRecents;
+ (void)setPreferredCallViewMode:(NSString *)mode;
+ (NSString * _Nullable)preferredCallViewMode;
+ (void)setSpeakerViewStripeHidden:(BOOL)hidden;
+ (BOOL)speakerViewStripeHidden;

/// Stored as MediaUploadMode raw value. Default is Automatic.
+ (void)setMediaUploadMode:(NSInteger)mode;
+ (NSInteger)mediaUploadMode;

/// Max chat-file download cache size in bytes. Default 3 GB.
+ (void)setFileCacheMaxBytes:(int64_t)bytes;
+ (int64_t)fileCacheMaxBytes;

@end

NS_ASSUME_NONNULL_END
