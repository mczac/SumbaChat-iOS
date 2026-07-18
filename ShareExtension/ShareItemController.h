/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
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
/// Called when one or more attachments could not be loaded (e.g. iCloud not available).
- (void)shareItemController:(ShareItemController *)shareItemController didFailToStageItemsWithNames:(NSArray<NSString *> *)fileNames;
@optional
/// Drop decoded pager bitmaps between serial encodes (jetsam mitigation).
- (void)shareItemControllerShouldReleaseHeavyPreviews:(ShareItemController *)shareItemController;

@end


@interface ShareItemController : NSObject

@property (nonatomic, weak) id<ShareItemControllerDelegate> delegate;
@property (strong, nonatomic) NSArray<ShareItem *> *shareItems;
/// Active Talk account id — scopes convert-cache reuse (required before Send prepare).
@property (nonatomic, copy, nullable) NSString *accountId;
@property (nonatomic, readonly) NSInteger preparingItemCount;
/// Count of in-flight NSItemProvider / PHPicker loads (iCloud download, etc.).
@property (nonatomic, readonly) NSInteger pendingProviderLoadCount;
/// YES while provider load or local staging copy is still running (before Send).
@property (nonatomic, readonly) BOOL isBusyLoadingMedia;

- (instancetype)initWithMediaUploadCompressionSettings:(MediaUploadCompressionSettings *)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
/// Copies the provider URL into the upload temp dir. Returns YES only if a non-empty local file was staged.
- (BOOL)addItemWithURL:(NSURL *)fileURL;
- (BOOL)addItemWithURLAndName:(NSURL *)fileURL withName:(NSString *)fileName;
/// Photos / share fallback when file-URL staging fails: file representation → UIImage → loadItem.
- (void)addImageFromItemProvider:(NSItemProvider *)itemProvider;
/// Same as above; `completion` is always called on the main thread (success = staged at least one image).
- (void)addImageFromItemProvider:(NSItemProvider *)itemProvider completion:(void (^ _Nullable)(BOOL success))completion;
- (void)addItemWithImage:(UIImage *)image;
/// Call on the main thread before starting `loadFileRepresentation` / provider work; pair with `endProviderLoad`.
- (void)beginProviderLoad;
- (void)endProviderLoad;
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

/// Compress staged originals before upload. Provider returns MediaUploadCompressionLevel raw value.
/// `progress` reports overall prepare fraction 0…1 plus 1-based current/total (main thread).
- (void)prepareItemsForUploadWithLevelProvider:(NSInteger (^)(ShareItem *item))levelProvider
                                      progress:(void (^ _Nullable)(float fraction, NSInteger current, NSInteger total))progress
                                   completion:(void (^)(void))completion;

/// Stop in-flight Send-path compression (video export). Safe to call from Cancel.
- (void)cancelPreparation;

/// Record a staging failure when the share provider never reaches addItem (all fallbacks exhausted).
- (void)reportStagingFailureWithName:(NSString *)fileName;

@end

NS_ASSUME_NONNULL_END
