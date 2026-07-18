/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursorov and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */


#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kShareConfirmationCellIdentifier;
extern NSString *const kShareConfirmationTableCellNibName;

@interface ShareConfirmationCollectionViewCell : UICollectionViewCell

@property (strong, nonatomic) IBOutlet UIImageView *previewView;
@property (strong, nonatomic) IBOutlet UIImageView *placeholderImageView;
@property (strong, nonatomic) IBOutlet UITextView *placeholderTextView;

- (void)setPlaceHolderImage:(UIImage *)image;
- (void)setPlaceHolderText:(NSString *)text;
- (void)setPreviewImage:(UIImage *)image;
/// Hide the XIB’s top-left 120×120 file icon (used while waiting for a full-bleed preview).
- (void)hidePlaceholderChrome;
- (void)setShowsVideoIndicator:(BOOL)showsVideoIndicator;
/// Drop decoded preview bitmaps (full-screen video thumbs) so multi-encode Send can stay under jetsam.
- (void)releaseDecodedPreview;

@end

NS_ASSUME_NONNULL_END
