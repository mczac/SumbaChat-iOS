/**
 * SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
 * SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <MobileCoreServices/MobileCoreServices.h>

#import "ShareItemController.h"
#import "SumbaChat-Swift.h"

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
/// Content fingerprints already staged in this bag (dedup).
@property (nonatomic, strong) NSMutableSet<NSString *> *stagedContentFingerprints;

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
        self.stagedContentFingerprints = [[NSMutableSet alloc] init];
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
    // Wipe prior session upload/ + thumbs/ before staging (sync — must be empty first).
    [MediaUploadDiskStore clearSessionScratchCachesWithReason:@"share-init" wait:YES];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    // App Group Caches (shared with main app) — falls back to tmp if group unavailable.
    self.tempDirectoryPath = [MediaUploadDiskStore.shared uploadDirectoryPath];
    if (![self.tempDirectoryPath hasSuffix:@"/"]) {
        self.tempDirectoryPath = [self.tempDirectoryPath stringByAppendingString:@"/"];
    }

    if (![fileManager fileExistsAtPath:self.tempDirectoryPath]) {
        [fileManager createDirectoryAtPath:self.tempDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    self.tempDirectoryURL = [NSURL fileURLWithPath:self.tempDirectoryPath isDirectory:YES];
    [MediaUploadDiskStore enforceUploadStagingBudget];
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

/// Confine staging names to a single path component under `upload/` (blocks `../` traversal).
- (NSString *)sanitizedStagingFileName:(NSString *)fileName
{
    NSString *fallback = [NSString stringWithFormat:@"file-%.0f.bin", [[NSDate date] timeIntervalSince1970] * 1000];
    if (fileName.length == 0) {
        return fallback;
    }

    NSString *name = [fileName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    name = name.lastPathComponent;
    name = [name stringByReplacingOccurrencesOfString:@"\0" withString:@""];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return fallback;
    }

    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"/\\"];
    if ([name rangeOfCharacterFromSet:separators].location != NSNotFound) {
        name = [[name componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@"_"];
    }
    if ([name containsString:@".."]) {
        name = [name stringByReplacingOccurrencesOfString:@".." withString:@"_"];
    }
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return fallback;
    }
    return name;
}

- (NSURL *)getFileLocalURL:(NSString *)fileName
{
    NSString *safeName = [self sanitizedStagingFileName:fileName];
    NSURL *rootURL = self.tempDirectoryURL.URLByStandardizingPath;
    NSURL *fileLocalURL = [[rootURL URLByAppendingPathComponent:safeName] URLByStandardizingPath];

    // Defense in depth: never allow a resolved path outside upload staging.
    NSString *rootPath = rootURL.path;
    NSString *resolvedPath = fileLocalURL.path;
    BOOL underRoot = [resolvedPath isEqualToString:rootPath]
        || [resolvedPath hasPrefix:[rootPath stringByAppendingString:@"/"]];
    if (!underRoot) {
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: rejected staging path escape for %@", fileName]];
        safeName = [self sanitizedStagingFileName:@""];
        fileLocalURL = [rootURL URLByAppendingPathComponent:safeName];
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:fileLocalURL.path]) {
        NSString *extension = [safeName pathExtension];
        NSString *nameWithoutExtension = [safeName stringByDeletingPathExtension];
        NSString *newFileName = [NSString stringWithFormat:@"%@%.f.%@", nameWithoutExtension, [[NSDate date] timeIntervalSince1970] * 1000, extension];
        newFileName = [self sanitizedStagingFileName:newFileName];
        fileLocalURL = [rootURL URLByAppendingPathComponent:newFileName];
    }

    return fileLocalURL;
}

/// Always-unique upload path for a re-encoded derivative.
/// Avoids `IMG_0002.JPG` vs `IMG_0002.jpg` collisions on case-insensitive volumes
/// (those made convert-HIT / encode silently fall back to originals).
- (NSURL *)uniqueDerivativeURLWithBaseName:(NSString *)baseName pathExtension:(NSString *)ext
{
    NSString *safeBase = [[self sanitizedStagingFileName:baseName] stringByDeletingPathExtension];
    if (safeBase.length == 0) {
        safeBase = @"file";
    }
    NSString *safeExt = ext.length > 0 ? ext.lowercaseString : @"bin";
    NSString *name = [NSString stringWithFormat:@"%@_%@.%@", safeBase, [[NSUUID UUID] UUIDString], safeExt];
    NSURL *rootURL = self.tempDirectoryURL.URLByStandardizingPath;
    return [rootURL URLByAppendingPathComponent:[self sanitizedStagingFileName:name]];
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
            // Never memory-map large / video files — Share Extension jetsam risk.
            NSString *ext = newURL.pathExtension.lowercaseString.length
                ? newURL.pathExtension.lowercaseString
                : fileLocalURL.pathExtension.lowercaseString;
            BOOL isVideo = ext.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:ext];
            NSNumber *fileSizeNum = nil;
            [newURL getResourceValue:&fileSizeNum forKey:NSURLFileSizeKey error:nil];
            unsigned long long knownSize = fileSizeNum != nil ? fileSizeNum.unsignedLongLongValue : 0;
            static const unsigned long long kMappedFallbackMaxBytes = 48ULL * 1024ULL * 1024ULL;
            if (isVideo || (knownSize > 0 && knownSize > kMappedFallbackMaxBytes)) {
                [NCLog log:[NSString stringWithFormat:
                    @"ShareItemController: refusing mapped staging fallback (%@ size=%llu video=%d)",
                    ext, knownSize, isVideo ? 1 : 0]];
                wroteBytes = NO;
                [fm removeItemAtURL:stagingURL error:nil];
                ioError = [NSError errorWithDomain:@"ShareItemController"
                                              code:2
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Provider copy failed; refusing large/video memory fallback"}];
                return;
            }
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

        [MediaUploadDiskStore removeItemAllowingCaseVariantsAtURL:fileLocalURL];
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

- (NSString *)contentFingerprintRejectingDuplicateAtURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    NSString *fingerprint = [MediaUploadDiskStore contentFingerprintAtPath:fileLocalURL.path];
    if (fingerprint.length == 0) {
        return @"";
    }
    if ([self.stagedContentFingerprints containsObject:fingerprint]) {
        [MediaUploadTrace log:[NSString stringWithFormat:@"CACHE dedup-skip %@ (same content already in bag)", fileName]];
        [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
        return nil;
    }
    [self.stagedContentFingerprints addObject:fingerprint];
    return fingerprint;
}

- (void)addShareItemWithLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName isImage:(BOOL)fileIsImage
{
    if (![self fileURLHasNonZeroContent:fileLocalURL]) {
        NSLog(@"Refusing to stage empty shareItem: %@ %@", fileName, fileLocalURL);
        [NCLog log:[NSString stringWithFormat:@"ShareItemController: refusing empty staged file %@", fileName]];
        [NSFileManager.defaultManager removeItemAtURL:fileLocalURL error:nil];
        return;
    }

    NSString *fingerprint = [self contentFingerprintRejectingDuplicateAtURL:fileLocalURL fileName:fileName];
    if (!fingerprint) {
        return;
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:fileLocalURL.path error:nil];
    NSLog(@"Adding shareItem: %@ %@ (%llu bytes)", fileName, fileLocalURL, (unsigned long long)[attrs fileSize]);
    [NCLog log:[NSString stringWithFormat:@"ShareItemController: staged %@ (%@, %llu bytes)",
                fileName, fileLocalURL.lastPathComponent, (unsigned long long)[attrs fileSize]]];

    ShareItem *item = [ShareItem initWithURL:fileLocalURL withName:fileName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:fileIsImage];
    item.contentFingerprint = fingerprint.length > 0 ? fingerprint : nil;
    if (fileIsImage || [NCUtils isImageWithFileExtension:fileLocalURL.pathExtension.lowercaseString]) {
        UIImage *preview = [MediaUploadPreprocessor previewImageAtURL:fileLocalURL maxDimension:1024];
        if (preview) {
            [MediaUploadDiskStore storeThumbFromImage:preview forStagingPath:fileLocalURL.path];
            item.placeholderImage = preview;
        }
    }
    [self.internalShareItems addObject:item];
    // Refresh cross-process marker so long compose / multi-stage stays protected.
    [MediaUploadDiskStore touchUploadSession];
    [self.delegate shareItemControllerItemsChanged:self];
}

- (void)finalizeImageItemFromLocalURL:(NSURL *)fileLocalURL fileName:(NSString *)fileName
{
    // Stage original (or lightly re-encoded only if settings request it during staging).
    NSURL *jpegURL = [self uniqueDerivativeURLWithBaseName:fileName pathExtension:@"jpg"];
    NSString *jpegName = jpegURL.lastPathComponent;
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
    NSString *safeName = [self sanitizedStagingFileName:fileName];
    __block NSURL *fileLocalURL = nil;
    void (^beginOnMain)(void) = ^{
        [self beginPreparingItem];
        fileLocalURL = [self getFileLocalURL:safeName];
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
            [NCLog log:[NSString stringWithFormat:@"ShareItemController: failed to prepare %@ for sharing", safeName]];
            // Do not record a user-facing failure here — callers may still fall back (e.g. UIImage).
            [self endPreparingItem];
            return;
        }

        NSString *extension = fileLocalURL.pathExtension.lowercaseString;
        BOOL fileIsImage = (extension.length > 0 && [NCUtils isImageWithFileExtension:extension]);

        if (fileIsImage) {
            [self finalizeImageItemFromLocalURL:fileLocalURL fileName:safeName];
            return;
        }

        if (extension.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:extension]) {
            [self finalizeVideoItemFromLocalURL:fileLocalURL fileName:safeName];
            return;
        }

        [self addShareItemWithLocalURL:fileLocalURL fileName:safeName isImage:fileIsImage];
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
    NSString *safeName = [self sanitizedStagingFileName:imageName];
    NSURL *fileLocalURL = [self getFileLocalURL:safeName];
    [data writeToFile:fileLocalURL.path atomically:YES];

    NSLog(@"Adding shareItem with image: %@ %@", safeName, fileLocalURL);

    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:safeName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [MediaUploadDiskStore touchUploadSession];
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
    NSString *safeName = [self sanitizedStagingFileName:vCardFileName];
    NSURL *fileLocalURL = [self getFileLocalURL:safeName];
    NSString* vcString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [vcString writeToFile:fileLocalURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
    NSLog(@"Adding shareItem with contact: %@ %@", safeName, fileLocalURL);
    
    ShareItem* item = [ShareItem initWithURL:fileLocalURL withName:safeName withPlaceholderImage:[self getPlaceholderImageForFileURL:fileLocalURL] isImage:YES];

    [self.internalShareItems addObject:item];
    [MediaUploadDiskStore touchUploadSession];
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
    if (item.contentFingerprint.length > 0) {
        [self.stagedContentFingerprints removeObject:item.contentFingerprint];
    }
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
    [self.stagedContentFingerprints removeAllObjects];
    // Catch orphans (encode sidecars, thumbs) after a finished send.
    [MediaUploadDiskStore clearSessionScratchCachesWithReason:@"share-remove-all" wait:NO];
}

- (UIImage *)getPlaceholderImageForFileURL:(NSURL *)fileURL
{
    UIImage *thumb = [MediaUploadDiskStore loadThumbForStagingPath:fileURL.path];
    if (thumb) {
        return thumb;
    }
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
            unsigned long long origSkip = [[NSFileManager.defaultManager attributesOfItemAtPath:item.filePath error:nil] fileSize];
            [MediaUploadTrace log:[NSString stringWithFormat:
                @"ENCODE skip image %@ level=%@ original=%@ reason=unlikely-to-shrink",
                item.fileName, [MediaUploadTrace levelName:level], [MediaUploadTrace mbUInt:origSkip]]];
            if (progress) {
                progress(1.0f);
            }
            if (completion) {
                completion();
            }
            return;
        }

        NSURL *jpegURL = [self uniqueDerivativeURLWithBaseName:item.fileName pathExtension:@"jpg"];
        NSURL *sourceURL = item.fileURL;

        dispatch_async(self.preparationQueue, ^{
            BOOL success = NO;
            NSString *accountId = self.accountId ?: @"";
            NSURL *cached = [MediaUploadDiskStore cachedConvertURLForSourceURL:sourceURL
                                                                     accountId:accountId
                                                                         level:level
                                                                      settings:settings
                                                               outputExtension:@"jpg"];
            if (cached) {
                NSError *copyError = nil;
                success = [MediaUploadDiskStore copyItemReplacingAtURL:cached toURL:jpegURL error:&copyError];
                if (success) {
                    unsigned long long cachedBytes = [[NSFileManager.defaultManager attributesOfItemAtPath:jpegURL.path error:nil] fileSize];
                    NSString *profile = [MediaUploadDiskStore profileFingerprintForLevel:level settings:settings];
                    [MediaUploadTrace log:[NSString stringWithFormat:
                        @"CACHE convert-HIT image %@ level=%@ result=%@ profile=%@",
                        item.fileName, [MediaUploadTrace levelName:level], [MediaUploadTrace mbUInt:cachedBytes], profile]];
                } else {
                    [MediaUploadTrace log:[NSString stringWithFormat:@"CACHE convert-copy-FAIL image %@", copyError.localizedDescription ?: @""]];
                }
            }
            if (!success) {
                [MediaUploadTrace log:[NSString stringWithFormat:@"ENCODE image start %@ level=%@",
                                       item.fileName, [MediaUploadTrace levelName:level]]];
                success = [MediaUploadPreprocessor compressImageAtURL:sourceURL
                                                     toDestinationURL:jpegURL
                                                             settings:settings];
                if (success) {
                    [MediaUploadDiskStore storeConvertResultFrom:jpegURL
                                                       sourceURL:sourceURL
                                                       accountId:accountId
                                                           level:level
                                                        settings:settings];
                }
            }
            [MediaUploadMemoryGateObjC waitForHeadroom];
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
                        [MediaUploadTrace log:[NSString stringWithFormat:
                            @"RESULT image %@ level=%@ original=%@ → result=%@ (kept compressed)",
                            item.fileName, [MediaUploadTrace levelName:level],
                            [MediaUploadTrace mbUInt:original], [MediaUploadTrace mbUInt:written]]];
                    } else {
                        [MediaUploadTrace log:[NSString stringWithFormat:
                            @"RESULT image %@ level=%@ original=%@ → result=%@ (kept original, not smaller)",
                            item.fileName, [MediaUploadTrace levelName:level],
                            [MediaUploadTrace mbUInt:original], [MediaUploadTrace mbUInt:written]]];
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
            unsigned long long origSkip = [[NSFileManager.defaultManager attributesOfItemAtPath:item.filePath error:nil] fileSize];
            [MediaUploadTrace log:[NSString stringWithFormat:
                @"ENCODE skip video %@ level=%@ original=%@ reason=unlikely-to-shrink",
                item.fileName, [MediaUploadTrace levelName:level], [MediaUploadTrace mbUInt:origSkip]]];
            if (progress) {
                progress(1.0f);
            }
            if (completion) {
                completion();
            }
            return;
        }

        NSURL *mp4URL = [self uniqueDerivativeURLWithBaseName:item.fileName pathExtension:@"mp4"];
        NSString *mp4Name = mp4URL.lastPathComponent;
        NSURL *sourceURL = item.fileURL;
        MediaUploadPreparationToken *token = self.activePreparationToken;

        // Mirror image path: never create AVAsset / ExportSession on the main thread.
        dispatch_async(self.preparationQueue, ^{
            NSString *accountId = self.accountId ?: @"";
            NSURL *cached = [MediaUploadDiskStore cachedConvertURLForSourceURL:sourceURL
                                                                     accountId:accountId
                                                                         level:level
                                                                      settings:settings
                                                               outputExtension:@"mp4"];
            if (cached) {
                NSError *copyError = nil;
                BOOL copied = [MediaUploadDiskStore copyItemReplacingAtURL:cached toURL:mp4URL error:&copyError];
                if (copied) {
                    unsigned long long cachedBytes = [[NSFileManager.defaultManager attributesOfItemAtPath:mp4URL.path error:nil] fileSize];
                    unsigned long long origBytes = [[NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil] fileSize];
                    NSString *profile = [MediaUploadDiskStore profileFingerprintForLevel:level settings:settings];
                    [MediaUploadTrace log:[NSString stringWithFormat:
                        @"CACHE convert-HIT video %@ level=%@ original=%@ result=%@ profile=%@",
                        item.fileName, [MediaUploadTrace levelName:level],
                        [MediaUploadTrace mbUInt:origBytes], [MediaUploadTrace mbUInt:cachedBytes], profile]];
                    void (^finishCached)(void) = ^{
                        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:mp4URL.path error:nil];
                        unsigned long long written = [attrs fileSize];
                        if (written > 0) {
                            if (![item.filePath isEqualToString:mp4URL.path]) {
                                [NSFileManager.defaultManager removeItemAtURL:item.fileURL error:nil];
                            }
                            item.fileURL = mp4URL;
                            item.filePath = mp4URL.path;
                            item.fileName = mp4Name;
                        }
                        if (progress) {
                            progress(1.0f);
                        }
                        if (completion) {
                            completion();
                        }
                    };
                    dispatch_async(dispatch_get_main_queue(), finishCached);
                    return;
                }
                [MediaUploadTrace log:[NSString stringWithFormat:@"CACHE convert-copy-FAIL video %@", copyError.localizedDescription ?: @""]];
            }

            unsigned long long origBefore = [[NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:nil] fileSize];
            [MediaUploadTrace log:[NSString stringWithFormat:
                @"ENCODE video start %@ level=%@ original=%@ edgeCap=%ld",
                item.fileName, [MediaUploadTrace levelName:level],
                [MediaUploadTrace mbUInt:origBefore], (long)self.batchVideoMaxEdgeCap]];

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
                if (success) {
                    [MediaUploadDiskStore storeConvertResultFrom:mp4URL
                                                       sourceURL:sourceURL
                                                       accountId:accountId
                                                           level:level
                                                        settings:settings];
                }
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
                            [MediaUploadTrace log:[NSString stringWithFormat:
                                @"RESULT video %@ level=%@ original=%@ → result=%@ (kept compressed)",
                                item.fileName, [MediaUploadTrace levelName:level],
                                [MediaUploadTrace mbUInt:origBefore], [MediaUploadTrace mbUInt:written]]];
                        } else {
                            [MediaUploadTrace log:[NSString stringWithFormat:@"RESULT video %@ refused 0-byte output", mp4Name]];
                            [NSFileManager.defaultManager removeItemAtURL:mp4URL error:nil];
                        }
                    } else {
                        [MediaUploadTrace log:[NSString stringWithFormat:
                            @"RESULT video %@ level=%@ original=%@ → FAILED (kept original)",
                            item.fileName, [MediaUploadTrace levelName:level], [MediaUploadTrace mbUInt:origBefore]]];
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
                                      progress:(void (^)(float fraction, NSInteger current, NSInteger total))progress
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
            progress(1.0f, 0, 0);
        }
        if (completion) {
            completion();
        }
        return;
    }

    [self.activePreparationToken cancel];
    self.activePreparationToken = [[MediaUploadPreparationToken alloc] init];

    [MediaUploadTrace logSync:[NSString stringWithFormat:@"PREPARE begin compress=%ld/%ld serially settings={%@}",
                               (long)totalToCompress, (long)items.count, [MediaUploadTrace settingsSnapshot]]];

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

    // Multi-file batch: keep the Settings engine (Writer or Presets), encode serially via
    // MediaUploadVideoEncodeQueue, and cap Writer max-edge so peak RAM stays lower.
    NSInteger videoToCompress = 0;
    unsigned long long videoBytes = 0;
    for (ShareItem *item in itemsToCompress) {
        NSString *ext = item.fileName.pathExtension.lowercaseString;
        if (ext.length > 0 && [MediaUploadPreprocessor isVideoFileExtension:ext]) {
            videoToCompress += 1;
            videoBytes += [[NSFileManager.defaultManager attributesOfItemAtPath:item.filePath error:nil] fileSize];
        }
    }
    BOOL multiVideo = (videoToCompress >= 2);
    BOOL heavyBatch = (multiVideo && videoBytes >= 40ULL * 1024ULL * 1024ULL);
    BOOL writerChosen = [MediaUploadDebugSettings sharedSettings].usesAssetWriter;
    MediaUploadPreprocessor.preferExportSession = NO;
    if (writerChosen && heavyBatch) {
        self.batchVideoMaxEdgeCap = 640;
        [MediaUploadTrace logSync:[NSString stringWithFormat:
            @"JETSAM multi-video Writer serial videos=%ld videoBytes=%@ edgeCap=640 (heavy≥40MB)",
            (long)videoToCompress, [MediaUploadTrace mbUInt:videoBytes]]];
    } else if (writerChosen && multiVideo) {
        self.batchVideoMaxEdgeCap = 720;
        [MediaUploadTrace logSync:[NSString stringWithFormat:
            @"JETSAM multi-video Writer serial videos=%ld videoBytes=%@ edgeCap=720",
            (long)videoToCompress, [MediaUploadTrace mbUInt:videoBytes]]];
    } else {
        self.batchVideoMaxEdgeCap = 0;
        if (multiVideo) {
            [MediaUploadTrace logSync:[NSString stringWithFormat:
                @"JETSAM multi-video ExportSession serial videos=%ld (Settings=Presets)",
                (long)videoToCompress]];
        } else if (videoToCompress == 1) {
            [MediaUploadTrace log:[NSString stringWithFormat:
                @"JETSAM single-video engine=%@ edgeCap=profile",
                writerChosen ? @"Writer" : @"ExportSession"]];
        }
    }

    for (NSInteger i = 0; i < totalToCompress; i++) {
        ShareItem *it = itemsToCompress[i];
        MediaUploadCompressionLevel lv = (MediaUploadCompressionLevel)levelsToCompress[i].integerValue;
        unsigned long long sz = [[NSFileManager.defaultManager attributesOfItemAtPath:it.filePath error:nil] fileSize];
        [MediaUploadTrace log:[NSString stringWithFormat:@"PREPARE queue[%ld] %@ level=%@ original=%@",
                               (long)i, it.fileName, [MediaUploadTrace levelName:lv], [MediaUploadTrace mbUInt:sz]]];
    }

    if (progress) {
        progress(0.0f, 1, totalToCompress);
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
            NSInteger current = completedCount >= totalToCompress
                ? totalToCompress
                : MAX((NSInteger)1, completedCount + 1);
            progress(overall, current, totalToCompress);
        };
        if ([NSThread isMainThread]) {
            emit();
        } else {
            dispatch_async(dispatch_get_main_queue(), emit);
        }
    };

    BOOL usedExportBatch = multiVideo && !writerChosen;
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
                    // Give mediaserverd a breather between serial encodes.
                    [MediaUploadMemoryGateObjC waitForHeadroom];
                    [NSThread sleepForTimeInterval:multiVideo ? 0.35 : 0.12];
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
