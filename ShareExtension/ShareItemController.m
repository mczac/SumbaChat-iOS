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

- (void)addItemWithURL:(NSURL *)fileURL
{
    [self addItemWithURLAndName:fileURL withName:fileURL.lastPathComponent];
}

- (BOOL)prepareFileForUploadingAtURL:(NSURL *)fileURL toLocalURL:(NSURL *)fileLocalURL withCoordinatorOption:(NSFileCoordinatorReadingOptions)options
{
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *error;

    // Make a local copy to prevent bug where file is removed after some time from inbox
    // See: https://stackoverflow.com/a/48007752/2512312
    [coordinator coordinateReadingItemAtURL:fileURL options:options error:&error byAccessor:^(NSURL *newURL) {
        if ([NSFileManager.defaultManager fileExistsAtPath:fileLocalURL.path]) {
            [NSFileManager.defaultManager removeItemAtPath:fileLocalURL.path error:nil];
        }

        [NSFileManager.defaultManager moveItemAtPath:newURL.path toPath:fileLocalURL.path error:nil];
    }];

    BOOL success = (error == nil);
    return success;
}

- (void)addShareItemWithLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName isImage:(BOOL)fileIsImage
{
    NSLog(@"Adding shareItem: %@ %@", fileName, fileLocalURL);
    [NCLog log:[NSString stringWithFormat:@"ShareItemController: staged %@ (%@)", fileName, fileLocalURL.lastPathComponent]];

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

- (void)addItemWithURLAndName:(NSURL *)fileURL withName:(NSString *)fileName
{
    // PHPicker / NSItemProvider completions are often off the main thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addItemWithURLAndName:fileURL withName:fileName];
        });
        return;
    }

    [self beginPreparingItem];

    NSURL *fileLocalURL = [self getFileLocalURL:fileName];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        ShareItemController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        // Copy off the main thread so large videos don't freeze the share sheet.
        BOOL preparedSuccessfully = [strongSelf prepareFileForUploadingAtURL:fileURL toLocalURL:fileLocalURL withCoordinatorOption:NSFileCoordinatorReadingForUploading];

        if (!preparedSuccessfully) {
            preparedSuccessfully = [strongSelf prepareFileForUploadingAtURL:fileURL toLocalURL:fileLocalURL withCoordinatorOption:NSFileCoordinatorReadingWithoutChanges];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ShareItemController *mainSelf = weakSelf;
            if (!mainSelf) {
                return;
            }

            if (!preparedSuccessfully) {
                NSLog(@"Failed to prepare file for sharing");
                [NCLog log:[NSString stringWithFormat:@"ShareItemController: failed to prepare %@ for sharing", fileName]];
                [mainSelf endPreparingItem];
                return;
            }

            NSString *extension = fileLocalURL.pathExtension.lowercaseString;
            BOOL fileIsImage = (extension.length > 0 && [NCUtils isImageWithFileExtension:extension]);

            if (fileIsImage) {
                [mainSelf finalizeImageItemFromLocalURL:fileLocalURL fileName:fileName];
                return;
            }

            if (extension.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:extension]) {
                [mainSelf finalizeVideoItemFromLocalURL:fileLocalURL fileName:fileName];
                return;
            }

            [mainSelf addShareItemWithLocalURL:fileLocalURL fileName:fileName isImage:fileIsImage];
            [mainSelf endPreparingItem];
        });
    });
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
    // This is called when an item was edited in quicklook and we want to use the edited image
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *error;
    
    [coordinator coordinateReadingItemAtURL:fileURL options:NSFileCoordinatorReadingForUploading error:&error byAccessor:^(NSURL *newURL) {
        if ([NSFileManager.defaultManager fileExistsAtPath:item.filePath]) {
            [NSFileManager.defaultManager removeItemAtPath:item.filePath error:nil];
        }
        
        [NSFileManager.defaultManager moveItemAtPath:newURL.path toPath:item.filePath error:nil];
    }];
    
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
        [NCLog log:@"ShareItemController: prepareItemsForUpload — finished"];
        [self.delegate shareItemControllerItemsChanged:self];
        if (completion) {
            completion();
        }
    });
}

@end
