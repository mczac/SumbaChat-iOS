/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ShareItem.h"

NS_ASSUME_NONNULL_BEGIN

@class MediaUploadCompressionSettings;
@class ShareItemController;
@protocol ShareItemControllerDelegate <NSObject>

- (void)shareItemControllerItemsChanged:(ShareItemController *)shareItemController;
- (void)shareItemControllerPreparingItemsChanged:(ShareItemController *)shareItemController;

@end


@interface ShareItemController : NSObject

@property (nonatomic, weak) id<ShareItemControllerDelegate> delegate;
@property (strong, nonatomic) NSArray<ShareItem *> *shareItems;
@property (nonatomic, readonly) NSInteger preparingItemCount;

- (instancetype)initWithMediaUploadCompressionSettings:(MediaUploadCompressionSettings *)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (void)addItemWithURL:(NSURL *)fileURL;
- (void)addItemWithURLAndName:(NSURL *)fileURL withName:(NSString *)fileName;
- (void)addItemWithImage:(UIImage *)image;
- (void)addItemWithImageAndName:(UIImage *)image withName:(NSString *)imageName;
- (void)addItemWithImageDataAndName:(NSData *)data withName:(NSString *)imageName;
- (void)addItemWithContactData:(NSData *)data;
- (void)addItemWithContactDataAndName:(NSData *)data withName:(NSString *)imageName;
- (void)updateItem:(ShareItem *)item withImage:(UIImage *)image;
- (void)updateItem:(ShareItem *)item withURL:(NSURL *)fileURL;
- (void)removeItem:(ShareItem *)item;
- (void)removeItems:(NSArray<ShareItem *> *)items;
- (void)removeAllItems;
- (UIImage * _Nullable)getImageFromItem:(ShareItem *)item;

@end

NS_ASSUME_NONNULL_END
