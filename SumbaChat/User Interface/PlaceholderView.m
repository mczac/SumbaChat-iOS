/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "PlaceholderView.h"

#import "NCAppBranding.h"

@interface PlaceholderView ()

@property (strong, nonatomic) IBOutlet UIView *contentView;

@end

@implementation PlaceholderView

- (instancetype)init
{
    self = [super init];

    if (self) {
        [[NSBundle mainBundle] loadNibNamed:@"PlaceholderView" owner:self options:nil];

        [self addSubview:self.contentView];

        self.contentView.frame = self.bounds;
        [self configureTextViewDefaults];
    }

    return self;
}

- (instancetype)initForTableViewStyle:(UITableViewStyle)style
{
    self = [self init];

    return self;
}

- (void)configureTextViewDefaults
{
    self.placeholderTextView.editable = NO;
    self.placeholderTextView.selectable = NO;
    self.placeholderTextView.scrollEnabled = NO;
    self.placeholderTextView.backgroundColor = UIColor.clearColor;
    self.placeholderTextView.textContainerInset = UIEdgeInsetsMake(4, 12, 4, 12);
    self.placeholderTextView.textContainer.lineFragmentPadding = 0;
}

- (void)setImage:(UIImage *)image
{
    [self setImage:image accented:NO];
}

- (void)setImage:(UIImage *)image accented:(BOOL)accented
{
    if (!image) {
        self.placeholderImage.image = nil;
        return;
    }

    UIImage *placeholderImage = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.placeholderImage.image = placeholderImage;
    self.placeholderImage.contentMode = UIViewContentModeScaleAspectFit;
    if (accented) {
        // Soft brand presence without competing with the nav logo.
        self.placeholderImage.tintColor = [[NCAppBranding elementColor] colorWithAlphaComponent:0.55];
    } else {
        self.placeholderImage.tintColor = [UIColor secondaryLabelColor];
    }
}

- (void)setPlainMessage:(NSString *)message
{
    if (message.length == 0) {
        self.placeholderTextView.attributedText = nil;
        self.placeholderTextView.text = @"";
        return;
    }

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    style.lineSpacing = 3;

    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.placeholderTextView.attributedText = [[NSAttributedString alloc] initWithString:message attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
        NSParagraphStyleAttributeName: style
    }];
}

- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle
{
    NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
    titleStyle.alignment = NSTextAlignmentCenter;
    titleStyle.lineSpacing = 2;

    NSMutableParagraphStyle *bodyStyle = [[NSMutableParagraphStyle alloc] init];
    bodyStyle.alignment = NSTextAlignmentCenter;
    bodyStyle.lineSpacing = 3;
    bodyStyle.paragraphSpacingBefore = 6;

    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    titleFont = [UIFont systemFontOfSize:titleFont.pointSize weight:UIFontWeightSemibold];
    UIFont *bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:title ?: @"" attributes:@{
        NSFontAttributeName: titleFont,
        NSForegroundColorAttributeName: [UIColor labelColor],
        NSParagraphStyleAttributeName: titleStyle
    }]];

    if (subtitle.length > 0) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:subtitle] attributes:@{
            NSFontAttributeName: bodyFont,
            NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
            NSParagraphStyleAttributeName: bodyStyle
        }]];
    }

    self.placeholderTextView.attributedText = text;
}

@end
