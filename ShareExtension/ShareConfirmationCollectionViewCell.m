/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "ShareConfirmationCollectionViewCell.h"

NSString *const kShareConfirmationCellIdentifier = @"ShareConfirmationCellIdentifier";
NSString *const kShareConfirmationTableCellNibName = @"ShareConfirmationCollectionViewCell";

@interface ShareConfirmationCollectionViewCell ()

@property (nonatomic, strong) UIImageView *videoIndicatorView;

@end

@implementation ShareConfirmationCollectionViewCell

- (void)awakeFromNib {
    [super awakeFromNib];
    [self setupVideoIndicatorIfNeeded];
}

- (void)setupVideoIndicatorIfNeeded
{
    if (self.videoIndicatorView) {
        return;
    }

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightRegular];
    UIImage *playImage = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:config];
    self.videoIndicatorView = [[UIImageView alloc] initWithImage:playImage];
    self.videoIndicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoIndicatorView.tintColor = [UIColor whiteColor];
    self.videoIndicatorView.hidden = YES;
    self.videoIndicatorView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.videoIndicatorView.layer.shadowOpacity = 0.45;
    self.videoIndicatorView.layer.shadowRadius = 4;
    self.videoIndicatorView.layer.shadowOffset = CGSizeZero;
    [self.contentView addSubview:self.videoIndicatorView];

    [NSLayoutConstraint activateConstraints:@[
        [self.videoIndicatorView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.videoIndicatorView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
    ]];
}

- (void)prepareForReuse
{
    [super prepareForReuse];

    self.previewView.image = nil;
    self.placeholderImageView.image = nil;
    self.placeholderTextView.text = @"";
    
    self.placeholderImageView.hidden = NO;
    self.placeholderTextView.hidden = NO;
    self.videoIndicatorView.hidden = YES;
}

- (void)setPreviewImage:(UIImage *)image
{
    [self.previewView setImage:image];
    
    self.placeholderImageView.hidden = YES;
    self.placeholderTextView.hidden = YES;
}

- (void)setPlaceHolderImage:(UIImage *)image
{
    [self.placeholderImageView setImage:image];
}

- (void)setPlaceHolderText:(NSString *)text
{
    [self.placeholderTextView setText:text];
}

- (void)setShowsVideoIndicator:(BOOL)showsVideoIndicator
{
    [self setupVideoIndicatorIfNeeded];
    self.videoIndicatorView.hidden = !showsVideoIndicator;
}

- (void)releaseDecodedPreview
{
    self.previewView.image = nil;
    self.placeholderImageView.hidden = NO;
    self.placeholderTextView.hidden = NO;
}

@end
