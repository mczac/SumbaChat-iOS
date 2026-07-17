/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <MobileCoreServices/MobileCoreServices.h>

#import "ShareItemController.h"
#import "NextcloudTalk-Swift.h"

@interface ShareItemController ()

@property (nonatomic, strong) NSString *tempDirectoryPath;
@property (nonatomic, strong) NSURL *tempDirectoryURL;
@property (nonatomic, strong) NSMutableArray *internalShareItems;
@property (nonatomic, strong) MediaUploadCompressionSettings *stagingSettings;
@property (nonatomic, strong) dispatch_queue_t preparationQueue;
@property (nonatomic, assign, readwrite) NSInteger preparingItemCount;
@property (nonatomic, assign, readwrite) NSInteger pendingProviderLoadCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingStagingFailures;
@property (nonatomic, strong) MediaUploadPreparationToken *activePreparationToken;
@property (nonatomic, assign) NSInteger batchVideoMaxEdgeCap;

@end

@implementation ShareItemController

- (instancetype)init
{
    // Stage originals; compress on Send via prepareItemsForUpload…
    return [self initWithMediaUploadCompressionSettings:[[MediaUploadCompressionSettings alloc] initWithLevel:MediaUploadCompressionLevelNone]];
}

- (instancetype)initWithMediaUploadCompressionSettings:(MediaUploadCompressionSettings *)settings
{
    self = [super init];
    if (self) {
        self.stagingSettings = settings ?: [[MediaUploadCompressionSettings alloc] initWithLevel:MediaUploadCompressionLevelNone];
        self.internalShareItems = [[NSMutableArray alloc] init];
        self.pendingStagingFailures = [[NSMutableArray alloc] init];
        self.preparationQueue = dispatch_queue_create("com.spl.SumbaChat.media-upload-preparation", DISPATCH_QUEUE_SERIAL);
        [self initTempDirectory];
    }
    return self;
}

- (NSArray<ShareItem *> *)shareItems {
    return [self.internalShareItems copy];
}

- (void)initTempDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    self.tempDirectoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"/upload/"];
    
    if (![fileManager fileExistsAtPath:self.tempDirectoryPath]) {
        // Make sure our upload directory exists
        [fileManager createDirectoryAtPath:self.tempDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    } else {
        // Clean up any temporary files from a previous upload
        NSArray *previousFiles = [fileManager contentsOfDirectoryAtPath:self.tempDirectoryPath error:nil];
        
        for (NSString *previousFile in previousFiles) {
            [fileManager removeItemAtPath:[self.tempDirectoryPath stringByAppendingPathComponent:previousFile] error:nil];
        }
    }
    
    self.tempDirectoryURL = [NSURL fileURLWithPath:self.tempDirectoryPath isDirectory:YES];
}

- (void)beginPreparingItem
{
    NSAssert(NSThread.isMainThread, @"Preparing item count must be updated on the main thread");
    self.preparingItemCount += 1;
    [self.delegate shareItemControllerPreparingItemsChanged:self];
}

- (void)endPreparingItem
{
    NSAssert(NSThread.isMainThread, @"Preparing item count must be updated on the main thread");
    if (self.preparingItemCount <= 0) {
        return;
    }

    self.preparingItemCount -= 1;
    [self.delegate shareItemControllerPreparingItemsChanged:self];
    if (self.preparingItemCount == 0 && self.pendingProviderLoadCount == 0) {
        [self flushPendingStagingFailures];
    }
}

- (BOOL)isBusyLoadingMedia
{
    return self.pendingProviderLoadCount > 0 || self.preparingItemCount > 0;
}

- (void)beginProviderLoad
{
    void (^bump)(void) = ^{
        self.pendingProviderLoadCount += 1;
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: beginProviderLoad (pending=%ld)", (long)self.pendingProviderLoadCount]];
        [self.delegate shareItemControllerPreparingItemsChanged:self];
    };
    if ([NSThread isMainThread]) {
        bump();
    } else {
        dispatch_sync(dispatch_get_main_queue(), bump);
    }
}

- (void)endProviderLoad
{
    void (^drop)(void) = ^{
        if (self.pendingProviderLoadCount <= 0) {
            [NCLog log:@"ShareItemController: endProviderLoad ignored (already 0)"];
            return;
        }
        self.pendingProviderLoadCount -= 1;
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: endProviderLoad (pending=%ld)", (long)self.pendingProviderLoadCount]];
        [self.delegate shareItemControllerPreparingItemsChanged:self];
        if (self.pendingProviderLoadCount == 0 && self.preparingItemCount == 0) {
            [self flushPendingStagingFailures];
        }
    };
    if ([NSThread isMainThread]) {
        drop();
    } else {
        dispatch_async(dispatch_get_main_queue(), drop);
    }
}

- (void)reportStagingFailureWithName:(NSString *)fileName
{
    NSString *name = fileName.length > 0 ? fileName : NSLocalizedString(@"Shared file", @"Generic name when a shared attachment has no filename");
    void (^record)(void) = ^{
        [self.pendingStagingFailures addObject:name];
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: staging failure recorded for %@", name]];
        if (self.preparingItemCount == 0 && self.pendingProviderLoadCount == 0) {
            [self flushPendingStagingFailures];
        }
    };
    if ([NSThread isMainThread]) {
        record();
    } else {
        dispatch_async(dispatch_get_main_queue(), record);
    }
}

- (void)flushPendingStagingFailures
{
    NSAssert(NSThread.isMainThread, @"Staging failures must flush on the main thread");
    if (self.pendingStagingFailures.count == 0) {
        return;
    }
    NSArray<NSString *> *names = [self.pendingStagingFailures copy];
    [self.pendingStagingFailures removeAllObjects];
    if ([self.delegate respondsToSelector:@selector(shareItemController:didFailToStageItemsWithNames:)]) {
        [self.delegate shareItemController:self didFailToStageItemsWithNames:names];
    }
}

- (void)cancelPreparation
{
    [self.activePreparationToken cancel];
    self.activePreparationToken = nil;
    [NCLog log:@"ShareItemController: preparation cancelled"];
}

- (NSURL *)getFileLocalURL:(NSString *)fileName
{
    NSURL *fileLocalURL = [self.tempDirectoryURL URLByAppendingPathComponent:fileName];

    if ([NSFileManager.defaultManager fileExistsAtPath:fileLocalURL.path]) {
        NSString *extension = [fileName pathExtension];
        NSString *nameWithoutExtension = [fileName stringByDeletingPathExtension];

        NSString *newFileName = [NSString stringWithFormat:@"%@%.f.%@", nameWithoutExtension, [[NSDate date] timeIntervalSince1970] * 1000, extension];
        fileLocalURL = [self.tempDirectoryURL URLByAppendingPathComponent:newFileName];
    }

    return fileLocalURL;
}

- (BOOL)addItemWithURL:(NSURL *)fileURL
{
    return [self addItemWithURLAndName:fileURL withName:fileURL.lastPathComponent];
}

- (BOOL)fileURLHasNonZeroContent:(NSURL *)url
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return attrs != nil && [attrs fileSize] > 0;
}

- (BOOL)prepareFileForUploadingAtURL:(NSURL *)fileURL toLocalURL:(NSURL *)fileLocalURL withCoordinatorOption:(NSFileCoordinatorReadingOptions)options
{
    // Photos / Share Extension hand security-scoped URLs on iOS 18. Prefer copy over move —
    // move can "succeed" the coordinator while leaving an empty local file when the provider
    // only grants read access (None chip shows "–", Moderate/High floor at ~12.3 KB).
    // Write to a staging sibling first so a failed copy never wipes an existing destination.
    BOOL accessing = [fileURL startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *coordinatorError = nil;
    __block NSError *ioError = nil;
    __block BOOL wroteBytes = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *stagingURL = [[fileLocalURL URLByDeletingLastPathComponent]
                         URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@",
                                                      [[NSUUID UUID] UUIDString],
                                                      fileLocalURL.lastPathComponent]];

    [coordinator coordinateReadingItemAtURL:fileURL options:options error:&coordinatorError byAccessor:^(NSURL *newURL) {
        [fm removeItemAtURL:stagingURL error:nil];

        if (![fm copyItemAtURL:newURL toURL:stagingURL error:&ioError]) {
            // Fallback: read bytes (some provider URLs reject copyItem).
            NSData *data = [NSData dataWithContentsOfURL:newURL options:NSDataReadingMappedIfSafe error:&ioError];
            if (data.length == 0 || ![data writeToURL:stagingURL options:NSDataWritingAtomic error:&ioError]) {
                wroteBytes = NO;
                [fm removeItemAtURL:stagingURL error:nil];
                return;
            }
        }

        if (![self fileURLHasNonZeroContent:stagingURL]) {
            wroteBytes = NO;
            [fm removeItemAtURL:stagingURL error:nil];
            ioError = [NSError errorWithDomain:@"ShareItemController"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"Copied file is empty"}];
            return;
        }

        if ([fm fileExistsAtPath:fileLocalURL.path]) {
            [fm removeItemAtPath:fileLocalURL.path error:nil];
        }
        if ([fm moveItemAtURL:stagingURL toURL:fileLocalURL error:&ioError]) {
            wroteBytes = YES;
        } else {
            [fm removeItemAtURL:stagingURL error:nil];
            wroteBytes = NO;
        }
    }];

    if (accessing) {
        [fileURL stopAccessingSecurityScopedResource];
    }

    if (coordinatorError != nil || !wroteBytes) {
        NSString *detail = coordinatorError.localizedDescription ?: ioError.localizedDescription ?: @"unknown";
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: staging copy failed for %@ → %@: %@",
                    fileURL.lastPathComponent, fileLocalURL.lastPathComponent, detail]];
        [fm removeItemAtURL:stagingURL error:nil];
        return NO;
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:fileLocalURL.path error:nil];
    [NCLog log:[NSString stringWithFormat:@"ShareItemController: staged copy %@ (%llu bytes)",
                fileLocalURL.lastPathComponent, (unsigned long long)[attrs fileSize]]];
    return YES;
}

- (void)addShareItemWithLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName isImage:(BOOL)fileIsImage
{
    if (![self fileURLHasNonZeroContent:fileLocalURL]) {
        NSLog(@"Refusing to stage empty shareItem: %@ %@", fileName, fileLocalURL);
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: refusing empty staged file %@", fileName]];
        [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
        return;
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:fileLocalURL.path error:nil];
    NSLog(@"Adding shareItem: %@ %@ (%llu bytes)", fileName, fileLocalURL, (unsigned long long)[attrs fileSize]);
    [NCLog log:[NSString stringWithFormat:@"ShareItemController: staged %@ (%@, %llu bytes)",
                fileName, fileLocalURL.lastPathComponent, (unsigned long long)[attrs fileSize]]];

    ShareItem *item = [ShareItem initWithURL:fileLocalURL withName:fileName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:fileIsImage];
    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)finalizeImageItemFromLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    // Stage original (or lightly re-encoded only if settings request it during staging).
    NSString *jpegName = [[fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
    NSURL *jpegURL = [self getFileLocalURL:jpegName];
    MediaUploadCompressionSettings *settings = self.stagingSettings;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        NSURL *finalURL = fileLocalURL;
        NSString *finalName = fileName;

        if ([MediaUploadPreprocessor compressImageAtURL:fileLocalURL
                                       toDestinationURL:jpegURL
                                               settings:settings]) {
            [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
            finalURL = jpegURL;
            finalName = jpegName;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            [strongSelf addShareItemWithLocalURL:finalURL fileName:finalName isImage:YES];
            [strongSelf endPreparingItem];
        });
    });
}

- (void)finalizeVideoItemFromLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    // Stage original; video compression happens on Send.
    [self addShareItemWithLocalURL:fileLocalURL fileName:fileName isImage:NO];
    [self endPreparingItem];
}

- (BOOL)addItemWithURLAndName:(NSURL *)fileURL withName:(NSString *)fileName
{
    // NSItemProvider / PHPicker may revoke the source URL as soon as their completion
    // returns. Previously we dispatched the copy async and returned immediately — on
    // iOS 18 that often staged 0-byte files (placeholder preview, None=–, ~12.3 KB chips).
    // Callers that use loadFileRepresentation MUST invoke this before the handler returns.
    __block NSURL *fileLocalURL = nil;
    void (^beginOnMain)(void) = ^{
        [self beginPreparingItem];
        fileLocalURL = [self getFileLocalURL:fileName];
    };
    if ([NSThread isMainThread]) {
        beginOnMain();
    } else {
        dispatch_sync(dispatch_get_main_queue(), beginOnMain);
    }

    // Copy on the serial prep queue so large videos never hitch the main thread.
    // dispatch_sync keeps loadFileRepresentation handlers from returning before the copy finishes.
    __block BOOL preparedSuccessfully = NO;
    dispatch_sync(self.preparationQueue, ^{
        preparedSuccessfully = [self prepareFileForUploadingAtURL:fileURL
                                                       toLocalURL:fileLocalURL
                                           withCoordinatorOption:NSFileCoordinatorReadingForUploading];
        if (!preparedSuccessfully) {
            preparedSuccessfully = [self prepareFileForUploadingAtURL:fileURL
                                                           toLocalURL:fileLocalURL
                                               withCoordinatorOption:NSFileCoordinatorReadingWithoutChanges];
        }
    });

    void (^finishOnMain)(void) = ^{
        if (!preparedSuccessfully) {
            NSLog(@"Failed to prepare file for sharing");
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: failed to prepare %@ for sharing", fileName]];
            // Do not record a user-facing failure here — callers may still fall back (e.g. UIImage).
            [self endPreparingItem];
            return;
        }

        NSString *extension = fileLocalURL.pathExtension.lowercaseString;
        BOOL fileIsImage = (extension.length > 0 && [NCUtils isImageWithFileExtension:extension]);

        if (fileIsImage) {
            [self finalizeImageItemFromLocalURL:fileLocalURL fileName:fileName];
            return;
        }

        if (extension.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:extension]) {
            [self finalizeVideoItemFromLocalURL:fileLocalURL fileName:fileName];
            return;
        }

        [self addShareItemWithLocalURL:fileLocalURL fileName:fileName isImage:fileIsImage];
        [self endPreparingItem];
    };
    if ([NSThread isMainThread]) {
        finishOnMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), finishOnMain);
    }

    return preparedSuccessfully;
}

- (void)addImageFromItemProvider:(NSItemProvider *)itemProvider
{
    [self addImageFromItemProvider:itemProvider completion:nil];
}

- (void)addImageFromItemProvider:(NSItemProvider *)itemProvider completion:(void (^)(BOOL success))completion
{
    void (^finish)(BOOL) = ^(BOOL success) {
        if (!completion) {
            return;
        }
        if ([NSThread isMainThread]) {
            completion(success);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success);
            });
        }
    };

    if (!itemProvider || ![itemProvider hasItemConformingToTypeIdentifier:(NSString *)kUTTypeImage]) {
        [NCLog log:@"ShareItemController: image fallback skipped — provider has no image type"];
        finish(NO);
        return;
    }

    __weak typeof(self) weakSelf = self;
    [itemProvider loadFileRepresentationForTypeIdentifier:(NSString *)kUTTypeImage
                                         completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
        ShareItemController *strongSelf = weakSelf;
        if (!strongSelf) {
            finish(NO);
            return;
        }

        if (url != nil) {
            NSString *name = url.lastPathComponent.length > 0 ? url.lastPathComponent : [NSString stringWithFormat:@"IMG_%.f.jpg", [[NSDate date] timeIntervalSince1970] * 1000];
            // Must copy before this handler returns — system deletes the representation file.
            if ([strongSelf addItemWithURLAndName:url withName:name]) {
                [NCLog log:[NSString stringWithFormat:@"ShareItemController: image fallback staged file representation %@", name]];
                finish(YES);
                return;
            }
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: image file representation copy failed (%@)", error.localizedDescription ?: @"empty"]];
        } else {
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: loadFileRepresentation(image) failed: %@", error.localizedDescription ?: @"nil url"]];
        }

        // Decoded bitmap path — loses HEIC container but still uploads a real JPEG.
        [itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage * _Nullable image, NSError * _Nullable imageError) {
            ShareItemController *innerSelf = weakSelf;
            if (!innerSelf) {
                finish(NO);
                return;
            }
            if (image != nil) {
                [NCLog log:@"ShareItemController: image fallback staged via UIImage"];
                [innerSelf addItemWithImage:image];
                finish(YES);
                return;
            }

            [itemProvider loadItemForTypeIdentifier:(NSString *)kUTTypeImage
                                            options:nil
                                  completionHandler:^(id<NSSecureCoding>  _Nullable item, NSError * _Null_unspecified loadError) {
                ShareItemController *loadSelf = weakSelf;
                if (!loadSelf) {
                    finish(NO);
                    return;
                }
                if ([(NSObject *)item isKindOfClass:[UIImage class]]) {
                    [NCLog log:@"ShareItemController: image fallback staged via loadItem UIImage"];
                    [loadSelf addItemWithImage:(UIImage *)item];
                    finish(YES);
                } else if ([(NSObject *)item isKindOfClass:[NSData class]]) {
                    UIImage *fromData = [UIImage imageWithData:(NSData *)item];
                    if (fromData) {
                        [NCLog log:@"ShareItemController: image fallback staged via loadItem NSData"];
                        [loadSelf addItemWithImage:fromData];
                        finish(YES);
                    } else {
                        [NCLog log:@"ShareItemController: image fallback NSData could not decode"];
                        [loadSelf reportStagingFailureWithName:NSLocalizedString(@"Photo", @"Generic name when a shared photo failed to load")];
                        finish(NO);
                    }
                } else if ([(NSObject *)item isKindOfClass:[NSURL class]]) {
                    [NCLog log:@"ShareItemController: image fallback trying loadItem URL"];
                    BOOL ok = [loadSelf addItemWithURL:(NSURL *)item];
                    if (!ok) {
                        [loadSelf reportStagingFailureWithName:NSLocalizedString(@"Photo", @"Generic name when a shared photo failed to load")];
                    }
                    finish(ok);
                } else {
                    [NCLog log:[NSString stringWithFormat:@"ShareItemController: all image fallbacks failed (%@)",
                                loadError.localizedDescription ?: imageError.localizedDescription ?: @"unknown"]];
                    [loadSelf reportStagingFailureWithName:NSLocalizedString(@"Photo", @"Generic name when a shared photo failed to load")];
                    finish(NO);
                }
            }];
        }];
    }];
}

- (void)addItemWithImage:(UIImage *)image
{
    NSString *imageName = [NSString stringWithFormat:@"IMG_%.f.jpg", [[NSDate date] timeIntervalSince1970] * 1000];
    [self addItemWithImageAndName:image withName:imageName];
}

- (void)addItemWithImageAndName:(UIImage *)image withName:(NSString *)imageName
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addItemWithImageAndName:image withName:imageName];
        });
        return;
    }

    [self beginPreparingItem];

    MediaUploadCompressionSettings *settings = self.stagingSettings;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        // Stage near-original JPEG for preview; compression runs on Send.
        NSData *jpegData = [MediaUploadPreprocessor compressedJPEGDataFromImage:image settings:settings];
        if (!jpegData) {
            jpegData = UIImageJPEGRepresentation(image, 1.0);
        }
        NSString *jpegName = [[imageName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];

        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            if (!jpegData) {
                NSLog(@"Failed to encode image for staging");
                [strongSelf endPreparingItem];
                return;
            }

            [strongSelf addItemWithImageDataAndName:jpegData withName:jpegName];
            [strongSelf endPreparingItem];
        });
    });
}

- (void)addItemWithImageDataAndName:(NSData *)data withName:(NSString *)imageName
{
    NSURL *fileLocalURL = [self getFileLocalURL:imageName];
    [data writeToFile:fileLocalURL.path atomically:YES];

    NSLog(@"Adding shareItem with image: %@ %@", imageName, fileLocalURL);

    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:imageName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (UIImage *)getImageFromItem:(ShareItem *)item
{
    if (!item || !item.fileURL) {
        return nil;
    }

    // Downsample for UI / crop — originals stay on disk for upload compression.
    return [MediaUploadPreprocessor previewImageAtURL:item.fileURL maxDimension:2048];
}

- (void)addItemWithContactData:(NSData *)data
{
    NSString *vCardFileName = [NSString stringWithFormat:@"Contact_%.f.vcf", [[NSDate date] timeIntervalSince1970] * 1000];
    [self addItemWithContactDataAndName:data withName:vCardFileName];
}

- (void)addItemWithContactDataAndName:(NSData *)data withName:(NSString *)vCardFileName
{
    NSURL *fileLocalURL = [self getFileLocalURL:vCardFileName];
    NSString* vcString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [vcString writeToFile:fileLocalURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
    NSLog(@"Adding shareItem with contact: %@ %@", vCardFileName, fileLocalURL);
    
    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:vCardFileName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)updateItem:(ShareItem *)item withURL:(NSURL *)fileURL
{
    // Quick Look edits — stage to a new local file, then swap paths (keeps original if copy fails).
    NSURL *destination = [self getFileLocalURL:item.fileName];
    BOOL ok = [self prepareFileForUploadingAtURL:fileURL toLocalURL:destination withCoordinatorOption:NSFileCoordinatorReadingForUploading];
    if (!ok) {
        ok = [self prepareFileForUploadingAtURL:fileURL toLocalURL:destination withCoordinatorOption:NSFileCoordinatorReadingWithoutChanges];
    }
    if (!ok) {
        NSLog(@"Failed to update shareItem from edited URL: %@", item.fileName);
        return;
    }

    NSString *oldPath = item.filePath;
    item.fileURL = destination;
    item.filePath = destination.path;
    item.fileName = destination.lastPathComponent;
    if (oldPath.length > 0 && ![oldPath isEqualToString:destination.path]) {
        [NSFileManager.defaultManager removeItemAtPath:oldPath error:nil];
    }

    NSLog(@"Updating shareItem: %@ %@", item.fileName, item.fileURL);
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)updateItem:(ShareItem *)item withImage:(UIImage *)image
{
    // Keep edited preview as high-quality JPEG; final compression runs on Send.
    NSData *jpegData = UIImageJPEGRepresentation(image, 1.0);
    if (!jpegData) {
        NSLog(@"Failed to encode updated image for staging");
        return;
    }

    [jpegData writeToFile:item.filePath atomically:YES];
    
    NSLog(@"Updating shareItem with Image: %@ %@", item.fileName, item.fileURL);
    
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)removeItem:(ShareItem *)item
{
    [self removeItems:@[item]];
}

- (void)removeItems:(NSArray<ShareItem *> *)items
{
    for (ShareItem *item in items) {
        [self cleanupItem:item];

        NSLog(@"Removing shareItem: %@ %@", item.fileName, item.fileURL);
        [self.internalShareItems removeObject:item];
    }

    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)cleanupItem:(ShareItem *)item
{
    if ([NSFileManager.defaultManager fileExistsAtPath:item.filePath]) {
        [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
    }
}

- (void)removeAllItems
{
    for (ShareItem *item in self.internalShareItems) {
        [self cleanupItem:item];
    }
    
    [self.internalShareItems removeAllObjects];
}

- (UIImage *)getPlaceholderImageForFileURL:(NSURL *)fileURL
{
    NSString *previewImage = [NCUtils previewImageForFileExtension:[fileURL pathExtension]];
    return [UIImage imageNamed:previewImage];
}

- (void)compressItem:(ShareItem *)item
            withLevel:(MediaUploadCompressionLevel)level
             progress:(void (^)(float fraction))progress
           completion:(void (^)(void))completion
{
    MediaUploadCompressionSettings *settings =
        [[MediaUploadCompressionSettings alloc] initWithLevel:level videoMaxEdgeCap:self.batchVideoMaxEdgeCap];
    NSString *extension = item.fileURL.pathExtension.lowercaseString;

    if (item.isImage && extension.length > 0 && [NCUtils isImageWithFileExtension:extension] && ![extension isEqualToString:@"gif"]) {
        // Chip may be on because another item benefits — skip this photo if it would not shrink.
        if (![MediaUploadDebugSettings itemCompressionLikelyShrinksAtURL:item.fileURL level:level]) {
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: skipping image compress for %@ (unlikely to shrink at level %ld)",
                        item.fileName, (long)level]];
            if (progress) {
                progress(1.0f);
            }
            if (completion) {
                completion();
            }
            return;
        }

        NSString *jpegName = [[item.fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        NSURL *jpegURL = [self getFileLocalURL:jpegName];
        NSURL *sourceURL = item.fileURL;

        dispatch_async(self.preparationQueue, ^{
            BOOL success = [MediaUploadPreprocessor compressImageAtURL:sourceURL
                                                      toDestinationURL:jpegURL
                                                              settings:settings];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:jpegURL.path error:nil];
                    unsigned long long written = [attrs fileSize];
                    NSDictionary *srcAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil];
                    unsigned long long original = [srcAttrs fileSize];
                    // Keep original when re-JPEG did not shrink (same safety net as video).
                    if (written > 0 && (original == 0 || written < original)) {
                        if (![item.filePath isEqualToString:jpegURL.path]) {
                            [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
                        }
                        item.fileURL = jpegURL;
                        item.filePath = jpegURL.path;
                        item.fileName = jpegURL.lastPathComponent;
                    } else {
                        [NCLog log:[NSString stringWithFormat:@"ShareItemController: image compress not smaller (%llu → %llu); keeping original %@",
                                    original, written, item.fileName]];
                        [NSFileManager.defaultManager removeItemAtURL:jpegURL error:nil];
                    }
                }
                if (progress) {
                    progress(1.0f);
                }
                if (completion) {
                    completion();
                }
            });
        });
        return;
    }

    if (extension.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:extension]) {
        // Chip may be on because another item benefits — skip already-small videos.
        // Heavy-batch ExportSession path already curated the work list; avoid another AVAsset open.
        if (!MediaUploadPreprocessor.preferExportSession
            && ![MediaUploadDebugSettings itemCompressionLikelyShrinksAtURL:item.fileURL level:level]) {
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: skipping video compress for %@ (unlikely to shrink at level %ld)",
                        item.fileName, (long)level]];
            if (progress) {
                progress(1.0f);
            }
            if (completion) {
                completion();
            }
            return;
        }

        NSString *mp4Name = [[item.fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
        NSURL *mp4URL = [self getFileLocalURL:mp4Name];
        NSURL *sourceURL = item.fileURL;
        MediaUploadPreparationToken *token = self.activePreparationToken;

        // Mirror image path: never create AVAsset / ExportSession on the main thread.
        dispatch_async(self.preparationQueue, ^{
            [MediaUploadPreprocessor compressVideoAtURL:sourceURL
                                       toDestinationURL:mp4URL
                                               settings:settings
                                            cancelToken:token
                                               progress:^(float fraction) {
                if (progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progress(fraction);
                    });
                }
            } completion:^(BOOL success) {
                void (^finishItem)(void) = ^{
                    if (success) {
                        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:mp4URL.path error:nil];
                        unsigned long long written = [attrs fileSize];
                        if (written > 0) {
                            if (![item.filePath isEqualToString:mp4URL.path]) {
                                [NSFileManager.defaultManager removeItemAtURL:item.fileURL error:nil];
                            }
                            item.fileURL = mp4URL;
                            item.filePath = mp4URL.path;
                            item.fileName = mp4Name;
                        } else {
                            NSLog(@"MediaUploadPreprocessor: refusing to swap to 0-byte compressed video %@", mp4Name);
                            [NCLog log:[NSString stringWithFormat:@"ShareItemController: refusing 0-byte compressed video %@", mp4Name]];
                            [NSFileManager.defaultManager removeItemAtURL:mp4URL error:nil];
                        }
                    } else {
                        [NSFileManager.defaultManager removeItemAtURL:mp4URL error:nil];
                    }
                    if (completion) {
                        completion();
                    }
                };
                if ([NSThread isMainThread]) {
                    finishItem();
                } else {
                    dispatch_async(dispatch_get_main_queue(), finishItem);
                }
            }];
        });
        return;
    }

    if (progress) {
        progress(1.0f);
    }
    if (completion) {
        completion();
    }
}

- (void)prepareItemsForUploadWithLevelProvider:(NSInteger (^)(ShareItem *item))levelProvider
                                      progress:(void (^)(float fraction))progress
                                   completion:(void (^)(void))completion
{
    NSArray<ShareItem *> *items = [self.internalShareItems copy];
    if (items.count == 0) {
        if (completion) {
            completion();
        }
        return;
    }

    // Build the work list first — only items that need compression.
    NSMutableArray<ShareItem *> *itemsToCompress = [NSMutableArray array];
    NSMutableArray<NSNumber *> *levelsToCompress = [NSMutableArray array];
    for (ShareItem *item in items) {
        MediaUploadCompressionLevel level = levelProvider ? (MediaUploadCompressionLevel)levelProvider(item) : MediaUploadCompressionLevelNone;
        if (level != MediaUploadCompressionLevelNone) {
            [itemsToCompress addObject:item];
            [levelsToCompress addObject:@(level)];
        }
    }

    NSInteger totalToCompress = (NSInteger)itemsToCompress.count;
    if (totalToCompress == 0) {
        [NCLog log:@"ShareItemController: prepareItemsForUpload — nothing to compress"];
        if (progress) {
            progress(1.0f);
        }
        if (completion) {
            completion();
        }
        return;
    }

    [self.activePreparationToken cancel];
    self.activePreparationToken = [[MediaUploadPreparationToken alloc] init];

    [NCLog log:[NSString stringWithFormat:@"ShareItemController: prepareItemsForUpload — compressing %ld item(s) serially", (long)totalToCompress]];

    // Largest first while memory is freshest (after preview release).
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:(NSUInteger)totalToCompress];
    for (NSInteger i = 0; i < totalToCompress; i++) {
        [order addObject:@(i)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        ShareItem *ia = itemsToCompress[a.integerValue];
        ShareItem *ib = itemsToCompress[b.integerValue];
        unsigned long long sa = [[NSFileManager.defaultManager attributesOfItemAtPath:ia.filePath error:nil] fileSize];
        unsigned long long sb = [[NSFileManager.defaultManager attributesOfItemAtPath:ib.filePath error:nil] fileSize];
        if (sa < sb) { return NSOrderedDescending; }
        if (sa > sb) { return NSOrderedAscending; }
        return NSOrderedSame;
    }];
    NSMutableArray<ShareItem *> *sortedItems = [NSMutableArray arrayWithCapacity:(NSUInteger)totalToCompress];
    NSMutableArray<NSNumber *> *sortedLevels = [NSMutableArray arrayWithCapacity:(NSUInteger)totalToCompress];
    for (NSNumber *idx in order) {
        [sortedItems addObject:itemsToCompress[idx.integerValue]];
        [sortedLevels addObject:levelsToCompress[idx.integerValue]];
    }
    [itemsToCompress setArray:sortedItems];
    [levelsToCompress setArray:sortedLevels];

    // Multi-video: ExportSession on a dedicated serial queue + full session teardown between files
    // (public AVFoundation pattern — main-thread session churn correlated with Nth-file process death).
    unsigned long long totalBytes = 0;
    for (ShareItem *item in itemsToCompress) {
        totalBytes += [[NSFileManager.defaultManager attributesOfItemAtPath:item.filePath error:nil] fileSize];
    }
    BOOL heavyBatch = (totalToCompress >= 2 && totalBytes >= 40ULL * 1024ULL * 1024ULL);
    if (heavyBatch) {
        self.batchVideoMaxEdgeCap = 640;
        MediaUploadPreprocessor.preferExportSession = YES;
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: batch ExportSession serial teardown (items=%ld total=%.1f MB edgeCap=640)",
                    (long)totalToCompress, totalBytes / 1048576.0]];
    } else if (totalToCompress >= 2) {
        self.batchVideoMaxEdgeCap = 720;
        MediaUploadPreprocessor.preferExportSession = YES;
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: batch ExportSession serial teardown (items=%ld edgeCap=720)",
                    (long)totalToCompress]];
    } else {
        self.batchVideoMaxEdgeCap = 0;
        MediaUploadPreprocessor.preferExportSession = NO;
    }

    if (progress) {
        progress(0.0f);
    }

    // One encode at a time. Parallel AVAssetWriter sessions jetsam the process when several
    // large videos (e.g. screen recordings) are selected — seen as an instant relaunch mid-prepare.
    __weak typeof(self) weakSelf = self;
    __block NSInteger completedCount = 0;
    __block float currentItemFraction = 0.0f;

    void (^reportOverall)(void) = ^{
        void (^emit)(void) = ^{
            if (!progress) {
                return;
            }
            float overall = MIN(1.0f, ((float)completedCount + currentItemFraction) / (float)totalToCompress);
            progress(overall);
        };
        if ([NSThread isMainThread]) {
            emit();
        } else {
            dispatch_async(dispatch_get_main_queue(), emit);
        }
    };

    BOOL usedExportBatch = heavyBatch || (totalToCompress >= 2);
    void (^finishAll)(void) = ^{
        void (^done)(void) = ^{
            typeof(self) strongSelf = weakSelf;
            BOOL cancelled = strongSelf.activePreparationToken.isCancelled;
            strongSelf.activePreparationToken = nil;
            strongSelf.batchVideoMaxEdgeCap = 0;
            MediaUploadPreprocessor.preferExportSession = NO;
            // Sync — async NCLog often never flushes when jetsam hits the upload handoff.
            [NCLog logSync:[NSString stringWithFormat:@"ShareItemController: prepareItemsForUpload — finished (cancelled=%d)", cancelled]];
            // Do NOT call shareItemControllerItemsChanged here. Reloading the pager regenerates
            // full-screen video thumbnails right after encode and jetsams multi-video sends.
            // ShareConfirmation starts upload from the completion callback instead.
            if (completion) {
                completion();
            }
        };
        // Final mediaserverd cooldown off-main before upload handoff.
        // Multi-video ExportSession batches were dying ~5s after the last ACTUAL with no
        // "finished" line (async log + MemoryGate spinning on available==0).
        dispatch_async(weakSelf.preparationQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NCLog logSync:[NSString stringWithFormat:@"ShareItemController: prepare handoff drain (exportBatch=%d avail=%.0f MB)",
                            usedExportBatch, [MediaUploadMemoryGateObjC availableMegabytes]]];
            if (usedExportBatch) {
                [MediaUploadMemoryGateObjC drainAfterExportBatch];
            } else {
                [MediaUploadMemoryGateObjC waitForHeadroom];
            }
            [NCLog logSync:@"ShareItemController: prepare handoff → main"];
            dispatch_async(dispatch_get_main_queue(), done);
        });
    };

    __block void (^processNext)(NSInteger index) = nil;
    processNext = ^(NSInteger index) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.activePreparationToken.isCancelled || index >= totalToCompress) {
            // CRITICAL: call finishAll BEFORE clearing processNext.
            // processNext is the last owner of finishAll (prepareItemsForUpload already returned).
            // `processNext = nil; finishAll();` was use-after-free — silent relaunch after the
            // last encode (seen as die after "after compress N/N → next", never "handoff drain").
            [NCLog logSync:[NSString stringWithFormat:@"ShareItemController: prepare serial done (index=%ld) → finishAll", (long)index]];
            void (^finish)(void) = [finishAll copy];
            processNext = nil;
            finish();
            return;
        }

        ShareItem *item = itemsToCompress[index];
        MediaUploadCompressionLevel level = (MediaUploadCompressionLevel)levelsToCompress[index].integerValue;
        currentItemFraction = 0.0f;
        reportOverall();

        id<ShareItemControllerDelegate> delegate = strongSelf.delegate;
        if ([delegate respondsToSelector:@selector(shareItemControllerShouldReleaseHeavyPreviews:)]) {
            [delegate shareItemControllerShouldReleaseHeavyPreviews:strongSelf];
        }

        [strongSelf beginPreparingItem];
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: compressing %@ at level %ld (%ld/%ld) avail=%.0f MB",
                    item.fileName, (long)level, (long)(index + 1), (long)totalToCompress,
                    [MediaUploadMemoryGateObjC availableMegabytes]]];

        [strongSelf compressItem:item withLevel:level progress:^(float fraction) {
            currentItemFraction = MAX(0.0f, MIN(1.0f, fraction));
            reportOverall();
        } completion:^{
            // Drain autoreleased AVFoundation buffers off the main thread before the next encode.
            typeof(self) queueSelf = weakSelf;
            dispatch_queue_t prepQueue = queueSelf.preparationQueue;
            if (!prepQueue) {
                processNext(index + 1);
                return;
            }
            dispatch_async(prepQueue, ^{
                @autoreleasepool {
                    // Extra mediaserverd drain between serial encodes (in addition to ExportSession teardown).
                    if (MediaUploadPreprocessor.preferExportSession) {
                        [NSThread sleepForTimeInterval:0.35];
                    } else {
                        [MediaUploadMemoryGateObjC waitForHeadroom];
                    }
                }
                [NCLog logSync:[NSString stringWithFormat:@"ShareItemController: after compress %ld/%ld → next",
                                (long)(index + 1), (long)totalToCompress]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) innerSelf = weakSelf;
                    [NCLog logSync:[NSString stringWithFormat:@"ShareItemController: main after compress %ld/%ld",
                                    (long)(index + 1), (long)totalToCompress]];
                    [innerSelf endPreparingItem];
                    completedCount += 1;
                    currentItemFraction = 0.0f;
                    reportOverall();
                    processNext(index + 1);
                });
            });
        }];
    };

    processNext(0);
}

@end
