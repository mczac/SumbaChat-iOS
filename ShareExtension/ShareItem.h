/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface ShareItem : NSObject

@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSString *filePath;
@property (nonatomic, strong) NSString *fileName;
@property (nonatomic, strong) UIImage *placeholderImage;
@property (nonatomic, assign) CGFloat uploadProgress;
@property (nonatomic, assign) BOOL isImage;
@property (nonatomic, strong) NSString *caption;
/// Content fingerprint used for bag dedup / convert cache (optional).
@property (nonatomic, copy, nullable) NSString *contentFingerprint;

+ (instancetype)initWithURL:(NSURL *)fileURL withName:(NSString *)fileName withPlaceholderImage:(UIImage *)placeholderImage isImage:(BOOL)isImage;

@end

