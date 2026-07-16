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
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingStagingFailures;
@property (nonatomic, strong) MediaUploadPreparationToken *activePreparationToken;

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
    if (self.preparingItemCount == 0) {
        [self flushPendingStagingFailures];
    }
}

- (void)reportStagingFailureWithName:(NSString *)fileName
{
    NSString *name = fileName.length > 0 ? fileName : NSLocalizedString("Shared file", comment: "Generic name when a shared attachment has no filename");
    void (^record)(void) = ^{
        [self.pendingStagingFailures addObject:name];
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: staging failure recorded for %@", name]];
        if (self.preparingItemCount == 0) {
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
    if (!itemProvider || ![itemProvider hasItemConformingToTypeIdentifier:(NSString *)kUTTypeImage]) {
        [NCLog log:@"ShareItemController: image fallback skipped — provider has no image type"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [itemProvider loadFileRepresentationForTypeIdentifier:(NSString *)kUTTypeImage
                                         completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
        ShareItemController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (url != nil) {
            NSString *name = url.lastPathComponent.length > 0 ? url.lastPathComponent : [NSString stringWithFormat:@"IMG_%.f.jpg", [[NSDate date] timeIntervalSince1970] * 1000];
            // Must copy before this handler returns — system deletes the representation file.
            if ([strongSelf addItemWithURLAndName:url withName:name]) {
                [NCLog log:[NSString stringWithFormat:@"ShareItemController: image fallback staged file representation %@", name]];
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
                return;
            }
            if (image != nil) {
                [NCLog log:@"ShareItemController: image fallback staged via UIImage"];
                [innerSelf addItemWithImage:image];
                return;
            }

            [itemProvider loadItemForTypeIdentifier:(NSString *)kUTTypeImage
                                            options:nil
                                  completionHandler:^(id<NSSecureCoding>  _Nullable item, NSError * _Null_unspecified loadError) {
                ShareItemController *loadSelf = weakSelf;
                if (!loadSelf) {
                    return;
                }
                if ([(NSObject *)item isKindOfClass:[UIImage class]]) {
                    [NCLog log:@"ShareItemController: image fallback staged via loadItem UIImage"];
                    [loadSelf addItemWithImage:(UIImage *)item];
                } else if ([(NSObject *)item isKindOfClass:[NSData class]]) {
                    UIImage *fromData = [UIImage imageWithData:(NSData *)item];
                    if (fromData) {
                        [NCLog log:@"ShareItemController: image fallback staged via loadItem NSData"];
                        [loadSelf addItemWithImage:fromData];
                    } else {
                        [NCLog log:@"ShareItemController: image fallback NSData could not decode"];
                    }
                } else if ([(NSObject *)item isKindOfClass:[NSURL class]]) {
                    [NCLog log:@"ShareItemController: image fallback trying loadItem URL"];
                    [loadSelf addItemWithURL:(NSURL *)item];
                } else {
                    [NCLog log:[NSString stringWithFormat:@"ShareItemController: all image fallbacks failed (%@)",
                                loadError.localizedDescription ?: imageError.localizedDescription ?: @"unknown"]];
                    [loadSelf reportStagingFailureWithName:NSLocalizedString("Photo", comment: "Generic name when a shared photo failed to load")];
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
    MediaUploadCompressionSettings *settings = [[MediaUploadCompressionSettings alloc] initWithLevel:level];
    NSString *extension = item.fileURL.pathExtension.lowercaseString;

    if (item.isImage && extension.length > 0 && [NCUtils isImageWithFileExtension:extension] && ![extension isEqualToString:@"gif"]) {
        NSString *jpegName = [[item.fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        NSURL *jpegURL = [self getFileLocalURL:jpegName];

        dispatch_async(self.preparationQueue, ^{
            BOOL success = [MediaUploadPreprocessor compressImageAtURL:item.fileURL
                                                      toDestinationURL:jpegURL
                                                              settings:settings];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:jpegURL.path error:nil];
                    unsigned long long written = [attrs fileSize];
                    if (written > 0) {
                        if (![item.filePath isEqualToString:jpegURL.path]) {
                            [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
                        }
                        item.fileURL = jpegURL;
                        item.filePath = jpegURL.path;
                        item.fileName = jpegURL.lastPathComponent;
                    } else {
                        NSLog(@"MediaUploadPreprocessor: refusing to swap to 0-byte compressed image %@", jpegURL.lastPathComponent);
                        [NCLog log:[NSString stringWithFormat:@"ShareItemController: refusing 0-byte compressed image %@", jpegURL.lastPathComponent]];
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
        NSString *mp4Name = [[item.fileName stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
        NSURL *mp4URL = [self getFileLocalURL:mp4Name];

        [MediaUploadPreprocessor compressVideoAtURL:item.fileURL
                                   toDestinationURL:mp4URL
                                           settings:settings
                                        cancelToken:self.activePreparationToken
                                           progress:^(float fraction) {
            if (progress) {
                progress(fraction);
            }
        } completion:^(BOOL success) {
            // Completion already hops to main inside MediaUploadPreprocessor.
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
        }];
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

    NSInteger totalToCompress = 0;
    for (ShareItem *item in items) {
        MediaUploadCompressionLevel level = levelProvider ? (MediaUploadCompressionLevel)levelProvider(item) : MediaUploadCompressionLevelNone;
        if (level != MediaUploadCompressionLevelNone) {
            totalToCompress += 1;
        }
    }

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

    [NCLog log:[NSString stringWithFormat:@"ShareItemController: prepareItemsForUpload — compressing %ld item(s)", (long)totalToCompress]];

    if (progress) {
        progress(0.0f);
    }

    dispatch_group_t group = dispatch_group_create();
    __block NSInteger completedCount = 0;
    // Track in-flight item fractions so multi-item prepare can show continuous progress.
    NSMutableDictionary<NSNumber *, NSNumber *> *itemFractions = [NSMutableDictionary dictionary];
    __block NSInteger nextItemIndex = 0;

    void (^reportOverall)(void) = ^{
        void (^emit)(void) = ^{
            if (!progress) {
                return;
            }
            __block float sum = (float)completedCount;
            [itemFractions enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSNumber *value, BOOL *stop) {
                sum += value.floatValue;
            }];
            float overall = MIN(1.0f, sum / (float)totalToCompress);
            progress(overall);
        };
        if ([NSThread isMainThread]) {
            emit();
        } else {
            dispatch_async(dispatch_get_main_queue(), emit);
        }
    };

    for (ShareItem *item in items) {
        MediaUploadCompressionLevel level = levelProvider ? (MediaUploadCompressionLevel)levelProvider(item) : MediaUploadCompressionLevelNone;
        if (level == MediaUploadCompressionLevelNone) {
            continue;
        }

        NSNumber *itemKey = @(nextItemIndex);
        nextItemIndex += 1;
        itemFractions[itemKey] = @0;

        dispatch_group_enter(group);
        [self beginPreparingItem];
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: compressing %@ at level %ld", item.fileName, (long)level]];
        [self compressItem:item withLevel:level progress:^(float fraction) {
            void (^update)(void) = ^{
                itemFractions[itemKey] = @(MAX(0.0f, MIN(1.0f, fraction)));
                reportOverall();
            };
            if ([NSThread isMainThread]) {
                update();
            } else {
                dispatch_async(dispatch_get_main_queue(), update);
            }
        } completion:^{
            void (^finish)(void) = ^{
                [itemFractions removeObjectForKey:itemKey];
                completedCount += 1;
                reportOverall();
                [self endPreparingItem];
                dispatch_group_leave(group);
            };
            if ([NSThread isMainThread]) {
                finish();
            } else {
                dispatch_async(dispatch_get_main_queue(), finish);
            }
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        BOOL cancelled = self.activePreparationToken.isCancelled;
        self.activePreparationToken = nil;
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: prepareItemsForUpload — finished (cancelled=%d)", cancelled]];
        [self.delegate shareItemControllerItemsChanged:self];
        if (completion) {
            completion();
        }
    });
}

@end
