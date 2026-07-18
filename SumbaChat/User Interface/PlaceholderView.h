/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <UIKit/UIKit.h>

@interface PlaceholderView : UIView

- (instancetype)initForTableViewStyle:(UITableViewStyle)style;

@property (weak, nonatomic) IBOutlet UIView *placeholderView;
@property (weak, nonatomic) IBOutlet UIImageView *placeholderImage;
@property (weak, nonatomic) IBOutlet UITextView *placeholderTextView;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *loadingView;

- (void)setImage:(UIImage * _Nullable)image;
/// Soft brand tint for primary empty states (e.g. conversations list).
- (void)setImage:(UIImage * _Nullable)image accented:(BOOL)accented;
/// Single-line / paragraph empty copy (secondary label color).
- (void)setPlainMessage:(NSString *)message;
/// Title + optional supporting line — clearer hierarchy than one gray paragraph.
- (void)setTitle:(NSString *)title subtitle:(NSString * _Nullable)subtitle;

@end
